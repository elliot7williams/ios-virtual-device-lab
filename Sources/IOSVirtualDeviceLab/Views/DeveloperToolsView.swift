import SwiftUI
import UniformTypeIdentifiers

struct DeveloperToolsView: View {
    @EnvironmentObject private var model: LabAppModel
    @State private var showingArtifactImporter = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    backendContract
                    xcode
                    artifacts
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .fileImporter(
            isPresented: $showingArtifactImporter,
            allowedContentTypes: [
                UTType(filenameExtension: "ipa") ?? .archive,
                UTType(filenameExtension: "tipa") ?? .archive,
            ],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls): if let url = urls.first { model.importAppArtifact(url) }
            case let .failure(error): model.alertMessage = error.localizedDescription
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Developer Tools").font(.title2.weight(.semibold))
                Text("Backend-neutral deployment entry points, Xcode integration, and reusable app builds.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Import App Build", systemImage: "plus") { showingArtifactImporter = true }
        }
        .padding(18)
    }

    private var backendContract: some View {
        GroupBox("Backend API") {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("Backend", value: model.backendDescriptor.name)
                LabeledContent("Identifier", value: model.backendDescriptor.id)
                LabeledContent("Engine", value: model.backendDescriptor.engine)
                Divider()
                Text("The SwiftUI layer sends typed creation, lifecycle, configuration, testing, diagnostic, and progress requests through LabBackend. Command-line syntax remains inside the selected adapter.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 6)
        }
    }

    private var xcode: some View {
        GroupBox("Xcode / Developer Tools Integration") {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Developer directory", value: model.xcodeIntegration.xcodePath ?? "Not detected")
                    LabeledContent("xcodebuild", value: model.xcodeIntegration.xcodebuildVersion ?? "Unavailable")
                    if let helper = model.xcodeIntegration.helperScriptURL {
                        LabeledContent("Deployment helper", value: helper.path)
                        Text("Add it as an Xcode Run Script: `vdl-deploy.sh <vm-name> <path-to-ipa>`. ")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(model.xcodeIntegration.helperScriptURL == nil ? "Install Deployment Helper" : "Reinstall Helper") {
                    model.installXcodeDeploymentHelper()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 6)
        }
    }

    @ViewBuilder
    private var artifacts: some View {
        GroupBox("App Artifact Library") {
            if model.appArtifacts.isEmpty {
                LabEmptyState(
                    icon: "shippingbox",
                    title: "No saved app builds",
                    message: "Import an IPA or TIPA once, then reuse it across test matrices and automation."
                )
                .frame(height: 180)
            } else {
                VStack(spacing: 8) {
                    ForEach(model.appArtifacts) { artifact in
                        HStack {
                            Image(systemName: "app.badge")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(artifact.name).fontWeight(.medium)
                                Text(artifact.url.lastPathComponent).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: artifact.sizeBytes, countStyle: .file))
                                .foregroundStyle(.secondary)
                            Button("Reveal") { model.reveal(artifact.url) }
                            Button("Remove", role: .destructive) { model.deleteAppArtifact(artifact) }
                        }
                        .padding(10)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(.top, 6)
            }
        }
    }
}
