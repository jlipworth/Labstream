import SwiftUI

/// A thin "continue watching" progress bar pinned to a poster's bottom edge,
/// shown only when the item carries a resume offset. Mirrors Plex/Netflix posters.
/// Renders nothing without a positive offset and duration.
struct ProgressSliver: View {
    let offset: Int?
    let duration: Int?

    var body: some View {
        if let offset, offset > 0,
           let duration, duration > 0 {
            let fraction = min(1, max(0, Double(offset) / Double(duration)))
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.black.opacity(0.45))
                    Capsule().fill(.tint)
                        .frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 4)
            .padding(.horizontal, DS.Space.sm)
            .padding(.bottom, DS.Space.sm)
        }
    }
}
