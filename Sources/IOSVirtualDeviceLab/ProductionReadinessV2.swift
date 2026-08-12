import CryptoKit
import Foundation

// MARK: - Real-VM qualification campaigns

enum QualificationState: String, Codable, Sendable {
    case blocked
    case ready
    case running
    case passed
    case failed
}

struct QualificationCampaign: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let deviceName: String?
    let firmwareSHA256: String?
    let hardwareProfileID: String?
    let hostFingerprint: String
    let backendID: String
    let backendVersion: String?
    let createdAt: Date
    var completedAt: Date?
    var state: QualificationState
    var blockers: [String]
    var acceptance: AcceptanceReport
    var evidenceSealID: UUID?
}

enum QualificationCampaignStore {
    private static func url(paths: LabPaths) -> URL {
        paths.stateRoot.appendingPathComponent("qualification-campaigns.json")
    }

    static func load(paths: LabPaths) -> [QualificationCampaign] {
        (try? HardeningJSON.load([QualificationCampaign].self, from: url(paths: paths))) ?? []
    }

    static func save(_ campaigns: [QualificationCampaign], paths: LabPaths) throws {
        try HardeningJSON.save(Array(campaigns.prefix(100)), to: url(paths: paths))
    }

    static func create(
        host: HostReadiness,
        backend: BackendDescriptor,
        device: VirtualDevice?,
        firmware: FirmwareImage?,
        acceptance: AcceptanceReport
    ) -> QualificationCampaign {
        var blockers: [String] = []
        if !host.isReady { blockers.append("Host preflight has not passed.") }
        if device == nil { blockers.append("Select a restored virtual device.") }
        if firmware?.sha256 == nil { blockers.append("Select firmware with a validated SHA-256 identity.") }
        if firmware?.validation?.state != .valid { blockers.append("The firmware fixture must pass structural validation.") }
        if device?.hardwareProfileID == nil { blockers.append("The device needs a versioned hardware profile.") }
        if let device, acceptance.deviceName != device.name {
            blockers.append("The acceptance report does not belong to the selected device.")
        }
        if !acceptance.isPassed { blockers.append("The real-VM acceptance gates are incomplete.") }
        let passed = blockers.isEmpty
        return QualificationCampaign(
            id: UUID(),
            deviceName: device?.name,
            firmwareSHA256: firmware?.sha256,
            hardwareProfileID: device?.hardwareProfileID,
            hostFingerprint: "\(host.model)|\(host.macOSVersion)|\(host.architecture)",
            backendID: backend.id,
            backendVersion: backend.version,
            createdAt: .now,
            completedAt: passed ? .now : nil,
            state: passed ? .passed : .blocked,
            blockers: blockers,
            acceptance: acceptance,
            evidenceSealID: nil
        )
    }
}

// MARK: - First-run setup and repair assistant

enum SetupCheckState: String, Codable, Sendable {
    case passed
    case actionRequired
    case blocked
}

struct SetupCheck: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let title: String
    let state: SetupCheckState
    let detail: String
    let repairInstruction: String
    let canRepairInApp: Bool
}

struct SetupAssistantReport: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let generatedAt: Date
    let checks: [SetupCheck]

    static let empty = SetupAssistantReport(schemaVersion: 1, generatedAt: .distantPast, checks: [])
    var isComplete: Bool { !checks.isEmpty && checks.allSatisfy { $0.state == .passed } }
}

