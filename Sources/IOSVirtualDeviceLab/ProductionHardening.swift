import CryptoKit
import Foundation
import Security

// MARK: - Acceptance definitions and evidence

enum AcceptanceGateKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case hostPreflight
    case firmwareIdentity
    case bootAndGuestControl
    case networking
    case audio
    case appDeployment
    case snapshotRestore
    case diagnostics
    case stability

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hostPreflight: "Host preflight"
        case .firmwareIdentity: "Firmware and hardware identity"
        case .bootAndGuestControl: "Boot and guest control"
        case .networking: "Networking"
        case .audio: "Audio"
        case .appDeployment: "Application deployment"
        case .snapshotRestore: "Snapshot and restore"
        case .diagnostics: "Diagnostics export"
        case .stability: "Sustained stability"
        }
    }
}

enum AcceptanceGateStatus: String, Codable, Sendable {
    case passed
    case pending
    case blocked
    case failed
}

struct AcceptanceGateResult: Identifiable, Codable, Hashable, Sendable {
    let kind: AcceptanceGateKind
    let status: AcceptanceGateStatus
    let evidence: String
    let requiredEvidence: String
    var id: String { kind.rawValue }
}

struct AcceptanceReport: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let generatedAt: Date
    let deviceName: String?
    let gates: [AcceptanceGateResult]

    static let empty = AcceptanceReport(schemaVersion: 1, generatedAt: .distantPast, deviceName: nil, gates: [])
    var isPassed: Bool { !gates.isEmpty && gates.allSatisfy { $0.status == .passed } }
}

enum AcceptanceEvaluator {
    static func evaluate(
        host: HostReadiness,
        device: VirtualDevice?,
        testRuns: [TestRunRecord],
        capabilities: BackendCapabilities,
        handshake: GuestProtocolHandshake?
    ) -> AcceptanceReport {
        let baseline = testRuns.first { run in
            run.kind == .baselineAcceptance && (device == nil || run.results.contains { $0.deviceName == device?.name })
        }
        let assertionResults = baseline?.results.flatMap { $0.assertionResults ?? [] } ?? []
        let baselinePassed = baseline?.state == .passed
        func assertion(_ kind: TestAssertionKind) -> Bool {
            assertionResults.contains { $0.assertion.kind == kind && $0.passed }
        }
        func result(
            _ kind: AcceptanceGateKind,
            _ passed: Bool,
            available: Bool = true,
            evidence: String,
            required: String
        ) -> AcceptanceGateResult {
            AcceptanceGateResult(
                kind: kind,
                status: passed ? .passed : (available ? .pending : .blocked),
                evidence: evidence,
                requiredEvidence: required
            )
        }

        let hostGate = result(
            .hostPreflight,
            host.isReady,
            available: host.state != .unavailable,
            evidence: host.isReady ? "Host and backend preflight passed at \(host.checkedAt.formatted())" : host.researchGuestsStatus,
            required: "Apple silicon, compatible macOS, research-guest policy, and a runnable backend"
        )
        let identityPassed = device?.restoreInfo != nil && device?.hardwareProfileID != nil
        let identityGate = result(
            .firmwareIdentity,
            identityPassed,
            available: device != nil,
            evidence: identityPassed ? "\(device?.iosLabel ?? "iOS") is paired with hardware profile \(device?.hardwareProfileID ?? "")" : "No validated device/profile pairing",
            required: "BuildManifest identity must match a versioned virtual hardware profile"
        )
        let guestPassed = assertion(.guestReady)
            && handshake?.status == .compatible
            && handshake?.negotiatedVersion == 3
            && handshake?.authenticated == true
            && handshake?.replayProtected == true
            && (handshake?.authenticationClockSkewSeconds ?? .max) <= 30
        let bootGate = result(
            .bootAndGuestControl,
            guestPassed,
            available: host.isReady && device != nil,
            evidence: guestPassed ? "Baseline run connected using authenticated guest protocol v\(handshake?.negotiatedVersion ?? 0)" : "No authenticated real-guest handshake evidence",
            required: "Boot, input, screenshot, and an authenticated negotiated guest-control handshake"
        )
        let networkGate = result(
            .networking,
            assertion(.networkMode),
            available: capabilities.networking,
            evidence: assertion(.networkMode) ? "Network assertion passed in the baseline run" : "Network policy is available but has not passed a real-guest assertion",
            required: "Verify the selected mode, connectivity, isolation, and failure behavior"
        )
        let audioGate = result(
            .audio,
            assertion(.audioConfigured),
            available: capabilities.audio,
            evidence: assertion(.audioConfigured) ? "Audio assertion passed in the baseline run" : "Runtime audio capability exists without playback evidence",
            required: "Verify audible playback, routing, interruption, and background behavior where supported"
        )
        let deploymentGate = result(
            .appDeployment,
            assertion(.launchSucceeded),
            available: capabilities.xcodeDeployment,
            evidence: assertion(.launchSucceeded) ? "Deployment assertion passed" : "No successful real-guest deployment evidence",
            required: "Install and launch a signed test application through guest control"
        )
        let snapshotGate = result(
            .snapshotRestore,
            baselinePassed,
            available: device != nil,
            evidence: baselinePassed ? "Baseline acceptance completed snapshot, verification, restore, and cleanup" : "Baseline acceptance has not passed",
            required: "Create, checksum, restore as a new device, boot, and clean up"
        )
        let diagnosticsGate = result(
            .diagnostics,
            assertion(.diagnosticsCollected),
            available: capabilities.crashExport,
            evidence: assertion(.diagnosticsCollected) ? "Sanitized diagnostic evidence was collected" : "No passing diagnostic assertion",
            required: "Export bounded guest logs/crashes plus sanitized host evidence"
        )
        let stabilityGate = result(
            .stability,
            baselinePassed && assertion(.maximumDuration),
            available: host.isReady && device != nil,
            evidence: baselinePassed ? "Baseline passed; add a duration assertion for sustained evidence" : "No sustained passing baseline",
            required: "Complete the full workflow within a declared duration without VM or app crashes"
        )
        return AcceptanceReport(
            schemaVersion: 1,
            generatedAt: .now,
            deviceName: device?.name,
            gates: [hostGate, identityGate, bootGate, networkGate, audioGate, deploymentGate, snapshotGate, diagnosticsGate, stabilityGate]
        )
    }
}

