import AppKit
import SwiftUI

struct PlatformEngineeringView: View {
    @EnvironmentObject private var model: LabAppModel
    @State private var resetPolicy = DeterministicResetPolicy.standard
    @State private var retryPolicy = RetryAndRegressionPolicy.standard
    @State private var qualityPolicy = FuzzAndCoveragePolicy.standard
    @State private var betaPolicy = BetaOperationsPolicy.standard
    @State private var sourceRevision = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                adapters
                reset
                builds
                replay
                trends
                fleet
                timeline
                security
                quality
                betaOperations
            }
            .padding(20)
            .frame(maxWidth: 1_160, alignment: .leading)
        }
        .onAppear {
            resetPolicy = model.platformEngineering.resetPolicy
            retryPolicy = model.platformEngineering.retryPolicy
            qualityPolicy = model.platformEngineering.qualityPolicy
            betaPolicy = model.platformEngineering.betaPolicy
            model.refreshPlatformEngineeringAssessments()
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Platform Engineering").font(.title2.weight(.semibold))
                Text("Backend contracts, reproducible tests, fleet placement, correlated evidence, security, quality gates, and staged beta operations.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Refresh", systemImage: "arrow.clockwise") { model.refreshPlatformEngineeringAssessments() }
                .accessibilityIdentifier("platform.refresh")
        }
    }

    private var adapters: some View {
        GroupBox("1. Backend Adapter SDK and conformance") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    StatusPill(
                        text: model.platformEngineering.adapterConformance.passed ? "PASS" : "NOT CONFORMANT",
                        color: model.platformEngineering.adapterConformance.passed ? .green : .orange
                    )
                    Text(model.platformEngineering.adapterManifests.first?.name ?? "No adapter manifest imported")
                    Spacer()
                    Button("Export SDK…") { exportAdapterSDK() }
                    Button("Import Manifest…") { importAdapter() }
                        .accessibilityIdentifier("platform.adapter-import")
                    Button("Run Conformance") { model.runAdapterConformance() }
                }
                ForEach(model.platformEngineering.adapterConformance.checks) { check in
                    gateRow(check.passed, check.id.capitalized, check.evidence)
                }
                Text("The frontend consumes a versioned capability contract. Adapter executables remain isolated and undeclared operations fail closed.")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(.top, 6)
        }
    }

    private var reset: some View {
        GroupBox("2. Deterministic test reset") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Toggle("Golden snapshot", isOn: $resetPolicy.restoreGoldenSnapshot)
                    Toggle("Reinstall app", isOn: $resetPolicy.reinstallApplication)
                    Toggle("App data", isOn: $resetPolicy.resetAppData)
                    Toggle("Permissions", isOn: $resetPolicy.resetPermissions)
                    Toggle("Keychain", isOn: $resetPolicy.resetKeychain)
                }
                HStack {
                    Toggle("Network", isOn: $resetPolicy.resetNetwork)
                    Toggle("Environment", isOn: $resetPolicy.reapplyEnvironment)
                    Spacer()
                    Button("Plan Reset") { model.updateResetPolicy(resetPolicy) }
                        .accessibilityIdentifier("platform.reset-plan")
                    Button("Export Plan…") { exportResetPlan() }
                        .disabled(model.platformEngineering.resetPlan.generatedAt == .distantPast)
                }
                ForEach(model.platformEngineering.resetPlan.steps) { step in
                    gateRow(step.supported, "\(step.order). \(step.action)", step.evidence)
                }
                ForEach(model.platformEngineering.resetPlan.blockers, id: \.self) {
                    Label($0, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                }
                Text("A reset can execute only after the backend exposes every required authenticated guest operation; planning never claims the guest was changed.")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(.top, 6)
        }
    }

    private var builds: some View {
        GroupBox("3. Build, signing, and symbol catalog") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("Source revision (optional)", text: $sourceRevision).frame(maxWidth: 320)
                    Spacer()
                    Button("Index Latest Artifact") {
                        if let artifact = model.appArtifacts.first {
                            model.indexBuildIdentity(artifact, sourceRevision: sourceRevision)
                        }
                    }
                    .disabled(model.appArtifacts.isEmpty)
                    .accessibilityIdentifier("platform.build-index")
                    Button("Index with dSYM…") { chooseDSYM() }.disabled(model.appArtifacts.isEmpty)
                }
                if model.appArtifacts.isEmpty {
                    Text("Import a signed .app or .ipa in Developer Tools first.").font(.caption).foregroundStyle(.orange)
                }
                ForEach(model.platformEngineering.builds.prefix(4)) { build in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(build.appName).fontWeight(.medium)
                            Text([build.marketingVersion, build.buildNumber].compactMap { $0 }.joined(separator: " ("))
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                            Spacer()
                            Text(build.sha256.map { String($0.prefix(12)) + "…" } ?? "No hash")
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Text("Bundle \(build.bundleIdentifier ?? "unknown") • Team \(build.signingTeamIdentifier ?? "unsigned/unknown") • \(build.executableUUIDs.count) executable UUID(s) • \(build.dSYMPaths.count) dSYM(s)")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(build.warnings, id: \.self) { Text($0).font(.caption2).foregroundStyle(.orange) }
                    }
                    .padding(8).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                }
            }.padding(.top, 6)
        }
    }

    private var replay: some View {
        GroupBox("4. Reproducible failure bundles") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Packages the failed run identity, Labfile, environment mapping, fixture IDs, and evidence references.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Bundle Latest Failure") {
                        if let run = latestFailedRun { model.createFailureReplayBundle(for: run) }
                    }
                    .disabled(latestFailedRun == nil)
                    .accessibilityIdentifier("platform.replay-create")
                }
                ForEach(model.platformEngineering.replayBundles.prefix(3)) { bundle in
                    HStack {
                        Text(bundle.generatedAt.formatted()).fontWeight(.medium)
                        Text(bundle.manifestSHA256.prefix(16) + "…").font(.caption.monospaced()).foregroundStyle(.secondary)
                        Spacer()
                        Button("Reveal") { model.reveal(URL(fileURLWithPath: bundle.path)) }
                    }
                }
                Text("Firmware, VM disks, credentials, signing keys, secret values, and raw external files are excluded.")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(.top, 6)
        }
    }

    private var trends: some View {
        GroupBox("5. Flakiness and regression analysis") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Stepper("Retries \(retryPolicy.maximumRetries)", value: $retryPolicy.maximumRetries, in: 0...3)
                    Toggle("Infrastructure failures only", isOn: $retryPolicy.retryInfrastructureFailuresOnly)
                    Stepper("Quarantine at \(retryPolicy.quarantineFailureCount)", value: $retryPolicy.quarantineFailureCount, in: 1...10)
                    Stepper("Flaky floor \(Int(retryPolicy.flakyPassRateFloorPercent))%", value: $retryPolicy.flakyPassRateFloorPercent, in: 5...95, step: 5)
                    Stepper("Regression \(Int(retryPolicy.performanceRegressionPercent))%", value: $retryPolicy.performanceRegressionPercent, in: 5...100, step: 5)
                    Spacer()
                    Button("Save & Analyze") { model.updateRetryAndRegressionPolicy(retryPolicy) }
                        .accessibilityIdentifier("platform.trends-analyze")
                }
                if model.platformEngineering.trends.trends.isEmpty {
                    Text("Completed per-device test results will appear here.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(model.platformEngineering.trends.trends.prefix(8)) { trend in
                    HStack {
                        StatusPill(text: trend.flaky ? "FLAKY" : (trend.quarantined ? "QUARANTINE" : "TRACKED"), color: trend.flaky || trend.quarantined ? .orange : .green)
                        Text("\(trend.runName) • \(trend.deviceName)").fontWeight(.medium)
                        Spacer()
                        Text(String(format: "%.1f%% pass • n=%d • p95 %.1fs", trend.passRatePercent, trend.sampleCount, trend.p95DurationSeconds ?? 0))
                            .font(.caption.monospaced()).foregroundStyle(trend.performanceRegression ? .orange : .secondary)
                    }
                }
            }.padding(.top, 6)
        }
    }

    private var fleet: some View {
        GroupBox("6. Multi-Mac fleet scheduler") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    StatusPill(text: model.platformEngineering.placement.placed ? "PLACED" : "NO PLACEMENT", color: model.platformEngineering.placement.placed ? .green : .orange)
                    Text(model.platformEngineering.placement.hostName ?? model.platformEngineering.placement.blockers.first ?? "No request")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Register This Mac") { model.registerLocalFleetHost() }
                        .accessibilityIdentifier("platform.fleet-register")
                    Button("Preview Placement") { model.previewFleetPlacement() }
                }
                ForEach(model.platformEngineering.fleetHosts) { host in
                    HStack {
                        Image(systemName: host.state == .online ? "desktopcomputer.and.macbook" : "desktopcomputer.trianglebadge.exclamationmark")
                        Text(host.name).fontWeight(.medium)
                        Text("\(host.runningVMs)/\(host.maximumConcurrentVMs) VMs • \(host.memoryMB) MB • \(host.capabilities.count) capabilities")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Toggle("Drained", isOn: Binding(
                            get: { host.drained },
                            set: { model.setFleetHostDrained(host, drained: $0) }
                        )).toggleStyle(.switch)
                    }
                }
                Text("Remote placement is scheduling only until an authenticated remote agent is configured; no remote work is simulated.")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(.top, 6)
        }
    }

    private var timeline: some View {
        GroupBox("7. Unified run timeline") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Correlates run phases, assertions, logs, screenshots, diagnostics, and host performance by timestamp.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Capture Latest Run") {
                        if let run = model.testRuns.first { model.captureUnifiedTimeline(for: run) }
                    }
                    .disabled(model.testRuns.isEmpty)
                    .accessibilityIdentifier("platform.timeline-capture")
                }
                if let timeline = model.platformEngineering.timelines.first {
                    LabeledContent("Latest", value: "\(timeline.events.count) events • \(timeline.generatedAt.formatted())")
                    ForEach(timeline.events.suffix(5)) { event in
                        HStack {
                            Text(event.timestamp.formatted(date: .omitted, time: .standard)).font(.caption.monospaced())
                            Text(event.kind.rawValue.capitalized).font(.caption.weight(.medium))
                            Text(event.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    ForEach(timeline.unavailableSources, id: \.self) { Text($0).font(.caption2).foregroundStyle(.orange) }
                }
            }.padding(.top, 6)
        }
    }

    private var security: some View {
        GroupBox("8. Threat model and secrets inventory") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    StatusPill(text: model.platformEngineering.security.passed ? "PASS" : "REVIEW", color: model.platformEngineering.security.passed ? .green : .orange)
                    Text("Secret metadata only; values are never read into reports.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reassess") { model.refreshPlatformEngineeringAssessments() }
                        .accessibilityIdentifier("platform.security-assess")
                }
                ForEach(model.platformEngineering.security.threats) { threat in
                    gateRow(threat.state == .passed, threat.boundary, "\(threat.threat) — \(threat.evidence)")
                }
                Divider()
                ForEach(model.platformEngineering.security.secrets) { secret in
                    HStack {
                        Image(systemName: secret.present ? "key.fill" : "key.slash")
                            .foregroundStyle(secret.present ? .green : .secondary)
                        Text(secret.purpose).fontWeight(.medium)
                        Spacer()
                        Text("\(secret.storage) • export \(secret.exportAllowed ? "allowed" : "forbidden")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.padding(.top, 6)
        }
    }

    private var quality: some View {
        GroupBox("9. Continuous fuzzing and coverage gates") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Stepper("Cases \(qualityPolicy.caseCount)", value: $qualityPolicy.caseCount, in: 100...10_000, step: 100)
                    Stepper("Coverage gate \(Int(qualityPolicy.minimumSourceCoveragePercent))%", value: $qualityPolicy.minimumSourceCoveragePercent, in: 0...100, step: 5)
                    TextField("Measured coverage %", value: $qualityPolicy.measuredSourceCoveragePercent, format: .number)
                        .frame(width: 150)
                    Spacer()
                    Button("Save Policy") { model.updateQualityPolicy(qualityPolicy) }
                    Button("Run Deterministic Fuzz") {
                        model.updateQualityPolicy(qualityPolicy)
                        Task { await model.runEngineeringQualitySuite() }
                    }
                    .disabled(model.isBusy("platform-quality"))
                    .accessibilityIdentifier("platform.quality-run")
                }
                HStack {
                    StatusPill(text: model.platformEngineering.quality.fuzzGatePassed ? "FUZZ PASS" : "FUZZ INCOMPLETE", color: model.platformEngineering.quality.fuzzGatePassed ? .green : .orange)
                    StatusPill(text: model.platformEngineering.quality.coverageGatePassed ? "COVERAGE PASS" : "COVERAGE NEEDED", color: model.platformEngineering.quality.coverageGatePassed ? .green : .orange)
                    Text("\(model.platformEngineering.quality.totalCases) cases • \(model.platformEngineering.quality.failedCases) mismatch(es)")
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Text(model.platformEngineering.quality.coverageEvidence).font(.caption).foregroundStyle(.secondary)
                ForEach(model.platformEngineering.quality.suites) { suite in
                    LabeledContent(suite.id, value: "\(suite.cases) cases • \(suite.failures) failures • \(suite.behaviorClasses.joined(separator: ", "))")
                        .font(.caption)
                }
            }.padding(.top, 6)
        }
    }

    private var betaOperations: some View {
        GroupBox("10. Beta operations and feedback loop") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker("Channel", selection: $betaPolicy.channel) {
                        ForEach(BetaReleaseChannel.allCases) { Text($0.title).tag($0) }
                    }.frame(width: 190)
                    Stepper("Rollout \(betaPolicy.rolloutPercent)%", value: $betaPolicy.rolloutPercent, in: 1...100)
                    Stepper("Healthy runs \(betaPolicy.minimumHealthyLaunches)", value: $betaPolicy.minimumHealthyLaunches, in: 1...1_000)
                    Stepper("Crash max \(Int(betaPolicy.maximumCrashRatePercent))%", value: $betaPolicy.maximumCrashRatePercent, in: 0...25, step: 1)
                    Stepper("Support \(betaPolicy.supportResponseHours)h", value: $betaPolicy.supportResponseHours, in: 1...168)
                }
                HStack {
                    TextField("HTTPS feedback endpoint", text: Binding(
                        get: { betaPolicy.feedbackURL ?? "" }, set: { betaPolicy.feedbackURL = $0.isEmpty ? nil : $0 }
                    ))
                    Toggle("Allow sanitized diagnostics", isOn: $betaPolicy.allowSanitizedDiagnostics)
                    Button("Save & Evaluate") { model.updateBetaOperationsPolicy(betaPolicy) }
                        .accessibilityIdentifier("platform.beta-evaluate")
                    Button("Create Feedback Package") { model.createFeedbackPackage() }
                }
                StatusPill(text: model.platformEngineering.betaOperations.canPromote ? "PROMOTION READY" : "HOLD", color: model.platformEngineering.betaOperations.canPromote ? .green : .orange)
                ForEach(model.platformEngineering.betaOperations.gates) { gate in
                    gateRow(gate.passed, gate.id.capitalized, gate.evidence)
                }
                if let path = model.platformEngineering.latestFeedbackPackagePath {
                    Button("Reveal Latest Feedback Package") { model.reveal(URL(fileURLWithPath: path)) }
                }
                Text("Channel and rollout are policy records only; promotion never bypasses signing, notarization, public-beta, security, fuzz, or coverage gates.")
                    .font(.caption2).foregroundStyle(.secondary)
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

    private var latestFailedRun: TestRunRecord? {
        model.testRuns.first { $0.state == .failed || $0.results.contains { $0.state == .failed } }
    }

    private func importAdapter() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { model.importAdapterManifest(url) }
    }

    private func exportAdapterSDK() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export SDK Here"
        if panel.runModal() == .OK, let url = panel.url {
            model.exportAdapterSDK(to: url.appendingPathComponent("VirtualDeviceLabAdapterSDK", isDirectory: true))
        }
    }

    private func exportResetPlan() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "deterministic-reset-plan.json"
        if panel.runModal() == .OK, let url = panel.url { model.exportDeterministicResetPlan(to: url) }
    }

    private func chooseDSYM() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Index dSYM"
        if panel.runModal() == .OK, let url = panel.url, let artifact = model.appArtifacts.first {
            model.indexBuildIdentity(artifact, sourceRevision: sourceRevision, dSYM: url)
        }
    }
}