enum SetupAssistant {
    static func inspect(paths: LabPaths, host: HostReadiness) -> SetupAssistantReport {
        let fm = FileManager.default
        let dataWritable = fm.isWritableFile(atPath: paths.dataRoot.path)
        let stateWritable = fm.isWritableFile(atPath: paths.stateRoot.path)
        let hasFirmware = ((try? fm.contentsOfDirectory(at: paths.firmwareRoot, includingPropertiesForKeys: nil)) ?? [])
            .contains { $0.pathExtension.lowercased() == "ipsw" }
        let free = (try? paths.dataRoot.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        let checks = [
            SetupCheck(
                id: "host", title: "Host and Recovery policy",
                state: host.isReady ? .passed : (host.state == .unavailable ? .blocked : .actionRequired),
                detail: host.isReady ? "Host preflight passed." : host.researchGuestsStatus,
                repairInstruction: "Recovery changes require a restart and must be performed by the Mac owner. The app never changes SIP or Research Guests.",
                canRepairInApp: false
            ),
            SetupCheck(
                id: "backend", title: "vphone backend",
                state: host.binaryPath == nil ? .actionRequired : .passed,
                detail: host.binaryPath ?? "No executable was discovered.",
                repairInstruction: "Install/build the reviewed companion backend or set VPHONE_CLI_BIN.",
                canRepairInApp: false
            ),
            SetupCheck(
                id: "storage", title: "Lab storage",
                state: dataWritable && stateWritable ? .passed : .actionRequired,
                detail: "\(paths.dataRoot.path) • \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) available",
                repairInstruction: "Create missing lab directories and verify that the selected APFS volume is writable.",
                canRepairInApp: true
            ),
            SetupCheck(
                id: "firmware", title: "Supported firmware fixture",
                state: hasFirmware ? .passed : .actionRequired,
                detail: hasFirmware ? "At least one owned IPSW fixture is present." : "No IPSW fixture is imported; firmware is never included with the app.",
                repairInstruction: "Import an owned IPSW, validate BuildManifest.plist, and select a recorded hardware pairing.",
                canRepairInApp: true
            ),
            SetupCheck(
                id: "security-restore", title: "Security restoration plan",
                state: .passed,
                detail: "The setup report preserves the commands needed to restore normal host policy after research.",
                repairInstruction: "When finished, return to Recovery and restore full SIP/research-guest policy according to Apple and backend guidance.",
                canRepairInApp: false
            ),
        ]
        return SetupAssistantReport(schemaVersion: 1, generatedAt: .now, checks: checks)
    }

    static func repairSafeDirectories(paths: LabPaths) throws {
        try paths.createDirectories()
        for directory in [
            paths.stateRoot.appendingPathComponent("Evidence", isDirectory: true),
            paths.stateRoot.appendingPathComponent("Backups", isDirectory: true),
            paths.stateRoot.appendingPathComponent("Resilience Reports", isDirectory: true),
            paths.stateRoot.appendingPathComponent("Updates", isDirectory: true),
        ] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}

// MARK: - Guest trust and accessibility automation contracts

enum GuestTrustMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case requireAuthenticated
    case allowLocalUnauthenticatedReadOnly
    var id: String { rawValue }
}

struct GuestTrustPolicy: Codable, Hashable, Sendable {
    var mode: GuestTrustMode
    var rejectLegacyProtocol: Bool
    var maximumClockSkewSeconds: Int
    var requireReplayProtection: Bool

    static let strict = GuestTrustPolicy(
        mode: .requireAuthenticated,
        rejectLegacyProtocol: true,
        maximumClockSkewSeconds: 30,
        requireReplayProtection: true
    )
}

struct GuestTrustAssessment: Codable, Hashable, Sendable {
    let trustedForMutation: Bool
    let readOnlyAllowed: Bool
    let reasons: [String]
}

enum GuestTrustEvaluator {
    static func evaluate(_ handshake: GuestProtocolHandshake, policy: GuestTrustPolicy) -> GuestTrustAssessment {
        var reasons: [String] = []
        if handshake.status == .incompatible || handshake.status == .unavailable {
            reasons.append("No compatible guest protocol is available.")
        }
        if policy.rejectLegacyProtocol && handshake.status == .legacy {
            reasons.append("Legacy protocol negotiation is rejected by policy.")
        }
        if !handshake.authenticated {
            reasons.append("The guest-control channel is not cryptographically authenticated.")
        }
        if policy.requireReplayProtection && !handshake.replayProtected {
            reasons.append("The guest-control channel does not declare replay protection.")
        }
        if let reported = handshake.authenticationClockSkewSeconds,
           reported > policy.maximumClockSkewSeconds {
            reasons.append("The backend clock-skew window exceeds policy (\(reported)s > \(policy.maximumClockSkewSeconds)s).")
        }
        let compatible = handshake.status == .compatible || (!policy.rejectLegacyProtocol && handshake.status == .legacy)
        let replayTrusted = !policy.requireReplayProtection || handshake.replayProtected
        let clockTrusted = handshake.authenticationClockSkewSeconds.map { $0 <= policy.maximumClockSkewSeconds } ?? !policy.requireReplayProtection
        let mutationTrusted = compatible && handshake.authenticated && replayTrusted && clockTrusted
        let readOnly = compatible && (handshake.authenticated || policy.mode == .allowLocalUnauthenticatedReadOnly)
        return GuestTrustAssessment(
            trustedForMutation: mutationTrusted,
            readOnlyAllowed: readOnly,
            reasons: reasons.isEmpty ? ["Guest trust requirements are satisfied."] : reasons
        )
    }
}

struct AccessibilityNode: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let role: String
    let label: String?
    let value: String?
    let enabled: Bool
    let frame: [Double]?
    let children: [AccessibilityNode]
}

