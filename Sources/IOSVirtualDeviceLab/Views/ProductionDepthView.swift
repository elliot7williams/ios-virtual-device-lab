import SwiftUI
import UniformTypeIdentifiers

struct ProductionDepthView: View {
    @EnvironmentObject private var model: LabAppModel

    @State private var companionPayload: URL?
    @State private var companionIdentifier = "vdl-guest"
    @State private var companionVersion = "3.0.0"
    @State private var signingApp: URL?
    @State private var selectedIdentityID = ""
    @State private var leaseOwner = NSUserName()
    @State private var leaseMinutes = 60
    @State private var visualBaseline: URL?
    @State private var visualCandidate: URL?
    @State private var visualThreshold = 8
    @State private var changedPercent = 0.5
    @State private var maskX = 0
    @State private var maskY = 0
    @State private var maskWidth = 0
    @State private var maskHeight = 0
    @State private var faultName = "Network degradation"
    @State private var faultDomain: FaultInjectionDomain = .network
    @State private var faultDuration = 30
    @State private var faultLatency = 250
    @State private var faultLoss = 5.0
    @State private var faultOffline = false
    @State private var faultProxy = ""
    @State private var audioFault: AudioFaultKind = .interruption
    @State private var audioRoute = "speaker"
    @State private var mtlsEndpoint = "https://"
    @State private var mtlsAgentID = Host.current().localizedName.map(NameSanitizer.fileComponent) ?? "mac-agent"
    @State private var mtlsIdentityLabel = ""
    @State private var mtlsPins = ""
    @State private var repositoryRoot: URL?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                header
                companionLifecycle
                signingProvisioning
                physicalLifecycle
                visualRegression
                faultInjection
                fleetTransport
                scalableStorage
                upgradeCertification
                ciMaintenance
                operatorRunbooks
            }
            .padding(22)
        }
        .navigationTitle("Production Depth")
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Production Depth").font(.title2.weight(.semibold))
                Text("Managed guest software, signing, physical-device lifecycle, regression evidence, controlled faults, authenticated fleet transport, durable state, upgrade gates, CI lifecycle, and incident drills.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            StatusPill(text: "SCHEMA \(model.productionDepth.schemaVersion)", color: .indigo)
        }
    }

    private var companionLifecycle: some View {
        GroupBox("1. Guest companion lifecycle") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Imports versioned companion packages only after manifest, protocol, backend, path, size, and SHA-256 verification.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Import Package…") { chooseCompanionPackage() }
                        .accessibilityIdentifier("depth.companion.import")
                }
                HStack {
                    TextField("Package ID", text: $companionIdentifier).frame(maxWidth: 220)
                    TextField("Version", text: $companionVersion).frame(maxWidth: 110)
                    Button(companionPayload?.lastPathComponent ?? "Choose Payload…") {
                        companionPayload = chooseFile()
                    }
                    Button("Build & Import…") {
                        if let companionPayload, let destination = chooseDirectory() {
                            model.buildGuestCompanionPackage(
                                payload: companionPayload, identifier: companionIdentifier,
                                version: companionVersion, destination: destination
                            )
                        }
                    }
                    .disabled(companionPayload == nil || companionIdentifier.isEmpty || companionVersion.isEmpty)
                    .accessibilityIdentifier("depth.companion.build")
                }
                ForEach(model.productionDepth.companions) { package in
                    HStack {
                        StatusPill(text: package.active ? "ACTIVE" : "INACTIVE", color: package.active ? .green : .secondary)
                        Text("\(package.identifier) \(package.version)").fontWeight(.medium)
                        Text(package.payloadSHA256.prefix(16) + "…").font(.caption.monospaced()).foregroundStyle(.secondary)
                        Spacer()
                        Button("Deploy") { Task { await model.deployGuestCompanion(package) } }
                            .disabled(!package.active || model.isBusy("companion-deploy"))
                        Button("Rollback") { model.rollbackGuestCompanion(package) }
                            .disabled(package.replacedVersion == nil)
                    }
                }
                if let record = model.productionDepth.companionLifecycle.first {
                    gateRow(record.succeeded, "Latest lifecycle event", record.message)
                } else {
                    Text("No companion package has been imported. The current guest remains unchanged.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }.padding(.top, 6)
        }
    }

    private var signingProvisioning: some View {
        GroupBox("2. Signing and provisioning manager") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button(signingApp?.lastPathComponent ?? "Choose Expanded .app…") { signingApp = chooseApp() }
                    Button("Refresh Identities") { Task { await model.refreshSigningIdentities() } }
                        .disabled(model.isBusy("signing-identities"))
                    Picker("Identity", selection: $selectedIdentityID) {
                        Text("Select identity").tag("")
                        ForEach(model.availableSigningIdentities) { identity in
                            Text(identity.commonName).tag(identity.id)
                        }
                    }.frame(maxWidth: 360)
                    Spacer()
                    Button("Inspect") {
                        if let signingApp { Task { await model.inspectSigningAndProvisioning(signingApp) } }
                    }.disabled(signingApp == nil || model.isBusy("signing-inspect"))
                    Button("Stage & Sign Copy") {
                        if let signingApp,
                           let identity = model.availableSigningIdentities.first(where: { $0.id == selectedIdentityID }) {
                            Task { await model.stageAndSign(signingApp, identity: identity) }
                        }
                    }.disabled(signingApp == nil || selectedIdentityID.isEmpty || model.isBusy("signing-stage"))
                    .accessibilityIdentifier("depth.signing.stage")
                }
                if let assessment = model.productionDepth.signingAssessments.first {
                    gateRow(assessment.passed, assessment.bundleIdentifier ?? "Unknown app", assessment.passed ? "Signature, profile, expiration, bundle, and team checks passed." : "One or more signing/provisioning gates failed.")
                    ForEach(assessment.checks) { gateRow($0.passed, $0.id, $0.evidence) }
                }
                Text("Signing always targets a staged copy under lab state; the selected source app is never overwritten.")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(.top, 6)
        }
    }

    private var physicalLifecycle: some View {
        GroupBox("3. Physical-device lifecycle and exclusive leases") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("Lease owner", text: $leaseOwner).frame(maxWidth: 220)
                    Stepper("\(leaseMinutes) minutes", value: $leaseMinutes, in: 1...1_440)
                    Spacer()
                    Button("Discover Devices") { Task { await model.discoverPhysicalDevices() } }
                }
                ForEach(model.labExpansion.physicalDevices) { target in
                    HStack {
                        Image(systemName: "iphone")
                        Text(target.name).fontWeight(.medium)
                        if let detail = model.productionDepth.physicalDetails.first(where: { $0.targetID == target.id }) {
                            StatusPill(text: detail.ready ? "READY" : "ACTION REQUIRED", color: detail.ready ? .green : .orange)
                            Text(detail.batteryPercent.map { String(format: "%.0f%% battery", $0) } ?? "battery unavailable")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Pair") { Task { await model.pairPhysicalDevice(target) } }
                        Button("Inspect & Mount DDI") { Task { await model.inspectPhysicalDevice(target) } }
                        Button("Lease") { model.acquirePhysicalDeviceLease(target, owner: leaseOwner, minutes: leaseMinutes) }
                    }
                }
                ForEach(model.productionDepth.physicalLeases.prefix(8)) { lease in
                    HStack {
                        StatusPill(text: lease.state.rawValue.uppercased(), color: lease.state == .active ? .green : .secondary)
                        Text(lease.targetID).font(.caption.monospaced())
                        Text(lease.owner).font(.caption)
                        Spacer()
                        Button("Release") { model.releasePhysicalDeviceLease(lease) }.disabled(lease.state != .active)
                    }
                }
                if model.labExpansion.physicalDevices.isEmpty {
                    Text("No CoreDevice target is connected. Lifecycle controls remain fail-closed.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }.padding(.top, 6)
        }
    }

    private var visualRegression: some View {
        GroupBox("4. Visual and accessibility regression") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button(visualBaseline?.lastPathComponent ?? "Choose Baseline PNG…") { visualBaseline = chooseImage() }
                    Button(visualCandidate?.lastPathComponent ?? "Choose Candidate PNG…") { visualCandidate = chooseImage() }
                    Stepper("Channel threshold \(visualThreshold)", value: $visualThreshold, in: 0...255)
                    TextField("Max changed %", value: $changedPercent, format: .number).frame(width: 110)
                    Spacer()
                    Button("Compare Pixels") {
                        if let visualBaseline, let visualCandidate {
                            Task { await model.compareVisualBaseline(
                                baseline: visualBaseline, candidate: visualCandidate,
                                masks: visualMasks,
                                threshold: visualThreshold, maximumChangedPercent: changedPercent
                            ) }
                        }
                    }.disabled(visualBaseline == nil || visualCandidate == nil || model.isBusy("visual-regression"))
                    .accessibilityIdentifier("depth.visual.compare")
                    Button("Compare Latest Accessibility Trees") { model.compareLatestAccessibilitySnapshots() }
                }
                HStack {
                    Text("Optional ignored pixel mask").font(.caption).foregroundStyle(.secondary)
                    Stepper("X \(maskX)", value: $maskX, in: 0...20_000)
                    Stepper("Y \(maskY)", value: $maskY, in: 0...20_000)
                    Stepper("W \(maskWidth)", value: $maskWidth, in: 0...20_000)
                    Stepper("H \(maskHeight)", value: $maskHeight, in: 0...20_000)
                }
                if let report = model.productionDepth.visualRegressions.first {
                    gateRow(report.passed, String(format: "%.4f%% changed", report.changedPercent), "\(report.changedPixels) of \(report.comparedPixels) pixels • mean error \(String(format: "%.6f", report.meanAbsoluteError))")
                    if let diff = report.diffPath { Button("Reveal Diff") { model.reveal(URL(fileURLWithPath: diff)) } }
                }
                if let report = model.productionDepth.accessibilityRegressions.first {
                    gateRow(report.passed, "Accessibility structure", "\(report.addedIdentifiers.count) added • \(report.removedIdentifiers.count) removed • \(report.changedNodes) changed")
                }
            }.padding(.top, 6)
        }
    }

    private var faultInjection: some View {
        GroupBox("5. Real network and audio fault injection") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("Scenario name", text: $faultName)
                    Picker("Domain", selection: $faultDomain) {
                        ForEach(FaultInjectionDomain.allCases) { Text($0.rawValue.capitalized).tag($0) }
                    }.frame(width: 150)
                    Stepper("\(faultDuration)s", value: $faultDuration, in: 1...3_600)
                    Spacer()
                    Button("Inject") { Task { await model.injectFaultScenario(faultScenario) } }
                        .disabled(model.isBusy("fault-injection"))
                        .accessibilityIdentifier("depth.fault.inject")
                }
                if faultDomain == .network {
                    HStack {
                        Stepper("Latency \(faultLatency) ms", value: $faultLatency, in: 0...60_000)
                        TextField("Packet loss %", value: $faultLoss, format: .number).frame(width: 130)
                        Toggle("Offline", isOn: $faultOffline)
                        TextField("Optional HTTP(S) proxy", text: $faultProxy)
                    }
                } else {
                    HStack {
                        Picker("Fault", selection: $audioFault) {
                            ForEach(AudioFaultKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        TextField("Route", text: $audioRoute)
                    }
                }
                if let result = model.productionDepth.faultResults.first {
                    gateRow(result.succeeded, "Latest fault", result.message)
                } else {
                    Text("Execution requires authenticated protocol v3 and an explicit fault_injection guest capability; policy alone is not reported as a pass.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.top, 6)
        }
    }

    private var fleetTransport: some View {
        GroupBox("6. Mutually authenticated fleet transport") {
            VStack(alignment: .leading, spacing: 8) {
                TextField("HTTPS endpoint", text: $mtlsEndpoint)
                HStack {
                    TextField("Agent ID", text: $mtlsAgentID)
                    TextField("Keychain client identity label", text: $mtlsIdentityLabel)
                }
                TextField("Server certificate SHA-256 pins (comma-separated)", text: $mtlsPins)
                HStack {
                    Text("Client credentials remain in Keychain. State stores labels, endpoint, pins, rotation, revocation, and probes only.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Save / Rotate Enrollment") { model.saveMTLSEnrollment(mtlsConfiguration) }
                    Button("Revoke Active") { model.revokeActiveMTLSEnrollment() }
                        .disabled(model.productionDepth.mtlsConfiguration == nil)
                    Button("Probe mTLS") { Task { await model.probeMTLSFleet() } }
                        .disabled(model.productionDepth.mtlsConfiguration == nil || model.isBusy("mtls-probe"))
                        .accessibilityIdentifier("depth.mtls.probe")
                }
                if let probe = model.productionDepth.mtlsProbes.first {
                    gateRow(probe.authenticated, probe.endpoint, probe.message)
                }
            }.padding(.top, 6)
        }
    }

    private var scalableStorage: some View {
        GroupBox("7. SQLite high-volume event storage") {
            VStack(alignment: .leading, spacing: 8) {
                gateRow(model.productionDepth.eventStore.integrityPassed, "SQLite integrity", model.productionDepth.eventStore.message)
                LabeledContent("Journal mode", value: model.productionDepth.eventStore.journalMode.uppercased())
                LabeledContent("Durable events", value: String(model.productionDepth.eventStore.rowCount))
                HStack {
                    Text("Activity and test-run updates dual-write to the WAL-backed event database. Migration is idempotent.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Migrate Current High-Volume State") { Task { await model.migrateHighVolumeStateToSQLite() } }
                        .disabled(model.isBusy("event-store-migration"))
                        .accessibilityIdentifier("depth.sqlite.migrate")
                }
            }.padding(.top, 6)
        }
    }

    private var upgradeCertification: some View {
        GroupBox("8. Exact runtime upgrade certification") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Certificates bind host, macOS, backend, companion, adapter, schema, qualification campaign, reviewed seal, and suite hash.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Issue from Suite Evidence…") { chooseCertificationSuite() }
                    Button("Evaluate Current Tuple") { model.evaluateCurrentRuntimeUpgrade() }
                        .accessibilityIdentifier("depth.upgrade.evaluate")
                }
                gateRow(model.productionDepth.upgradeDecision.allowed, "Current runtime tuple", model.productionDepth.upgradeDecision.allowed ? "An exact unexpired compatibility certificate permits this tuple." : model.productionDepth.upgradeDecision.blockers.joined(separator: " "))
                ForEach(model.productionDepth.compatibilityCertificates.prefix(5)) { certificate in
                    HStack {
                        StatusPill(text: certificate.expiresAt > .now ? "VALID" : "EXPIRED", color: certificate.expiresAt > .now ? .green : .orange)
                        Text(certificate.id.uuidString).font(.caption.monospaced())
                        Spacer()
                        Text("expires \(certificate.expiresAt.formatted(date: .abbreviated, time: .omitted))").font(.caption)
                    }
                }
            }.padding(.top, 6)
        }
    }

    private var ciMaintenance: some View {
        GroupBox("9. Dependency and CI lifecycle enforcement") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button(repositoryRoot?.lastPathComponent ?? "Choose Repository…") { repositoryRoot = chooseDirectory() }
                    Spacer()
                    Button("Audit Workflow Actions") {
                        if let repositoryRoot { model.auditCIMaintenance(repositoryRoot: repositoryRoot) }
                    }.disabled(repositoryRoot == nil)
                    .accessibilityIdentifier("depth.ci.audit")
                }
                let assessment = model.productionDepth.ciMaintenance
                gateRow(assessment.passed, "Workflow maintenance", assessment.message)
                ForEach(assessment.unpinnedActionReferences + assessment.deprecatedActionReferences, id: \.self) {
                    Label($0, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                }
            }.padding(.top, 6)
        }
    }

    private var operatorRunbooks: some View {
        GroupBox("10. Operator runbooks and drills") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(OperatorRunbookCatalog.builtIns) { runbook in
                    HStack {
                        StatusPill(text: runbook.risk.rawValue.uppercased(), color: runbook.risk == .destructive ? .red : .blue)
                        Text(runbook.title).fontWeight(.medium)
                        Text("\(runbook.steps.count) steps").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Run Read-Only Drill") { model.runOperatorDrill(runbook) }
                            .accessibilityIdentifier("depth.runbook.\(runbook.id)")
                    }
                    if let drill = model.productionDepth.runbookDrills.first(where: { $0.runbookID == runbook.id }) {
                        gateRow(drill.passed, "Latest drill", drill.message)
                    }
                }
                Text("Drills validate documentation, prerequisites, and verification steps. They never perform destructive runbook actions automatically.")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(.top, 6)
        }
    }

    private var faultScenario: FaultInjectionScenario {
        FaultInjectionScenario(
            id: UUID(), name: faultName, domain: faultDomain, durationSeconds: faultDuration,
            latencyMilliseconds: faultDomain == .network ? faultLatency : nil,
            packetLossPercent: faultDomain == .network ? faultLoss : nil,
            offline: faultDomain == .network && faultOffline,
            proxyURL: faultDomain == .network && !faultProxy.isEmpty ? faultProxy : nil,
            audioFault: faultDomain == .audio ? audioFault : nil,
            audioRoute: faultDomain == .audio && !audioRoute.isEmpty ? audioRoute : nil
        )
    }

    private var visualMasks: [VisualMaskRect] {
        guard maskWidth > 0, maskHeight > 0 else { return [] }
        return [VisualMaskRect(x: maskX, y: maskY, width: maskWidth, height: maskHeight)]
    }

    private var mtlsConfiguration: MTLSEnrollmentConfiguration {
        MTLSEnrollmentConfiguration(
            endpoint: mtlsEndpoint, agentID: NameSanitizer.fileComponent(mtlsAgentID),
            clientIdentityLabel: mtlsIdentityLabel,
            serverCertificateSHA256Pins: mtlsPins.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }, requestTimeoutSeconds: 30
        )
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

    private func chooseCompanionPackage() {
        if let url = chooseDirectory() { model.installGuestCompanionPackage(url) }
    }

    private func chooseFile() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func chooseDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func chooseApp() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "app")].compactMap { $0 }
        panel.treatsFilePackagesAsDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func chooseImage() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png]
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func chooseCertificationSuite() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { model.issueCurrentCompatibilityCertificate(suiteURL: url) }
    }
}
