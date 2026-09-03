import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ReleaseCompletionView: View {
    @EnvironmentObject private var model: LabAppModel

    @State private var contract = V1SupportContract.draft
    @State private var iosVersions = "15"
    @State private var profileIDs = ""
    @State private var reviewer = NSUserName()
    @State private var companionRoot: URL?
    @State private var fleetPolicy = FleetAccessPolicy.localDraft
    @State private var principalSubject = ""
    @State private var principalRole: FleetRole = .operatorRole
    @State private var principalPin = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                supportContract
                companion
                realAcceptance
                compatibilityMatrix
                uiAutomation
                faultRecovery
                fleet
                reliability
                quality
                releaseExit
            }
            .padding(22)
        }
        .navigationTitle("v1 Completion")
        .onAppear(perform: loadDrafts)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("v1 Completion").font(.title2.weight(.semibold))
                Text("A fail-closed finish line for support scope, real guests, acceptance, UI automation, recovery, fleet operation, reliability, quality, and release evidence.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            StatusPill(
                text: model.releaseCompletion.report.releaseAuthorized ? "V1 AUTHORIZED" : "V1 HOLD",
                color: model.releaseCompletion.report.releaseAuthorized ? .green : .orange
            )
        }
    }

    private var supportContract: some View {
        GroupBox("1. v1 support contract") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("Product version", text: $contract.productVersion).frame(width: 140)
                    TextField("Minimum macOS", text: $contract.minimumMacOSVersion).frame(width: 150)
                    TextField("Minimum backend", text: $contract.minimumBackendVersion).frame(width: 160)
                    LabeledContent("Protocol", value: "v\(contract.guestProtocolVersion)")
                    Spacer()
                    StatusPill(text: model.releaseCompletion.supportContract.status.rawValue.uppercased(), color: contractColor)
                }
                TextField("Supported iOS lines (comma-separated)", text: $iosVersions)
                TextField("Exact hardware profile IDs (comma-separated)", text: $profileIDs)
                HStack {
                    Text("Profiles available: \(model.hardwareProfiles.profiles.map(\.id).joined(separator: ", "))")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Spacer()
                    Button("Save Candidate") { saveContract() }
                        .accessibilityIdentifier("completion.contract.save")
                    TextField("Reviewer", text: $reviewer).frame(width: 180)
                    Button("Approve After All Gates Pass") { model.approveSupportContract(reviewer: reviewer) }
                        .disabled(model.releaseCompletion.supportContract.status != .candidate)
                }
                ForEach(SupportContractValidator.evaluate(contract)) { check in
                    checkRow(check.passed, check.id, check.evidence)
                }
            }.padding(.top, 6)
        }
    }

    private var companion: some View {
        GroupBox("2. Real guest companion") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button(companionRoot?.lastPathComponent ?? "Choose vphone Checkout…") {
                        companionRoot = chooseDirectory()
                    }
                    Spacer()
                    Button("Audit Source Contract") {
                        if let companionRoot { Task { await model.auditGuestCompanionSource(repositoryRoot: companionRoot) } }
                    }
                    .disabled(companionRoot == nil || model.isBusy("completion-companion-audit"))
                    .accessibilityIdentifier("completion.companion.audit")
                }
                checkRow(
                    model.releaseCompletion.companionSource.passed,
                    "Source conformance", model.releaseCompletion.companionSource.message
                )
                ForEach(model.releaseCompletion.companionSource.checks) { check in
                    checkRow(check.passed, check.id, check.evidence)
                }
                Text("A source pass is not real-guest qualification. The running VM must independently advertise every capability over authenticated protocol v3.")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(.top, 6)
        }
    }

    private var realAcceptance: some View {
        GroupBox("3. First real-VM acceptance") {
            VStack(alignment: .leading, spacing: 8) {
                checkRow(
                    model.acceptanceReport.isPassed,
                    model.acceptanceReport.deviceName ?? "No selected acceptance device",
                    model.acceptanceReport.isPassed ? "Every real-VM gate passed." : "Run baseline acceptance from Lab Operations after host and firmware preflight."
                )
                ForEach(model.acceptanceReport.gates) { gate in
                    checkRow(gate.status == .passed, gate.kind.title, gate.evidence)
                }
            }.padding(.top, 6)
        }
    }

    private var compatibilityMatrix: some View {
        GroupBox("4. Supported iOS qualification matrix") {
            VStack(alignment: .leading, spacing: 8) {
                let rows = model.labExpansion.qualificationMatrix
                if rows.isEmpty {
                    Text("No exact device/profile/backend qualification row exists.")
                        .font(.caption).foregroundStyle(.orange)
                }
                ForEach(rows.prefix(20)) { row in
                    checkRow(
                        row.state == .approved,
                        "iOS \(row.iosVersion) • \(row.deviceProductType)",
                        "\(row.hardwareProfileID) • \(row.state.rawValue)"
                    )
                }
                Text("The contract is satisfied only when every declared iOS major has an approved evidence-sealed row.")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(.top, 6)
        }
    }

    private var uiAutomation: some View {
        GroupBox("5. Real macOS UI automation") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Run `vdl-ui-smoke --app <built.app> --output <report.json>` in a logged-in macOS session with Accessibility permission.")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Spacer()
                    Button("Import UI Report…") {
                        if let url = chooseJSON() { model.importUIAutomationEvidence(url) }
                    }
                    .accessibilityIdentifier("completion.ui.import")
                }
                if let report = model.releaseCompletion.uiAutomation.first {
                    checkRow(report.passed, "Latest UI run", "\(report.checks.count) checks • \(report.appVersion ?? "unknown version")")
                    ForEach(report.checks) { check in checkRow(check.passed, check.id, check.evidence) }
                } else {
                    Text("No real UI report has been imported.").font(.caption).foregroundStyle(.orange)
                }
            }.padding(.top, 6)
        }
    }

    private var faultRecovery: some View {
        GroupBox("6. Fault cleanup and health verification") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Cleanup sends an explicit clear request, queries guest fault status, and passes only when the active-fault list is empty.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear & Verify Selected VM") { Task { await model.recoverLatestFaults() } }
                        .disabled(model.isBusy("fault-recovery"))
                        .accessibilityIdentifier("completion.fault.clear")
                }
                if let receipt = model.releaseCompletion.faultRecoveries.first {
                    checkRow(receipt.recovered, receipt.deviceName, receipt.message)
                } else {
                    Text("No fault-recovery receipt exists.").font(.caption).foregroundStyle(.orange)
                }
            }.padding(.top, 6)
        }
    }

    private var fleet: some View {
        GroupBox("7. Fleet coordinator authorization and two-Mac exercise") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(fleetPolicy.principals) { principal in
                    HStack {
                        StatusPill(text: principal.role.rawValue.uppercased(), color: principal.enabled ? .blue : .secondary)
                        Text(principal.subject).font(.body.monospaced())
                        Text(principal.certificateSHA256.map { String($0.prefix(12)) + "…" } ?? "certificate pin missing")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Remove") { fleetPolicy.principals.removeAll { $0.id == principal.id } }
                    }
                }
                HStack {
                    TextField("Subject", text: $principalSubject)
                    Picker("Role", selection: $principalRole) {
                        ForEach(FleetRole.allCases) { Text($0.rawValue.capitalized).tag($0) }
                    }.frame(width: 180)
                    TextField("Client certificate SHA-256", text: $principalPin)
                    Button("Add") { addPrincipal() }
                        .disabled(principalSubject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                HStack {
                    Button("Save RBAC Policy") { model.updateFleetAccessPolicy(fleetPolicy) }
                        .accessibilityIdentifier("completion.fleet.policy")
                    Button("Import Two-Mac Exercise…") {
                        if let url = chooseJSON() { model.importFleetQualificationExercise(url) }
                    }
                    Spacer()
                    Text("Packaged server: `vdl-fleetd --help`").font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                ForEach(FleetAuthorizationEvaluator.evaluate(fleetPolicy)) { check in
                    checkRow(check.passed, check.id, check.evidence)
                }
                if let exercise = model.releaseCompletion.fleetExercises.first {
                    checkRow(exercise.passed, "Latest exercise", "\(Set(exercise.agentHostIDs + [exercise.controllerHostID]).count) distinct hosts • mTLS and audit verified")
                }
            }.padding(.top, 6)
        }
    }

    private var reliability: some View {
        GroupBox("8. Reliability and interruption campaign") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Required: 24-hour soak plus host sleep/restart, volume loss, low disk, guest hang, network loss, and interrupted-update recovery.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Export Campaign Plan…") {
                        if let url = chooseSaveJSON(defaultName: "v1-reliability-plan.json") {
                            model.exportReliabilityCampaignPlan(to: url)
                        }
                    }
                    Button("Import Campaign Evidence…") {
                        if let url = chooseJSON() { model.importReliabilityCampaign(url) }
                    }
                }
                if let campaign = model.releaseCompletion.reliabilityCampaigns.first {
                    checkRow(campaign.passed, "Latest reliability campaign", String(format: "%.2f soak hours • %d scenario results", campaign.soakHours, campaign.scenarios.count))
                } else {
                    Text("No passing reliability campaign has been imported.").font(.caption).foregroundStyle(.orange)
                }
            }.padding(.top, 6)
        }
    }

    private var quality: some View {
        GroupBox("9. Coverage ratchet and test tiers") {
            VStack(alignment: .leading, spacing: 8) {
                let policy = model.releaseCompletion.coverageRatchet
                let measured = model.labExpansion.coverageReports.sorted { $0.importedAt > $1.importedAt }.first?.linePercent
                HStack {
                    LabeledContent("Current floor", value: String(format: "%.1f%%", policy.currentOverallFloor))
                    LabeledContent("Next", value: String(format: "%.1f%%", policy.nextOverallFloor))
                    LabeledContent("v1 target", value: String(format: "%.1f%%", policy.releaseOverallTarget))
                    LabeledContent("Measured", value: measured.map { String(format: "%.2f%%", $0) } ?? "Not imported")
                    Spacer()
                    Button("Advance Ratchet") { model.advanceCoverageRatchet() }
                }
                ForEach(CoverageRatchet.evaluate(policy: policy, coverage: model.labExpansion.coverageReports.sorted { $0.importedAt > $1.importedAt }.first, uiEvidence: model.releaseCompletion.uiAutomation.first)) { check in
                    checkRow(check.passed, check.id, check.evidence)
                }
            }.padding(.top, 6)
        }
    }

    private var releaseExit: some View {
        GroupBox("10. Release exit checklist") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(model.releaseCompletion.report.summary)
                        .font(.headline)
                    Spacer()
                    Button("Evaluate") { model.refreshReleaseCompletionAssessment() }
                        .accessibilityIdentifier("completion.evaluate")
                    Button("Export Report…") {
                        if let url = chooseSaveJSON(defaultName: "v1-completion-report.json") {
                            model.exportReleaseCompletionReport(to: url)
                        }
                    }
                }
                ForEach(model.releaseCompletion.report.gates) { gate in
                    completionRow(gate)
                }
                Text("Face ID, cellular/baseband, Secure Enclave equivalence, App Store/iCloud support, and unavailable GPU/FPS telemetry remain documented non-goals unless a backend provides real evidence.")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(.top, 6)
        }
    }

    private var contractColor: Color {
        switch model.releaseCompletion.supportContract.status {
        case .draft: .orange
        case .candidate: .blue
        case .approved: .green
        }
    }

    private func loadDrafts() {
        contract = model.releaseCompletion.supportContract
        iosVersions = contract.supportedIOSVersions.joined(separator: ", ")
        profileIDs = contract.hardwareProfileIDs.joined(separator: ", ")
        fleetPolicy = model.releaseCompletion.fleetAccessPolicy
    }

    private func saveContract() {
        contract.supportedIOSVersions = csv(iosVersions)
        contract.hardwareProfileIDs = csv(profileIDs)
        model.updateSupportContract(contract)
        contract = model.releaseCompletion.supportContract
    }

    private func addPrincipal() {
        let subject = principalSubject.trimmingCharacters(in: .whitespacesAndNewlines)
        let pin = principalPin.trimmingCharacters(in: .whitespacesAndNewlines)
        fleetPolicy.principals.removeAll { $0.subject == subject }
        fleetPolicy.principals.append(FleetPrincipal(
            id: UUID(), subject: subject, role: principalRole,
            certificateSHA256: pin.isEmpty ? nil : pin.lowercased(), enabled: true
        ))
        principalSubject = ""
        principalPin = ""
    }

    private func csv(_ value: String) -> [String] {
        value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    @ViewBuilder
    private func checkRow(_ passed: Bool, _ title: String, _ evidence: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: passed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(passed ? .green : .orange)
            Text(title).fontWeight(.medium)
            Spacer()
            Text(evidence).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
    }

    @ViewBuilder
    private func completionRow(_ gate: CompletionGate) -> some View {
        HStack(alignment: .top) {
            Image(systemName: gate.passed ? "checkmark.seal.fill" : gate.state == .ready ? "hourglass.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(gate.passed ? .green : gate.state == .ready ? .blue : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(gate.title).fontWeight(.medium)
                Text(gate.evidence).font(.caption).foregroundStyle(.secondary)
                if !gate.passed { Text(gate.requiredAction).font(.caption2).foregroundStyle(.orange) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chooseDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func chooseJSON() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.json]
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func chooseSaveJSON(defaultName: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = defaultName
        return panel.runModal() == .OK ? panel.url : nil
    }
}