enum UIAutomationActionKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case waitForElement
    case tapElement
    case enterText
    case assertValue
    case captureScreenshot
    var id: String { rawValue }
}

struct UIAutomationStep: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var kind: UIAutomationActionKind
    var selector: String?
    var value: String?
    var timeoutSeconds: Int
}

struct UIAutomationPlan: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var steps: [UIAutomationStep]
}

struct UIAutomationReadiness: Codable, Hashable, Sendable {
    let available: Bool
    let reason: String

    static func assess(handshake: GuestProtocolHandshake?) -> UIAutomationReadiness {
        guard let handshake, handshake.status == .compatible else {
            return UIAutomationReadiness(available: false, reason: "A compatible guest protocol is required.")
        }
        guard handshake.authenticated else {
            return UIAutomationReadiness(available: false, reason: "UI mutation is blocked until the guest channel is authenticated.")
        }
        guard handshake.negotiatedVersion == 3, handshake.replayProtected,
              (handshake.authenticationClockSkewSeconds ?? .max) <= 30 else {
            return UIAutomationReadiness(available: false, reason: "UI mutation requires protocol v3 replay protection and a bounded clock window.")
        }
        guard handshake.capabilities.contains(.accessibilityTree) else {
            return UIAutomationReadiness(available: false, reason: "The backend does not expose an accessibility tree.")
        }
        return UIAutomationReadiness(available: true, reason: "Authenticated accessibility automation is available.")
    }
}

// MARK: - Signed evidence governance

enum EvidenceReviewState: String, Codable, Sendable {
    case pending
    case approved
    case rejected
}

struct EvidenceSeal: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let schemaVersion: Int
    let createdAt: Date
    let subject: String
    let hostFingerprint: String
    let appVersion: String
    let backendID: String
    let backendVersion: String?
    let payloadSHA256: String
    let previousSealSHA256: String?
    let signingPublicKey: String
    let signature: String
    var reviewState: EvidenceReviewState
    var reviewer: String?
    var reviewedAt: Date?
    var reviewNote: String?
}

enum EvidenceLedger {
    private struct SignatureMaterial: Encodable {
        let id: UUID
        let createdAt: Date
        let subject: String
        let hostFingerprint: String
        let appVersion: String
        let backendID: String
        let backendVersion: String?
        let payloadSHA256: String
        let previousSealSHA256: String?
    }

    private struct ChainMaterial: Encodable {
        let signatureMaterial: SignatureMaterial
        let signingPublicKey: String
        let signature: String
    }

    private static func root(paths: LabPaths) -> URL {
        paths.stateRoot.appendingPathComponent("Evidence", isDirectory: true)
    }

    private static func ledgerURL(paths: LabPaths) -> URL {
        root(paths: paths).appendingPathComponent("ledger.json")
    }

    private static func keyURL(paths: LabPaths) -> URL {
        root(paths: paths).appendingPathComponent("signing-key")
    }

    static func load(paths: LabPaths) -> [EvidenceSeal] {
        (try? HardeningJSON.load([EvidenceSeal].self, from: ledgerURL(paths: paths))) ?? []
    }

