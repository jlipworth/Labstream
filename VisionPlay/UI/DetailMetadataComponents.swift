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
                                    .padding(.horizontal, DS.Space.sm)
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .hoverEffect(.highlight)
                            .padding(.leading, -DS.Space.sm)
                        } else {
                            Text(show)
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let code = item.seasonEpisodeCode {
                        Text(code)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.tint)
                    }
                }
                Text(item.title)
                    .font(.largeTitle.bold())
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text(item.title)
                .font(.largeTitle.bold())
        }
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

    var body: some View {
        HStack(spacing: 16) {
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
        .font(.title3)
        .foregroundStyle(.secondary)
    }
}

/// Cast / director / studio credits (#76). Each line renders only when its tag list is non-empty.
struct DetailCreditsSection: View {
    let roles: [Tag]?
    let directors: [Tag]?
    let studios: [Tag]?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            creditLine(label: "Cast", tags: roles, limit: 6)
            creditLine(label: "Director", tags: directors, limit: 3)
            creditLine(label: "Studio", tags: studios, limit: 3)
        }
    }

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

    var body: some View {
        HStack(spacing: DS.Space.sm) {
            ForEach(specBadges, id: \.self) { spec in
                SpecChip(text: spec, monospaced: true)
            }
            if let chapterCount, chapterCount > 0 {
                Label("\(chapterCount) chapters", systemImage: "list.bullet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, DS.Space.xs)
    }
}
