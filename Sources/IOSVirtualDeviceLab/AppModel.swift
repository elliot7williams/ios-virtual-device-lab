import AppKit
import Foundation
import SwiftUI

private struct LocalBootstrapState: Sendable {
    let compatibility: CompatibilityManifest
    let hardwareProfiles: HardwareProfileCatalog
    let backendCatalog: BackendCatalog
    let attributionCatalog: AttributionCatalog
    let testRuns: [TestRunRecord]
    let workflows: [AutomationWorkflow]
    let plugins: [PluginDescriptor]
    let appArtifacts: [AppArtifact]
    let snapshotRetention: SnapshotRetentionPolicy
    let resourcePolicy: LabResourcePolicy
    let diagnosticPrivacy: DiagnosticPrivacyPolicy
    let xcodeIntegration: XcodeIntegrationStatus
    let logs: [LogEntry]
    let hardening: ProductionHardeningState

    static func load(paths: LabPaths) throws -> LocalBootstrapState {
        try PluginRegistry.prepare(paths: paths)

        let activityURL = paths.stateRoot.appendingPathComponent("activity.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let persistedLogs = (try? Data(contentsOf: activityURL))
            .flatMap { try? decoder.decode([LogEntry].self, from: $0) }
        let hardening = try ProductionHardeningState.load(paths: paths)

        return LocalBootstrapState(
            compatibility: CompatibilityCatalog.load(paths: paths),
            hardwareProfiles: HardwareProfilesCatalog.load(paths: paths),
            backendCatalog: ProjectCatalogLoader.loadBackends(paths: paths),
            attributionCatalog: ProjectCatalogLoader.loadAttribution(paths: paths),
            testRuns: TestRunStore.load(paths: paths),
            workflows: WorkflowStore.load(paths: paths),
            plugins: PluginRegistry.loadPlugins(paths: paths),
            appArtifacts: AppArtifactStore.load(paths: paths),
            snapshotRetention: SnapshotRetentionStore.load(paths: paths),
            resourcePolicy: ResourcePolicyStore.load(paths: paths),
            diagnosticPrivacy: DiagnosticPrivacyStore.load(paths: paths),
            xcodeIntegration: DeveloperTools.inspect(paths: paths),
            logs: Array((persistedLogs ?? []).suffix(2_000)),
            hardening: hardening
        )
    }
}

@MainActor
final class LabAppModel: ObservableObject {
    @Published var selectedSection: LabSection = .devices
    @Published var selectedDeviceID: String?
    @Published private(set) var devices: [VirtualDevice] = []
    @Published private(set) var firmware: [FirmwareImage] = []
    @Published private(set) var hardwareProfiles: HardwareProfileCatalog = .empty
    @Published private(set) var backendCatalog: BackendCatalog = .empty
    @Published private(set) var attributionCatalog: AttributionCatalog = .empty
    @Published private(set) var snapshots: [SnapshotRecord] = []
    @Published private(set) var compatibility: CompatibilityManifest = .empty
    @Published private(set) var testRuns: [TestRunRecord] = []
    @Published private(set) var workflows: [AutomationWorkflow] = []
    @Published private(set) var plugins: [PluginDescriptor] = []
    @Published private(set) var appArtifacts: [AppArtifact] = []
    @Published private(set) var diagnosticBundles: [DiagnosticBundle] = []
    @Published private(set) var diagnosticAnalysisReports: [DiagnosticAnalysisReport] = []
    @Published private(set) var diagnosticPrivacy: DiagnosticPrivacyPolicy = .standard
    @Published private(set) var latestDiagnosticPreview: DiagnosticPrivacyPreview?
    @Published private(set) var performanceSamples: [String: PerformanceSample] = [:]
    @Published private(set) var progressEvents: [LabProgressEvent] = []
    @Published private(set) var snapshotRetention: SnapshotRetentionPolicy = .standard
    @Published private(set) var resourcePolicy: LabResourcePolicy = .standard
    @Published private(set) var backendDescriptor: BackendDescriptor = .vphone
    @Published private(set) var xcodeIntegration = XcodeIntegrationStatus(
        xcodePath: nil,
        xcodebuildVersion: nil,
        commandLineToolsReady: false,
        helperScriptURL: nil
    )
    @Published private(set) var backendCapabilities: BackendCapabilities = .vphone
    @Published private(set) var updateState: UpdateState = .idle
    @Published private(set) var logs: [LogEntry] = []
    @Published private(set) var readiness: HostReadiness = .checking
    @Published private(set) var acceptanceReport: AcceptanceReport = .empty
    @Published private(set) var hostCompatibilityAssessment: HostCompatibilityAssessment = .unverified
    @Published private(set) var hostCompatibilityCatalog: HostCompatibilityCatalog = .empty
    @Published private(set) var migrationReport: LabMigrationReport = .none
    @Published private(set) var operationJournalEntries: [OperationJournalEntry] = []
    @Published private(set) var environmentProfiles: [EnvironmentProfile] = []
    @Published private(set) var environmentAssignments: [String: UUID] = [:]
    @Published private(set) var guestProtocolHandshakes: [String: GuestProtocolHandshake] = [:]
    @Published private(set) var storagePolicy: LabStoragePolicy = .standard
    @Published private(set) var storageInventory: LabStorageInventory = .empty
    @Published private(set) var pluginAuditRecords: [PluginAuditRecord] = []
    @Published private(set) var remoteAgentConfiguration: RemoteLabAgentConfiguration?
    @Published private(set) var busyKeys: Set<String> = []
    @Published var alertMessage: String?

