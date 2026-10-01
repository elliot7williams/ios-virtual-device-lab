import AppKit
import ServiceManagement
import SwiftUI
import VDLEvolutionCore

@MainActor func evolutionChooseFile(directory: Bool = false) -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = directory; panel.canChooseFiles = !directory
    return panel.runModal() == .OK ? panel.url : nil
}

struct BootstrapRescueView: View {
    @EnvironmentObject private var model: LabAppModel
    @State private var entries: [String] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Reconnect lab storage").font(.title)
            Text(model.storageLocationStatus.message)
            Text(model.paths.dataRoot.path).font(.caption.monospaced()).textSelection(.enabled)
            Text("Reconnect the volume or grant access, then retry. Inspect readable files or select an existing lab directory while device operations are paused.")
            HStack {
                Button("Retry Startup") { Task { await model.retryBootstrap() } }.accessibilityIdentifier("rescue.retry").disabled(model.isBusy("bootstrap"))
                Button("Choose Existing Lab Directory…") { if let url = evolutionChooseFile(directory: true) { Task { await model.relinkExternalStorage(to: url) } } }
                Button("Inspect Readable Files") { entries = (try? FileManager.default.contentsOfDirectory(atPath: model.paths.dataRoot.path)) ?? ["Storage is not readable yet."] }
                Button("Open Privacy Settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!) }
            }
            List(entries, id: \.self) { Text($0) }
        }.padding(24)
    }
}

