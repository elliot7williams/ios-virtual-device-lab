import SwiftUI

struct BackendAttributionView: View {
    @EnvironmentObject private var model: LabAppModel
    @State private var selectedBackendID: String?
    @State private var selectedFirmwareID: UUID?

    private var selectedBackend: BackendCatalogEntry? {
        model.backendCatalog.entry(id: selectedBackendID) ?? model.backendCatalog.entries.first
    }

    private var selectedFirmware: FirmwareImage? {
        model.firmware.first { $0.id == selectedFirmwareID }
            ?? model.firmware.first { $0.kind == .iPhone }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                backendSummary
                recommendationPanel
                comparisonPanel
                capabilityPanel
                attributionPanel
            }
            .padding(20)
            .frame(maxWidth: 1_120, alignment: .leading)
        }
        .onAppear {
            selectedBackendID = selectedBackendID ?? model.backendDescriptor.id
            selectedFirmwareID = selectedFirmwareID ?? model.firmware.first(where: { $0.kind == .iPhone })?.id
        }
    }

    private var comparisonPanel: some View {
        GroupBox("Three-project capability comparison") {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                GridRow {
                    Text("Capability").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(model.backendCatalog.entries) { backend in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(backend.name).font(.caption.weight(.semibold))
                            Text(backend.integrationState.displayName)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Divider().gridCellColumns(model.backendCatalog.entries.count + 1)
                ForEach(BackendCapabilityID.allCases) { capability in
                    GridRow {
                        Text(capability.displayName).font(.caption)
                        ForEach(model.backendCatalog.entries) { backend in
                            let level = backend.capability(capability)?.level
                            StatusPill(
                                text: level?.displayName ?? "Unrecorded",
                                color: capabilityColor(level)
                            )
                            .help(backend.capability(capability)?.evidence ?? "No evidence recorded")
                        }
                    }
                }
            }
            .padding(.top, 6)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Backends & Attribution").font(.title2.weight(.semibold))
                Text("Capability-based engine selection with explicit licensing, provenance, and integration boundaries.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            StatusPill(
                text: "\(model.backendCatalog.entries.filter(\.isRunnable).count) runnable",
                color: model.backendCatalog.entries.contains(where: \.isRunnable) ? .green : .orange
            )
        }
    }

    private var backendSummary: some View {
        GroupBox("Backend registry") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Inspect backend", selection: Binding(
                    get: { selectedBackendID ?? selectedBackend?.id ?? "" },
                    set: { selectedBackendID = $0 }
                )) {
                    ForEach(model.backendCatalog.entries) { backend in
                        Text(backend.name).tag(backend.id)
                    }
                }
                .pickerStyle(.segmented)

                if let backend = selectedBackend {
                    HStack(alignment: .top, spacing: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(backend.name).font(.headline)
                            Text(backend.role).foregroundStyle(.secondary)
                            LabeledContent("Integration", value: backend.integrationState.displayName)
                            LabeledContent("Version", value: backend.version)
                            LabeledContent("License", value: backend.license)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 8) {
                            StatusPill(
                                text: backend.isRunnable ? "Runnable" : "Not selectable",
                                color: backend.isRunnable ? .green : (backend.integrationState == .referenceOnly ? .secondary : .orange)
                            )
                            if let url = URL(string: backend.sourceURL) {
                                Link("Open authoritative source", destination: url)
                            }
                        }
                    }
                    ForEach(backend.notes, id: \.self) { note in
                        Label(note, systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 6)
        }
    }

    @ViewBuilder
    private var recommendationPanel: some View {
        GroupBox("Automatic backend recommendation") {
            VStack(alignment: .leading, spacing: 10) {
                if model.firmware.filter({ $0.kind == .iPhone }).isEmpty {
                    Text("Import an iPhone IPSW to receive a firmware-specific backend recommendation.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Firmware", selection: Binding(
                        get: { selectedFirmwareID ?? selectedFirmware?.id },
                        set: { selectedFirmwareID = $0 }
                    )) {
                        ForEach(model.firmware.filter { $0.kind == .iPhone }) { firmware in
                            Text("\(firmware.fileName) • \(firmware.versionLabel)").tag(Optional(firmware.id))
                        }
                    }
                    if let firmware = selectedFirmware {
                        let recommendation = model.backendRecommendation(for: firmware)
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(recommendation.title).font(.headline)
                                ForEach(recommendation.reasons, id: \.self) { reason in
                                    Text(reason).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            StatusPill(text: recommendation.verdict.displayName, color: color(for: recommendation.verdict))
                        }
                        if !recommendation.researchCandidateIDs.isEmpty {
                            Text("Research candidates: \(recommendation.researchCandidateIDs.compactMap { model.backendCatalog.entry(id: $0)?.name }.joined(separator: ", ")). These are not automatic fallbacks until an adapter and boot evidence exist.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            .padding(.top, 6)
        }
    }

    @ViewBuilder
    private var capabilityPanel: some View {
        if let backend = selectedBackend {
            GroupBox("Capability evidence") {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 10) {
                    ForEach(BackendCapabilityID.allCases) { capability in
                        let record = backend.capability(capability)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(capability.displayName).font(.callout.weight(.medium))
                                Spacer()
                                StatusPill(
                                    text: record?.level.displayName ?? "Unrecorded",
                                    color: capabilityColor(record?.level)
                                )
                            }
                            Text(record?.evidence ?? "No evidence has been recorded.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(10)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(.top, 6)
            }
        }
    }

    private var attributionPanel: some View {
        GroupBox("Third-party provenance and license review") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Catalog schema \(model.attributionCatalog.schemaVersion) • updated \(model.attributionCatalog.updatedAt)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Spacer()
                    StatusPill(
                        text: model.attributionCatalog.completenessIssues.isEmpty ? "Required fields recorded" : "Review required",
                        color: model.attributionCatalog.completenessIssues.isEmpty ? .green : .orange
                    )
                }
                ForEach(model.attributionCatalog.records) { record in
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 5) {
                            LabeledContent("Version / pin", value: record.version)
                            LabeledContent("License / terms", value: record.license)
                            LabeledContent("Source-code use", value: record.sourceCodeUse)
                            LabeledContent("Distributed with app", value: record.distributedWithApp ? "Yes" : "No")
                            ForEach(record.modifications, id: \.self) { item in
                                Label(item, systemImage: "wrench.and.screwdriver")
                            }
                            ForEach(record.obligations, id: \.self) { item in
                                Label(item, systemImage: "checklist")
                            }
                            if let url = URL(string: record.sourceURL) {
                                Link("Source or official documentation", destination: url)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(record.name).fontWeight(.medium)
                                Text(record.role).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            StatusPill(text: record.reviewState.displayName, color: attributionColor(record.reviewState))
                            Text(record.integrationState.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                }
                ForEach(model.attributionCatalog.completenessIssues, id: \.self) { issue in
                    Label(issue, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.top, 6)
        }
    }

    private func color(for verdict: BackendRecommendationVerdict) -> Color {
        switch verdict {
        case .ready: .green
        case .guarded: .orange
        case .unavailable: .orange
        case .blocked: .red
        }
    }

    private func capabilityColor(_ level: BackendCapabilityLevel?) -> Color {
        switch level {
        case .supported: .green
        case .partial, .experimental: .orange
        case .unsupported: .red
        case .benchmark: .blue
        case .unknown, nil: .secondary
        }
    }

    private func attributionColor(_ state: AttributionReviewState) -> Color {
        switch state {
        case .verified: .green
        case .conditional: .orange
        case .referenceOnly: .blue
        }
    }
}