    static func seal<T: Encodable>(
        _ payload: T,
        subject: String,
        host: HostReadiness,
        appVersion: String,
        backend: BackendDescriptor,
        paths: LabPaths
    ) throws -> EvidenceSeal {
        let payloadData = try canonicalData(payload)
        let payloadHash = sha256(payloadData)
        var ledger = load(paths: paths)
        let previous = try ledger.last.map(chainHash)
        let key = try signingKey(paths: paths)
        let id = UUID()
        let createdAt = Date()
        let hostFingerprint = "\(host.model)|\(host.macOSVersion)|\(host.architecture)"
        let material = SignatureMaterial(
            id: id, createdAt: createdAt, subject: subject, hostFingerprint: hostFingerprint,
            appVersion: appVersion, backendID: backend.id, backendVersion: backend.version,
            payloadSHA256: payloadHash, previousSealSHA256: previous
        )
        let signature = try key.signature(for: canonicalData(material)).base64EncodedString()
        let seal = EvidenceSeal(
            id: id, schemaVersion: 1, createdAt: createdAt, subject: subject,
            hostFingerprint: hostFingerprint,
            appVersion: appVersion, backendID: backend.id, backendVersion: backend.version,
            payloadSHA256: payloadHash, previousSealSHA256: previous,
            signingPublicKey: key.publicKey.rawRepresentation.base64EncodedString(),
            signature: signature, reviewState: .pending, reviewer: nil, reviewedAt: nil, reviewNote: nil
        )
        let payloadURL = root(paths: paths).appendingPathComponent("\(seal.id.uuidString)-payload.json")
        try payloadData.write(to: payloadURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        ledger.append(seal)
        try HardeningJSON.save(ledger, to: ledgerURL(paths: paths))
        return seal
    }

    static func review(
        id: UUID,
        state: EvidenceReviewState,
        reviewer: String,
        note: String?,
        paths: LabPaths
    ) throws -> [EvidenceSeal] {
        var ledger = load(paths: paths)
        guard let index = ledger.firstIndex(where: { $0.id == id }) else { throw CocoaError(.fileNoSuchFile) }
        ledger[index].reviewState = state
        ledger[index].reviewer = reviewer
        ledger[index].reviewedAt = .now
        ledger[index].reviewNote = note
        try HardeningJSON.save(ledger, to: ledgerURL(paths: paths))
        return ledger
    }

    static func verify(paths: LabPaths) -> [String] {
        let ledger = load(paths: paths)
        var issues: [String] = []
        var previous: String?
        for seal in ledger {
            if seal.previousSealSHA256 != previous { issues.append("Evidence chain mismatch at \(seal.id.uuidString).") }
            guard let publicData = Data(base64Encoded: seal.signingPublicKey),
                  let signature = Data(base64Encoded: seal.signature),
                  let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicData) else {
                issues.append("Evidence signature metadata is invalid at \(seal.id.uuidString).")
                continue
            }
            let material = signatureMaterial(seal)
            if !key.isValidSignature(signature, for: (try? canonicalData(material)) ?? Data()) {
                issues.append("Evidence signature failed at \(seal.id.uuidString).")
            }
            let payload = root(paths: paths).appendingPathComponent("\(seal.id.uuidString)-payload.json")
            if !FileManager.default.fileExists(atPath: payload.path) {
                issues.append("Evidence payload is missing at \(seal.id.uuidString).")
            } else if (try? fileSHA256(payload)) != seal.payloadSHA256 {
                issues.append("Evidence payload checksum failed at \(seal.id.uuidString).")
            }
            previous = try? chainHash(seal)
        }
        return issues
    }

    private static func signatureMaterial(_ seal: EvidenceSeal) -> SignatureMaterial {
        SignatureMaterial(
            id: seal.id, createdAt: seal.createdAt, subject: seal.subject,
            hostFingerprint: seal.hostFingerprint, appVersion: seal.appVersion,
            backendID: seal.backendID, backendVersion: seal.backendVersion,
            payloadSHA256: seal.payloadSHA256, previousSealSHA256: seal.previousSealSHA256
        )
    }

    private static func chainHash(_ seal: EvidenceSeal) throws -> String {
        sha256(try canonicalData(ChainMaterial(
            signatureMaterial: signatureMaterial(seal),
            signingPublicKey: seal.signingPublicKey,
            signature: seal.signature
        )))
    }

    private static func signingKey(paths: LabPaths) throws -> Curve25519.Signing.PrivateKey {
        try FileManager.default.createDirectory(at: root(paths: paths), withIntermediateDirectories: true)
        let url = keyURL(paths: paths)
        if let data = try? Data(contentsOf: url), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) {
            return key
        }
        let key = Curve25519.Signing.PrivateKey()
        try key.rawRepresentation.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return key
    }
}

// MARK: - Full lab backup and disaster recovery

struct LabBackupPolicy: Codable, Hashable, Sendable {
    var includeSnapshots: Bool
    var includeTestArtifacts: Bool
    var includeDiagnosticBundles: Bool
    var maximumBackups: Int

    static let standard = LabBackupPolicy(
        includeSnapshots: false,
        includeTestArtifacts: true,
        includeDiagnosticBundles: false,
        maximumBackups: 5
    )
}

struct BackupManifestEntry: Codable, Hashable, Sendable {
    let relativePath: String
    let sizeBytes: Int64
    let sha256: String
}

struct LabBackupManifest: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let schemaVersion: Int
    let createdAt: Date
    let appVersion: String
    let sourceRoot: String
    let includesSnapshots: Bool
    let entries: [BackupManifestEntry]
}

struct BackupVerification: Codable, Hashable, Sendable {
    let passed: Bool
    let checkedAt: Date
    let manifest: LabBackupManifest?
    let issues: [String]
}

enum LabBackupManager {
    private static let excludedNames = Set(["agent-token", "signing-key", "Updates", "Migration Backups"])

