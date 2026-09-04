import AppKit
import ApplicationServices
import CryptoKit
import Foundation
import Security

// MARK: - v1.1 operations and hardening gates

enum OperationsGateKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case hostSetupContinuation
    case permissionOnboarding
    case fleetWorkerProtocol
    case tamperEvidentAudit
    case evidenceInvalidation
    case liveStorageEncryption
    case startupReconciliation
    case atomicComponentUpgrades
    case supplyChainPolicy
    case supportLifecycle

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hostSetupContinuation: "Guided host setup and reboot continuation"
        case .permissionOnboarding: "Permission onboarding"
        case .fleetWorkerProtocol: "Fleet worker protocol"
        case .tamperEvidentAudit: "Tamper-evident fleet auditing"
        case .evidenceInvalidation: "Transitive evidence invalidation"
        case .liveStorageEncryption: "Live-storage encryption"
        case .startupReconciliation: "Startup reconciliation"
        case .atomicComponentUpgrades: "Atomic component upgrades"
        case .supplyChainPolicy: "Supply-chain policy"
        case .supportLifecycle: "Support and deprecation lifecycle"
        }
    }
}

enum OperationsGateState: String, Codable, Sendable {
    case passed
    case actionRequired
    case blocked
}

struct OperationsGateResult: Identifiable, Codable, Hashable, Sendable {
    let kind: OperationsGateKind
    let state: OperationsGateState
    let evidence: String
    let requiredAction: String
    var id: String { kind.rawValue }
    var passed: Bool { state == .passed }
}

struct OperationsHardeningReport: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let generatedAt: Date
    let gates: [OperationsGateResult]
    var releaseReady: Bool { gates.count == OperationsGateKind.allCases.count && gates.allSatisfy(\.passed) }

    static let empty = OperationsHardeningReport(schemaVersion: 1, generatedAt: .distantPast, gates: [])
}

// MARK: - 1. Guided host setup and reboot continuation

enum HostSetupPhase: String, Codable, CaseIterable, Sendable {
    case notStarted
    case recoveryRequired
    case restartRequired
    case verificationRequired
    case complete
}

struct MacOSInstallation: Identifiable, Codable, Hashable, Sendable {
    let volumeUUID: String
    let name: String
    let mountPoint: String?
    var id: String { volumeUUID }
}

struct HostSetupContinuation: Codable, Hashable, Sendable {
    var phase: HostSetupPhase
    var targetVolumeUUID: String?
    var targetVolumeName: String?
    var originatingBootSessionID: String?
    var lastObservedBootSessionID: String?
    var recoveryCommand: String?
    var verificationCommand: String
    var createdAt: Date?
    var updatedAt: Date
    var verifiedAt: Date?
    var note: String

    static let empty = HostSetupContinuation(
        phase: .notStarted, targetVolumeUUID: nil, targetVolumeName: nil,
        originatingBootSessionID: nil, lastObservedBootSessionID: nil,
        recoveryCommand: nil, verificationCommand: "vdlctl doctor --json",
        createdAt: nil, updatedAt: .distantPast, verifiedAt: nil,
        note: "Choose the exact macOS installation before preparing Recovery steps."
    )
}

enum HostSetupCoordinator {
    static func installations(fromAPFSPlist data: Data) -> [MacOSInstallation] {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let containers = root["Containers"] as? [[String: Any]] else { return [] }
        var result: [MacOSInstallation] = []
        for container in containers {
            guard let volumes = container["Volumes"] as? [[String: Any]] else { continue }
            for volume in volumes {
                guard let roles = volume["Roles"] as? [String], roles.contains("System"),
                      let uuid = volume["APFSVolumeUUID"] as? String,
                      let name = volume["Name"] as? String else { continue }
                result.append(MacOSInstallation(
                    volumeUUID: uuid, name: name, mountPoint: volume["MountPoint"] as? String
                ))
            }
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func discoverInstallations() -> [MacOSInstallation] {
        let result = ProcessExecutor.run(
            executable: URL(fileURLWithPath: "/usr/sbin/diskutil"),
            arguments: ["apfs", "list", "-plist"], timeout: 15
        )
        return installations(fromAPFSPlist: Data(result.output.utf8))
    }

    static func bootSessionID() -> String {
        let result = ProcessExecutor.run(
            executable: URL(fileURLWithPath: "/usr/sbin/sysctl"), arguments: ["-n", "kern.boottime"], timeout: 5
        )
        let source = result.succeeded ? result.output : ProcessInfo.processInfo.operatingSystemVersionString
        return SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func begin(for installation: MacOSInstallation, bootSessionID: String = bootSessionID()) -> HostSetupContinuation {
        return HostSetupContinuation(
            phase: .recoveryRequired,
            targetVolumeUUID: installation.volumeUUID,
            targetVolumeName: installation.name,
            originatingBootSessionID: bootSessionID,
            lastObservedBootSessionID: bootSessionID,
            recoveryCommand: "csrutil enable --without debug\ncsrutil allow-research-guests enable",
            verificationCommand: "vdlctl doctor --json",
            createdAt: .now, updatedAt: .now, verifiedAt: nil,
            note: "Restart into macOS Recovery for \(installation.name) (\(installation.volumeUUID)), confirm that exact installation when prompted, run the displayed commands, then restart normally."
        )
    }

    static func markRecoveryApplied(_ record: HostSetupContinuation) -> HostSetupContinuation {
        var next = record
        guard record.phase == .recoveryRequired else { return next }
        next.phase = .restartRequired
        next.updatedAt = .now
        next.note = "Recovery was acknowledged. Restart into the selected macOS installation to continue verification."
        return next
    }

    static func reconcile(_ record: HostSetupContinuation, currentBootSessionID: String = bootSessionID()) -> HostSetupContinuation {
        var next = record
        next.lastObservedBootSessionID = currentBootSessionID
        next.updatedAt = .now
        if record.phase == .restartRequired,
           let origin = record.originatingBootSessionID, origin != currentBootSessionID {
            next.phase = .verificationRequired
            next.note = "A new boot session was detected. Run host verification to complete setup."
        }
        return next
    }

    static func verify(_ record: HostSetupContinuation, hostReady: Bool) -> HostSetupContinuation {
        var next = reconcile(record)
        if hostReady {
            next.phase = .complete
            next.verifiedAt = .now
            next.note = "Host policy and backend preflight passed after restart."
        } else {
            next.phase = .verificationRequired
            next.note = "Host preflight is still blocked. Review the selected installation and Recovery policy."
        }
        next.updatedAt = .now
        return next
    }
}

// MARK: - 2. Permission onboarding

enum LabPermissionKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case removableVolume
    case accessibility
    case keychain
    case localNetwork
    var id: String { rawValue }

    var title: String {
        switch self {
        case .removableVolume: "Removable volume"
        case .accessibility: "Accessibility"
        case .keychain: "Keychain"
        case .localNetwork: "Local network"
        }
    }
}

struct PermissionCheck: Identifiable, Codable, Hashable, Sendable {
    let kind: LabPermissionKind
    let required: Bool
    let granted: Bool
    let rationale: String
    let settingsURL: String?
    var id: String { kind.rawValue }
    var passed: Bool { !required || granted }
}

struct PermissionOnboardingReport: Codable, Hashable, Sendable {
    let generatedAt: Date
    let checks: [PermissionCheck]
    var passed: Bool { !checks.isEmpty && checks.allSatisfy(\.passed) }
    static let empty = PermissionOnboardingReport(generatedAt: .distantPast, checks: [])
}

enum PermissionOnboardingInspector {
    static func inspect(paths: LabPaths, fleetEnabled: Bool) -> PermissionOnboardingReport {
        let storageGranted = FileManager.default.isReadableFile(atPath: paths.dataRoot.path)
            && FileManager.default.isWritableFile(atPath: paths.dataRoot.path)
        let accessibilityGranted = AXIsProcessTrusted()
        let keychainStatus = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "dev.elliotwilliams.ios-virtual-device-lab.permission-probe",
            kSecReturnData: false,
            kSecMatchLimit: kSecMatchLimitOne,
        ] as CFDictionary, nil)
        let keychainGranted = keychainStatus == errSecSuccess || keychainStatus == errSecItemNotFound
        let localNetworkConfigured = !fleetEnabled || fleetConfigurationExists(paths: paths)
        return PermissionOnboardingReport(generatedAt: .now, checks: [
            PermissionCheck(
                kind: .removableVolume, required: true, granted: storageGranted,
                rationale: "Read and write VM disks, firmware, snapshots, and evidence on the selected lab volume.",
                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders"
            ),
            PermissionCheck(
                kind: .accessibility, required: true, granted: accessibilityGranted,
                rationale: "Drive the desktop UI smoke suite and accessibility-based recovery checks.",
                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            ),
            PermissionCheck(
                kind: .keychain, required: true, granted: keychainGranted,
                rationale: "Protect guest-control secrets and mTLS fleet identities.", settingsURL: nil
            ),
            PermissionCheck(
                kind: .localNetwork, required: fleetEnabled, granted: localNetworkConfigured,
                rationale: "Accept mutually authenticated worker traffic when fleet mode is enabled.",
                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork"
            ),
        ])
    }

