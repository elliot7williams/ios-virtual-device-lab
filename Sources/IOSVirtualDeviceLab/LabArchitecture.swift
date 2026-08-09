import Foundation

// MARK: - Backend identity and operation reporting

struct BackendDescriptor: Codable, Hashable, Sendable {
    let id: String
    let name: String
    let version: String?
    let engine: String

    static let vphone = BackendDescriptor(
        id: "com.virtualdevicelab.vphone",
        name: "vphone-cli",
        version: nil,
        engine: "Apple Virtualization.framework / vphone"
    )
}

enum LabOperationKind: String, Codable, Sendable {
    case preflight
    case create
    case boot
    case stop
    case configure
    case snapshot
    case restore
    case firmware
    case testing
    case automation
    case diagnostics
}

enum LabOperationPhase: String, Codable, Sendable {
    case queued
    case validating
    case preparing
    case downloading
    case restoring
    case patching
    case booting
    case connecting
    case installing
    case capturing
    case exporting
    case verifying
    case cleaningUp
    case completed
    case failed
    case cancelled
}

struct LabProgressEvent: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let operationID: UUID
    let kind: LabOperationKind
    let phase: LabOperationPhase
    let fractionCompleted: Double?
    let message: String
    let timestamp: Date

    init(
        operationID: UUID,
        kind: LabOperationKind,
        phase: LabOperationPhase,
        fractionCompleted: Double? = nil,
        message: String
    ) {
        id = UUID()
        self.operationID = operationID
        self.kind = kind
        self.phase = phase
        self.fractionCompleted = fractionCompleted
        self.message = message
        timestamp = .now
    }
}

typealias LabProgressHandler = @Sendable (LabProgressEvent) -> Void

// MARK: - Virtual hardware profiles

enum HardwareProfileStatus: String, Codable, Sendable {
    case supported
    case experimental
    case researchOnly
}

struct DisplayProfile: Codable, Hashable, Sendable {
    let width: Int
    let height: Int
    let scale: Double
    let refreshRateHz: Int
}

struct GPUProfile: Codable, Hashable, Sendable {
    let family: String
    let acceleration: String
}

struct HardwareProfile: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let name: String
    let productType: String
    let soc: String
    let cpuCores: Int
    let memoryMB: Int
    let defaultStorageGB: Int
    let display: DisplayProfile
    let gpu: GPUProfile
    let networking: [NetworkMode]
    let minimumIOSMajor: Int
    let maximumIOSMajor: Int
    let status: HardwareProfileStatus
    let notes: String

    func supports(version: String?) -> Bool {
        guard let major = version.flatMap({ Int($0.split(separator: ".").first ?? "") }) else { return false }
        return (minimumIOSMajor...maximumIOSMajor).contains(major)
    }
}

struct HardwareProfileCatalog: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let updatedAt: String
    let profiles: [HardwareProfile]

    static let empty = HardwareProfileCatalog(schemaVersion: 1, updatedAt: "unknown", profiles: [])

    func profile(id: String?) -> HardwareProfile? {
        guard let id else { return nil }
        return profiles.first { $0.id == id }
    }

    func recommended(for firmware: FirmwareImage, entry: CompatibilityEntry?) -> HardwareProfile? {
        if let ids = entry?.hardwareProfileIDs {
            for id in ids where profile(id: id) != nil { return profile(id: id) }
        }
        if let device = firmware.device,
           let exact = profiles.first(where: { $0.productType == device }) {
            return exact
        }
        return profiles.first { $0.supports(version: firmware.version) }
    }
}

// MARK: - Device configuration

enum NetworkMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case nat
    case bridged
    case isolated
    case offline

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .nat: "Internet (NAT)"
        case .bridged: "Virtual Wi-Fi / Bridged"
        case .isolated: "Isolated Lab Network"
        case .offline: "Offline"
        }
    }

    var backendValue: String {
        switch self {
        case .nat: "nat"
        case .bridged: "bridged"
        case .isolated, .offline: "none"
        }
    }
}

struct NetworkConfiguration: Codable, Hashable, Sendable {
    var mode: NetworkMode
    var proxyURL: String?
    var captureTraffic: Bool
    var allowHostAccess: Bool

    static let standard = NetworkConfiguration(
        mode: .nat,
        proxyURL: nil,
        captureTraffic: false,
        allowHostAccess: false
    )
}

enum AudioRoute: String, Codable, CaseIterable, Identifiable, Sendable {
    case systemOutput
    case virtualDevice
    case muted

    var id: String { rawValue }
}

struct AudioConfiguration: Codable, Hashable, Sendable {
    var outputEnabled: Bool
    var inputEnabled: Bool
    var route: AudioRoute
    var sampleRateHz: Int
    var simulateInterruptions: Bool
    var backgroundAudioValidation: Bool

    static let playback = AudioConfiguration(
        outputEnabled: true,
        inputEnabled: false,
        route: .systemOutput,
        sampleRateHz: 48_000,
        simulateInterruptions: false,
        backgroundAudioValidation: true
    )
}

struct IsolationPolicy: Codable, Hashable, Sendable {
    var allowNetwork: Bool
    var allowHostNetwork: Bool
    var sharedFolderPath: String?
    var allowClipboard: Bool
    var allowHostIntegration: Bool

    static let strict = IsolationPolicy(
        allowNetwork: true,
        allowHostNetwork: false,
        sharedFolderPath: nil,
        allowClipboard: false,
        allowHostIntegration: false
    )
}

