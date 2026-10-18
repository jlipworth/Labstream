#if !os(tvOS)
import SwiftUI
import PMSKit

/// Shared semantic cell content; native list/form wrappers retain artwork and action target sizes.
struct DownloadRowContent: View {
    let presentation: DownloadRowPresentation

    private var statusColor: Color {
        switch presentation.tone {
        case .neutral: .secondary
        case .verified: .green
        case .caution: .orange
        case .failure: .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(presentation.row.title)
                .font(.headline)
                .lineLimit(2)
                .accessibilityLabel(presentation.row.title)
            HStack(spacing: 8) {
                Text(presentation.row.routeBadge.rawValue)
                    .accessibilityLabel("Download route: \(presentation.row.routeBadge.rawValue)")
                if presentation.row.showBackendBadge {
                    Text(presentation.row.backendName)
                        .accessibilityLabel("Source: \(presentation.row.backendName)")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            if let subtitle = presentation.row.subtitle { contextLine(subtitle) }
            if let quality = presentation.row.qualityText { contextLine(quality) }
            switch presentation.progress {
            case .none: EmptyView()
            case .indeterminate: ProgressView().controlSize(.small)
            case .fraction(let value, let estimated):
                ProgressView(value: value)
                    .accessibilityValue((estimated ? "Approximately " : "") + "\(Int(value * 100))%. "
                        + presentation.row.statusCaption)
            }
            Text(presentation.statusText)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(statusColor)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityLabel("Download status")
                .accessibilityValue(presentation.accessibleStatus)
                .accessibilityIdentifier("download.status")
            if let error = presentation.row.errorMessage, !error.isEmpty {
                // The popover exposes the entire reason at narrow widths and large text sizes.
                DownloadRowReason(reason: error, color: statusColor)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func contextLine(_ value: String) -> some View {
        Text(value)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .accessibilityValue(value)
    }
}

private struct DownloadRowReason: View {
    let reason: String
    let color: Color
    @State private var showingReason = false
    var body: some View {
        Button { showingReason = true } label: {
            Text("Details")
                .font(.caption)
                .foregroundStyle(color)
                .frame(minHeight: 44, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Download details")
        .accessibilityValue(reason)
        .popover(isPresented: $showingReason) {
            Text(reason).padding().frame(idealWidth: 320).textSelection(.enabled)
        }
    }
}
#endif

#if !os(tvOS)
/// The same title/detail/accessory geometry for every selectable download route.
struct DownloadOptionContent: View {
    let title: String
    let detail: String?
    let systemImage: String
    let selected: Bool
    var disabled = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .frame(width: 28)
                .foregroundStyle(disabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(disabled ? .secondary : .primary).lineLimit(2)
                if let detail, !detail.isEmpty {
                    Text(detail.replacingOccurrences(of: "\n", with: " • "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .accessibilityValue(detail)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "checkmark")
                .foregroundStyle(.tint)
                .opacity(selected ? 1 : 0)
                .accessibilityHidden(true)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("download.option.\(title)")
    }
}
#endif