    private static func fleetConfigurationExists(paths: LabPaths) -> Bool {
        ["fleet-server-policy.json", "remote-agent.json"].contains {
            FileManager.default.fileExists(atPath: paths.stateRoot.appendingPathComponent($0).path)
        }
    }
}

// MARK: - 3. Fleet worker protocol

enum FleetWorkerCapability: String, Codable, CaseIterable, Identifiable, Sendable {
    case enroll
    case heartbeat
    case submit
    case claim
    case progress
    case result
    case query
    case cancel
    var id: String { rawValue }
}

struct FleetWorkerProtocolEvidence: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let generatedAt: Date
    let serverVersion: String
    let controllerHostID: String
    let workerHostIDs: [String]
    let capabilities: Set<FleetWorkerCapability>
    let mutuallyAuthenticated: Bool
    let idempotencyVerified: Bool
    let cancellationVerified: Bool
    let boundedPayloadsVerified: Bool
    let passed: Bool
    let sourceSHA256: String?

    static let unavailable = FleetWorkerProtocolEvidence(
        schemaVersion: 1, generatedAt: .distantPast, serverVersion: "unavailable",
        controllerHostID: "", workerHostIDs: [], capabilities: [], mutuallyAuthenticated: false,
        idempotencyVerified: false, cancellationVerified: false, boundedPayloadsVerified: false,
        passed: false, sourceSHA256: nil
    )
}

enum FleetWorkerProtocolEvaluator {
    static func validate(_ evidence: FleetWorkerProtocolEvidence, now: Date = .now) -> [String] {
        var issues: [String] = []
        guard evidence.schemaVersion == 1 else { return ["Unsupported fleet evidence schema."] }
        let required = Set(FleetWorkerCapability.allCases)
        if !required.isSubset(of: evidence.capabilities) { issues.append("Not every worker lifecycle operation was exercised.") }
        if !evidence.mutuallyAuthenticated { issues.append("Mutual TLS was not verified.") }
        if !evidence.idempotencyVerified { issues.append("Idempotent retries were not verified.") }
        if !evidence.cancellationVerified { issues.append("Cancellation propagation was not verified.") }
        if !evidence.boundedPayloadsVerified { issues.append("Request and result size bounds were not verified.") }
        if !evidence.serverVersion.hasPrefix("1.1.") { issues.append("Fleet server 1.1 evidence is required.") }
        if evidence.sourceSHA256?.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) == nil {
            issues.append("Fleet evidence must pin the qualification source revision or report digest.")
        }
        if Set(evidence.workerHostIDs + [evidence.controllerHostID]).filter({ !$0.isEmpty }).count < 2 {
            issues.append("Evidence must contain at least two distinct hosts.")
        }
        if abs(evidence.generatedAt.timeIntervalSince(now)) > 90 * 86_400 { issues.append("Fleet evidence is older than 90 days.") }
        if !evidence.passed { issues.append("The fleet exercise did not pass.") }
        return issues
    }
}

// MARK: - 4. Tamper-evident fleet auditing

struct FleetAuditEnvelope: Codable, Hashable, Sendable {
    let sequence: UInt64
    let previousHash: String
    let recordHash: String
    let signature: String?
    let signingCertificateSHA256: String?
    let canonicalRecord: String
}

