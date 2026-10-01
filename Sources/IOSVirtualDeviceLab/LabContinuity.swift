import CryptoKit
import Darwin
import Foundation

// MARK: - External storage identity and relinking

enum StorageLocationState: String, Codable, Sendable {
    case online
    case readOnly
    case missing
    case relinkRequired
    case unknown
}

struct StorageLocationStatus: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let configuredPath: String
    let resolvedPath: String?
    let isSymbolicLink: Bool
    let volumeName: String?
    let volumeUUID: String?
    let volumeIsRemovable: Bool?
    let isWritable: Bool
    let state: StorageLocationState
    let checkedAt: Date
    let message: String

    static let unknown = StorageLocationStatus(
        schemaVersion: 1,
        configuredPath: "Unknown",
        resolvedPath: nil,
        isSymbolicLink: false,
        volumeName: nil,
        volumeUUID: nil,
        volumeIsRemovable: nil,
        isWritable: false,
        state: .unknown,
        checkedAt: .distantPast,
        message: "Storage has not been inspected."
    )

    var requiresRelink: Bool { state == .relinkRequired }
}

enum StorageRelinkError: LocalizedError {
    case targetMissing
    case targetNotDirectory
    case targetNotWritable
    case unsafeTarget
    case rootRequiresMigration
    case relinkFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .targetMissing: "The selected storage root does not exist."
        case .targetNotDirectory: "The selected storage root is not a directory."
        case .targetNotWritable: "The selected storage root is not writable."
        case .unsafeTarget: "Choose a dedicated lab directory, not a filesystem root or home directory."
        case .rootRequiresMigration: "The current data root is a real directory. Stage a verified migration before replacing it with an external-storage link."
        case let .relinkFailed(code): "The atomic storage relink failed with errno \(code)."
        }
    }
}

enum ExternalStorageManager {
    static var defaultRegistryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/iOS Virtual Device Lab", isDirectory: true)
            .appendingPathComponent("storage-location.json")
    }

    static func inspect(paths: LabPaths, registryURL: URL? = nil) -> StorageLocationStatus {
        inspect(root: paths.dataRoot, registryURL: registryURL)
    }

    static func inspect(root: URL, registryURL: URL? = nil) -> StorageLocationStatus {
        let fm = FileManager.default
        let linkDestination = try? fm.destinationOfSymbolicLink(atPath: root.path)
        let resolved: URL
        if let linkDestination {
            let destinationURL = URL(fileURLWithPath: linkDestination)
            resolved = destinationURL.path.hasPrefix("/")
                ? destinationURL.standardizedFileURL
                : root.deletingLastPathComponent().appendingPathComponent(linkDestination).standardizedFileURL
        } else {
            resolved = root.standardizedFileURL
        }

        var isDirectory: ObjCBool = false
        let exists = fm.fileExists(atPath: resolved.path, isDirectory: &isDirectory)
        let writable = exists && isDirectory.boolValue && fm.isWritableFile(atPath: resolved.path)
        let values = try? resolved.resourceValues(forKeys: [
            .volumeNameKey, .volumeUUIDStringKey, .volumeIsRemovableKey,
        ])
        let state: StorageLocationState
        let message: String
        if !exists || !isDirectory.boolValue {
            state = linkDestination == nil ? .missing : .relinkRequired
            message = linkDestination == nil
                ? "The configured local lab directory has not been initialized yet."
                : "The external-storage link points to an unavailable location. Relink it before starting backend work."
        } else if !writable {
            state = .readOnly
            message = "Lab storage is mounted read-only; mutating operations are blocked."
        } else {
            state = .online
            message = "Lab storage is online and writable."
        }
        let status = StorageLocationStatus(
            schemaVersion: 1,
            configuredPath: root.path,
            resolvedPath: exists ? resolved.path : linkDestination.map { _ in resolved.path },
            isSymbolicLink: linkDestination != nil,
            volumeName: values?.volumeName,
            volumeUUID: values?.volumeUUIDString,
            volumeIsRemovable: values?.volumeIsRemovable,
            isWritable: writable,
            state: state,
            checkedAt: .now,
            message: message
        )
        if let registryURL = registryURL ?? Optional(defaultRegistryURL) {
            try? HardeningJSON.save(status, to: registryURL)
        }
        return status
    }

    static func relink(
        root: URL,
        to destination: URL,
        registryURL: URL? = nil
    ) throws -> StorageLocationStatus {
        let fm = FileManager.default
        let target = destination.standardizedFileURL
        let home = fm.homeDirectoryForCurrentUser.standardizedFileURL
        guard target.path != "/", target.path != home.path, target.pathComponents.count > 2 else {
            throw StorageRelinkError.unsafeTarget
        }
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: target.path, isDirectory: &isDirectory) else {
            throw StorageRelinkError.targetMissing
        }
        guard isDirectory.boolValue else { throw StorageRelinkError.targetNotDirectory }
        guard fm.isWritableFile(atPath: target.path) else { throw StorageRelinkError.targetNotWritable }

        let existingLink = try? fm.destinationOfSymbolicLink(atPath: root.path)
        if existingLink == nil, fm.fileExists(atPath: root.path) {
            throw StorageRelinkError.rootRequiresMigration
        }
        try fm.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = root.deletingLastPathComponent()
            .appendingPathComponent(".\(root.lastPathComponent).relink-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temporary) }
        try fm.createSymbolicLink(at: temporary, withDestinationURL: target)
        guard Darwin.rename(temporary.path, root.path) == 0 else {
            throw StorageRelinkError.relinkFailed(errno)
        }
        for name in ["VMs", "ipsws", "Snapshots", "VirtualDeviceLab"] {
            try SecureFilesystem.prepareDirectory(target.appendingPathComponent(name, isDirectory: true))
        }
        return inspect(root: root, registryURL: registryURL)
    }
}