// MARK: - Host compatibility and upgrade guard

enum HostCompatibilityStatus: String, Codable, Sendable {
    case validated
    case experimental
    case unverified
    case incompatible
}

struct HostCompatibilityRecord: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let macOSPrefixes: [String]
    let modelPrefixes: [String]
    let backendVersionPrefixes: [String]
    let iosMajorVersions: [Int]
    let status: HostCompatibilityStatus
    let evidence: String
    let updatedAt: String

    func matches(macOS: String, model: String, backendVersion: String?, iosMajor: Int?) -> Bool {
        let osMatches = macOSPrefixes.contains("*") || macOSPrefixes.contains { macOS.hasPrefix($0) }
        let modelMatches = modelPrefixes.contains("*") || modelPrefixes.contains { model.hasPrefix($0) }
        let backendMatches = backendVersionPrefixes.contains("*")
            || backendVersion.map { version in backendVersionPrefixes.contains { version.hasPrefix($0) } } == true
        let iosMatches = iosMajor == nil || iosMajorVersions.isEmpty || iosMajorVersions.contains(iosMajor!)
        return osMatches && modelMatches && backendMatches && iosMatches
    }
}

struct HostCompatibilityCatalog: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let records: [HostCompatibilityRecord]
    static let empty = HostCompatibilityCatalog(schemaVersion: 1, records: [])
}

struct HostCompatibilityAssessment: Codable, Hashable, Sendable {
    let status: HostCompatibilityStatus
    let message: String
    let recordID: String?
    static let unverified = HostCompatibilityAssessment(status: .unverified, message: "This host/backend/iOS combination has no recorded evidence.", recordID: nil)
}

enum HostCompatibilityDatabase {
    static func load(paths: LabPaths) -> HostCompatibilityCatalog {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("host-compatibility.json"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/host-compatibility.json"),
            paths.stateRoot.appendingPathComponent("host-compatibility.json"),
        ].compactMap { $0 }
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            if let value = try? HardeningJSON.load(HostCompatibilityCatalog.self, from: url) { return value }
        }
        return .empty
    }

    static func assess(
        catalog: HostCompatibilityCatalog,
        host: HostReadiness,
        backendVersion: String?,
        device: VirtualDevice?
    ) -> HostCompatibilityAssessment {
        assessTarget(
            catalog: catalog,
            macOSVersion: host.macOSVersion,
            model: host.model,
            backendVersion: backendVersion,
            iosVersion: device?.restoreInfo?.ios.version
        )
    }

    static func assessTarget(
        catalog: HostCompatibilityCatalog,
        macOSVersion: String,
        model: String,
        backendVersion: String?,
        iosVersion: String?
    ) -> HostCompatibilityAssessment {
        let iosMajor = iosVersion?.split(separator: ".").first.flatMap { Int($0) }
        guard let record = catalog.records.first(where: {
            $0.matches(macOS: macOSVersion, model: model, backendVersion: backendVersion, iosMajor: iosMajor)
        }) else { return .unverified }
        return HostCompatibilityAssessment(status: record.status, message: record.evidence, recordID: record.id)
    }
}

// MARK: - Schema migrations and rollback

