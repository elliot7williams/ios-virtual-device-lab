import Foundation

enum LabSection: String, CaseIterable, Identifiable {
    case devices = "Virtual Devices"
    case firmware = "Firmware Library"
    case profiles = "Hardware Profiles"
    case compatibility = "Compatibility"
    case backends = "Backends & Attribution"
    case snapshots = "Snapshots"
    case testRuns = "Test Runs"
    case automation = "Automation"
    case diagnostics = "Diagnostics & Performance"
    case operations = "Lab Operations"
    case developerTools = "Developer Tools"
    case plugins = "Plugins"
    case activity = "Activity"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .devices: "iphone.gen3"
        case .firmware: "shippingbox"
        case .profiles: "iphone.gen3.radiowaves.left.and.right"
        case .compatibility: "checkmark.seal"
        case .backends: "square.stack.3d.up"
        case .snapshots: "camera.filters"
        case .testRuns: "checklist"
        case .automation: "flowchart"
        case .diagnostics: "waveform.path.ecg"
        case .operations: "checkmark.shield"
        case .developerTools: "hammer"
        case .plugins: "puzzlepiece.extension"
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
    var isPaused: Bool = false
    var hardwareProfileID: String? = nil
    var networkConfiguration: NetworkConfiguration? = nil
    var audioConfiguration: AudioConfiguration? = nil
    var isolationPolicy: IsolationPolicy? = nil

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
    var device: String?
    var version: String?
    var build: String?
    let sizeBytes: Int64
    let importedAt: Date
    var sha256: String? = nil
    var validation: FirmwareValidation? = nil
    var compatibilityStatus: CompatibilityStatus? = nil
    var recommendedProfileID: String? = nil
    var manifestMetadata: IPSWManifestMetadata? = nil
    var provenance: FirmwareProvenance? = nil

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
            importedAt: importedAt,
            provenance: .localImport(path: url.path, importedAt: importedAt)
        )
    }
}

struct IPSWBuildIdentity: Codable, Hashable, Sendable {
    let deviceClass: String?
    let variant: String?
    let boardID: String?
    let chipID: String?
}

struct IPSWManifestMetadata: Codable, Hashable, Sendable {
    let productVersion: String?
    let productBuildVersion: String?
    let supportedProductTypes: [String]
    let buildIdentities: [IPSWBuildIdentity]
    let sourceEntry: String

    var primaryProductType: String? {
        supportedProductTypes.count == 1 ? supportedProductTypes[0] : nil
    }
}

enum FirmwareValidationState: String, Codable, Sendable {
    case valid
    case warning
    case invalid
}

struct FirmwareValidation: Codable, Hashable, Sendable {
    let state: FirmwareValidationState
    let checkedAt: Date
    let hasBuildManifest: Bool
    let archiveEntryCount: Int
    let issues: [String]
}

enum DiagnosticSeverity: String, Codable, CaseIterable, Sendable {
    case information
    case warning
    case critical
}

enum DiagnosticClassification: String, Codable, CaseIterable, Sendable {
    case appCrash
    case vmCrash
    case bootFailure
    case kernelPanic
    case resourcePressure
    case networkFailure
    case audioFailure
    case unknown
}

struct DiagnosticFinding: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let classification: DiagnosticClassification
    let severity: DiagnosticSeverity
    let title: String
    let evidence: String
    let recommendation: String
    let sourceFile: String?

    init(
        classification: DiagnosticClassification,
        severity: DiagnosticSeverity,
        title: String,
        evidence: String,
        recommendation: String,
        sourceFile: String? = nil
    ) {
        id = UUID()
        self.classification = classification
        self.severity = severity
        self.title = title
        self.evidence = evidence
        self.recommendation = recommendation
        self.sourceFile = sourceFile
    }
}

struct DiagnosticAnalysisReport: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let bundlePath: String
    let createdAt: Date
    let analyzer: String
    let findings: [DiagnosticFinding]
    let summary: String
}

struct DiagnosticPrivacyPolicy: Codable, Hashable, Sendable {
    var redactSecrets: Bool
    var redactPersonalData: Bool
    var includeHostProfile: Bool
    var includeScreenshots: Bool
    var maximumFileBytes: Int64
    var encryptExports: Bool

    static let standard = DiagnosticPrivacyPolicy(
        redactSecrets: true,
        redactPersonalData: true,
        includeHostProfile: false,
        includeScreenshots: true,
        maximumFileBytes: 50 * 1_048_576,
        encryptExports: false
    )
}

struct DiagnosticPrivacyPreview: Codable, Hashable, Sendable {
    let filesIncluded: Int
    let filesExcluded: Int
    let redactions: Int
    let totalBytes: Int64
    let warnings: [String]
}

enum CompatibilityStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case supported
    case experimental
    case researching
    case incompatible
    case unverified

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .supported: "Supported"
        case .experimental: "Experimental"
        case .researching: "Researching"
        case .incompatible: "Incompatible"
        case .unverified: "Unverified"
        }
    }
}

