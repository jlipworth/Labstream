import SwiftUI
import PMSKit

/// Presentation-only title/header block for leaf DetailView items.
///
/// Keeps episode context (show link + S/E code) separate from the title while leaving navigation
/// ownership with the surrounding navigation stack.
struct DetailTitleHeader: View {
    let item: MediaItem
    let showItem: MediaItem?

    var body: some View {
        if item.kind == .episode {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                HStack(spacing: DS.Space.sm) {
                    if let show = item.grandparentTitle, !show.isEmpty {
                        if let showItem {
                            NavigationLink(value: showItem) {
                                Text(show)
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .padding(.horizontal, DS.Space.sm)
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            #if !os(macOS)
                            .hoverEffect(.highlight)
                            #endif
                            .padding(.leading, -DS.Space.sm)
                        } else {
                            Text(show)
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    if let code = item.seasonEpisodeCode {
                        Text(code)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.tint)
                            .layoutPriority(1)
                    }
                }
                Text(item.title)
                    .font(detailTitleFont)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text(item.title)
                .font(detailTitleFont)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var detailTitleFont: Font {
        #if os(tvOS)
        .title2.bold()
        #else
        .largeTitle.bold()
        #endif
    }
}

/// Year/runtime/rating/watched row for a leaf detail item.
struct DetailMetadataRow: View {
    let year: Int?
    let runtimeMinutes: Int?
    let contentRating: String?
    let rating: Double?
    let criticRating: Double?
    let isWatched: Bool

    @Environment(\.labstreamCompactWidth) private var compactWidth

    var body: some View {
        Group {
            if compactWidth {
                // Six children at .title3 overflow the ~358-pt compact budget, so fall
                // back to a two-row layout (year/runtime/rating, then stars/critic/watched)
                // when they can't fit on one line.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: DS.Space.md) {
                        primaryItems
                        secondaryItems
                    }
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        HStack(spacing: DS.Space.md) { primaryItems }
                        HStack(spacing: DS.Space.md) { secondaryItems }
                    }
                }
            } else {
                HStack(spacing: 16) {
                    primaryItems
                    secondaryItems
                }
            }
        }
        .font(metadataFont)
        .foregroundStyle(.secondary)
    }

    private var metadataFont: Font {
        #if os(tvOS)
        .body
        #else
        compactWidth ? .subheadline : .title3
        #endif
    }

    @ViewBuilder
    private var primaryItems: some View {
        if let year {
            Text(String(year))
        }
        if let runtimeMinutes {
            Text("\(runtimeMinutes) min")
        }
        if let contentRating, !contentRating.isEmpty {
            Text(contentRating)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, DS.Space.sm)
                .padding(.vertical, 3)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(.secondary, lineWidth: 1)
                )
        }
    }

    @ViewBuilder
    private var secondaryItems: some View {
        if let rating, rating > 0 {
            Label(String(format: "%.1f", rating), systemImage: "star.fill")
                .foregroundStyle(.yellow)
        }
        if let criticRating, criticRating > 0 {
            Label(String(format: "%.1f", criticRating), systemImage: "rosette")
                .foregroundStyle(.orange)
        }
        if isWatched {
            Label("Watched", systemImage: "checkmark.circle.fill")
        }
    }
}

/// Cast / director / studio credits (#76). Each line renders only when its tag list is non-empty.
struct DetailCreditsSection: View {
    let roles: [Tag]?
    let directors: [Tag]?
    let studios: [Tag]?

    var body: some View {
        #if os(tvOS)
        Grid(alignment: .leading, horizontalSpacing: DS.Space.lg, verticalSpacing: DS.Space.sm) {
            tvCreditRow(label: "Cast", tags: roles, limit: 6)
            tvCreditRow(label: "Director", tags: directors, limit: 3)
            tvCreditRow(label: "Studio", tags: studios, limit: 3)
        }
        #else
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            creditLine(label: "Cast", tags: roles, limit: 6)
            creditLine(label: "Director", tags: directors, limit: 3)
            creditLine(label: "Studio", tags: studios, limit: 3)
        }
        #endif
    }

    #if os(tvOS)
    @ViewBuilder
    private func tvCreditRow(label: String, tags: [Tag]?, limit: Int) -> some View {
        if let tags, !tags.isEmpty {
            let names = tags.prefix(limit).map(\.tag).joined(separator: ", ")
            GridRow(alignment: .firstTextBaseline) {
                Text(label)
                    .foregroundStyle(.secondary)
                    .frame(width: 140, alignment: .leading)
                Text(names)
                    .foregroundStyle(.primary.opacity(0.85))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.callout)
        }
    }
    #endif

    @ViewBuilder
    private func creditLine(label: String, tags: [Tag]?, limit: Int) -> some View {
        if let tags, !tags.isEmpty {
            let names = tags.prefix(limit).map(\.tag).joined(separator: ", ")
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(label):").foregroundStyle(.secondary)
                Text(names).foregroundStyle(.primary.opacity(0.85))
            }
            .font(.callout)
        }
    }
}

/// Selected-version technical badges plus chapter count for the leaf detail page.
struct DetailMediaInfoSummary: View {
    let specBadges: [String]
    let chapterCount: Int?

    @Environment(\.labstreamCompactWidth) private var compactWidth

    var body: some View {
        Group {
            #if os(tvOS)
            ScrollView(.horizontal, showsIndicators: false) {
                chips
            }
            .mediaRailScrollStyle(horizontalMargin: 0, clipDisabled: false)
            #else
            if compactWidth {
                // A full spec set (4K · DOLBY VISION · HEVC · TRUEHD 7.1 · 24 MBPS · chapters)
                // overflows a 390-pt phone, so let the chip row scroll horizontally.
                ScrollView(.horizontal, showsIndicators: false) {
                    chips
                }
                .mediaRailScrollStyle()
            } else {
                chips
            }
            #endif
        }
        .padding(.top, DS.Space.xs)
    }

    private var chips: some View {
        HStack(spacing: DS.Space.sm) {
            ForEach(specBadges, id: \.self) { spec in
                SpecChip(text: spec, monospaced: true)
            }
            if let chapterCount, chapterCount > 0 {
                Text("\(chapterCount) chapters")
                    .font(chapterFont)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var chapterFont: Font {
        #if os(tvOS)
        .callout
        #else
        .caption
        #endif
    }
}