struct FleetAuditVerification: Codable, Hashable, Sendable {
    let verifiedAt: Date
    let recordCount: Int
    let chainValid: Bool
    let signaturesPresent: Bool
    let signatureValid: Bool
    let finalHash: String?
    let issues: [String]
    var passed: Bool { recordCount > 0 && chainValid && signaturesPresent && signatureValid && issues.isEmpty }

    static let unavailable = FleetAuditVerification(
        verifiedAt: .distantPast, recordCount: 0, chainValid: false,
        signaturesPresent: false, signatureValid: false, finalHash: nil,
        issues: ["No fleet audit ledger has been verified."]
    )
}

enum FleetAuditVerifier {
    static func verify(lines: [String], verifySignature: (FleetAuditEnvelope) -> Bool) -> FleetAuditVerification {
        var previous = String(repeating: "0", count: 64)
        var expectedSequence: UInt64 = 1
        var chainValid = true
        var signaturesPresent = true
        var signatureValid = true
        var issues: [String] = []
        let decoder = JSONDecoder()
        var count = 0
        for line in lines where !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let data = line.data(using: .utf8),
                  let envelope = try? decoder.decode(FleetAuditEnvelope.self, from: data) else {
                chainValid = false
                issues.append("Audit line \(count + 1) is not a valid envelope.")
                break
            }
            count += 1
            let digest = SHA256.hash(data: Data(("\(envelope.sequence)\n\(envelope.previousHash)\n\(envelope.canonicalRecord)").utf8))
                .map { String(format: "%02x", $0) }.joined()
            if envelope.sequence != expectedSequence || envelope.previousHash != previous || envelope.recordHash != digest {
                chainValid = false
                issues.append("Hash-chain verification failed at sequence \(envelope.sequence).")
            }
            if envelope.signature == nil || envelope.signingCertificateSHA256 == nil { signaturesPresent = false }
            if !verifySignature(envelope) { signatureValid = false }
            previous = envelope.recordHash
            expectedSequence += 1
        }
        if count == 0 { issues.append("The audit ledger is empty.") }
        if !signaturesPresent { issues.append("One or more audit records is unsigned.") }
        if !signatureValid { issues.append("One or more audit signatures failed verification.") }
        return FleetAuditVerification(
            verifiedAt: .now, recordCount: count, chainValid: chainValid,
            signaturesPresent: signaturesPresent, signatureValid: signatureValid,
            finalHash: count > 0 ? previous : nil, issues: issues
        )
    }

    static func verify(url: URL, certificate: SecCertificate?) throws -> FleetAuditVerification {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= 128 * 1_024 * 1_024 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines)
        let expectedFingerprint = certificate.map {
            SHA256.hash(data: SecCertificateCopyData($0) as Data)
                .map { String(format: "%02x", $0) }.joined()
        }
        return verify(lines: lines) { envelope in
            guard let certificate,
                  envelope.signingCertificateSHA256?.caseInsensitiveCompare(expectedFingerprint ?? "") == .orderedSame,
                  let publicKey = SecCertificateCopyKey(certificate),
                  let encodedSignature = envelope.signature,
                  let signature = Data(base64Encoded: encodedSignature) else { return false }
            let digest = Data(hexadecimal: envelope.recordHash) ?? Data()
            let algorithm: SecKeyAlgorithm = SecKeyIsAlgorithmSupported(publicKey, .verify, .ecdsaSignatureDigestX962SHA256)
                ? .ecdsaSignatureDigestX962SHA256 : .rsaSignatureDigestPKCS1v15SHA256
            return SecKeyVerifySignature(publicKey, algorithm, digest as CFData, signature as CFData, nil)
        }
    }
}

// MARK: - 5. Transitive evidence invalidation

enum EvidenceDependency: String, Codable, CaseIterable, Hashable, Sendable {
    case appBuild
    case backendBuild
    case guestCompanion
    case compatibilityManifest
    case hardwareProfiles
    case supplyChainManifest
    case hostPolicy
    case acceptance
    case qualification
    case automation
    case performance
    case releaseDecision
}

struct EvidenceDependencySnapshot: Codable, Hashable, Sendable {
    let capturedAt: Date
    let values: [EvidenceDependency: String]
}

struct EvidenceInvalidationRecord: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let detectedAt: Date
    let changedRoots: [EvidenceDependency]
    let invalidatedEvidence: [EvidenceDependency]
    let acknowledgedAt: Date?
    var resolved: Bool { acknowledgedAt != nil }
}

enum EvidenceInvalidationEngine {
    private static let edges: [EvidenceDependency: Set<EvidenceDependency>] = [
        .appBuild: [.automation, .performance, .releaseDecision],
        .backendBuild: [.acceptance, .qualification, .automation, .performance, .releaseDecision],
        .guestCompanion: [.acceptance, .qualification, .automation, .releaseDecision],
        .compatibilityManifest: [.qualification, .releaseDecision],
        .hardwareProfiles: [.qualification, .acceptance, .releaseDecision],
        .supplyChainManifest: [.releaseDecision],
        .hostPolicy: [.acceptance, .qualification, .performance, .releaseDecision],
        .acceptance: [.qualification, .automation, .performance, .releaseDecision],
        .qualification: [.releaseDecision], .automation: [.releaseDecision], .performance: [.releaseDecision],
    ]

    static func compare(_ baseline: EvidenceDependencySnapshot, _ current: EvidenceDependencySnapshot) -> EvidenceInvalidationRecord? {
        let changed = EvidenceDependency.allCases.filter { baseline.values[$0] != current.values[$0] }
        guard !changed.isEmpty else { return nil }
        var affected = Set(changed)
        var pending = changed
        while let node = pending.popLast() {
            for dependent in edges[node] ?? [] where affected.insert(dependent).inserted { pending.append(dependent) }
        }
        return EvidenceInvalidationRecord(
            id: UUID(), detectedAt: .now, changedRoots: changed,
            invalidatedEvidence: affected.sorted { $0.rawValue < $1.rawValue }, acknowledgedAt: nil
        )
    }

