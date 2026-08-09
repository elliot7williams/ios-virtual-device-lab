import AppKit
import Foundation
import SwiftUI

@MainActor
final class LabAppModel: ObservableObject {
    @Published var selectedSection: LabSection = .devices
    @Published var selectedDeviceID: String?
    @Published private(set) var devices: [VirtualDevice] = []
    @Published private(set) var firmware: [FirmwareImage] = []
    @Published private(set) var snapshots: [SnapshotRecord] = []
    @Published private(set) var compatibility: CompatibilityManifest = .empty
    @Published private(set) var testRuns: [TestRunRecord] = []
    @Published private(set) var workflows: [AutomationWorkflow] = []
    @Published private(set) var plugins: [PluginDescriptor] = []
    @Published private(set) var diagnosticBundles: [DiagnosticBundle] = []
    @Published private(set) var backendCapabilities: BackendCapabilities = .vphone
    @Published private(set) var logs: [LogEntry] = []
    @Published private(set) var readiness: HostReadiness = .checking
    @Published private(set) var busyKeys: Set<String> = []
    @Published var alertMessage: String?

    let paths: LabPaths
    private let backend: any LabBackend
    private var didBootstrap = false
    private var orchestrationFlags: [UUID: OperationCancellationFlag] = [:]

    init(paths: LabPaths = .default, backend: (any LabBackend)? = nil) {
        self.paths = paths
        self.backend = backend ?? VPhoneBackend(paths: paths)
    }

    var selectedDevice: VirtualDevice? {
        devices.first { $0.id == selectedDeviceID }
    }

    var isBusy: Bool { !busyKeys.isEmpty }