    let paths: LabPaths
    private let backend: any LabBackend
    private var didBootstrap = false
    private var orchestrationFlags: [UUID: OperationCancellationFlag] = [:]
    private let updateService = UpdateService()

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
            let labPaths = paths
            let localState = try await Task.detached(priority: .userInitiated) {
                try LocalBootstrapState.load(paths: labPaths)
            }.value
            compatibility = localState.compatibility
            hardwareProfiles = localState.hardwareProfiles
            backendCatalog = localState.backendCatalog
            attributionCatalog = localState.attributionCatalog
            testRuns = localState.testRuns
            workflows = localState.workflows
            plugins = localState.plugins
            appArtifacts = localState.appArtifacts
            snapshotRetention = localState.snapshotRetention
            resourcePolicy = localState.resourcePolicy
            diagnosticPrivacy = localState.diagnosticPrivacy
            xcodeIntegration = localState.xcodeIntegration
            logs = localState.logs
            migrationReport = localState.hardening.migrationReport
            operationJournalEntries = localState.hardening.journalEntries
            hostCompatibilityCatalog = localState.hardening.hostCatalog
            environmentProfiles = localState.hardening.environmentProfiles
            environmentAssignments = localState.hardening.environmentAssignments
            storagePolicy = localState.hardening.storagePolicy
            pluginAuditRecords = localState.hardening.pluginAudits
            remoteAgentConfiguration = localState.hardening.remoteAgent
            backendDescriptor = await backend.descriptor
            backendCapabilities = await backend.capabilities
            appendLog(.info, scope: "lab", "Storage: \(paths.dataRoot.path)")
            await refreshAll()
            Task { await checkForUpdates(automatic: true) }
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
        await refreshOperationalReadiness()

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

    // MARK: - Operational readiness

    func refreshOperationalReadiness() async {
        let device = selectedDevice ?? devices.first
        if let device, device.isRunning {
            guestProtocolHandshakes[device.id] = await backend.guestProtocolHandshake(for: device)
        }
        let handshake = device.flatMap { guestProtocolHandshakes[$0.id] }
        acceptanceReport = AcceptanceEvaluator.evaluate(
            host: readiness,
            device: device,
            testRuns: testRuns,
            capabilities: backendCapabilities,
            handshake: handshake
        )
        hostCompatibilityAssessment = HostCompatibilityDatabase.assess(
            catalog: hostCompatibilityCatalog,
            host: readiness,
            backendVersion: backendDescriptor.version,
            device: device
        )

        let labPaths = paths
        let currentDevices = devices
        let currentFirmware = firmware
        let currentSnapshots = snapshots
        let policy = storagePolicy
        storageInventory = await Task.detached(priority: .utility) {
            StorageLifecycleManager.scan(
                paths: labPaths,
                devices: currentDevices,
                firmware: currentFirmware,
                snapshots: currentSnapshots,
                policy: policy
            )
        }.value
        pluginAuditRecords = await Task.detached(priority: .utility) {
            PluginAuditStore.load(paths: labPaths)
        }.value
    }

    func probeGuestProtocol(for device: VirtualDevice) async {
        guestProtocolHandshakes[device.id] = await backend.guestProtocolHandshake(for: device)
        await refreshOperationalReadiness()
    }

    func applyEnvironmentProfile(_ profile: EnvironmentProfile, to device: VirtualDevice) async {
        environmentAssignments[device.id] = profile.id
        do {
            try EnvironmentProfileStore.saveAssignments(environmentAssignments, paths: paths)
            if let plugin = plugins.first(where: {
                $0.capabilities.contains("environment-policy") && $0.trusted == true
            }), let data = try? JSONEncoder().encode(profile), let json = String(data: data, encoding: .utf8) {
                let result = await PluginRegistry.run(
                    plugin,
                    capability: "environment-policy",
                    device: device,
                    paths: paths,
                    additionalEnvironment: ["LAB_ENVIRONMENT_PROFILE": json],
                    onLine: logger(scope: "plugin:\(plugin.id)")
                )
                finish(result, scope: "plugin:\(plugin.id)", success: "Environment profile applied by trusted extension")
            } else {
                appendLog(
                    .warning,
                    scope: device.name,
                    "Environment profile saved as test intent; unsupported guest simulations require a trusted environment-policy extension"
                )
                persistLogs()
            }
        } catch {
            present(error, context: "Saving environment profile assignment")
        }
    }

    func updateStoragePolicy(_ policy: LabStoragePolicy) async {
        storagePolicy = policy
        do {
            try StorageLifecycleManager.savePolicy(policy, paths: paths)
            await refreshOperationalReadiness()
        } catch {
            present(error, context: "Saving storage lifecycle policy")
        }
    }

    func exportPortableConfiguration(to destination: URL) {
        do {
            let output = try StorageLifecycleManager.exportConfiguration(paths: paths, destination: destination)
            appendLog(.success, scope: "storage", "Portable configuration exported without firmware, VM disks, or secrets")
            persistLogs()
            reveal(output)
        } catch {
            present(error, context: "Exporting portable lab configuration")
        }
    }

