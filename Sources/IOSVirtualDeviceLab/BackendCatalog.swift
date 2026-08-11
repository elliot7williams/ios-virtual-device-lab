import Foundation

enum BackendIntegrationState: String, Codable, CaseIterable, Sendable {
    case activeAdapter
    case plannedAdapter
    case researchOnly
    case referenceOnly

    var displayName: String {
        switch self {
        case .activeAdapter: "Active adapter"
        case .plannedAdapter: "Planned adapter"
        case .researchOnly: "Research only"
        case .referenceOnly: "Reference only"
        }
    }

    var isRunnable: Bool { self == .activeAdapter }
}

enum BackendCapabilityID: String, Codable, CaseIterable, Identifiable, Sendable {
    case appleSilicon
    case iosBoot
    case vmLifecycle
    case firmware
    case virtualHardware
    case snapshots
    case cloning
    case graphics
    case audio
    case networking
    case appDeployment
    case debugging
    case automation
    case olderIOS

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .appleSilicon: "Apple Silicon"
        case .iosBoot: "iOS boot"
        case .vmLifecycle: "VM lifecycle"
        case .firmware: "Firmware handling"
        case .virtualHardware: "Virtual hardware"
        case .snapshots: "Snapshots"
        case .cloning: "Cloning"
        case .graphics: "Graphics / GPU"
        case .audio: "Audio"
        case .networking: "Networking"
        case .appDeployment: "App deployment"
        case .debugging: "Debugging"
        case .automation: "Automation"
        case .olderIOS: "Older iOS"
        }
    }
}

enum BackendCapabilityLevel: String, Codable, Sendable {
    case supported
    case partial
    case experimental
    case unsupported
    case unknown
    case benchmark

    var displayName: String {
        switch self {
        case .supported: "Supported"
        case .partial: "Partial"
        case .experimental: "Experimental"
        case .unsupported: "Unsupported"
        case .unknown: "Unknown"
        case .benchmark: "Benchmark"
        }
    }
}

struct BackendCapabilityRecord: Codable, Hashable, Sendable {
    let capability: BackendCapabilityID
    let level: BackendCapabilityLevel
    let evidence: String
}

struct BackendCatalogEntry: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let name: String
    let role: String
    let sourceURL: String
    let license: String
    let version: String
    let integrationState: BackendIntegrationState
    let selectable: Bool
    let capabilities: [BackendCapabilityRecord]
    let notes: [String]

    var isRunnable: Bool { integrationState.isRunnable && selectable }

    func capability(_ id: BackendCapabilityID) -> BackendCapabilityRecord? {
        capabilities.first { $0.capability == id }
    }
}

struct BackendCatalog: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let updatedAt: String
    let entries: [BackendCatalogEntry]

    static let empty = BackendCatalog(schemaVersion: 1, updatedAt: "unknown", entries: [])

    func entry(id: String?) -> BackendCatalogEntry? {
        guard let id else { return nil }
        return entries.first { $0.id == id }
    }
}

enum BackendRecommendationVerdict: String, Codable, Sendable {
    case ready
    case guarded
    case unavailable
    case blocked

    var displayName: String {
        switch self {
        case .ready: "Ready"
        case .guarded: "Experimental"
        case .unavailable: "No validated backend"
        case .blocked: "Blocked"
        }
    }
}

struct BackendRecommendation: Hashable, Sendable {
    let verdict: BackendRecommendationVerdict
    let selectedBackendID: String?
    let title: String
    let reasons: [String]
    let researchCandidateIDs: [String]
}

