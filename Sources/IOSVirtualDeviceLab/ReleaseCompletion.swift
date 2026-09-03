import CryptoKit
import Foundation

// MARK: - Shared v1 completion contracts

enum CompletionGateState: String, Codable, CaseIterable, Sendable {
    case blocked
    case ready
    case passed
}

struct CompletionGate: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let title: String
    let state: CompletionGateState
    let evidence: String
    let requiredAction: String

    var passed: Bool { state == .passed }
}

enum SupportContractStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case draft
    case candidate
    case approved

    var id: String { rawValue }
}

struct V1SupportContract: Codable, Hashable, Sendable {
    var schemaVersion: Int
    var productVersion: String
    var minimumMacOSVersion: String
    var supportedArchitectures: [String]
    var backendID: String
    var minimumBackendVersion: String
    var guestProtocolVersion: Int
    var supportedIOSVersions: [String]
    var hardwareProfileIDs: [String]
    var requiredWorkflows: [String]
    var status: SupportContractStatus
    var approvedBy: String?
    var approvedAt: Date?
    var updatedAt: Date

    static let draft = V1SupportContract(
        schemaVersion: 1,
        productVersion: "1.0.0",
        minimumMacOSVersion: "15.0.0",
        supportedArchitectures: ["arm64"],
        backendID: BackendDescriptor.vphone.id,
        minimumBackendVersion: "0.8.0",
        guestProtocolVersion: 3,
        supportedIOSVersions: ["15"],
        hardwareProfileIDs: [],
        requiredWorkflows: [
            "boot", "authenticated-guest-control", "app-deployment",
            "diagnostics", "snapshot-restore", "fault-recovery",
        ],
        status: .draft,
        approvedBy: nil,
        approvedAt: nil,
        updatedAt: .now
    )
}

enum SupportContractValidator {
    static func evaluate(_ contract: V1SupportContract) -> [ProductionGateCheck] {
        let versions = contract.supportedIOSVersions.map(normalized).filter { !$0.isEmpty }
        let profiles = contract.hardwareProfileIDs.map(normalized).filter { !$0.isEmpty }
        let workflows = Set(contract.requiredWorkflows.map(normalized).filter { !$0.isEmpty })
        let expectedWorkflows: Set<String> = [
            "boot", "authenticated-guest-control", "app-deployment",
            "diagnostics", "snapshot-restore", "fault-recovery",
        ]
        let architectureSet = Set(contract.supportedArchitectures.map(normalized))
        let iosValid = !versions.isEmpty && versions.allSatisfy { value in
            guard let major = Int(value.split(separator: ".").first ?? "") else { return false }
            return (12...26).contains(major)
        }
        return [
            .init(id: "schema", passed: contract.schemaVersion == 1, evidence: "Support contract schema must be 1."),
            .init(id: "product-version", passed: SemanticVersion(contract.productVersion) != nil, evidence: "Product version must use semantic versioning."),
            .init(id: "host", passed: SemanticVersion(contract.minimumMacOSVersion) != nil && architectureSet == ["arm64"], evidence: "v1 must declare a semantic minimum macOS version and the arm64 architecture."),
            .init(id: "backend", passed: contract.backendID == BackendDescriptor.vphone.id && SemanticVersion(contract.minimumBackendVersion) != nil, evidence: "v1 must pin the runnable vphone backend and a semantic minimum version."),
            .init(id: "guest-protocol", passed: contract.guestProtocolVersion == 3, evidence: "The supported guest-control contract is protocol v3."),
            .init(id: "ios", passed: iosValid, evidence: iosValid ? "Declared iOS lines: \(versions.joined(separator: ", "))." : "At least one valid iOS 12–26 line is required."),
            .init(id: "profiles", passed: !profiles.isEmpty && Set(profiles).count == profiles.count, evidence: profiles.isEmpty ? "At least one exact hardware profile is required." : "\(profiles.count) exact hardware profile(s) declared."),
            .init(id: "workflows", passed: expectedWorkflows.isSubset(of: workflows), evidence: "The contract must include all six v1 workflows."),
        ]
    }

