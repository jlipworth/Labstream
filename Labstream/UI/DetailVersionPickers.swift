import SwiftUI
import PMSKit

/// Collapsed movie-version chooser (#108). This is distinct from the media-version picker below:
/// each row is a separate backend item/ratingKey that the grid collapsed into one logical movie.
struct DetailMovieVersionPicker: View {
    let versions: [MediaItem]
    let activeVersionRatingKey: String
    @Binding var selectedVersionRatingKey: String?
    let resolvedLabels: [String: String]

    var body: some View {
        if versions.count > 1 {
            Menu {
                ForEach(Array(versions.enumerated()), id: \.element.ratingKey) { index, version in
                    Button {
                        selectedVersionRatingKey = version.ratingKey
                    } label: {
                        if version.ratingKey == activeVersionRatingKey {
                            Label(label(for: version, index: index), systemImage: "checkmark")
                        } else {
                            Text(label(for: version, index: index))
                        }
                    }
                }
            } label: {
                Label("Version: \(label(for: currentVersion, index: currentVersionIndex))",
                      systemImage: "square.stack.3d.up")
                    .font(.callout)
            }
            .menuStyle(.borderlessButton)
        }
    }

    private var currentVersion: MediaItem {
        versions.first { $0.ratingKey == activeVersionRatingKey } ?? versions[0]
    }

    private var currentVersionIndex: Int {
        versions.firstIndex { $0.ratingKey == activeVersionRatingKey } ?? 0
    }

    /// Prefer the per-version metadata fetch label; fall back to whatever the collapsed grid
    /// payload carried; then use a stable ordinal so duplicate-title versions remain distinct.
    private func label(for version: MediaItem, index: Int) -> String {
        if let resolved = resolvedLabels[version.ratingKey], !resolved.isEmpty {
            return resolved
        }
        if let media = version.media?.first {
            let label = MediaVersionLabel.versionLabel(for: media)
            if label != "Version" { return label }
        }
        return "Version \(index + 1)"
    }
}

/// In-item media-version chooser. These are multiple `Media` entries inside one backend item,
/// e.g. 4K vs 1080p files under the same ratingKey.
struct DetailMediaVersionPicker: View {
    let media: [Media]?
    @Binding var selectedMediaIndex: Int

    var body: some View {
        if let media, media.count > 1 {
            Menu {
                ForEach(Array(media.enumerated()), id: \.element.id) { index, item in
                    Button {
                        selectedMediaIndex = index
                    } label: {
                        if index == selectedMediaIndex {
                            Label(MediaVersionLabel.versionLabel(for: item), systemImage: "checkmark")
                        } else {
                            Text(MediaVersionLabel.versionLabel(for: item))
                        }
                    }
                }
            } label: {
                Label("Version: \(MediaVersionLabel.versionLabel(for: media[safe: selectedMediaIndex] ?? media[0]))",
                      systemImage: "rectangle.stack.badge.play")
                    .font(.callout)
            }
            .menuStyle(.borderlessButton)
        }
    }
}