struct LabEvolutionView: View {
    @EnvironmentObject private var model: LabAppModel
    @State private var revision = "f8324c052f089f0b0241708e02160a689fd9628c"
    @State private var provenance = ""
    @State private var kind: RegistryArtifactKind = .ipa
    @State private var working = false
    @State private var project = ""
    @State private var scheme = ""
    @State private var testPlan = ""
    @State private var destination = "platform=iOS Simulator,name=iPhone 17"
    @State private var stateMessage = "No saved-state validation has run."
    @State private var fixtureMessage = "Fixture service is stopped."
    @State private var serviceRevision = 0
    @State private var approvedExecutables: [URL] = []
    private func run(_ action: @escaping @MainActor () async -> Void) {
        guard !working else { return }; working = true
        Task { await action(); working = false }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("v1.2 Lab Tools").font(.title2.bold()); Spacer()
                    if working { ProgressView().controlSize(.small) }
                    Button("Refresh") { model.loadEvolution(); serviceRevision += 1 }.accessibilityIdentifier("evolution.refresh")
                }
                GroupBox("1. Startup and storage recovery") {
                    VStack(alignment: .leading) {
                        Text(model.storageLocationStatus.message)
                        Text("Unavailable storage opens the recovery screen automatically. Retry re-runs startup after access is restored.").font(.caption)
                        Button("Inspect Storage") { run { await model.refreshAll() } }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("2. Host-policy assistant") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Button("Inspect Host Policy") { run { await model.inspectHostPolicy() } }
                            Button("Recovery Setup") { model.selectedSection = .operationsHardening }
                            Button("Reveal Backend Helper") { model.reveal(URL(fileURLWithPath: "/Applications/vphone-cli.app/Contents/Resources/scripts/start_amfidont_for_vphone.sh")) }
                        }
                        ForEach(model.evolution.hostChecks) { check in
                            DisclosureGroup("\(check.passed ? "✓" : "⚠") \(check.name)") { Text(check.detail).font(.caption.monospaced()).textSelection(.enabled) }
                        }
                        Text("Recovery and amfidont are user-run host changes. Repeat binary launch and CDHash checks after backend upgrades.").font(.caption)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("3. Upstream compatibility tracking") {
                    VStack(alignment: .leading) {
                        TextField("Installed backend source revision (40 characters)", text: $revision).textFieldStyle(.roundedBorder)
                        Button("Check vphone Upstream") { run { await model.checkUpstream(revision: revision) } }
                        if let upstream = model.evolution.upstream {
                            Text(upstream.changed ? "Upstream differs. Review adapter and firmware compatibility before updating." : "Installed revision matches upstream.")
                            Link("Review upstream changes", destination: URL(string: upstream.compareURL)!)
                            Text("Checked \(upstream.checkedAt.formatted())").font(.caption)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("4. Background services") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(ManagedLabService.allCases) { service in
                            HStack {
                                VStack(alignment: .leading) { Text(service.rawValue); Text(service.status).font(.caption) }; Spacer()
                                Button("Import Config…") { if let file = evolutionChooseFile() { do { try model.configureService(service, from: file); serviceRevision += 1 } catch { model.alertMessage = error.localizedDescription } } }
                                Button("Start") { run { await model.changeService(service, action: "start"); serviceRevision += 1 } }
                                Button("Restart") { run { await model.changeService(service, action: "restart"); serviceRevision += 1 } }
                                Button("Stop / Unregister") { run { await model.changeService(service, action: "stop"); serviceRevision += 1 } }
                            }
                        }
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                        Text("Runs under your macOS account using imported certificate policies. Service approval is controlled in Login Items.").font(.caption)
                    }.id(serviceRevision)
                }
                GroupBox("5. Executable compatibility matrix") {
                    VStack(alignment: .leading) {
                        HStack {
                            Button("Run Matrix JSON…") { if let file = evolutionChooseFile() { run { await model.runVersionMatrix(file, approvedExecutables: approvedExecutables) } } }
                            Button("Approve Another Component Executable…") { if let file = evolutionChooseFile() { approvedExecutables.append(file) } }
                        }
                        ForEach(model.evolution.matrixResults) { result in
                            DisclosureGroup("\(result.passed ? "✓" : "⚠") \(result.id)") {
                                Text((result.issues + result.probes.map { "\($0.component): \($0.passed ? "PASS" : "FAIL") \($0.output.prefix(300))" }).joined(separator: "\n")).font(.caption)
                            }
                        }
                        Text("Pin all five components, migration, and optional downgrade probes. Installed components and \(approvedExecutables.count) explicitly selected executables are approved for this session.").font(.caption)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("6. Artifact registry") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Picker("Kind", selection: $kind) { ForEach(RegistryArtifactKind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.frame(width: 220)
                            TextField("Source / provenance", text: $provenance).textFieldStyle(.roundedBorder)
                            Button("Import…") { if let file = evolutionChooseFile() { run { await model.importRegistryArtifact(file, kind: kind, provenance: provenance) } } }.disabled(provenance.isEmpty)
                        }
                        ForEach(model.evolution.artifacts.prefix(30)) { artifact in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(artifact.originalName)
                                    Text("\(artifact.sha256.prefix(16)) · \(ByteCountFormatter.string(fromByteCount: artifact.bytes, countStyle: .file)) · \(artifact.approvedAt == nil ? "Quarantined" : "Approved")").font(.caption.monospaced())
                                }; Spacer()
                                if artifact.approvedAt == nil { Button("Approve") { model.approveRegistryArtifact(artifact) } }
                                Button("Export…") {
                                    let panel = NSSavePanel(); panel.nameFieldStringValue = artifact.originalName
                                    if panel.runModal() == .OK, let url = panel.url { do { try model.artifactRegistry.export(artifact.sha256, to: url) } catch { model.alertMessage = error.localizedDescription } }
                                }.disabled(artifact.approvedAt == nil)
                            }
                        }
                        Text("SHA-256 deduplication, quarantine, approval, and verified resumable cross-Mac file transfers are available through vdlctl artifact.").font(.caption)
                    }
                }
                GroupBox("7. Network and time fixtures") {
                    VStack(alignment: .leading) {
                        HStack {
                            Button("Import Scenario…") {
                                if let file = evolutionChooseFile() { do { let value = try EvolutionFiles.load(NetworkFixtureScenario.self, file); try value.validate(); model.evolution.fixtureScenario = value; model.saveEvolution() } catch { model.alertMessage = error.localizedDescription } }
                            }
                            Button("Start Fixture Server") { fixtureMessage = model.startNetworkFixture() }
                            Button("Stop") { model.stopNetworkFixture(); fixtureMessage = "Fixture service stopped." }
                            Button("Reveal Log") { model.reveal(model.paths.stateRoot.appendingPathComponent("network-fixture.log")) }
                        }
                        Text(fixtureMessage)
                        Text("HTTP 127.0.0.1:\(model.evolution.fixtureScenario.port) · DNS 127.0.0.1:\(model.evolution.fixtureScenario.dnsPort)")
                        Text("Clients opt into fixture endpoints. Simulated date is an HTTP header for an injected app clock. Guest clock changes, transparent proxies, TLS expiry simulation, and hypervisor packet loss require backend support.").font(.caption)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("8. Suspend / resume compatibility") {
                    VStack(alignment: .leading) {
                        Button("Validate Saved Machine State…") {
                            if let manifestURL = evolutionChooseFile(), let bindingURL = evolutionChooseFile(), let payload = evolutionChooseFile() {
                                do {
                                    let manifest = try EvolutionFiles.load(SavedMachineManifest.self, manifestURL), current = try EvolutionFiles.load(SavedMachineBinding.self, bindingURL)
                                    let issues = SavedMachineValidator.validate(manifest, current: current, deviceID: model.selectedDeviceID ?? "", stateFile: payload, backendAdvertisesRestore: false)
                                    stateMessage = issues.isEmpty ? "Validation passed." : issues.joined(separator: "\n")
                                    model.evolution.savedStateIssues = issues; model.saveEvolution()
                                } catch { model.alertMessage = error.localizedDescription }
                            }
                        }
                        Text(stateMessage)
                        Text("The current vphone adapter has no qualified RAM-state provider. The backend contract includes save/restore operations; disk snapshots remain available. Host/backend/firmware/profile changes invalidate saved state.").font(.caption)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("9. Fleet scheduling and recovery") {
                    VStack(alignment: .leading) {
                        Text("Coordinator 1.2 supports priorities, aging and subject fairness, per-host concurrency, queue quotas, capability matching, bounded retries/backoff, draining, and maintenance windows.")
                        Text("Admin: /v1/admin/maintenance · /v1/admin/backup · /v1/jobs/{id}/retry").font(.caption.monospaced())
                        Button("Export Scheduling Policy…") {
                            let panel = NSSavePanel(); panel.nameFieldStringValue = "scheduling-policy.json"
                            if panel.runModal() == .OK, let url = panel.url { do { try EvolutionFiles.save(model.evolution.schedulerPolicy, url) } catch { model.alertMessage = error.localizedDescription } }
                        }
                        Text("Recovery snapshots verify on restore. Fence the previous coordinator before promoting another Mac. Automatic distributed failover and mid-job preemption remain unqualified.").font(.caption)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("10. XCTest and xcresult") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { TextField("Project / workspace", text: $project).textFieldStyle(.roundedBorder); Button("Choose…") { if let url = evolutionChooseFile(directory: true) { project = url.path } } }
                        HStack { TextField("Scheme", text: $scheme); TextField("Test plan (optional)", text: $testPlan) }.textFieldStyle(.roundedBorder)
                        TextField("Xcode destination", text: $destination).textFieldStyle(.roundedBorder)
                        HStack {
                            Button("Run XCTest") {
                                let request = XcodeTestRequest(projectPath: project, scheme: scheme, testPlan: testPlan.isEmpty ? nil : testPlan, destination: destination,
                                    resultBundlePath: model.paths.stateRoot.appendingPathComponent("XCTestResults/\(UUID().uuidString).xcresult").path)
                                run { await model.runXCTest(request) }
                            }.disabled(project.isEmpty || scheme.isEmpty)
                            Button("Import xcresult…") { if let url = evolutionChooseFile(directory: true) { run { await model.importXCTestBundle(url) } } }
                        }
                        ForEach(model.evolution.xctestReports, id: \.id) { report in Text("\(report.passed ? "✓" : "⚠") \(report.cases.count) XCTest cases · \(report.importedAt.formatted())") }
                        Text("Preserves xcresult and exports available screenshots, diagnostics, coverage, JUnit, and HTML. Destinations must be recognized by Xcode; vphone devices are not currently Xcode destinations.").font(.caption)
                    }
                }
            }.padding(22).disabled(working)
        }.navigationTitle("v1.2 Lab Tools")
    }
}