    static func candidate(_ contract: V1SupportContract) -> V1SupportContract {
        var result = contract
        result.supportedIOSVersions = uniqueNormalized(result.supportedIOSVersions)
        result.hardwareProfileIDs = uniqueNormalized(result.hardwareProfileIDs)
        result.requiredWorkflows = uniqueNormalized(result.requiredWorkflows)
        result.supportedArchitectures = uniqueNormalized(result.supportedArchitectures)
        result.approvedAt = nil
        result.approvedBy = nil
        result.status = evaluate(result).allSatisfy(\.passed) ? .candidate : .draft
        result.updatedAt = .now
        return result
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func uniqueNormalized(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.map(normalized).filter { !$0.isEmpty && seen.insert($0).inserted }.sorted()
    }
}

// MARK: - Guest companion source and release conformance

struct GuestCompanionSourceReport: Codable, Hashable, Sendable {
    let inspectedAt: Date
    let repositoryPath: String?
    let sourceRevision: String?
    let checks: [ProductionGateCheck]
    let declaredCapabilities: [String]
    let passed: Bool
    let message: String

    static let unavailable = GuestCompanionSourceReport(
        inspectedAt: .distantPast, repositoryPath: nil, sourceRevision: nil,
        checks: [], declaredCapabilities: [], passed: false,
        message: "The vphone guest companion source has not been inspected."
    )
}

enum GuestCompanionSourceAuditor {
    static let requiredCapabilities = [
        "deterministic_reset", "accessibility_tree", "companion_lifecycle",
        "fault_injection", "fault_clear", "fault_status",
    ]

    static func inspect(repositoryRoot: URL) -> GuestCompanionSourceReport {
        let root = repositoryRoot.standardizedFileURL
        let host = readableText(root.appendingPathComponent("sources/vphone-cli/VPhoneHostControl.swift"))
        let guest = readableText(root.appendingPathComponent("scripts/vphoned/vphoned.m"))
        let reset = readableText(root.appendingPathComponent("scripts/vphoned/vphoned_reset.m"))
        let faults = readableText(root.appendingPathComponent("scripts/vphoned/vphoned_faults.m"))
        let accessibility = readableText(root.appendingPathComponent("scripts/vphoned/vphoned_accessibility.m"))
        let contractURL = root.appendingPathComponent("sources/vdl-backend-contract.json")
        let contractCapabilities: [String] = {
            guard let data = try? Data(contentsOf: contractURL), data.count <= 1_048_576,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return [] }
            return object["guestCapabilities"] as? [String] ?? []
        }()
        let revision = ProcessExecutor.run(
            executable: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-C", root.path, "rev-parse", "HEAD"],
            timeout: 10, maximumOutputBytes: 4_096
        )
        let revisionValue = revision.succeeded
            ? revision.output.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        let dispatchImplemented = requiredCapabilities.allSatisfy { host.contains("\"\($0)\"") }
            && ["deterministic_reset", "accessibility_tree", "fault_injection", "fault_clear", "fault_status"]
                .allSatisfy { guest.contains("\"\($0)\"") }
        let capabilitySet = Set(contractCapabilities)
        let checks = [
            ProductionGateCheck(id: "repository", passed: FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path), evidence: "A vphone Swift package checkout is required."),
            ProductionGateCheck(id: "revision", passed: revisionValue?.count == 40, evidence: revisionValue.map { "Source revision \($0)." } ?? "The exact Git source revision is unavailable."),
            ProductionGateCheck(id: "host-dispatch", passed: dispatchImplemented, evidence: "Host control must expose and route all required companion operations."),
            ProductionGateCheck(id: "reset-module", passed: reset.contains("vp_handle_reset_command") && reset.contains("reset_app_data") && reset.contains("reset_permissions") && reset.contains("reset_keychain") && reset.contains("reset_network"), evidence: "The guest must implement bounded deterministic reset operations."),
            ProductionGateCheck(id: "accessibility-module", passed: accessibility.contains("accessibility_root") && !accessibility.contains("not yet implemented"), evidence: "The guest accessibility handler must return a structured root instead of a stub."),
            ProductionGateCheck(id: "fault-module", passed: faults.contains("vp_handle_fault_command") && faults.contains("fault_clear") && faults.contains("fault_status"), evidence: "Fault execution must include explicit clear and status operations."),
            ProductionGateCheck(id: "contract", passed: Set(requiredCapabilities).isSubset(of: capabilitySet), evidence: "The machine-readable backend contract must declare the full companion surface."),
        ]
        let passed = checks.allSatisfy(\.passed)
        return GuestCompanionSourceReport(
            inspectedAt: .now, repositoryPath: root.path, sourceRevision: revisionValue,
            checks: checks, declaredCapabilities: contractCapabilities.sorted(), passed: passed,
            message: passed
                ? "Guest companion source conformance passed. Real-guest capability negotiation is still required."
                : "Guest companion source conformance found missing or stubbed operations."
        )
    }

    private static func readableText(_ url: URL) -> String {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              (values.fileSize ?? 0) <= 4 * 1_048_576
        else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}

