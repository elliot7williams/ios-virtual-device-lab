import CryptoKit
import Foundation

// MARK: - 1. Evidence-backed capability maturity

enum CapabilityMaturityLevel: Int, Codable, CaseIterable, Comparable, Sendable {
    case designed = 0
    case implemented = 1
    case integrated = 2
    case realVMQualified = 3
    case releaseReady = 4

    static func < (lhs: CapabilityMaturityLevel, rhs: CapabilityMaturityLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var title: String {
        switch self {
        case .designed: "Designed"
        case .implemented: "Implemented"
        case .integrated: "Integrated"
        case .realVMQualified: "Real-VM qualified"
        case .releaseReady: "Release ready"
        }
    }
}

struct CapabilityMaturityRecord: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let name: String
    let level: CapabilityMaturityLevel
    let evidence: [String]
    let blockers: [String]
    let evaluatedAt: Date
}

enum CapabilityMaturityEvaluator {
    struct Evidence: Sendable {
        let adapterInstalled: Bool
        let adapterInvocationSucceeded: Bool
        let guestAutomationAvailable: Bool
        let replayValidated: Bool
        let symbolicationSucceeded: Bool
        let fleetLeaseActive: Bool
        let timelineCaptured: Bool
        let coverageImported: Bool
        let physicalTargetDiscovered: Bool
        let approvedQualificationCount: Int
    }

    static func evaluate(_ evidence: Evidence) -> [CapabilityMaturityRecord] {
        func record(
            _ id: String,
            _ name: String,
            implemented: Bool,
            integrated: Bool,
            qualified: Bool,
            proof: [String],
            blockers: [String]
        ) -> CapabilityMaturityRecord {
            let level: CapabilityMaturityLevel
            if qualified { level = .realVMQualified }
            else if integrated { level = .integrated }
            else if implemented { level = .implemented }
            else { level = .designed }
            return CapabilityMaturityRecord(
                id: id, name: name, level: level, evidence: proof,
                blockers: blockers, evaluatedAt: .now
            )
        }

        let hasQualification = evidence.approvedQualificationCount > 0
        return [
            record("capability-maturity", "Capability maturity matrix", implemented: true, integrated: true,
                   qualified: false, proof: ["Versioned evidence evaluator and persisted matrix are active."],
                   blockers: ["Release-ready promotion requires an approved release policy and signed release evidence."]),
            record("real-vm-qualification", "Real-VM qualification", implemented: true, integrated: true,
                   qualified: hasQualification, proof: hasQualification ? ["At least one passed campaign has an approved evidence seal."] : ["Campaign and matrix evaluators are integrated."],
                   blockers: hasQualification ? [] : ["No approved real-VM qualification evidence exists on this host."]),
            record("runtime-adapters", "Runtime adapter host", implemented: true, integrated: evidence.adapterInvocationSucceeded,
                   qualified: false,
                   proof: evidence.adapterInvocationSucceeded ? ["A checksum-pinned adapter returned a valid correlated runtime response."] : (evidence.adapterInstalled ? ["A checksum-pinned adapter is installed."] : ["Installer, sandbox, invocation, and rollback contracts are implemented."]),
                   blockers: evidence.adapterInvocationSucceeded ? ["Run the adapter in a feature-specific approved real-VM campaign."] : (evidence.adapterInstalled ? ["No installed adapter has returned a valid correlated runtime response."] : ["No checksum-pinned adapter is installed."])),
            record("guest-automation", "Guest automation services", implemented: true, integrated: evidence.guestAutomationAvailable,
                   qualified: false,
                   proof: evidence.guestAutomationAvailable ? ["Authenticated protocol v3 advertises guest automation."] : ["Typed guest automation operations fail closed behind guest trust."],
                   blockers: evidence.guestAutomationAvailable ? ["Capture and approve feature-specific real-VM automation evidence."] : ["The active guest does not advertise authenticated automation capabilities."]),
            record("replay", "Replay validation and execution", implemented: true, integrated: evidence.replayValidated,
                   qualified: false,
                   proof: evidence.replayValidated ? ["A replay manifest passed identity and fixture validation."] : ["Replay manifests, hashes, fixtures, builds, and environments are validated."],
                   blockers: evidence.replayValidated ? ["Execute and approve a feature-specific replay on a real VM."] : ["No replay bundle has passed validation."]),
            record("symbolication", "Crash symbolication", implemented: true, integrated: evidence.symbolicationSucceeded,
                   qualified: false,
                   proof: evidence.symbolicationSucceeded ? ["A crash was matched to a dSYM UUID and symbolicated."] : ["UUID verification, atos invocation, and crash fingerprinting are implemented."],
                   blockers: evidence.symbolicationSucceeded ? ["Approve feature-specific symbolication evidence from a real-VM crash."] : ["No UUID-matched crash and dSYM have been symbolicated."]),
            record("fleet", "Production fleet control", implemented: true, integrated: evidence.fleetLeaseActive,
                   qualified: false,
                   proof: evidence.fleetLeaseActive ? ["An authenticated leased job dispatch has been recorded."] : ["Reservations, leases, heartbeats, expiry, and drain state are modeled."],
                   blockers: evidence.fleetLeaseActive ? ["mTLS multi-Mac transport still requires two-host qualification."] : ["No live fleet lease exists; multi-Mac mTLS transport remains unqualified."]),
            record("timeline", "High-fidelity timelines", implemented: true, integrated: evidence.timelineCaptured,
                   qualified: false,
                   proof: evidence.timelineCaptured ? ["A monotonic-clock timeline artifact was captured."] : ["Monotonic events, clock calibration, and source availability are implemented."],
                   blockers: evidence.timelineCaptured ? ["Capture and approve a feature-specific real-VM timeline with required guest sources."] : ["No high-fidelity timeline session has been captured."]),
            record("quality", "Automated quality pipeline", implemented: true, integrated: evidence.coverageImported,
                   qualified: false,
                   proof: evidence.coverageImported ? ["Machine-readable source coverage was imported."] : ["LLVM/xccov JSON coverage import and quality gates are implemented."],
                   blockers: evidence.coverageImported ? ["Meet the release coverage threshold and attach the report to signed release evidence."] : ["No source coverage evidence has been imported."]),
            record("hybrid-lab", "Hybrid virtual/physical lab", implemented: true, integrated: evidence.physicalTargetDiscovered,
                   qualified: false,
                   proof: evidence.physicalTargetDiscovered ? ["CoreDevice installed and launched a signed app on an authorized physical target."] : ["Target discovery, capability-aware routing, and explicit CoreDevice deployment are implemented."],
                   blockers: evidence.physicalTargetDiscovered ? ["Capture and approve feature-specific physical-device evidence."] : ["No successful authorized physical-device install and launch is recorded."]),
        ]
    }
}

