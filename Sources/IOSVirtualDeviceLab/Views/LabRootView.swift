import SwiftUI

struct LabRootView: View {
    @EnvironmentObject private var model: LabAppModel
    @State private var showingCreateVM = false

    private var sectionSelection: Binding<LabSection?> {
        Binding(
            get: { model.selectedSection },
            set: { if let value = $0 { model.selectedSection = value } }
        )
    }

    var body: some View {
        NavigationSplitView {
            List(selection: sectionSelection) {
                Section("Lab") {
                    ForEach(LabSection.allCases) { section in
                        Label(section.rawValue, systemImage: section.systemImage)
                            .tag(section)
                            .accessibilityIdentifier("lab.section.\(section.rawValue.lowercased().replacingOccurrences(of: " ", with: "-"))")
                    }
                }

                Section("Environment") {
                    LabeledContent("Backend") {
                        Text(model.readiness.binaryPath == nil ? "Missing" : "vphone-cli")
                            .foregroundStyle(model.readiness.binaryPath == nil ? .red : .secondary)
                    }
                    LabeledContent("Storage") {
                        Text("External")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Device Lab")
            .navigationSplitViewColumnWidth(min: 205, ideal: 230, max: 270)
        } detail: {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    HostReadinessBanner(readiness: model.readiness) {
                        Task { await model.recheckHost() }
                    }
                    Divider()
                    sectionContent
                }
                .frame(
                    width: geometry.size.width,
                    height: geometry.size.height,
                    alignment: .topLeading
                )
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    Task { await model.refreshAll() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh virtual device lab")
                .accessibilityIdentifier("lab.refresh")
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.isBusy("refresh"))

                Button {
                    showingCreateVM = true
                } label: {
                    Label("New Virtual Device", systemImage: "plus")
                }
                .accessibilityLabel("Create a new virtual device")
                .accessibilityIdentifier("lab.create-device")
                .keyboardShortcut("n", modifiers: .command)
            }
        }
        .sheet(isPresented: $showingCreateVM) {
            CreateVMView()
                .environmentObject(model)
        }
        .alert(
            "iOS Virtual Device Lab",
            isPresented: Binding(
                get: { model.alertMessage != nil },
                set: { if !$0 { model.alertMessage = nil } }
            )
        ) {
            Button("OK") { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "")
        }
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch model.selectedSection {
        case .devices:
            DevicesView(showCreateVM: $showingCreateVM)
        case .firmware:
            FirmwareLibraryView()
        case .profiles:
            HardwareProfilesView()
        case .compatibility:
            CompatibilityView()
        case .backends:
            BackendAttributionView()
        case .snapshots:
            SnapshotsView()
        case .testRuns:
            TestRunsView()
        case .automation:
            AutomationView()
        case .diagnostics:
            DiagnosticsPerformanceView()
        case .operations:
            LabOperationsView()
        case .productionReadiness:
            ProductionReadinessView()
        case .developerTools:
            DeveloperToolsView()
        case .plugins:
            PluginsView()
        case .activity:
            ActivityView()
        }
    }
}

struct LabSettingsView: View {
    @EnvironmentObject private var model: LabAppModel

    var body: some View {
        Form {
            Section("Backend") {
                LabeledContent("Executable", value: model.readiness.binaryPath ?? "Not found")
                LabeledContent("Status", value: model.readiness.state.rawValue)
            }
            Section("Storage") {
                LabeledContent("Data root", value: model.paths.dataRoot.path)
                LabeledContent("VM library", value: model.paths.libraryRoot.path)
                LabeledContent("Snapshots", value: model.paths.snapshotsRoot.path)
                Button("Reveal Data Root") { model.reveal(model.paths.dataRoot) }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
