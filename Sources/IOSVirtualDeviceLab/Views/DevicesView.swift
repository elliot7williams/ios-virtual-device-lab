import SwiftUI
import UniformTypeIdentifiers

struct DevicesView: View {
    @EnvironmentObject private var model: LabAppModel
    @Binding var showCreateVM: Bool

    var body: some View {
        if model.devices.isEmpty {
            LabEmptyState(
                icon: "iphone.gen3",
                title: "No virtual devices",
                message: "Create a supported vphone device to begin building the multi-version test library.",
                actionTitle: "Create Virtual Device"
            ) { showCreateVM = true }
        } else {
            HSplitView {
                List(selection: $model.selectedDeviceID) {
                    ForEach(model.devices) { device in
                        DeviceRow(device: device)
                            .tag(device.id)
                    }
                }
                .listStyle(.sidebar)
                .frame(minWidth: 250, idealWidth: 290, maxWidth: 340)

                if let device = model.selectedDevice {
                    DeviceDetailView(device: device)
                        .id(device.id)
                        .frame(minWidth: 570)
                } else {
                    LabEmptyState(
                        icon: "cursorarrow.click",
                        title: "Select a virtual device",
                        message: "Choose a device from the library to inspect and control it."
                    )
                }
            }
        }
    }
}

private struct DeviceRow: View {
    @EnvironmentObject private var model: LabAppModel
    let device: VirtualDevice

    var body: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(device.isPaused ? Color.orange.opacity(0.15) : (device.isRunning ? Color.green.opacity(0.15) : Color.secondary.opacity(0.12)))
                Image(systemName: "iphone.gen3")
                    .foregroundStyle(device.isPaused ? .orange : (device.isRunning ? .green : .secondary))
            }
            .frame(width: 38, height: 48)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(device.name).font(.headline).lineLimit(1)
                    Spacer()
                    if model.isBusy("launch:\(device.id)") || model.isBusy("stop:\(device.id)") {
                        ProgressView().controlSize(.small)
                    }
                }
                Text(device.iosLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("\(device.cpuCount) CPU • \(device.memoryLabel) • \(model.snapshotCount(for: device)) snapshots")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 5)
    }
}

private struct DeviceDetailView: View {
    @EnvironmentObject private var model: LabAppModel
    let device: VirtualDevice