// MARK: - Real desktop UI automation evidence

struct UIAutomationEvidenceCheck: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let passed: Bool
    let evidence: String
}

struct UIAutomationEvidence: Identifiable, Codable, Hashable, Sendable {
    let schemaVersion: Int
    let id: UUID
    let generatedAt: Date
    let appPath: String
    let appVersion: String?
    let sourceRevision: String?
    let harnessVersion: String
    let checks: [UIAutomationEvidenceCheck]
    let observedIdentifiers: [String]
    let passed: Bool
    var reportSHA256: String?

    static let unavailable = UIAutomationEvidence(
        schemaVersion: 1, id: UUID(), generatedAt: .distantPast,
        appPath: "", appVersion: nil, sourceRevision: nil, harnessVersion: "unavailable",
        checks: [], observedIdentifiers: [], passed: false, reportSHA256: nil
    )
}

enum UIAutomationEvidenceImporter {
    static let requiredIdentifiers = [
        "lab.refresh", "lab.create-device", "continuity.refresh",
        "continuity.storage-relink", "continuity.labfile-apply",
        "depth.fault.inject", "depth.fault.clear", "completion.evaluate",
    ]

    static func load(_ url: URL) throws -> UIAutomationEvidence {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= 4 * 1_048_576 else {
            throw ProductionDepthError.invalid("UI automation evidence must be a regular JSON file no larger than 4 MiB.")
        }
        let data = try Data(contentsOf: url)
        var report = try JSONDecoder.completionISO8601.decode(UIAutomationEvidence.self, from: data)
        let identifiers = Set(report.observedIdentifiers)
        let revisionIsValid = report.sourceRevision.map { revision in
            [40, 64].contains(revision.count)
                && revision.unicodeScalars.allSatisfy { scalar in
                    (48...57).contains(scalar.value)
                        || (65...70).contains(scalar.value)
                        || (97...102).contains(scalar.value)
                }
        } == true
        guard report.schemaVersion == 1, report.harnessVersion != "unavailable",
              report.appVersion?.isEmpty == false, revisionIsValid,
              !report.checks.isEmpty, report.checks.allSatisfy(\.passed), report.passed,
              Set(requiredIdentifiers).isSubset(of: identifiers) else {
            throw ProductionDepthError.invalid("UI automation evidence must pass every check, include build identity, and expose every required accessibility identifier.")
        }
        report.reportSHA256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return report
    }
}

// MARK: - Recoverable fault lifecycle

struct FaultRecoveryReceipt: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let scenarioID: UUID?
    let deviceName: String
    let requestedAt: Date
    let completedAt: Date
    let clearAcknowledged: Bool
    let statusVerified: Bool
    let remainingFaults: [String]
    let message: String

    var recovered: Bool { clearAcknowledged && statusVerified && remainingFaults.isEmpty }
}

// MARK: - Fleet authorization and two-host exercise evidence

enum FleetRole: String, Codable, CaseIterable, Identifiable, Sendable {
    case viewer
    case operatorRole = "operator"
    case administrator
    var id: String { rawValue }
}

enum FleetPermission: String, Codable, CaseIterable, Sendable {
    case readStatus
    case submitJob
    case cancelJob
    case drainHost
    case enrollHost
    case rotateCredentials
    case approveEvidence
}