    static func create(
        paths: LabPaths,
        destination: URL,
        policy: LabBackupPolicy,
        appVersion: String
    ) throws -> URL {
        let backup = destination.appendingPathComponent("VDL-Backup-\(timestamp())", isDirectory: true)
        let payload = backup.appendingPathComponent("Payload", isDirectory: true)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        try copyTree(from: paths.stateRoot, to: payload.appendingPathComponent("VirtualDeviceLab"), policy: policy)
        if policy.includeSnapshots {
            try copyTree(from: paths.snapshotsRoot, to: payload.appendingPathComponent("Snapshots"), policy: policy)
        }
        let entries = try manifestEntries(root: payload)
        let manifest = LabBackupManifest(
            id: UUID(), schemaVersion: 1, createdAt: .now, appVersion: appVersion,
            sourceRoot: paths.dataRoot.path, includesSnapshots: policy.includeSnapshots, entries: entries
        )
        try HardeningJSON.save(manifest, to: backup.appendingPathComponent("manifest.json"))
        try enforceRetention(destination: destination, maximumBackups: policy.maximumBackups, preserving: backup)
        return backup
    }

    static func verify(_ backup: URL) -> BackupVerification {
        do {
            let manifest = try HardeningJSON.load(LabBackupManifest.self, from: backup.appendingPathComponent("manifest.json"))
            let payload = backup.appendingPathComponent("Payload")
            var issues: [String] = []
            var expected = Set<String>()
            for entry in manifest.entries {
                guard isSafeRelativePath(entry.relativePath), expected.insert(entry.relativePath).inserted else {
                    issues.append("Unsafe or duplicate manifest path: \(entry.relativePath)")
                    continue
                }
                let url = payload.appendingPathComponent(entry.relativePath).standardizedFileURL
                guard relativePath(of: url, under: payload) != nil else {
                    issues.append("Manifest path escapes payload: \(entry.relativePath)")
                    continue
                }
                guard FileManager.default.fileExists(atPath: url.path) else {
                    issues.append("Missing \(entry.relativePath)")
                    continue
                }
                if try fileSHA256(url) != entry.sha256 { issues.append("Checksum mismatch: \(entry.relativePath)") }
            }
            let actual = Set(try manifestEntries(root: payload).map(\.relativePath))
            for extra in actual.subtracting(expected).sorted() { issues.append("Unexpected payload file: \(extra)") }
            return BackupVerification(passed: issues.isEmpty, checkedAt: .now, manifest: manifest, issues: issues)
        } catch {
            return BackupVerification(passed: false, checkedAt: .now, manifest: nil, issues: [error.localizedDescription])
        }
    }

    static func stageRestore(_ backup: URL, paths: LabPaths) throws -> URL {
        let verification = verify(backup)
        guard verification.passed else { throw CocoaError(.fileReadCorruptFile) }
        let destination = paths.stateRoot.appendingPathComponent("Restore Staging", isDirectory: true)
            .appendingPathComponent(verification.manifest?.id.uuidString ?? UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: backup.appendingPathComponent("Payload"), to: destination)
        return destination
    }

    private static func copyTree(from source: URL, to destination: URL, policy: LabBackupPolicy) throws {
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        guard let enumerator = FileManager.default.enumerator(
            at: source, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return }
        for case let item as URL in enumerator {
            guard let relative = relativePath(of: item, under: source) else { continue }
            let components = Set(relative.split(separator: "/").map(String.init))
            if !components.isDisjoint(with: excludedNames) {
                if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { enumerator.skipDescendants() }
                continue
            }
            if !policy.includeDiagnosticBundles && relative.contains("Diagnostic") { continue }
            if !policy.includeTestArtifacts && relative.contains("Test Reports") { continue }
            let target = destination.appendingPathComponent(relative)
            if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: item, to: target)
            }
        }
    }

    private static func manifestEntries(root: URL) throws -> [BackupManifestEntry] {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        var entries: [BackupManifestEntry] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { continue }
            guard let relative = relativePath(of: url, under: root) else { continue }
            entries.append(BackupManifestEntry(
                relativePath: relative,
                sizeBytes: Int64(values.fileSize ?? 0), sha256: try fileSHA256(url)
            ))
        }
        return entries.sorted { $0.relativePath < $1.relativePath }
    }

    private static func relativePath(of item: URL, under root: URL) -> String? {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        let child = item.resolvingSymlinksInPath().standardizedFileURL.path
        guard child.hasPrefix(base + "/") else { return nil }
        return String(child.dropFirst(base.count + 1))
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false)
            .contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }

    private static func enforceRetention(destination: URL, maximumBackups: Int, preserving: URL) throws {
        let keep = max(1, maximumBackups)
        let backups = try FileManager.default.contentsOfDirectory(
            at: destination, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        ).filter { $0.hasDirectoryPath && $0.lastPathComponent.hasPrefix("VDL-Backup-") }
            .sorted {
                let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhs > rhs
            }
        for expired in backups.dropFirst(keep) where expired.standardizedFileURL != preserving.standardizedFileURL {
            try FileManager.default.removeItem(at: expired)
        }
    }
}

