import AppKit
import SwiftUI

struct ActivityView: View {
    @EnvironmentObject private var model: LabAppModel
    @State private var query = ""
    @State private var selectedLevel: LogLevel?

    private var visibleLogs: [LogEntry] {
        model.logs.filter { entry in
            let levelMatches = selectedLevel == nil || entry.level == selectedLevel
            let queryMatches = query.isEmpty
                || entry.message.localizedCaseInsensitiveContains(query)
                || entry.scope.localizedCaseInsensitiveContains(query)
            return levelMatches && queryMatches
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let progress = model.progressEvents.last,
               ![LabOperationPhase.completed, .failed, .cancelled].contains(progress.phase) {
                HStack(spacing: 12) {
                    ProgressView(value: progress.fractionCompleted ?? 0)
                        .frame(width: 180)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(progress.phase.rawValue.capitalized).fontWeight(.medium)
                        Text(progress.message).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text(progress.kind.rawValue.capitalized).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                Divider()
            }
            if model.logs.isEmpty {
                LabEmptyState(
                    icon: "text.alignleft",
                    title: "No activity yet",
                    message: "Backend commands, boot output, and diagnostics appear here."
                )
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(visibleLogs) { entry in
                                LogRow(entry: entry)
                                    .id(entry.id)
                                Divider().opacity(0.35)
                            }
                        }
                        .padding(.horizontal, 12)
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                    .onChange(of: model.logs.count) {
                        if query.isEmpty, let last = visibleLogs.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Activity & Diagnostics").font(.title2.weight(.semibold))
                Text("Streaming backend output and persistent local operation history.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            TextField("Filter logs", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(width: 190)
            Picker("Level", selection: $selectedLevel) {
                Text("All levels").tag(LogLevel?.none)
                Text("Commands").tag(Optional(LogLevel.command))
                Text("Warnings").tag(Optional(LogLevel.warning))
                Text("Errors").tag(Optional(LogLevel.error))
            }
            .labelsHidden()
            .frame(width: 125)
            if model.isBusy {
                Button("Cancel", role: .destructive) {
                    Task { await model.cancelOperations() }
                }
            }
            Menu {
                Button("Copy Visible Logs", action: copyVisible)
                Button("Export All Logs…", action: export)
                Divider()
                Button("Clear Activity", role: .destructive) { model.clearLogs() }
            } label: {
                Label("Actions", systemImage: "ellipsis.circle")
            }
        }
        .padding(18)
    }

    private func copyVisible() {
        let formatter = ISO8601DateFormatter()
        let text = visibleLogs.map {
            "\(formatter.string(from: $0.timestamp)) [\($0.level.rawValue.uppercased())] [\($0.scope)] \($0.message)"
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "ios-virtual-device-lab.log"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try model.exportLogs(to: url) }
        catch { model.alertMessage = error.localizedDescription }
    }
}

private struct LogRow: View {
    let entry: LogEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                .foregroundStyle(.tertiary)
                .frame(width: 82, alignment: .leading)
            Text(entry.scope)
                .foregroundStyle(color)
                .frame(width: 100, alignment: .leading)
                .lineLimit(1)
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 16)
            Text(entry.message)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption.monospaced())
        .padding(.vertical, 6)
    }

    private var icon: String {
        switch entry.level {
        case .info: "circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        case .command: "terminal.fill"
        }
    }

    private var color: Color {
        switch entry.level {
        case .info: .secondary
        case .success: .green
        case .warning: .orange
        case .error: .red
        case .command: .blue
        }
    }
}
