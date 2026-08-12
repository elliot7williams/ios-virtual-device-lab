import Foundation

protocol LabBackend: Sendable {
    var descriptor: BackendDescriptor { get async }
    var capabilities: BackendCapabilities { get async }

    func prepareStorage() async throws
    func checkHost() async -> HostReadiness
    func listDevices() async -> [VirtualDevice]
    func loadSnapshots() async -> [SnapshotRecord]
    func loadFirmware() async -> [FirmwareImage]

    func createVM(
        request: VMCreationRequest,
        onProgress: @escaping LabProgressHandler,
        onLine: @escaping @Sendable (String) -> Void
    ) async -> CommandResult
    func launch(
        _ device: VirtualDevice,
        installPackage: URL?,
        onLine: @escaping @Sendable (String) -> Void
    ) async -> CommandResult
    func stop(
        _ device: VirtualDevice,
        onLine: @escaping @Sendable (String) -> Void
    ) async -> CommandResult
    func pause(
        _ device: VirtualDevice,
        onLine: @escaping @Sendable (String) -> Void
    ) async -> CommandResult
    func resume(
        _ device: VirtualDevice,
        onLine: @escaping @Sendable (String) -> Void
    ) async -> CommandResult
    func clone(
        _ device: VirtualDevice,
        as newName: String,
        onLine: @escaping @Sendable (String) -> Void
    ) async -> CommandResult
    func deleteVM(
        _ device: VirtualDevice,
        onLine: @escaping @Sendable (String) -> Void
    ) async -> CommandResult
    func updateConfiguration(
        request: VMConfigurationRequest,
        onProgress: @escaping LabProgressHandler,
        onLine: @escaping @Sendable (String) -> Void
    ) async -> CommandResult

    func createSnapshot(
        of device: VirtualDevice,
        named snapshotName: String,
        onLine: @escaping @Sendable (String) -> Void
    ) async -> (CommandResult, SnapshotRecord?)
    func restoreSnapshot(
        _ snapshot: SnapshotRecord,
        as newName: String,
        onLine: @escaping @Sendable (String) -> Void
    ) async -> CommandResult
    func verifySnapshot(_ snapshot: SnapshotRecord) async -> SnapshotVerification
    func deleteSnapshot(_ snapshot: SnapshotRecord) async throws

    func importFirmware(_ urls: [URL], kind: FirmwareKind) async throws -> [FirmwareImage]
    func validateFirmware(
        _ firmware: FirmwareImage,
        compatibility: CompatibilityManifest
    ) async throws -> [FirmwareImage]
    func updateFirmwareKind(_ firmware: FirmwareImage, kind: FirmwareKind) async throws -> [FirmwareImage]
    func forgetFirmware(_ firmware: FirmwareImage) async throws -> [FirmwareImage]

    func storageCheck(requiredBytes: Int64) async -> StorageCheck
    func captureScreenshot(_ device: VirtualDevice, destination: URL) async -> ControlResponse
    func sendHardwareKey(_ device: VirtualDevice, name: String) async -> ControlResponse
    func guestProtocolHandshake(for device: VirtualDevice) async -> GuestProtocolHandshake
    func createDiagnosticBundle(
        for device: VirtualDevice,
        activityLog: String
    ) async throws -> DiagnosticBundle
    func performanceSample(for device: VirtualDevice) async -> PerformanceSample
    func exportGuestDiagnostics(
        for device: VirtualDevice,
        categories: [DiagnosticCategory],
        destination: URL
    ) async -> DiagnosticExportResult
    func cancelAllOperations() async
}