    func initializeRemoteAgent() {
        do {
            remoteAgentConfiguration = try RemoteLabAgentBootstrap.initialize(paths: paths)
            appendLog(.success, scope: "agent", "Initialized an authenticated local queue; the agent remains disabled until explicitly started")
            persistLogs()
        } catch {
            present(error, context: "Initializing remote lab agent")
        }
    }

    func resolveJournalEntry(_ entry: OperationJournalEntry) {
        guard let index = operationJournalEntries.firstIndex(where: { $0.id == entry.id }) else { return }
        operationJournalEntries[index].state = .resolved
        operationJournalEntries[index].updatedAt = .now
        operationJournalEntries[index].message = "Reviewed and resolved by the user."
        try? OperationJournalStore.save(operationJournalEntries, paths: paths)
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
        cloudOSIPSW: URL?,
        hardwareProfileID: String? = nil,
        network: NetworkConfiguration = .standard,
        audio: AudioConfiguration = .playback,
        isolation: IsolationPolicy = .strict,
        allowUnverifiedFirmware: Bool = false
    ) async {
        guard requireReady(for: "Create VM") else { return }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            alertMessage = "Enter a name for the virtual device."
            return
        }
        let iphone = iphoneIPSW.flatMap { url in firmware.first { $0.path == url.path } }
        let requestedCloud = cloudOSIPSW.flatMap { url in firmware.first { $0.path == url.path } }
        let recommendation = iphone.map {
            CompatibilityEvaluator.recommend(
                iphone: $0,
                catalog: compatibility,
                profiles: hardwareProfiles,
                availableFirmware: firmware
            )
        }
        guard let profile = hardwareProfiles.profile(id: hardwareProfileID)
            ?? recommendation?.hardwareProfile
            ?? hardwareProfiles.profiles.first(where: { $0.status == .supported })
            ?? hardwareProfiles.profiles.first
        else {
            alertMessage = "No virtual hardware profiles are installed."
            return
        }
        let operationID = UUID()
        let request = VMCreationRequest(
            operationID: operationID,
            name: name,
            hardwareProfile: profile,
            variant: variant,
            diskSizeGB: diskSizeGB,
            iphoneFirmware: iphone,
            cloudOSFirmware: requestedCloud ?? recommendation?.cloudOSFirmware,
            network: network,
            audio: audio,
            isolation: isolation,
            allowUnverifiedFirmware: allowUnverifiedFirmware
        )
        let decision = CompatibilityEvaluator.evaluate(request, compatibility: compatibility)
        guard decision.decision != .blocked else {
            alertMessage = decision.messages.joined(separator: "\n")
            return
        }
        guard decision.decision != .warning || allowUnverifiedFirmware else {
            alertMessage = decision.messages.joined(separator: "\n") + "\n\nEnable the experimental/unverified acknowledgement to continue."
            return
        }
        let key = "create:\(name)"
        busyKeys.insert(key)
        beginJournal(
            id: operationID,
            kind: .create,
            target: name,
            phase: .preparing,
            recovery: "Remove an incomplete VM bundle only after confirming no backend process is using its disk."
        )
        appendLog(
            .command,
            scope: name,
            "Creating \(variant.displayName) VM with \(profile.name), a \(diskSizeGB) GB disk, and \(network.mode.displayName)"
        )
        let result = await backend.createVM(
            request: request,
            onProgress: progressHandler(scope: name),
            onLine: logger(scope: name)
        )
        finishJournal(id: operationID, result: result)
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
        let journalID = UUID()
        busyKeys.insert(key)
        beginJournal(
            id: journalID,
            kind: .boot,
            target: device.name,
            phase: .booting,
            recovery: "Re-scan the VM process and socket; stop the device before retrying if either remains active."
        )
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
        finishJournal(id: journalID, result: result)
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
        let journalID = UUID()
        busyKeys.insert(key)
        beginJournal(
            id: journalID,
            kind: .create,
            target: trimmed,
            phase: .exporting,
            recovery: "Verify the clone bundle and remove it only if its config or disk copy is incomplete."
        )
        appendLog(.command, scope: device.name, "Cloning as \(trimmed)")
        let result = await backend.clone(device, as: trimmed, onLine: logger(scope: device.name))
        finishJournal(id: journalID, result: result)
        finish(result, scope: device.name, success: "Clone created: \(trimmed)")
        busyKeys.remove(key)
        await refreshDevices()
        if result.succeeded { selectedDeviceID = trimmed }
    }