struct VMCreationRequest: Sendable {
    let operationID: UUID
    let name: String
    let hardwareProfile: HardwareProfile
    let variant: FirmwareVariant
    let diskSizeGB: Int
    let iphoneFirmware: FirmwareImage?
    let cloudOSFirmware: FirmwareImage?
    let network: NetworkConfiguration
    let audio: AudioConfiguration
    let isolation: IsolationPolicy
    let allowUnverifiedFirmware: Bool
}

struct VMConfigurationRequest: Sendable {
    let operationID: UUID
    let device: VirtualDevice
    let hardwareProfileID: String?
    let cpu: Int
    let memoryMB: Int
    let network: NetworkConfiguration
    let audio: AudioConfiguration
    let isolation: IsolationPolicy
}

struct LabDeviceMetadata: Codable, Hashable, Sendable {
    let schemaVersion: Int
    var hardwareProfileID: String?
    var network: NetworkConfiguration
    var audio: AudioConfiguration
    var isolation: IsolationPolicy
    var updatedAt: Date
}

enum CompatibilityDecision: String, Codable, Sendable {
    case allowed
    case warning
    case blocked
}

struct FirmwareRecommendation: Sendable {
    let decision: CompatibilityDecision
    let status: CompatibilityStatus
    let hardwareProfile: HardwareProfile?
    let cloudOSFirmware: FirmwareImage?
    let messages: [String]
}

// MARK: - App artifacts and test assertions

struct AppArtifact: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let name: String
    let path: String
    let importedAt: Date
    let sizeBytes: Int64
    let sha256: String?

    var url: URL { URL(fileURLWithPath: path) }
}

enum TestAssertionKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case guestReady
    case launchSucceeded
    case screenshotCaptured
    case exitCodeZero
    case diagnosticsCollected
    case maximumDuration

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .guestReady: "Guest control connected"
        case .launchSucceeded: "App deployment completed"
        case .screenshotCaptured: "Screenshot captured"
        case .exitCodeZero: "VM exited cleanly"
        case .diagnosticsCollected: "Diagnostics collected"
        case .maximumDuration: "Completed within time limit"
        }
    }
}

struct TestAssertion: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var kind: TestAssertionKind
    var expectedValue: String?
    var isRequired: Bool

    init(_ kind: TestAssertionKind, expectedValue: String? = nil, isRequired: Bool = true) {
        id = UUID()
        self.kind = kind
        self.expectedValue = expectedValue
        self.isRequired = isRequired
    }

    static let deploymentDefaults: [TestAssertion] = [
        TestAssertion(.guestReady),
        TestAssertion(.launchSucceeded),
        TestAssertion(.screenshotCaptured),
        TestAssertion(.exitCodeZero),
    ]
}

struct TestAssertionResult: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let assertion: TestAssertion
    let passed: Bool
    let message: String

    init(assertion: TestAssertion, passed: Bool, message: String) {
        id = UUID()
        self.assertion = assertion
        self.passed = passed
        self.message = message
    }
}

// MARK: - Performance, diagnostics, and retention

struct PerformanceSample: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let deviceName: String
    let timestamp: Date
    let cpuPercent: Double?
    let residentMemoryBytes: Int64?
    let diskReadBytesPerSecond: Int64?
    let diskWriteBytesPerSecond: Int64?
    let gpuPercent: Double?
    let framesPerSecond: Double?
    let audioSampleRateHz: Int?
    let source: String

    init(
        deviceName: String,
        cpuPercent: Double?,
        residentMemoryBytes: Int64?,
        diskReadBytesPerSecond: Int64? = nil,
        diskWriteBytesPerSecond: Int64? = nil,
        gpuPercent: Double? = nil,
        framesPerSecond: Double? = nil,
        audioSampleRateHz: Int? = nil,
        source: String
    ) {
        id = UUID()
        self.deviceName = deviceName
        timestamp = .now
        self.cpuPercent = cpuPercent
        self.residentMemoryBytes = residentMemoryBytes
        self.diskReadBytesPerSecond = diskReadBytesPerSecond
        self.diskWriteBytesPerSecond = diskWriteBytesPerSecond
        self.gpuPercent = gpuPercent
        self.framesPerSecond = framesPerSecond
        self.audioSampleRateHz = audioSampleRateHz
        self.source = source
    }
}

enum DiagnosticCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case managerLogs
    case hostLogs
    case guestSystemLogs
    case applicationLogs
    case appCrashes
    case vmCrashes
    case bootFailures
    case kernelPanics
    case performance

    var id: String { rawValue }
}

struct DiagnosticExportResult: Sendable {
    let supported: Bool
    let categories: [DiagnosticCategory]
    let outputURL: URL?
    let message: String
}

struct SnapshotRetentionPolicy: Codable, Hashable, Sendable {
    var isEnabled: Bool
    var keepLastPerDevice: Int
    var maximumAgeDays: Int
    var maximumTotalBytes: Int64
    var verifyBeforePruning: Bool

    static let standard = SnapshotRetentionPolicy(
        isEnabled: false,
        keepLastPerDevice: 5,
        maximumAgeDays: 30,
        maximumTotalBytes: 100 * 1_073_741_824,
        verifyBeforePruning: true
    )
}

struct SnapshotRetentionResult: Sendable {
    let removed: [SnapshotRecord]
    let preserved: [SnapshotRecord]
    let reclaimedBytes: Int64
}

struct XcodeIntegrationStatus: Sendable {
    let xcodePath: String?
    let xcodebuildVersion: String?
    let commandLineToolsReady: Bool
    let helperScriptURL: URL?
}