// MARK: - Audited crash recovery decisions

enum RecoveryAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case resume = "Resume / Retry"
    case rollback = "Roll Back"
    case abandon = "Abandon"
    case keepForReview = "Keep for Review"
    var id: String { rawValue }
}

struct RecoveryDecision: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let journalEntryID: UUID
    let action: RecoveryAction
    let decidedAt: Date
    let target: String
    let guidance: String
    let requiresManualAction: Bool
}

struct RecoveryCenterSnapshot: Codable, Hashable, Sendable {
    let generatedAt: Date
    let unresolvedEntries: [OperationJournalEntry]
    let decisions: [RecoveryDecision]

    static let empty = RecoveryCenterSnapshot(generatedAt: .distantPast, unresolvedEntries: [], decisions: [])
}

enum RecoveryCenterStore {
    private static func url(paths: LabPaths) -> URL {
        paths.stateRoot.appendingPathComponent("recovery-decisions.json")
    }

    static func load(paths: LabPaths, entries: [OperationJournalEntry]) -> RecoveryCenterSnapshot {
        let decisions = (try? HardeningJSON.load([RecoveryDecision].self, from: url(paths: paths))) ?? []
        return RecoveryCenterSnapshot(
            generatedAt: .now,
            unresolvedEntries: entries.filter { [.interrupted, .failed].contains($0.state) },
            decisions: decisions
        )
    }

    static func decide(
        entry: OperationJournalEntry,
        action: RecoveryAction,
        entries: inout [OperationJournalEntry],
        paths: LabPaths
    ) throws -> RecoveryDecision {
        let guidance: String
        let manual: Bool
        switch action {
        case .resume:
            guidance = "The original transaction remains immutable. Re-run the operation from its owning screen after preflight and target-state checks pass."
            manual = true
        case .rollback:
            guidance = entry.recoveryInstruction
            manual = true
        case .abandon:
            guidance = "No files were deleted. Inspect the target before performing any later cleanup."
            manual = false
        case .keepForReview:
            guidance = "The interrupted entry remains open and will continue to appear in Recovery Center."
            manual = false
        }
        let decision = RecoveryDecision(
            id: UUID(), journalEntryID: entry.id, action: action, decidedAt: .now,
            target: entry.target, guidance: guidance, requiresManualAction: manual
        )
        var decisions = (try? HardeningJSON.load([RecoveryDecision].self, from: url(paths: paths))) ?? []
        decisions.insert(decision, at: 0)
        try HardeningJSON.save(Array(decisions.prefix(500)), to: url(paths: paths))
        if action != .keepForReview, let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index].state = .resolved
            entries[index].updatedAt = .now
            entries[index].message = "Recovery decision: \(action.rawValue). \(guidance)"
            try OperationJournalStore.save(entries, paths: paths)
        }
        return decision
    }
}

// MARK: - Canonical real-VM fixtures

struct CanonicalVMFixture: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let schemaVersion: Int
    let name: String
    let createdAt: Date
    let deviceName: String
    let deviceProductType: String
    let firmwareSHA256: String
    let cloudOSFirmwareSHA256: String?
    let hardwareProfileID: String
    let backendID: String
    let backendVersion: String?
    let guestProtocolVersion: Int?
    let snapshotSHA256: String
    let smokeAppSHA256: String?
    let acceptanceGeneratedAt: Date
    let acceptanceGateIDs: [String]
}

struct CanonicalFixtureAssessment: Codable, Hashable, Sendable {
    let ready: Bool
    let blockers: [String]
    static let unavailable = CanonicalFixtureAssessment(ready: false, blockers: ["No fixture candidate has been assessed."])
}

enum CanonicalFixtureStore {
    private static func url(paths: LabPaths) -> URL {
        paths.stateRoot.appendingPathComponent("canonical-fixtures.json")
    }

    static func load(paths: LabPaths) -> [CanonicalVMFixture] {
        (try? HardeningJSON.load([CanonicalVMFixture].self, from: url(paths: paths))) ?? []
    }