struct FleetPrincipal: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var subject: String
    var role: FleetRole
    var certificateSHA256: String?
    var enabled: Bool
}

struct FleetAccessPolicy: Codable, Hashable, Sendable {
    var schemaVersion: Int
    var principals: [FleetPrincipal]
    var requirePinnedClientCertificate: Bool
    var requireDistinctOperatorAndAdministrator: Bool
    var updatedAt: Date

    static var localDraft: FleetAccessPolicy {
        FleetAccessPolicy(
            schemaVersion: 1,
            principals: [FleetPrincipal(
                id: UUID(), subject: NSUserName(), role: .administrator,
                certificateSHA256: nil, enabled: true
            )],
            requirePinnedClientCertificate: true,
            requireDistinctOperatorAndAdministrator: true,
            updatedAt: .now
        )
    }
}

enum FleetAuthorizationEvaluator {
    static func permissions(for role: FleetRole) -> Set<FleetPermission> {
        switch role {
        case .viewer: [.readStatus]
        case .operatorRole: [.readStatus, .submitJob, .cancelJob]
        case .administrator: Set(FleetPermission.allCases)
        }
    }

    static func evaluate(_ policy: FleetAccessPolicy) -> [ProductionGateCheck] {
        let enabled = policy.principals.filter(\.enabled)
        let subjects = enabled.map { $0.subject.trimmingCharacters(in: .whitespacesAndNewlines) }
        let uniqueSubjects = Set(subjects)
        let pinsValid = !policy.requirePinnedClientCertificate || enabled.allSatisfy { principal in
            guard let pin = principal.certificateSHA256 else { return false }
            return pin.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil
        }
        let distinctRoles = !policy.requireDistinctOperatorAndAdministrator
            || (enabled.contains { $0.role == .administrator }
                && enabled.contains { $0.role == .operatorRole }
                && Set(enabled.filter { [.administrator, .operatorRole].contains($0.role) }.map(\.subject)).count >= 2)
        return [
            .init(id: "schema", passed: policy.schemaVersion == 1, evidence: "Fleet access-policy schema must be 1."),
            .init(id: "subjects", passed: !subjects.isEmpty && !subjects.contains("") && uniqueSubjects.count == subjects.count, evidence: "Enabled fleet subjects must be explicit and unique."),
            .init(id: "certificates", passed: pinsValid, evidence: pinsValid ? "Every enabled principal has an exact certificate pin." : "Each enabled principal requires a 64-character certificate SHA-256 pin."),
            .init(id: "separation", passed: distinctRoles, evidence: distinctRoles ? "Operator and administrator duties are separated." : "Use distinct enabled operator and administrator subjects."),
        ]
    }

    static func authorize(
        subject: String,
        certificateSHA256: String,
        permission: FleetPermission,
        policy: FleetAccessPolicy
    ) -> Bool {
        guard evaluate(policy).allSatisfy(\.passed),
              let principal = policy.principals.first(where: {
                  $0.enabled && $0.subject == subject
                      && $0.certificateSHA256?.caseInsensitiveCompare(certificateSHA256) == .orderedSame
              }) else { return false }
        return permissions(for: principal.role).contains(permission)
    }
}

struct FleetQualificationExercise: Identifiable, Codable, Hashable, Sendable {
    let schemaVersion: Int
    let id: UUID
    let startedAt: Date
    let completedAt: Date
    let controllerHostID: String
    let agentHostIDs: [String]
    let mutualTLSVerified: Bool
    let heartbeatVerified: Bool
    let leaseExpiryVerified: Bool
    let cancellationVerified: Bool
    let dispatchAuditVerified: Bool
    let requestCorrelationVerified: Bool
    let passed: Bool
    var reportSHA256: String?
}

enum FleetQualificationImporter {
    static func load(_ url: URL) throws -> FleetQualificationExercise {
        let data = try boundedEvidenceData(url, maximumBytes: 4 * 1_048_576)
        var exercise = try JSONDecoder.completionISO8601.decode(FleetQualificationExercise.self, from: data)
        let distinctHosts = Set(exercise.agentHostIDs + [exercise.controllerHostID])
        guard exercise.schemaVersion == 1, distinctHosts.count >= 2,
              exercise.completedAt >= exercise.startedAt,
              exercise.mutualTLSVerified, exercise.heartbeatVerified,
              exercise.leaseExpiryVerified, exercise.cancellationVerified,
              exercise.dispatchAuditVerified, exercise.requestCorrelationVerified,
              exercise.passed else {
            throw ProductionDepthError.invalid("Fleet qualification evidence must pass every control across at least two distinct Macs.")
        }
        exercise.reportSHA256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return exercise
    }
}