    static func capture(
        paths: LabPaths, appVersion: String,
        backendVersion: String?, backendExecutable: URL?, guestIdentity: String?
    ) -> EvidenceDependencySnapshot {
        func hash(_ candidates: [URL]) -> String {
            for url in candidates where FileManager.default.fileExists(atPath: url.path) {
                if let data = try? Data(contentsOf: url) {
                    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                }
            }
            return "missing"
        }
        let working = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let resources = Bundle.main.resourceURL
        return EvidenceDependencySnapshot(capturedAt: .now, values: [
            .appBuild: "\(appVersion):\(hash([Bundle.main.executableURL].compactMap { $0 }))",
            .backendBuild: "\(backendVersion ?? "missing"):\(hash([backendExecutable].compactMap { $0 }))",
            .guestCompanion: guestIdentity ?? "missing",
            .compatibilityManifest: hash([resources?.appendingPathComponent("compatibility-manifest.json"), working.appendingPathComponent("Resources/compatibility-manifest.json")].compactMap { $0 }),
            .hardwareProfiles: hash([resources?.appendingPathComponent("hardware-profiles.json"), working.appendingPathComponent("Resources/hardware-profiles.json")].compactMap { $0 }),
            .supplyChainManifest: hash([resources?.appendingPathComponent("supply-chain-manifest.json")].compactMap { $0 }),
            .hostPolicy: "schema-\(LabMigrationManager.currentSchemaVersion)",
        ])
    }
}

// MARK: - 6. Live-storage encryption checks

enum StorageEncryptionState: String, Codable, Sendable {
    case encrypted
    case unencrypted
    case unknown
}

struct StorageEncryptionReport: Codable, Hashable, Sendable {
    let inspectedAt: Date
    let path: String
    let volumeName: String?
    let volumeUUID: String?
    let fileSystem: String?
    let removable: Bool?
    let readOnly: Bool?
    let state: StorageEncryptionState
    let evidence: String
    var passed: Bool { state == .encrypted && readOnly != true }

    static let unknown = StorageEncryptionReport(
        inspectedAt: .distantPast, path: "", volumeName: nil, volumeUUID: nil,
        fileSystem: nil, removable: nil, readOnly: nil, state: .unknown,
        evidence: "Live storage has not been inspected."
    )
}

enum StorageEncryptionInspector {
    static func mountedVolume(containing path: URL, candidates: [URL]? = nil) -> URL? {
        let target = path.resolvingSymlinksInPath().standardizedFileURL.path
        let volumes = candidates ?? (FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]
        ) ?? [])
        return volumes.map { $0.resolvingSymlinksInPath().standardizedFileURL }
            .filter { target == $0.path || target.hasPrefix($0.path.hasSuffix("/") ? $0.path : $0.path + "/") }
            .max { $0.path.count < $1.path.count }
    }

    static func parse(plist data: Data, path: String) -> StorageEncryptionReport {
        guard let value = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return StorageEncryptionReport(
                inspectedAt: .now, path: path, volumeName: nil, volumeUUID: nil, fileSystem: nil,
                removable: nil, readOnly: nil, state: .unknown, evidence: "diskutil did not return a valid property list."
            )
        }
        let encrypted = (value["APFSVolumeFileVault"] as? Bool)
            ?? (value["FileVault"] as? Bool)
            ?? (value["Encrypted"] as? Bool)
        let state: StorageEncryptionState = encrypted.map { $0 ? .encrypted : .unencrypted } ?? .unknown
        let writable = value["Writable"] as? Bool
        return StorageEncryptionReport(
            inspectedAt: .now, path: path,
            volumeName: value["VolumeName"] as? String,
            volumeUUID: (value["APFSVolumeUUID"] as? String) ?? (value["VolumeUUID"] as? String),
            fileSystem: (value["FilesystemType"] as? String) ?? (value["Type (Bundle)"] as? String),
            removable: value["Removable"] as? Bool,
            readOnly: writable.map(!), state: state,
            evidence: encrypted == true ? "The mounted data volume reports FileVault/APFS encryption enabled."
                : encrypted == false ? "The mounted data volume reports encryption disabled."
                : "The mounted volume did not expose a recognized encryption field."
        )
    }

    static func inspect(path: URL) -> StorageEncryptionReport {
        guard let volume = mountedVolume(containing: path) else {
            return StorageEncryptionReport(
                inspectedAt: .now, path: path.path, volumeName: nil, volumeUUID: nil,
                fileSystem: nil, removable: nil, readOnly: nil, state: .unknown,
                evidence: "The live-storage mount point could not be resolved."
            )
        }
        let result = ProcessExecutor.run(
            executable: URL(fileURLWithPath: "/usr/sbin/diskutil"),
            arguments: ["info", "-plist", volume.path], timeout: 15
        )
        guard result.succeeded else {
            return StorageEncryptionReport(
                inspectedAt: .now, path: path.path, volumeName: nil, volumeUUID: nil,
                fileSystem: nil, removable: nil, readOnly: nil, state: .unknown,
                evidence: result.output.nilIfBlank ?? "diskutil could not inspect the live storage volume."
            )
        }
        return parse(plist: Data(result.output.utf8), path: path.path)
    }
}

// MARK: - 7. Startup reconciliation

enum ReconciliationSeverity: String, Codable, Sendable { case information, warning, blocking }

struct ReconciliationFinding: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let severity: ReconciliationSeverity
    let summary: String
    let recoveryAction: String
    let safeToRepairAutomatically: Bool
}

struct StartupReconciliationReport: Codable, Hashable, Sendable {
    let generatedAt: Date
    let findings: [ReconciliationFinding]
    let repairedFindingIDs: [String]
    var passed: Bool { findings.allSatisfy { $0.severity != .blocking || repairedFindingIDs.contains($0.id) } }
    static let empty = StartupReconciliationReport(generatedAt: .distantPast, findings: [], repairedFindingIDs: [])
}