    static func assess(
        device: VirtualDevice?,
        firmware: FirmwareImage?,
        snapshot: SnapshotRecord?,
        acceptance: AcceptanceReport
    ) -> CanonicalFixtureAssessment {
        var blockers: [String] = []
        if device == nil { blockers.append("Select a restored virtual device.") }
        if device?.restoreInfo?.device == nil { blockers.append("The virtual-device product type is unknown.") }
        if device?.hardwareProfileID == nil { blockers.append("Assign a versioned hardware profile.") }
        if firmware?.sha256 == nil || firmware?.validation?.state != .valid {
            blockers.append("Use structurally validated firmware with a SHA-256 identity.")
        }
        if snapshot?.sha256 == nil || snapshot?.integrityStatus != .verified {
            blockers.append("Create and verify a golden snapshot.")
        }
        if !acceptance.isPassed || acceptance.deviceName != device?.name {
            blockers.append("Complete baseline acceptance for this exact device.")
        }
        return CanonicalFixtureAssessment(ready: blockers.isEmpty, blockers: blockers)
    }

    static func create(
        name: String,
        device: VirtualDevice,
        firmware: FirmwareImage,
        cloudOS: FirmwareImage?,
        snapshot: SnapshotRecord,
        smokeApp: AppArtifact?,
        backend: BackendDescriptor,
        handshake: GuestProtocolHandshake?,
        acceptance: AcceptanceReport,
        paths: LabPaths
    ) throws -> CanonicalVMFixture {
        let assessment = assess(device: device, firmware: firmware, snapshot: snapshot, acceptance: acceptance)
        guard assessment.ready,
              let product = device.restoreInfo?.device,
              let profile = device.hardwareProfileID,
              let firmwareHash = firmware.sha256,
              let snapshotHash = snapshot.sha256
        else { throw CocoaError(.validationMissingMandatoryProperty) }
        let fixture = CanonicalVMFixture(
            id: UUID(), schemaVersion: 1, name: name, createdAt: .now,
            deviceName: device.name, deviceProductType: product, firmwareSHA256: firmwareHash,
            cloudOSFirmwareSHA256: cloudOS?.sha256, hardwareProfileID: profile,
            backendID: backend.id, backendVersion: backend.version,
            guestProtocolVersion: handshake?.negotiatedVersion, snapshotSHA256: snapshotHash,
            smokeAppSHA256: smokeApp?.sha256, acceptanceGeneratedAt: acceptance.generatedAt,
            acceptanceGateIDs: acceptance.gates.filter { $0.status == .passed }.map { $0.kind.rawValue }
        )
        var fixtures = load(paths: paths)
        fixtures.removeAll { $0.name.caseInsensitiveCompare(fixture.name) == .orderedSame }
        fixtures.insert(fixture, at: 0)
        try HardeningJSON.save(Array(fixtures.prefix(50)), to: url(paths: paths))
        return fixture
    }
}

// MARK: - Declarative Labfile planning

struct LabfileDevice: Codable, Hashable, Sendable {
    var name: String
    var hardwareProfileID: String
    var firmwareSHA256: String
    var cloudOSFirmwareSHA256: String?
    var cpuCount: Int
    var memoryMB: Int
    var diskSizeGB: Int
    var networkMode: String
    var environmentProfileID: UUID?
    var workflowNames: [String]
}

struct LabfileDocument: Codable, Hashable, Sendable {
    var schemaVersion: Int
    var name: String
    var backendID: String
    var devices: [LabfileDevice]

    static let empty = LabfileDocument(
        schemaVersion: 1, name: "iOS Virtual Device Lab", backendID: BackendDescriptor.vphone.id, devices: []
    )
}

enum LabfileChangeKind: String, Codable, Sendable {
    case create
    case update
    case unchanged
    case blocked
}

struct LabfileChange: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let deviceName: String
    let kind: LabfileChangeKind
    let summary: String
}

struct LabfilePlan: Codable, Hashable, Sendable {
    let generatedAt: Date
    let labName: String
    let changes: [LabfileChange]
    let blockers: [String]
    var canApply: Bool { blockers.isEmpty && !changes.contains { $0.kind == .blocked } }
    static let empty = LabfilePlan(generatedAt: .distantPast, labName: "None", changes: [], blockers: [])
}

