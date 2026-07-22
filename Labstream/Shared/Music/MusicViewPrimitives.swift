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
            // Color.clear.overlay, NOT a bare PosterImage: the 900×600 poster frame
            // is an intrinsic size, and a ZStack consulting it inflates the WHOLE
            // page to ~900 pt (live on iPhone: album title and track card laid out
            // at 900 pt and bled off both screen edges; same mechanism as the
            // NowPlayingView sheet-overflow note). Zero-ideal-size + clipped keeps
            // the wash purely decorative at any window width.
            Color.clear
                .overlay {
                    // Scale the fixed-size wash up to cover the container: a bare
                    // 900×600 leaves un-washed bands on tall phone screens while the
                    // full-height gradient keeps going.
                    GeometryReader { geo in
                        let scale = max(geo.size.width / 900, geo.size.height / 600, 1)
                        PosterImage(path: art, width: 900, height: 600, cornerRadius: 0, requestScale: 1.0)
                            .scaleEffect(scale)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .blur(radius: 60)
                            .opacity(0.30)
                    }
                }
                .clipped()
                .overlay(
                    LinearGradient(colors: [.clear, .black.opacity(0.55)],
                                   startPoint: .top, endPoint: .bottom)
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
    }
}