// MARK: - 2. Real-VM qualification matrix and publication

enum QualificationPublicationState: String, Codable, Sendable {
    case blocked, candidate, approved
}

struct QualificationMatrixEntry: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let iosVersion: String
    let deviceProductType: String
    let hardwareProfileID: String
    let backendID: String
    let backendVersion: String?
    let campaignID: UUID?
    let evidenceSealID: UUID?
    let state: QualificationPublicationState
    let blockers: [String]
    let evaluatedAt: Date
}

struct PublishedCompatibilityEvidence: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let generatedAt: Date
    let entries: [QualificationMatrixEntry]
    let evidenceSeals: [EvidenceSeal]
    let sourceStateSHA256: String
}

enum QualificationMatrixEvaluator {
    static func evaluate(
        devices: [VirtualDevice],
        campaigns: [QualificationCampaign],
        seals: [EvidenceSeal]
    ) -> [QualificationMatrixEntry] {
        let approvedSeals = Dictionary(uniqueKeysWithValues: seals.filter { $0.reviewState == .approved }.map { ($0.id, $0) })
        return devices.compactMap { device in
            guard let version = device.restoreInfo?.ios.version,
                  let product = device.restoreInfo?.device,
                  let profile = device.hardwareProfileID else { return nil }
            let campaign = campaigns
                .filter { $0.deviceName == device.name && $0.hardwareProfileID == profile }
                .sorted { $0.createdAt > $1.createdAt }.first
            let approved = campaign?.state == .passed
                && campaign?.evidenceSealID.flatMap { approvedSeals[$0] } != nil
            var blockers: [String] = []
            if campaign == nil { blockers.append("No exact qualification campaign exists.") }
            if campaign?.state != .passed { blockers.append("The latest exact campaign has not passed.") }
            if campaign?.evidenceSealID == nil { blockers.append("The campaign has no evidence seal.") }
            else if campaign?.evidenceSealID.flatMap({ approvedSeals[$0] }) == nil { blockers.append("The evidence seal is not approved.") }
            let state: QualificationPublicationState = approved ? .approved : (campaign?.state == .passed ? .candidate : .blocked)
            return QualificationMatrixEntry(
                id: "\(version)|\(product)|\(profile)|\(campaign?.backendID ?? "unqualified")",
                iosVersion: version, deviceProductType: product, hardwareProfileID: profile,
                backendID: campaign?.backendID ?? "unqualified", backendVersion: campaign?.backendVersion,
                campaignID: campaign?.id, evidenceSealID: campaign?.evidenceSealID,
                state: state, blockers: blockers, evaluatedAt: .now
            )
        }.sorted { ($0.iosVersion, $0.deviceProductType) < ($1.iosVersion, $1.deviceProductType) }
    }

    static func publishApproved(
        _ entries: [QualificationMatrixEntry],
        seals: [EvidenceSeal],
        to url: URL
    ) throws -> PublishedCompatibilityEvidence {
        let approved = entries.filter { $0.state == .approved }
        guard !approved.isEmpty else { throw CocoaError(.validationMissingMandatoryProperty) }
        let sealIDs = Set(approved.compactMap(\.evidenceSealID))
        let approvedSeals = seals.filter { sealIDs.contains($0.id) && $0.reviewState == .approved }
        guard approvedSeals.count == sealIDs.count else { throw CocoaError(.validationMissingMandatoryProperty) }
        let material = try JSONEncoder.sortedISO8601.encode(CompatibilityPublicationMaterial(entries: approved, seals: approvedSeals))
        let publication = PublishedCompatibilityEvidence(
            schemaVersion: 1, generatedAt: .now, entries: approved,
            evidenceSeals: approvedSeals,
            sourceStateSHA256: SHA256.hash(data: material).hexString
        )
        let encoder = JSONEncoder.sortedISO8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(publication).write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        try SecureFilesystem.protectFile(url)
        return publication
    }

    private struct CompatibilityPublicationMaterial: Codable {
        let entries: [QualificationMatrixEntry]
        let seals: [EvidenceSeal]
    }
}

// MARK: - 3. Checksum-pinned runtime adapter host

struct InstalledAdapterRecord: Identifiable, Codable, Hashable, Sendable {
    var id: String { "\(adapterID)@\(version)" }
    let adapterID: String
    let name: String
    let version: String
    let installedAt: Date
    let executablePath: String
    let executableSHA256: String
    let manifestPath: String
    let capabilities: [String]
    var active: Bool
    let replacedVersion: String?
}

struct AdapterRuntimeRequest: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let requestID: UUID
    let operation: String
    let deviceName: String?
    let arguments: [String: String]
}

struct AdapterRuntimeResponse: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let requestID: UUID
    let succeeded: Bool
    let message: String
    let values: [String: String]?
}

struct AdapterInvocationRecord: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let adapterID: String
    let requestID: UUID
    let operation: String
    let startedAt: Date
    let completedAt: Date
    let succeeded: Bool
    let exitCode: Int32
    let timedOut: Bool
    let message: String
}