// MARK: - Reliability and interruption campaigns

enum ReliabilityScenarioKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case sustainedSoak = "sustained-soak"
    case hostSleepWake = "host-sleep-wake"
    case hostRestart = "host-restart"
    case externalVolumeRemoval = "external-volume-removal"
    case lowDisk = "low-disk"
    case guestOrCompanionHang = "guest-or-companion-hang"
    case networkLoss = "network-loss"
    case interruptedUpdate = "interrupted-update"

    var id: String { rawValue }
}

struct ReliabilityScenarioResult: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let scenario: ReliabilityScenarioKind
    let startedAt: Date
    let completedAt: Date
    let passed: Bool
    let recoveryVerified: Bool
    let evidence: String
}

struct ReliabilityCampaignEvidence: Identifiable, Codable, Hashable, Sendable {
    let schemaVersion: Int
    let id: UUID
    let hostFingerprint: String
    let backendID: String
    let backendVersion: String?
    let startedAt: Date
    let completedAt: Date
    let soakHours: Double
    let scenarios: [ReliabilityScenarioResult]
    let passed: Bool
    var reportSHA256: String?
}

struct ReliabilityCampaignPlan: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let generatedAt: Date
    let minimumSoakHours: Double
    let requiredScenarios: [ReliabilityScenarioKind]
    let safetyNotice: String

    static let standard = ReliabilityCampaignPlan(
        schemaVersion: 1, generatedAt: .now, minimumSoakHours: 24,
        requiredScenarios: ReliabilityScenarioKind.allCases,
        safetyNotice: "Run only on controlled fixtures. Preserve evidence, restore normal networking, reconnect storage, and verify update rollback after every interruption."
    )
}

enum ReliabilityCampaignManager {
    static func exportPlan(_ plan: ReliabilityCampaignPlan = .standard, to url: URL) throws {
        try HardeningJSON.save(plan, to: url)
    }

    static func loadEvidence(_ url: URL, plan: ReliabilityCampaignPlan = .standard) throws -> ReliabilityCampaignEvidence {
        let data = try boundedEvidenceData(url, maximumBytes: 8 * 1_048_576)
        var report = try JSONDecoder.completionISO8601.decode(ReliabilityCampaignEvidence.self, from: data)
        let required = Set(plan.requiredScenarios)
        let passing = Set(report.scenarios.filter { $0.passed && $0.recoveryVerified }.map(\.scenario))
        guard report.schemaVersion == 1, report.completedAt >= report.startedAt,
              report.soakHours >= plan.minimumSoakHours,
              required.isSubset(of: passing), report.passed else {
            throw ProductionDepthError.invalid("Reliability evidence must include the required soak and recovered pass for every interruption scenario.")
        }
        report.reportSHA256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return report
    }
}

// MARK: - Coverage ratchet

struct CoverageRatchetPolicy: Codable, Hashable, Sendable {
    var currentOverallFloor: Double
    var nextOverallFloor: Double
    var releaseOverallTarget: Double
    var minimumUITestChecks: Int
    var updatedAt: Date

    static let standard = CoverageRatchetPolicy(
        currentOverallFloor: 25, nextOverallFloor: 30,
        releaseOverallTarget: 75, minimumUITestChecks: 8, updatedAt: .now
    )
}