enum StartupReconciler {
    static func inspect(
        paths: LabPaths,
        journal: [OperationJournalEntry],
        stagedUpdate: StagedUpdateRecord?,
        fleetLeases: [FleetLease] = [],
        physicalLeases: [PhysicalDeviceLease] = [],
        faultResults: [FaultInjectionResult] = [],
        faultRecoveries: [FaultRecoveryReceipt] = [],
        now: Date = .now
    ) -> StartupReconciliationReport {
        var findings: [ReconciliationFinding] = []
        for entry in journal where [.running, .interrupted].contains(entry.state) {
            findings.append(ReconciliationFinding(
                id: "journal-\(entry.id.uuidString)", severity: .blocking,
                summary: "\(entry.kind.rawValue) for \(entry.target) was interrupted during \(entry.phase.rawValue).",
                recoveryAction: entry.recoveryInstruction, safeToRepairAutomatically: false
            ))
        }
        if let stagedUpdate, !stagedUpdate.installationApproved {
            findings.append(ReconciliationFinding(
                id: "staged-update-\(stagedUpdate.version)", severity: .warning,
                summary: "Component update \(stagedUpdate.version) remains staged but unapproved.",
                recoveryAction: "Approve and install it, or retain it as a rollback-safe staged candidate.",
                safeToRepairAutomatically: false
            ))
        }
        for lease in fleetLeases where lease.state == .active && lease.expiresAt <= now {
            findings.append(ReconciliationFinding(
                id: "fleet-lease-\(lease.id.uuidString)", severity: .warning,
                summary: "Fleet lease for \(lease.jobName) expired while still marked active.",
                recoveryAction: "Normalize the lease to expired before scheduling replacement work.",
                safeToRepairAutomatically: true
            ))
        }
        for lease in physicalLeases where lease.state == .active && lease.expiresAt <= now {
            findings.append(ReconciliationFinding(
                id: "physical-lease-\(lease.id.uuidString)", severity: .warning,
                summary: "Physical-device lease for \(lease.targetID) expired while still marked active.",
                recoveryAction: "Normalize the exclusive lease to expired before allocating the device.",
                safeToRepairAutomatically: true
            ))
        }
        let recoveredScenarios = Set(faultRecoveries.filter(\.recovered).compactMap(\.scenarioID))
        for result in faultResults where result.succeeded && !recoveredScenarios.contains(result.scenarioID) {
            findings.append(ReconciliationFinding(
                id: "guest-fault-\(result.scenarioID.uuidString)", severity: .blocking,
                summary: "Fault scenario on \(result.deviceName) has no verified cleanup receipt.",
                recoveryAction: "Start the guest, clear the scenario, query fault status, and record an empty active-fault list.",
                safeToRepairAutomatically: false
            ))
        }
        let sockets = ((try? FileManager.default.contentsOfDirectory(
            at: paths.stateRoot, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        )) ?? []).filter { $0.pathExtension == "sock" }
        for socket in sockets {
            let modified = (try? socket.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if now.timeIntervalSince(modified) > 86_400 {
                findings.append(ReconciliationFinding(
                    id: "socket-\(socket.lastPathComponent)", severity: .warning,
                    summary: "A stale local socket is older than 24 hours.",
                    recoveryAction: "Remove \(socket.path) after confirming no worker owns it.", safeToRepairAutomatically: true
                ))
            }
        }
        return StartupReconciliationReport(generatedAt: .now, findings: findings, repairedFindingIDs: [])
    }

    static func repairSafeFindings(_ report: StartupReconciliationReport, paths: LabPaths) -> StartupReconciliationReport {
        var repaired = Set(report.repairedFindingIDs)
        for finding in report.findings where finding.safeToRepairAutomatically && finding.id.hasPrefix("socket-") {
            let name = String(finding.id.dropFirst("socket-".count))
            let url = paths.stateRoot.appendingPathComponent(name)
            guard url.deletingLastPathComponent().standardizedFileURL == paths.stateRoot.standardizedFileURL else { continue }
            if (try? FileManager.default.removeItem(at: url)) != nil { repaired.insert(finding.id) }
        }
        return StartupReconciliationReport(
            generatedAt: .now, findings: report.findings,
            repairedFindingIDs: repaired.sorted()
        )
    }
}

// MARK: - 8. Atomic component upgrades

enum ComponentUpgradePhase: String, Codable, Sendable { case none, staged, approved, committed, rolledBack, failed }

struct ComponentVersionSet: Codable, Hashable, Sendable {
    let manager: String
    let backend: String
    let guestCompanion: String
    let protocolVersion: Int
    let schemaVersion: Int
}

struct ComponentArtifact: Codable, Hashable, Sendable {
    let component: String
    let sourcePath: String
    let stagedPath: String
    let sha256: String
    let sizeBytes: Int64
}

struct ComponentUpgradeTransaction: Codable, Hashable, Sendable {
    let id: UUID
    let createdAt: Date
    var updatedAt: Date
    let from: ComponentVersionSet
    let to: ComponentVersionSet
    let artifacts: [ComponentArtifact]
    let rollbackRoot: String
    var phase: ComponentUpgradePhase
    var healthChecks: [String: Bool]
    var message: String

    static let empty = ComponentUpgradeTransaction(
        id: UUID(), createdAt: .distantPast, updatedAt: .distantPast,
        from: ComponentVersionSet(manager: "", backend: "", guestCompanion: "", protocolVersion: 0, schemaVersion: 0),
        to: ComponentVersionSet(manager: "", backend: "", guestCompanion: "", protocolVersion: 0, schemaVersion: 0),
        artifacts: [], rollbackRoot: "", phase: .none, healthChecks: [:], message: "No component upgrade is staged."
    )
}

enum ComponentUpgradeCoordinator {
    static func validate(_ transaction: ComponentUpgradeTransaction) -> [String] {
        var issues: [String] = []
        if transaction.to.protocolVersion != BackendAdapterConformance.protocolVersion { issues.append("Guest protocol is incompatible with this manager.") }
        if transaction.to.schemaVersion != LabMigrationManager.currentSchemaVersion { issues.append("State schema is incompatible with this manager.") }
        if transaction.artifacts.isEmpty { issues.append("No component artifacts were staged.") }
        if Set(transaction.artifacts.map(\.component)).count != transaction.artifacts.count { issues.append("Component names must be unique.") }
        for artifact in transaction.artifacts {
            if artifact.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) == nil { issues.append("\(artifact.component) has an invalid SHA-256.") }
            if artifact.sizeBytes <= 0 { issues.append("\(artifact.component) is empty.") }
        }
        return issues
    }

