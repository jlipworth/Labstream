import SwiftUI
import PMSKit

/// "Trailers & Extras" shelf on a leaf detail page (#199): a horizontal rail of playable
/// secondary media (trailers, featurettes, deleted scenes, special features). Tapping a
/// card plays that item directly through the page's normal per-backend launch path — the
/// primary item's metadata and actions are untouched. The shelf is only rendered when
/// there is something to show, so "no extras" is simply an absent section.
struct DetailRelatedMediaShelf: View {
    @Environment(\.labstreamCompactWidth) private var compactWidth

    let items: [MediaItem]
    /// True while the page is already resolving/presenting playback; cards disable so a
    /// second tap can't race the in-flight launch.
    let isBusy: Bool
    let onPlay: (MediaItem) -> Void

    /// Extras are clips: 16:9 thumbs unless the backend reports a real ratio. Compact phones
    /// shrink the card so more than one is visible on a ~390-pt rail.
    private static let cardWidth: CGFloat = 280
    private static let compactCardWidth: CGFloat = 200
    private static let clipAspect = 16.0 / 9.0

    #if os(iOS)
    @State private var railViewportWidth: CGFloat?
    @State private var firstVisibleItemID: String?

    private var railMargin: CGFloat { DS.Scroll.railHorizontalMargin(compact: compactWidth) }
    private var gutter: CGFloat { compactWidth ? DS.Space.md : DS.Space.xl }

    /// iPhone/iPad: measured from the rail viewport (global rule 7, landscape family).
    private var cardWidth: CGFloat {
        DS.Poster.measuredLandscapeRailWidth(viewport: railViewportWidth, compact: compactWidth,
                                             margin: railMargin, gutter: gutter,
                                             fallback: compactWidth ? Self.compactCardWidth : Self.cardWidth)
    }

    /// iPhone/iPad: the same rail and type rules as Cast and More Like This (iPhone Duo design
    /// spec, global rules 6 and 7, Color & type): the shared section header, a viewport that is
    /// the content region with equal content margins, measured cards, Body title and Caption.
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            RailSectionHeader(title: "Trailers & Extras", destination: nil)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: gutter) {
                    ForEach(items) { item in
                        card(for: item)
                    }
                }
                .railScrollTargetLayout()
                .padding(.vertical, DS.Space.sm)
            }
            .mediaRailScrollStyle(horizontalMargin: railMargin)
            .railScrollAnchor($firstVisibleItemID)
            .railViewportWidth($railViewportWidth)
        }
    }

    private var titleFont: Font { .subheadline.weight(.semibold) }
    private var captionFont: Font { .caption }
    #else
    private var cardWidth: CGFloat { compactWidth ? Self.compactCardWidth : Self.cardWidth }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            Text("Trailers & Extras")
                .font(compactWidth ? .title3.weight(.semibold) : .title2.weight(.semibold))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: DS.Space.lg) {
                    ForEach(items) { item in
                        card(for: item)
                    }
                }
            }
        }
    }

    private var titleFont: Font { .headline }
    private var captionFont: Font { .subheadline }
    #endif

    private func card(for item: MediaItem) -> some View {
        Button {
            onPlay(item)
        } label: {
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                PosterImage(path: item.thumb,
                            width: cardWidth,
                            height: CGFloat(Double(cardWidth) / item.resolvedPosterAspect(fallback: Self.clipAspect)))
                    .overlay {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(.white.opacity(0.9))
                            .shadow(radius: 8)
                    }
                    .posterHover()

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(titleFont)
                        .lineLimit(1)
                    Text(subtitle(for: item))
                        .font(captionFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: cardWidth, alignment: .leading)
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
    }

    /// "Trailer · 2m" / "Extra · 14m" — kind label plus a rounded duration when known.
    private func subtitle(for item: MediaItem) -> String {
        let kindLabel = item.kind == .trailer ? "Trailer" : "Extra"
        guard let duration = item.duration, duration > 0 else { return kindLabel }
        let minutes = max(1, Int((Double(duration) / 60_000).rounded()))
        return "\(kindLabel) · \(minutes)m"
    }
}