enum RuntimeAdapterInstaller {
    static func install(manifest: BackendAdapterManifest, paths: LabPaths, existing: [InstalledAdapterRecord]) throws -> InstalledAdapterRecord {
        let conformance = BackendAdapterConformance.evaluate(manifest)
        guard conformance.passed, let sourcePath = manifest.executablePath else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        let source = URL(fileURLWithPath: sourcePath).standardizedFileURL
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              FileManager.default.isExecutableFile(atPath: source.path) else {
            throw CocoaError(.fileReadNoPermission)
        }
        guard !existing.contains(where: { $0.adapterID == manifest.id && $0.version == manifest.version }) else {
            throw CocoaError(.fileWriteFileExists)
        }
        let root = paths.stateRoot.appendingPathComponent("Adapters", isDirectory: true)
            .appendingPathComponent(manifest.id, isDirectory: true)
            .appendingPathComponent(manifest.version, isDirectory: true)
        try SecureFilesystem.prepareDirectory(root)
        let executable = root.appendingPathComponent("adapter", isDirectory: false)
        let manifestURL = root.appendingPathComponent("adapter-manifest.json", isDirectory: false)
        try FileManager.default.copyItem(at: source, to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        var installedManifest = manifest
        installedManifest.executablePath = executable.path
        try HardeningJSON.save(installedManifest, to: manifestURL)
        let previous = existing.first { $0.adapterID == manifest.id && $0.active }
        return InstalledAdapterRecord(
            adapterID: manifest.id, name: manifest.name, version: manifest.version,
            installedAt: .now, executablePath: executable.path,
            executableSHA256: try fileSHA256(executable), manifestPath: manifestURL.path,
            capabilities: manifest.capabilities.sorted(), active: true, replacedVersion: previous?.version
        )
    }
}

enum RuntimeAdapterHost {
    static func invoke(
        adapter: InstalledAdapterRecord,
        request: AdapterRuntimeRequest,
        paths: LabPaths
    ) -> (AdapterRuntimeResponse?, AdapterInvocationRecord) {
        let started = Date()
        let executable = URL(fileURLWithPath: adapter.executablePath)
        guard FileManager.default.isExecutableFile(atPath: executable.path),
              (try? fileSHA256(executable)) == adapter.executableSHA256 else {
            let record = AdapterInvocationRecord(
                id: UUID(), adapterID: adapter.adapterID, requestID: request.requestID,
                operation: request.operation, startedAt: started, completedAt: .now,
                succeeded: false, exitCode: 77, timedOut: false,
                message: "Adapter executable is missing or no longer matches its trusted checksum."
            )
            return (nil, record)
        }
        guard adapter.capabilities.contains(request.operation) else {
            let record = AdapterInvocationRecord(
                id: UUID(), adapterID: adapter.adapterID, requestID: request.requestID,
                operation: request.operation, startedAt: started, completedAt: .now,
                succeeded: false, exitCode: 64, timedOut: false,
                message: "The adapter does not declare operation \(request.operation)."
            )
            return (nil, record)
        }
        let input = (try? JSONEncoder.sortedISO8601.encode(request)) ?? Data()
        let outputRoot = paths.stateRoot.appendingPathComponent("Adapter Output", isDirectory: true)
        try? SecureFilesystem.prepareDirectory(outputRoot)
        let policy = PluginSandboxPolicy.standard
        let sandbox = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        let useSandbox = policy.enabled && FileManager.default.isExecutableFile(atPath: sandbox.path)
        let result = ProcessExecutor.run(
            executable: useSandbox ? sandbox : executable,
            arguments: useSandbox ? ["-p", PluginSandboxProfile.make(executable: executable.path, outputRoot: outputRoot, deviceRoot: nil, policy: policy), executable.path] : [],
            environment: ["VDL_ADAPTER_PROTOCOL": "3", "VDL_OUTPUT_ROOT": outputRoot.path],
            standardInput: input + Data("\n".utf8), timeout: TimeInterval(policy.timeoutSeconds),
            maximumOutputBytes: policy.maximumOutputBytes
        )
        let response = try? JSONDecoder.iso8601.decode(AdapterRuntimeResponse.self, from: Data(result.output.utf8))
        let valid = result.succeeded && response?.requestID == request.requestID && response?.schemaVersion == 1
        let message = response?.message ?? (result.output.isEmpty ? "Adapter returned no valid protocol response." : String(result.output.prefix(512)))
        let record = AdapterInvocationRecord(
            id: UUID(), adapterID: adapter.adapterID, requestID: request.requestID,
            operation: request.operation, startedAt: started, completedAt: .now,
            succeeded: valid && response?.succeeded == true, exitCode: result.exitCode,
            timedOut: result.timedOut, message: message
        )
        return (valid ? response : nil, record)
    }
}

// MARK: - 4. Authenticated guest automation

enum GuestAutomationAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case resetAppData = "reset_app_data"
    case resetPermissions = "reset_permissions"
    case resetKeychain = "reset_keychain"
    case resetNetwork = "reset_network"
    case accessibilityTree = "accessibility_tree"
    case tap = "accessibility_tap"
    case typeText = "accessibility_type_text"
    case waitForElement = "accessibility_wait"
    var id: String { rawValue }
    var mutatesGuest: Bool { self != .accessibilityTree }
}

struct GuestAutomationRequest: Codable, Hashable, Sendable {
    let id: UUID
    let action: GuestAutomationAction
    let bundleIdentifier: String?
    let selector: String?
    let value: String?
    let timeoutSeconds: Int
}

struct GuestAutomationResult: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let requestID: UUID
    let deviceName: String
    let action: GuestAutomationAction
    let startedAt: Date
    let completedAt: Date
    let succeeded: Bool
    let message: String
    let accessibilityRoot: AccessibilityNode?
}

