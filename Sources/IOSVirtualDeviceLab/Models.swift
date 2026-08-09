import Foundation

enum LabSection: String, CaseIterable, Identifiable {
    case devices = "Virtual Devices"
    case firmware = "Firmware Library"
    case snapshots = "Snapshots"
    case activity = "Activity"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .devices: "iphone.gen3"
        case .firmware: "shippingbox"
        case .snapshots: "camera.filters"
        case .activity: "text.alignleft"
        }
    }
}

enum FirmwareKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case iPhone = "iPhone"
    case cloudOS = "cloudOS"

    var id: String { rawValue }
}

enum FirmwareVariant: String, Codable, CaseIterable, Identifiable, Sendable {
    case regular
    case dev
    case jb
    case exp
    case less

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .regular: "Regular"
        case .dev: "Development"
        case .jb: "Jailbreak"
        case .exp: "Experimental"
        case .less: "Patchless"
        }
    }

    var explanation: String {
        switch self {
        case .regular: "Standard security and compatibility patches"
        case .dev: "Regular patches plus developer/debug support"
        case .jb: "Full jailbreak with Sileo and TrollStore setup"
        case .exp: "Jailbreak plus experimental anti-VM-detection patches"
        case .less: "Minimal boot-chain patches; keeps most iOS mitigations"
        }
    }
}

struct NetworkReport: Codable, Hashable, Sendable {
    let mode: String
    let macAddress: String?
    let bridgeInterface: String?
}

struct OSVersionReport: Codable, Hashable, Sendable {
    let version: String
    let build: String
}

struct RestoreInfoReport: Codable, Hashable, Sendable {
    let ios: OSVersionReport
    let cloudOS: OSVersionReport
    let variant: String?
    let device: String?
}

struct VirtualDevice: Identifiable, Hashable, Sendable {
    let name: String
    let cpuCount: Int
    let memoryMB: Int
    let diskSizeBytes: Int64
    let network: NetworkReport
    let restoreInfo: RestoreInfoReport?
    let udid: String?
    let bundleURL: URL
    let diskURL: URL
    var isRunning: Bool

    var id: String { name }

    var iosLabel: String {
        guard let ios = restoreInfo?.ios else { return "Not restored" }
        return "iOS \(ios.version)"
    }

    var buildLabel: String {
        restoreInfo?.ios.build ?? "—"
    }

    var variantLabel: String {
        restoreInfo?.variant?.capitalized ?? "Unknown"
    }

    var memoryLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(memoryMB) * 1_048_576, countStyle: .memory)
    }

    var diskLabel: String {
        ByteCountFormatter.string(fromByteCount: diskSizeBytes, countStyle: .file)
    }
}

struct BackendVMReport: Codable, Sendable {
    let name: String
    let cpuCount: Int
    let memoryMB: Int
    let diskSizeBytes: Int64
    let network: NetworkReport
    let restoreInfo: RestoreInfoReport?
    let udid: String?
}

struct FirmwareImage: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var kind: FirmwareKind
    let path: String
    let fileName: String
    let device: String?
    let version: String?
    let build: String?
    let sizeBytes: Int64
    let importedAt: Date

    var url: URL { URL(fileURLWithPath: path) }

    var versionLabel: String {
        [version, build].compactMap { $0 }.joined(separator: " • ").nilIfEmpty ?? "Unknown version"
    }

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    static func inspect(
        _ url: URL,
        kind override: FirmwareKind? = nil,
        importedAt: Date = .now
    ) -> FirmwareImage {
        let name = url.lastPathComponent
        let parsed = FirmwareFilenameParser.parse(name)
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let lower = name.lowercased()
        let inferred: FirmwareKind = lower.contains("cloud") || lower.contains("universal")
            ? .cloudOS : .iPhone
        return FirmwareImage(
            id: UUID(),
            kind: override ?? inferred,
            path: url.path,
            fileName: name,
            device: parsed.device,
            version: parsed.version,
            build: parsed.build,
            sizeBytes: size,
            importedAt: importedAt
        )
    }
}

enum FirmwareFilenameParser {
    struct Result: Equatable, Sendable {
        let device: String?
        let version: String?
        let build: String?
    }

    static func parse(_ fileName: String) -> Result {
        var stem = fileName
        if stem.lowercased().hasSuffix(".ipsw") { stem.removeLast(5) }
        if stem.hasSuffix("_Restore") { stem.removeLast("_Restore".count) }

        let pieces = stem.split(separator: "_", omittingEmptySubsequences: true).map(String.init)
        guard pieces.count >= 3 else {
            return Result(device: nil, version: nil, build: nil)
        }
        return Result(
            device: pieces[0],
            version: pieces[1],
            build: pieces.dropFirst(2).joined(separator: "_")
        )
    }
}

struct SnapshotRecord: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let name: String
    let sourceVM: String
    let createdAt: Date
    let archivePath: String
    var sizeBytes: Int64

    var archiveURL: URL { URL(fileURLWithPath: archivePath) }

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

enum ReadinessState: String, Sendable {
    case ready
    case actionRequired
    case unavailable
}

struct HostReadiness: Sendable {
    let state: ReadinessState
    let macOSVersion: String
    let model: String
    let architecture: String
    let sipStatus: String
    let researchGuestsStatus: String
    let binaryPath: String?
    let binaryExitCode: Int32?
    let nestedVirtualization: Bool
    let checkedAt: Date

    var isReady: Bool { state == .ready }

    static let checking = HostReadiness(
        state: .actionRequired,
        macOSVersion: "Checking…",
        model: "Checking…",
        architecture: "arm64",
        sipStatus: "Checking…",
        researchGuestsStatus: "Checking…",
        binaryPath: nil,
        binaryExitCode: nil,
        nestedVirtualization: false,
        checkedAt: .distantPast
    )
}

enum LogLevel: String, Codable, Sendable {
    case info
    case success
    case warning
    case error
    case command
}

struct LogEntry: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let timestamp: Date
    let level: LogLevel
    let scope: String
    let message: String

    init(level: LogLevel, scope: String, message: String) {
        id = UUID()
        timestamp = .now
        self.level = level
        self.scope = scope
        self.message = message
    }
}

struct CommandResult: Sendable {
    let executable: String
    let arguments: [String]
    let output: String
    let exitCode: Int32

    var succeeded: Bool { exitCode == 0 }
}

struct LabPaths: Sendable {
    let dataRoot: URL
    let libraryRoot: URL
    let firmwareRoot: URL
    let snapshotsRoot: URL
    let stateRoot: URL

    static var `default`: LabPaths {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let root = home.appendingPathComponent(".vphone", isDirectory: true)
        return LabPaths(
            dataRoot: root,
            libraryRoot: root.appendingPathComponent("VMs", isDirectory: true),
            firmwareRoot: root.appendingPathComponent("ipsws", isDirectory: true),
            snapshotsRoot: root.appendingPathComponent("Snapshots", isDirectory: true),
            stateRoot: root.appendingPathComponent("VirtualDeviceLab", isDirectory: true)
        )
    }

    func createDirectories() throws {
        let fm = FileManager.default
        for url in [dataRoot, libraryRoot, firmwareRoot, snapshotsRoot, stateRoot] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}

enum NameSanitizer {
    static func fileComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let mapped = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
        let collapsed = String(mapped)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "snapshot" : collapsed
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
