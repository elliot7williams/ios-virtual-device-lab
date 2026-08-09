import SwiftUI

struct CreateVMView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: LabAppModel

    @State private var name = ""
    @State private var variant: FirmwareVariant = .regular
    @State private var diskSizeGB = 64
    @State private var iphonePath: String?
    @State private var cloudOSPath: String?

    private var iphoneImages: [FirmwareImage] { model.firmware.filter { $0.kind == .iPhone } }
    private var cloudImages: [FirmwareImage] { model.firmware.filter { $0.kind == .cloudOS } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("New Virtual Device").font(.title2.weight(.semibold))
                    Text("Creates, restores, patches, and performs the first boot through vphone-cli.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "iphone.gen3.badge.plus")
                    .font(.largeTitle)
                    .foregroundStyle(.blue)
            }

            Form {
                Section("Identity") {
                    TextField("Name", text: $name, prompt: Text("Example: ios-26-regular"))
                    Picker("Firmware variant", selection: $variant) {
                        ForEach(FirmwareVariant.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    Text(variant.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Firmware") {
                    Picker("iPhone IPSW", selection: $iphonePath) {
                        Text("Automatic supported firmware").tag(String?.none)
                        ForEach(iphoneImages) { image in
                            Text("\(image.versionLabel) — \(image.compatibilityStatus?.displayName ?? "Unverified") — \(image.fileName)")
                                .tag(Optional(image.path))
                        }
                    }
                    Picker("cloudOS IPSW", selection: $cloudOSPath) {
                        Text("Automatic recommended pairing").tag(String?.none)
                        ForEach(cloudImages) { image in
                            Text("\(image.versionLabel) — \(image.compatibilityStatus?.displayName ?? "Unverified") — \(image.fileName)")
                                .tag(Optional(image.path))
                        }
                    }
                    if model.firmware.isEmpty {
                        Text("No imported firmware is required: the backend can download a supported pairing automatically.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Storage") {
                    Stepper("Virtual disk: \(diskSizeGB) GB", value: $diskSizeGB, in: 32...256, step: 16)
                    Text("Firmware downloads and VM data are stored under \(model.paths.dataRoot.path).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            HStack {
                Label("VM creation can download several gigabytes and may take a while.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Create") { submit() }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 620, height: 590)
    }

    private func submit() {
        let submittedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let iphoneURL = iphonePath.map(URL.init(fileURLWithPath:))
        let cloudURL = cloudOSPath.map(URL.init(fileURLWithPath:))
        dismiss()
        Task {
            await model.createVM(
                name: submittedName,
                variant: variant,
                diskSizeGB: diskSizeGB,
                iphoneIPSW: iphoneURL,
                cloudOSIPSW: cloudURL
            )
        }
    }
}
