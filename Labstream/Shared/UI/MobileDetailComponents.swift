#if os(iOS)
import PMSKit
import SwiftUI

// iPhone/iPad detail-page pieces (iPhone Duo design spec, Movie detail and Show detail). Three
// text styles only: Title (`.title3` semibold), Body (`.subheadline`) and Caption (`.caption`,
// secondary). visionOS, tvOS and macOS keep their own detail compositions.

/// One Caption context line ("2026 · 1h 59m · PG-13") that never wraps: when the full line does
/// not fit, trailing fields drop until it does (the first field always stays).
struct DetailContextLine: View {
    let parts: [String]

    var body: some View {
        if !parts.isEmpty {
            ViewThatFits(in: .horizontal) {
                ForEach((1...parts.count).reversed(), id: \.self) { count in
                    Text(parts.prefix(count).joined(separator: " · "))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Full-width key art: a decorative background layer that crops to `height`, fades into the page
/// at its foot and, through `backgroundExtensionEffect()`, extends under the vertical bar while
/// the text below stays in the content region (global rule 4).
struct DetailKeyArtBand: View {
    let path: String?
    let height: CGFloat

    var body: some View {
        GeometryReader { geometry in
            PosterImage(path: path,
                        width: geometry.size.width,
                        height: geometry.size.height,
                        cornerRadius: 0,
                        showsLoadingShimmer: false)
        }
        .frame(height: max(height, 0))
        .frame(maxWidth: .infinity)
        .clipped()
        .mask {
            LinearGradient(stops: [.init(color: .black, location: 0),
                                   .init(color: .black, location: 0.7),
                                   .init(color: .clear, location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }
        .backgroundExtensionEffect()
        .accessibilityHidden(true)
    }
}

/// A secondary detail action drawn as a 44-pt glass circle. The title is kept for VoiceOver and
/// for the long-press tooltip, so the circle never loses its meaning.
struct DetailCircleActionLabel: View {
    let title: String
    let systemImage: String
    var isBusy: Bool = false

    var body: some View {
        ZStack {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .opacity(isBusy ? 0 : 1)
            if isBusy { ProgressView() }
        }
        .frame(width: 30, height: 30)
        .accessibilityLabel(title)
    }
}

extension View {
    /// Glass circle styling for `DetailCircleActionLabel` buttons (label color, never amber).
    func detailCircleActionStyle(title: String) -> some View {
        self.buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .foregroundStyle(.primary)
            .help(title)
    }
}

/// "Cast" rail: a monogram circle and the name under it, clipped at the content region like
/// every rail (global rule 6). Backends do not deliver headshots on `Tag`, so the circle shows
/// initials.
struct DetailCastRail: View {
    let roles: [Tag]

    @Environment(\.labstreamCompactWidth) private var compactWidth

    private static let avatarSize: CGFloat = 68

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            RailSectionHeader(title: "Cast", destination: nil)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: DS.Space.lg) {
                    ForEach(Array(roles.prefix(20).enumerated()), id: \.offset) { _, role in
                        VStack(spacing: DS.Space.sm) {
                            Circle()
                                .fill(.quaternary)
                                .frame(width: Self.avatarSize, height: Self.avatarSize)
                                .overlay {
                                    Text(Self.initials(role.tag))
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                            Text(role.tag)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(width: Self.avatarSize + DS.Space.lg)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(role.tag)
                    }
                }
                .padding(.vertical, DS.Space.xs)
            }
            .mediaRailScrollStyle(horizontalMargin: DS.Scroll.railHorizontalMargin(compact: compactWidth))
        }
    }

    static func initials(_ name: String) -> String {
        let words = name.split(separator: " ").filter { !$0.isEmpty }
        let letters = [words.first, words.count > 1 ? words.last : nil]
            .compactMap { $0?.first.map(String.init) }
        return letters.joined().uppercased()
    }
}

/// "More Like This" rail: 2:3 posters sized from the measured rail viewport (global rule 7),
/// each pushing its own detail page.
struct DetailMoreLikeThisRail: View {
    let items: [MediaItem]

    @Environment(\.labstreamCompactWidth) private var compactWidth
    @State private var railViewportWidth: CGFloat?
    @State private var firstVisibleItemID: String?

    private var gutter: CGFloat { compactWidth ? DS.Space.md : DS.Space.xl }

    private var posterWidth: CGFloat {
        DS.Poster.measuredRailWidth(viewport: railViewportWidth,
                                    compact: compactWidth,
                                    margin: DS.Scroll.railHorizontalMargin(compact: compactWidth),
                                    gutter: gutter)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            RailSectionHeader(title: "More Like This", destination: nil)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: gutter) {
                    ForEach(items) { item in
                        NavigationLink(value: item) {
                            PosterCell(item: item, width: posterWidth)
                        }
                        .cardLink()
                        .videoCardContextMenu(for: item)
                    }
                }
                .railScrollTargetLayout()
                .padding(.vertical, DS.Space.sm)
            }
            .mediaRailScrollStyle(horizontalMargin: DS.Scroll.railHorizontalMargin(compact: compactWidth))
            .railScrollAnchor($firstVisibleItemID)
            .railViewportWidth($railViewportWidth)
        }
    }
}

/// The season level's one row pattern (iPhone/iPad): a 16:9 still with progress inside the art,
/// the episode title (Body) and "E1 · 38m" (Caption). The season is the screen title, so the
/// row never repeats it.
struct MobileEpisodeRow: View {
    let episode: MediaItem
    var isSelected = false

    @Environment(\.labstreamCompactWidth) private var compactWidth

    var body: some View {
        let stillWidth: CGFloat = compactWidth ? 128 : 160
        HStack(alignment: .center, spacing: DS.Space.md) {
            PosterImage(path: episode.thumb ?? episode.parentThumb,
                        width: stillWidth,
                        height: round(stillWidth * 9 / 16),
                        cornerRadius: DS.Radius.poster)
                .overlay(alignment: .bottom) {
                    ProgressSliver(offset: episode.viewOffset, duration: episode.duration)
                }
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(episode.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .accessibilityIdentifier("container.episode.title.\(episode.ratingKey)")
                Text(MediaDetailCaptions.episodeRow(episode))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if (episode.viewCount ?? 0) > 0 {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Watched")
            }
        }
        .padding(.vertical, DS.Space.xs)
        .contentShape(Rectangle())
    }
}
#endif