struct CompatibilityEntry: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let iosVersion: String
    let iosBuild: String?
    let device: String?
    let cloudOSVersion: String?
    let cloudOSBuild: String?
    let status: CompatibilityStatus
    let notes: String
    let validatedHosts: [String]
    let hardwareProfileIDs: [String]?
    let bootStatus: String?
    let knownIssues: [String]?
    let requiredPatches: [String]?
    let appDeploymentSupport: String?

    func matches(version: String?, build: String?, device candidateDevice: String?) -> Bool {
        guard let version else { return false }
        let versionMatches = version == iosVersion || version.hasPrefix(iosVersion + ".")
        let buildMatches = iosBuild == nil || iosBuild == build
        let deviceMatches = device == nil || device == candidateDevice
        return versionMatches && buildMatches && deviceMatches
    }
}

struct CompatibilityManifest: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let updatedAt: String
    let entries: [CompatibilityEntry]

    static let empty = CompatibilityManifest(schemaVersion: 1, updatedAt: "unknown", entries: [])

    func entry(for firmware: FirmwareImage) -> CompatibilityEntry? {
        if firmware.kind == .cloudOS {
            return entries.first { entry in
                guard let candidate = entry.cloudOSVersion,
                      let version = firmware.version else { return false }
                let versionMatches = version == candidate || version.hasPrefix(candidate + ".")
                let buildMatches = entry.cloudOSBuild == nil || entry.cloudOSBuild == firmware.build
                return versionMatches && buildMatches
            }
        }
        return entries.first { $0.matches(version: firmware.version, build: firmware.build, device: firmware.device) }
            ?? entries.first { $0.matches(version: firmware.version, build: nil, device: firmware.device) }
    }

    func status(for firmware: FirmwareImage) -> CompatibilityStatus {
        entry(for: firmware)?.status ?? .unverified
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
    var sha256: String? = nil
    var lastVerifiedAt: Date? = nil
    var integrityStatus: SnapshotIntegrityStatus? = nil

    var archiveURL: URL { URL(fileURLWithPath: archivePath) }

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

enum SnapshotIntegrityStatus: String, Codable, Sendable {
    case verified
    case changed
    case missing
    case unchecked
}

struct SnapshotVerification: Sendable {
    let snapshot: SnapshotRecord
    let status: SnapshotIntegrityStatus
    let message: String
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
    var timedOut: Bool = false
    var cancelled: Bool = false
    var outputLimitExceeded: Bool = false
    var duration: TimeInterval = 0

    var succeeded: Bool { exitCode == 0 }
}

enum TestRunKind: String, Codable, Sendable {
    case deployment
    case baselineAcceptance
}

enum TestRunState: String, Codable, Sendable {
    case queued
    case running
    case passed
    case failed
    case cancelled
}

struct DeviceTestResult: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let deviceName: String
    var state: TestRunState
    var message: String
    var screenshotPath: String?
    var diagnosticBundlePath: String?
    var startedAt: Date
    var completedAt: Date?
    var assertionResults: [TestAssertionResult]?
    var performanceSummary: String?

    init(deviceName: String, state: TestRunState = .queued, message: String = "Queued") {
        id = UUID()
        self.deviceName = deviceName
        self.state = state
        self.message = message
        startedAt = .now
    }

    init(
        id: UUID,
        deviceName: String,
        state: TestRunState,
        message: String,
        screenshotPath: String?,
        diagnosticBundlePath: String?,
        startedAt: Date,
        completedAt: Date?,
        assertionResults: [TestAssertionResult]? = nil,
        performanceSummary: String? = nil
    ) {
        self.id = id
        self.deviceName = deviceName
        self.state = state
        self.message = message
        self.screenshotPath = screenshotPath
        self.diagnosticBundlePath = diagnosticBundlePath
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.assertionResults = assertionResults
        self.performanceSummary = performanceSummary
    }
}

struct TestRunRecord: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let kind: TestRunKind
    let name: String
    let packagePath: String?
    let createdAt: Date
    var completedAt: Date?
    var state: TestRunState
    var results: [DeviceTestResult]
    var assertions: [TestAssertion]? = nil
    var reportPath: String? = nil
    var appArtifactID: UUID? = nil
}

struct LabResourcePolicy: Codable, Hashable, Sendable {
    var maximumConcurrentVMs: Int
    var maximumAggregateMemoryMB: Int
    var reservedHostMemoryMB: Int
    var maximumHostCPUPercent: Double

    static let standard = LabResourcePolicy(
        maximumConcurrentVMs: 2,
        maximumAggregateMemoryMB: 12_288,
        reservedHostMemoryMB: 4_096,
        maximumHostCPUPercent: 85
    )
}

