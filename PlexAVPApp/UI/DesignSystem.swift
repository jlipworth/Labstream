import SwiftUI

/// The app's shared visual language — one place that defines the spacing scale,
/// corner radii, poster proportions, and reusable styling primitives so every
/// screen feels like the same premium product instead of a pile of ad-hoc numbers.
///
/// WHY a namespace of constants rather than scattered literals: a media app lives
/// or dies on *rhythm* — posters that share an aspect ratio, rails that share a
/// gutter, cards that share a corner radius. Centralising those values lets us tune
/// the whole app from one file and guarantees Home, Libraries, Search and Detail
/// stay visually in lock-step. Nothing here changes behaviour: it is pure layout.
enum DS {
    /// 8-pt spacing scale. Using named steps (instead of raw 8/16/24…) makes intent
    /// readable at the call site and keeps vertical/horizontal rhythm consistent.
    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let xxxl: CGFloat = 48
    }

    /// Continuous corner radii. Posters and cards use the same family so rounded
    /// shapes read as one system rather than a grab-bag of radii.
    enum Radius {
        static let poster: CGFloat = 16
        static let card: CGFloat = 20
        static let chip: CGFloat = 10
    }

    /// Canonical poster geometry. A 2:3 movie-poster ratio is the backbone of the
    /// browse UI; deriving heights from a single width keeps every rail and grid
    /// cell perfectly aligned regardless of the size we render at.
    enum Poster {
        /// The 2:3 aspect ratio shared by rail and grid posters.
        static let aspect: CGFloat = 2.0 / 3.0
        /// Default rail/grid poster width in points.
        static let railWidth: CGFloat = 184
        static let gridMin: CGFloat = 168
        static let gridMax: CGFloat = 208
        /// Detail-screen hero poster width.
        static let detailWidth: CGFloat = 300

        /// Height for a given poster width at the canonical 2:3 ratio.
        static func height(for width: CGFloat) -> CGFloat { width / aspect }
    }

    /// Soft, layered shadow used under posters and cards to lift them off the glass
    /// without looking heavy. visionOS already has real depth; this is a gentle hint.
    static func posterShadow<S: Shape>(_ shape: S) -> some View {
        shape.fill(.clear)
            .shadow(color: .black.opacity(0.35), radius: 14, x: 0, y: 10)
    }
}

// MARK: - Reusable view modifiers

/// Lifts a poster/card on visionOS hover: a subtle scale + brighten that gives the
/// browse grid the same tactile, gaze-responsive feel as Apple's own media apps.
/// Hover is the primary "where am I looking" cue on visionOS, so every tappable
/// poster gets it for free via `.posterHover()`.
private struct PosterHoverEffect: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering ? 1.05 : 1.0)
            .shadow(color: .black.opacity(hovering ? 0.45 : 0.30),
                    radius: hovering ? 22 : 12,
                    x: 0, y: hovering ? 16 : 8)
            .animation(.spring(response: 0.32, dampingFraction: 0.7), value: hovering)
            .onHover { hovering = $0 }
    }
}

extension View {
    /// Apply the standard poster hover lift. Purely visual; does not affect hit-testing.
    func posterHover() -> some View { modifier(PosterHoverEffect()) }

    /// visionOS-safe style for poster/card `NavigationLink`s. MUST ride a BUILT-IN
    /// button style: any custom `ButtonStyle` gets its gaze/hover region registered
    /// displaced (~1.35× about the window center), so pinches on a rail card route to
    /// a NEIGHBOR card — proven live by bisection, see the gotcha in
    /// docs/DEVELOPMENT.md. `.plain` registers through the correct path and routes
    /// clicks accurately; the `contentShape(.hoverEffect, …)` reshapes its automatic
    /// system highlight to the card's rounded rect.
    func cardLink(cornerRadius: CGFloat = DS.Radius.poster) -> some View {
        buttonStyle(.plain)
            .contentShape(.hoverEffect,
                          RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// A pill-shaped spec/metadata chip used across Detail and cards. Centralised so the
/// "4K · HEVC · 24 Mbps" style badges look identical everywhere they appear.
struct SpecChip: View {
    let text: String
    var monospaced: Bool = false

    var body: some View {
        Text(text)
            .font(monospaced ? .caption.monospaced() : .caption.weight(.medium))
            .padding(.horizontal, DS.Space.md)
            .padding(.vertical, DS.Space.xs + 1)
            .background(.thinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
    }
}
