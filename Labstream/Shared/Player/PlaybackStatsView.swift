import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The player Stats panel (#331), hosted by the Stats menu in the custom player chrome.
///
/// Compact by default: a signal chain (server file → what the server does → this device) plus
/// buffer, bitrate, connection, and track tiles. "See more" swaps the same panel to a segmented
/// Video / Audio / Network view that keeps every diagnostic row the old grid had, with a
/// privacy-safe Copy action. The chosen view persists across sessions. Nothing here opens a
/// nested popover or navigation stack, so the same structure works with touch, pointer, gaze,
/// and the tvOS focus engine.
///
/// Typography is limited to three roles — title, value, label — and every compact block uses
/// one cell style (label above value) while every expanded block uses one row style (label
/// beside value). Color means only how the server handles the stream.
@MainActor
struct PlaybackStatsView: View {
    var diagnostics: PlaybackDiagnostics
    var tracks: PlaybackStatsSummary.Tracks

    /// "" shows the compact summary; otherwise the raw value of the expanded section.
    @AppStorage(PlaybackStatsView.sectionDefaultsKey) private var storedSection = ""
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    @State private var copied = false

    nonisolated static let sectionDefaultsKey = "playback.stats.expandedSection"

    private var summary: PlaybackStatsSummary { .make(diagnostics, tracks: tracks) }
    private var section: PlaybackStatsSummary.Section? { .init(rawValue: storedSection) }
    private var stacksCells: Bool { dynamicTypeSize.isAccessibilitySize }

    var body: some View {
        let summary = summary
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            header(summary)
            if let section {
                expanded(summary, section: section)
            } else {
                compact(summary)
            }
        }
        .animation(.smooth(duration: 0.2), value: storedSection)
    }

    // MARK: Header

    private func header(_ summary: PlaybackStatsSummary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Circle()
                    .fill(pathColor(summary.path))
                    .frame(width: Metrics.dot, height: Metrics.dot)
                    .accessibilityHidden(true)
                Text(summary.path.title)
                    .font(.headline)
            }
            Text(summary.reason)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.leading, Metrics.dot + 8)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Compact

    @ViewBuilder
    private func compact(_ summary: PlaybackStatsSummary) -> some View {
        if stacksCells {
            VStack(alignment: .leading, spacing: Metrics.cellGap) {
                chain(summary, vertical: true)
                tiles(summary)
                expandButton
            }
        } else {
            // Wide hosts (phone landscape, iPad, TV) put the chain beside the tiles so the
            // summary fits the short popover without scrolling.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: Metrics.spacing) {
                    chain(summary, vertical: false)
                        .frame(minWidth: Metrics.wideColumn)
                    VStack(spacing: Metrics.cellGap) {
                        tiles(summary)
                        expandButton
                    }
                    .frame(minWidth: Metrics.wideColumn)
                }
                VStack(alignment: .leading, spacing: Metrics.cellGap) {
                    chain(summary, vertical: false)
                    tiles(summary)
                    expandButton
                }
            }
        }
    }

    private func chain(_ summary: PlaybackStatsSummary, vertical: Bool) -> some View {
        let layout = vertical
            ? AnyLayout(VStackLayout(spacing: 0))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 0))
        return layout {
            node(title: "Server file", summary.source, path: summary.path)
            link(summary.path, vertical: vertical)
            node(title: "This device", summary.device, path: summary.path)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary.accessibilitySummary)
        .accessibilityIdentifier("playback.stats.summary")
    }

    private func node(title: String, _ node: PlaybackStatsSummary.Node,
                      path: PlaybackStatsSummary.Path) -> some View {
        VStack(alignment: .leading, spacing: Metrics.cellInnerGap) {
            Text(title).statsLabel()
            ForEach([("Video", node.video), ("HDR", node.hdr), ("Audio", node.audio)], id: \.0) { label, spec in
                VStack(alignment: .leading, spacing: 1) {
                    Text(label).statsLabel()
                    // A converted value keeps primary text on a path-tinted chip, so the color
                    // signal never costs text contrast on light glass.
                    Text(spec.value)
                        .statsValue()
                        .padding(.horizontal, spec.converted ? 5 : 0)
                        .padding(.vertical, spec.converted ? 1 : 0)
                        .background {
                            if spec.converted {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(pathColor(path).opacity(0.28))
                            }
                        }
                        .padding(.horizontal, spec.converted ? -5 : 0)
                }
            }
        }
        .statsCell()
    }

    private func link(_ path: PlaybackStatsSummary.Path, vertical: Bool) -> some View {
        ZStack {
            Rectangle()
                .fill(pathColor(path))
                .frame(width: vertical ? 2 : nil, height: vertical ? nil : 2)
                .frame(maxWidth: vertical ? nil : .infinity, maxHeight: vertical ? .infinity : nil)
            Text(path.linkLabel)
                .font(.caption2.weight(.bold))
                .foregroundStyle(colorScheme == .dark ? .black : .white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(pathColor(path), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .fixedSize()
        }
        .frame(width: vertical ? nil : Metrics.linkLength, height: vertical ? Metrics.linkLength : nil)
        .frame(maxWidth: vertical ? .infinity : nil, maxHeight: vertical ? nil : .infinity)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func tiles(_ summary: PlaybackStatsSummary) -> some View {
        if stacksCells {
            VStack(spacing: Metrics.cellGap) {
                ForEach([summary.buffer, summary.bitrate, summary.connection,
                         summary.audioTrack, summary.subtitles], id: \.label) { tile($0) }
            }
        } else {
            // Health facts in thirds, then the two tracks in halves: track names are the
            // longest values in the summary.
            VStack(spacing: Metrics.cellGap) {
                HStack(spacing: Metrics.cellGap) {
                    tile(summary.buffer)
                    tile(summary.bitrate)
                    tile(summary.connection)
                }
                .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Metrics.cellGap) {
                    tile(summary.audioTrack)
                    tile(summary.subtitles)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func tile(_ tile: PlaybackStatsSummary.Tile) -> some View {
        let layout = stacksCells
            ? AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 10))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 1))
        return VStack(alignment: .leading, spacing: 1) {
            Text(tile.label).statsLabel()
            layout {
                Text(tile.value).statsValue()
                HStack(spacing: 3) {
                    if let symbol = tile.contextSymbol {
                        Image(systemName: symbol)
                            .imageScale(.small)
                            .foregroundStyle(tile.isProblem ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    }
                    Text(tile.context)
                        .foregroundStyle(tile.isProblem ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .fontWeight(tile.isProblem ? .semibold : nil)
                }
                .statsLabel()
            }
        }
        .statsCell()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tile.label)
        .accessibilityValue("\(tile.value), \(tile.accessibilityContext ?? tile.context)")
    }

    private var expandButton: some View {
        Button {
            storedSection = PlaybackStatsSummary.Section.video.rawValue
        } label: {
            Text("See more").statsButtonLabel()
        }
        .statsButtonStyle()
        .accessibilityIdentifier("playback.stats.expand")
        .accessibilityHint("Shows detailed video, audio, and network diagnostics")
    }

    // MARK: Expanded

    @ViewBuilder
    private func expanded(_ summary: PlaybackStatsSummary,
                          section: PlaybackStatsSummary.Section) -> some View {
        Picker("Section", selection: Binding(
            get: { section },
            set: { storedSection = $0.rawValue })) {
            ForEach(PlaybackStatsSummary.Section.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityIdentifier("playback.stats.sections")

        ForEach(summary.groups(for: section), id: \.title) { group in
            VStack(alignment: .leading, spacing: 4) {
                Text(group.title).statsLabel().padding(.leading, 2)
                VStack(spacing: 0) {
                    ForEach(Array(group.rows.enumerated()), id: \.offset) { index, row in
                        if index > 0 { Divider().opacity(0.5) }
                        rowView(row)
                    }
                }
                .padding(.horizontal, Metrics.cellPadding)
                .background(.fill.quaternary,
                            in: RoundedRectangle(cornerRadius: Metrics.cellRadius, style: .continuous))
            }
        }

        HStack(spacing: Metrics.cellGap) {
            #if !os(tvOS)
            Button {
                copy(summary.copyText)
            } label: {
                Text(copied ? "Copied" : "Copy diagnostics").statsButtonLabel()
            }
            .statsButtonStyle()
            .accessibilityIdentifier("playback.stats.copy")
            .accessibilityHint("Copies these stats without track titles")
            #endif
            Button {
                storedSection = ""
            } label: {
                Text("Show less").statsButtonLabel()
            }
            .statsButtonStyle()
            .accessibilityIdentifier("playback.stats.collapse")
        }
    }

    @ViewBuilder
    private func rowView(_ row: PlaybackStatsSummary.Row) -> some View {
        let layout = stacksCells
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 10))
        layout {
            Text(row.label)
                .statsLabel()
                .frame(minWidth: stacksCells ? nil : Metrics.rowLabelWidth, alignment: .leading)
            Text(row.value)
                .font(.subheadline)
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                #if !os(tvOS)
                .textSelection(.enabled)
                #endif
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
    }

    /// The path hue, deepened on light glass so converted values keep text contrast.
    private func pathColor(_ path: PlaybackStatsSummary.Path) -> Color {
        path.color(for: colorScheme)
    }

    private func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif !os(tvOS)
        UIPasteboard.general.string = text
        #endif
        copied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}

private enum Metrics {
    #if os(tvOS)
    static let spacing: CGFloat = 18
    static let cellGap: CGFloat = 12
    static let cellPadding: CGFloat = 16
    static let cellInnerGap: CGFloat = 10
    static let cellRadius: CGFloat = 18
    static let dot: CGFloat = 16
    static let linkLength: CGFloat = 90
    static let wideColumn: CGFloat = 380
    static let rowLabelWidth: CGFloat = 220
    #else
    static let spacing: CGFloat = 10
    static let cellGap: CGFloat = 6
    static let cellPadding: CGFloat = 10
    static let cellInnerGap: CGFloat = 6
    static let cellRadius: CGFloat = 12
    static let dot: CGFloat = 10
    static let linkLength: CGFloat = 44
    static let wideColumn: CGFloat = 260
    static let rowLabelWidth: CGFloat = 104
    #endif
}

extension PlaybackStatsSummary.Path {
    /// One hue per path. Light appearance (e.g. iOS glass over a bright frame) uses deeper
    /// shades of the same hues so small value text stays legible.
    func color(for scheme: ColorScheme) -> Color {
        switch (self, scheme) {
        case (.direct, .dark): .green
        case (.copy, .dark): .cyan
        case (.encode, .dark): .orange
        case (.direct, _): Color(red: 0.05, green: 0.45, blue: 0.18)
        case (.copy, _): Color(red: 0.0, green: 0.40, blue: 0.58)
        case (.encode, _): Color(red: 0.70, green: 0.30, blue: 0.0)
        }
    }
}

private extension View {
    func statsLabel() -> some View {
        font(.caption).foregroundStyle(.secondary).lineLimit(1)
    }

    func statsValue() -> some View {
        font(.subheadline.weight(.semibold)).monospacedDigit().lineLimit(1)
    }

    func statsCell() -> some View {
        padding(.horizontal, Metrics.cellPadding)
            .padding(.vertical, Metrics.cellPadding * 0.8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.fill.quaternary,
                        in: RoundedRectangle(cornerRadius: Metrics.cellRadius, style: .continuous))
    }

    func statsButtonLabel() -> some View {
        font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
    }

    /// tvOS needs a focus platter and visionOS a gaze highlight, which the system bordered
    /// style provides; touch and pointer platforms use a quiet filled shape.
    @ViewBuilder
    func statsButtonStyle() -> some View {
        #if os(tvOS) || os(visionOS)
        buttonStyle(.bordered)
        #else
        buttonStyle(.plain)
            .background(.fill.tertiary,
                        in: RoundedRectangle(cornerRadius: Metrics.cellRadius, style: .continuous))
        #endif
    }
}
