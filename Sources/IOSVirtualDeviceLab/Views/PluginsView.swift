import SwiftUI

struct PluginsView: View {
    @EnvironmentObject private var model: LabAppModel
    @State private var selectedPluginID: String?
    @State private var selectedDeviceID: String?
    @State private var selectedCapability = ""

    private var selectedPlugin: PluginDescriptor? {
        model.plugins.first { $0.id == selectedPluginID }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.plugins.isEmpty {
                LabEmptyState(
                    icon: "puzzlepiece.extension",
                    title: "No plugins installed",
                    message: "Add a JSON descriptor to the Plugins folder. Plugins run only after an explicit action.",
                    actionTitle: "Reveal Plugins Folder"
                ) { model.reveal(PluginRegistry.root(paths: model.paths)) }
            } else {
                HSplitView {
                    List(model.plugins, selection: $selectedPluginID) { plugin in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(plugin.name).fontWeight(.medium)
                                Image(systemName: plugin.trusted == true ? "checkmark.shield.fill" : "exclamationmark.shield")
                                    .foregroundStyle(plugin.trusted == true ? .green : .orange)
                            }
                            Text("v\(plugin.version) • \(plugin.capabilities.joined(separator: ", "))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(plugin.id)
                        .padding(.vertical, 4)
                    }
                    .frame(minWidth: 250, idealWidth: 290)

                    if let plugin = selectedPlugin {
                        pluginDetail(plugin)
                    } else {
                        LabEmptyState(icon: "puzzlepiece.extension", title: "Select a plugin", message: "Inspect its executable and declared capabilities before running it.")
                    }
                }
            }
        }
        .onAppear {
            selectedPluginID = selectedPluginID ?? model.plugins.first?.id
            selectedDeviceID = selectedDeviceID ?? model.devices.first?.id
            selectedCapability = selectedPlugin?.capabilities.first ?? ""
        }
        .onChange(of: selectedPluginID) {
            selectedCapability = selectedPlugin?.capabilities.first ?? ""
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Plugin Registry").font(.title2.weight(.semibold))
                Text("Explicit, executable-based extensions with declared capabilities and context isolation.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Reveal Folder") { model.reveal(PluginRegistry.root(paths: model.paths)) }
            Button("Reload", systemImage: "arrow.clockwise") { model.reloadPlugins() }
        }
        .padding(18)
    }

    private func pluginDetail(_ plugin: PluginDescriptor) -> some View {
        Form {
            Section("Plugin") {
                LabeledContent("Name", value: plugin.name)
                LabeledContent("Identifier", value: plugin.id)
                LabeledContent("Version", value: plugin.version)
                LabeledContent("API version", value: String(plugin.apiVersion ?? 1))
                LabeledContent("Executable", value: plugin.executable)
                LabeledContent("Trust", value: plugin.trusted == true ? "Trusted and checksum-pinned" : "Not trusted")
                LabeledContent("Permissions", value: (plugin.permissions ?? plugin.capabilities).joined(separator: ", "))
                if let description = plugin.description { Text(description).foregroundStyle(.secondary) }
                Button(plugin.trusted == true ? "Revoke Trust" : "Review and Trust…", role: plugin.trusted == true ? .destructive : nil) {
                    model.setPluginTrusted(plugin, trusted: plugin.trusted != true)
                }
            }
            Section("Run") {
                Picker("Capability", selection: $selectedCapability) {
                    ForEach(plugin.capabilities, id: \.self) { Text($0).tag($0) }
                }
                Picker("Device context", selection: $selectedDeviceID) {
                    Text("No device").tag(String?.none)
                    ForEach(model.devices) { Text($0.name).tag(Optional($0.id)) }
                }
                Button("Run Plugin") {
                    let device = model.devices.first { $0.id == selectedDeviceID }
                    Task { await model.runPlugin(plugin, capability: selectedCapability, device: device) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedCapability.isEmpty || plugin.trusted != true)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