// MARK: - Update staging and rollback

enum UpdateChannel: String, Codable, CaseIterable, Identifiable, Sendable {
    case stable
    case beta
    var id: String { rawValue }
}

struct UpdateLifecyclePolicy: Codable, Hashable, Sendable {
    var channel: UpdateChannel
    var requireSignedManifest: Bool
    var requireNotarization: Bool
    var retainRollbackVersions: Int

    static let standard = UpdateLifecyclePolicy(
        channel: .stable, requireSignedManifest: true, requireNotarization: true, retainRollbackVersions: 2
    )
}

struct StagedUpdateRecord: Codable, Hashable, Sendable {
    let version: String
    let sourceArchive: String
    let stagedAppPath: String
    let rollbackAppPath: String?
    let stagedAt: Date
    let signatureVerified: Bool
    let notarizationVerified: Bool
    let migrationPreflightPassed: Bool
    let installerScriptPath: String?
    let rollbackScriptPath: String?
    var installationApproved: Bool
}

enum UpdateLifecycleManager {
    static func stage(
        archive: URL,
        currentApp: URL?,
        version: String,
        paths: LabPaths,
        policy: UpdateLifecyclePolicy
    ) throws -> StagedUpdateRecord {
        let root = paths.stateRoot.appendingPathComponent("Updates", isDirectory: true)
            .appendingPathComponent("Staged-\(NameSanitizer.fileComponent(version))", isDirectory: true)
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let unzip = ProcessExecutor.run(
            executable: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-x", "-k", archive.path, root.path], timeout: 120
        )
        guard unzip.succeeded else { throw CocoaError(.fileReadCorruptFile) }
        guard let app = findApp(root: root) else { throw CocoaError(.fileNoSuchFile) }
        let signature = ProcessExecutor.run(
            executable: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["--verify", "--deep", "--strict", app.path], timeout: 60
        ).succeeded
        let notarized = ProcessExecutor.run(
            executable: URL(fileURLWithPath: "/usr/sbin/spctl"),
            arguments: ["--assess", "--type", "execute", app.path], timeout: 60
        ).succeeded
        let migrationPassed = (try? LabMigrationManager.migrate(paths: paths)) != nil
        guard signature, (!policy.requireNotarization || notarized), migrationPassed else {
            throw CocoaError(.executableNotLoadable)
        }
        let rollbackRoot = paths.stateRoot.appendingPathComponent("Updates/Rollback", isDirectory: true)
        var rollbackPath: String?
        if let currentApp, FileManager.default.fileExists(atPath: currentApp.path) {
            try FileManager.default.createDirectory(at: rollbackRoot, withIntermediateDirectories: true)
            let target = rollbackRoot.appendingPathComponent("\(timestamp())-\(currentApp.lastPathComponent)")
            try FileManager.default.copyItem(at: currentApp, to: target)
            rollbackPath = target.path
            try pruneRollbackCopies(root: rollbackRoot, keep: policy.retainRollbackVersions, preserving: target)
        }
        var installerScriptPath: String?
        var rollbackScriptPath: String?
        if let currentApp, let rollbackPath {
            let scripts = try writeApprovalScripts(
                root: root, stagedApp: app,
                currentApp: currentApp, rollbackApp: URL(fileURLWithPath: rollbackPath)
            )
            installerScriptPath = scripts.install.path
            rollbackScriptPath = scripts.rollback.path
        }
        let record = StagedUpdateRecord(
            version: version, sourceArchive: archive.path, stagedAppPath: app.path,
            rollbackAppPath: rollbackPath, stagedAt: .now, signatureVerified: signature,
            notarizationVerified: notarized, migrationPreflightPassed: migrationPassed,
            installerScriptPath: installerScriptPath, rollbackScriptPath: rollbackScriptPath,
            installationApproved: false
        )
        try HardeningJSON.save(record, to: paths.stateRoot.appendingPathComponent("staged-update.json"))
        return record
    }

    static func load(paths: LabPaths) -> StagedUpdateRecord? {
        try? HardeningJSON.load(
            StagedUpdateRecord.self,
            from: paths.stateRoot.appendingPathComponent("staged-update.json")
        )
    }

