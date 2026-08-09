import SwiftUI

struct SnapshotsView: View {
    @EnvironmentObject private var model: LabAppModel
    @State private var selectedID: UUID?
    @State private var restoring: SnapshotRecord?
    @State private var deleting: SnapshotRecord?

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
}