enum LabfilePlanner {
    static func load(_ url: URL) throws -> LabfileDocument {
        let data = try Data(contentsOf: url)
        guard data.count <= 2 * 1_024 * 1_024 else { throw CocoaError(.fileReadTooLarge) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(LabfileDocument.self, from: data)
        guard document.schemaVersion == 1 else { throw CocoaError(.coderInvalidValue) }
        return document
    }

    static func save(_ document: LabfileDocument, to url: URL) throws {
        guard document.schemaVersion == 1 else { throw CocoaError(.coderInvalidValue) }
        try HardeningJSON.save(document, to: url)
    }

    static func plan(
        _ document: LabfileDocument,
        devices: [VirtualDevice],
        firmware: [FirmwareImage],
        profiles: HardwareProfileCatalog,
        backend: BackendDescriptor
    ) -> LabfilePlan {
        var blockers: [String] = []
        if document.backendID != backend.id {
            blockers.append("Labfile backend \(document.backendID) does not match active backend \(backend.id).")
        }
        var seen = Set<String>()
        var changes: [LabfileChange] = []
        for desired in document.devices {
            let key = desired.name.lowercased()
            if !seen.insert(key).inserted {
                changes.append(.init(id: UUID(), deviceName: desired.name, kind: .blocked, summary: "Duplicate device name in Labfile."))
                continue
            }
            guard profiles.profile(id: desired.hardwareProfileID) != nil else {
                changes.append(.init(id: UUID(), deviceName: desired.name, kind: .blocked, summary: "Unknown hardware profile \(desired.hardwareProfileID)."))
                continue
            }
            guard firmware.contains(where: { $0.sha256?.caseInsensitiveCompare(desired.firmwareSHA256) == .orderedSame }) else {
                changes.append(.init(id: UUID(), deviceName: desired.name, kind: .blocked, summary: "Required firmware hash is not in the local authorized catalog."))
                continue
            }
            guard let current = devices.first(where: { $0.name.caseInsensitiveCompare(desired.name) == .orderedSame }) else {
                changes.append(.init(id: UUID(), deviceName: desired.name, kind: .create, summary: "Create from pinned firmware and profile."))
                continue
            }
            var differences: [String] = []
            if current.cpuCount != desired.cpuCount { differences.append("CPU") }
            if current.memoryMB != desired.memoryMB { differences.append("memory") }
            if current.hardwareProfileID != desired.hardwareProfileID { differences.append("hardware profile") }
            if current.network.mode != desired.networkMode { differences.append("network") }
            changes.append(.init(
                id: UUID(), deviceName: desired.name,
                kind: differences.isEmpty ? .unchanged : .update,
                summary: differences.isEmpty ? "Configuration already matches." : "Update \(differences.joined(separator: ", "))."
            ))
        }
        return LabfilePlan(generatedAt: .now, labName: document.name, changes: changes, blockers: blockers)
    }
}

// MARK: - Evidence freshness and recertification

struct EvidenceLifecyclePolicy: Codable, Hashable, Sendable {
    var maximumAgeDays: Int
    var invalidateOnHostChange: Bool
    var invalidateOnBackendChange: Bool
    var invalidateOnFirmwareChange: Bool
    var requireApprovedSeal: Bool

    static let standard = EvidenceLifecyclePolicy(
        maximumAgeDays: 30, invalidateOnHostChange: true, invalidateOnBackendChange: true,
        invalidateOnFirmwareChange: true, requireApprovedSeal: true
    )
}

struct EvidenceFreshnessItem: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let campaignID: UUID
    let fresh: Bool
    let reasons: [String]
}

struct EvidenceFreshnessReport: Codable, Hashable, Sendable {
    let generatedAt: Date
    let items: [EvidenceFreshnessItem]
    var freshCount: Int { items.filter(\.fresh).count }
    static let empty = EvidenceFreshnessReport(generatedAt: .distantPast, items: [])
}

enum EvidenceLifecycleManager {
    static func loadPolicy(paths: LabPaths) -> EvidenceLifecyclePolicy {
        (try? HardeningJSON.load(
            EvidenceLifecyclePolicy.self,
            from: paths.stateRoot.appendingPathComponent("evidence-lifecycle-policy.json")
        )) ?? .standard
    }

    static func savePolicy(_ policy: EvidenceLifecyclePolicy, paths: LabPaths) throws {
        try HardeningJSON.save(policy, to: paths.stateRoot.appendingPathComponent("evidence-lifecycle-policy.json"))
    }

    static func evaluate(
        campaigns: [QualificationCampaign],
        policy: EvidenceLifecyclePolicy,
        host: HostReadiness,
        backend: BackendDescriptor,
        currentFirmwareHashes: Set<String>,
        seals: [EvidenceSeal],
        now: Date = .now
    ) -> EvidenceFreshnessReport {
        let fingerprint = "\(host.model)|\(host.macOSVersion)|\(host.architecture)"
        let items = campaigns.map { campaign in
            var reasons: [String] = []
            if now.timeIntervalSince(campaign.completedAt ?? campaign.createdAt) > Double(policy.maximumAgeDays) * 86_400 {
                reasons.append("Evidence is older than \(policy.maximumAgeDays) days.")
            }
            if policy.invalidateOnHostChange && campaign.hostFingerprint != fingerprint {
                reasons.append("Host fingerprint changed.")
            }
            if policy.invalidateOnBackendChange
                && (campaign.backendID != backend.id || campaign.backendVersion != backend.version) {
                reasons.append("Backend identity or version changed.")
            }
            if policy.invalidateOnFirmwareChange,
               let hash = campaign.firmwareSHA256,
               !currentFirmwareHashes.contains(hash.lowercased()) {
                reasons.append("Pinned firmware is not present in the current catalog.")
            }
            if policy.requireApprovedSeal {
                let approved = campaign.evidenceSealID.flatMap { id in seals.first { $0.id == id } }?.reviewState == .approved
                if !approved { reasons.append("No approved evidence seal is linked.") }
            }
            return EvidenceFreshnessItem(id: UUID(), campaignID: campaign.id, fresh: reasons.isEmpty, reasons: reasons)
        }
        return EvidenceFreshnessReport(generatedAt: now, items: items)
    }
}