    func updateConfiguration(
        _ device: VirtualDevice,
        cpu: Int,
        memoryMB: Int,
        network: String,
        hardwareProfileID: String? = nil,
        networkConfiguration: NetworkConfiguration? = nil,
        audio: AudioConfiguration? = nil,
        isolation: IsolationPolicy? = nil
    ) async {
        guard requireReady(for: "Update VM") else { return }
        guard !device.isRunning else {
            alertMessage = "Stop \(device.name) before changing its hardware configuration."
            return
        }
        let key = "config:\(device.id)"
        busyKeys.insert(key)
        appendLog(.command, scope: device.name, "Updating hardware configuration")
        let request = VMConfigurationRequest(
            operationID: UUID(),
            device: device,
            hardwareProfileID: hardwareProfileID ?? device.hardwareProfileID,
            cpu: cpu,
            memoryMB: memoryMB,
            network: networkConfiguration ?? device.networkConfiguration ?? NetworkConfiguration(
                mode: network == "bridged" ? .bridged : (network == "none" ? .offline : .nat),
                proxyURL: nil,
                captureTraffic: false,
                allowHostAccess: false
            ),
            audio: audio ?? device.audioConfiguration ?? .playback,
            isolation: isolation ?? device.isolationPolicy ?? .strict
        )
        let result = await backend.updateConfiguration(
            request: request,
            onProgress: progressHandler(scope: device.name),
            onLine: logger(scope: device.name)
        )
        finish(result, scope: device.name, success: "Configuration updated")
        if result.succeeded,
           request.network.proxyURL != nil || request.network.captureTraffic {
            if let plugin = plugins.first(where: {
                $0.capabilities.contains("network-policy") && $0.trusted == true
            }),
               let data = try? JSONEncoder().encode(request.network),
               let json = String(data: data, encoding: .utf8) {
                let extensionResult = await PluginRegistry.run(
                    plugin,
                    capability: "network-policy",
                    device: device,
                    paths: paths,
                    additionalEnvironment: ["LAB_NETWORK_CONFIGURATION": json],
                    onLine: logger(scope: "plugin:\(plugin.id)")
                )
                finish(extensionResult, scope: "plugin:\(plugin.id)", success: "Network instrumentation policy applied")
            } else {
                appendLog(
                    .warning,
                    scope: device.name,
                    "Proxy and packet-capture policy was saved but requires a trusted network-policy plugin"
                )
            }
        }
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
        let journalID = UUID()
        busyKeys.insert(key)
        beginJournal(
            id: journalID,
            kind: .configure,
            target: device.name,
            phase: .cleaningUp,
            recovery: "Re-scan the device library. Preserve any remaining bundle until its ownership is confirmed."
        )
        appendLog(.command, scope: device.name, "Deleting VM bundle")
        let result = await backend.deleteVM(device, onLine: logger(scope: device.name))
        finishJournal(id: journalID, result: result)
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
        let journalID = UUID()
        busyKeys.insert(key)
        beginJournal(
            id: journalID,
            kind: .snapshot,
            target: "\(device.name)/\(trimmed)",
            phase: .exporting,
            recovery: "Discard an incomplete archive and its sidecar only after checksum verification fails."
        )
        appendLog(.command, scope: device.name, "Creating snapshot “\(trimmed)”")
        let (result, _) = await backend.createSnapshot(
            of: device,
            named: trimmed,
            onLine: logger(scope: device.name)
        )
        finishJournal(id: journalID, result: result)
        finish(result, scope: device.name, success: "Snapshot created")
        busyKeys.remove(key)
        snapshots = await backend.loadSnapshots()
        if result.succeeded, snapshotRetention.isEnabled {
            _ = await applySnapshotRetention()
        }
    }

