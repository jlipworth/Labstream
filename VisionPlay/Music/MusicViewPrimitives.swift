import SwiftUI
import PMSKit

// MARK: - Duration formatting

/// Format a track duration as `m:ss`, or `h:mm:ss` at an hour or more.
func formatTrackDuration(milliseconds: Int) -> String {
    let total = milliseconds / 1000
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let seconds = total % 60
    return hours > 0
        ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
        : String(format: "%d:%02d", minutes, seconds)
}

/// Format a second count as `m:ss`, or `h:mm:ss` at an hour or more.
func formatTrackDuration(seconds: Double) -> String {
    let total = Int(seconds.rounded())
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60
    return hours > 0
        ? String(format: "%d:%02d:%02d", hours, minutes, secs)
        : String(format: "%d:%02d", minutes, secs)
}

// MARK: - Art backdrop

/// Blurred, dimmed wash of artwork behind music content — the same decorative
/// treatment shared by Now Playing, album, and playlist pages. Never hit-testable.
/// Renders nothing when `art` is nil or empty.
struct MusicArtBackdrop: View {
    let art: String?

    var body: some View {
        if let art, !art.isEmpty {
            PosterImage(path: art, width: 900, height: 600, cornerRadius: 0, requestScale: 1.0)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .blur(radius: 60)
                .opacity(0.30)
                .overlay(
                    LinearGradient(colors: [.clear, .black.opacity(0.55)],
                                   startPoint: .top, endPoint: .bottom)
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
    }
}