// MARK: - Host capacity calibration

enum HostCapacityClass: String, Codable, Sendable {
    case constrained
    case standard
    case highCapacity
}

struct HostCapacityCalibration: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let measuredAt: Date
    let physicalMemoryMB: Int
    let activeProcessorCount: Int
    let availableStorageBytes: Int64
    let diskWriteMBPerSecond: Double?
    let capacityClass: HostCapacityClass
    let recommendedConcurrentVMs: Int
    let recommendedAggregateMemoryMB: Int
    let reservedHostMemoryMB: Int
    let notes: [String]

    static let unavailable = HostCapacityCalibration(
        schemaVersion: 1, measuredAt: .distantPast, physicalMemoryMB: 0, activeProcessorCount: 0,
        availableStorageBytes: 0, diskWriteMBPerSecond: nil, capacityClass: .constrained,
        recommendedConcurrentVMs: 1, recommendedAggregateMemoryMB: 2_048,
        reservedHostMemoryMB: 4_096, notes: ["Host capacity has not been calibrated."]
    )
}

enum HostCapacityCalibrator {
    static func load(paths: LabPaths) -> HostCapacityCalibration {
        (try? HardeningJSON.load(
            HostCapacityCalibration.self,
            from: paths.stateRoot.appendingPathComponent("host-capacity.json")
        )) ?? .unavailable
    }

    static func recommendation(
        physicalMemoryMB: Int,
        processors: Int,
        availableStorageBytes: Int64,
        diskWriteMBPerSecond: Double? = nil,
        measuredAt: Date = .now
    ) -> HostCapacityCalibration {
        let capacity: HostCapacityClass
        let concurrent: Int
        let reserve: Int
        if physicalMemoryMB < 16_384 || processors < 8 {
            capacity = .constrained; concurrent = 1; reserve = min(4_096, max(2_048, physicalMemoryMB / 2))
        } else if physicalMemoryMB < 32_768 {
            capacity = .standard; concurrent = 2; reserve = 6_144
        } else {
            capacity = .highCapacity; concurrent = min(4, max(2, processors / 4)); reserve = 8_192
        }
        let aggregate = max(2_048, min(physicalMemoryMB - reserve, concurrent * 6_144))
        var notes: [String] = []
        if physicalMemoryMB < 16_384 { notes.append("Low-memory mode: run one VM and prefer 2–4 GB guest profiles.") }
        if availableStorageBytes < 100 * 1_073_741_824 { notes.append("Available storage is below the 100 GiB working reserve.") }
        if let speed = diskWriteMBPerSecond, speed < 100 { notes.append("Storage throughput may increase restore and snapshot time.") }
        return HostCapacityCalibration(
            schemaVersion: 1, measuredAt: measuredAt, physicalMemoryMB: physicalMemoryMB,
            activeProcessorCount: processors, availableStorageBytes: availableStorageBytes,
            diskWriteMBPerSecond: diskWriteMBPerSecond, capacityClass: capacity,
            recommendedConcurrentVMs: concurrent, recommendedAggregateMemoryMB: aggregate,
            reservedHostMemoryMB: reserve, notes: notes
        )
    }

    static func run(paths: LabPaths) -> HostCapacityCalibration {
        let info = ProcessInfo.processInfo
        let memory = Int(info.physicalMemory / 1_048_576)
        let available = (try? paths.dataRoot.resolvingSymlinksInPath().resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ))?.volumeAvailableCapacityForImportantUsage ?? 0
        let temporary = paths.stateRoot.appendingPathComponent(".capacity-\(UUID().uuidString)")
        let payload = Data(repeating: 0xA5, count: 8 * 1_024 * 1_024)
        let started = Date()
        let wrote = (try? payload.write(to: temporary, options: [.atomic])) != nil
        let elapsed = max(0.001, Date().timeIntervalSince(started))
        try? FileManager.default.removeItem(at: temporary)
        let speed = wrote ? 8.0 / elapsed : nil
        let result = recommendation(
            physicalMemoryMB: memory, processors: info.activeProcessorCount,
            availableStorageBytes: available, diskWriteMBPerSecond: speed
        )
        try? HardeningJSON.save(result, to: paths.stateRoot.appendingPathComponent("host-capacity.json"))
        return result
    }
}

// MARK: - Hostile input and parser boundary suite

struct SecurityBoundaryResult: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let name: String
    let passed: Bool
    let evidence: String
}

struct HostileInputReport: Codable, Hashable, Sendable {
    let generatedAt: Date
    let results: [SecurityBoundaryResult]
    var passed: Bool { !results.isEmpty && results.allSatisfy(\.passed) }
    static let empty = HostileInputReport(generatedAt: .distantPast, results: [])
}