    static func stage(
        sources: [(component: String, url: URL)], from: ComponentVersionSet,
        to: ComponentVersionSet, paths: LabPaths
    ) throws -> ComponentUpgradeTransaction {
        let id = UUID()
        let root = paths.stateRoot.appendingPathComponent("Component Upgrades/\(id.uuidString)", isDirectory: true)
        let staged = root.appendingPathComponent("Staged", isDirectory: true)
        let rollback = root.appendingPathComponent("Rollback", isDirectory: true)
        try SecureFilesystem.prepareDirectory(staged)
        try SecureFilesystem.prepareDirectory(rollback)
        var artifacts: [ComponentArtifact] = []
        for source in sources {
            let values = try source.url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size > 0, size <= 512 * 1_024 * 1_024 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let name = NameSanitizer.fileComponent(source.component)
            let target = staged.appendingPathComponent(name)
            try FileManager.default.copyItem(at: source.url, to: target)
            try SecureFilesystem.protectFile(target)
            let digest = SHA256.hash(data: try Data(contentsOf: target)).map { String(format: "%02x", $0) }.joined()
            artifacts.append(ComponentArtifact(
                component: source.component, sourcePath: source.url.path, stagedPath: target.path,
                sha256: digest, sizeBytes: Int64(size)
            ))
        }
        var transaction = ComponentUpgradeTransaction(
            id: id, createdAt: .now, updatedAt: .now, from: from, to: to,
            artifacts: artifacts, rollbackRoot: rollback.path, phase: .staged,
            healthChecks: [:], message: "Components are staged; compatibility and hashes must pass before approval."
        )
        let issues = validate(transaction)
        if !issues.isEmpty { transaction.phase = .failed; transaction.message = issues.joined(separator: " ") }
        try HardeningJSON.save(transaction, to: root.appendingPathComponent("transaction.json"))
        return transaction
    }

    static func approve(_ transaction: ComponentUpgradeTransaction) -> ComponentUpgradeTransaction {
        var next = transaction
        let issues = validate(next)
        guard next.phase == .staged, issues.isEmpty else {
            next.phase = .failed
            next.message = issues.isEmpty ? "Only a staged transaction can be approved." : issues.joined(separator: " ")
            next.updatedAt = .now
            return next
        }
        next.phase = .approved
        next.updatedAt = .now
        next.message = "Compatibility, bounds, and artifact hashes passed. Commit remains an explicit operator action."
        return next
    }

    static func commit(
        _ transaction: ComponentUpgradeTransaction,
        healthChecks: [String: Bool],
        paths: LabPaths
    ) throws -> ComponentUpgradeTransaction {
        var next = transaction
        guard transaction.phase == .approved, !healthChecks.isEmpty, healthChecks.values.allSatisfy({ $0 }) else {
            next.phase = .failed
            next.healthChecks = healthChecks
            next.message = "Every pre-activation health check must pass before the component set can be committed."
            next.updatedAt = .now
            return next
        }
        for artifact in transaction.artifacts {
            let url = URL(fileURLWithPath: artifact.stagedPath)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  values.fileSize == Int(artifact.sizeBytes),
                  SHA256.hash(data: try Data(contentsOf: url)).map({ String(format: "%02x", $0) }).joined() == artifact.sha256 else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
        let active = paths.stateRoot.appendingPathComponent("active-component-set.json")
        if FileManager.default.fileExists(atPath: active.path) {
            let rollback = URL(fileURLWithPath: transaction.rollbackRoot).appendingPathComponent("active-component-set.json")
            try FileManager.default.copyItem(at: active, to: rollback)
            try SecureFilesystem.protectFile(rollback)
        }
        next.phase = .committed
        next.healthChecks = healthChecks
        next.message = "The verified component set was activated with one atomic manifest replacement."
        next.updatedAt = .now
        try HardeningJSON.save(next, to: active)
        return next
    }

    static func rollback(_ transaction: ComponentUpgradeTransaction, paths: LabPaths) throws -> ComponentUpgradeTransaction {
        var next = transaction
        guard transaction.phase == .committed else {
            next.phase = .failed
            next.message = "Only a committed component transaction can be rolled back."
            next.updatedAt = .now
            return next
        }
        let active = paths.stateRoot.appendingPathComponent("active-component-set.json")
        let rollback = URL(fileURLWithPath: transaction.rollbackRoot).appendingPathComponent("active-component-set.json")
        guard FileManager.default.fileExists(atPath: rollback.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let prior = try HardeningJSON.load(ComponentUpgradeTransaction.self, from: rollback)
        try HardeningJSON.save(prior, to: active)
        next.phase = .rolledBack
        next.updatedAt = .now
        next.message = "The previous component activation manifest was restored atomically."
        return next
    }
}

// MARK: - 9. Supply-chain policy enforcement

enum VulnerabilitySeverity: String, Codable, CaseIterable, Comparable, Sendable {
    case unknown, low, medium, high, critical
    private var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

struct SoftwareComponentRecord: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let name: String
    let version: String
    let licenses: [String]
    let maximumSeverity: VulnerabilitySeverity
    let vulnerabilityIDs: [String]
}

struct SupplyChainPolicy: Codable, Hashable, Sendable {
    var allowedLicenses: Set<String>
    var deniedLicenses: Set<String>
    var maximumAllowedSeverity: VulnerabilitySeverity
    var requireSBOM: Bool
    var requireProvenance: Bool
    var blockUnknownLicenses: Bool

    static let standard = SupplyChainPolicy(
        allowedLicenses: ["Apache-2.0", "BSD-2-Clause", "BSD-3-Clause", "ISC", "MIT", "MPL-2.0"],
        deniedLicenses: ["AGPL-3.0-only", "GPL-3.0-only"], maximumAllowedSeverity: .high,
        requireSBOM: true, requireProvenance: true, blockUnknownLicenses: true
    )
}

struct SupplyChainPolicyEvidence: Codable, Hashable, Sendable {
    let importedAt: Date
    let sourceRevision: String?
    let sbomSHA256: String?
    let provenanceVerified: Bool
    let components: [SoftwareComponentRecord]
    let issues: [String]
    var passed: Bool { issues.isEmpty }

    static let unavailable = SupplyChainPolicyEvidence(
        importedAt: .distantPast, sourceRevision: nil, sbomSHA256: nil,
        provenanceVerified: false, components: [], issues: ["No SBOM and vulnerability evidence has been imported."]
    )
}

enum SupplyChainPolicyEvaluator {
    static func evaluate(
        policy: SupplyChainPolicy, components: [SoftwareComponentRecord],
        sbomSHA256: String?, sourceRevision: String?, provenanceVerified: Bool,
        importedAt: Date = .now
    ) -> SupplyChainPolicyEvidence {
        var issues: [String] = []
        if policy.requireSBOM && (components.isEmpty || sbomSHA256 == nil) { issues.append("A non-empty, hashed SBOM is required.") }
        if policy.requireProvenance && (!provenanceVerified || sourceRevision?.isEmpty != false) { issues.append("Verified source provenance is required.") }
        for component in components {
            if component.licenses.contains(where: policy.deniedLicenses.contains) { issues.append("\(component.name) uses a denied license.") }
            if policy.blockUnknownLicenses && component.licenses.isEmpty { issues.append("\(component.name) has no declared license.") }
            if !component.licenses.isEmpty && !policy.allowedLicenses.isEmpty
                && !component.licenses.allSatisfy(policy.allowedLicenses.contains) {
                issues.append("\(component.name) has a license outside the allowlist.")
            }
            if component.maximumSeverity > policy.maximumAllowedSeverity {
                issues.append("\(component.name) exceeds the \(policy.maximumAllowedSeverity.rawValue) vulnerability threshold.")
            }
        }
        return SupplyChainPolicyEvidence(
            importedAt: importedAt, sourceRevision: sourceRevision, sbomSHA256: sbomSHA256,
            provenanceVerified: provenanceVerified, components: components, issues: Array(Set(issues)).sorted()
        )
    }
}

struct SupplyChainEvidenceDocument: Codable, Sendable {
    let schemaVersion: Int
    let sourceRevision: String
    let provenanceVerified: Bool
    let components: [SoftwareComponentRecord]
}

enum SupplyChainEvidenceImporter {
    static func load(_ url: URL, policy: SupplyChainPolicy) throws -> SupplyChainPolicyEvidence {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= 32 * 1_024 * 1_024 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let data = try Data(contentsOf: url)
        let document = try JSONDecoder().decode(SupplyChainEvidenceDocument.self, from: data)
        guard document.schemaVersion == 1,
              document.sourceRevision.range(of: "^[0-9a-fA-F]{7,64}$", options: .regularExpression) != nil else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return SupplyChainPolicyEvaluator.evaluate(
            policy: policy, components: document.components, sbomSHA256: hash,
            sourceRevision: document.sourceRevision.lowercased(),
            provenanceVerified: document.provenanceVerified
        )
    }
}

// MARK: - 10. Support and deprecation lifecycle

enum SupportLifecycleStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case preview
    case supported
    case deprecated
    case endOfLife
    var id: String { rawValue }
}

struct SupportLifecycleEntry: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let component: String
    let versionRange: String
    var status: SupportLifecycleStatus
    var deprecatedAt: Date?
    var endOfLifeAt: Date?
    var migrationTarget: String?
    var rationale: String
}

