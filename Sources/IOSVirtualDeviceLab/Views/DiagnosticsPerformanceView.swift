import SwiftUI

struct DiagnosticsPerformanceView: View {
    @EnvironmentObject private var model: LabAppModel
    @State private var selectedDeviceID: String?
    @State private var categories = Set(DiagnosticCategory.allCases)

    private var device: VirtualDevice? {
        model.devices.first { $0.id == selectedDeviceID }
    }

    private var sample: PerformanceSample? {
        selectedDeviceID.flatMap { model.performanceSamples[$0] }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                if let device {
                    VStack(alignment: .leading, spacing: 18) {
                        performance(device)
                        configuration(device)
                        diagnosticControls(device)
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    LabEmptyState(
                        icon: "waveform.path.ecg",
                        title: "Choose a virtual device",
                        message: "Performance, audio, networking, isolation, and diagnostic controls appear here."
                    )
                    .frame(minHeight: 420)
                }
            }
        }
        .onAppear { selectedDeviceID = selectedDeviceID ?? model.devices.first?.id }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Diagnostics & Performance").font(.title2.weight(.semibold))
                Text("Host counters plus explicit guest-log and crash-export capability reporting.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Virtual device", selection: $selectedDeviceID) {
                Text("Choose a device").tag(String?.none)
                ForEach(model.devices) { device in Text(device.name).tag(Optional(device.id)) }
            }
            .frame(width: 250)
        }
        .padding(18)
    }

    private func performance(_ device: VirtualDevice) -> some View {
        GroupBox("Live performance") {
            VStack(alignment: .leading, spacing: 12) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                    MetricCard(title: "CPU", value: percent(sample?.cpuPercent), systemImage: "cpu")
                    MetricCard(title: "RAM", value: bytes(sample?.residentMemoryBytes), systemImage: "memorychip")
                    MetricCard(title: "GPU", value: percent(sample?.gpuPercent), systemImage: "square.3.layers.3d")
                    MetricCard(title: "Disk I/O", value: diskRate(sample), systemImage: "internaldrive")
                    MetricCard(title: "FPS", value: sample?.framesPerSecond.map { String(format: "%.0f", $0) } ?? "Unavailable", systemImage: "speedometer")
                    MetricCard(title: "Audio", value: sample?.audioSampleRateHz.map { "\($0 / 1_000) kHz" } ?? "Unavailable", systemImage: "waveform")
                }
                HStack {
                    Text(sample?.source ?? "No sample collected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Refresh Sample") { Task { await model.refreshPerformance(for: device) } }
                }
            }
            .padding(.top, 6)
        }
    }

    private func configuration(_ device: VirtualDevice) -> some View {
        HStack(alignment: .top, spacing: 16) {
            GroupBox("Networking") {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Mode", value: device.networkConfiguration?.mode.displayName ?? device.network.mode.uppercased())
                    LabeledContent("Proxy", value: device.networkConfiguration?.proxyURL ?? "None")
                    LabeledContent("Traffic capture", value: device.networkConfiguration?.captureTraffic == true ? "Enabled" : "Disabled")
                    LabeledContent("Host access", value: device.networkConfiguration?.allowHostAccess == true ? "Allowed" : "Blocked")
                }
                .padding(.top, 6)
            }
            .frame(maxWidth: .infinity)

            GroupBox("Audio") {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Output", value: device.audioConfiguration?.outputEnabled == false ? "Disabled" : "Enabled")
                    LabeledContent("Input", value: device.audioConfiguration?.inputEnabled == true ? "Enabled" : "Disabled")
                    LabeledContent("Route", value: device.audioConfiguration?.route.rawValue ?? "Backend default")
                    LabeledContent("Background validation", value: device.audioConfiguration?.backgroundAudioValidation == true ? "Enabled" : "Disabled")
                }
                .padding(.top, 6)
            }
            .frame(maxWidth: .infinity)

            GroupBox("Isolation") {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Host integration", value: device.isolationPolicy?.allowHostIntegration == true ? "Allowed" : "Blocked")
                    LabeledContent("Clipboard", value: device.isolationPolicy?.allowClipboard == true ? "Allowed" : "Blocked")
                    LabeledContent("Shared folder", value: device.isolationPolicy?.sharedFolderPath ?? "None")
                }
                .padding(.top, 6)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func diagnosticControls(_ device: VirtualDevice) -> some View {
        GroupBox("Crash and diagnostic collection") {
            VStack(alignment: .leading, spacing: 12) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180))], alignment: .leading) {
                    ForEach(DiagnosticCategory.allCases) { category in
                        Toggle(category.rawValue, isOn: Binding(
                            get: { categories.contains(category) },
                            set: { enabled in
                                if enabled { categories.insert(category) } else { categories.remove(category) }
                            }
                        ))
                    }
                }
                HStack {
                    if !model.backendCapabilities.guestLogs || !model.backendCapabilities.crashExport {
                        Label("Guest syslog/crash export requires a trusted plugin or upstream backend support.", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    Button("Standard Bundle") {
                        Task {
                            if let bundle = await model.collectDiagnostics(for: device) { model.reveal(bundle.url) }
                        }
                    }
                    Button("Export Guest Diagnostics") {
                        Task {
                            let result = await model.exportGuestDiagnostics(for: device, categories: Array(categories))
                            if let output = result.outputURL { model.reveal(output) }
                            else { model.alertMessage = result.message }
                        }
                    }
                    .disabled(categories.isEmpty)
                }
            }
            .padding(.top, 6)
        }
    }

    private func percent(_ value: Double?) -> String {
        value.map { String(format: "%.1f%%", $0) } ?? "Unavailable"
    }

    private func bytes(_ value: Int64?) -> String {
        value.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .memory) } ?? "Unavailable"
    }

    private func diskRate(_ sample: PerformanceSample?) -> String {
        guard let read = sample?.diskReadBytesPerSecond, let write = sample?.diskWriteBytesPerSecond else { return "Unavailable" }
        return "R \(ByteCountFormatter.string(fromByteCount: read, countStyle: .file))/s • W \(ByteCountFormatter.string(fromByteCount: write, countStyle: .file))/s"
    }
}