enum HostileInputValidator {
    static func load(paths: LabPaths) -> HostileInputReport {
        (try? HardeningJSON.load(
            HostileInputReport.self,
            from: paths.stateRoot.appendingPathComponent("hostile-input-report.json")
        )) ?? .empty
    }

    static func isSafeArchivePath(_ path: String) -> Bool {
        guard !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.contains("..") && !components.contains("")
    }

    static func acceptsJSON(_ data: Data, maximumBytes: Int = 1_048_576) -> Bool {
        guard !data.isEmpty, data.count <= maximumBytes else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    static func run(paths: LabPaths) -> HostileInputReport {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vdl-hostile-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var results: [SecurityBoundaryResult] = []
        func add(_ name: String, _ passed: Bool, _ evidence: String) {
            results.append(.init(id: UUID(), name: name, passed: passed, evidence: evidence))
        }
        add("Malformed JSON", !acceptsJSON(Data("{broken".utf8)), "Malformed state is rejected.")
        add("Oversized JSON", !acceptsJSON(Data(repeating: 0x20, count: 1_048_577)), "Payload ceiling rejects oversized input before parsing.")
        add("Archive traversal", !isSafeArchivePath("../../escape"), "Parent-directory archive entries are rejected.")
        add("Absolute archive path", !isSafeArchivePath("/tmp/escape"), "Absolute archive entries are rejected.")
        add("Valid archive path", isSafeArchivePath("Payload/App.app/Contents/Info.plist"), "A bounded relative path remains accepted.")
        let outside = root.appendingPathComponent("outside")
        let link = root.appendingPathComponent("payload-link")
        try? FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let linkDetected = (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil
        add("Symlink escape", linkDetected, "Symlink entries are detectable before recursive copy or extraction.")
        let report = HostileInputReport(generatedAt: .now, results: results)
        try? HardeningJSON.save(report, to: paths.stateRoot.appendingPathComponent("hostile-input-report.json"))
        return report
    }
}

// MARK: - Unified data lifecycle and recoverable quarantine

struct UnifiedRetentionPolicy: Codable, Hashable, Sendable {
    var activityDays: Int
    var testArtifactDays: Int
    var diagnosticDays: Int
    var screenshotDays: Int
    var migrationBackupDays: Int
    var quarantineDays: Int
    var preserveSignedEvidence: Bool
    var telemetryEnabled: Bool

    static let standard = UnifiedRetentionPolicy(
        activityDays: 30, testArtifactDays: 30, diagnosticDays: 14, screenshotDays: 14,
        migrationBackupDays: 90, quarantineDays: 30, preserveSignedEvidence: true,
        telemetryEnabled: false
    )
}

struct RetentionCandidate: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let category: String
    let path: String
    let ageDays: Int
    let sizeBytes: Int64
}

struct RetentionPreview: Codable, Hashable, Sendable {
    let generatedAt: Date
    let candidates: [RetentionCandidate]
    let totalBytes: Int64
    static let empty = RetentionPreview(generatedAt: .distantPast, candidates: [], totalBytes: 0)
}

enum UnifiedDataLifecycleManager {
    static func load(paths: LabPaths) -> UnifiedRetentionPolicy {
        (try? HardeningJSON.load(UnifiedRetentionPolicy.self, from: paths.stateRoot.appendingPathComponent("unified-retention-policy.json"))) ?? .standard
    }

    static func save(_ policy: UnifiedRetentionPolicy, paths: LabPaths) throws {
        try HardeningJSON.save(policy, to: paths.stateRoot.appendingPathComponent("unified-retention-policy.json"))
    }

    static func preview(paths: LabPaths, policy: UnifiedRetentionPolicy, now: Date = .now) -> RetentionPreview {
        let roots: [(String, URL, Int)] = [
            ("Test Artifacts", paths.stateRoot.appendingPathComponent("Test Artifacts"), policy.testArtifactDays),
            ("Diagnostics", paths.stateRoot.appendingPathComponent("Diagnostics"), policy.diagnosticDays),
            ("Screenshots", paths.stateRoot.appendingPathComponent("Screenshots"), policy.screenshotDays),
            ("Migration Backups", paths.stateRoot.appendingPathComponent("Migration Backups"), policy.migrationBackupDays),
        ]
        var candidates: [RetentionCandidate] = []
        for (category, root, limit) in roots where limit >= 0 {
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for child in children {
                let values = try? child.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                let age = Int(now.timeIntervalSince(values?.contentModificationDate ?? .distantPast) / 86_400)
                if age >= limit {
                    candidates.append(.init(
                        id: UUID(), category: category, path: child.path, ageDays: age,
                        sizeBytes: Int64(values?.fileSize ?? 0)
                    ))
                }
            }
        }
        candidates.sort { $0.path < $1.path }
        return RetentionPreview(
            generatedAt: now, candidates: candidates,
            totalBytes: candidates.reduce(0) { $0 + $1.sizeBytes }
        )
    }