struct SupportLifecyclePolicy: Codable, Hashable, Sendable {
    var minimumDeprecationNoticeDays: Int
    var entries: [SupportLifecycleEntry]
    var updatedAt: Date

    static let standard = SupportLifecyclePolicy(
        minimumDeprecationNoticeDays: 90,
        entries: [
            SupportLifecycleEntry(id: "manager-0.14", component: "iOS Virtual Device Lab", versionRange: "0.14.x", status: .supported, deprecatedAt: nil, endOfLifeAt: nil, migrationTarget: nil, rationale: "Current operations-hardening release line."),
            SupportLifecycleEntry(id: "guest-protocol-3", component: "Guest protocol", versionRange: "3", status: .supported, deprecatedAt: nil, endOfLifeAt: nil, migrationTarget: nil, rationale: "Authenticated and replay-protected protocol contract."),
            SupportLifecycleEntry(id: "state-schema-10", component: "State schema", versionRange: "10", status: .supported, deprecatedAt: nil, endOfLifeAt: nil, migrationTarget: nil, rationale: "Current persisted state schema."),
        ], updatedAt: .now
    )
}

struct SupportLifecycleAssessment: Codable, Hashable, Sendable {
    let evaluatedAt: Date
    let issues: [String]
    var passed: Bool { issues.isEmpty }
    static let empty = SupportLifecycleAssessment(evaluatedAt: .distantPast, issues: ["Lifecycle policy has not been evaluated."])
}

enum SupportLifecycleEvaluator {
    static func evaluate(_ policy: SupportLifecyclePolicy, now: Date = .now) -> SupportLifecycleAssessment {
        var issues: [String] = []
        if policy.minimumDeprecationNoticeDays < 30 { issues.append("Deprecation notice must be at least 30 days.") }
        if policy.entries.isEmpty { issues.append("At least one supported component must be declared.") }
        if !policy.entries.contains(where: { $0.status == .supported }) { issues.append("At least one current supported component is required.") }
        if Set(policy.entries.map(\.id)).count != policy.entries.count { issues.append("Lifecycle entry identifiers must be unique.") }
        for entry in policy.entries {
            if entry.id.isEmpty || entry.component.isEmpty || entry.versionRange.isEmpty || entry.rationale.isEmpty {
                issues.append("Every lifecycle entry needs an identifier, component, version range, and rationale.")
            }
            switch entry.status {
            case .deprecated:
                guard let deprecated = entry.deprecatedAt, let end = entry.endOfLifeAt else {
                    issues.append("\(entry.component) is deprecated without dated notice and end-of-life milestones.")
                    continue
                }
                if end.timeIntervalSince(deprecated) < Double(policy.minimumDeprecationNoticeDays) * 86_400 {
                    issues.append("\(entry.component) does not provide the minimum deprecation notice.")
                }
                if entry.migrationTarget?.isEmpty != false { issues.append("\(entry.component) has no migration target.") }
            case .endOfLife:
                if entry.endOfLifeAt == nil || entry.endOfLifeAt! > now { issues.append("\(entry.component) is marked end-of-life before its effective date.") }
                if entry.migrationTarget?.isEmpty != false { issues.append("\(entry.component) has no migration target.") }
            case .preview, .supported: break
            }
        }
        return SupportLifecycleAssessment(evaluatedAt: now, issues: issues)
    }
}

// MARK: - Unified v1.1 state and evaluation