enum GuestAutomationGate {
    static func validate(
        request: GuestAutomationRequest,
        handshake: GuestProtocolHandshake?,
        policy: GuestTrustPolicy
    ) -> [String] {
        guard let handshake else { return ["No guest protocol handshake exists for this device."] }
        let trust = GuestTrustEvaluator.evaluate(handshake, policy: policy)
        var blockers = request.action.mutatesGuest && !trust.trustedForMutation ? trust.reasons : []
        if !request.action.mutatesGuest && !trust.readOnlyAllowed { blockers.append(contentsOf: trust.reasons) }
        let required: GuestCapability = request.action.rawValue.hasPrefix("accessibility_") ? .accessibilityTree : .deterministicReset
        if !handshake.capabilities.contains(required) { blockers.append("The guest does not advertise \(required.rawValue).") }
        if [.resetAppData, .resetPermissions, .resetKeychain].contains(request.action),
           request.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            blockers.append("This reset requires an explicit application bundle identifier.")
        }
        if [.tap, .typeText, .waitForElement].contains(request.action),
           request.selector?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            blockers.append("This accessibility action requires an explicit selector.")
        }
        if request.action == .typeText,
           request.value?.isEmpty != false {
            blockers.append("Typing requires an explicit value.")
        }
        if request.timeoutSeconds <= 0 || request.timeoutSeconds > 120 { blockers.append("Automation timeout must be between 1 and 120 seconds.") }
        if let encoded = try? JSONEncoder().encode(request), encoded.count > handshake.maximumMessageBytes {
            blockers.append("The automation request exceeds the negotiated guest message limit.")
        }
        return Array(Set(blockers)).sorted()
    }
}

// MARK: - 5. Replay validation and execution records

struct ReplayValidationReport: Codable, Hashable, Sendable {
    let generatedAt: Date
    let bundlePath: String
    let manifestID: UUID?
    let passed: Bool
    let checks: [AdapterConformanceCheck]
}

struct ReplayExecutionRecord: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let manifestID: UUID
    let validation: ReplayValidationReport
    let startedAt: Date
    var completedAt: Date?
    var runID: UUID?
    var state: TestRunState
    var message: String
}

enum ReplayValidator {
    static func validate(
        record: FailureReplayBundleRecord,
        devices: [VirtualDevice],
        artifacts: [AppArtifact],
        fixtures: [CanonicalVMFixture],
        environments: [EnvironmentProfile],
        backend: BackendDescriptor
    ) -> (FailureReplayManifest?, ReplayValidationReport) {
        let manifestURL = URL(fileURLWithPath: record.path).appendingPathComponent("replay-manifest.json")
        let actualHash = try? fileSHA256(manifestURL)
        let manifest = try? HardeningJSON.load(FailureReplayManifest.self, from: manifestURL)
        let knownDevices = Set(devices.map(\.name))
        let stopped = devices.filter { manifest?.deviceNames.contains($0.name) == true }.allSatisfy { !$0.isRunning }
        let fixtureIDs = Set(fixtures.map(\.id))
        let environmentIDs = Set(environments.map(\.id))
        let artifact = manifest?.appArtifactID.flatMap { id in artifacts.first { $0.id == id } }
        let artifactHashValid = artifact.map { artifact in
            guard let expected = artifact.sha256 else { return false }
            return FileManager.default.fileExists(atPath: artifact.path)
                && (try? fileSHA256(artifact.url)) == expected
        } ?? (manifest?.appArtifactID == nil)
        let fixturesValid = manifest.map { manifest in
            let selected = fixtures.filter { manifest.fixtureIDs.contains($0.id) }
            guard selected.count == manifest.deviceNames.count else { return false }
            return manifest.deviceNames.allSatisfy { deviceName in
                guard let device = devices.first(where: { $0.name == deviceName }),
                      let fixture = selected.first(where: { $0.deviceName == deviceName }) else { return false }
                return fixture.deviceProductType == device.restoreInfo?.device
                    && fixture.hardwareProfileID == device.hardwareProfileID
                    && fixture.backendID == backend.id
            }
        } ?? false
        let checks = [
            AdapterConformanceCheck(id: "manifest", passed: manifest?.schemaVersion == 1 && manifest?.id == record.id, evidence: "Replay manifest schema and identity must match the catalog record."),
            AdapterConformanceCheck(id: "hash", passed: actualHash == record.manifestSHA256, evidence: actualHash == record.manifestSHA256 ? "Manifest SHA-256 matches." : "Manifest SHA-256 changed after bundling."),
            AdapterConformanceCheck(id: "devices", passed: manifest.map { Set($0.deviceNames).isSubset(of: knownDevices) && !$0.deviceNames.isEmpty } == true, evidence: "Every replay device must exist locally."),
            AdapterConformanceCheck(id: "stopped", passed: stopped, evidence: stopped ? "Replay devices are stopped." : "Stop every replay device before execution."),
            AdapterConformanceCheck(id: "fixtures", passed: fixturesValid && manifest.map { Set($0.fixtureIDs).isSubset(of: fixtureIDs) } == true, evidence: "Every device requires its exact canonical fixture, product type, hardware profile, and backend."),
            AdapterConformanceCheck(id: "environments", passed: manifest.map { Set($0.environmentAssignments.values).isSubset(of: environmentIDs) } == true, evidence: "All referenced environment profiles must exist."),
            AdapterConformanceCheck(id: "artifact", passed: artifactHashValid, evidence: artifactHashValid ? "Application artifact identity is available." : "The pinned application artifact is missing or changed."),
            AdapterConformanceCheck(id: "backend", passed: manifest.map { $0.labfile?.backendID == nil || $0.labfile?.backendID == backend.id } ?? false, evidence: "Labfile backend must match \(backend.id)."),
        ]
        let report = ReplayValidationReport(
            generatedAt: .now, bundlePath: record.path, manifestID: manifest?.id,
            passed: !checks.isEmpty && checks.allSatisfy(\.passed), checks: checks
        )
        return (manifest, report)
    }
}

// MARK: - 6. UUID-verified crash symbolication

struct SymbolicatedFrame: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let address: String
    let symbol: String
}

struct SymbolicationReport: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let generatedAt: Date
    let crashPath: String
    let dSYMPath: String
    let crashUUID: String?
    let matchedBuildID: UUID?
    let matchedExecutableUUID: String?
    let frames: [SymbolicatedFrame]
    let fingerprint: String?
    let succeeded: Bool
    let blockers: [String]
}