    static func quarantine(_ preview: RetentionPreview, paths: LabPaths) throws -> URL? {
        guard !preview.candidates.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        let stamp = formatter.string(from: .now).replacingOccurrences(of: ":", with: "-")
        let root = paths.stateRoot.appendingPathComponent("Recovery Bin/\(stamp)", isDirectory: true)
        try SecureFilesystem.prepareDirectory(root)
        for candidate in preview.candidates {
            let source = URL(fileURLWithPath: candidate.path).standardizedFileURL
            guard source.path.hasPrefix(paths.stateRoot.standardizedFileURL.path + "/") else { continue }
            let category = NameSanitizer.fileComponent(candidate.category)
            let destinationRoot = root.appendingPathComponent(category, isDirectory: true)
            try SecureFilesystem.prepareDirectory(destinationRoot)
            let destination = destinationRoot.appendingPathComponent("\(UUID().uuidString)-\(source.lastPathComponent)")
            try FileManager.default.moveItem(at: source, to: destination)
        }
        return root
    }
}

// MARK: - Measurable operational objectives

struct OperationalObjectivePolicy: Codable, Hashable, Sendable {
    var minimumRunSuccessPercent: Double
    var maximumP95DurationSeconds: Double
    var minimumSoakHours: Double
    var recoveryTimeObjectiveMinutes: Int
    var recoveryPointObjectiveHours: Int
    var requireSecondVolumeRestore: Bool

    static let standard = OperationalObjectivePolicy(
        minimumRunSuccessPercent: 95, maximumP95DurationSeconds: 600,
        minimumSoakHours: 24, recoveryTimeObjectiveMinutes: 60,
        recoveryPointObjectiveHours: 24, requireSecondVolumeRestore: true
    )
}

struct OperationalGate: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let name: String
    let passed: Bool
    let measured: String
    let required: String
}

struct OperationalObjectiveReport: Codable, Hashable, Sendable {
    let generatedAt: Date
    let gates: [OperationalGate]
    var passed: Bool { !gates.isEmpty && gates.allSatisfy(\.passed) }
    static let empty = OperationalObjectiveReport(generatedAt: .distantPast, gates: [])
}

enum OperationalObjectiveEvaluator {
    static func loadPolicy(paths: LabPaths) -> OperationalObjectivePolicy {
        (try? HardeningJSON.load(
            OperationalObjectivePolicy.self,
            from: paths.stateRoot.appendingPathComponent("operational-objective-policy.json")
        )) ?? .standard
    }

    static func savePolicy(_ policy: OperationalObjectivePolicy, paths: LabPaths) throws {
        try HardeningJSON.save(policy, to: paths.stateRoot.appendingPathComponent("operational-objective-policy.json"))
    }

    static func evaluate(
        policy: OperationalObjectivePolicy,
        testRuns: [TestRunRecord],
        acceptance: AcceptanceReport,
        resilience: ResilienceReport?,
        secondVolumeRestoreRecorded: Bool
    ) -> OperationalObjectiveReport {
        let completed = testRuns.filter { $0.completedAt != nil }
        let passed = completed.filter { $0.state == .passed }
        let successRate = completed.isEmpty ? 0 : Double(passed.count) / Double(completed.count) * 100
        let durations = completed.compactMap { run in
            run.completedAt.map { $0.timeIntervalSince(run.createdAt) }
        }.sorted()
        let p95Index = durations.isEmpty ? nil : min(durations.count - 1, Int(ceil(Double(durations.count) * 0.95)) - 1)
        let p95 = p95Index.map { durations[$0] }
        let longestHours = (durations.max() ?? 0) / 3_600
        let gates = [
            OperationalGate(
                id: UUID(), name: "Run success rate",
                passed: !completed.isEmpty && successRate >= policy.minimumRunSuccessPercent,
                measured: completed.isEmpty ? "No completed runs" : String(format: "%.1f%%", successRate),
                required: String(format: "≥ %.1f%%", policy.minimumRunSuccessPercent)
            ),
            OperationalGate(
                id: UUID(), name: "P95 workflow duration",
                passed: p95.map { $0 <= policy.maximumP95DurationSeconds } == true,
                measured: p95.map { String(format: "%.1f s", $0) } ?? "No duration evidence",
                required: String(format: "≤ %.1f s", policy.maximumP95DurationSeconds)
            ),
            OperationalGate(
                id: UUID(), name: "Sustained soak",
                passed: longestHours >= policy.minimumSoakHours,
                measured: String(format: "%.2f h", longestHours),
                required: String(format: "≥ %.0f h", policy.minimumSoakHours)
            ),
            OperationalGate(
                id: UUID(), name: "Acceptance evidence", passed: acceptance.isPassed,
                measured: acceptance.isPassed ? "Passed" : "Incomplete", required: "All real-VM gates pass"
            ),
            OperationalGate(
                id: UUID(), name: "Fault tolerance", passed: resilience?.passed == true,
                measured: resilience?.passed == true ? "Passed" : "Not passed", required: "All resilience fixtures pass"
            ),
            OperationalGate(
                id: UUID(), name: "Second-volume recovery drill",
                passed: !policy.requireSecondVolumeRestore || secondVolumeRestoreRecorded,
                measured: secondVolumeRestoreRecorded ? "Recorded" : "Not recorded",
                required: policy.requireSecondVolumeRestore ? "Restore verified on a second volume" : "Optional"
            ),
        ]
        return OperationalObjectiveReport(generatedAt: .now, gates: gates)
    }
}