enum AutomationAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case boot
    case installApp
    case waitForGuest
    case delay
    case screenshot
    case pressHome
    case setNetworkMode
    case samplePerformance
    case assertGuestReady
    case stop
    case snapshot
    case diagnostics

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .boot: "Boot"
        case .installApp: "Boot & Install App"
        case .waitForGuest: "Wait for Guest"
        case .delay: "Delay"
        case .screenshot: "Capture Screenshot"
        case .pressHome: "Press Home"
        case .setNetworkMode: "Set Network Mode"
        case .samplePerformance: "Sample Performance"
        case .assertGuestReady: "Assert Guest Ready"
        case .stop: "Stop"
        case .snapshot: "Create Snapshot"
        case .diagnostics: "Collect Diagnostics"
        }
    }
}

struct AutomationStep: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var action: AutomationAction
    var value: String?
    var delaySeconds: Double?
    var retryCount: Int?
    var continueOnFailure: Bool?
    var condition: String?

    init(
        _ action: AutomationAction,
        value: String? = nil,
        delaySeconds: Double = 0,
        retryCount: Int = 0,
        continueOnFailure: Bool = false,
        condition: String? = nil
    ) {
        id = UUID()
        self.action = action
        self.value = value
        self.delaySeconds = delaySeconds
        self.retryCount = retryCount
        self.continueOnFailure = continueOnFailure
        self.condition = condition
    }
}

struct AutomationWorkflow: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var steps: [AutomationStep]
    var isBuiltIn: Bool
    var schedule: String? = nil
    var headless: Bool? = nil
}

struct PluginDescriptor: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let name: String
    let version: String
    let executable: String
    let capabilities: [String]
    let arguments: [String]
    let description: String?
    var apiVersion: Int?
    var executableSHA256: String?
    var trusted: Bool?
    var permissions: [String]?
    var sandbox: PluginSandboxPolicy?

    init(
        id: String,
        name: String,
        version: String,
        executable: String,
        capabilities: [String],
        arguments: [String],
        description: String?,
        apiVersion: Int? = 1,
        executableSHA256: String? = nil,
        trusted: Bool? = false,
        permissions: [String]? = nil,
        sandbox: PluginSandboxPolicy? = nil
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.executable = executable
        self.capabilities = capabilities
        self.arguments = arguments
        self.description = description
        self.apiVersion = apiVersion
        self.executableSHA256 = executableSHA256
        self.trusted = trusted
        self.permissions = permissions
        self.sandbox = sandbox
    }
}

struct DiagnosticBundle: Identifiable, Hashable, Sendable {
    let id: UUID
    let deviceName: String
    let url: URL
    let createdAt: Date
}

struct ControlResponse: Sendable {
    let succeeded: Bool
    let path: String?
    let error: String?
    let imageData: Data?
}

struct StorageCheck: Sendable {
    let availableBytes: Int64
    let requiredBytes: Int64

    var isSufficient: Bool { availableBytes >= requiredBytes }

    var message: String {
        let available = ByteCountFormatter.string(fromByteCount: availableBytes, countStyle: .file)
        let required = ByteCountFormatter.string(fromByteCount: requiredBytes, countStyle: .file)
        return "\(available) available; \(required) required"
    }
}

struct BackendCapabilities: Sendable {
    let pause: Bool
    let screenshots: Bool
    let automation: Bool
    let guestLogs: Bool
    let networking: Bool
    let audio: Bool
    let performanceMetrics: Bool
    let crashExport: Bool
    let xcodeDeployment: Bool

    static let vphone = BackendCapabilities(
        pause: true,
        screenshots: true,
        automation: true,
        guestLogs: true,
        networking: true,
        audio: true,
        performanceMetrics: true,
        crashExport: true,
        xcodeDeployment: true
    )

    var featureSupport: [BackendFeatureSupport] {
        [
            BackendFeatureSupport(name: "NAT / bridged / offline networking", state: networking ? .available : .unavailable, reason: "Mapped to vphone VM network configuration"),
            BackendFeatureSupport(name: "Proxy injection", state: .unavailable, reason: "No guest proxy API is exposed by vphone"),
            BackendFeatureSupport(name: "Packet capture", state: .extensionRequired, reason: "Requires a trusted capture plugin with explicit permission"),
            BackendFeatureSupport(name: "Host audio input/output", state: audio ? .available : .unavailable, reason: "vphone provisions Virtio sound streams backed by host audio"),
            BackendFeatureSupport(name: "Audio interruptions and accessories", state: .unavailable, reason: "The engine does not expose interruption or Bluetooth/headphone simulation"),
            BackendFeatureSupport(name: "CPU, memory, and disk I/O", state: performanceMetrics ? .available : .unavailable, reason: "Measured from the host VM processes"),
            BackendFeatureSupport(name: "Guest GPU utilization and FPS", state: .unavailable, reason: "Virtualization.framework does not expose these counters"),
        ]
    }
}

enum BackendFeatureState: String, Codable, Sendable {
    case available
    case extensionRequired
    case unavailable
}

struct BackendFeatureSupport: Identifiable, Codable, Hashable, Sendable {
    let name: String
    let state: BackendFeatureState
    let reason: String
    var id: String { name }
}

final class OperationCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false

    func cancel() {
        lock.lock()
        requested = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return requested
    }
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