enum CoverageRatchet {
    static func evaluate(
        policy: CoverageRatchetPolicy,
        coverage: SourceCoverageRecord?,
        uiEvidence: UIAutomationEvidence?
    ) -> [ProductionGateCheck] {
        let measured = coverage?.linePercent
        let uiCount = uiEvidence?.checks.filter(\.passed).count ?? 0
        return [
            .init(id: "policy", passed: policy.currentOverallFloor >= 25 && policy.nextOverallFloor > policy.currentOverallFloor && policy.releaseOverallTarget >= policy.nextOverallFloor && policy.releaseOverallTarget <= 100, evidence: "Coverage floors must increase monotonically to a bounded release target."),
            .init(id: "current", passed: measured.map { $0 >= policy.currentOverallFloor } == true, evidence: measured.map { String(format: "Measured %.2f%%; current floor %.2f%%.", $0, policy.currentOverallFloor) } ?? "No machine-readable coverage report is imported."),
            .init(id: "next", passed: measured.map { $0 >= policy.nextOverallFloor } == true, evidence: measured.map { String(format: "Measured %.2f%%; next floor %.2f%%.", $0, policy.nextOverallFloor) } ?? "No coverage evidence exists for the next ratchet."),
            .init(id: "ui", passed: uiEvidence?.passed == true && uiCount >= policy.minimumUITestChecks, evidence: "\(uiCount) passing UI check(s); \(policy.minimumUITestChecks) required."),
        ]
    }

    static func advance(
        _ policy: CoverageRatchetPolicy,
        coverage: SourceCoverageRecord?,
        uiEvidence: UIAutomationEvidence?
    ) throws -> CoverageRatchetPolicy {
        let checks = evaluate(policy: policy, coverage: coverage, uiEvidence: uiEvidence)
        guard checks.allSatisfy(\.passed) else {
            throw ProductionDepthError.invalid("Coverage cannot advance until the next measured floor and UI-test minimum pass.")
        }
        var result = policy
        result.currentOverallFloor = policy.nextOverallFloor
        result.nextOverallFloor = min(policy.releaseOverallTarget, policy.nextOverallFloor + 5)
        result.updatedAt = .now
        return result
    }
}

// MARK: - Release exit report and persistence

struct ReleaseCompletionReport: Codable, Hashable, Sendable {
    let generatedAt: Date
    let gates: [CompletionGate]
    let releaseAuthorized: Bool
    let summary: String

    static let empty = ReleaseCompletionReport(
        generatedAt: .distantPast, gates: [], releaseAuthorized: false,
        summary: "The v1 completion report has not been evaluated."
    )
}

struct ReleaseCompletionState: Codable, Hashable, Sendable {
    var schemaVersion: Int
    var supportContract: V1SupportContract
    var companionSource: GuestCompanionSourceReport
    var uiAutomation: [UIAutomationEvidence]
    var faultRecoveries: [FaultRecoveryReceipt]
    var fleetAccessPolicy: FleetAccessPolicy
    var fleetExercises: [FleetQualificationExercise]
    var reliabilityCampaigns: [ReliabilityCampaignEvidence]
    var coverageRatchet: CoverageRatchetPolicy
    var report: ReleaseCompletionReport

    static let empty = ReleaseCompletionState(
        schemaVersion: 1, supportContract: .draft,
        companionSource: .unavailable, uiAutomation: [], faultRecoveries: [],
        fleetAccessPolicy: .localDraft, fleetExercises: [], reliabilityCampaigns: [],
        coverageRatchet: .standard, report: .empty
    )
}

struct ReleaseCompletionContext: Sendable {
    let liveGuestCapabilities: Set<GuestCapability>
    let acceptance: AcceptanceReport
    let qualificationMatrix: [QualificationMatrixEntry]
    let successfulFaultScenarioIDs: Set<UUID>
    let coverage: SourceCoverageRecord?
    let publicBeta: PublicBetaReadinessReport
    let stagedUpdate: StagedUpdateRecord?
    let secondVolumeRestoreRecorded: Bool
}

