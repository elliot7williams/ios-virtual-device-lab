import SwiftUI
import UniformTypeIdentifiers

struct FirmwareLibraryView: View {
    @EnvironmentObject private var model: LabAppModel
    @State private var showingImporter = false
    @State private var importKind: FirmwareKind = .iPhone

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.firmware.isEmpty {
                LabEmptyState(
                    icon: "shippingbox",
                    title: "No indexed firmware",
                    message: "Import local IPSWs or let vphone-cli download a supported pairing when a VM is created.",
                    actionTitle: "Import IPSW"
                ) { showingImporter = true }
            } else {
                List {
                    ForEach(model.firmware) { image in
                        FirmwareRow(image: image)
                    }
                }
                .listStyle(.inset)
            }
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [UTType(filenameExtension: "ipsw") ?? .archive],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case let .success(urls):
                Task { await model.importFirmware(urls, kind: importKind) }
            case let .failure(error):
                model.alertMessage = error.localizedDescription
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Firmware Library").font(.title2.weight(.semibold))
                Text("Index local IPSWs without duplicating multi-gigabyte files.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Import as", selection: $importKind) {
                ForEach(FirmwareKind.allCases) { kind in Text(kind.rawValue).tag(kind) }
            }
            .pickerStyle(.segmented)
            .frame(width: 210)
            Button {
                showingImporter = true
            } label: {
                Label("Import IPSW", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(18)
    }
}

private struct FirmwareRow: View {
    @EnvironmentObject private var model: LabAppModel
    let image: FirmwareImage

    private var isManagedCache: Bool {
        image.path.hasPrefix(model.paths.firmwareRoot.path + "/")
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: image.kind == .iPhone ? "iphone" : "cloud")
                .font(.title2)
                .foregroundStyle(image.kind == .iPhone ? .blue : .purple)
                .frame(width: 42, height: 42)
                .background(
                    (image.kind == .iPhone ? Color.blue : Color.purple).opacity(0.1),
                    in: RoundedRectangle(cornerRadius: 9)
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(image.fileName).font(.headline).lineLimit(1)
                HStack(spacing: 8) {
                    Text(image.versionLabel)
                    if let device = image.device { Text(device) }
                    Text(image.sizeLabel)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(image.path)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
            Picker(
                "Kind",
                selection: Binding(
                    get: { image.kind },
                    set: { kind in Task { await model.setFirmwareKind(image, kind: kind) } }
                )
            ) {
                ForEach(FirmwareKind.allCases) { kind in Text(kind.rawValue).tag(kind) }
            }
            .labelsHidden()
            .frame(width: 115)
            Button { model.reveal(image.url) } label: {
                Image(systemName: "folder")
            }
            .help("Reveal in Finder")
            if !isManagedCache {
                Button {
                    Task { await model.forgetFirmware(image) }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .help("Forget without deleting source file")
            }
        }
        .padding(.vertical, 6)
    }
}
