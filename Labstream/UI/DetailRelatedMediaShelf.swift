import SwiftUI
import PMSKit

/// "Trailers & Extras" shelf on a leaf detail page (#199): a horizontal rail of playable
/// secondary media (trailers, featurettes, deleted scenes, special features). Tapping a
/// card plays that item directly through the page's normal per-backend launch path — the
/// primary item's metadata and actions are untouched. The shelf is only rendered when
/// there is something to show, so "no extras" is simply an absent section.
struct DetailRelatedMediaShelf: View {
    let items: [MediaItem]
    /// True while the page is already resolving/presenting playback; cards disable so a
    /// second tap can't race the in-flight launch.
    let isBusy: Bool
    let onPlay: (MediaItem) -> Void

    /// Extras are clips: 16:9 thumbs unless the backend reports a real ratio.
    private static let cardWidth: CGFloat = 280
    private static let clipAspect = 16.0 / 9.0

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            Text("Trailers & Extras")
                .font(.title2.weight(.semibold))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: DS.Space.lg) {
                    ForEach(items) { item in
                        card(for: item)
                    }
                }
            }
        }
    }

    private func card(for item: MediaItem) -> some View {
        Button {
            onPlay(item)
        } label: {
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                PosterImage(path: item.thumb,
                            width: Self.cardWidth,
                            height: CGFloat(Double(Self.cardWidth) / item.resolvedPosterAspect(fallback: Self.clipAspect)))
                    .overlay {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(.white.opacity(0.9))
                            .shadow(radius: 8)
                    }
                    .posterHover()

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(subtitle(for: item))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: Self.cardWidth, alignment: .leading)
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
