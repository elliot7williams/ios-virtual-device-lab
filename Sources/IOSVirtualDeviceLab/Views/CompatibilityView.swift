import SwiftUI

struct CompatibilityView: View {
    @EnvironmentObject private var model: LabAppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Table(model.compatibility.entries) {
                TableColumn("iOS") { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.iosVersion).fontWeight(.medium)
                        Text(entry.iosBuild ?? "Any recorded build")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .width(min: 100, ideal: 125)

                TableColumn("Device") { entry in
                    Text(entry.device ?? "Research target")
                        .font(.callout.monospaced())
                }
                .width(min: 120, ideal: 145)

                TableColumn("cloudOS") { entry in
                    Text([entry.cloudOSVersion, entry.cloudOSBuild].compactMap { $0 }.joined(separator: " • "))
                        .foregroundStyle(.secondary)
                }
                .width(min: 110, ideal: 150)

                TableColumn("Status") { entry in
                    StatusPill(text: entry.status.displayName, color: color(for: entry.status))
                }
                .width(115)

                TableColumn("Hardware profile") { entry in
                    Text((entry.hardwareProfileIDs ?? []).compactMap { model.hardwareProfiles.profile(id: $0)?.name }.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .width(min: 120, ideal: 170)

                TableColumn("Evidence and notes") { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.notes).lineLimit(2)
                        if !entry.validatedHosts.isEmpty {
                            Text(entry.validatedHosts.joined(separator: " • "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if let boot = entry.bootStatus { Text(boot).font(.caption).foregroundStyle(.secondary) }
                        if let deployment = entry.appDeploymentSupport { Text("App deployment: \(deployment)").font(.caption2).foregroundStyle(.tertiary) }
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Compatibility Manifest").font(.title2.weight(.semibold))
                Text("Versioned evidence, not assumptions based on an IPSW filename.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("Schema \(model.compatibility.schemaVersion) • updated \(model.compatibility.updatedAt)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            StatusPill(
                text: "\(model.compatibility.entries.filter { $0.status == .supported }.count) supported",
                color: .green
            )
        }
        .padding(18)
    }

    private func color(for status: CompatibilityStatus) -> Color {
        switch status {
        case .supported: .green
        case .experimental: .orange
        case .researching: .blue
        case .incompatible: .red
        case .unverified: .secondary
        }
    }
}