struct OperationsHardeningState: Codable, Hashable, Sendable {
    var hostSetup: HostSetupContinuation
    var permissions: PermissionOnboardingReport
    var fleetProtocol: FleetWorkerProtocolEvidence
    var fleetAudit: FleetAuditVerification
    var evidenceBaseline: EvidenceDependencySnapshot?
    var evidenceCurrent: EvidenceDependencySnapshot?
    var evidenceInvalidations: [EvidenceInvalidationRecord]
    var storageEncryption: StorageEncryptionReport
    var reconciliation: StartupReconciliationReport
    var componentUpgrade: ComponentUpgradeTransaction
    var supplyChainPolicy: SupplyChainPolicy
    var supplyChainEvidence: SupplyChainPolicyEvidence
    var lifecyclePolicy: SupportLifecyclePolicy
    var lifecycleAssessment: SupportLifecycleAssessment
    var report: OperationsHardeningReport

    static let empty = OperationsHardeningState(
        hostSetup: .empty, permissions: .empty, fleetProtocol: .unavailable,
        fleetAudit: .unavailable, evidenceBaseline: nil, evidenceCurrent: nil,
        evidenceInvalidations: [], storageEncryption: .unknown, reconciliation: .empty,
        componentUpgrade: .empty, supplyChainPolicy: .standard,
        supplyChainEvidence: .unavailable, lifecyclePolicy: .standard,
        lifecycleAssessment: .empty, report: .empty
    )
}

enum OperationsHardeningEvaluator {
    static func evaluate(_ state: OperationsHardeningState) -> OperationsHardeningReport {
        let fleetIssues = FleetWorkerProtocolEvaluator.validate(state.fleetProtocol)
        let unresolved = state.evidenceInvalidations.filter { !$0.resolved }
        let upgradePassed = state.componentUpgrade.phase == .committed
            && !state.componentUpgrade.healthChecks.isEmpty
            && state.componentUpgrade.healthChecks.values.allSatisfy { $0 }
        func gate(_ kind: OperationsGateKind, _ passed: Bool, _ evidence: String, _ action: String, blocked: Bool = false) -> OperationsGateResult {
            OperationsGateResult(
                kind: kind, state: passed ? .passed : (blocked ? .blocked : .actionRequired),
                evidence: evidence, requiredAction: action
            )
        }
        return OperationsHardeningReport(schemaVersion: 1, generatedAt: .now, gates: [
            gate(.hostSetupContinuation, state.hostSetup.phase == .complete,
                 state.hostSetup.note, "Complete the Recovery, restart, and post-boot verification flow."),
            gate(.permissionOnboarding, state.permissions.passed,
                 "\(state.permissions.checks.filter(\.passed).count)/\(state.permissions.checks.count) required permission checks pass.",
                 "Grant each required permission in System Settings, then inspect again."),
            gate(.fleetWorkerProtocol, fleetIssues.isEmpty,
                 fleetIssues.isEmpty ? "The complete two-host worker lifecycle passed." : fleetIssues.joined(separator: " "),
                 "Run and import a current two-host worker protocol qualification.", blocked: state.fleetProtocol.generatedAt == .distantPast),
            gate(.tamperEvidentAudit, state.fleetAudit.passed,
                 state.fleetAudit.passed ? "\(state.fleetAudit.recordCount) signed records form a valid chain." : state.fleetAudit.issues.joined(separator: " "),
                 "Import the fleet ledger with its signing certificate and verify every record."),
            gate(.evidenceInvalidation, state.evidenceBaseline != nil && unresolved.isEmpty,
                 unresolved.isEmpty ? (state.evidenceBaseline == nil ? "No dependency baseline exists." : "No transitive evidence is stale.") : "\(unresolved.count) dependency change set(s) invalidate evidence.",
                 "Capture a baseline, then re-run and explicitly replace all invalidated evidence."),
            gate(.liveStorageEncryption, state.storageEncryption.passed,
                 state.storageEncryption.evidence, "Move the lab to an encrypted writable APFS/FileVault volume and inspect again."),
            gate(.startupReconciliation, state.reconciliation.passed,
                 state.reconciliation.passed ? "Startup state is internally consistent." : "\(state.reconciliation.findings.filter { $0.severity == .blocking }.count) blocking recovery finding(s).",
                 "Resolve interrupted journal operations and re-run reconciliation."),
            gate(.atomicComponentUpgrades, upgradePassed,
                 state.componentUpgrade.message, "Exercise a compatible multi-component transaction, health checks, commit, and rollback."),
            gate(.supplyChainPolicy, state.supplyChainEvidence.passed,
                 state.supplyChainEvidence.passed ? "SBOM, license, vulnerability, and provenance policy passed." : state.supplyChainEvidence.issues.joined(separator: " "),
                 "Import a hashed SBOM, vulnerability scan, and verified provenance that satisfy policy."),
            gate(.supportLifecycle, state.lifecycleAssessment.passed,
                 state.lifecycleAssessment.passed ? "Every lifecycle entry has valid support and migration dates." : state.lifecycleAssessment.issues.joined(separator: " "),
                 "Correct notice periods, end-of-life dates, and migration targets."),
        ])
    }
}

enum OperationsHardeningStore {
    private static func url(paths: LabPaths) -> URL { paths.stateRoot.appendingPathComponent("operations-hardening.json") }

    static func load(paths: LabPaths) -> OperationsHardeningState {
        if let persisted = try? HardeningJSON.load(OperationsHardeningState.self, from: url(paths: paths)) {
            return persisted
        }
        var state = OperationsHardeningState.empty
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("supply-chain-policy.json"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Resources/supply-chain-policy.json"),
        ].compactMap { $0 }
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            if let policy = try? JSONDecoder().decode(SupplyChainPolicy.self, from: Data(contentsOf: candidate)) {
                state.supplyChainPolicy = policy
                break
            }
        }
        state.lifecycleAssessment = SupportLifecycleEvaluator.evaluate(state.lifecyclePolicy)
        state.report = OperationsHardeningEvaluator.evaluate(state)
        return state
    }

    static func save(_ state: OperationsHardeningState, paths: LabPaths) throws {
        try HardeningJSON.save(state, to: url(paths: paths))
    }
}

private extension Data {
    init?(hexadecimal: String) {
        guard hexadecimal.count.isMultiple(of: 2), hexadecimal.allSatisfy({ $0.isHexDigit }) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hexadecimal.count / 2)
        var index = hexadecimal.startIndex
        while index < hexadecimal.endIndex {
            let next = hexadecimal.index(index, offsetBy: 2)
            guard let byte = UInt8(hexadecimal[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self = Data(bytes)
    }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