    func restore(_ snapshot: SnapshotRecord, as newName: String) async {
        guard requireReady(for: "Restore snapshot") else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { alertMessage = "Enter a name for the restored VM."; return }
        let key = "restore:\(snapshot.id.uuidString)"
        let journalID = UUID()
        busyKeys.insert(key)
        beginJournal(
            id: journalID,
            kind: .restore,
            target: trimmed,
            phase: .restoring,
            recovery: "Preserve the source snapshot; verify or remove only the newly imported incomplete VM bundle."
        )
        appendLog(.command, scope: snapshot.sourceVM, "Restoring “\(snapshot.name)” as \(trimmed)")
        let result = await backend.restoreSnapshot(
            snapshot,
            as: trimmed,
            onLine: logger(scope: snapshot.sourceVM)
        )
        finishJournal(id: journalID, result: result)
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

    func updateSnapshotRetention(_ policy: SnapshotRetentionPolicy) {
        snapshotRetention = policy
        do {
            try SnapshotRetentionStore.save(policy, paths: paths)
            appendLog(.success, scope: "snapshots", "Snapshot retention policy updated")
            persistLogs()
        } catch {
            present(error, context: "Saving snapshot retention policy")
        }
    }

    @discardableResult
    func applySnapshotRetention() async -> SnapshotRetentionResult {
        let policy = snapshotRetention
        guard policy.isEnabled else {
            return SnapshotRetentionResult(removed: [], preserved: snapshots, reclaimedBytes: 0)
        }

        let ordered = snapshots.sorted { $0.createdAt > $1.createdAt }
        var preservedIDs = Set<UUID>()
        for group in Dictionary(grouping: ordered, by: \.sourceVM).values {
            for snapshot in group.prefix(max(0, policy.keepLastPerDevice)) {
                preservedIDs.insert(snapshot.id)
            }
        }

        let ageCutoff = Calendar.current.date(byAdding: .day, value: -max(0, policy.maximumAgeDays), to: .now) ?? .distantPast
        var pruneIDs = Set(ordered.filter {
            !preservedIDs.contains($0.id) && $0.createdAt < ageCutoff
        }.map(\.id))

        var projectedBytes = ordered
            .filter { !pruneIDs.contains($0.id) }
            .reduce(Int64(0)) { $0 + $1.sizeBytes }
        if projectedBytes > policy.maximumTotalBytes {
            for snapshot in ordered.reversed()
                where !preservedIDs.contains(snapshot.id) && !pruneIDs.contains(snapshot.id) {
                pruneIDs.insert(snapshot.id)
                projectedBytes -= snapshot.sizeBytes
                if projectedBytes <= policy.maximumTotalBytes { break }
            }
        }

        var removed: [SnapshotRecord] = []
        for snapshot in ordered where pruneIDs.contains(snapshot.id) {
            if policy.verifyBeforePruning {
                let verification = await backend.verifySnapshot(snapshot)
                guard verification.status == .verified else {
                    appendLog(.warning, scope: snapshot.sourceVM, "Retention preserved \(snapshot.name): integrity is \(verification.status.rawValue)")
                    continue
                }
            }
            do {
                try await backend.deleteSnapshot(snapshot)
                removed.append(snapshot)
            } catch {
                present(error, context: "Pruning snapshot \(snapshot.name)")
            }
        }
        snapshots = await backend.loadSnapshots()
        let reclaimed = removed.reduce(Int64(0)) { $0 + $1.sizeBytes }
        appendLog(.info, scope: "snapshots", "Retention removed \(removed.count) snapshot(s) and reclaimed \(ByteCountFormatter.string(fromByteCount: reclaimed, countStyle: .file))")
        persistLogs()
        return SnapshotRetentionResult(removed: removed, preserved: snapshots, reclaimedBytes: reclaimed)
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

    func firmwareRecommendation(for image: FirmwareImage) -> FirmwareRecommendation {
        CompatibilityEvaluator.recommend(
            iphone: image,
            catalog: compatibility,
            profiles: hardwareProfiles,
            availableFirmware: firmware
        )
    }

    func backendRecommendation(for image: FirmwareImage) -> BackendRecommendation {
        BackendRecommendationEvaluator.recommend(
            firmware: image,
            catalog: backendCatalog,
            compatibility: compatibility,
            activeBackendID: backendDescriptor.id,
            hostReady: readiness.isReady
        )
    }

    func importAppArtifact(_ url: URL) {
        do {
            appArtifacts = try AppArtifactStore.importArtifact(url, paths: paths)
            appendLog(.success, scope: "artifacts", "Imported \(url.lastPathComponent) into the app artifact library")
            persistLogs()
        } catch {
            present(error, context: "Importing app artifact")
        }
    }

    func deleteAppArtifact(_ artifact: AppArtifact) {
        do {
            appArtifacts = try AppArtifactStore.remove(artifact, paths: paths)
            appendLog(.info, scope: "artifacts", "Removed \(artifact.name) from the app artifact library")
            persistLogs()
        } catch {
            present(error, context: "Removing app artifact")
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
            let rawBundle = try await backend.createDiagnosticBundle(
                for: device,
                activityLog: formattedActivityLog()
            )
            let sanitizedURL = rawBundle.url.deletingLastPathComponent()
                .appendingPathComponent(rawBundle.url.lastPathComponent + "-sanitized", isDirectory: true)
            latestDiagnosticPreview = try DiagnosticSanitizer.sanitize(
                source: rawBundle.url,
                destination: sanitizedURL,
                policy: diagnosticPrivacy
            )
            try? FileManager.default.removeItem(at: rawBundle.url)
            let bundle = DiagnosticBundle(
                id: rawBundle.id,
                deviceName: rawBundle.deviceName,
                url: sanitizedURL,
                createdAt: rawBundle.createdAt
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

    func updateDiagnosticPrivacy(_ policy: DiagnosticPrivacyPolicy) {
        diagnosticPrivacy = policy
        do {
            try DiagnosticPrivacyStore.save(policy, paths: paths)
            appendLog(.info, scope: "privacy", "Diagnostic privacy policy updated")
            persistLogs()
        } catch {
            present(error, context: "Saving diagnostic privacy policy")
        }
    }

    func analyzeDiagnostics(_ bundle: DiagnosticBundle, useTrustedPlugin: Bool = false) async {
        do {
            let local = try DiagnosticAnalyzer.analyze(bundle.url)
            diagnosticAnalysisReports.insert(local, at: 0)
            appendLog(.success, scope: "diagnostics", local.summary)
            if useTrustedPlugin,
               let plugin = plugins.first(where: {
                   $0.capabilities.contains("diagnostic-analysis") && $0.trusted == true
               }) {
                let result = await PluginRegistry.run(
                    plugin,
                    capability: "diagnostic-analysis",
                    device: nil,
                    paths: paths,
                    additionalEnvironment: ["LAB_DIAGNOSTIC_BUNDLE": bundle.url.path],
                    onLine: logger(scope: "plugin:\(plugin.id)")
                )
                finish(result, scope: "plugin:\(plugin.id)", success: "Trusted diagnostic analyzer completed")
            }
            persistLogs()
        } catch {
            present(error, context: "Analyzing diagnostics")
        }
    }

    func exportEncryptedDiagnostics(_ bundle: DiagnosticBundle, passphrase: String) {
        do {
            let destination = bundle.url.deletingLastPathComponent()
                .appendingPathComponent(bundle.url.lastPathComponent + ".vdlenc")
            let output = try DiagnosticSanitizer.encryptedArchive(
                of: bundle.url,
                destination: destination,
                passphrase: passphrase
            )
            appendLog(.success, scope: "privacy", "Encrypted diagnostic export created")
            persistLogs()
            reveal(output)
        } catch {
            present(error, context: "Encrypting diagnostic export (use at least 12 characters)")
        }
    }

    func refreshPerformance(for device: VirtualDevice) async {
        let sample = await backend.performanceSample(for: device)
        performanceSamples[device.id] = sample
    }

    func exportGuestDiagnostics(
        for device: VirtualDevice,
        categories: [DiagnosticCategory]
    ) async -> DiagnosticExportResult {
        let destination = paths.stateRoot
            .appendingPathComponent("Diagnostics", isDirectory: true)
            .appendingPathComponent("\(NameSanitizer.fileComponent(device.name))-guest-\(timestamp())", isDirectory: true)
        let result = await backend.exportGuestDiagnostics(
            for: device,
            categories: categories,
            destination: destination
        )
        if result.supported {
            appendLog(.success, scope: device.name, result.message)
            persistLogs()
            return result
        }

        if let plugin = plugins.first(where: {
            $0.capabilities.contains("guest-diagnostics") && $0.trusted == true
        }) {
            let pluginResult = await PluginRegistry.run(
                plugin,
                capability: "guest-diagnostics",
                device: device,
                paths: paths,
                onLine: logger(scope: "plugin:\(plugin.id)")
            )
            let pluginExport = DiagnosticExportResult(
                supported: pluginResult.succeeded,
                categories: categories,
                outputURL: pluginResult.succeeded ? destination : nil,
                message: pluginResult.output
            )
            appendLog(pluginResult.succeeded ? .success : .error, scope: device.name, pluginExport.message)
            persistLogs()
            return pluginExport
        }

        appendLog(.warning, scope: device.name, result.message)
        persistLogs()
        return result
    }

    // MARK: - Multi-device test runs

    func startDeploymentTest(
        name: String,
        deviceIDs: Set<String>,
        packageURL: URL,
        assertions: [TestAssertion] = TestAssertion.deploymentDefaults
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
        record.assertions = assertions
        testRuns.insert(record, at: 0)
        saveTestRuns()
        let runID = record.id
        let cancellation = OperationCancellationFlag()
        orchestrationFlags[runID] = cancellation
        busyKeys.insert("test-run:\(runID.uuidString)")
        let backend = self.backend
        let paths = self.paths
        let shouldCollectDiagnostics = assertions.contains { $0.kind == .diagnosticsCollected }
        let gate = LabResourceGate(policy: resourcePolicy)
        let runPolicy = resourcePolicy

        let results = await withTaskGroup(of: DeviceTestResult.self, returning: [DeviceTestResult].self) { group in
            for device in selected {
                let logger = logger(scope: "test:\(device.name)")
                group.addTask {
                    let reservedMemory = min(
                        max(1, device.memoryMB),
                        max(1, runPolicy.maximumAggregateMemoryMB)
                    )
                    guard await HostResourceMonitor.waitForCPU(
                        below: runPolicy.maximumHostCPUPercent,
                        cancellation: cancellation
                    ) else {
                        return DeviceTestResult(
                            id: UUID(),
                            deviceName: device.name,
                            state: cancellation.isCancelled ? .cancelled : .failed,
                            message: "Host CPU remained above the configured resource limit",
                            screenshotPath: nil,
                            diagnosticBundlePath: nil,
                            startedAt: .now,
                            completedAt: .now
                        )
                    }
                    await gate.acquire(memoryMB: reservedMemory)
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
                    var diagnosticPath: String?
                    if shouldCollectDiagnostics,
                       let bundle = try? await backend.createDiagnosticBundle(
                           for: device,
                           activityLog: "Generated by deployment test \(runID.uuidString)\n"
                       ) {
                        diagnosticPath = bundle.url.path
                    }
                    let performance = await backend.performanceSample(for: device)
                    let current = await backend.listDevices().first { $0.id == device.id }
                    if let current, current.isRunning {
                        _ = await backend.stop(current, onLine: logger)
                    }
                    let launch = await launchTask.value
                    let duration = Date().timeIntervalSince(startedAt)
                    let assertionResults = TestAssertionEvaluator.evaluate(
                        assertions,
                        guestReady: guestReady,
                        launch: launch,
                        screenshotPath: screenshotPath,
                        diagnosticPath: diagnosticPath,
                        duration: duration,
                        networkMode: device.networkConfiguration?.mode
                            ?? NetworkMode(rawValue: device.network.mode),
                        audioConfigured: device.audioConfiguration?.outputEnabled == true
                            && performance.audioSampleRateHz != nil,
                        performance: performance
                    )
                    let passed = assertionResults.allSatisfy { !$0.assertion.isRequired || $0.passed }
                        && !cancellation.isCancelled
                    let passedAssertions = assertionResults.filter(\.passed).count
                    let deviceResult = DeviceTestResult(
                        id: UUID(),
                        deviceName: device.name,
                        state: passed ? .passed : ((launch.cancelled || cancellation.isCancelled) ? .cancelled : .failed),
                        message: "\(passedAssertions)/\(assertionResults.count) assertions passed",
                        screenshotPath: screenshotPath,
                        diagnosticBundlePath: diagnosticPath,
                        startedAt: startedAt,
                        completedAt: .now,
                        assertionResults: assertionResults,
                        performanceSummary: performance.source
                    )
                    await gate.release(memoryMB: reservedMemory)
                    return deviceResult
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
        if let report = try? TestReportStore.write(record, paths: paths) {
            record.reportPath = report.path
        }
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

    func updateResourcePolicy(_ policy: LabResourcePolicy) {
        resourcePolicy = policy
        do {
            try ResourcePolicyStore.save(policy, paths: paths)
            appendLog(.info, scope: "scheduler", "Resource policy updated: \(policy.maximumConcurrentVMs) concurrent VMs, \(policy.maximumAggregateMemoryMB) MB")
            persistLogs()
        } catch {
            present(error, context: "Saving resource policy")
        }
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
        if let report = try? TestReportStore.write(record, paths: paths) {
            record.reportPath = report.path
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

    func addWorkflow(name: String, steps: [AutomationStep], schedule: String?, headless: Bool) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !steps.isEmpty else { return }
        workflows.append(AutomationWorkflow(
            id: UUID(),
            name: trimmed,
            steps: steps,
            isBuiltIn: false,
            schedule: schedule?.trimmingCharacters(in: .whitespacesAndNewlines),
            headless: headless
        ))
        saveWorkflows()
    }

    func updateWorkflow(_ workflow: AutomationWorkflow) {
        guard !workflow.isBuiltIn,
              let index = workflows.firstIndex(where: { $0.id == workflow.id }) else { return }
        workflows[index] = workflow
        saveWorkflows()
    }

    func moveWorkflowStep(workflowID: UUID, stepID: UUID, offset: Int) {
        guard let workflowIndex = workflows.firstIndex(where: { $0.id == workflowID && !$0.isBuiltIn }),
              let stepIndex = workflows[workflowIndex].steps.firstIndex(where: { $0.id == stepID }) else { return }
        let destination = min(max(0, stepIndex + offset), workflows[workflowIndex].steps.count - 1)
        guard destination != stepIndex else { return }
        let step = workflows[workflowIndex].steps.remove(at: stepIndex)
        workflows[workflowIndex].steps.insert(step, at: destination)
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

        workflowSteps: for step in workflow.steps {
            if Task.isCancelled || cancellation.isCancelled { break }
            if let refreshed = await backend.listDevices().first(where: { $0.id == initialDevice.id }) {
                current = refreshed
            }
            if step.condition == "running", !current.isRunning { continue }
            if step.condition == "stopped", current.isRunning { continue }
            if let delay = step.delaySeconds, delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            appendLog(.info, scope: initialDevice.name, "Automation: \(step.action.displayName)")
            let attempts = max(1, (step.retryCount ?? 0) + 1)
            var stepSucceeded = false
            for attempt in 0..<attempts {
                switch step.action {
                case .boot, .installApp:
                    if !current.isRunning {
                        let backend = self.backend
                        let logger = logger(scope: initialDevice.name)
                        let deviceToLaunch = current
                        let package = step.action == .installApp
                            ? step.value.map { URL(fileURLWithPath: $0) }
                            : nil
                        launchTask = Task {
                            await backend.launch(deviceToLaunch, installPackage: package, onLine: logger)
                        }
                    }
                    stepSucceeded = true
                case .waitForGuest:
                    let seconds = Int(step.value ?? "120") ?? 120
                    for _ in 0..<max(1, seconds / 3) {
                        if cancellation.isCancelled { break }
                        try? await Task.sleep(for: .seconds(3))
                        if await backend.sendHardwareKey(current, name: "home").succeeded {
                            stepSucceeded = true
                            break
                        }
                    }
                case .delay:
                    let seconds = Double(step.value ?? "1") ?? 1
                    try? await Task.sleep(for: .seconds(max(0, seconds)))
                    stepSucceeded = true
                case .screenshot:
                    let directory = paths.stateRoot.appendingPathComponent("Automation", isDirectory: true)
                    let destination = directory.appendingPathComponent("\(NameSanitizer.fileComponent(current.name))-\(timestamp()).png")
                    stepSucceeded = await backend.captureScreenshot(current, destination: destination).succeeded
                case .pressHome, .assertGuestReady:
                    let result = await backend.sendHardwareKey(current, name: "home")
                    stepSucceeded = result.succeeded
                    appendLog(result.succeeded ? .success : .warning, scope: current.name, result.error ?? "Guest control responded")
                case .setNetworkMode:
                    guard !current.isRunning else { stepSucceeded = false; break }
                    let mode = NetworkMode(rawValue: step.value ?? "nat") ?? .nat
                    await updateConfiguration(
                        current,
                        cpu: current.cpuCount,
                        memoryMB: current.memoryMB,
                        network: mode.backendValue,
                        networkConfiguration: NetworkConfiguration(
                            mode: mode,
                            proxyURL: current.networkConfiguration?.proxyURL,
                            captureTraffic: current.networkConfiguration?.captureTraffic ?? false,
                            allowHostAccess: current.networkConfiguration?.allowHostAccess ?? false
                        )
                    )
                    stepSucceeded = true
                case .samplePerformance:
                    await refreshPerformance(for: current)
                    stepSucceeded = performanceSamples[current.id] != nil
                case .stop:
                    if current.isRunning {
                        stepSucceeded = await backend.stop(current, onLine: logger(scope: current.name)).succeeded
                    } else {
                        stepSucceeded = true
                    }
                case .snapshot:
                    if !current.isRunning {
                        stepSucceeded = await backend.createSnapshot(
                            of: current,
                            named: step.value ?? "Automated Snapshot",
                            onLine: logger(scope: current.name)
                        ).0.succeeded
                    }
                case .diagnostics:
                    stepSucceeded = await collectDiagnostics(for: current) != nil
                }
                if stepSucceeded { break }
                if attempt + 1 < attempts { try? await Task.sleep(for: .seconds(1)) }
            }
            if !stepSucceeded {
                appendLog(.error, scope: current.name, "Automation step failed: \(step.action.displayName)")
                if step.continueOnFailure != true { break workflowSteps }
            }
        }
        if let launchTask, workflow.steps.contains(where: { $0.action == .stop }) {
            _ = await launchTask.value
        }
        busyKeys.remove(key)
        orchestrationFlags.removeValue(forKey: workflow.id)
        snapshots = await backend.loadSnapshots()
        await refreshDevices()
        appendLog(.success, scope: initialDevice.name, "Workflow finished: \(workflow.name)")
        persistLogs()
    }

    func reloadPlugins() async {
        let labPaths = paths
        plugins = await Task.detached(priority: .utility) {
            PluginRegistry.loadPlugins(paths: labPaths)
        }.value
    }

    func setPluginTrusted(_ plugin: PluginDescriptor, trusted: Bool) async {
        do {
            let labPaths = paths
            plugins = try await Task.detached(priority: .userInitiated) {
                try PluginRegistry.setTrusted(plugin, trusted: trusted, paths: labPaths)
                return PluginRegistry.loadPlugins(paths: labPaths)
            }.value
            appendLog(
                trusted ? .warning : .info,
                scope: "plugin:\(plugin.id)",
                trusted ? "Plugin trusted with an executable checksum and declared permissions" : "Plugin trust revoked"
            )
            persistLogs()
        } catch {
            present(error, context: trusted ? "Trusting plugin" : "Revoking plugin trust")
        }
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

    func installXcodeDeploymentHelper() {
        do {
            let embeddedCLI = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/vdlctl")
            let helper = try DeveloperTools.installHelper(
                paths: paths,
                vdlctlPath: FileManager.default.isExecutableFile(atPath: embeddedCLI.path)
                    ? embeddedCLI.path : "/opt/homebrew/bin/vdlctl"
            )
            xcodeIntegration = DeveloperTools.inspect(paths: paths)
            appendLog(.success, scope: "developer-tools", "Installed Xcode deployment helper at \(helper.path)")
            persistLogs()
        } catch {
            present(error, context: "Installing Xcode deployment helper")
        }
    }

    func checkForUpdates(automatic: Bool = false) async {
        if !automatic { updateState = .checking }
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        do {
            updateState = try await updateService.check(currentVersion: current)
        } catch {
            if !automatic { updateState = .failed(error.localizedDescription) }
        }
    }

    func downloadAvailableUpdate() async {
        do {
            let destination = paths.stateRoot.appendingPathComponent("Updates", isDirectory: true)
            updateState = try await updateService.downloadVerifiedUpdate(destinationRoot: destination)
            if case let .downloaded(_, path) = updateState {
                reveal(URL(fileURLWithPath: path))
            }
        } catch {
            updateState = .failed(error.localizedDescription)
        }
    }

    func snapshotCount(for device: VirtualDevice) -> Int {
        snapshots.filter { $0.sourceVM == device.name }.count
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

    private func beginJournal(
        id: UUID = UUID(),
        kind: LabOperationKind,
        target: String,
        phase: LabOperationPhase,
        recovery: String
    ) {
        operationJournalEntries.insert(
            OperationJournalEntry(
                id: id,
                kind: kind,
                target: target,
                startedAt: .now,
                updatedAt: .now,
                state: .running,
                phase: phase,
                recoveryInstruction: recovery,
                message: "Operation started."
            ),
            at: 0
        )
        try? OperationJournalStore.save(operationJournalEntries, paths: paths)
    }

    private func finishJournal(id: UUID, result: CommandResult) {
        guard let index = operationJournalEntries.firstIndex(where: { $0.id == id }) else { return }
        operationJournalEntries[index].updatedAt = .now
        operationJournalEntries[index].state = result.succeeded ? .completed : .failed
        operationJournalEntries[index].phase = result.succeeded ? .completed : (result.cancelled ? .cancelled : .failed)
        operationJournalEntries[index].message = result.succeeded
            ? "Operation completed successfully."
            : "Operation exited with status \(result.exitCode). Review logs before cleanup or retry."
        try? OperationJournalStore.save(operationJournalEntries, paths: paths)
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

    private func progressHandler(scope: String) -> LabProgressHandler {
        { [weak self] event in self?.relayProgress(scope: scope, event: event) }
    }

    nonisolated private func relayLog(scope: String, line: String) {
        Task { @MainActor [weak self] in
            self?.appendLog(.info, scope: scope, line)
        }
    }

    nonisolated private func relayProgress(scope: String, event: LabProgressEvent) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            progressEvents.append(event)
            if progressEvents.count > 300 { progressEvents.removeFirst(progressEvents.count - 300) }
            appendLog(.info, scope: scope, "[\(event.phase.rawValue)] \(event.message)")
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
