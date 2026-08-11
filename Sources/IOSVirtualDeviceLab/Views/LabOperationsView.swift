import AppKit
import SwiftUI

struct LabOperationsView: View {
    @EnvironmentObject private var model: LabAppModel
    @State private var selectedDeviceID: String?
    @State private var selectedProfileID: UUID?
    @State private var storagePolicy: LabStoragePolicy = .standard
    @State private var proposedMacOSVersion = ""
    @State private var proposedHostAssessment: HostCompatibilityAssessment?

    private var selectedDevice: VirtualDevice? {
        model.devices.first { $0.id == selectedDeviceID }
    }

    private var selectedProfile: EnvironmentProfile? {
        model.environmentProfiles.first { $0.id == selectedProfileID }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                acceptanceSection
                hostSection
                migrationAndJournalSection
                environmentSection
                guestProtocolSection
                storageSection
                pluginAuditSection
                remoteAgentSection
            }
            .padding(20)
        }
        .onAppear {
            selectedDeviceID = selectedDeviceID ?? model.selectedDevice?.id ?? model.devices.first?.id
            selectedProfileID = selectedProfileID ?? model.environmentProfiles.first?.id
            storagePolicy = model.storagePolicy
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Lab Operations").font(.title2.weight(.semibold))
                Text("Acceptance, compatibility, recovery, reproducibility, storage, extension audit, and CI-agent controls.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Refresh", systemImage: "arrow.clockwise") {
                Task { await model.refreshOperationalReadiness() }
            }
            .accessibilityIdentifier("operations.refresh")
        }
    }

    private var acceptanceSection: some View {
        GroupBox("Acceptance definition") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(model.acceptanceReport.isPassed ? "Release evidence complete" : "Real-VM evidence incomplete")
                        .font(.headline)
                    Spacer()
                    StatusPill(
                        text: model.acceptanceReport.isPassed ? "PASSED" : "GATED",
                        color: model.acceptanceReport.isPassed ? .green : .orange
                    )
                }
                ForEach(model.acceptanceReport.gates) { gate in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: gateIcon(gate.status))
                            .foregroundStyle(gateColor(gate.status))
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(gate.kind.title).fontWeight(.medium)
                            Text(gate.evidence).font(.caption).foregroundStyle(.secondary)
                            Text("Required: \(gate.requiredEvidence)").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    private var hostSection: some View {
        GroupBox("Host compatibility and upgrade guard") {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    LabeledContent("Current host", value: "\(model.readiness.model) • macOS \(model.readiness.macOSVersion)")
                    LabeledContent("Evidence", value: model.hostCompatibilityAssessment.message)
                    LabeledContent("Matrix record", value: model.hostCompatibilityAssessment.recordID ?? "No matching record")
                    HStack {
                        TextField("Proposed macOS version", text: $proposedMacOSVersion)
                            .frame(width: 190)
                        Button("Check Upgrade") {
                            proposedHostAssessment = HostCompatibilityDatabase.assessTarget(
                                catalog: model.hostCompatibilityCatalog,
                                macOSVersion: proposedMacOSVersion,
                                model: model.readiness.model,
                                backendVersion: model.backendDescriptor.version,
                                iosVersion: selectedDevice?.restoreInfo?.ios.version
                            )
                        }
                        .disabled(proposedMacOSVersion.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if let proposedHostAssessment {
                        Text("Proposed host: \(proposedHostAssessment.status.rawValue) — \(proposedHostAssessment.message)")
                            .font(.caption)
                            .foregroundStyle(hostColor(proposedHostAssessment.status))
                    }
                }
                Spacer()
                StatusPill(
                    text: model.hostCompatibilityAssessment.status.rawValue.uppercased(),
                    color: hostColor(model.hostCompatibilityAssessment.status)
                )
            }
            .padding(8)
        }
    }

    private var migrationAndJournalSection: some View {
        GroupBox("Data migrations and crash recovery") {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent(
                    "State schema",
                    value: "v\(model.migrationReport.destinationVersion) • \(model.migrationReport.applied.count) migration(s) this launch"
                )
                if let backup = model.migrationReport.latestBackupPath {
                    LabeledContent("Rollback backup", value: backup)
                }
                let unresolved = model.operationJournalEntries.filter { [.interrupted, .failed].contains($0.state) }
                if unresolved.isEmpty {
                    Label("No interrupted operations require review", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    ForEach(unresolved) { entry in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(entry.kind.rawValue.capitalized): \(entry.target)").fontWeight(.medium)
                                Text(entry.recoveryInstruction).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Mark Resolved") { model.resolveJournalEntry(entry) }
                        }
                    }
                }
            }
            .padding(8)
        }
    }

    private var environmentSection: some View {
        GroupBox("Reproducible test environment") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Picker("Device", selection: $selectedDeviceID) {
                        Text("Select a device").tag(String?.none)
                        ForEach(model.devices) { Text($0.name).tag(Optional($0.id)) }
                    }
                    Picker("Profile", selection: $selectedProfileID) {
                        ForEach(model.environmentProfiles) { Text($0.name).tag(Optional($0.id)) }
                    }
                    Button("Assign") {
                        if let selectedDevice, let selectedProfile {
                            Task { await model.applyEnvironmentProfile(selectedProfile, to: selectedDevice) }
                        }
                    }
                    .disabled(selectedDevice == nil || selectedProfile == nil)
                }
                if let profile = selectedProfile {
                    Text("\(profile.localeIdentifier) • \(profile.timeZoneIdentifier) • \(profile.appearance.rawValue) • \(profile.orientation) • latency \(profile.networkCondition.latencyMilliseconds) ms")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Unsupported guest simulations are stored as test intent and require a capability-declaring trusted extension.")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
            .padding(8)
        }
    }

    private var guestProtocolSection: some View {
        GroupBox("Guest-control protocol") {
            HStack(alignment: .top) {
                if let device = selectedDevice {
                    let handshake = model.guestProtocolHandshakes[device.id] ?? .unavailable
                    VStack(alignment: .leading, spacing: 5) {
                        LabeledContent("Status", value: handshake.status.rawValue)
                        LabeledContent("Version", value: handshake.negotiatedVersion.map(String.init) ?? "Unavailable")
                        LabeledContent("Capabilities", value: handshake.capabilities.map(\.rawValue).sorted().joined(separator: ", ").isEmpty ? "None" : handshake.capabilities.map(\.rawValue).sorted().joined(separator: ", "))
                        Text(handshake.message).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Negotiate") { Task { await model.probeGuestProtocol(for: device) } }
                        .disabled(!device.isRunning)
                } else {
                    Text("Select a virtual device to inspect its negotiated guest protocol.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
        }
    }

    private var storageSection: some View {
        GroupBox("Storage lifecycle") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    LabeledContent("Managed", value: bytes(model.storageInventory.totalManagedBytes))
                    Spacer()
                    LabeledContent("Available", value: bytes(model.storageInventory.availableBytes))
                }
                HStack {
                    Toggle("Automatic snapshot pruning", isOn: $storagePolicy.automaticSnapshotPruning)
                    Toggle("Flag duplicate IPSWs", isOn: $storagePolicy.flagDuplicateFirmware)
                    Spacer()
                    Button("Save Policy") { Task { await model.updateStoragePolicy(storagePolicy) } }
                    Button("Export Configuration…") { exportConfiguration() }
                }
                ForEach(model.storageInventory.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                if !model.storageInventory.duplicateFirmware.isEmpty {
                    Text("\(model.storageInventory.duplicateFirmware.count) duplicate firmware checksum group(s) detected; no files are removed automatically.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(8)
        }
    }

    private var pluginAuditSection: some View {
        GroupBox("Extension isolation and audit") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Trusted plugins default to a deny-by-default write/network sandbox, bounded runtime, explicit capabilities, checksum pinning, and per-run user initiation.")
                    .font(.caption).foregroundStyle(.secondary)
                if model.pluginAuditRecords.isEmpty {
                    Text("No plugin executions have been recorded.").foregroundStyle(.secondary)
                } else {
                    ForEach(model.pluginAuditRecords.prefix(5)) { audit in
                        LabeledContent(
                            "\(audit.pluginID) • \(audit.capability)",
                            value: "exit \(audit.exitCode) • \(audit.sandboxed ? "sandboxed" : "unsandboxed")"
                        )
                    }
                }
            }
            .padding(8)
        }
    }

    private var remoteAgentSection: some View {
        GroupBox("Remote and CI lab agent") {
            HStack(alignment: .top) {
                if let agent = model.remoteAgentConfiguration {
                    VStack(alignment: .leading, spacing: 5) {
                        LabeledContent("Agent", value: agent.agentID.uuidString)
                        LabeledContent("Authenticated queue", value: agent.queuePath)
                        LabeledContent("State", value: agent.enabled ? "Enabled" : "Initialized, disabled")
                        Text("The token is stored separately with mode 0600 and is never included in portable exports or reports.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("No local queue has been initialized.")
                        Text("Initialization creates an authenticated inbox/results queue but does not start a listener or accept network traffic.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Initialize Agent") { model.initializeRemoteAgent() }
                }
            }
            .padding(8)
        }
    }

    private func exportConfiguration() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        if panel.runModal() == .OK, let url = panel.url { model.exportPortableConfiguration(to: url) }
    }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private func gateIcon(_ status: AcceptanceGateStatus) -> String {
        switch status {
        case .passed: "checkmark.circle.fill"
        case .pending: "clock.fill"
        case .blocked: "nosign"
        case .failed: "xmark.circle.fill"
        }
    }

    private func gateColor(_ status: AcceptanceGateStatus) -> Color {
        switch status {
        case .passed: .green
        case .pending: .orange
        case .blocked, .failed: .red
        }
    }

    private func hostColor(_ status: HostCompatibilityStatus) -> Color {
        switch status {
        case .validated: .green
        case .experimental: .orange
        case .unverified: .secondary
        case .incompatible: .red
        }
    }
}
