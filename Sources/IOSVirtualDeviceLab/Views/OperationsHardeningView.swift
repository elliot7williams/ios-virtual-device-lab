import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct OperationsHardeningView: View {
    @EnvironmentObject private var model: LabAppModel
    @State private var selectedInstallationID = ""
    @State private var auditLedger: URL?
    @State private var auditCertificate: URL?
    @State private var managerArtifact: URL?
    @State private var backendArtifact: URL?
    @State private var guestArtifact: URL?
    @State private var managerVersion = BackendAdapterConformance.labVersion
    @State private var backendVersion = "0.8.0"
    @State private var guestVersion = "3.0.0"
    @State private var lifecycle = SupportLifecyclePolicy.standard

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                hostSetup
                permissions
                fleetProtocol
                audit
                invalidation
                encryption
                reconciliation
                componentUpgrade
                supplyChain
                supportLifecycle
                report
            }
            .padding(22)
        }
        .navigationTitle("v1.1 Hardening")
        .onAppear {
            lifecycle = model.operationsHardening.lifecyclePolicy
            Task { await model.discoverHostInstallations() }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Operations & Hardening").font(.title2.weight(.semibold))
                Text("Ten fail-closed controls for safely operating, updating, auditing, and supporting the virtual-device lab.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            StatusPill(
                text: model.operationsHardening.report.releaseReady ? "V1.1 READY" : "V1.1 HOLD",
                color: model.operationsHardening.report.releaseReady ? .green : .orange
            )
            Button("Inspect All") { Task { await model.refreshOperationsHardening() } }
                .accessibilityIdentifier("hardening.inspect")
                .disabled(model.isBusy("operations-inspection"))
        }
    }

    private var hostSetup: some View {
        GroupBox("1. Guided host setup and reboot continuation") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker("macOS installation", selection: $selectedInstallationID) {
                        Text("Choose exact System volume").tag("")
                        ForEach(model.macOSInstallations) { volume in
                            Text("\(volume.name) • \(volume.volumeUUID.prefix(8))").tag(volume.volumeUUID)
                        }
                    }
                    Button("Rediscover") { Task { await model.discoverHostInstallations() } }
                        .disabled(model.isBusy("operations-host-discovery"))
                    Button("Prepare Continuation") {
                        if let target = model.macOSInstallations.first(where: { $0.volumeUUID == selectedInstallationID }) {
                            model.beginHostSetup(for: target)
                        }
                    }.disabled(selectedInstallationID.isEmpty)
                }
                LabeledContent("Phase", value: model.operationsHardening.hostSetup.phase.rawValue)
                Text(model.operationsHardening.hostSetup.note).font(.caption).foregroundStyle(.secondary)
                if let command = model.operationsHardening.hostSetup.recoveryCommand {
                    HStack {
                        Text(command).font(.caption.monospaced()).textSelection(.enabled)
                        Spacer()
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(command, forType: .string)
                        }
                    }
                }
                HStack {
                    Button("I Completed the Recovery Step") { model.acknowledgeRecoveryStep() }
                        .disabled(model.operationsHardening.hostSetup.phase != .recoveryRequired)
                    Button("Verify After Restart") { model.verifyHostSetup() }
                        .disabled(![.restartRequired, .verificationRequired].contains(model.operationsHardening.hostSetup.phase))
                }
                Text("The app never runs Recovery commands or changes SIP automatically. The selected volume UUID and boot session are persisted so setup resumes after restart.")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(.top, 6)
        }
    }

    private var permissions: some View {
        GroupBox("2. Permission onboarding") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.operationsHardening.permissions.checks) { check in
                    HStack(alignment: .firstTextBaseline) {
                        gateIcon(check.passed)
                        VStack(alignment: .leading) {
                            Text(check.kind.title).fontWeight(.medium)
                            Text(check.rationale).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if check.required { Text("Required").font(.caption2).foregroundStyle(.orange) }
                        if check.settingsURL != nil { Button("Open Settings") { model.openPermissionSettings(check) } }
                    }
                }
                Button("Inspect Permissions Again") { Task { await model.refreshOperationsHardening() } }
            }.padding(.top, 6)
        }
    }

    private var fleetProtocol: some View {
        GroupBox("3. Complete fleet worker protocol") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Enrollment, heartbeat, submission, claim, progress, result, query, and cancellation are versioned and protected by mTLS/RBAC in `vdl-fleetd`.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Import Two-Host Protocol Evidence…") {
                        if let url = chooseFile(types: [.json]) { model.importFleetWorkerEvidence(url) }
                    }
                    Spacer()
                    Text("Server \(model.operationsHardening.fleetProtocol.serverVersion)")
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                let issues = FleetWorkerProtocolEvaluator.validate(model.operationsHardening.fleetProtocol)
                checkRow(issues.isEmpty, "Protocol qualification", issues.isEmpty ? "All eight lifecycle operations and retry boundaries passed." : issues.joined(separator: " "))
            }.padding(.top, 6)
        }
    }

    private var audit: some View {
        GroupBox("4. Tamper-evident fleet auditing") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button(auditLedger?.lastPathComponent ?? "Choose audit.jsonl…") {
                        auditLedger = chooseFile(types: [.plainText, .json])
                    }
                    Button(auditCertificate?.lastPathComponent ?? "Choose signing certificate…") {
                        auditCertificate = chooseFile(types: [.data])
                    }
                    Spacer()
                    Button("Verify Chain & Signatures") {
                        if let ledger = auditLedger, let certificate = auditCertificate {
                            model.verifyFleetAudit(ledger: ledger, certificate: certificate)
                        }
                    }.disabled(auditLedger == nil || auditCertificate == nil)
                }
                checkRow(
                    model.operationsHardening.fleetAudit.passed,
                    "Signed append-only ledger",
                    model.operationsHardening.fleetAudit.passed
                        ? "\(model.operationsHardening.fleetAudit.recordCount) records verified."
                        : model.operationsHardening.fleetAudit.issues.joined(separator: " ")
                )
            }.padding(.top, 6)
        }
    }

    private var invalidation: some View {
        GroupBox("5. Transitive evidence invalidation") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button("Capture Current Baseline") { model.captureEvidenceDependencyBaseline() }
                    Button("Mark Evidence Replaced") { model.acknowledgeEvidenceReplacement() }
                        .disabled(model.operationsHardening.evidenceInvalidations.allSatisfy(\.resolved))
                    Spacer()
                    Text(model.operationsHardening.evidenceBaseline == nil ? "No baseline" : "Baseline captured")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(model.operationsHardening.evidenceInvalidations.prefix(10)) { record in
                    checkRow(
                        record.resolved,
                        record.changedRoots.map(\.rawValue).joined(separator: ", "),
                        "Invalidates: \(record.invalidatedEvidence.map(\.rawValue).joined(separator: ", "))"
                    )
                }
                Text("Changing a backend, guest companion, hardware profile, compatibility manifest, app build, host policy, or supply manifest recursively stales dependent acceptance and release evidence.")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(.top, 6)
        }
    }

    private var encryption: some View {
        GroupBox("6. Live-storage encryption") {
            VStack(alignment: .leading, spacing: 8) {
                checkRow(
                    model.operationsHardening.storageEncryption.passed,
                    model.operationsHardening.storageEncryption.volumeName ?? model.paths.dataRoot.lastPathComponent,
                    model.operationsHardening.storageEncryption.evidence
                )
                HStack {
                    LabeledContent("State", value: model.operationsHardening.storageEncryption.state.rawValue)
                    LabeledContent("Filesystem", value: model.operationsHardening.storageEncryption.fileSystem ?? "unknown")
                    LabeledContent("Writable", value: model.operationsHardening.storageEncryption.readOnly == true ? "no" : "yes")
                    Spacer()
                    Button("Inspect Mounted Volume") { Task { await model.refreshOperationsHardening() } }
                }
            }.padding(.top, 6)
        }
    }

    private var reconciliation: some View {
        GroupBox("7. Startup reconciliation") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Journal, staged update, lease, and stale socket state is checked before new operations.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Repair Safe Findings") { model.repairSafeStartupFindings() }
                    Button("Scan Again") { Task { await model.refreshOperationsHardening() } }
                }
                if model.operationsHardening.reconciliation.findings.isEmpty {
                    checkRow(true, "Reconciled", "No stale or interrupted state was found.")
                }
                ForEach(model.operationsHardening.reconciliation.findings) { finding in
                    checkRow(
                        model.operationsHardening.reconciliation.repairedFindingIDs.contains(finding.id) || finding.severity != .blocking,
                        finding.summary, finding.recoveryAction
                    )
                }
            }.padding(.top, 6)
        }
    }

    private var componentUpgrade: some View {
        GroupBox("8. Atomic component upgrades") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    artifactButton("Manager", selection: $managerArtifact)
                    TextField("Manager version", text: $managerVersion).frame(width: 120)
                    artifactButton("Backend", selection: $backendArtifact)
                    TextField("Backend version", text: $backendVersion).frame(width: 110)
                    artifactButton("Guest", selection: $guestArtifact)
                    TextField("Guest version", text: $guestVersion).frame(width: 100)
                }
                HStack {
                    Button("Stage Set") {
                        var sources: [(component: String, url: URL)] = []
                        if let managerArtifact { sources.append(("manager", managerArtifact)) }
                        if let backendArtifact { sources.append(("backend", backendArtifact)) }
                        if let guestArtifact { sources.append(("guest-companion", guestArtifact)) }
                        model.stageComponentUpgrade(
                            sources: sources, managerVersion: managerVersion,
                            backendVersion: backendVersion, guestVersion: guestVersion
                        )
                    }.disabled(managerArtifact == nil || backendArtifact == nil || guestArtifact == nil)
                    Button("Approve") { model.approveComponentUpgrade() }
                        .disabled(model.operationsHardening.componentUpgrade.phase != .staged)
                    Button("Commit Atomic Manifest") { model.commitComponentUpgrade() }
                        .disabled(model.operationsHardening.componentUpgrade.phase != .approved)
                    Button("Rollback") { model.rollbackComponentUpgrade() }
                        .disabled(model.operationsHardening.componentUpgrade.phase != .committed)
                    Spacer()
                    StatusPill(text: model.operationsHardening.componentUpgrade.phase.rawValue.uppercased(), color: model.operationsHardening.componentUpgrade.phase == .committed ? .green : .orange)
                }
                Text(model.operationsHardening.componentUpgrade.message).font(.caption).foregroundStyle(.secondary)
            }.padding(.top, 6)
        }
    }

    private var supplyChain: some View {
        GroupBox("9. Supply-chain policy enforcement") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    LabeledContent("Severity threshold", value: model.operationsHardening.supplyChainPolicy.maximumAllowedSeverity.rawValue)
                    LabeledContent("Allowed licenses", value: "\(model.operationsHardening.supplyChainPolicy.allowedLicenses.count)")
                    LabeledContent("Denied licenses", value: "\(model.operationsHardening.supplyChainPolicy.deniedLicenses.count)")
                    Spacer()
                    Button("Import SBOM + Scan Evidence…") {
                        if let url = chooseFile(types: [.json]) { model.importSupplyChainPolicyEvidence(url) }
                    }
                }
                checkRow(
                    model.operationsHardening.supplyChainEvidence.passed,
                    "Policy decision",
                    model.operationsHardening.supplyChainEvidence.passed
                        ? "\(model.operationsHardening.supplyChainEvidence.components.count) components passed provenance, license, and vulnerability policy."
                        : model.operationsHardening.supplyChainEvidence.issues.joined(separator: " ")
                )
            }.padding(.top, 6)
        }
    }

    private var supportLifecycle: some View {
        GroupBox("10. Support and deprecation lifecycle") {
            VStack(alignment: .leading, spacing: 8) {
                Stepper("Minimum deprecation notice: \(lifecycle.minimumDeprecationNoticeDays) days", value: $lifecycle.minimumDeprecationNoticeDays, in: 30...730)
                ForEach(lifecycle.entries) { entry in
                    HStack {
                        StatusPill(text: entry.status.rawValue.uppercased(), color: entry.status == .supported ? .green : .orange)
                        Text(entry.component).fontWeight(.medium)
                        Text(entry.versionRange).font(.body.monospaced())
                        Spacer()
                        Text(entry.migrationTarget ?? entry.rationale).font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button("Save & Evaluate Policy") {
                        lifecycle.updatedAt = .now
                        model.updateLifecyclePolicy(lifecycle)
                    }
                    Button("Import Policy…") {
                        if let url = chooseFile(types: [.json]) {
                            model.importLifecyclePolicy(url)
                            lifecycle = model.operationsHardening.lifecyclePolicy
                        }
                    }
                    Button("Export Policy…") {
                        let panel = NSSavePanel()
                        panel.allowedContentTypes = [.json]
                        panel.nameFieldStringValue = "support-lifecycle-policy.json"
                        if panel.runModal() == .OK, let url = panel.url { model.exportLifecyclePolicy(to: url) }
                    }
                    Spacer()
                    checkRow(
                        model.operationsHardening.lifecycleAssessment.passed,
                        "Lifecycle decision",
                        model.operationsHardening.lifecycleAssessment.passed
                            ? "Support declarations and notice windows are valid."
                            : model.operationsHardening.lifecycleAssessment.issues.joined(separator: " ")
                    )
                }
            }.padding(.top, 6)
        }
    }

    private var report: some View {
        GroupBox("v1.1 release decision") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(model.operationsHardening.report.releaseReady ? "All ten operations gates pass." : "Release remains fail-closed until all ten operations gates pass.")
                        .font(.headline)
                    Spacer()
                    Button("Export Report…") {
                        let panel = NSSavePanel()
                        panel.allowedContentTypes = [.json]
                        panel.nameFieldStringValue = "v1.1-operations-hardening-report.json"
                        if panel.runModal() == .OK, let url = panel.url { model.exportOperationsHardeningReport(to: url) }
                    }
                }
                ForEach(model.operationsHardening.report.gates) { gate in
                    checkRow(gate.passed, gate.kind.title, gate.passed ? gate.evidence : "\(gate.evidence) Next: \(gate.requiredAction)")
                }
            }.padding(.top, 6)
        }
    }

    @ViewBuilder
    private func artifactButton(_ title: String, selection: Binding<URL?>) -> some View {
        Button(selection.wrappedValue?.lastPathComponent ?? "Choose \(title)…") {
            selection.wrappedValue = chooseFile(types: [.data, .applicationBundle, .unixExecutable])
        }
    }

    private func gateIcon(_ passed: Bool) -> some View {
        Image(systemName: passed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .foregroundStyle(passed ? .green : .orange)
    }

    private func checkRow(_ passed: Bool, _ title: String, _ evidence: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            gateIcon(passed)
            Text(title).fontWeight(.medium)
            Spacer()
            Text(evidence).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
    }

    private func chooseFile(types: [UTType]) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = types
        return panel.runModal() == .OK ? panel.url : nil
    }
}