struct LabMigrationRecord: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let fromVersion: Int
    let toVersion: Int
    let appliedAt: Date
    let backupPath: String?
    let summary: String
}

struct LabMigrationState: Codable, Hashable, Sendable {
    var schemaVersion: Int
    var history: [LabMigrationRecord]
    static let initial = LabMigrationState(schemaVersion: 0, history: [])
}

struct LabMigrationReport: Codable, Hashable, Sendable {
    let sourceVersion: Int
    let destinationVersion: Int
    let applied: [LabMigrationRecord]
    let latestBackupPath: String?
    static let none = LabMigrationReport(sourceVersion: 0, destinationVersion: 0, applied: [], latestBackupPath: nil)
}

enum LabMigrationManager {
    static let currentSchemaVersion = 5
    private static let managedFiles = [
        "activity.json", "automation-workflows.json", "compatibility-manifest.json",
        "diagnostic-privacy.json", "environment-assignments.json", "environment-profiles.json",
        "firmware-catalog.json", "operation-journal.json", "plugin-audit.json",
        "remote-agent.json", "resource-policy.json", "snapshot-retention.json",
        "storage-policy.json", "test-runs.json", "qualification-campaigns.json",
        "guest-trust-policy.json", "backup-policy.json", "update-lifecycle-policy.json",
        "evidence-ledger.json", "resilience-reports.json", "recovery-decisions.json",
        "canonical-fixtures.json", "evidence-lifecycle-policy.json", "host-capacity.json",
        "hostile-input-report.json", "unified-retention-policy.json",
        "operational-objective-policy.json", "beta-verification.json",
    ]

    static func migrate(paths: LabPaths) throws -> LabMigrationReport {
        let marker = paths.stateRoot.appendingPathComponent("lab-schema.json")
        var state = (try? HardeningJSON.load(LabMigrationState.self, from: marker)) ?? .initial
        let source = state.schemaVersion
        guard source < currentSchemaVersion else {
            return LabMigrationReport(
                sourceVersion: source,
                destinationVersion: state.schemaVersion,
                applied: [],
                latestBackupPath: state.history.last?.backupPath
            )
        }
        let backup = try backupManagedState(paths: paths, fromVersion: source)
        var applied: [LabMigrationRecord] = []
        for destination in (source + 1)...currentSchemaVersion {
            let summary: String
            switch destination {
            case 1:
                summary = "Established versioned lab state and rollback metadata."
            case 2:
                summary = "Added operational-readiness, provenance, environment, journal, and agent schemas."
            case 3:
                summary = "Added qualification, guest trust, evidence governance, backup, update, supply-chain, and resilience schemas."
            case 4:
                summary = "Added full-lab encrypted recovery, companion contracts, credential lifecycle, locked state, launch forensics, and update health rollback."
            default:
                summary = "Added storage relinking, Recovery Center decisions, canonical fixtures, Labfiles, evidence expiry, host calibration, hostile-input boundaries, unified retention, SLOs, and beta verification."
            }
            let record = LabMigrationRecord(
                id: UUID(),
                fromVersion: destination - 1,
                toVersion: destination,
                appliedAt: .now,
                backupPath: backup?.path,
                summary: summary
            )
            state.schemaVersion = destination
            state.history.append(record)
            applied.append(record)
        }
        try HardeningJSON.save(state, to: marker)
        return LabMigrationReport(
            sourceVersion: source,
            destinationVersion: state.schemaVersion,
            applied: applied,
            latestBackupPath: backup?.path
        )
    }

    static func restoreLatestBackup(paths: LabPaths) throws -> URL {
        let marker = paths.stateRoot.appendingPathComponent("lab-schema.json")
        let state = try HardeningJSON.load(LabMigrationState.self, from: marker)
        guard let path = state.history.reversed().compactMap(\.backupPath).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        let backup = URL(fileURLWithPath: path)
        for file in managedFiles {
            let source = backup.appendingPathComponent(file)
            let destination = paths.stateRoot.appendingPathComponent(file)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
        }
        return backup
    }

    private static func backupManagedState(paths: LabPaths, fromVersion: Int) throws -> URL? {
        let existing = managedFiles.filter {
            FileManager.default.fileExists(atPath: paths.stateRoot.appendingPathComponent($0).path)
        }
        guard !existing.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let root = paths.stateRoot.appendingPathComponent("Migration Backups", isDirectory: true)
            .appendingPathComponent("v\(fromVersion)-\(formatter.string(from: .now))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for file in existing {
            try FileManager.default.copyItem(
                at: paths.stateRoot.appendingPathComponent(file),
                to: root.appendingPathComponent(file)
            )
        }
        return root
    }
}

// MARK: - Crash-safe operation journal

enum JournalEntryState: String, Codable, Sendable {
    case queued
    case running
    case completed
    case failed
    case interrupted
    case resolved
}