enum ReleaseCompletionEvaluator {
    static func evaluate(
        state: ReleaseCompletionState,
        context: ReleaseCompletionContext
    ) -> ReleaseCompletionReport {
        func gate(
            _ id: String,
            _ title: String,
            _ passed: Bool,
            ready: Bool = false,
            evidence: String,
            action: String
        ) -> CompletionGate {
            CompletionGate(
                id: id, title: title,
                state: passed ? .passed : (ready ? .ready : .blocked),
                evidence: evidence, requiredAction: action
            )
        }

        let contractChecks = SupportContractValidator.evaluate(state.supportContract)
        let contractReady = contractChecks.allSatisfy(\.passed) && state.supportContract.status != .draft
        let requiredGuest: Set<GuestCapability> = [.deterministicReset, .accessibilityTree, .companionLifecycle, .faultInjection]
        let guestQualified = state.companionSource.passed && requiredGuest.isSubset(of: context.liveGuestCapabilities)
        let versions = Set(state.supportContract.supportedIOSVersions.map {
            String($0.split(separator: ".").first ?? "")
        })
        let profileIDs = Set(state.supportContract.hardwareProfileIDs)
        let minimumBackend = SemanticVersion(state.supportContract.minimumBackendVersion)
        let qualifiedRows = context.qualificationMatrix.filter { row in
            guard row.state == .approved,
                  row.backendID == state.supportContract.backendID,
                  profileIDs.contains(row.hardwareProfileID),
                  let minimumBackend,
                  let rowVersion = row.backendVersion.flatMap(SemanticVersion.init)
            else { return false }
            return rowVersion >= minimumBackend
        }
        let approvedVersions = Set(qualifiedRows.map {
            String($0.iosVersion.split(separator: ".").first ?? "")
        })
        let matrixPassed = !versions.isEmpty && !profileIDs.isEmpty && versions.isSubset(of: approvedVersions)
        let ui = state.uiAutomation.first
        let uiQualified = ui?.passed == true
            && ui?.appVersion == state.supportContract.productVersion
        let fault = state.faultRecoveries.first
        let faultQualified = fault?.recovered == true
            && fault?.scenarioID.map(context.successfulFaultScenarioIDs.contains) == true
        let fleetPolicyPassed = FleetAuthorizationEvaluator.evaluate(state.fleetAccessPolicy).allSatisfy(\.passed)
        let fleet = state.fleetExercises.first
        let reliability = state.reliabilityCampaigns.first
        let coverage = context.coverage?.linePercent
        let releaseChecks = context.stagedUpdate.map {
            $0.signatureVerified && $0.notarizationVerified && $0.migrationPreflightPassed
        } == true
        let gates = [
            gate("support-contract", "v1 support contract", contractReady, evidence: contractReady ? "\(state.supportContract.productVersion) candidate pins \(versions.sorted().joined(separator: ", ")) and \(state.supportContract.hardwareProfileIDs.count) profile(s)." : contractChecks.filter { !$0.passed }.map(\.evidence).joined(separator: " "), action: "Save a complete candidate support contract; approve it only after every other gate passes."),
            gate("guest-companion", "Guest companion", guestQualified, ready: state.companionSource.passed, evidence: guestQualified ? "Source conformance and live protocol-v3 capability negotiation passed." : state.companionSource.message, action: "Build/install the companion, boot a guest, and negotiate all four required capabilities."),
            gate("real-acceptance", "Real-VM acceptance", context.acceptance.isPassed, evidence: context.acceptance.isPassed ? "Every baseline acceptance gate passed." : "The current acceptance report is incomplete or blocked.", action: "Run baseline acceptance on an authorized supported IPSW after host preflight."),
            gate("compatibility-matrix", "Supported iOS matrix", matrixPassed, ready: !approvedVersions.isEmpty, evidence: matrixPassed ? "Every declared iOS line has approved qualification evidence." : "Declared \(versions.sorted()); approved \(approvedVersions.sorted()).", action: "Complete and approve exact qualification campaigns for every declared iOS line."),
            gate("ui-automation", "Desktop UI automation", uiQualified, ready: ui?.passed == true, evidence: ui.map { "\($0.checks.filter(\.passed).count) UI checks passed for app \($0.appVersion ?? "unknown"); report \($0.reportSHA256.map { String($0.prefix(12)) } ?? "unhashed")." } ?? "No real UI harness report is imported.", action: "Run the packaged vdl-ui-smoke harness against the exact support-contract build and import its report."),
            gate("fault-recovery", "Fault cleanup and recovery", faultQualified, ready: fault?.recovered == true, evidence: fault?.message ?? "No verified fault-clear receipt exists.", action: "Inject a supported guest fault, clear it, and verify that the matching scenario has no active faults."),
            gate("fleet", "Fleet control and authorization", fleetPolicyPassed && fleet?.passed == true, ready: fleetPolicyPassed || fleet?.passed == true, evidence: fleetPolicyPassed && fleet?.passed == true ? "RBAC policy and a two-host mTLS exercise passed." : "RBAC policy valid: \(fleetPolicyPassed); two-host exercise: \(fleet?.passed == true).", action: "Pin distinct operator/admin certificates and import a passing two-Mac fleet exercise."),
            gate("reliability", "Reliability campaign", reliability?.passed == true && (reliability?.soakHours ?? 0) >= 24, evidence: reliability.map { String(format: "%.2f soak hours and %d recovered scenarios.", $0.soakHours, $0.scenarios.filter { $0.passed && $0.recoveryVerified }.count) } ?? "No reliability campaign evidence is imported.", action: "Complete the 24-hour soak and all interruption/recovery scenarios."),
            gate("quality", "Coverage ratchet", coverage.map { $0 >= state.coverageRatchet.releaseOverallTarget } == true && uiQualified && context.coverage?.sourceRevision == ui?.sourceRevision, ready: coverage.map { $0 >= state.coverageRatchet.currentOverallFloor } == true, evidence: coverage.map { String(format: "Measured %.2f%%; v1 target %.2f%%. Coverage/UI revisions match: %@.", $0, state.coverageRatchet.releaseOverallTarget, context.coverage?.sourceRevision == ui?.sourceRevision && context.coverage?.sourceRevision != nil ? "true" : "false") } ?? "No source coverage evidence is imported.", action: "Raise measured source coverage in ratcheted steps and retain UI evidence from the same source revision."),
            gate("release-exit", "Signed release, recovery, privacy, and legal exit", releaseChecks && context.publicBeta.passed && context.secondVolumeRestoreRecorded, ready: releaseChecks || context.publicBeta.passed, evidence: "Signed/notarized staged update: \(releaseChecks); public-beta gates: \(context.publicBeta.passed); second-volume restore: \(context.secondVolumeRestoreRecorded).", action: "Stage the notarized release, pass public-beta/legal gates, and record the second-volume restore drill."),
        ]
        let evidencePassed = gates.allSatisfy(\.passed)
        let authorized = evidencePassed && state.supportContract.status == .approved
        return ReleaseCompletionReport(
            generatedAt: .now, gates: gates, releaseAuthorized: authorized,
            summary: authorized
                ? "v1 is authorized by the approved support contract and all ten evidence gates."
                : "v1 remains on hold: \(gates.filter { !$0.passed }.count) evidence gate(s) are incomplete\(state.supportContract.status == .approved ? "." : ", and the support contract is not approved.")"
        )
    }
}