    func isBusy(_ key: String) -> Bool { busyKeys.contains(key) }

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        do {
            try await backend.prepareStorage()
            try PluginRegistry.prepare(paths: paths)
            compatibility = CompatibilityCatalog.load(paths: paths)
            testRuns = TestRunStore.load(paths: paths)
            workflows = WorkflowStore.load(paths: paths)
            plugins = PluginRegistry.loadPlugins(paths: paths)
            backendCapabilities = await backend.capabilities
            loadPersistedLogs()
            appendLog(.info, scope: "lab", "Storage: \(paths.dataRoot.path)")
            await refreshAll()
        } catch {
            present(error, context: "Preparing lab storage")
        }
    }

    func refreshAll() async {
        busyKeys.insert("refresh")
        readiness = await backend.checkHost()
        devices = await backend.listDevices()
        snapshots = await backend.loadSnapshots()
        firmware = await backend.loadFirmware()
        normalizeSelection()
        busyKeys.remove("refresh")

        switch readiness.state {
        case .ready:
            appendLog(.success, scope: "preflight", "Host is ready for PV=3 virtual devices")
        case .actionRequired:
            let code = readiness.binaryExitCode.map(String.init) ?? "unknown"
            appendLog(.warning, scope: "preflight", "Host policy action required (vphone exit \(code))")
        case .unavailable:
            appendLog(.error, scope: "preflight", "This host cannot run the selected virtualization backend")
        }
        persistLogs()
    }

    func refreshDevices() async {
        devices = await backend.listDevices()
        normalizeSelection()
    }

    func recheckHost() async {
        busyKeys.insert("preflight")
        readiness = await backend.checkHost()
        busyKeys.remove("preflight")
        appendLog(
            readiness.isReady ? .success : .warning,
            scope: "preflight",
            readiness.isReady ? "Host preflight passed" : "Host preflight still requires action"
        )
        persistLogs()
    }

    // MARK: - VM lifecycle

    func createVM(
        name: String,
        variant: FirmwareVariant,
        diskSizeGB: Int,
        iphoneIPSW: URL?,
        cloudOSIPSW: URL?
    ) async {
        guard requireReady(for: "Create VM") else { return }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            alertMessage = "Enter a name for the virtual device."
            return
        }
        let key = "create:\(name)"
        busyKeys.insert(key)
        appendLog(.command, scope: name, "Creating \(variant.displayName) VM with a \(diskSizeGB) GB disk")
        let result = await backend.createVM(
            name: name,
            variant: variant,
            diskSizeGB: diskSizeGB,
            iphoneIPSW: iphoneIPSW,
            cloudOSIPSW: cloudOSIPSW,
            onLine: logger(scope: name)
        )
        finish(result, scope: name, success: "VM creation completed")
        busyKeys.remove(key)
        await refreshDevices()
        if result.succeeded { selectedDeviceID = name }
    }

    func launch(_ device: VirtualDevice, installPackage: URL? = nil) async {
        guard requireReady(for: installPackage == nil ? "Boot VM" : "Install app") else { return }
        guard !device.isRunning else {
            alertMessage = installPackage == nil
                ? "\(device.name) is already running."
                : "Stop \(device.name), then use Launch & Install. A running VM can also install from its own Install menu."
            return
        }
        let key = "launch:\(device.id)"
        busyKeys.insert(key)
        let packageSuffix = installPackage.map { " and installing \($0.lastPathComponent)" } ?? ""
        appendLog(.command, scope: device.name, "Launching VM\(packageSuffix)")

        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            await self?.refreshDevices()
        }

        let result = await backend.launch(
            device,
            installPackage: installPackage,
            onLine: logger(scope: device.name)
        )
        finish(result, scope: device.name, success: "VM process exited cleanly")
        busyKeys.remove(key)
        await refreshDevices()
    }

    func stop(_ device: VirtualDevice) async {
        guard requireReady(for: "Stop VM") else { return }
        let key = "stop:\(device.id)"
        busyKeys.insert(key)
        appendLog(.command, scope: device.name, "Requesting graceful shutdown")
        let result = await backend.stop(device, onLine: logger(scope: device.name))
        finish(result, scope: device.name, success: "VM stopped")
        busyKeys.remove(key)
        await refreshDevices()
    }

    func pause(_ device: VirtualDevice) async {
        guard requireReady(for: "Pause VM") else { return }
        guard backendCapabilities.pause, device.isRunning, !device.isPaused else { return }
        let key = "pause:\(device.id)"
        busyKeys.insert(key)
        appendLog(.command, scope: device.name, "Pausing VM processes")
        let result = await backend.pause(device, onLine: logger(scope: device.name))
        finish(result, scope: device.name, success: "VM paused")
        busyKeys.remove(key)
        await refreshDevices()
    }

    func resume(_ device: VirtualDevice) async {
        guard requireReady(for: "Resume VM") else { return }
        guard backendCapabilities.pause, device.isRunning, device.isPaused else { return }
        let key = "resume:\(device.id)"
        busyKeys.insert(key)
        appendLog(.command, scope: device.name, "Resuming VM processes")
        let result = await backend.resume(device, onLine: logger(scope: device.name))
        finish(result, scope: device.name, success: "VM resumed")
        busyKeys.remove(key)
        await refreshDevices()
    }

    func cancelOperations() async {
        for flag in orchestrationFlags.values { flag.cancel() }
        await backend.cancelAllOperations()
        appendLog(.warning, scope: "lab", "Cancellation requested for active backend operations")
        persistLogs()
    }

    func clone(_ device: VirtualDevice, as newName: String) async {
        guard requireReady(for: "Clone VM") else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { alertMessage = "Enter a name for the clone."; return }
        let key = "clone:\(device.id)"
        busyKeys.insert(key)
        appendLog(.command, scope: device.name, "Cloning as \(trimmed)")
        let result = await backend.clone(device, as: trimmed, onLine: logger(scope: device.name))
        finish(result, scope: device.name, success: "Clone created: \(trimmed)")
        busyKeys.remove(key)
        await refreshDevices()
        if result.succeeded { selectedDeviceID = trimmed }
    }

    func updateConfiguration(
        _ device: VirtualDevice,
        cpu: Int,
        memoryMB: Int,
        network: String
    ) async {
        guard requireReady(for: "Update VM") else { return }
        guard !device.isRunning else {
            alertMessage = "Stop \(device.name) before changing its hardware configuration."
            return
        }
        let key = "config:\(device.id)"
        busyKeys.insert(key)
        appendLog(.command, scope: device.name, "Updating hardware configuration")
        let result = await backend.updateConfiguration(
            device,
            cpu: cpu,
            memoryMB: memoryMB,
            network: network,
            onLine: logger(scope: device.name)
        )
        finish(result, scope: device.name, success: "Configuration updated")
        busyKeys.remove(key)
        await refreshDevices()
    }

    func delete(_ device: VirtualDevice) async {
        guard requireReady(for: "Delete VM") else { return }
        guard !device.isRunning else {
            alertMessage = "Stop \(device.name) before deleting it."
            return
        }
        let key = "delete:\(device.id)"
        busyKeys.insert(key)
        appendLog(.command, scope: device.name, "Deleting VM bundle")
        let result = await backend.deleteVM(device, onLine: logger(scope: device.name))
        finish(result, scope: device.name, success: "VM deleted")
        busyKeys.remove(key)
        await refreshDevices()
    }

    // MARK: - Snapshots

    func createSnapshot(of device: VirtualDevice, name: String) async {
        guard requireReady(for: "Create snapshot") else { return }
        guard !device.isRunning else {
            alertMessage = "Stop \(device.name) before creating a consistent snapshot."
            return
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { alertMessage = "Enter a snapshot name."; return }
        let key = "snapshot:\(device.id)"
        busyKeys.insert(key)
        appendLog(.command, scope: device.name, "Creating snapshot “\(trimmed)”")
        let (result, _) = await backend.createSnapshot(
            of: device,
            named: trimmed,
            onLine: logger(scope: device.name)
        )
        finish(result, scope: device.name, success: "Snapshot created")
        busyKeys.remove(key)
        snapshots = await backend.loadSnapshots()
    }

    func restore(_ snapshot: SnapshotRecord, as newName: String) async {
        guard requireReady(for: "Restore snapshot") else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { alertMessage = "Enter a name for the restored VM."; return }
        let key = "restore:\(snapshot.id.uuidString)"
        busyKeys.insert(key)
        appendLog(.command, scope: snapshot.sourceVM, "Restoring “\(snapshot.name)” as \(trimmed)")
        let result = await backend.restoreSnapshot(
            snapshot,
            as: trimmed,
            onLine: logger(scope: snapshot.sourceVM)
        )
        finish(result, scope: snapshot.sourceVM, success: "Snapshot restored as \(trimmed)")
        busyKeys.remove(key)
        await refreshDevices()
        if result.succeeded {
            selectedSection = .devices
            selectedDeviceID = trimmed
        }
    }

    func verify(_ snapshot: SnapshotRecord) async {
        let key = "verify-snapshot:\(snapshot.id.uuidString)"
        busyKeys.insert(key)
        appendLog(.command, scope: snapshot.sourceVM, "Verifying snapshot SHA-256")
        let verification = await backend.verifySnapshot(snapshot)
        appendLog(
            verification.status == .verified ? .success : .error,
            scope: snapshot.sourceVM,
            verification.message
        )
        snapshots = await backend.loadSnapshots()
        busyKeys.remove(key)
        persistLogs()
    }

    func delete(_ snapshot: SnapshotRecord) async {
        do {
            try await backend.deleteSnapshot(snapshot)
            appendLog(.success, scope: snapshot.sourceVM, "Deleted snapshot “\(snapshot.name)”")
            snapshots = await backend.loadSnapshots()
            persistLogs()
        } catch {
            present(error, context: "Deleting snapshot")
        }
    }

    // MARK: - Firmware

    func importFirmware(_ urls: [URL], kind: FirmwareKind) async {
        do {
            firmware = try await backend.importFirmware(urls, kind: kind)
            appendLog(.success, scope: "firmware", "Added \(urls.count) firmware image(s); validating structure and checksums")
            for url in urls {
                if let image = firmware.first(where: { $0.path == url.path }) {
                    firmware = try await backend.validateFirmware(image, compatibility: compatibility)
                    let updated = firmware.first { $0.path == url.path }
                    let state = updated?.validation?.state.rawValue ?? "unknown"
                    appendLog(.info, scope: "firmware", "\(url.lastPathComponent): \(state)")
                }
            }
            persistLogs()
        } catch {
            present(error, context: "Importing firmware")
        }
    }

    func validateFirmware(_ image: FirmwareImage) async {
        let key = "firmware-validate:\(image.id.uuidString)"
        busyKeys.insert(key)
        appendLog(.command, scope: "firmware", "Validating \(image.fileName) and calculating SHA-256")
        do {
            firmware = try await backend.validateFirmware(image, compatibility: compatibility)
            let updated = firmware.first { $0.id == image.id }
            let state = updated?.validation?.state ?? .invalid
            appendLog(
                state == .valid ? .success : (state == .warning ? .warning : .error),
                scope: "firmware",
                "Validation completed: \(state.rawValue)"
            )
        } catch {
            present(error, context: "Validating firmware")
        }
        busyKeys.remove(key)
        persistLogs()
    }

    func setFirmwareKind(_ image: FirmwareImage, kind: FirmwareKind) async {
        do {
            firmware = try await backend.updateFirmwareKind(image, kind: kind)
        } catch {
            present(error, context: "Updating firmware metadata")
        }
    }

    func forgetFirmware(_ image: FirmwareImage) async {
        do {
            firmware = try await backend.forgetFirmware(image)
            appendLog(.info, scope: "firmware", "Removed \(image.fileName) from the catalog; source file was preserved")
            persistLogs()
        } catch {
            present(error, context: "Removing firmware from catalog")
        }
    }

    // MARK: - Screenshots and diagnostics

    func captureScreenshot(of device: VirtualDevice) async {
        let directory = paths.stateRoot.appendingPathComponent("Screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(
            "\(NameSanitizer.fileComponent(device.name))-\(timestamp()).png"
        )
        appendLog(.command, scope: device.name, "Capturing full-resolution screenshot")
        let response = await backend.captureScreenshot(device, destination: destination)
        if response.succeeded {
            appendLog(.success, scope: device.name, "Screenshot saved to \(response.path ?? destination.path)")
        } else {
            appendLog(.error, scope: device.name, response.error ?? "Screenshot failed")
            alertMessage = response.error ?? "Screenshot failed"
        }
        persistLogs()
    }

    func collectDiagnostics(for device: VirtualDevice) async -> DiagnosticBundle? {
        let key = "diagnostics:\(device.id)"
        busyKeys.insert(key)
        appendLog(.command, scope: device.name, "Collecting diagnostic bundle")
        do {
            let bundle = try await backend.createDiagnosticBundle(
                for: device,
                activityLog: formattedActivityLog()
            )
            diagnosticBundles.insert(bundle, at: 0)
            appendLog(.success, scope: device.name, "Diagnostics saved to \(bundle.url.path)")
            busyKeys.remove(key)
            persistLogs()
            return bundle
        } catch {
            busyKeys.remove(key)
            present(error, context: "Collecting diagnostics")
            return nil
        }
    }

    // MARK: - Multi-device test runs

    func startDeploymentTest(
        name: String,
        deviceIDs: Set<String>,
        packageURL: URL
    ) async {
        guard requireReady(for: "Run multi-device test") else { return }
        let selected = devices.filter { deviceIDs.contains($0.id) }
        guard !selected.isEmpty else { alertMessage = "Select at least one virtual device."; return }
        guard selected.allSatisfy({ !$0.isRunning }) else {
            alertMessage = "Stop every selected device before starting a repeatable deployment run."
            return
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var record = TestRunRecord(
            id: UUID(),
            kind: .deployment,
            name: trimmedName.isEmpty ? "Deployment \(timestamp())" : trimmedName,
            packagePath: packageURL.path,
            createdAt: .now,
            completedAt: nil,
            state: .running,
            results: selected.map { DeviceTestResult(deviceName: $0.name, state: .running, message: "Booting and installing") }
        )
        testRuns.insert(record, at: 0)
        saveTestRuns()
        let runID = record.id
        let cancellation = OperationCancellationFlag()
        orchestrationFlags[runID] = cancellation
        busyKeys.insert("test-run:\(runID.uuidString)")
        let backend = self.backend
        let paths = self.paths

        let results = await withTaskGroup(of: DeviceTestResult.self, returning: [DeviceTestResult].self) { group in
            for device in selected {
                let logger = logger(scope: "test:\(device.name)")
                group.addTask {
                    let startedAt = Date()
                    let screenshot = paths.stateRoot
                        .appendingPathComponent("Test Runs", isDirectory: true)
                        .appendingPathComponent(runID.uuidString, isDirectory: true)
                        .appendingPathComponent("\(NameSanitizer.fileComponent(device.name)).png")
                    try? FileManager.default.createDirectory(
                        at: screenshot.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    let launchTask = Task {
                        await backend.launch(device, installPackage: packageURL, onLine: logger)
                    }
                    var guestReady = false
                    for _ in 0..<36 {
                        if cancellation.isCancelled { break }
                        try? await Task.sleep(for: .seconds(5))
                        let key = await backend.sendHardwareKey(device, name: "home")
                        if key.succeeded {
                            guestReady = true
                            break
                        }
                        if Task.isCancelled || cancellation.isCancelled { break }
                    }
                    var screenshotPath: String?
                    if guestReady {
                        try? await Task.sleep(for: .seconds(2))
                        let capture = await backend.captureScreenshot(device, destination: screenshot)
                        screenshotPath = capture.succeeded ? (capture.path ?? screenshot.path) : nil
                    }
                    let current = await backend.listDevices().first { $0.id == device.id }
                    if let current, current.isRunning {
                        _ = await backend.stop(current, onLine: logger)
                    }
                    let launch = await launchTask.value
                    let passed = guestReady && launch.succeeded && !cancellation.isCancelled
                    return DeviceTestResult(
                        id: UUID(),
                        deviceName: device.name,
                        state: passed ? .passed : ((launch.cancelled || cancellation.isCancelled) ? .cancelled : .failed),
                        message: passed
                            ? "Guest connected, app deployment completed, screenshot captured, and VM stopped"
                            : (guestReady ? "VM exited with code \(launch.exitCode)" : "Guest control did not become ready"),
                        screenshotPath: screenshotPath,
                        diagnosticBundlePath: nil,
                        startedAt: startedAt,
                        completedAt: .now
                    )
                }
            }
            var collected: [DeviceTestResult] = []
            for await result in group { collected.append(result) }
            return collected.sorted { $0.deviceName < $1.deviceName }
        }

        record.results = results
        record.completedAt = .now
        record.state = results.allSatisfy { $0.state == .passed } ? .passed
            : (results.contains { $0.state == .cancelled } ? .cancelled : .failed)
        replaceTestRun(record)
        orchestrationFlags.removeValue(forKey: runID)
        busyKeys.remove("test-run:\(runID.uuidString)")
        appendLog(
            record.state == .passed ? .success : .error,
            scope: "test-run",
            "\(record.name): \(record.state.rawValue)"
        )
        await refreshDevices()
        persistLogs()
    }

    func runBaselineAcceptance(on source: VirtualDevice, packageURL: URL?) async {
        guard requireReady(for: "Run baseline acceptance") else { return }
        guard !source.isRunning else { alertMessage = "Stop \(source.name) before baseline acceptance."; return }
        guard source.restoreInfo != nil else { alertMessage = "The selected VM has not been restored."; return }

        let suffix = String(UUID().uuidString.prefix(6)).lowercased()
        let cloneName = "acceptance-\(suffix)"
        let restoredName = "acceptance-restored-\(suffix)"
        var record = TestRunRecord(
            id: UUID(),
            kind: .baselineAcceptance,
            name: "Baseline acceptance — \(source.name)",
            packagePath: packageURL?.path,
            createdAt: .now,
            completedAt: nil,
            state: .running,
            results: [DeviceTestResult(deviceName: source.name, state: .running, message: "Cloning baseline")]
        )
        testRuns.insert(record, at: 0)
        saveTestRuns()
        let cancellation = OperationCancellationFlag()
        orchestrationFlags[record.id] = cancellation
        busyKeys.insert("test-run:\(record.id.uuidString)")
        let logger = logger(scope: "acceptance")
        var cloneDevice: VirtualDevice?
        var restoredDevice: VirtualDevice?
        var temporarySnapshot: SnapshotRecord?

        do {
            let cloneResult = await backend.clone(source, as: cloneName, onLine: logger)
            guard cloneResult.succeeded else { throw LabWorkflowError.failed("Clone failed") }
            cloneDevice = await backend.listDevices().first { $0.name == cloneName }
            guard let cloneDevice else { throw LabWorkflowError.failed("Cloned VM was not discovered") }

            let launchTask = Task {
                await backend.launch(cloneDevice, installPackage: packageURL, onLine: logger)
            }
            var guestReady = false
            for _ in 0..<36 {
                if cancellation.isCancelled {
                    throw LabWorkflowError.failed("Acceptance run cancelled")
                }
                try? await Task.sleep(for: .seconds(5))
                if await backend.sendHardwareKey(cloneDevice, name: "home").succeeded {
                    guestReady = true
                    break
                }
            }
            guard guestReady else {
                await backend.cancelAllOperations()
                throw LabWorkflowError.failed("Guest control did not become ready within three minutes")
            }

            let screenshot = paths.stateRoot
                .appendingPathComponent("Test Runs/\(record.id.uuidString)/acceptance.png")
            let capture = await backend.captureScreenshot(cloneDevice, destination: screenshot)
            guard capture.succeeded else { throw LabWorkflowError.failed(capture.error ?? "Screenshot failed") }
            if let current = await backend.listDevices().first(where: { $0.name == cloneName }) {
                let stopResult = await backend.stop(current, onLine: logger)
                guard stopResult.succeeded else { throw LabWorkflowError.failed("Stop failed") }
            }
            let launchResult = await launchTask.value
            guard launchResult.succeeded else { throw LabWorkflowError.failed("Boot process exited with \(launchResult.exitCode)") }

            guard let stoppedClone = await backend.listDevices().first(where: { $0.name == cloneName }) else {
                throw LabWorkflowError.failed("Stopped clone was not discovered")
            }
            let snapshotResult = await backend.createSnapshot(
                of: stoppedClone,
                named: "Acceptance",
                onLine: logger
            )
            guard snapshotResult.0.succeeded, let snapshot = snapshotResult.1 else {
                throw LabWorkflowError.failed("Snapshot creation failed")
            }
            temporarySnapshot = snapshot
            let verification = await backend.verifySnapshot(snapshot)
            guard verification.status == .verified else {
                throw LabWorkflowError.failed("Snapshot integrity verification failed")
            }
            let restoreResult = await backend.restoreSnapshot(snapshot, as: restoredName, onLine: logger)
            guard restoreResult.succeeded else { throw LabWorkflowError.failed("Snapshot restore failed") }
            restoredDevice = await backend.listDevices().first { $0.name == restoredName }
            guard let restoredDevice else { throw LabWorkflowError.failed("Restored VM was not discovered") }

            let restoredDelete = await backend.deleteVM(restoredDevice, onLine: logger)
            guard restoredDelete.succeeded else { throw LabWorkflowError.failed("Restored VM cleanup failed") }
            try await backend.deleteSnapshot(snapshot)
            temporarySnapshot = nil
            let cloneDelete = await backend.deleteVM(stoppedClone, onLine: logger)
            guard cloneDelete.succeeded else { throw LabWorkflowError.failed("Clone cleanup failed") }

            record.state = .passed
            record.completedAt = .now
            record.results = [DeviceTestResult(
                id: UUID(),
                deviceName: source.name,
                state: .passed,
                message: "Clone, boot, guest control, screenshot, stop, snapshot, checksum, restore, and cleanup passed",
                screenshotPath: capture.path ?? screenshot.path,
                diagnosticBundlePath: nil,
                startedAt: record.createdAt,
                completedAt: .now
            )]
        } catch {
            if let restoredDevice { _ = await backend.deleteVM(restoredDevice, onLine: logger) }
            if let temporarySnapshot { try? await backend.deleteSnapshot(temporarySnapshot) }
            if let currentClone = await backend.listDevices().first(where: { $0.name == cloneName }) {
                if currentClone.isRunning { _ = await backend.stop(currentClone, onLine: logger) }
                _ = await backend.deleteVM(currentClone, onLine: logger)
            }
            record.state = .failed
            record.completedAt = .now
            record.results = [DeviceTestResult(
                id: UUID(),
                deviceName: source.name,
                state: .failed,
                message: error.localizedDescription,
                screenshotPath: nil,
                diagnosticBundlePath: nil,
                startedAt: record.createdAt,
                completedAt: .now
            )]
        }
        replaceTestRun(record)
        orchestrationFlags.removeValue(forKey: record.id)
        busyKeys.remove("test-run:\(record.id.uuidString)")
        snapshots = await backend.loadSnapshots()
        await refreshDevices()
        persistLogs()
    }

    // MARK: - Automation and plugins

    func addWorkflow(name: String, actions: [AutomationAction]) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !actions.isEmpty else { return }
        workflows.append(AutomationWorkflow(
            id: UUID(),
            name: trimmed,
            steps: actions.map { AutomationStep($0) },
            isBuiltIn: false
        ))
        saveWorkflows()
    }

    func deleteWorkflow(_ workflow: AutomationWorkflow) {
        guard !workflow.isBuiltIn else { return }
        workflows.removeAll { $0.id == workflow.id }
        saveWorkflows()
    }

    func runWorkflow(_ workflow: AutomationWorkflow, on initialDevice: VirtualDevice) async {
        guard requireReady(for: "Run automation") else { return }
        let key = "workflow:\(workflow.id.uuidString)"
        busyKeys.insert(key)
        let cancellation = OperationCancellationFlag()
        orchestrationFlags[workflow.id] = cancellation
        appendLog(.command, scope: initialDevice.name, "Running workflow “\(workflow.name)”")
        var launchTask: Task<CommandResult, Never>?
        var current = initialDevice

        for step in workflow.steps {
            if Task.isCancelled || cancellation.isCancelled { break }
            if let refreshed = await backend.listDevices().first(where: { $0.id == initialDevice.id }) {
                current = refreshed
            }
            appendLog(.info, scope: initialDevice.name, "Automation: \(step.action.displayName)")
            switch step.action {
            case .boot:
                if !current.isRunning {
                    let backend = self.backend
                    let logger = logger(scope: initialDevice.name)
                    let deviceToLaunch = current
                    launchTask = Task {
                        await backend.launch(deviceToLaunch, installPackage: nil, onLine: logger)
                    }
                }
            case .waitForGuest:
                let seconds = Int(step.value ?? "120") ?? 120
                var ready = false
                for _ in 0..<max(1, seconds / 3) {
                    if cancellation.isCancelled { break }
                    try? await Task.sleep(for: .seconds(3))
                    if await backend.sendHardwareKey(current, name: "home").succeeded {
                        ready = true
                        break
                    }
                }
                if !ready { appendLog(.warning, scope: current.name, "Guest control wait timed out") }
            case .screenshot:
                await captureScreenshot(of: current)
            case .pressHome:
                let result = await backend.sendHardwareKey(current, name: "home")
                appendLog(result.succeeded ? .success : .warning, scope: current.name, result.error ?? "Home key sent")
            case .stop:
                if current.isRunning { _ = await backend.stop(current, onLine: logger(scope: current.name)) }
            case .snapshot:
                if !current.isRunning {
                    _ = await backend.createSnapshot(
                        of: current,
                        named: step.value ?? "Automated Snapshot",
                        onLine: logger(scope: current.name)
                    )
                }
            case .diagnostics:
                _ = await collectDiagnostics(for: current)
            }
        }
        if let launchTask, workflow.steps.contains(where: { $0.action == .stop }) {
            _ = await launchTask.value
        }
        busyKeys.remove(key)
        orchestrationFlags.removeValue(forKey: workflow.id)
        snapshots = await backend.loadSnapshots()
        await refreshDevices()
        appendLog(.success, scope: initialDevice.name, "Workflow completed: \(workflow.name)")
        persistLogs()
    }

    func reloadPlugins() {
        plugins = PluginRegistry.loadPlugins(paths: paths)
    }

    func runPlugin(_ plugin: PluginDescriptor, capability: String, device: VirtualDevice?) async {
        let scope = "plugin:\(plugin.id)"
        appendLog(.command, scope: scope, "Running \(capability)")
        let result = await PluginRegistry.run(
            plugin,
            capability: capability,
            device: device,
            paths: paths,
            onLine: logger(scope: scope)
        )
        finish(result, scope: scope, success: "Plugin completed")
    }

    // MARK: - Activity

    func clearLogs() {
        logs.removeAll()
        persistLogs()
    }

    func exportLogs(to url: URL) throws {
        try formattedActivityLog().write(to: url, atomically: true, encoding: .utf8)
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Helpers

    private func formattedActivityLog() -> String {
        let formatter = ISO8601DateFormatter()
        return logs.map {
            "\(formatter.string(from: $0.timestamp)) [\($0.level.rawValue.uppercased())] [\($0.scope)] \($0.message)"
        }.joined(separator: "\n") + "\n"
    }

    private func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: .now)
    }

    private func saveTestRuns() {
        do { try TestRunStore.save(testRuns, paths: paths) }
        catch { present(error, context: "Saving test runs") }
    }

    private func replaceTestRun(_ record: TestRunRecord) {
        if let index = testRuns.firstIndex(where: { $0.id == record.id }) {
            testRuns[index] = record
        } else {
            testRuns.insert(record, at: 0)
        }
        saveTestRuns()
    }

    private func saveWorkflows() {
        do { try WorkflowStore.saveCustom(workflows, paths: paths) }
        catch { present(error, context: "Saving automation workflows") }
    }

    private func normalizeSelection() {
        if let selectedDeviceID, devices.contains(where: { $0.id == selectedDeviceID }) { return }
        selectedDeviceID = devices.first?.id
    }

    private func requireReady(for action: String) -> Bool {
        guard readiness.isReady else {
            alertMessage = "\(action) requires the host preflight to pass. Complete the Recovery-mode SIP/research-guest step and start vphone-amfidont, then click Recheck Host."
            return false
        }
        return true
    }

    private func finish(_ result: CommandResult, scope: String, success: String) {
        if result.succeeded {
            appendLog(.success, scope: scope, success)
        } else {
            appendLog(.error, scope: scope, "Command failed with exit \(result.exitCode)")
            alertMessage = "The \(scope) operation failed with exit \(result.exitCode). Open Activity for the complete log."
        }
        persistLogs()
    }

    private func logger(scope: String) -> @Sendable (String) -> Void {
        { [weak self] line in self?.relayLog(scope: scope, line: line) }
    }

    nonisolated private func relayLog(scope: String, line: String) {
        Task { @MainActor [weak self] in
            self?.appendLog(.info, scope: scope, line)
        }
    }

    private func appendLog(_ level: LogLevel, scope: String, _ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        logs.append(LogEntry(level: level, scope: scope, message: trimmed))
        if logs.count > 2_000 { logs.removeFirst(logs.count - 2_000) }
    }

    private var activityURL: URL {
        paths.stateRoot.appendingPathComponent("activity.json")
    }

    private func loadPersistedLogs() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: activityURL),
              let records = try? decoder.decode([LogEntry].self, from: data)
        else { return }
        logs = Array(records.suffix(2_000))
    }

    private func persistLogs() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(logs) else { return }
        try? data.write(to: activityURL, options: .atomic)
    }

    private func present(_ error: Error, context: String) {
        let message = "\(context): \(error.localizedDescription)"
        appendLog(.error, scope: "lab", message)
        alertMessage = message
        persistLogs()
    }
}

private enum LabWorkflowError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .failed(message): message
        }
    }
}
