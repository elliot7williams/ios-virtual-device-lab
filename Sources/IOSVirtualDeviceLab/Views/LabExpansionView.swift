import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LabExpansionView: View {
    @EnvironmentObject private var model: LabAppModel
    @State private var crashURL: URL?
    @State private var dSYMURL: URL?
    @State private var preferPhysical = false
    @State private var guestBundleIdentifier = ""
    @State private var guestSelector = ""
    @State private var guestValue = ""
    @State private var physicalAppURL: URL?
    @State private var routeCapabilities = "networking,audio"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                maturity
                qualification
                runtimeAdapters
                guestAutomation
                replay
                symbolication
                fleet
                timeline
                quality
                hybridLab
            }
            .padding(20)
            .frame(maxWidth: 1_160, alignment: .leading)
        }
        .onAppear { model.refreshLabExpansionAssessments() }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Qualification & Scale").font(.title2.weight(.semibold))
                Text("Evidence-backed maturity, executable adapters and replays, crash analysis, fleet leases, monotonic timelines, quality evidence, and hybrid device routing.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Refresh", systemImage: "arrow.clockwise") { model.refreshLabExpansionAssessments() }
                .accessibilityIdentifier("expansion.refresh")
        }
    }

    private var maturity: some View {
        GroupBox("1. Capability maturity matrix") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.labExpansion.maturity) { capability in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            StatusPill(text: capability.level.title.uppercased(), color: maturityColor(capability.level))
                            Text(capability.name).fontWeight(.medium)
                            Spacer()
                            Text(capability.evaluatedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text(capability.evidence.joined(separator: " ")).font(.caption).foregroundStyle(.secondary)
                        ForEach(capability.blockers, id: \.self) {
                            Label($0, systemImage: "lock.trianglebadge.exclamationmark")
                                .font(.caption2).foregroundStyle(.orange)
                        }
                    }
                    .padding(8)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                }
                Text("Maturity is derived from persisted evidence. The app never promotes a capability to real-VM qualified or release ready merely because its code exists.")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(.top, 6)
        }
    }

    private var qualification: some View {
        GroupBox("2. Real-VM qualification program") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Exact iOS, product type, hardware profile, backend, campaign, and reviewed seal combinations.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Record Campaign") { model.createQualificationCampaign() }
                        .accessibilityIdentifier("expansion.qualification-record")
                    Button("Export Approved…") { exportQualification() }
                        .disabled(!model.labExpansion.qualificationMatrix.contains { $0.state == .approved })
                }
                if model.labExpansion.qualificationMatrix.isEmpty {
                    Text("Restore and profile a virtual device to create a qualification matrix row.")
                        .font(.caption).foregroundStyle(.orange)
                }
                ForEach(model.labExpansion.qualificationMatrix) { entry in
                    HStack(alignment: .firstTextBaseline) {
                        StatusPill(text: entry.state.rawValue.uppercased(), color: entry.state == .approved ? .green : .orange)
                        Text("iOS \(entry.iosVersion) • \(entry.deviceProductType)").fontWeight(.medium)
                        Text(entry.hardwareProfileID).font(.caption.monospaced()).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(entry.backendID) \(entry.backendVersion ?? "unversioned")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.padding(.top, 6)
        }
    }

    private var runtimeAdapters: some View {
        GroupBox("3. Runtime adapter host") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Installs a conformance-passing executable into a versioned, checksum-pinned sandbox boundary.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Install Conformant Adapter") { model.installRuntimeAdapter() }
                        .disabled(!model.platformEngineering.adapterConformance.passed)
                        .accessibilityIdentifier("expansion.adapter-install")
                }
                ForEach(model.labExpansion.installedAdapters) { adapter in
                    HStack {
                        StatusPill(text: adapter.active ? "ACTIVE" : "INACTIVE", color: adapter.active ? .green : .secondary)
                        Text("\(adapter.name) \(adapter.version)").fontWeight(.medium)
                        Text(adapter.executableSHA256.prefix(16) + "…").font(.caption.monospaced()).foregroundStyle(.secondary)
                        Spacer()
                        Button("Probe") { Task { await model.probeRuntimeAdapter(adapter) } }
                            .disabled(!adapter.active || model.isBusy("adapter-probe"))
                        Button("Rollback") { model.rollbackRuntimeAdapter(adapter) }
                            .disabled(adapter.replacedVersion == nil)
                    }
                }
                if let invocation = model.labExpansion.adapterInvocations.first {
                    gateRow(invocation.succeeded, "Latest invocation", invocation.message)
                }
            }.padding(.top, 6)
        }
    }

    private var guestAutomation: some View {
        GroupBox("4. Guest automation services") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("App bundle identifier for scoped resets", text: $guestBundleIdentifier)
                    TextField("Accessibility selector", text: $guestSelector)
                    TextField("Text value", text: $guestValue)
                }
                HStack {
                    ForEach(GuestAutomationAction.allCases) { action in
                        Button(action.rawValue.replacingOccurrences(of: "_", with: " ").capitalized) {
                            Task {
                                await model.performGuestAutomation(
                                    action, bundleIdentifier: guestBundleIdentifier,
                                    selector: guestSelector, value: guestValue
                                )
                            }
                        }
                        .disabled(model.isBusy("guest-automation"))
                    }
                }
                if let result = model.labExpansion.guestAutomationResults.first {
                    gateRow(result.succeeded, "\(result.action.rawValue) on \(result.deviceName)", result.message)
                } else {
                    Text("Mutation requires authenticated, replay-protected protocol v3 plus the exact declared capability.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.top, 6)
        }
    }

    private var replay: some View {
        GroupBox("5. Replay validation and execution") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.platformEngineering.replayBundles.prefix(10)) { bundle in
                    HStack {
                        Text(bundle.generatedAt.formatted()).fontWeight(.medium)
                        Text(bundle.manifestSHA256.prefix(16) + "…").font(.caption.monospaced()).foregroundStyle(.secondary)
                        Spacer()
                        Button("Validate") { _ = model.validateReplay(bundle) }
                        Button("Execute") { Task { await model.executeReplay(bundle) } }
                    }
                }
                if model.platformEngineering.replayBundles.isEmpty {
                    Text("Create a failure replay bundle from Platform Engineering first.")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let execution = model.labExpansion.replayExecutions.first {
                    gateRow(execution.validation.passed, "Latest replay", execution.message)
                    ForEach(execution.validation.checks) { check in gateRow(check.passed, check.id, check.evidence) }
                }
            }.padding(.top, 6)
        }
    }

    private var symbolication: some View {
        GroupBox("6. Automatic crash symbolication") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button(crashURL?.lastPathComponent ?? "Choose Crash…") { chooseCrash() }
                    Button(dSYMURL?.lastPathComponent ?? "Choose dSYM…") { chooseDSYM() }
                    Spacer()
                    Button("Verify UUID & Symbolicate") {
                        if let crashURL, let dSYMURL { Task { await model.symbolicateCrash(crashURL, dSYM: dSYMURL) } }
                    }
                    .disabled(crashURL == nil || dSYMURL == nil || model.isBusy("symbolication"))
                    .accessibilityIdentifier("expansion.symbolicate")
                }
                if let report = model.labExpansion.symbolicationReports.first {
                    gateRow(report.succeeded, "UUID \(report.crashUUID ?? "missing")", report.succeeded ? "\(report.frames.count) frames • fingerprint \(report.fingerprint?.prefix(16) ?? "—")" : report.blockers.joined(separator: " "))
                    ForEach(report.frames.prefix(8)) { frame in
                        Text("\(frame.address)  \(frame.symbol)").font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            }.padding(.top, 6)
        }
    }

    private var fleet: some View {
        GroupBox("7. Production fleet control plane") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Placement uses heartbeat freshness, drain state, memory, concurrency, and active leases.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Register This Mac") { model.registerLocalFleetHost() }
                    Button("Acquire Lease") { model.acquireFleetLease() }
                        .disabled(model.platformEngineering.fleetHosts.isEmpty)
                        .accessibilityIdentifier("expansion.fleet-lease")
                }
                ForEach(model.platformEngineering.fleetHosts) { host in
                    HStack {
                        Text(host.name).fontWeight(.medium)
                        Text(host.state.rawValue).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Heartbeat") { model.recordFleetHeartbeat(host) }
                    }
                }
                ForEach(model.labExpansion.fleetLeases.prefix(10)) { lease in
                    HStack {
                        StatusPill(text: lease.state.rawValue.uppercased(), color: lease.state == .active ? .green : .secondary)
                        Text(lease.jobName)
                        Text("expires \(lease.expiresAt.formatted(date: .omitted, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Dispatch") { Task { await model.dispatchFleetLease(lease) } }
                            .disabled(lease.state != .active || model.remoteAgentConfiguration == nil)
                        Button("Release") { model.releaseFleetLease(lease) }.disabled(lease.state != .active)
                    }
                }
                if let dispatch = model.labExpansion.fleetDispatches.first {
                    gateRow(dispatch.authenticated, "Latest dispatch", dispatch.message)
                }
                Text("A second authenticated Mac is still required to qualify network transport; local leases do not claim remote execution.")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(.top, 6)
        }
    }

    private var timeline: some View {
        GroupBox("8. High-fidelity timeline capture") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Persists monotonic nanoseconds, wall-clock calibration, source identity, and explicit unavailable sources.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Capture Latest Run") {
                        if let run = model.testRuns.first { model.captureHighFidelityTimeline(run) }
                    }
                    .disabled(model.testRuns.isEmpty)
                    .accessibilityIdentifier("expansion.timeline-capture")
                }
                if let session = model.labExpansion.highFidelityTimelines.first {
                    LabeledContent("Latest", value: "\(session.events.count) events • \(session.unavailableSources.count) unavailable source(s)")
                    ForEach(session.events.suffix(8)) { event in
                        Text("\(event.monotonicNanoseconds)  \(event.source.rawValue)  \(event.summary)")
                            .font(.caption.monospaced()).lineLimit(1)
                    }
                }
            }.padding(.top, 6)
        }
    }

    private var quality: some View {
        GroupBox("9. Automated quality pipeline") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Imports LLVM or xccov JSON and pins the source artifact hash and revision.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Import Coverage…") { chooseCoverage() }
                        .accessibilityIdentifier("expansion.coverage-import")
                    Button("Run Fuzz Gate") { Task { await model.runEngineeringQualitySuite() } }
                        .disabled(model.isBusy("platform-quality"))
                }
                if let coverage = model.labExpansion.coverageReports.first {
                    gateRow(model.platformEngineering.quality.coverageGatePassed,
                            String(format: "%.1f%% line coverage", coverage.linePercent),
                            "\(coverage.producer) • \(coverage.sourceSHA256.prefix(16))… • \(coverage.sourceRevision ?? "revision not recorded")")
                } else {
                    Text("Coverage remains failed closed until a machine-readable report is imported.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }.padding(.top, 6)
        }
    }

    private var hybridLab: some View {
        GroupBox("10. Hybrid virtual/physical device lab") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Toggle("Prefer physical", isOn: $preferPhysical).toggleStyle(.switch)
                    TextField("Required capabilities (comma-separated)", text: $routeCapabilities)
                        .frame(maxWidth: 330)
                    Button(physicalAppURL?.lastPathComponent ?? "Choose Signed .app…") { choosePhysicalApp() }
                    Spacer()
                    Button("Discover via CoreDevice") { Task { await model.discoverPhysicalDevices() } }
                        .disabled(model.isBusy("physical-discovery"))
                        .accessibilityIdentifier("expansion.physical-discover")
                    Button("Route Test") {
                        model.routeHybridTarget(
                            preferPhysical: preferPhysical,
                            requiredCapabilities: routeCapabilities.split(separator: ",").map {
                                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                        )
                    }
                }
                ForEach(model.labExpansion.physicalDevices) { target in
                    HStack {
                        Image(systemName: "iphone")
                        Text(target.name).fontWeight(.medium)
                        Text("\(target.productType ?? "unknown") • iOS \(target.osVersion ?? "unknown")")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        StatusPill(text: target.available && target.authorized ? "READY" : "UNAVAILABLE", color: target.available && target.authorized ? .green : .orange)
                    }
                }
                if let target = model.labExpansion.hybridRoute.target {
                    gateRow(true, "Routed to \(target.name)", "\(target.kind.rawValue) • \(target.source)")
                    if target.kind == .physical {
                        Button("Install & Launch on Routed iPhone") {
                            if let physicalAppURL { Task { await model.deployToPhysicalTarget(app: physicalAppURL, target: target) } }
                        }
                        .disabled(physicalAppURL == nil || model.isBusy("physical-deployment"))
                        .accessibilityIdentifier("expansion.physical-deploy")
                    }
                } else {
                    ForEach(model.labExpansion.hybridRoute.blockers, id: \.self) { gateRow(false, "Route blocked", $0) }
                }
                if let deployment = model.labExpansion.physicalDeployments.first {
                    gateRow(deployment.installed && deployment.launched, "Latest physical deployment", deployment.message)
                }
            }.padding(.top, 6)
        }
    }

    @ViewBuilder
    private func gateRow(_ passed: Bool, _ title: String, _ evidence: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: passed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(passed ? .green : .orange)
            Text(title).fontWeight(.medium)
            Spacer()
            Text(evidence).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
    }

    private func maturityColor(_ level: CapabilityMaturityLevel) -> Color {
        switch level {
        case .designed: .secondary
        case .implemented: .blue
        case .integrated: .indigo
        case .realVMQualified: .green
        case .releaseReady: .mint
        }
    }

    private func exportQualification() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "approved-compatibility-evidence.json"
        if panel.runModal() == .OK, let url = panel.url { model.publishApprovedCompatibility(to: url) }
    }

    private func chooseCrash() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["crash", "ips", "txt"].compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK { crashURL = panel.url }
    }

    private func chooseDSYM() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "dSYM")].compactMap { $0 }
        panel.treatsFilePackagesAsDirectories = false
        if panel.runModal() == .OK { dSYMURL = panel.url }
    }

    private func chooseCoverage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url { model.importSourceCoverage(url) }
    }

    private func choosePhysicalApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "app")].compactMap { $0 }
        panel.treatsFilePackagesAsDirectories = false
        if panel.runModal() == .OK { physicalAppURL = panel.url }
    }
}