enum ReleaseCompletionStore {
    static func url(paths: LabPaths) -> URL {
        paths.stateRoot.appendingPathComponent("release-completion.json")
    }

    static func load(paths: LabPaths) -> ReleaseCompletionState {
        let source = url(paths: paths)
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= 32 * 1_024 * 1_024,
              var state = try? HardeningJSON.load(ReleaseCompletionState.self, from: source),
              state.schemaVersion == 1 else { return .empty }
        state.uiAutomation = Array(state.uiAutomation.prefix(100))
        state.faultRecoveries = Array(state.faultRecoveries.prefix(1_000))
        state.fleetAccessPolicy.principals = Array(state.fleetAccessPolicy.principals.prefix(100))
        state.fleetExercises = Array(state.fleetExercises.prefix(100))
        state.reliabilityCampaigns = Array(state.reliabilityCampaigns.prefix(100))
        return state
    }

    static func save(_ state: ReleaseCompletionState, paths: LabPaths) throws {
        try HardeningJSON.save(state, to: url(paths: paths))
    }
}

private func boundedEvidenceData(_ url: URL, maximumBytes: Int) throws -> Data {
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true,
          let size = values.fileSize, size > 0, size <= maximumBytes else {
        throw ProductionDepthError.invalid("Evidence must be a bounded regular file and cannot be a symbolic link.")
    }
    return try Data(contentsOf: url)
}

private extension JSONDecoder {
    static var completionISO8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