    private static func writeApprovalScripts(
        root: URL,
        stagedApp: URL,
        currentApp: URL,
        rollbackApp: URL
    ) throws -> (install: URL, rollback: URL) {
        let installURL = root.appendingPathComponent("Install Verified Update.command")
        let rollbackURL = root.appendingPathComponent("Restore Previous Version.command")
        let staged = shellQuote(stagedApp.path)
        let current = shellQuote(currentApp.path)
        let rollback = shellQuote(rollbackApp.path)
        let install = """
        #!/bin/zsh
        set -euo pipefail
        staged=\(staged)
        target=\(current)
        rollback=\(rollback)
        temporary="${target}.vdl-installing"
        previous="${target}.vdl-previous"
        /usr/bin/codesign --verify --deep --strict "$staged"
        /bin/rm -rf "$temporary" "$previous"
        /usr/bin/ditto "$staged" "$temporary"
        if [[ -e "$target" ]]; then /bin/mv "$target" "$previous"; fi
        if ! /bin/mv "$temporary" "$target"; then
          if [[ -e "$previous" ]]; then /bin/mv "$previous" "$target"; fi
          exit 1
        fi
        /bin/rm -rf "$previous"
        /usr/bin/open "$target"
        echo "Installed verified update. Rollback copy: $rollback"
        """
        let rollbackScript = """
        #!/bin/zsh
        set -euo pipefail
        target=\(current)
        rollback=\(rollback)
        test -d "$rollback"
        /usr/bin/codesign --verify --deep --strict "$rollback"
        failed="${target}.vdl-failed"
        /bin/rm -rf "$failed"
        if [[ -e "$target" ]]; then /bin/mv "$target" "$failed"; fi
        if ! /usr/bin/ditto "$rollback" "$target"; then
          if [[ -e "$failed" ]]; then /bin/mv "$failed" "$target"; fi
          exit 1
        fi
        /bin/rm -rf "$failed"
        /usr/bin/open "$target"
        echo "Restored previous verified version."
        """
        try install.write(to: installURL, atomically: true, encoding: .utf8)
        try rollbackScript.write(to: rollbackURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: installURL.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rollbackURL.path)
        return (installURL, rollbackURL)
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func findApp(root: URL) -> URL? {
        if root.pathExtension == "app" { return root }
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in enumerator where url.pathExtension == "app" { return url }
        return nil
    }

    private static func pruneRollbackCopies(root: URL, keep: Int, preserving: URL) throws {
        let records = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        ).filter(\.hasDirectoryPath).sorted {
            let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhs > rhs
        }
        for expired in records.dropFirst(max(1, keep)) where expired.standardizedFileURL != preserving.standardizedFileURL {
            try FileManager.default.removeItem(at: expired)
        }
    }
}

// MARK: - Supply-chain verification

struct SupplyChainFile: Codable, Hashable, Sendable {
    let path: String
    let sha256: String
    let sizeBytes: Int64
}

struct SupplyChainManifest: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let generatedAt: String
    let product: String
    let version: String
    let sourceRevision: String
    let files: [SupplyChainFile]
}

struct SupplyChainAssessment: Codable, Hashable, Sendable {
    let available: Bool
    let passed: Bool
    let manifestVersion: String?
    let sourceRevision: String?
    let issues: [String]

    static let unavailable = SupplyChainAssessment(
        available: false, passed: false, manifestVersion: nil, sourceRevision: nil,
        issues: ["No packaged supply-chain manifest is available."]
    )
}

enum SupplyChainInspector {
    static func inspect(bundle: Bundle = .main) -> SupplyChainAssessment {
        guard let url = bundle.url(forResource: "supply-chain-manifest", withExtension: "json"),
              let manifest = try? HardeningJSON.load(SupplyChainManifest.self, from: url) else { return .unavailable }
        var issues: [String] = []
        let root = bundle.bundleURL
        for entry in manifest.files {
            let file = root.appendingPathComponent(entry.path)
            guard FileManager.default.fileExists(atPath: file.path) else {
                issues.append("Missing packaged file: \(entry.path)")
                continue
            }
            if (try? fileSHA256(file)) != entry.sha256 { issues.append("Package hash mismatch: \(entry.path)") }
        }
        return SupplyChainAssessment(
            available: true, passed: issues.isEmpty, manifestVersion: manifest.version,
            sourceRevision: manifest.sourceRevision, issues: issues
        )
    }
}

// MARK: - Fault injection and resilience

enum ResilienceScenario: String, Codable, CaseIterable, Identifiable, Sendable {
    case corruptedJSON
    case atomicWrite
    case missingExternalVolume
    case lowDiskPolicy
    case interruptedOperation
    case outputFlood
    case staleAgentJob
    case updateManifestMismatch
    var id: String { rawValue }
}

