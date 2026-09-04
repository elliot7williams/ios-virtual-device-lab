import SwiftUI

struct DiagnosticsPerformanceView: View {
    @EnvironmentObject private var model: LabAppModel
    @State private var selectedDeviceID: String?
    @State private var categories = Set(DiagnosticCategory.allCases)
    @State private var useTrustedAnalyzer = false
    @State private var diagnosticPassphrase = ""

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
                        capabilityMatrix
                        configuration(device)
                        diagnosticControls(device)
                        privacyAndAnalysis(device)
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

    private var capabilityMatrix: some View {
        GroupBox("Backend capability evidence") {
            VStack(spacing: 8) {
                ForEach(model.backendCapabilities.featureSupport) { feature in
                    HStack(alignment: .top) {
                        StatusPill(
                            text: feature.state == .available ? "Available" : (feature.state == .extensionRequired ? "Extension" : "Unavailable"),
                            color: feature.state == .available ? .green : (feature.state == .extensionRequired ? .orange : .secondary)
                        )
                        Text(feature.name).fontWeight(.medium)
                        Spacer()
                        Text(feature.reason).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 6)
        }
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
                    .accessibilityLabel("Collect sanitized standard diagnostic bundle")
                    Button("Export Guest Diagnostics") {
                        Task {
                            let result = await model.exportGuestDiagnostics(for: device, categories: Array(categories))
                            if let output = result.outputURL { model.reveal(output) }
                            else { model.alertMessage = result.message }
                        }
                    }
                    .disabled(categories.isEmpty)
                    .accessibilityLabel("Export selected guest diagnostic categories")
                }
            }
            .padding(.top, 6)
        }
    }

    private func privacyAndAnalysis(_ device: VirtualDevice) -> some View {
        GroupBox("Privacy & Assisted Diagnostics") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 18) {
                    Toggle("Redact secrets", isOn: privacyBinding(\.redactSecrets))
                    Toggle("Redact personal data", isOn: privacyBinding(\.redactPersonalData))
                    Toggle("Include host profile", isOn: privacyBinding(\.includeHostProfile))
                    Toggle("Include screenshots", isOn: privacyBinding(\.includeScreenshots))
                    Toggle("Encrypt exports", isOn: privacyBinding(\.encryptExports))
                }
                Text("Bundles are sanitized locally before they are shown or handed to an analyzer. Local deterministic classification does not use the network.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let preview = model.latestDiagnosticPreview {
                    Label(
                        "Privacy preview: \(preview.filesIncluded) included, \(preview.filesExcluded) excluded, \(preview.redactions) redactions",
                        systemImage: "hand.raised.fill"
                    )
                    .font(.callout)
                }

                Toggle("Also run a trusted diagnostic-analysis plugin (explicit opt-in)", isOn: $useTrustedAnalyzer)
                HStack {
                    Button("Collect & Analyze") {
                        Task {
                            if let bundle = await model.collectDiagnostics(for: device) {
                                await model.analyzeDiagnostics(bundle, useTrustedPlugin: useTrustedAnalyzer)
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Collect sanitized diagnostics and run assisted analysis")
                    if let bundle = model.diagnosticBundles.first(where: { $0.deviceName == device.name }) {
                        Button("Analyze Latest Sanitized Bundle") {
                            Task { await model.analyzeDiagnostics(bundle, useTrustedPlugin: useTrustedAnalyzer) }
                        }
                    }
                    Spacer()
                }
                if model.diagnosticPrivacy.encryptExports,
                   let bundle = model.diagnosticBundles.first(where: { $0.deviceName == device.name }) {
                    HStack {
                        SecureField("Export passphrase (12+ characters)", text: $diagnosticPassphrase)
                        Button("Create Encrypted Export") {
                            model.exportEncryptedDiagnostics(bundle, passphrase: diagnosticPassphrase)
                            diagnosticPassphrase = ""
                        }
                        .disabled(diagnosticPassphrase.count < 12)
                    }
                }

                if let report = model.diagnosticAnalysisReports.first {
                    Divider()
                    Text(report.summary).font(.headline)
                    ForEach(report.findings.prefix(8)) { finding in
                        VStack(alignment: .leading, spacing: 3) {
                            Label(finding.title, systemImage: finding.severity == .critical ? "exclamationmark.octagon.fill" : "info.circle.fill")
                                .fontWeight(.medium)
                            Text(finding.recommendation).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.top, 6)
        }
    }

    private func privacyBinding(_ keyPath: WritableKeyPath<DiagnosticPrivacyPolicy, Bool>) -> Binding<Bool> {
        Binding(
            get: { model.diagnosticPrivacy[keyPath: keyPath] },
            set: { value in
                var policy = model.diagnosticPrivacy
                policy[keyPath: keyPath] = value
                model.updateDiagnosticPrivacy(policy)
            }
        )
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