struct OperationJournalEntry: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let kind: LabOperationKind
    let target: String
    let startedAt: Date
    var updatedAt: Date
    var state: JournalEntryState
    var phase: LabOperationPhase
    var recoveryInstruction: String
    var message: String
}

enum OperationJournalStore {
    private static func url(paths: LabPaths) -> URL {
        paths.stateRoot.appendingPathComponent("operation-journal.json")
    }

    static func load(paths: LabPaths) -> [OperationJournalEntry] {
        (try? HardeningJSON.load([OperationJournalEntry].self, from: url(paths: paths))) ?? []
    }

    static func save(_ entries: [OperationJournalEntry], paths: LabPaths) throws {
        try HardeningJSON.save(Array(entries.prefix(500)), to: url(paths: paths))
    }

    static func recoverInterrupted(paths: LabPaths) throws -> [OperationJournalEntry] {
        var entries = load(paths: paths)
        var changed = false
        for index in entries.indices where [.queued, .running].contains(entries[index].state) {
            entries[index].state = .interrupted
            entries[index].phase = .failed
            entries[index].updatedAt = .now
            entries[index].message = "The previous app session ended before this operation recorded completion."
            changed = true
        }
        if changed { try save(entries, paths: paths) }
        return entries
    }
}

// MARK: - Reproducible environment profiles

enum LabAppearance: String, Codable, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark
    var id: String { rawValue }
}

enum SimulatedPressure: String, Codable, CaseIterable, Identifiable, Sendable {
    case normal
    case warning
    case critical
    var id: String { rawValue }
}

struct NetworkConditionProfile: Codable, Hashable, Sendable {
    var latencyMilliseconds: Int
    var downstreamKbps: Int?
    var upstreamKbps: Int?
    var packetLossPercent: Double
}

struct SimulatedLocation: Codable, Hashable, Sendable {
    var latitude: Double
    var longitude: Double
    var name: String
}

struct EnvironmentProfile: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var localeIdentifier: String
    var timeZoneIdentifier: String
    var appearance: LabAppearance
    var contentSizeCategory: String
    var orientation: String
    var lowPowerMode: Bool
    var storagePressure: SimulatedPressure
    var thermalPressure: SimulatedPressure
    var location: SimulatedLocation?
    var networkCondition: NetworkConditionProfile
    var permissionDecisions: [String: String]
    var isBuiltIn: Bool
}

enum EnvironmentProfileStore {
    static let builtIns: [EnvironmentProfile] = [
        EnvironmentProfile(
            id: UUID(uuidString: "E0000000-0000-4000-8000-000000000001")!,
            name: "Default Test Device", localeIdentifier: "en_CA", timeZoneIdentifier: "America/Toronto",
            appearance: .system, contentSizeCategory: "large", orientation: "portrait",
            lowPowerMode: false, storagePressure: .normal, thermalPressure: .normal, location: nil,
            networkCondition: NetworkConditionProfile(latencyMilliseconds: 0, downstreamKbps: nil, upstreamKbps: nil, packetLossPercent: 0),
            permissionDecisions: [:], isBuiltIn: true
        ),
        EnvironmentProfile(
            id: UUID(uuidString: "E0000000-0000-4000-8000-000000000002")!,
            name: "Adverse Mobile Network", localeIdentifier: "en_CA", timeZoneIdentifier: "America/Toronto",
            appearance: .dark, contentSizeCategory: "accessibilityExtraExtraExtraLarge", orientation: "portrait",
            lowPowerMode: true, storagePressure: .warning, thermalPressure: .warning,
            location: SimulatedLocation(latitude: 43.6532, longitude: -79.3832, name: "Toronto"),
            networkCondition: NetworkConditionProfile(latencyMilliseconds: 250, downstreamKbps: 1_000, upstreamKbps: 256, packetLossPercent: 2),
            permissionDecisions: ["microphone": "denied", "notifications": "allowed"], isBuiltIn: true
        ),
    ]

    static func load(paths: LabPaths) -> [EnvironmentProfile] {
        let url = paths.stateRoot.appendingPathComponent("environment-profiles.json")
        let custom = (try? HardeningJSON.load([EnvironmentProfile].self, from: url)) ?? []
        return builtIns + custom.filter { !$0.isBuiltIn }
    }

    static func saveCustom(_ profiles: [EnvironmentProfile], paths: LabPaths) throws {
        try HardeningJSON.save(profiles.filter { !$0.isBuiltIn }, to: paths.stateRoot.appendingPathComponent("environment-profiles.json"))
    }

    static func loadAssignments(paths: LabPaths) -> [String: UUID] {
        (try? HardeningJSON.load([String: UUID].self, from: paths.stateRoot.appendingPathComponent("environment-assignments.json"))) ?? [:]
    }

