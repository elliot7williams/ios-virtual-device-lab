import SwiftUI

struct CreateVMView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: LabAppModel

    @State private var name = ""
    @State private var variant: FirmwareVariant = .regular
    @State private var diskSizeGB = 64
    @State private var iphonePath: String?
    @State private var cloudOSPath: String?
    @State private var hardwareProfileID: String?
    @State private var networkMode: NetworkMode = .nat
    @State private var proxyURL = ""
    @State private var captureTraffic = false
    @State private var allowHostNetwork = false
    @State private var audioOutput = true
    @State private var audioInput = false
    @State private var audioRoute: AudioRoute = .systemOutput
    @State private var simulateInterruptions = false
    @State private var allowClipboard = false
    @State private var allowHostIntegration = false
    @State private var allowUnverified = false

    private var iphoneImages: [FirmwareImage] { model.firmware.filter { $0.kind == .iPhone } }
    private var cloudImages: [FirmwareImage] { model.firmware.filter { $0.kind == .cloudOS } }
    private var selectedIPhone: FirmwareImage? { iphonePath.flatMap { path in iphoneImages.first { $0.path == path } } }
    private var recommendation: FirmwareRecommendation? { selectedIPhone.map(model.firmwareRecommendation(for:)) }

    private var canCreate: Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard recommendation?.decision != .blocked else { return false }
        return recommendation?.decision != .warning || allowUnverified
    }

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

                Section("Virtual hardware") {
                    Picker("Device profile", selection: $hardwareProfileID) {
                        ForEach(model.hardwareProfiles.profiles) { profile in
                            Text("\(profile.name) — iOS \(profile.minimumIOSMajor)–\(profile.maximumIOSMajor)")
                                .tag(Optional(profile.id))
                        }
                    }
                    if let profile = model.hardwareProfiles.profile(id: hardwareProfileID) {
                        Text("\(profile.soc) • \(profile.cpuCores) CPU • \(profile.memoryMB) MB RAM • \(profile.productType)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
                    if let recommendation {
                        VStack(alignment: .leading, spacing: 4) {
                            StatusPill(
                                text: recommendation.status.displayName,
                                color: recommendation.decision == .allowed ? .green : (recommendation.decision == .blocked ? .red : .orange)
                            )
                            ForEach(recommendation.messages, id: \.self) { message in
                                Text(message).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if recommendation.decision == .warning {
                            Toggle("I understand this firmware is experimental or unverified", isOn: $allowUnverified)
                        }
                    }
                }

                Section("Storage") {
                    Stepper("Virtual disk: \(diskSizeGB) GB", value: $diskSizeGB, in: 32...256, step: 16)
                    Text("Firmware downloads and VM data are stored under \(model.paths.dataRoot.path).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Networking & isolation") {
                    Picker("Network mode", selection: $networkMode) {
                        ForEach(NetworkMode.allCases) { mode in Text(mode.displayName).tag(mode) }
                    }
                    TextField("Proxy URL (optional)", text: $proxyURL)
                    Toggle("Capture network traffic when supported", isOn: $captureTraffic)
                    Toggle("Allow VM access to host network", isOn: $allowHostNetwork)
                    Toggle("Allow clipboard integration", isOn: $allowClipboard)
                    Toggle("Allow optional host integration", isOn: $allowHostIntegration)
                }

                Section("Audio testing") {
                    Toggle("Virtual audio output", isOn: $audioOutput)
                    Toggle("Virtual audio input", isOn: $audioInput)
                    Picker("Route", selection: $audioRoute) {
                        ForEach(AudioRoute.allCases) { route in Text(route.rawValue).tag(route) }
                    }
                    Toggle("Enable interruption simulation workflow", isOn: $simulateInterruptions)
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
                    .disabled(!canCreate)
            }
        }
        .padding(24)
        .frame(width: 720, height: 780)
        .onAppear {
            hardwareProfileID = hardwareProfileID
                ?? model.hardwareProfiles.profiles.first(where: { $0.status == .supported })?.id
                ?? model.hardwareProfiles.profiles.first?.id
        }
        .onChange(of: iphonePath) { _, _ in applyRecommendation() }
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
                cloudOSIPSW: cloudURL,
                hardwareProfileID: hardwareProfileID,
                network: NetworkConfiguration(
                    mode: networkMode,
                    proxyURL: proxyURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : proxyURL,
                    captureTraffic: captureTraffic,
                    allowHostAccess: allowHostNetwork
                ),
                audio: AudioConfiguration(
                    outputEnabled: audioOutput,
                    inputEnabled: audioInput,
                    route: audioRoute,
                    sampleRateHz: 48_000,
                    simulateInterruptions: simulateInterruptions,
                    backgroundAudioValidation: true
                ),
                isolation: IsolationPolicy(
                    allowNetwork: networkMode != .offline,
                    allowHostNetwork: allowHostNetwork,
                    sharedFolderPath: nil,
                    allowClipboard: allowClipboard,
                    allowHostIntegration: allowHostIntegration
                ),
                allowUnverifiedFirmware: allowUnverified
            )
        }
    }

    private func applyRecommendation() {
        guard let recommendation else { return }
        hardwareProfileID = recommendation.hardwareProfile?.id ?? hardwareProfileID
        cloudOSPath = recommendation.cloudOSFirmware?.path ?? cloudOSPath
        allowUnverified = false
    }
}
