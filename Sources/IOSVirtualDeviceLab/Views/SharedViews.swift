import SwiftUI

struct HostReadinessBanner: View {
    let readiness: HostReadiness
    let recheck: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if readiness.state != .ready {
                Text("Recovery: csrutil enable --without debug  •  csrutil allow-research-guests enable")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Button("Recheck", action: recheck)
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(color.opacity(0.08))
    }

    private var title: String {
        switch readiness.state {
        case .ready: "Host ready"
        case .actionRequired: "Host setup required"
        case .unavailable: "Host unavailable"
        }
    }

    private var detail: String {
        switch readiness.state {
        case .ready:
            "\(readiness.model) • macOS \(readiness.macOSVersion) • research guests enabled"
        case .actionRequired:
            "\(readiness.researchGuestsStatus) • vphone exit \(readiness.binaryExitCode.map(String.init) ?? "unknown") • run vphone-amfidont after restarting"
        case .unavailable:
            readiness.nestedVirtualization
                ? "Nested Virtualization.framework guests are unavailable"
                : "Apple Silicon, macOS 15+, and vphone-cli are required"
        }
    }

    private var icon: String {
        switch readiness.state {
        case .ready: "checkmark.circle.fill"
        case .actionRequired: "exclamationmark.triangle.fill"
        case .unavailable: "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch readiness.state {
        case .ready: .green
        case .actionRequired: .orange
        case .unavailable: .red
        }
    }
}

struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(color.opacity(0.12), in: Capsule())
        .foregroundStyle(color)
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .frame(width: 24)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.body.weight(.medium)).lineLimit(1)
            }
            Spacer(minLength: 4)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
        }
    }
}

struct LabEmptyState: View {
    let icon: String
    let title: String
    let message: String
    let actionTitle: String?
    let action: (() -> Void)?

    init(
        icon: String,
        title: String,
        message: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.icon = icon
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            Text(message)
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
