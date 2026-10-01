import AppKit
import SwiftUI

struct LabContinuityView: View {
    @EnvironmentObject private var model: LabAppModel
    @State private var fixtureName = "Golden Baseline"
    @State private var evidencePolicy = EvidenceLifecyclePolicy.standard
    @State private var retentionPolicy = UnifiedRetentionPolicy.standard
    @State private var objectivePolicy = OperationalObjectivePolicy.standard
    @State private var betaVerification = BetaVerificationRecord.empty
    @State private var confirmQuarantine = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                storage
                recovery
                fixture
                labfile
                evidenceLifecycle
                hostCapacity
                hostileInputs
                retention
                objectives
                beta
            }
            .padding(20)
            .frame(maxWidth: 1_120, alignment: .leading)
        }
        .onAppear {
            evidencePolicy = model.evidenceLifecyclePolicy
            retentionPolicy = model.unifiedRetentionPolicy
            objectivePolicy = model.operationalObjectivePolicy
            betaVerification = model.betaVerification
            model.refreshContinuityAssessments()
        }
        .confirmationDialog(
            "Move expired artifacts to Recovery Bin?",
            isPresented: $confirmQuarantine,
            titleVisibility: .visible
        ) {
            Button("Move to Recovery Bin") { model.quarantineExpiredArtifacts() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This moves only the previewed artifacts. Firmware, VM disks, credentials, and signed evidence are excluded.")
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Continuity & Public Beta").font(.title2.weight(.semibold))
                Text("Storage recovery, declarative fixtures, evidence freshness, capacity, security boundaries, retention, SLOs, and beta quality.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Refresh", systemImage: "arrow.clockwise") { model.refreshContinuityAssessments() }
                .accessibilityIdentifier("continuity.refresh")
        }
    }

    private var storage: some View {
        GroupBox("1. External-storage lifecycle") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    StatusPill(
                        text: model.storageLocationStatus.state.rawValue.uppercased(),
                        color: model.storageLocationStatus.state == .online ? .green : .orange
                    )
                    Text(model.storageLocationStatus.message).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Relink…") { chooseStorageRoot() }
                        .disabled(model.devices.contains(where: \.isRunning))
                        .accessibilityIdentifier("continuity.storage-relink")
                }
                LabeledContent("Configured", value: model.storageLocationStatus.configuredPath)
                LabeledContent("Resolved", value: model.storageLocationStatus.resolvedPath ?? "Unavailable")
                LabeledContent(
                    "Volume identity",
                    value: [model.storageLocationStatus.volumeName, model.storageLocationStatus.volumeUUID]
                        .compactMap { $0 }.joined(separator: " • ").nilIfEmpty ?? "Unavailable"
                )
                Text("Relinking atomically replaces only the ~/.vphone symlink. A real directory requires a separately verified migration and is never overwritten in-app.")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(.top, 6)
        }
    }

    private var recovery: some View {
        GroupBox("2. Crash Recovery Center") {
            VStack(alignment: .leading, spacing: 8) {
                if model.recoveryCenter.unresolvedEntries.isEmpty {
                    Label("No interrupted or failed transactions need a decision", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    ForEach(model.recoveryCenter.unresolvedEntries) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("\(entry.kind.rawValue.capitalized): \(entry.target)").fontWeight(.medium)
                                Spacer()
                                Button("Resume / Retry") { model.decideRecovery(entry, action: .resume) }
                                Button("Roll Back") { model.decideRecovery(entry, action: .rollback) }
                                Button("Abandon", role: .destructive) { model.decideRecovery(entry, action: .abandon) }
                            }
                            Text(entry.message).font(.caption).foregroundStyle(.secondary)
                            Text(entry.recoveryInstruction).font(.caption2).foregroundStyle(.orange)
                        }
                        .padding(8)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                if let latest = model.recoveryCenter.decisions.first {
                    Divider()
                    Text("Latest decision: \(latest.action.rawValue) • \(latest.target) • \(latest.decidedAt.formatted())")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.top, 6)
        }
    }

    private var fixture: some View {
        GroupBox("3. Canonical real-VM fixture") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("Fixture name", text: $fixtureName)
                    Button("Record Golden Fixture") { model.recordCanonicalFixture(name: fixtureName) }
                        .disabled(!model.canonicalFixtureAssessment.ready)
                        .accessibilityIdentifier("continuity.fixture-record")
                }
                ForEach(model.canonicalFixtureAssessment.blockers, id: \.self) { blocker in
                    Label(blocker, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                ForEach(model.canonicalFixtures.prefix(3)) { fixture in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(fixture.name).fontWeight(.medium)
                        Text("\(fixture.deviceProductType) • \(fixture.hardwareProfileID) • \(fixture.firmwareSHA256.prefix(16))…")
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                Text("Fixtures contain identities and hashes only; Apple firmware, VM disks, credentials, and signing material are never copied into the manifest.")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(.top, 6)
        }
    }

    private var labfile: some View {
        GroupBox("4. Declarative Labfile") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    LabeledContent("Loaded", value: model.activeLabfile?.name ?? "None")
                    Spacer()
                    Button("Export Current…") { exportLabfile() }
                    Button("Import & Plan…") { importLabfile() }
                    Button("Apply") { Task { await model.applyActiveLabfile() } }
                        .disabled(model.activeLabfile == nil || !model.labfilePlan.canApply)
                        .accessibilityIdentifier("continuity.labfile-apply")
                }
                ForEach(model.labfilePlan.blockers, id: \.self) { blocker in
                    Label(blocker, systemImage: "nosign").font(.caption).foregroundStyle(.red)
                }
                ForEach(model.labfilePlan.changes) { change in
                    HStack {
                        StatusPill(text: change.kind.rawValue.uppercased(), color: change.kind == .blocked ? .red : (change.kind == .unchanged ? .green : .orange))
                        Text(change.deviceName).fontWeight(.medium)
                        Text(change.summary).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("Plan and diff are side-effect free. Apply creates missing devices only from locally imported, hash-pinned firmware and updates stopped devices sequentially.")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(.top, 6)
        }
    }

    private var evidenceLifecycle: some View {
        GroupBox("5. Evidence expiry and recertification") {
            VStack(alignment: .leading, spacing: 8) {
                Stepper("Maximum age: \(evidencePolicy.maximumAgeDays) days", value: $evidencePolicy.maximumAgeDays, in: 1...365)
                HStack {
                    Toggle("Host changes", isOn: $evidencePolicy.invalidateOnHostChange)
                    Toggle("Backend changes", isOn: $evidencePolicy.invalidateOnBackendChange)
                    Toggle("Firmware changes", isOn: $evidencePolicy.invalidateOnFirmwareChange)
                    Toggle("Approved seal", isOn: $evidencePolicy.requireApprovedSeal)
                    Spacer()
                    Button("Save") { model.updateEvidenceLifecyclePolicy(evidencePolicy) }
                }
                LabeledContent(
                    "Fresh campaigns",
                    value: "\(model.evidenceFreshnessReport.freshCount)/\(model.evidenceFreshnessReport.items.count)"
                )
                ForEach(model.evidenceFreshnessReport.items.filter { !$0.fresh }) { item in
                    Text(item.reasons.joined(separator: " • ")).font(.caption).foregroundStyle(.orange)
                }
            }.padding(.top, 6)
        }
    }

    private var hostCapacity: some View {
        GroupBox("6. Host-capacity calibration") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    StatusPill(text: model.hostCapacityCalibration.capacityClass.rawValue.uppercased(), color: model.hostCapacityCalibration.capacityClass == .constrained ? .orange : .green)
                    Spacer()
                    Button("Calibrate") { Task { await model.calibrateHostCapacity() } }
                        .accessibilityIdentifier("continuity.capacity-calibrate")
                    Button("Apply Recommendation") { Task { await model.applyCapacityRecommendation() } }
                        .disabled(model.hostCapacityCalibration.measuredAt == .distantPast)
                }
                LabeledContent("Host", value: "\(model.hostCapacityCalibration.physicalMemoryMB) MB • \(model.hostCapacityCalibration.activeProcessorCount) logical CPUs")
                LabeledContent("Recommended", value: "\(model.hostCapacityCalibration.recommendedConcurrentVMs) VM(s) • \(model.hostCapacityCalibration.recommendedAggregateMemoryMB) MB aggregate")
                if let speed = model.hostCapacityCalibration.diskWriteMBPerSecond {
                    LabeledContent("Probe throughput", value: String(format: "%.1f MB/s", speed))
                }
                ForEach(model.hostCapacityCalibration.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
            }.padding(.top, 6)
        }
    }

    private var hostileInputs: some View {
        GroupBox("7. Hostile-input boundary suite") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Exercises malformed and oversized JSON, archive traversal, absolute paths, and symlink escapes in temporary storage.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Run Security Suite") { Task { await model.runHostileInputSuite() } }
                        .accessibilityIdentifier("continuity.hostile-inputs")
                }
                ForEach(model.hostileInputReport.results) { result in
                    HStack {
                        Image(systemName: result.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(result.passed ? .green : .red)
                        Text(result.name).fontWeight(.medium)
                        Spacer()
                        Text(result.evidence).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.padding(.top, 6)
        }
    }

    private var retention: some View {
        GroupBox("8. Unified data lifecycle") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Stepper("Diagnostics \(retentionPolicy.diagnosticDays)d", value: $retentionPolicy.diagnosticDays, in: 1...365)
                    Stepper("Screenshots \(retentionPolicy.screenshotDays)d", value: $retentionPolicy.screenshotDays, in: 1...365)
                    Stepper("Tests \(retentionPolicy.testArtifactDays)d", value: $retentionPolicy.testArtifactDays, in: 1...365)
                }
                HStack {
                    Toggle("Preserve signed evidence", isOn: $retentionPolicy.preserveSignedEvidence)
                    Toggle("Telemetry", isOn: $retentionPolicy.telemetryEnabled)
                    Spacer()
                    Button("Save & Preview") { model.updateUnifiedRetentionPolicy(retentionPolicy) }
                    Button("Quarantine \(model.retentionPreview.candidates.count)…") { confirmQuarantine = true }
                        .disabled(model.retentionPreview.candidates.isEmpty)
                }
                Text("Preview: \(ByteCountFormatter.string(fromByteCount: model.retentionPreview.totalBytes, countStyle: .file)) across \(model.retentionPreview.candidates.count) artifact(s). Telemetry is off by default.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Expired artifacts move to a recoverable Recovery Bin. APFS does not provide reliable overwrite-based secure deletion; encrypted-export key destruction is the only cryptographic erasure claim.")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(.top, 6)
        }
    }

    private var objectives: some View {
        GroupBox("9. Operational objectives and recovery gates") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Stepper("Success \(Int(objectivePolicy.minimumRunSuccessPercent))%", value: $objectivePolicy.minimumRunSuccessPercent, in: 50...100)
                    Stepper("P95 \(Int(objectivePolicy.maximumP95DurationSeconds))s", value: $objectivePolicy.maximumP95DurationSeconds, in: 60...3_600, step: 60)
                    Stepper("Soak \(Int(objectivePolicy.minimumSoakHours))h", value: $objectivePolicy.minimumSoakHours, in: 1...168)
                    Spacer()
                    Button("Save") { model.updateOperationalObjectivePolicy(objectivePolicy) }
                }
                HStack {
                    Stepper("RTO \(objectivePolicy.recoveryTimeObjectiveMinutes)m", value: $objectivePolicy.recoveryTimeObjectiveMinutes, in: 5...1_440, step: 5)
                    Stepper("RPO \(objectivePolicy.recoveryPointObjectiveHours)h", value: $objectivePolicy.recoveryPointObjectiveHours, in: 1...168)
                    Toggle("Require second-volume restore", isOn: $objectivePolicy.requireSecondVolumeRestore)
                }
                ForEach(model.operationalObjectiveReport.gates) { gate in
                    HStack {
                        Image(systemName: gate.passed ? "checkmark.circle.fill" : "clock.badge.exclamationmark.fill")
                            .foregroundStyle(gate.passed ? .green : .orange)
                        Text(gate.name).fontWeight(.medium)
                        Spacer()
                        Text("\(gate.measured) • required \(gate.required)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.padding(.top, 6)
        }
    }

    private var beta: some View {
        GroupBox("10. Public-beta readiness") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Toggle("VoiceOver", isOn: $betaVerification.voiceOverVerified)
                    Toggle("Keyboard", isOn: $betaVerification.keyboardNavigationVerified)
                    Toggle("Reduced motion", isOn: $betaVerification.reducedMotionVerified)
                    Toggle("Onboarding", isOn: $betaVerification.onboardingReviewed)
                }
                HStack {
                    Toggle("Support policy", isOn: $betaVerification.supportPolicyReviewed)
                    Toggle("Apple asset policy", isOn: $betaVerification.appleAssetPolicyReviewed)
                    Toggle("Second-volume restore", isOn: $betaVerification.secondVolumeRestoreRecorded)
                }
                HStack {
                    TextField("Legal review reference", text: $betaVerification.legalReviewReference)
                    Button("Save Verification") { model.updateBetaVerification(betaVerification) }
                    Button("Export Safe Support Report") { model.exportSupportReport() }
                }
                ForEach(model.publicBetaReadiness.items) { item in
                    HStack {
                        Image(systemName: item.passed ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(item.passed ? .green : .secondary)
                        Text(item.name)
                        Spacer()
                        Text(item.evidence).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("Verification toggles are evidence checklists, not automatic claims. Legal review and real assistive-technology passes remain explicit human gates.")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(.top, 6)
        }
    }

    private func chooseStorageRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Relink"
        if panel.runModal() == .OK, let url = panel.url {
            Task { await model.relinkExternalStorage(to: url) }
        }
    }

    private func exportLabfile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Labfile.json"
        if panel.runModal() == .OK, let url = panel.url { model.exportCurrentLabfile(to: url) }
    }

    private func importLabfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { model.importLabfile(url) }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
