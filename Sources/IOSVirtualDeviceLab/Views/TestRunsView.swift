import SwiftUI
import UniformTypeIdentifiers

struct TestRunsView: View {
    @EnvironmentObject private var model: LabAppModel
    @State private var runName = "Regression Run"
    @State private var selectedDeviceIDs: Set<String> = []
    @State private var packageURL: URL?
    @State private var showingPackageImporter = false
    @State private var baselineDeviceID: String?
    @State private var artifactID: UUID?
    @State private var assertionKinds = Set(TestAssertion.deploymentDefaults.map(\.kind))
    @State private var maximumDurationSeconds = 300

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    controls
                    runHistory
                }
                .padding(18)
            }
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
            case let .success(urls): packageURL = urls.first
            case let .failure(error): model.alertMessage = error.localizedDescription
            }
        }
        .onAppear {
            if baselineDeviceID == nil { baselineDeviceID = model.devices.first?.id }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Multi-version Test Runs").font(.title2.weight(.semibold))
                Text("Deploy one app to several VMs and preserve per-device results and screenshots.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isBusy {
                Button("Cancel Active Operations", role: .destructive) {
                    Task { await model.cancelOperations() }
                }
            }
        }
        .padding(18)
    }

    private var controls: some View {
        HStack(alignment: .top, spacing: 18) {
            GroupBox("Deployment Matrix") {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Run name", text: $runName)
                    Button(packageURL?.lastPathComponent ?? "Choose IPA/TIPA…") {
                        showingPackageImporter = true
                    }
                    if !model.appArtifacts.isEmpty {
                        Picker("Saved app build", selection: $artifactID) {
                            Text("None").tag(UUID?.none)
                            ForEach(model.appArtifacts) { artifact in
                                Text(artifact.name).tag(Optional(artifact.id))
                            }
                        }
                        .onChange(of: artifactID) { _, id in
                            packageURL = id.flatMap { selected in model.appArtifacts.first { $0.id == selected }?.url }
                        }
                    }
                    DisclosureGroup("Pass/fail assertions") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(TestAssertionKind.allCases) { kind in
                                Toggle(kind.displayName, isOn: Binding(
                                    get: { assertionKinds.contains(kind) },
                                    set: { enabled in
                                        if enabled { assertionKinds.insert(kind) } else { assertionKinds.remove(kind) }
                                    }
                                ))
                            }
                            if assertionKinds.contains(.maximumDuration) {
                                Stepper("Time limit: \(maximumDurationSeconds) seconds", value: $maximumDurationSeconds, in: 30...1_800, step: 30)
                            }
                        }
                        .padding(.top, 6)
                    }
                    Divider()
                    if model.devices.isEmpty {
                        Text("Create at least one virtual device first.").foregroundStyle(.secondary)
                    } else {
                        ForEach(model.devices) { device in
                            Toggle(isOn: Binding(
                                get: { selectedDeviceIDs.contains(device.id) },
                                set: { enabled in
                                    if enabled { selectedDeviceIDs.insert(device.id) }
                                    else { selectedDeviceIDs.remove(device.id) }
                                }
                            )) {
                                HStack {
                                    Text(device.name)
                                    Spacer()
                                    Text(device.iosLabel).foregroundStyle(.secondary)
                                    if device.isRunning { StatusPill(text: "Running", color: .orange) }
                                }
                            }
                        }
                    }
                    Button("Run on Selected Devices") {
                        guard let packageURL else { return }
                        Task {
                            await model.startDeploymentTest(
                                name: runName,
                                deviceIDs: selectedDeviceIDs,
                                packageURL: packageURL,
                                assertions: selectedAssertions
                            )
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(packageURL == nil || selectedDeviceIDs.isEmpty)
                }
                .padding(.top, 6)
            }
            .frame(maxWidth: .infinity)

            GroupBox("Baseline Acceptance") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Exercises clone → boot → guest control → screenshot → stop → snapshot → checksum → restore → cleanup.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Picker("Baseline VM", selection: $baselineDeviceID) {
                        Text("Choose a VM").tag(String?.none)
                        ForEach(model.devices) { device in
                            Text("\(device.name) — \(device.iosLabel)").tag(Optional(device.id))
                        }
                    }
                    Toggle(
                        "Include selected app package",
                        isOn: Binding(
                            get: { packageURL != nil },
                            set: { if !$0 { packageURL = nil } else { showingPackageImporter = true } }
                        )
                    )
                    Button("Run Full Acceptance") {
                        guard let id = baselineDeviceID,
                              let device = model.devices.first(where: { $0.id == id }) else { return }
                        Task { await model.runBaselineAcceptance(on: device, packageURL: packageURL) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(baselineDeviceID == nil)
                }
                .padding(.top, 6)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var selectedAssertions: [TestAssertion] {
        TestAssertionKind.allCases.compactMap { kind in
            guard assertionKinds.contains(kind) else { return nil }
            return TestAssertion(
                kind,
                expectedValue: kind == .maximumDuration ? String(maximumDurationSeconds) : nil
            )
        }
    }

    @ViewBuilder
    private var runHistory: some View {
        if model.testRuns.isEmpty {
            GroupBox {
                LabEmptyState(
                    icon: "checklist",
                    title: "No test runs yet",
                    message: "Deployment and baseline acceptance results will appear here."
                )
                .frame(height: 220)
            }
        } else {
            GroupBox("Run History") {
                LazyVStack(spacing: 10) {
                    ForEach(model.testRuns) { run in TestRunCard(run: run) }
                }
                .padding(.top, 6)
            }
        }
    }
}

private struct TestRunCard: View {
    @EnvironmentObject private var model: LabAppModel
    let run: TestRunRecord

    var body: some View {
        DisclosureGroup {
            VStack(spacing: 8) {
                ForEach(run.results) { result in
                    HStack(alignment: .top) {
                        StatusPill(text: result.state.rawValue.capitalized, color: color(for: result.state))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.deviceName).fontWeight(.medium)
                            Text(result.message).font(.caption).foregroundStyle(.secondary)
                            if let assertions = result.assertionResults {
                                ForEach(assertions) { assertion in
                                    Label(
                                        "\(assertion.assertion.kind.displayName): \(assertion.message)",
                                        systemImage: assertion.passed ? "checkmark.circle.fill" : "xmark.circle.fill"
                                    )
                                    .font(.caption2)
                                    .foregroundStyle(assertion.passed ? .green : .red)
                                }
                            }
                        }
                        Spacer()
                        if let path = result.screenshotPath {
                            Button("Screenshot") { model.reveal(URL(fileURLWithPath: path)) }
                        }
                        if let path = result.diagnosticBundlePath {
                            Button("Diagnostics") { model.reveal(URL(fileURLWithPath: path)) }
                        }
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            HStack {
                StatusPill(text: run.state.rawValue.capitalized, color: color(for: run.state))
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.name).fontWeight(.semibold)
                    Text("\(run.kind == .deployment ? "Deployment" : "Baseline acceptance") • \(run.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(run.results.filter { $0.state == .passed }.count)/\(run.results.count) passed")
                    .font(.caption.monospaced())
                if let report = run.reportPath {
                    Button("Report") { model.reveal(URL(fileURLWithPath: report)) }
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    private func color(for state: TestRunState) -> Color {
        switch state {
        case .passed: .green
        case .failed: .red
        case .cancelled: .orange
        case .running: .blue
        case .queued: .secondary
        }
    }
}