actor MockLabBackend: LabBackend {
    let descriptor = BackendDescriptor(id: "mock", name: "Mock Lab Backend", version: "1", engine: "In-memory")
    let capabilities = BackendCapabilities.vphone
    private var devices: [VirtualDevice]
    private var firmware: [FirmwareImage]
    private var snapshots: [SnapshotRecord]
    private let readiness: HostReadiness

    init(
        devices: [VirtualDevice] = [],
        firmware: [FirmwareImage] = [],
        snapshots: [SnapshotRecord] = [],
        readiness: HostReadiness = HostReadiness(
            state: .ready,
            macOSVersion: "15.0",
            model: "MockMac",
            architecture: "arm64",
            sipStatus: "mock",
            researchGuestsStatus: "enabled",
            binaryPath: "/mock/vphone-cli",
            binaryExitCode: 0,
            nestedVirtualization: false,
            checkedAt: .now
        )
    ) {
        self.devices = devices
        self.firmware = firmware
        self.snapshots = snapshots
        self.readiness = readiness
    }

    func prepareStorage() {}
    func checkHost() -> HostReadiness { readiness }
    func listDevices() -> [VirtualDevice] { devices }
    func loadSnapshots() -> [SnapshotRecord] { snapshots }
    func loadFirmware() -> [FirmwareImage] { firmware }

    private func success(_ arguments: [String], line: String, onLine: @Sendable (String) -> Void) -> CommandResult {
        onLine(line)
        return CommandResult(executable: "mock-vphone-cli", arguments: arguments, output: line, exitCode: 0)
    }

    func createVM(
        request: VMCreationRequest,
        onProgress: @escaping LabProgressHandler,
        onLine: @escaping @Sendable (String) -> Void
    ) -> CommandResult {
        onProgress(LabProgressEvent(
            operationID: request.operationID,
            kind: .create,
            phase: .completed,
            fractionCompleted: 1,
            message: "Mock VM created"
        ))
        return success(["vm", "create", request.name], line: "created \(request.name)", onLine: onLine)
    }

    func launch(
        _ device: VirtualDevice,
        installPackage: URL?,
        onLine: @escaping @Sendable (String) -> Void
    ) -> CommandResult {
        success(["vm", "launch", device.name], line: "launched \(device.name)", onLine: onLine)
    }

    func stop(_ device: VirtualDevice, onLine: @escaping @Sendable (String) -> Void) -> CommandResult {
        success(["vm", "stop", device.name], line: "stopped \(device.name)", onLine: onLine)
    }

    func pause(_ device: VirtualDevice, onLine: @escaping @Sendable (String) -> Void) -> CommandResult {
        success(["pause", device.name], line: "paused \(device.name)", onLine: onLine)
    }

    func resume(_ device: VirtualDevice, onLine: @escaping @Sendable (String) -> Void) -> CommandResult {
        success(["resume", device.name], line: "resumed \(device.name)", onLine: onLine)
    }

    func clone(
        _ device: VirtualDevice,
        as newName: String,
        onLine: @escaping @Sendable (String) -> Void
    ) -> CommandResult {
        success(["vm", "clone", device.name, newName], line: "cloned \(newName)", onLine: onLine)
    }

    func deleteVM(_ device: VirtualDevice, onLine: @escaping @Sendable (String) -> Void) -> CommandResult {
        success(["vm", "delete", device.name], line: "deleted \(device.name)", onLine: onLine)
    }

    func updateConfiguration(
        request: VMConfigurationRequest,
        onProgress: @escaping LabProgressHandler,
        onLine: @escaping @Sendable (String) -> Void
    ) -> CommandResult {
        onProgress(LabProgressEvent(
            operationID: request.operationID,
            kind: .configure,
            phase: .completed,
            fractionCompleted: 1,
            message: "Mock configuration applied"
        ))
        return success(
            ["vm", "config", request.device.name],
            line: "configured \(request.device.name)",
            onLine: onLine
        )
    }

    func createSnapshot(
        of device: VirtualDevice,
        named snapshotName: String,
        onLine: @escaping @Sendable (String) -> Void
    ) -> (CommandResult, SnapshotRecord?) {
        let record = SnapshotRecord(
            id: UUID(),
            name: snapshotName,
            sourceVM: device.name,
            createdAt: .now,
            archivePath: "/mock/\(snapshotName).tgz",
            sizeBytes: 1
        )
        snapshots.append(record)
        return (success(["vm", "export"], line: "snapshot created", onLine: onLine), record)
    }

    func restoreSnapshot(
        _ snapshot: SnapshotRecord,
        as newName: String,
        onLine: @escaping @Sendable (String) -> Void
    ) -> CommandResult {
        success(["vm", "import"], line: "restored \(newName)", onLine: onLine)
    }

    func verifySnapshot(_ snapshot: SnapshotRecord) -> SnapshotVerification {
        var copy = snapshot
        copy.integrityStatus = .verified
        copy.lastVerifiedAt = .now
        return SnapshotVerification(snapshot: copy, status: .verified, message: "Mock snapshot verified")
    }

    func deleteSnapshot(_ snapshot: SnapshotRecord) {
        snapshots.removeAll { $0.id == snapshot.id }
    }

    func importFirmware(_ urls: [URL], kind: FirmwareKind) -> [FirmwareImage] {
        firmware += urls.map { FirmwareImage.inspect($0, kind: kind) }
        return firmware
    }

    func validateFirmware(
        _ image: FirmwareImage,
        compatibility: CompatibilityManifest
    ) -> [FirmwareImage] {
        firmware = firmware.map { item in
            guard item.id == image.id else { return item }
            var copy = item
            copy.compatibilityStatus = compatibility.status(for: item)
            copy.validation = FirmwareValidation(
                state: .valid,
                checkedAt: .now,
                hasBuildManifest: true,
                archiveEntryCount: 1,
                issues: []
            )
            return copy
        }
        return firmware
    }

    func updateFirmwareKind(_ image: FirmwareImage, kind: FirmwareKind) -> [FirmwareImage] {
        firmware = firmware.map { item in
            guard item.id == image.id else { return item }
            var copy = item
            copy.kind = kind
            return copy
        }
        return firmware
    }

    func forgetFirmware(_ image: FirmwareImage) -> [FirmwareImage] {
        firmware.removeAll { $0.id == image.id }
        return firmware
    }

    func storageCheck(requiredBytes: Int64) -> StorageCheck {
        StorageCheck(availableBytes: .max, requiredBytes: requiredBytes)
    }

    func captureScreenshot(_ device: VirtualDevice, destination: URL) -> ControlResponse {
        ControlResponse(succeeded: true, path: destination.path, error: nil, imageData: nil)
    }

    func sendHardwareKey(_ device: VirtualDevice, name: String) -> ControlResponse {
        ControlResponse(succeeded: true, path: nil, error: nil, imageData: nil)
    }

    func guestProtocolHandshake(for device: VirtualDevice) -> GuestProtocolHandshake {
        GuestProtocolHandshake(
            status: .compatible,
            negotiatedVersion: 3,
            minimumSupportedVersion: 1,
            maximumSupportedVersion: 3,
            capabilities: [.screenshots, .hardwareKeys, .guestFiles, .audioOutput, .networking],
            maximumMessageBytes: 1_048_576,
            authenticated: true,
            replayProtected: true,
            authenticationClockSkewSeconds: 30,
            transport: "Mock in-memory transport",
            message: "Mock authenticated guest protocol v3"
        )
    }

    func createDiagnosticBundle(for device: VirtualDevice, activityLog: String) -> DiagnosticBundle {
        DiagnosticBundle(id: UUID(), deviceName: device.name, url: URL(fileURLWithPath: "/mock/diagnostics"), createdAt: .now)
    }

    func performanceSample(for device: VirtualDevice) -> PerformanceSample {
        PerformanceSample(
            deviceName: device.name,
            cpuPercent: device.isRunning ? 12 : 0,
            residentMemoryBytes: device.isRunning ? 512 * 1_048_576 : 0,
            gpuPercent: nil,
            framesPerSecond: nil,
            audioSampleRateHz: device.audioConfiguration?.sampleRateHz,
            source: "Mock backend"
        )
    }

    func exportGuestDiagnostics(
        for device: VirtualDevice,
        categories: [DiagnosticCategory],
        destination: URL
    ) -> DiagnosticExportResult {
        DiagnosticExportResult(
            supported: false,
            categories: categories,
            outputURL: nil,
            message: "Mock guest diagnostics are not configured"
        )
    }

    func cancelAllOperations() {}
}