    @State private var showingClone = false
    @State private var showingSnapshot = false
    @State private var showingConfig = false
    @State private var showingDeleteConfirmation = false
    @State private var showingPackageImporter = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                primaryActions
                metrics
                details
                developerWorkflow
                dangerZone
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $showingClone) {
            NamePromptSheet(
                title: "Clone \(device.name)",
                message: "The clone receives a fresh device identity.",
                initialValue: "\(device.name)-copy",
                actionTitle: "Clone"
            ) { name in
                Task { await model.clone(device, as: name) }
            }
        }
        .sheet(isPresented: $showingSnapshot) {
            NamePromptSheet(
                title: "Create Snapshot",
                message: "Creates a compressed, named restore point. The VM must remain stopped.",
                initialValue: "Clean State",
                actionTitle: "Create"
            ) { name in
                Task { await model.createSnapshot(of: device, name: name) }
            }
        }
        .sheet(isPresented: $showingConfig) {
            DeviceConfigurationSheet(device: device)
                .environmentObject(model)
        }
        .fileImporter(
            isPresented: $showingPackageImporter,
            allowedContentTypes: [
                UTType(filenameExtension: "ipa") ?? .archive,
                UTType(filenameExtension: "tipa") ?? .archive,
            ],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                if let package = urls.first {
                    Task { await model.launch(device, installPackage: package) }
                }
            case let .failure(error):
                model.alertMessage = error.localizedDescription
            }
        }
        .alert("Delete \(device.name)?", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task { await model.delete(device) }
            }
        } message: {
            Text("This permanently removes the VM bundle and its virtual disk. Existing exported snapshots are preserved.")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: "iphone.gen3")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(device.isRunning ? .green : .secondary)
                .frame(width: 62, height: 76)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 10) {
                    Text(device.name).font(.largeTitle.weight(.semibold))
                    StatusPill(
                        text: device.isPaused ? "Paused" : (device.isRunning ? "Running" : "Stopped"),
                        color: device.isPaused ? .orange : (device.isRunning ? .green : .secondary)
                    )
                }
                Text("\(device.iosLabel) • build \(device.buildLabel) • \(device.variantLabel)")
                    .foregroundStyle(.secondary)
                Text(device.bundleURL.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
            Spacer()
        }
    }

    private var primaryActions: some View {
        HStack(spacing: 10) {
            Button {
                Task { await model.launch(device) }
            } label: {
                Label("Boot", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(device.isRunning || model.isBusy("launch:\(device.id)"))

            Button {
                Task { await model.stop(device) }
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .disabled(!device.isRunning || model.isBusy("stop:\(device.id)"))

            Button {
                Task {
                    if device.isPaused { await model.resume(device) }
                    else { await model.pause(device) }
                }
            } label: {
                Label(device.isPaused ? "Resume" : "Pause", systemImage: device.isPaused ? "play.circle" : "pause.fill")
            }
            .disabled(!device.isRunning || !model.backendCapabilities.pause)

            Button { showingSnapshot = true } label: {
                Label("Snapshot", systemImage: "camera.filters")
            }
            .disabled(device.isRunning)

            Button { showingClone = true } label: {
                Label("Clone", systemImage: "square.on.square")
            }
            .disabled(device.isRunning)

            Spacer()
            Button { model.reveal(device.bundleURL) } label: {
                Label("Reveal", systemImage: "folder")
            }
        }
    }

    private var metrics: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
            MetricCard(title: "Processors", value: "\(device.cpuCount) cores", systemImage: "cpu")
            MetricCard(title: "Memory", value: device.memoryLabel, systemImage: "memorychip")
            MetricCard(title: "Virtual disk", value: device.diskLabel, systemImage: "internaldrive")
            MetricCard(title: "Network", value: device.network.mode.uppercased(), systemImage: "network")
            MetricCard(title: "Snapshots", value: "\(model.snapshotCount(for: device))", systemImage: "camera.filters")
        }
    }

    private var details: some View {
        GroupBox("Device metadata") {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 9) {
                detailRow("iOS", device.restoreInfo.map { "\($0.ios.version) (\($0.ios.build))" } ?? "Not restored")
                detailRow("cloudOS", device.restoreInfo.map { "\($0.cloudOS.version) (\($0.cloudOS.build))" } ?? "Not restored")
                detailRow("Variant", device.variantLabel)
                detailRow("Device model", device.restoreInfo?.device ?? "—")
                detailRow("Hardware profile", model.hardwareProfiles.profile(id: device.hardwareProfileID)?.name ?? "Legacy / unassigned")
                detailRow("UDID", device.udid ?? "—")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
        }
    }

    private var developerWorkflow: some View {
        GroupBox("Developer workflow") {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Launch & Install App").font(.headline)
                    Text("Select an IPA or TIPA. The lab boots this VM and installs it when the guest control channel connects.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Screenshot") {
                    Task { await model.captureScreenshot(of: device) }
                }
                .disabled(!device.isRunning || !model.backendCapabilities.screenshots)
                Button("Collect Diagnostics") {
                    Task {
                        if let bundle = await model.collectDiagnostics(for: device) { model.reveal(bundle.url) }
                    }
                }
                Button("Choose App…") { showingPackageImporter = true }
                    .disabled(device.isRunning)
            }
            .padding(.top, 6)
        }
    }

    private var dangerZone: some View {
        HStack {
            Button("Edit Configuration…") { showingConfig = true }
                .disabled(device.isRunning)
            Spacer()
            Button("Delete Virtual Device…", role: .destructive) {
                showingDeleteConfirmation = true
            }
            .disabled(device.isRunning)
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).frame(width: 95, alignment: .leading)
            Text(value).textSelection(.enabled)
        }
    }
}

struct NamePromptSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let message: String
    let actionTitle: String
    let action: (String) -> Void
    @State private var value: String

    init(
        title: String,
        message: String,
        initialValue: String,
        actionTitle: String,
        action: @escaping (String) -> Void
    ) {
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
        _value = State(initialValue: initialValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2.weight(.semibold))
            Text(message).foregroundStyle(.secondary)
            TextField("Name", text: $value)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button(actionTitle, action: submit)
                    .buttonStyle(.borderedProminent)
                    .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 430)
    }

    private func submit() {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        dismiss()
        action(trimmed)
    }
}