    static func saveAssignments(_ assignments: [String: UUID], paths: LabPaths) throws {
        try HardeningJSON.save(assignments, to: paths.stateRoot.appendingPathComponent("environment-assignments.json"))
    }
}

// MARK: - Guest protocol negotiation

enum GuestProtocolStatus: String, Codable, Sendable {
    case compatible
    case legacy
    case incompatible
    case unavailable
}

enum GuestCapability: String, Codable, CaseIterable, Sendable {
    case screenshots = "screenshots"
    case hardwareKeys = "hardware_keys"
    case guestFiles = "guest_files"
    case audioOutput = "audio_output"
    case audioInput = "audio_input"
    case networking = "network_modes"
    case environmentPolicy = "environment_policy"
    case accessibilityTree = "accessibility_tree"
}

struct GuestProtocolHandshake: Codable, Hashable, Sendable {
    let status: GuestProtocolStatus
    let negotiatedVersion: Int?
    let minimumSupportedVersion: Int
    let maximumSupportedVersion: Int
    let capabilities: Set<GuestCapability>
    let maximumMessageBytes: Int
    let authenticated: Bool
    let replayProtected: Bool
    let authenticationClockSkewSeconds: Int?
    let transport: String
    let message: String

    static let unavailable = GuestProtocolHandshake(
        status: .unavailable, negotiatedVersion: nil, minimumSupportedVersion: 1,
        maximumSupportedVersion: 3, capabilities: [], maximumMessageBytes: 0,
        authenticated: false, replayProtected: false, authenticationClockSkewSeconds: nil,
        transport: "Unix domain socket", message: "Guest control is unavailable."
    )
}

enum GuestProtocolNegotiator {
    static let supported = 1...3

    static func negotiate(json: [String: Any]?) -> GuestProtocolHandshake {
        guard let json else { return .unavailable }
        let version = json["protocol_version"] as? Int ?? 1
        let capabilities = Set(GuestCapability.allCases.filter { capability in
            json[capability.rawValue] as? Bool == true
                || (json["capabilities"] as? [String])?.contains(capability.rawValue) == true
                || (capability == .networking && json["network_modes"] as? [String] != nil)
        })
        let status: GuestProtocolStatus = supported.contains(version) ? (version == 1 ? .legacy : .compatible) : .incompatible
        return GuestProtocolHandshake(
            status: status,
            negotiatedVersion: supported.contains(version) ? version : nil,
            minimumSupportedVersion: supported.lowerBound,
            maximumSupportedVersion: supported.upperBound,
            capabilities: capabilities,
            maximumMessageBytes: json["maximum_message_bytes"] as? Int ?? 1_048_576,
            authenticated: json["authenticated"] as? Bool ?? false,
            replayProtected: json["replay_protection"] as? Bool ?? false,
            authenticationClockSkewSeconds: json["authentication_clock_skew_seconds"] as? Int,
            transport: "Unix domain socket",
            message: status == .incompatible
                ? "Guest protocol v\(version) is outside the supported range \(supported.lowerBound)-\(supported.upperBound)."
                : "Negotiated guest protocol v\(version) with \(capabilities.count) capability declaration(s)."
        )
    }
}

// MARK: - Storage lifecycle

struct LabStoragePolicy: Codable, Hashable, Sendable {
    var maximumLabBytes: Int64
    var warningFreeBytes: Int64
    var criticalFreeBytes: Int64
    var automaticSnapshotPruning: Bool
    var flagDuplicateFirmware: Bool
    var verifyArchivesBeforeExport: Bool

    static let standard = LabStoragePolicy(
        maximumLabBytes: 750 * 1_073_741_824,
        warningFreeBytes: 100 * 1_073_741_824,
        criticalFreeBytes: 25 * 1_073_741_824,
        automaticSnapshotPruning: false,
        flagDuplicateFirmware: true,
        verifyArchivesBeforeExport: true
    )
}

struct DuplicateFirmwareGroup: Identifiable, Codable, Hashable, Sendable {
    let sha256: String
    let paths: [String]
    var id: String { sha256 }
}

struct LabStorageInventory: Codable, Hashable, Sendable {
    let scannedAt: Date
    let virtualMachineBytes: Int64
    let firmwareBytes: Int64
    let snapshotBytes: Int64
    let labStateBytes: Int64
    let availableBytes: Int64
    let duplicateFirmware: [DuplicateFirmwareGroup]
    let warnings: [String]

    static let empty = LabStorageInventory(
        scannedAt: .distantPast, virtualMachineBytes: 0, firmwareBytes: 0,
        snapshotBytes: 0, labStateBytes: 0, availableBytes: 0, duplicateFirmware: [], warnings: []
    )
    var totalManagedBytes: Int64 { virtualMachineBytes + firmwareBytes + snapshotBytes + labStateBytes }
}

