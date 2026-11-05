#if !os(tvOS)
import SwiftUI
import PMSKit

/// Shared semantic cell content; native list/form wrappers retain artwork and action target sizes.
struct DownloadRowContent: View {
    let presentation: DownloadRowPresentation
    /// iPhone/iPad: the finished file's size, appended to the context line (there is no detail
    /// page to show it).
    var sizeText: String? = nil

    private var statusColor: Color {
        switch presentation.tone {
        case .neutral: .secondary
        case .verified: .green
        #if os(iOS)
        // iPhone/iPad palette (iPhone Duo design spec, Color & type): caution is the secondary
        // label plus a symbol, never an orange that reads as amber ("selected").
        case .caution: .secondary
        #else
        case .caution: .orange
        #endif
        case .failure: .red
        }
    }

    var body: some View {
        #if os(iOS)
        mobileBody
        #else
        standardBody
        #endif
    }

    #if os(iOS)
    /// iPhone/iPad: one row pattern with the three text styles (Body title on one line, one
    /// Caption context line, a 1–2 word Caption status).
    private var mobileBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(presentation.row.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityLabel(presentation.row.title)
            if let context = mobileContextText { contextLine(context) }
            progressBar
            HStack(spacing: 4) {
                if presentation.tone == .caution {
                    Image(systemName: "exclamationmark.triangle")
                        .accessibilityHidden(true)
                }
                Text(presentation.compactStatusText)
                    .lineLimit(1)
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(statusColor)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Download status")
            .accessibilityValue(presentation.accessibleStatus)
            .accessibilityIdentifier("download.status")
            if let error = presentation.row.errorMessage, !error.isEmpty {
                DownloadRowReason(reason: error, color: statusColor)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The single context line: the source (only when backends are mixed), then the year,
    /// runtime and rating; the requested quality only when there is no metadata line; then the
    /// file size once the download has finished.
    private var mobileContextText: String? {
        let detail = presentation.row.subtitle ?? presentation.row.qualityText
        let parts = [presentation.row.showBackendBadge ? presentation.row.backendName : nil, detail, sizeText]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }
    #endif

    @ViewBuilder
    private var progressBar: some View {
        switch presentation.progress {
        case .none: EmptyView()
        case .indeterminate: ProgressView().controlSize(.small)
        case .fraction(let value, let estimated):
            ProgressView(value: value)
                .modifier(DownloadTransferBarTint())
                .accessibilityValue((estimated ? "Approximately " : "") + "\(Int(value * 100))%. "
                    + presentation.row.statusCaption)
        }
    }

    #if !os(iOS)
    private var standardBody: some View {
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
            progressBar
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
    #endif

    private func contextLine(_ value: String) -> some View {
        Text(value)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .accessibilityValue(value)
    }
}

/// iPhone/iPad: the transfer bar uses the label color like all progress (amber means
/// "selected" only; iPhone Duo design spec, Color & type). Other platforms keep the accent.
private struct DownloadTransferBarTint: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content.tint(.primary)
        #else
        content
        #endif
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
                .foregroundStyle(iconStyle)
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

    /// iPhone/iPad: amber means "selected" only, so the route icon is the label color and the
    /// checkmark alone carries the selection. Other platforms keep the tinted icon.
    private var iconStyle: AnyShapeStyle {
        if disabled { return AnyShapeStyle(.secondary) }
        #if os(iOS)
        return AnyShapeStyle(.primary)
        #else
        return AnyShapeStyle(.tint)
        #endif
    }
}
#endif