private struct DeviceConfigurationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: LabAppModel
    let device: VirtualDevice

    @State private var cpu: Int
    @State private var memoryMB: Int
    @State private var profileID: String?
    @State private var networkMode: NetworkMode
    @State private var proxyURL: String
    @State private var captureTraffic: Bool
    @State private var allowHostNetwork: Bool
    @State private var audioOutput: Bool
    @State private var audioInput: Bool
    @State private var audioRoute: AudioRoute
    @State private var simulateInterruptions: Bool
    @State private var allowClipboard: Bool
    @State private var allowHostIntegration: Bool

    init(device: VirtualDevice) {
        self.device = device
        _cpu = State(initialValue: max(1, device.cpuCount))
        _memoryMB = State(initialValue: max(2_048, device.memoryMB))
        _profileID = State(initialValue: device.hardwareProfileID)
        _networkMode = State(initialValue: device.networkConfiguration?.mode ?? (device.network.mode == "bridged" ? .bridged : (device.network.mode == "none" ? .offline : .nat)))
        _proxyURL = State(initialValue: device.networkConfiguration?.proxyURL ?? "")
        _captureTraffic = State(initialValue: device.networkConfiguration?.captureTraffic ?? false)
        _allowHostNetwork = State(initialValue: device.networkConfiguration?.allowHostAccess ?? false)
        _audioOutput = State(initialValue: device.audioConfiguration?.outputEnabled ?? true)
        _audioInput = State(initialValue: device.audioConfiguration?.inputEnabled ?? false)
        _audioRoute = State(initialValue: device.audioConfiguration?.route ?? .systemOutput)
        _simulateInterruptions = State(initialValue: device.audioConfiguration?.simulateInterruptions ?? false)
        _allowClipboard = State(initialValue: device.isolationPolicy?.allowClipboard ?? false)
        _allowHostIntegration = State(initialValue: device.isolationPolicy?.allowHostIntegration ?? false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Configure \(device.name)").font(.title2.weight(.semibold))
            Form {
                Section("Hardware") {
                    Picker("Device profile", selection: $profileID) {
                        Text("Legacy / unassigned").tag(String?.none)
                        ForEach(model.hardwareProfiles.profiles) { profile in
                            Text(profile.name).tag(Optional(profile.id))
                        }
                    }
                    Stepper("CPU cores: \(cpu)", value: $cpu, in: 2...16)
                    Stepper("Memory: \(memoryMB) MB", value: $memoryMB, in: 2_048...32_768, step: 1_024)
                }
                Section("Network") {
                    Picker("Mode", selection: $networkMode) {
                        ForEach(NetworkMode.allCases) { mode in Text(mode.displayName).tag(mode) }
                    }
                    TextField("Proxy URL (optional)", text: $proxyURL)
                    Toggle("Capture traffic", isOn: $captureTraffic)
                    Toggle("Allow host-network access", isOn: $allowHostNetwork)
                }
                Section("Audio") {
                    Toggle("Output", isOn: $audioOutput)
                    Toggle("Input", isOn: $audioInput)
                    Picker("Route", selection: $audioRoute) {
                        ForEach(AudioRoute.allCases) { route in Text(route.rawValue).tag(route) }
                    }
                    Toggle("Simulate interruptions", isOn: $simulateInterruptions)
                }
                Section("Isolation") {
                    Toggle("Allow clipboard", isOn: $allowClipboard)
                    Toggle("Allow host integration", isOn: $allowHostIntegration)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Apply") {
                    dismiss()
                    Task {
                        await model.updateConfiguration(
                            device,
                            cpu: cpu,
                            memoryMB: memoryMB,
                            network: networkMode.backendValue,
                            hardwareProfileID: profileID,
                            networkConfiguration: NetworkConfiguration(
                                mode: networkMode,
                                proxyURL: proxyURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : proxyURL,
                                captureTraffic: captureTraffic,
                                allowHostAccess: allowHostNetwork
                            ),
                            audio: AudioConfiguration(
                                outputEnabled: audioOutput,
                                inputEnabled: audioInput,
                                route: audioRoute,
                                sampleRateHz: 48_000,
                                simulateInterruptions: simulateInterruptions,
                                backgroundAudioValidation: true
                            ),
                            isolation: IsolationPolicy(
                                allowNetwork: networkMode != .offline,
                                allowHostNetwork: allowHostNetwork,
                                sharedFolderPath: nil,
                                allowClipboard: allowClipboard,
                                allowHostIntegration: allowHostIntegration
                            )
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 560, height: 680)
    }
}
