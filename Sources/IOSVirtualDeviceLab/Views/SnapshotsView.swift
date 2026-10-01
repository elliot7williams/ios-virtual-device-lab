import SwiftUI

struct SnapshotsView: View {
    @EnvironmentObject private var model: LabAppModel
    @State private var selectedID: UUID?
    @State private var restoring: SnapshotRecord?
    @State private var deleting: SnapshotRecord?
    @State private var showingRetention = false

    private var selected: SnapshotRecord? {
        model.snapshots.first { $0.id == selectedID }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.snapshots.isEmpty {
                LabEmptyState(
                    icon: "camera.filters",
                    title: "No snapshots",
                    message: "Stop a virtual device and create a named restore point from its detail view."
                )
            } else {
                Table(model.snapshots, selection: $selectedID) {
                    TableColumn("Snapshot") { snapshot in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(snapshot.name).fontWeight(.medium)
                            Text(snapshot.sourceVM).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    TableColumn("Created") { snapshot in
                        Text(snapshot.createdAt.formatted(date: .abbreviated, time: .shortened))
                    }
                    TableColumn("Archive size") { snapshot in
                        Text(snapshot.sizeLabel)
                    }
                    TableColumn("Integrity") { snapshot in
                        StatusPill(
                            text: (snapshot.integrityStatus ?? .unchecked).rawValue.capitalized,
                            color: integrityColor(snapshot.integrityStatus ?? .unchecked)
                        )
                    }
                    TableColumn("Archive") { snapshot in
                        Text(snapshot.archiveURL.lastPathComponent)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                    }
                }
            }
        }
        .sheet(item: $restoring) { snapshot in
            NamePromptSheet(
                title: "Restore \(snapshot.name)",
                message: "Imports this restore point as a new VM, preserving the original device.",
                initialValue: "\(snapshot.sourceVM)-restored",
                actionTitle: "Restore"
            ) { newName in
                Task { await model.restore(snapshot, as: newName) }
            }
        }
        .sheet(isPresented: $showingRetention) {
            SnapshotRetentionSheet(policy: model.snapshotRetention) { policy, applyNow in
                model.updateSnapshotRetention(policy)
                if applyNow { Task { await model.applySnapshotRetention() } }
            }
        }
        .alert(
            "Delete snapshot?",
            isPresented: Binding(
                get: { deleting != nil },
                set: { if !$0 { deleting = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { deleting = nil }
            Button("Delete", role: .destructive) {
                if let deleting { Task { await model.delete(deleting) } }
                deleting = nil
            }
        } message: {
            Text("The compressed archive is permanently removed. The source VM is unchanged.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Snapshots & Backups").font(.title2.weight(.semibold))
                Text("Named compressed restore points backed by vphone-cli export/import.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Reveal Archives") { model.reveal(model.paths.snapshotsRoot) }
            Button("Retention…", systemImage: "calendar.badge.clock") { showingRetention = true }
            Button {
                if let selected { Task { await model.verify(selected) } }
            } label: {
                Label("Verify", systemImage: "checkmark.shield")
            }
            .disabled(selected == nil)
            Button {
                if let selected { restoring = selected }
            } label: {
                Label("Restore", systemImage: "arrow.uturn.backward")
            }
            .disabled(selected == nil)
            .buttonStyle(.borderedProminent)
            Button(role: .destructive) {
                deleting = selected
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(selected == nil)
        }
        .padding(18)
    }

    private func integrityColor(_ status: SnapshotIntegrityStatus) -> Color {
        switch status {
        case .verified: .green
        case .changed, .missing: .red
        case .unchecked: .secondary
        }
    }
}

private struct SnapshotRetentionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let save: (SnapshotRetentionPolicy, Bool) -> Void
    @State private var policy: SnapshotRetentionPolicy
    @State private var applyNow = false

    init(policy: SnapshotRetentionPolicy, save: @escaping (SnapshotRetentionPolicy, Bool) -> Void) {
        self.save = save
        _policy = State(initialValue: policy)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Snapshot Retention").font(.title2.weight(.semibold))
            Form {
                Toggle("Enable automatic retention after snapshot creation", isOn: $policy.isEnabled)
                Stepper("Keep last \(policy.keepLastPerDevice) per VM", value: $policy.keepLastPerDevice, in: 1...50)
                Stepper("Maximum age: \(policy.maximumAgeDays) days", value: $policy.maximumAgeDays, in: 1...365)
                Stepper(
                    "Maximum total storage: \(policy.maximumTotalBytes / 1_073_741_824) GB",
                    value: Binding(
                        get: { Int(policy.maximumTotalBytes / 1_073_741_824) },
                        set: { policy.maximumTotalBytes = Int64($0) * 1_073_741_824 }
                    ),
                    in: 10...2_000,
                    step: 10
                )
                Toggle("Verify checksum before pruning", isOn: $policy.verifyBeforePruning)
                Toggle("Apply policy now", isOn: $applyNow)
            }
            .formStyle(.grouped)
            Text("The newest protected snapshots per VM are never removed to satisfy age or storage limits.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") {
                    save(policy, applyNow)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 560, height: 470)
    }
}