enum StorageLifecycleManager {
    static func loadPolicy(paths: LabPaths) -> LabStoragePolicy {
        (try? HardeningJSON.load(LabStoragePolicy.self, from: paths.stateRoot.appendingPathComponent("storage-policy.json"))) ?? .standard
    }

    static func savePolicy(_ policy: LabStoragePolicy, paths: LabPaths) throws {
        try HardeningJSON.save(policy, to: paths.stateRoot.appendingPathComponent("storage-policy.json"))
    }

    static func scan(
        paths: LabPaths,
        devices: [VirtualDevice],
        firmware: [FirmwareImage],
        snapshots: [SnapshotRecord],
        policy: LabStoragePolicy
    ) -> LabStorageInventory {
        let vmBytes = devices.reduce(Int64(0)) { $0 + $1.diskSizeBytes }
        let firmwareBytes = firmware.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let snapshotBytes = snapshots.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let stateBytes = directoryBytes(paths.stateRoot, excluding: ["App Artifacts", "Diagnostics"])
        let available = (try? paths.dataRoot.resolvingSymlinksInPath().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        let duplicates = Dictionary(grouping: firmware.filter { $0.sha256 != nil }, by: { $0.sha256! })
            .filter { $0.value.count > 1 }
            .map { DuplicateFirmwareGroup(sha256: $0.key, paths: $0.value.map(\.path).sorted()) }
            .sorted { $0.sha256 < $1.sha256 }
        var warnings: [String] = []
        let total = vmBytes + firmwareBytes + snapshotBytes + stateBytes
        if total > policy.maximumLabBytes { warnings.append("Managed lab data exceeds its configured quota.") }
        if available < policy.criticalFreeBytes { warnings.append("Free storage is below the critical reserve.") }
        else if available < policy.warningFreeBytes { warnings.append("Free storage is below the warning reserve.") }
        if policy.flagDuplicateFirmware && !duplicates.isEmpty { warnings.append("Duplicate IPSW content was detected by SHA-256.") }
        return LabStorageInventory(
            scannedAt: .now, virtualMachineBytes: vmBytes, firmwareBytes: firmwareBytes,
            snapshotBytes: snapshotBytes, labStateBytes: stateBytes, availableBytes: available,
            duplicateFirmware: duplicates, warnings: warnings
        )
    }

    static func exportConfiguration(paths: LabPaths, destination: URL) throws -> URL {
        let root = destination.appendingPathComponent("VirtualDeviceLab-Portable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let names = [
            "automation-workflows.json", "compatibility-manifest.json", "environment-profiles.json",
            "hardware-profiles.json", "resource-policy.json", "snapshot-retention.json", "storage-policy.json",
        ]
        for name in names {
            let source = paths.stateRoot.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.copyItem(at: source, to: root.appendingPathComponent(name))
            }
        }
        let manifest: [String: String] = [
            "schemaVersion": String(LabMigrationManager.currentSchemaVersion),
            "createdAt": ISO8601DateFormatter().string(from: .now),
            "notice": "Configuration only. Apple firmware, VM disks, secrets, and signing identities are intentionally excluded.",
        ]
        try HardeningJSON.save(manifest, to: root.appendingPathComponent("manifest.json"))
        return root
    }

    private static func directoryBytes(_ root: URL, excluding excludedNames: Set<String>) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileAllocatedSizeKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            if excludedNames.contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileAllocatedSizeKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileAllocatedSize ?? values.fileSize ?? 0)
        }
        return total
    }
}

// MARK: - Firmware provenance

enum FirmwareSourceKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case localImport
    case appleDeveloper
    case userArchive
    case researchFixture
    var id: String { rawValue }
}

enum FirmwareSigningStatus: String, Codable, Sendable {
    case unknown
    case manifestPresent
    case verifiedMetadata
    case invalid
}

enum FirmwareRetentionPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case keep
    case archiveAfterValidation
    case removeWhenUnused
    var id: String { rawValue }
}

struct FirmwareProvenance: Codable, Hashable, Sendable {
    var sourceKind: FirmwareSourceKind
    var sourceDescription: String
    var importedBy: String
    var importedAt: Date
    var checksumSHA256: String?
    var signingStatus: FirmwareSigningStatus
    var ownershipNote: String
    var retentionPolicy: FirmwareRetentionPolicy

    static func localImport(path: String, importedAt: Date) -> FirmwareProvenance {
        FirmwareProvenance(
            sourceKind: .localImport,
            sourceDescription: path,
            importedBy: NSUserName(),
            importedAt: importedAt,
            checksumSHA256: nil,
            signingStatus: .unknown,
            ownershipNote: "User-supplied firmware; the project does not redistribute Apple firmware.",
            retentionPolicy: .keep
        )
    }
}

// MARK: - Plugin isolation and audit

