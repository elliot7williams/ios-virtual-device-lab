import AppKit
import SwiftUI

struct ProductionReadinessView: View {
    @EnvironmentObject private var model: LabAppModel
    @EnvironmentObject private var launchHealth: LaunchHealthMonitor
    @State private var trustPolicy = GuestTrustPolicy.strict
    @State private var backupPolicy = LabBackupPolicy.standard
    @State private var updatePolicy = UpdateLifecyclePolicy.standard
    @State private var reviewer = NSFullUserName()
    @State private var remoteJobID = ""
    @State private var revokePreviousAgentKey = false
    @State private var backupPassphrase = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                qualification
                setup
                guestTrustAndAutomation
                evidence
                backup
                remoteAgent
                updates
                supplyChain
                resilience
            }
            .padding(20)
            .frame(maxWidth: 1_100, alignment: .leading)
        }
        .onAppear {
            trustPolicy = model.guestTrustPolicy
            backupPolicy = model.backupPolicy
            updatePolicy = model.updateLifecyclePolicy
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Production Readiness").font(.title2.weight(.semibold))
                Text("Qualification, secure guest control, evidence review, recovery, updates, supply chain, and fault tolerance.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            StatusPill(
                text: model.acceptanceReport.isPassed && model.evidenceVerificationIssues.isEmpty ? "EVIDENCE READY" : "GATED",
                color: model.acceptanceReport.isPassed && model.evidenceVerificationIssues.isEmpty ? .green : .orange
            )
        }
    }

    private var qualification: some View {
        GroupBox("1. Real-VM qualification fixture") {
            VStack(alignment: .leading, spacing: 10) {
                Text("A campaign pins host, backend, firmware checksum, hardware profile, and the complete acceptance report.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    LabeledContent("Acceptance", value: model.acceptanceReport.isPassed ? "Passed" : "Incomplete")
                    Spacer()
                    Button("Record Qualification Campaign") { model.createQualificationCampaign() }
                        .accessibilityIdentifier("readiness.record-qualification")
                }
                LabeledContent("Companion", value: model.companionAssessment.compatible ? "Compatible" : "Blocked")
                Text(model.companionAssessment.message)
                    .font(.caption)
                    .foregroundStyle(model.companionAssessment.compatible ? .green : .orange)
                ForEach(model.qualificationCampaigns.prefix(3)) { campaign in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(campaign.deviceName ?? "No device").fontWeight(.medium)
                            Spacer()
                            StatusPill(text: campaign.state.rawValue.uppercased(), color: campaign.state == .passed ? .green : .orange)
                        }
                        Text(campaign.hostFingerprint).font(.caption.monospaced()).foregroundStyle(.secondary)
                        ForEach(campaign.blockers, id: \.self) { Text("• \($0)").font(.caption).foregroundStyle(.orange) }
                    }
                    .padding(8)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                }
            }.padding(.top, 6)
        }
    }

    private var setup: some View {
        GroupBox("2. Setup and repair assistant") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.setupAssistantReport.checks) { check in
                    HStack(alignment: .top) {
                        Image(systemName: check.state == .passed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(check.state == .passed ? .green : .orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(check.title).fontWeight(.medium)
                            Text(check.detail).font(.caption).foregroundStyle(.secondary)
                            if check.state != .passed { Text(check.repairInstruction).font(.caption2).foregroundStyle(.orange) }
                        }
                    }
                }
                HStack {
                    Text("Only filesystem support directories can be repaired in-app. Recovery and security policy remain owner-controlled.")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button("Repair Safe Items") { model.repairSafeSetup() }
                }
            }.padding(.top, 6)
        }
    }

    private var guestTrustAndAutomation: some View {
        GroupBox("3–4. Guest trust and deterministic UI automation") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Trust mode", selection: $trustPolicy.mode) {
                    Text("Require authenticated control").tag(GuestTrustMode.requireAuthenticated)
                    Text("Allow unauthenticated read-only inspection").tag(GuestTrustMode.allowLocalUnauthenticatedReadOnly)
                }
                Toggle("Reject legacy guest protocol", isOn: $trustPolicy.rejectLegacyProtocol)
                Toggle("Require replay protection", isOn: $trustPolicy.requireReplayProtection)
                HStack {
                    Spacer()
                    Button("Save Trust Policy") { model.updateGuestTrustPolicy(trustPolicy) }
                }
                if let device = model.selectedDevice ?? model.devices.first {
                    let handshake = model.guestProtocolHandshakes[device.id]
                    let trust = handshake.map { GuestTrustEvaluator.evaluate($0, policy: trustPolicy) }
                    let automation = UIAutomationReadiness.assess(handshake: handshake)
                    LabeledContent("Guest mutation", value: trust?.trustedForMutation == true ? "Trusted" : "Blocked")
                    LabeledContent("Accessibility automation", value: automation.available ? "Available" : "Gated")
                    Text(automation.reason).font(.caption).foregroundStyle(automation.available ? .green : .orange)
                    HStack {
                        Button("Rotate Credential") { model.rotateGuestCredential(for: device) }
                            .accessibilityIdentifier("readiness.rotate-guest-credential")
                        Button("Revoke Credential", role: .destructive) { model.revokeGuestCredential(for: device) }
                            .accessibilityIdentifier("readiness.revoke-guest-credential")
                    }
                } else {
                    Text("Select and boot a VM to assess its authenticated accessibility contract.")
                        .foregroundStyle(.secondary)
                }
            }.padding(.top, 6)
        }
    }

    private var evidence: some View {
        GroupBox("5. Signed evidence governance") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TextField("Reviewer", text: $reviewer).frame(maxWidth: 320)
                    Spacer()
                    Button("Seal Current Acceptance") { model.sealCurrentAcceptanceEvidence(reviewer: reviewer) }
                        .disabled(
                            reviewer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || !model.acceptanceReport.isPassed
                        )
                        .accessibilityIdentifier("readiness.seal-evidence")
                        .keyboardShortcut("e", modifiers: [.command, .shift])
                }
                if model.evidenceVerificationIssues.isEmpty {
                    Label("Evidence signature chain verifies", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                } else {
                    ForEach(model.evidenceVerificationIssues, id: \.self) { issue in
                        Label(issue, systemImage: "xmark.seal.fill").foregroundStyle(.red)
                    }
                }
                ForEach(model.evidenceSeals.suffix(5).reversed()) { seal in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(seal.subject).fontWeight(.medium)
                            Text("\(seal.payloadSHA256.prefix(16))… • \(seal.createdAt.formatted())")
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        StatusPill(text: seal.reviewState.rawValue.uppercased(), color: seal.reviewState == .approved ? .green : .orange)
                        if seal.reviewState == .pending {
                            Button("Approve") { model.reviewEvidence(seal, approved: true, reviewer: reviewer) }
                            Button("Reject") { model.reviewEvidence(seal, approved: false, reviewer: reviewer) }
                        }
                    }
                }
            }.padding(.top, 6)
        }
    }

    private var backup: some View {
        GroupBox("6. Backup and disaster recovery") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Include virtual-device library", isOn: $backupPolicy.includeVirtualDevices)
                Toggle("Include owned firmware/IPSW files", isOn: $backupPolicy.includeFirmware)
                Toggle("Include snapshots", isOn: $backupPolicy.includeSnapshots)
                Toggle("Include test artifacts", isOn: $backupPolicy.includeTestArtifacts)
                Toggle("Include sanitized diagnostic bundles", isOn: $backupPolicy.includeDiagnosticBundles)
                Toggle("Use incremental hard links when possible", isOn: $backupPolicy.incremental)
                Toggle("Encrypt portable archive", isOn: $backupPolicy.encryptArchive)
                if backupPolicy.encryptArchive {
                    SecureField("Backup passphrase (12+ characters)", text: $backupPassphrase)
                        .textContentType(.newPassword)
                }
                Stepper("Retain \(backupPolicy.maximumBackups) backup(s)", value: $backupPolicy.maximumBackups, in: 1...20)
                HStack {
                    Button("Save Policy") { model.updateBackupPolicy(backupPolicy) }
                    Spacer()
                    Button("Create Verified Backup…") { chooseBackupDestination() }
                        .accessibilityIdentifier("readiness.create-backup")
                        .keyboardShortcut("b", modifiers: [.command, .shift])
                    Button("Verify Backup…") { chooseBackup(operation: .verify) }
                        .accessibilityIdentifier("readiness.verify-backup")
                    Button("Stage Restore…") { chooseBackup(operation: .restore) }
                        .accessibilityIdentifier("readiness.stage-restore")
                }
                if let verification = model.latestBackupVerification {
                    Label(
                        verification.passed ? "Backup verification passed" : "Backup verification failed: \(verification.issues.joined(separator: ", "))",
                        systemImage: verification.passed ? "checkmark.circle.fill" : "xmark.circle.fill"
                    ).foregroundStyle(verification.passed ? .green : .red)
                }
                if let plan = model.latestRestorePlan {
                    LabeledContent("Restore plan", value: plan.canStage ? "Ready" : "Blocked")
                    LabeledContent("Capacity", value: "\(ByteCountFormatter.string(fromByteCount: plan.requiredBytes, countStyle: .file)) required • \(ByteCountFormatter.string(fromByteCount: plan.availableBytes, countStyle: .file)) available")
                    if !plan.conflicts.isEmpty {
                        Text("Live destinations with content: \(plan.conflicts.joined(separator: ", "))")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                if let command = model.latestRestoreCommand {
                    LabeledContent("Apply command", value: command.path)
                    Text("Quit the app, then explicitly open this command. It moves live destinations to a timestamped rollback directory before restoring.")
                        .font(.caption2).foregroundStyle(.orange)
                }
                Text("Restore always verifies into an isolated staging directory. It never overwrites live state automatically.")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(.top, 6)
        }
    }

    private var remoteAgent: some View {
        GroupBox("7. Remote agent v2") {
            VStack(alignment: .leading, spacing: 8) {
                if let agent = model.remoteAgentConfiguration {
                    LabeledContent("Agent identity", value: agent.agentID.uuidString)
                    LabeledContent("Active key", value: model.remoteAgentHealth?.activeKeyID ?? agent.activeKeyID ?? "Legacy key")
                    LabeledContent("Queue", value: agent.queuePath)
                    if let health = model.remoteAgentHealth {
                        LabeledContent("Health", value: health.healthy ? "Healthy" : "Action required")
                        LabeledContent("Jobs", value: "\(health.queued) queued • \(health.running) running • \(health.cancelled) cancelled")
                        LabeledContent("Replay ledger", value: "\(health.replayLedgerEntries) nonce(s)")
                    }
                    HStack {
                        Button("Refresh Health") { Task { await model.refreshRemoteAgentHealth() } }
                        Toggle("Revoke previous key", isOn: $revokePreviousAgentKey)
                        Button("Rotate Key") { Task { await model.rotateRemoteAgentKey(revokePrevious: revokePreviousAgentKey) } }
                        Button("Clean 30+ Day Artifacts") { Task { await model.cleanupRemoteAgentQueue() } }
                    }
                    HStack {
                        TextField("Job UUID to cancel", text: $remoteJobID)
                        Button("Cancel Queued Job") { Task { await model.cancelRemoteAgentJob(remoteJobID) } }
                            .disabled(UUID(uuidString: remoteJobID.trimmingCharacters(in: .whitespacesAndNewlines)) == nil)
                    }
                    Text("The v2 CLI adds key IDs, replay ledger, cancellation, rotation, cleanup, and health reporting. It remains a local queue without a listener.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Initialize the authenticated queue in Lab Operations, then use vdlctl agent-health and agent-key-rotate.")
                        .foregroundStyle(.secondary)
                }
            }.padding(.top, 6)
        }
    }

    private var updates: some View {
        GroupBox("8. Staged updates and rollback") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Channel", selection: $updatePolicy.channel) {
                    ForEach(UpdateChannel.allCases) { Text($0.rawValue.capitalized).tag($0) }
                }
                Toggle("Require signed update manifest", isOn: $updatePolicy.requireSignedManifest)
                Toggle("Require notarization", isOn: $updatePolicy.requireNotarization)
                Stepper("Retain \(updatePolicy.retainRollbackVersions) rollback version(s)", value: $updatePolicy.retainRollbackVersions, in: 1...10)
                HStack {
                    Button("Save Policy") { model.updateUpdateLifecyclePolicy(updatePolicy) }
                    Spacer()
                    Button("Stage Downloaded Update") { model.stageDownloadedUpdate() }
                        .disabled({ if case .downloaded = model.updateState { false } else { true } }())
                }
                if let staged = model.stagedUpdate {
                    LabeledContent("Staged version", value: staged.version)
                    LabeledContent("Rollback copy", value: staged.rollbackAppPath ?? "Unavailable")
                    LabeledContent("Installer", value: staged.installerScriptPath ?? "Unavailable")
                    LabeledContent("Rollback command", value: staged.rollbackScriptPath ?? "Unavailable")
                    Text("The generated installer and rollback commands require explicit user launch; staging never replaces the running app.")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }.padding(.top, 6)
        }
    }

    private var supplyChain: some View {
        GroupBox("9. Software supply chain") {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Packaged manifest", value: model.supplyChainAssessment.available ? "Present" : "Unavailable in development run")
                LabeledContent("Verification", value: model.supplyChainAssessment.passed ? "Passed" : "Not verified")
                LabeledContent("Source revision", value: model.supplyChainAssessment.sourceRevision ?? "Unknown")
                ForEach(model.supplyChainAssessment.issues, id: \.self) { issue in
                    Label(issue, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
                Text("Release packaging emits a CycloneDX SBOM, source provenance, and hashes for security-critical bundled files.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.top, 6)
        }
    }

    private var resilience: some View {
        GroupBox("10. Fault injection and resilience") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Runs non-destructive synthetic failures in temporary storage.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Run Resilience Suite") { model.runResilienceSuite() }
                        .accessibilityIdentifier("readiness.run-resilience")
                        .keyboardShortcut("f", modifiers: [.command, .shift])
                }
                if let report = model.resilienceReport {
                    ForEach(report.results) { result in
                        HStack {
                            Image(systemName: result.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(result.passed ? .green : .red)
                            Text(result.scenario.rawValue).font(.callout.monospaced())
                            Spacer()
                            Text(result.evidence).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Divider()
                LabeledContent("Launch health", value: launchHealth.record.safeMode ? "Safe mode" : "Normal")
                LabeledContent("Unclean launches", value: String(launchHealth.record.consecutiveUncleanLaunches))
                if launchHealth.record.safeMode {
                    Button("Exit Safe Mode") { launchHealth.disableSafeMode() }
                }
            }.padding(.top, 6)
        }
    }

    private enum BackupOperation { case verify, restore }

    private func chooseBackupDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Back Up"
        if panel.runModal() == .OK, let url = panel.url {
            model.createLabBackup(
                destination: url,
                passphrase: backupPolicy.encryptArchive ? backupPassphrase : nil
            )
        }
    }

    private func chooseBackup(operation: BackupOperation) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = operation == .verify ? "Verify" : "Stage Restore"
        if panel.runModal() == .OK, let url = panel.url {
            switch operation {
            case .verify: model.verifyLabBackup(url, passphrase: backupPassphrase.nilIfEmpty)
            case .restore: model.stageLabRestore(url, passphrase: backupPassphrase.nilIfEmpty)
            }
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