enum CrashSymbolicator {
    static func symbolicate(crash: URL, dSYM: URL, builds: [BuildIdentityRecord]) -> SymbolicationReport {
        let text = (try? String(contentsOf: crash, encoding: .utf8)) ?? ""
        let crashUUID = firstMatch(in: text, pattern: "(?i)(?:uuid|slice_uuid)[\\\"' :=]+([0-9a-f-]{32,36})")?.uppercased()
        let addresses = matches(in: text, pattern: "0x[0-9a-fA-F]{6,16}").uniqued().prefix(128)
        let dwarfs = dwarfExecutables(in: dSYM)
        var matchedDwarf: URL?
        var matchedUUID: String?
        for dwarf in dwarfs {
            let output = ProcessExecutor.run(
                executable: URL(fileURLWithPath: "/usr/bin/dwarfdump"),
                arguments: ["--uuid", dwarf.path], timeout: 30, maximumOutputBytes: 256 * 1_024
            ).output
            let uuids = matches(in: output, pattern: "(?i)UUID: ([0-9a-f-]{36})").map { $0.uppercased() }
            if let crashUUID, uuids.contains(crashUUID) {
                matchedDwarf = dwarf
                matchedUUID = crashUUID
                break
            }
        }
        let matchedBuild = builds.first { build in
            guard let matchedUUID else { return false }
            return build.executableUUIDs.map { $0.uppercased() }.contains(matchedUUID)
                && build.dSYMPaths.contains { URL(fileURLWithPath: $0).standardizedFileURL == dSYM.standardizedFileURL }
        }
        var blockers: [String] = []
        if text.isEmpty { blockers.append("The crash report is empty or unreadable.") }
        if crashUUID == nil { blockers.append("No executable UUID was found in the crash report.") }
        if matchedDwarf == nil { blockers.append("The dSYM does not contain the crash UUID.") }
        if matchedBuild == nil { blockers.append("The UUID-matched dSYM is not indexed in the build catalog.") }
        if addresses.isEmpty { blockers.append("No instruction addresses were found in the crash report.") }
        var frames: [SymbolicatedFrame] = []
        if blockers.isEmpty, let dwarf = matchedDwarf {
            let loadAddress = firstMatch(in: text, pattern: "(?i)(0x[0-9a-f]+)[-–]0x[0-9a-f]+.*\\b" + NSRegularExpression.escapedPattern(for: dwarf.lastPathComponent))
            var arguments = ["-arch", "arm64", "-o", dwarf.path]
            if let loadAddress { arguments += ["-l", loadAddress] }
            arguments += addresses
            let result = ProcessExecutor.run(
                executable: URL(fileURLWithPath: "/usr/bin/atos"), arguments: arguments,
                timeout: 30, maximumOutputBytes: 2 * 1_048_576
            )
            let symbols = result.output.components(separatedBy: .newlines).filter { !$0.isEmpty }
            frames = zip(addresses, symbols).map {
                SymbolicatedFrame(id: UUID(), address: $0.0, symbol: $0.1)
            }
            if !result.succeeded || frames.isEmpty { blockers.append("atos did not produce symbolicated frames.") }
        }
        let fingerprintMaterial = frames.prefix(5).map(\.symbol).joined(separator: "|")
            + "|" + (firstMatch(in: text, pattern: "(?im)^(?:Exception Type|exception)[ :=]+(.+)$") ?? "unknown")
        let fingerprint = frames.isEmpty ? nil : SHA256.hash(data: Data(fingerprintMaterial.utf8)).hexString
        return SymbolicationReport(
            id: UUID(), generatedAt: .now, crashPath: crash.path, dSYMPath: dSYM.path,
            crashUUID: crashUUID, matchedBuildID: matchedBuild?.id,
            matchedExecutableUUID: matchedUUID, frames: frames, fingerprint: fingerprint,
            succeeded: blockers.isEmpty && !frames.isEmpty, blockers: blockers
        )
    }

    private static func dwarfExecutables(in dSYM: URL) -> [URL] {
        let root = dSYM.appendingPathComponent("Contents/Resources/DWARF", isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )) ?? []).filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        matches(in: text, pattern: pattern).first
    }

    private static func matches(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            let range = match.numberOfRanges > 1 ? match.range(at: 1) : match.range
            guard let swiftRange = Range(range, in: text) else { return nil }
            return String(text[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

// MARK: - 7. Fleet leases, heartbeats, and dispatch audit

enum FleetLeaseState: String, Codable, Sendable { case active, released, expired, cancelled }

struct FleetHeartbeat: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let hostID: UUID
    let receivedAt: Date
    let runningJobs: Int
    let availableMemoryMB: Int
    let activeKeyID: String?
}

struct FleetLease: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let hostID: UUID
    let jobName: String
    let createdAt: Date
    let expiresAt: Date
    var state: FleetLeaseState
    let requiredCapabilities: [String]
    let reservedMemoryMB: Int
}

struct FleetDispatchRecord: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let leaseID: UUID
    let hostID: UUID
    let submittedAt: Date
    let authenticated: Bool
    let queuePath: String?
    let jobID: UUID?
    let message: String
}

enum FleetControlPlane {
    static func heartbeat(host: FleetHostRecord, activeKeyID: String?) -> FleetHeartbeat {
        FleetHeartbeat(
            id: UUID(), hostID: host.id, receivedAt: .now,
            runningJobs: host.runningVMs,
            availableMemoryMB: max(0, host.memoryMB), activeKeyID: activeKeyID
        )
    }

    static func acquire(
        request: FleetJobRequest,
        hosts: [FleetHostRecord],
        leases: [FleetLease],
        durationSeconds: Int = 900
    ) -> (FleetPlacementDecision, FleetLease?) {
        let now = Date()
        let activeByHost = Dictionary(grouping: leases.filter { $0.state == .active && $0.expiresAt > now }, by: \.hostID)
        let adjusted = hosts.map { host -> FleetHostRecord in
            var copy = host
            copy.runningVMs += activeByHost[host.id]?.count ?? 0
            if now.timeIntervalSince(host.lastSeen) > 90 { copy.state = .offline }
            return copy
        }
        let placement = FleetScheduler.place(request, on: adjusted)
        guard let hostID = placement.hostID else { return (placement, nil) }
        let lease = FleetLease(
            id: UUID(), hostID: hostID, jobName: request.name, createdAt: now,
            expiresAt: now.addingTimeInterval(TimeInterval(max(60, min(86_400, durationSeconds)))),
            state: .active, requiredCapabilities: request.requiredCapabilities.sorted(),
            reservedMemoryMB: request.requiredMemoryMB
        )
        return (placement, lease)
    }