struct PluginSandboxPolicy: Codable, Hashable, Sendable {
    var enabled: Bool
    var allowNetwork: Bool
    var allowDeviceRead: Bool
    var allowTemporaryFiles: Bool
    var timeoutSeconds: Int
    var maximumOutputBytes: Int
    var requirePerRunApproval: Bool

    static let standard = PluginSandboxPolicy(
        enabled: true, allowNetwork: false, allowDeviceRead: false,
        allowTemporaryFiles: true, timeoutSeconds: 120, maximumOutputBytes: 5 * 1_048_576,
        requirePerRunApproval: true
    )
}

struct PluginAuditRecord: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let pluginID: String
    let capability: String
    let startedAt: Date
    let completedAt: Date
    let deviceName: String?
    let sandboxed: Bool
    let networkAllowed: Bool
    let exitCode: Int32
    let timedOut: Bool
    let outputBytes: Int
}

enum PluginAuditStore {
    private static let lock = NSLock()

    static func load(paths: LabPaths) -> [PluginAuditRecord] {
        lock.lock()
        defer { lock.unlock() }
        return (try? HardeningJSON.load([PluginAuditRecord].self, from: paths.stateRoot.appendingPathComponent("plugin-audit.json"))) ?? []
    }

    static func append(_ record: PluginAuditRecord, paths: LabPaths) throws {
        lock.lock()
        defer { lock.unlock() }
        let url = paths.stateRoot.appendingPathComponent("plugin-audit.json")
        var records = (try? HardeningJSON.load([PluginAuditRecord].self, from: url)) ?? []
        records.insert(record, at: 0)
        try HardeningJSON.save(Array(records.prefix(1_000)), to: url)
    }
}

enum PluginSandboxProfile {
    static func make(
        executable: String,
        outputRoot: URL,
        deviceRoot: URL?,
        policy: PluginSandboxPolicy
    ) -> String {
        func literal(_ value: String) -> String {
            value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        var rules = [
            "(version 1)",
            "(deny default)",
            "(allow process*)",
            "(allow sysctl-read)",
            "(allow mach-lookup)",
            "(allow file-read-metadata)",
            "(allow file-read-data (literal \"/\"))",
            "(allow file-read* (subpath \"/System\") (subpath \"/usr/lib\") (subpath \"/usr/bin\") (subpath \"/bin\") (subpath \"/Library/Apple\") (subpath \"/private/var/db/dyld\"))",
            "(allow file-read* file-write* (subpath \"\(literal(outputRoot.path))\"))",
            "(allow file-read* (literal \"\(literal(executable))\"))",
        ]
        if policy.allowTemporaryFiles { rules.append("(allow file-read* file-write* (subpath \"/private/tmp\") (subpath \"/private/var/folders\"))") }
        if policy.allowDeviceRead, let deviceRoot { rules.append("(allow file-read* (subpath \"\(literal(deviceRoot.path))\"))") }
        if policy.allowNetwork { rules.append("(allow network*)") }
        return rules.joined(separator: "\n")
    }
}

// MARK: - Authenticated remote/CI queue configuration

struct RemoteLabAgentConfiguration: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let agentID: UUID
    let queuePath: String
    let tokenFilePath: String
    let createdAt: Date
    var activeKeyID: String?
    var rotatedAt: Date?
    var enabled: Bool
    var maximumConcurrentJobs: Int
    var jobTimeoutSeconds: Int
}

struct RemoteAgentHealthSnapshot: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let checkedAt: Date
    let queuePath: String
    let activeKeyID: String?
    let queued: Int
    let running: Int
    let results: Int
    let rejected: Int
    let cancelled: Int
    let replayLedgerEntries: Int
    let healthy: Bool
    let issues: [String]
}

enum RemoteLabAgentBootstrap {
    private struct KeyringFile: Codable {
        let schemaVersion: Int
        let activeKeyID: String
        let keys: [String: String]
        let keyCreatedAt: [String: Date]
        let revokedKeyIDs: [String]
        let rotatedAt: Date
    }

    static func load(paths: LabPaths) -> RemoteLabAgentConfiguration? {
        try? HardeningJSON.load(RemoteLabAgentConfiguration.self, from: paths.stateRoot.appendingPathComponent("remote-agent.json"))
    }

