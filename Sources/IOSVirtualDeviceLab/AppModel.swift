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
    @Published private(set) var logs: [LogEntry] = []
    @Published private(set) var readiness: HostReadiness = .checking
    @Published private(set) var busyKeys: Set<String> = []
    @Published var alertMessage: String?

    let paths: LabPaths
    private let backend: VPhoneBackend
    private var didBootstrap = false

    init(paths: LabPaths = .default) {
        self.paths = paths
        backend = VPhoneBackend(paths: paths)
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
            appendLog(.success, scope: "firmware", "Added \(urls.count) firmware image(s) to the catalog")
            persistLogs()
        } catch {
            present(error, context: "Importing firmware")
        }
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

    // MARK: - Activity

    func clearLogs() {
        logs.removeAll()
        persistLogs()
    }

    func exportLogs(to url: URL) throws {
        let formatter = ISO8601DateFormatter()
        let text = logs.map {
            "\(formatter.string(from: $0.timestamp)) [\($0.level.rawValue.uppercased())] [\($0.scope)] \($0.message)"
        }.joined(separator: "\n") + "\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Helpers

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