    static func expire(_ leases: [FleetLease], now: Date = .now) -> [FleetLease] {
        leases.map { lease in
            guard lease.state == .active, lease.expiresAt <= now else { return lease }
            var expired = lease
            expired.state = .expired
            return expired
        }
    }
}

// MARK: - 8. Monotonic, source-aware timelines

enum HighFidelitySource: String, Codable, CaseIterable, Sendable {
    case hostLogs, guestLogs, screenshots, video, audio, network, performance
}

struct ClockCalibrationSample: Codable, Hashable, Sendable {
    let wallClock: Date
    let monotonicNanoseconds: UInt64
    let guestOffsetNanoseconds: Int64?
    let uncertaintyNanoseconds: UInt64?
}

struct HighFidelityTimelineEvent: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let monotonicNanoseconds: UInt64
    let wallClock: Date
    let source: HighFidelitySource
    let deviceName: String?
    let summary: String
    let artifactPath: String?
}

struct HighFidelityTimelineSession: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let runID: UUID
    let capturedAt: Date
    let calibration: ClockCalibrationSample
    let events: [HighFidelityTimelineEvent]
    let unavailableSources: [HighFidelitySource: String]
    let artifactPath: String?
}

enum HighFidelityTimelineBuilder {
    static func capture(
        run: TestRunRecord,
        logs: [LogEntry],
        performance: [String: PerformanceSample],
        availableSources: Set<HighFidelitySource>,
        paths: LabPaths
    ) throws -> HighFidelityTimelineSession {
        let now = Date()
        let monotonic = DispatchTime.now().uptimeNanoseconds
        let calibration = ClockCalibrationSample(
            wallClock: now, monotonicNanoseconds: monotonic,
            guestOffsetNanoseconds: nil, uncertaintyNanoseconds: nil
        )
        func monotonicTime(for date: Date) -> UInt64 {
            let delta = Int64(date.timeIntervalSince(now) * 1_000_000_000)
            if delta >= 0 { return monotonic &+ UInt64(delta) }
            let magnitude = UInt64(-delta)
            return monotonic >= magnitude ? monotonic - magnitude : 0
        }
        var events = logs.filter { $0.timestamp >= run.createdAt && $0.timestamp <= (run.completedAt ?? now) }.map {
            HighFidelityTimelineEvent(
                id: UUID(), monotonicNanoseconds: monotonicTime(for: $0.timestamp), wallClock: $0.timestamp,
                source: .hostLogs, deviceName: $0.scope, summary: $0.message, artifactPath: nil
            )
        }
        events += performance.values.filter { $0.timestamp >= run.createdAt && $0.timestamp <= (run.completedAt ?? now) }.map {
            HighFidelityTimelineEvent(
                id: UUID(), monotonicNanoseconds: monotonicTime(for: $0.timestamp), wallClock: $0.timestamp,
                source: .performance, deviceName: $0.deviceName,
                summary: "CPU \($0.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "—") • RAM \($0.residentMemoryBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .memory) } ?? "—")",
                artifactPath: nil
            )
        }
        for result in run.results {
            if let screenshot = result.screenshotPath {
                let date = result.completedAt ?? result.startedAt
                events.append(.init(id: UUID(), monotonicNanoseconds: monotonicTime(for: date), wallClock: date,
                                    source: .screenshots, deviceName: result.deviceName,
                                    summary: "Screenshot captured", artifactPath: screenshot))
            }
        }
        let unavailable = Dictionary(uniqueKeysWithValues: HighFidelitySource.allCases.compactMap { source in
            availableSources.contains(source) ? nil : (source, "The active backend did not advertise \(source.rawValue) capture.")
        })
        let root = paths.stateRoot.appendingPathComponent("High Fidelity Timelines", isDirectory: true)
        try SecureFilesystem.prepareDirectory(root)
        let url = root.appendingPathComponent("\(run.id.uuidString)-\(Int(now.timeIntervalSince1970)).json")
        var session = HighFidelityTimelineSession(
            id: UUID(), runID: run.id, capturedAt: now, calibration: calibration,
            events: events.sorted { $0.monotonicNanoseconds < $1.monotonicNanoseconds },
            unavailableSources: unavailable, artifactPath: url.path
        )
        try HardeningJSON.save(session, to: url)
        session = try HardeningJSON.load(HighFidelityTimelineSession.self, from: url)
        return session
    }
}

// MARK: - 9. Machine-readable coverage evidence

struct SourceCoverageRecord: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let importedAt: Date
    let sourceRevision: String?
    let producer: String
    let sourcePath: String
    let sourceSHA256: String
    let linePercent: Double
    let functionPercent: Double?
    let regionPercent: Double?
}

enum SourceCoverageImporter {
    static func importReport(_ url: URL, sourceRevision: String? = nil) throws -> SourceCoverageRecord {
        let size = (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0, size <= 64 * 1_024 * 1_024 else { throw CocoaError(.fileReadTooLarge) }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard let root = object as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
        let producer: String
        let line: Double
        let function: Double?
        let region: Double?
        if let data = root["data"] as? [[String: Any]],
           let totals = data.first?["totals"] as? [String: Any],
           let lines = totals["lines"] as? [String: Any],
           let percent = number(lines["percent"]) {
            producer = "llvm-cov"
            line = percent
            function = (totals["functions"] as? [String: Any]).flatMap { number($0["percent"]) }
            region = (totals["regions"] as? [String: Any]).flatMap { number($0["percent"]) }
        } else if let covered = number(root["lineCoverage"]) ?? number(root["coverage"]) {
            producer = "xccov"
            line = covered <= 1 ? covered * 100 : covered
            function = nil
            region = nil
        } else {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard line.isFinite, (0...100).contains(line) else { throw CocoaError(.fileReadCorruptFile) }
        return SourceCoverageRecord(
            id: UUID(), importedAt: .now,
            sourceRevision: sourceRevision.flatMap { $0.isEmpty ? nil : $0 },
            producer: producer, sourcePath: url.path, sourceSHA256: try fileSHA256(url),
            linePercent: line, functionPercent: function, regionPercent: region
        )
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)
    }
}

// MARK: - 10. Hybrid virtual and physical execution targets

enum ExecutionTargetKind: String, Codable, CaseIterable, Sendable { case virtual, physical }

struct ExecutionTargetRecord: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let kind: ExecutionTargetKind
    let name: String
    let productType: String?
    let osVersion: String?
    let available: Bool
    let authorized: Bool
    let capabilities: [String]
    let source: String
}

