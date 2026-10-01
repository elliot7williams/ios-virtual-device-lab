import SwiftUI

struct HardwareProfilesView: View {
    @EnvironmentObject private var model: LabAppModel
    @State private var selectedID: String?

    private var selected: HardwareProfile? {
        model.hardwareProfiles.profile(id: selectedID)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                List(model.hardwareProfiles.profiles, selection: $selectedID) { profile in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(profile.name).fontWeight(.medium)
                        Text("\(profile.productType) • \(profile.soc)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(profile.id)
                    .padding(.vertical, 4)
                }
                .frame(minWidth: 250, idealWidth: 290)

                if let selected {
                    profileDetail(selected)
                } else {
                    LabEmptyState(
                        icon: "iphone.gen3.radiowaves.left.and.right",
                        title: "Select a hardware profile",
                        message: "Profiles describe the virtual hardware expected by each iOS family."
                    )
                }
            }
        }
        .onAppear { selectedID = selectedID ?? model.hardwareProfiles.profiles.first?.id }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Virtual Hardware Profiles").font(.title2.weight(.semibold))
                Text("Device, SoC, memory, display, GPU, networking, and supported-iOS contracts.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("Database schema \(model.hardwareProfiles.schemaVersion)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(18)
    }

    private func profileDetail(_ profile: HardwareProfile) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(profile.name).font(.largeTitle.weight(.semibold))
                        Text(profile.productType).font(.body.monospaced()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    StatusPill(
                        text: profile.status == .researchOnly ? "Research only" : profile.status.rawValue.capitalized,
                        color: profile.status == .supported ? .green : (profile.status == .experimental ? .orange : .purple)
                    )
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                    MetricCard(title: "SoC", value: profile.soc, systemImage: "cpu")
                    MetricCard(title: "CPU", value: "\(profile.cpuCores) cores", systemImage: "gauge.with.dots.needle.33percent")
                    MetricCard(title: "RAM", value: memoryLabel(profile.memoryMB), systemImage: "memorychip")
                    MetricCard(title: "Storage", value: "\(profile.defaultStorageGB) GB", systemImage: "internaldrive")
                }

                GroupBox("Hardware contract") {
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                        row("Supported iOS", "\(profile.minimumIOSMajor)–\(profile.maximumIOSMajor)")
                        row("Display", "\(profile.display.width)×\(profile.display.height) @ \(profile.display.scale.formatted())x / \(profile.display.refreshRateHz) Hz")
                        row("GPU", "\(profile.gpu.family) — \(profile.gpu.acceleration)")
                        row("Networking", profile.networking.map(\.displayName).joined(separator: ", "))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
                }

                Text(profile.notes).foregroundStyle(.secondary)
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            Text(value).textSelection(.enabled)
        }
    }

    private func memoryLabel(_ megabytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(megabytes) * 1_048_576, countStyle: .memory)
    }
}
