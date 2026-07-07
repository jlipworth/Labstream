import SwiftUI

/// Shared Home/Artists/Albums/Playlists pivot chrome for the Music tab.
///
/// Plex and MediaBrowser music provide different content for each pivot, but the segmented picker,
/// spacing, and pivot identity should not drift between backend shells (#159).
enum MusicPivot: String, CaseIterable, Identifiable {
    case home = "Home"
    case artists = "Artists"
    case albums = "Albums"
    case playlists = "Playlists"

    var id: String { rawValue }
}

struct MusicPivotShell<Content: View>: View {
    @Binding private var pivot: MusicPivot
    private let content: (MusicPivot) -> Content

    init(pivot: Binding<MusicPivot>, @ViewBuilder content: @escaping (MusicPivot) -> Content) {
        _pivot = pivot
        self.content = content
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Browse", selection: $pivot) {
                ForEach(MusicPivot.allCases) { pivot in
                    Text(pivot.rawValue).tag(pivot)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 460)
            // Breathing room on compact, where the bar would otherwise run
            // edge-to-edge; regular width is already capped at 460 and centered.
            .padding(.horizontal, DS.Space.lg)
            .padding(.top, DS.Space.md)
            .padding(.bottom, DS.Space.sm)

            content(pivot)
        }
    }
}