struct HybridRouteRequest: Codable, Hashable, Sendable {
    let iosMajor: Int?
    let requiredCapabilities: [String]
    let preferPhysical: Bool
}

struct HybridRouteDecision: Codable, Hashable, Sendable {
    let generatedAt: Date
    let request: HybridRouteRequest
    let target: ExecutionTargetRecord?
    let blockers: [String]
    var routed: Bool { target != nil && blockers.isEmpty }
    static let empty = HybridRouteDecision(
        generatedAt: .distantPast,
        request: HybridRouteRequest(iosMajor: nil, requiredCapabilities: [], preferPhysical: false),
        target: nil, blockers: ["No route has been requested."]
    )
}

struct PhysicalDeploymentRecord: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let targetID: String
    let targetName: String
    let appPath: String
    let bundleIdentifier: String?
    let startedAt: Date
    let completedAt: Date
    let installed: Bool
    let launched: Bool
    let message: String
}

enum PhysicalDeviceService {
    static func installAndLaunch(app: URL, on target: ExecutionTargetRecord) -> PhysicalDeploymentRecord {
        let started = Date()
        func record(installed: Bool, launched: Bool, _ message: String, bundleID: String? = nil) -> PhysicalDeploymentRecord {
            PhysicalDeploymentRecord(
                id: UUID(), targetID: target.id, targetName: target.name, appPath: app.path,
                bundleIdentifier: bundleID, startedAt: started, completedAt: .now,
                installed: installed, launched: launched, message: message
            )
        }
        guard target.kind == .physical, target.available, target.authorized else {
            return record(installed: false, launched: false, "The selected physical target is not available and authorized.")
        }
        guard target.id.count <= 256,
              !target.id.hasPrefix("-"),
              target.id.range(of: "^[A-Za-z0-9._:,-]+$", options: .regularExpression) != nil else {
            return record(installed: false, launched: false, "The physical target identifier is invalid.")
        }
        guard app.pathExtension.lowercased() == "app",
              FileManager.default.fileExists(atPath: app.path) else {
            return record(installed: false, launched: false, "Physical deployment requires an expanded .app bundle.")
        }
        let infoURL = app.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bundleID = plist["CFBundleIdentifier"] as? String, !bundleID.isEmpty else {
            return record(installed: false, launched: false, "The app bundle has no readable CFBundleIdentifier.")
        }
        let signing = ProcessExecutor.run(
            executable: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["--verify", "--deep", "--strict", app.path],
            timeout: 60, maximumOutputBytes: 1_048_576
        )
        guard signing.succeeded else {
            return record(installed: false, launched: false, "Code-signing verification failed: \(String(signing.output.prefix(512)))", bundleID: bundleID)
        }
        let installOutput = FileManager.default.temporaryDirectory.appendingPathComponent("vdl-install-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: installOutput) }
        let install = ProcessExecutor.run(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["devicectl", "device", "install", "app", "--device", target.id, app.path,
                        "--timeout", "120", "--json-output", installOutput.path],
            timeout: 150, maximumOutputBytes: 2 * 1_048_576
        )
        guard install.succeeded else {
            return record(installed: false, launched: false, "CoreDevice install failed: \(String(install.output.prefix(512)))", bundleID: bundleID)
        }
        let launchOutput = FileManager.default.temporaryDirectory.appendingPathComponent("vdl-launch-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: launchOutput) }
        let launch = ProcessExecutor.run(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["devicectl", "device", "process", "launch", "--device", target.id,
                        "--terminate-existing", bundleID, "--timeout", "60", "--json-output", launchOutput.path],
            timeout: 90, maximumOutputBytes: 2 * 1_048_576
        )
        return record(
            installed: true, launched: launch.succeeded,
            launch.succeeded ? "Installed and launched \(bundleID) through CoreDevice." : "Installed \(bundleID), but launch failed: \(String(launch.output.prefix(512)))",
            bundleID: bundleID
        )
    }
}

enum PhysicalDeviceDiscovery {
    static func discover() -> [ExecutionTargetRecord] {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun") else { return [] }
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vdl-devicectl-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let result = ProcessExecutor.run(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["devicectl", "list", "devices", "--timeout", "10", "--json-output", outputURL.path],
            timeout: 15, maximumOutputBytes: 512 * 1_024
        )
        guard result.succeeded,
              let object = try? JSONSerialization.jsonObject(with: Data(contentsOf: outputURL)) else { return [] }
        let candidates = dictionaries(in: object).filter { dictionary in
            dictionary["identifier"] != nil && (dictionary["name"] != nil || dictionary["deviceProperties"] != nil)
        }
        var seen = Set<String>()
        return candidates.compactMap { dictionary in
            let properties = dictionary["deviceProperties"] as? [String: Any] ?? [:]
            let hardware = dictionary["hardwareProperties"] as? [String: Any] ?? [:]
            guard let identifier = string(dictionary["identifier"] ?? properties["identifier"]), seen.insert(identifier).inserted else { return nil }
            let name = string(dictionary["name"] ?? properties["name"]) ?? "Physical iOS device"
            let version = string(properties["osVersionNumber"] ?? dictionary["osVersionNumber"])
            let product = string(hardware["productType"] ?? dictionary["productType"])
            let connection = dictionary["connectionProperties"] as? [String: Any] ?? [:]
            let state = (string(connection["tunnelState"] ?? dictionary["connectionState"] ?? properties["connectionState"]) ?? "").lowercased()
            let pairing = (string(connection["pairingState"] ?? dictionary["pairingState"]) ?? "").lowercased()
            let developerMode = (string(properties["developerModeStatus"] ?? dictionary["developerModeStatus"]) ?? "").lowercased()
            let available = state == "connected" || properties["ddiServicesAvailable"] as? Bool == true
            let authorized = pairing == "paired" && developerMode == "enabled"
            return ExecutionTargetRecord(
                id: identifier, kind: .physical, name: name, productType: product,
                osVersion: version, available: available, authorized: authorized,
                capabilities: ["camera", "cellular", "secureEnclave", "biometrics", "bluetooth", "motion", "audio", "networking", "xcodeDeployment"],
                source: "xcrun devicectl/CoreDevice"
            )
        }.sorted { $0.name < $1.name }
    }

    private static func dictionaries(in value: Any) -> [[String: Any]] {
        if let dictionary = value as? [String: Any] {
            return [dictionary] + dictionary.values.flatMap(dictionaries)
        }
        if let array = value as? [Any] { return array.flatMap(dictionaries) }
        return []
    }

    private static func string(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
}

enum HybridTargetRouter {
    static func virtualTargets(_ devices: [VirtualDevice], backendCapabilities: Set<String>) -> [ExecutionTargetRecord] {
        devices.map {
            ExecutionTargetRecord(
                id: $0.id, kind: .virtual, name: $0.name,
                productType: $0.restoreInfo?.device, osVersion: $0.restoreInfo?.ios.version,
                available: !$0.isPaused, authorized: true,
                capabilities: backendCapabilities.sorted(), source: "Virtual-device backend"
            )
        }
    }

    static func route(_ request: HybridRouteRequest, targets: [ExecutionTargetRecord]) -> HybridRouteDecision {
        let required = Set(request.requiredCapabilities)
        let eligible = targets.filter { target in
            target.available && target.authorized && required.isSubset(of: Set(target.capabilities))
                && request.iosMajor.map { major in
                    target.osVersion.flatMap { Int($0.split(separator: ".").first ?? "") } == major
                } != false
        }.sorted { left, right in
            if left.kind != right.kind {
                return request.preferPhysical ? left.kind == .physical : left.kind == .virtual
            }
            return left.name < right.name
        }
        guard let target = eligible.first else {
            return HybridRouteDecision(
                generatedAt: .now, request: request, target: nil,
                blockers: ["No available and authorized target satisfies the requested iOS version and capabilities."]
            )
        }
        return HybridRouteDecision(generatedAt: .now, request: request, target: target, blockers: [])
    }
}

// MARK: - Persisted 0.11 expansion state

struct LabExpansionState: Codable, Hashable, Sendable {
    var schemaVersion: Int
    var maturity: [CapabilityMaturityRecord]
    var qualificationMatrix: [QualificationMatrixEntry]
    var installedAdapters: [InstalledAdapterRecord]
    var adapterInvocations: [AdapterInvocationRecord]
    var guestAutomationResults: [GuestAutomationResult]
    var replayExecutions: [ReplayExecutionRecord]
    var symbolicationReports: [SymbolicationReport]
    var fleetHeartbeats: [FleetHeartbeat]
    var fleetLeases: [FleetLease]
    var fleetDispatches: [FleetDispatchRecord]
    var highFidelityTimelines: [HighFidelityTimelineSession]
    var coverageReports: [SourceCoverageRecord]
    var physicalDevices: [ExecutionTargetRecord]
    var physicalDeployments: [PhysicalDeploymentRecord]
    var hybridRoute: HybridRouteDecision

    static let empty = LabExpansionState(
        schemaVersion: 1, maturity: [], qualificationMatrix: [], installedAdapters: [],
        adapterInvocations: [], guestAutomationResults: [], replayExecutions: [],
        symbolicationReports: [], fleetHeartbeats: [], fleetLeases: [], fleetDispatches: [],
        highFidelityTimelines: [], coverageReports: [], physicalDevices: [],
        physicalDeployments: [], hybridRoute: .empty
    )
}

enum LabExpansionStore {
    static func url(paths: LabPaths) -> URL { paths.stateRoot.appendingPathComponent("lab-expansion.json") }

    static func load(paths: LabPaths) -> LabExpansionState {
        let source = url(paths: paths)
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= 32 * 1_024 * 1_024,
              var state = try? HardeningJSON.load(LabExpansionState.self, from: source),
              state.schemaVersion == 1 else { return .empty }
        state.maturity = Array(state.maturity.prefix(100))
        state.qualificationMatrix = Array(state.qualificationMatrix.prefix(1_000))
        state.installedAdapters = Array(state.installedAdapters.prefix(100))
        state.adapterInvocations = Array(state.adapterInvocations.prefix(1_000))
        state.guestAutomationResults = Array(state.guestAutomationResults.prefix(1_000))
        state.replayExecutions = Array(state.replayExecutions.prefix(250))
        state.symbolicationReports = Array(state.symbolicationReports.prefix(500))
        state.fleetHeartbeats = Array(state.fleetHeartbeats.prefix(1_000))
        state.fleetLeases = Array(state.fleetLeases.prefix(1_000))
        state.fleetDispatches = Array(state.fleetDispatches.prefix(1_000))
        state.highFidelityTimelines = Array(state.highFidelityTimelines.prefix(100))
        state.coverageReports = Array(state.coverageReports.prefix(250))
        state.physicalDevices = Array(state.physicalDevices.prefix(100))
        state.physicalDeployments = Array(state.physicalDeployments.prefix(250))
        return state
    }

    static func save(_ state: LabExpansionState, paths: LabPaths) throws {
        try HardeningJSON.save(state, to: url(paths: paths))
    }
}

private extension JSONEncoder {
    static var sortedISO8601: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension Digest {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

private extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