enum BackendRecommendationEvaluator {
    static func recommend(
        firmware: FirmwareImage,
        catalog: BackendCatalog,
        compatibility: CompatibilityManifest,
        activeBackendID: String,
        hostReady: Bool
    ) -> BackendRecommendation {
        let status = compatibility.entry(for: firmware)?.status
            ?? firmware.compatibilityStatus
            ?? .unverified
        let active = catalog.entry(id: activeBackendID)
        let candidates = catalog.entries
            .filter { $0.integrationState == .plannedAdapter || $0.integrationState == .researchOnly }
            .map(\.id)

        if status == .incompatible {
            return BackendRecommendation(
                verdict: .blocked,
                selectedBackendID: nil,
                title: "No backend selected",
                reasons: ["Recorded compatibility evidence marks this firmware configuration as incompatible."],
                researchCandidateIDs: candidates
            )
        }

        guard let active, active.isRunnable else {
            return BackendRecommendation(
                verdict: .unavailable,
                selectedBackendID: nil,
                title: "No runnable backend adapter",
                reasons: ["The catalog has no installed, selectable adapter. Research and reference entries cannot execute VMs."],
                researchCandidateIDs: candidates
            )
        }

        guard hostReady else {
            return BackendRecommendation(
                verdict: .unavailable,
                selectedBackendID: active.id,
                title: "\(active.name) requires host action",
                reasons: ["The adapter is installed, but host preflight is not ready. Resolve the Recovery policy or backend executable issue before launch."],
                researchCandidateIDs: candidates
            )
        }

        switch status {
        case .supported:
            return BackendRecommendation(
                verdict: .ready,
                selectedBackendID: active.id,
                title: "Use \(active.name)",
                reasons: ["The active adapter and compatibility database contain boot evidence for this firmware pairing."],
                researchCandidateIDs: []
            )
        case .experimental:
            return BackendRecommendation(
                verdict: .guarded,
                selectedBackendID: active.id,
                title: "Use \(active.name) experimentally",
                reasons: ["The firmware has experimental evidence. Explicit acknowledgement and preserved diagnostics are required."],
                researchCandidateIDs: candidates
            )
        case .researching:
            return BackendRecommendation(
                verdict: .unavailable,
                selectedBackendID: nil,
                title: "No validated backend for this research target",
                reasons: ["The installed adapter has no recorded boot evidence for this older-iOS target.", "QEMU remains a research candidate, not an installed adapter."],
                researchCandidateIDs: candidates
            )
        case .unverified:
            return BackendRecommendation(
                verdict: .guarded,
                selectedBackendID: active.id,
                title: "\(active.name) is the only runnable candidate",
                reasons: ["No firmware-specific boot evidence exists. The app can stage an acknowledged experiment but cannot claim support."],
                researchCandidateIDs: candidates
            )
        case .incompatible:
            fatalError("Handled above")
        }
    }
}

enum AttributionIntegrationState: String, Codable, Sendable {
    case activeExternal
    case platformFramework
    case transitiveExternal
    case planned
    case researchOnly
    case referenceOnly

    var displayName: String {
        switch self {
        case .activeExternal: "Active external tool"
        case .platformFramework: "Platform framework"
        case .transitiveExternal: "External transitive dependency"
        case .planned: "Planned"
        case .researchOnly: "Research only"
        case .referenceOnly: "Reference only"
        }
    }
}

enum AttributionReviewState: String, Codable, Sendable {
    case verified
    case conditional
    case referenceOnly

    var displayName: String {
        switch self {
        case .verified: "Recorded"
        case .conditional: "Review before integration"
        case .referenceOnly: "No source use"
        }
    }
}

struct AttributionRecord: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let name: String
    let role: String
    let sourceURL: String
    let license: String
    let version: String
    let integrationState: AttributionIntegrationState
    let reviewState: AttributionReviewState
    let sourceCodeUse: String
    let distributedWithApp: Bool
    let modifications: [String]
    let obligations: [String]
    let notes: [String]
}

struct AttributionCatalog: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let updatedAt: String
    let records: [AttributionRecord]

    static let empty = AttributionCatalog(schemaVersion: 1, updatedAt: "unknown", records: [])

    var completenessIssues: [String] {
        records.flatMap { record -> [String] in
            var issues: [String] = []
            if record.sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append("\(record.name) has no source URL.")
            }
            if record.license.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append("\(record.name) has no license or terms recorded.")
            }
            if record.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append("\(record.name) has no version or pinning status.")
            }
            if record.distributedWithApp && record.obligations.isEmpty {
                issues.append("\(record.name) is distributed without recorded obligations.")
            }
            return issues
        }
    }
}

enum ProjectCatalogLoader {
    static func loadBackends(paths: LabPaths) -> BackendCatalog {
        load(BackendCatalog.self, named: "backend-catalog.json", paths: paths) ?? .empty
    }

    static func loadAttribution(paths: LabPaths) -> AttributionCatalog {
        load(AttributionCatalog.self, named: "third-party-catalog.json", paths: paths) ?? .empty
    }

    private static func load<T: Decodable>(_ type: T.Type, named name: String, paths: LabPaths) -> T? {
        let manager = FileManager.default
        let candidates: [URL?] = [
            Bundle.main.resourceURL?.appendingPathComponent(name),
            URL(fileURLWithPath: manager.currentDirectoryPath).appendingPathComponent("Resources/\(name)"),
            paths.stateRoot.appendingPathComponent(name),
        ]
        for case let candidate? in candidates where manager.fileExists(atPath: candidate.path) {
            if let data = try? Data(contentsOf: candidate),
               let decoded = try? JSONDecoder().decode(type, from: data) {
                return decoded
            }
        }
        return nil
    }
}