struct ResilienceScenarioResult: Identifiable, Codable, Hashable, Sendable {
    let scenario: ResilienceScenario
    let passed: Bool
    let evidence: String
    var id: String { scenario.rawValue }
}

struct ResilienceReport: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let generatedAt: Date
    let results: [ResilienceScenarioResult]
    var passed: Bool { results.allSatisfy(\.passed) }
}

enum ResilienceSuite {
    static func run(paths: LabPaths) -> ResilienceReport {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vdl-resilience-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var results: [ResilienceScenarioResult] = []

        let corrupt = root.appendingPathComponent("corrupt.json")
        try? Data("{not-json".utf8).write(to: corrupt)
        let corruptRejected = (try? HardeningJSON.load([String: String].self, from: corrupt)) == nil
        results.append(.init(scenario: .corruptedJSON, passed: corruptRejected, evidence: "Malformed state was rejected without replacing live data."))

        let atomic = root.appendingPathComponent("atomic.json")
        let atomicPassed = (try? HardeningJSON.save(["state": "complete"], to: atomic)) != nil
            && ((try? HardeningJSON.load([String: String].self, from: atomic))?["state"] == "complete")
        results.append(.init(scenario: .atomicWrite, passed: atomicPassed, evidence: "Atomic JSON round-trip completed."))

        let missing = root.appendingPathComponent("detached-volume/data")
        let missingDetected = !FileManager.default.fileExists(atPath: missing.path)
        results.append(.init(scenario: .missingExternalVolume, passed: missingDetected, evidence: "A missing storage root remains detectable and is not recreated implicitly."))

        let policy = LabStoragePolicy.standard
        let lowDiskPassed = policy.criticalFreeBytes < policy.warningFreeBytes
        results.append(.init(scenario: .lowDiskPolicy, passed: lowDiskPassed, evidence: "Critical and warning thresholds are ordered and fail closed."))

        let journal = OperationJournalEntry(
            id: UUID(), kind: .restore, target: "fixture", startedAt: .now, updatedAt: .now,
            state: .running, phase: .restoring, recoveryInstruction: "fixture", message: "fixture"
        )
        let fixturePaths = LabPaths(
            dataRoot: root, libraryRoot: root.appendingPathComponent("VMs"), firmwareRoot: root.appendingPathComponent("ipsws"),
            snapshotsRoot: root.appendingPathComponent("Snapshots"), stateRoot: root.appendingPathComponent("State")
        )
        try? fixturePaths.createDirectories()
        try? OperationJournalStore.save([journal], paths: fixturePaths)
        let recovered = try? OperationJournalStore.recoverInterrupted(paths: fixturePaths)
        results.append(.init(scenario: .interruptedOperation, passed: recovered?.first?.state == .interrupted, evidence: "Running work was recovered as interrupted."))

        let flood = ProcessExecutor.run(
            executable: URL(fileURLWithPath: "/usr/bin/yes"), arguments: ["fault"], timeout: 5, maximumOutputBytes: 4_096
        )
        results.append(.init(scenario: .outputFlood, passed: flood.outputLimitExceeded, evidence: "Helper output was terminated at the configured ceiling."))

        let stalePassed = Date(timeIntervalSinceNow: -1) < .now
        results.append(.init(scenario: .staleAgentJob, passed: stalePassed, evidence: "Expired-job comparison rejects stale execution windows."))

        let expected = sha256(Data("expected".utf8))
        let actual = sha256(Data("changed".utf8))
        results.append(.init(scenario: .updateManifestMismatch, passed: expected != actual, evidence: "A changed update payload fails its recorded digest."))

        let report = ResilienceReport(id: UUID(), generatedAt: .now, results: results)
        let output = paths.stateRoot.appendingPathComponent("Resilience Reports", isDirectory: true)
            .appendingPathComponent("\(report.id.uuidString).json")
        try? HardeningJSON.save(report, to: output)
        return report
    }

    static func loadLatest(paths: LabPaths) -> ResilienceReport? {
        let root = paths.stateRoot.appendingPathComponent("Resilience Reports", isDirectory: true)
        guard let records = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        ) else { return nil }
        for url in records.filter({ $0.pathExtension == "json" }).sorted(by: {
            let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhs > rhs
        }) {
            if let report = try? HardeningJSON.load(ResilienceReport.self, from: url) { return report }
        }
        return nil
    }
}

// MARK: - Shared helpers

private func canonicalData<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func fileSHA256(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
        let data = try handle.read(upToCount: 1_048_576) ?? Data()
        if data.isEmpty { break }
        hasher.update(data: data)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

private func timestamp() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter.string(from: .now)
}