    static func initialize(paths: LabPaths) throws -> RemoteLabAgentConfiguration {
        let root = paths.stateRoot.appendingPathComponent("Remote Agent", isDirectory: true)
        let queue = root.appendingPathComponent("Queue", isDirectory: true)
        for component in [
            queue.appendingPathComponent("Inbox"), queue.appendingPathComponent("Running"),
            queue.appendingPathComponent("Results"), queue.appendingPathComponent("Rejected"),
            queue.appendingPathComponent("Cancelled"),
        ] {
            try FileManager.default.createDirectory(at: component, withIntermediateDirectories: true)
        }
        let tokenURL = root.appendingPathComponent("agent-token")
        guard !FileManager.default.fileExists(atPath: tokenURL.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw CocoaError(.fileWriteUnknown)
        }
        let keyID = UUID().uuidString
        let rotatedAt = Date()
        let keyring = KeyringFile(
            schemaVersion: 2, activeKeyID: keyID,
            keys: [keyID: Data(bytes).base64EncodedString()], keyCreatedAt: [keyID: rotatedAt],
            revokedKeyIDs: [],
            rotatedAt: rotatedAt
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(keyring).write(to: tokenURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenURL.path)
        let configuration = RemoteLabAgentConfiguration(
            schemaVersion: 2, agentID: UUID(), queuePath: queue.path, tokenFilePath: tokenURL.path,
            createdAt: .now, activeKeyID: keyID, rotatedAt: rotatedAt,
            enabled: false, maximumConcurrentJobs: 1, jobTimeoutSeconds: 7_200
        )
        try HardeningJSON.save(configuration, to: paths.stateRoot.appendingPathComponent("remote-agent.json"))
        return configuration
    }
}

// MARK: - Unified bootstrap state

struct ProductionHardeningState: Sendable {
    let migrationReport: LabMigrationReport
    let journalEntries: [OperationJournalEntry]
    let hostCatalog: HostCompatibilityCatalog
    let environmentProfiles: [EnvironmentProfile]
    let environmentAssignments: [String: UUID]
    let storagePolicy: LabStoragePolicy
    let pluginAudits: [PluginAuditRecord]
    let remoteAgent: RemoteLabAgentConfiguration?
    let qualificationCampaigns: [QualificationCampaign]
    let guestTrustPolicy: GuestTrustPolicy
    let evidenceSeals: [EvidenceSeal]
    let backupPolicy: LabBackupPolicy
    let updateLifecyclePolicy: UpdateLifecyclePolicy
    let stagedUpdate: StagedUpdateRecord?
    let supplyChain: SupplyChainAssessment
    let setupReport: SetupAssistantReport
    let resilienceReport: ResilienceReport?

    static func load(paths: LabPaths) throws -> ProductionHardeningState {
        let migration = try LabMigrationManager.migrate(paths: paths)
        return ProductionHardeningState(
            migrationReport: migration,
            journalEntries: try OperationJournalStore.recoverInterrupted(paths: paths),
            hostCatalog: HostCompatibilityDatabase.load(paths: paths),
            environmentProfiles: EnvironmentProfileStore.load(paths: paths),
            environmentAssignments: EnvironmentProfileStore.loadAssignments(paths: paths),
            storagePolicy: StorageLifecycleManager.loadPolicy(paths: paths),
            pluginAudits: PluginAuditStore.load(paths: paths),
            remoteAgent: RemoteLabAgentBootstrap.load(paths: paths),
            qualificationCampaigns: QualificationCampaignStore.load(paths: paths),
            guestTrustPolicy: (try? HardeningJSON.load(
                GuestTrustPolicy.self,
                from: paths.stateRoot.appendingPathComponent("guest-trust-policy.json")
            )) ?? .strict,
            evidenceSeals: EvidenceLedger.load(paths: paths),
            backupPolicy: (try? HardeningJSON.load(
                LabBackupPolicy.self,
                from: paths.stateRoot.appendingPathComponent("backup-policy.json")
            )) ?? .standard,
            updateLifecyclePolicy: (try? HardeningJSON.load(
                UpdateLifecyclePolicy.self,
                from: paths.stateRoot.appendingPathComponent("update-lifecycle-policy.json")
            )) ?? .standard,
            stagedUpdate: UpdateLifecycleManager.load(paths: paths),
            supplyChain: SupplyChainInspector.inspect(),
            setupReport: SetupAssistant.inspect(paths: paths, host: .checking),
            resilienceReport: ResilienceSuite.loadLatest(paths: paths)
        )
    }
}

enum HardeningJSON {
    static func load<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let decode: () throws -> T = {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(type, from: Data(contentsOf: url))
        }
        let immutableRoots = [
            Bundle.main.resourceURL,
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Resources", isDirectory: true),
        ].compactMap { $0?.standardizedFileURL }
        if immutableRoots.contains(where: { url.standardizedFileURL.path.hasPrefix($0.path + "/") }) {
            return try decode()
        }
        return try AdvisoryFileLock.withLock(at: url.appendingPathExtension("lock")) {
            try decode()
        }
    }

    static func save<T: Encodable>(_ value: T, to url: URL) throws {
        try AdvisoryFileLock.withLock(at: url.appendingPathExtension("lock")) {
            try SecureFilesystem.prepareDirectory(url.deletingLastPathComponent())
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(value).write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
            try SecureFilesystem.protectFile(url)
        }
    }
}