// MARK: - Public beta readiness and support bundle

struct BetaVerificationRecord: Codable, Hashable, Sendable {
    var voiceOverVerified: Bool
    var keyboardNavigationVerified: Bool
    var reducedMotionVerified: Bool
    var onboardingReviewed: Bool
    var supportPolicyReviewed: Bool
    var appleAssetPolicyReviewed: Bool
    var legalReviewReference: String
    var secondVolumeRestoreRecorded: Bool
    var verifiedAt: Date?

    static let empty = BetaVerificationRecord(
        voiceOverVerified: false, keyboardNavigationVerified: false,
        reducedMotionVerified: false, onboardingReviewed: false,
        supportPolicyReviewed: false, appleAssetPolicyReviewed: false,
        legalReviewReference: "", secondVolumeRestoreRecorded: false, verifiedAt: nil
    )
}

struct BetaReadinessItem: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let name: String
    let passed: Bool
    let evidence: String
}

struct PublicBetaReadinessReport: Codable, Hashable, Sendable {
    let generatedAt: Date
    let items: [BetaReadinessItem]
    var passed: Bool { !items.isEmpty && items.allSatisfy(\.passed) }
    static let empty = PublicBetaReadinessReport(generatedAt: .distantPast, items: [])
}

enum PublicBetaReadinessManager {
    static func load(paths: LabPaths) -> BetaVerificationRecord {
        (try? HardeningJSON.load(BetaVerificationRecord.self, from: paths.stateRoot.appendingPathComponent("beta-verification.json"))) ?? .empty
    }

    static func save(_ record: BetaVerificationRecord, paths: LabPaths) throws {
        var copy = record
        copy.verifiedAt = .now
        try HardeningJSON.save(copy, to: paths.stateRoot.appendingPathComponent("beta-verification.json"))
    }

    static func evaluate(record: BetaVerificationRecord, localizationCount: Int) -> PublicBetaReadinessReport {
        let legal = !record.legalReviewReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return PublicBetaReadinessReport(generatedAt: .now, items: [
            .init(id: UUID(), name: "VoiceOver", passed: record.voiceOverVerified, evidence: record.voiceOverVerified ? "Manual navigation recorded" : "Manual verification required"),
            .init(id: UUID(), name: "Keyboard navigation", passed: record.keyboardNavigationVerified, evidence: record.keyboardNavigationVerified ? "Recorded" : "Manual verification required"),
            .init(id: UUID(), name: "Reduced motion", passed: record.reducedMotionVerified, evidence: record.reducedMotionVerified ? "Recorded" : "Manual verification required"),
            .init(id: UUID(), name: "Onboarding", passed: record.onboardingReviewed, evidence: record.onboardingReviewed ? "Reviewed" : "Review required"),
            .init(id: UUID(), name: "Support policy", passed: record.supportPolicyReviewed, evidence: record.supportPolicyReviewed ? "Reviewed" : "Review required"),
            .init(id: UUID(), name: "Apple asset policy", passed: record.appleAssetPolicyReviewed, evidence: record.appleAssetPolicyReviewed ? "Reviewed" : "Review required"),
            .init(id: UUID(), name: "Legal review", passed: legal, evidence: legal ? record.legalReviewReference : "Reference required before public beta"),
            .init(id: UUID(), name: "Localization", passed: localizationCount >= 1, evidence: "\(localizationCount) localization catalog(s) packaged"),
        ])
    }

    static func createSupportBundle(
        paths: LabPaths,
        storage: StorageLocationStatus,
        capacity: HostCapacityCalibration,
        objectives: OperationalObjectiveReport,
        beta: PublicBetaReadinessReport
    ) throws -> URL {
        let root = paths.stateRoot.appendingPathComponent("Support Reports", isDirectory: true)
        try SecureFilesystem.prepareDirectory(root)
        let destination = root.appendingPathComponent("support-\(UUID().uuidString).json")
        struct Report: Codable {
            let schemaVersion: Int
            let createdAt: Date
            let appVersion: String
            let storage: StorageLocationStatus
            let capacity: HostCapacityCalibration
            let objectives: OperationalObjectiveReport
            let beta: PublicBetaReadinessReport
            let privacyNotice: String
        }
        let report = Report(
            schemaVersion: 1, createdAt: .now,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
            storage: storage, capacity: capacity, objectives: objectives, beta: beta,
            privacyNotice: "This report excludes firmware, VM disks, screenshots, credentials, account data, and raw console logs."
        )
        try HardeningJSON.save(report, to: destination)
        return destination
    }
}
