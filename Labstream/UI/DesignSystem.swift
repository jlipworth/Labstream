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
    /// Shared brand palette sampled from the Labstream mark. Keep these in one
    /// place so the welcome screen, icon previews, and any future empty states
    /// use the same identity instead of slightly different blues/ambers.
    enum Brand {
        static let blue = Color(red: 0.00, green: 0.64, blue: 1.00)
        static let amber = Color(red: 1.00, green: 0.72, blue: 0.20)
        static let coral = Color(red: 1.00, green: 0.27, blue: 0.29)
        static let deepTeal = Color(red: 0.03, green: 0.28, blue: 0.34)
        static let midnight = Color(red: 0.02, green: 0.09, blue: 0.13)

        static var iconPlateGradient: LinearGradient {
            LinearGradient(colors: [
                Color(red: 0.18, green: 0.49, blue: 0.58),
                deepTeal,
                midnight
            ], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

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
    ///
    /// Two size families: the bare constants are the visionOS/iPad values the app was
    /// authored against; `Compact` holds the iPhone-class counterparts (a 184-pt rail
    /// poster is half a phone screen). Views pick via the `compact:`-parameterized
    /// accessors, driven by `\.labstreamCompactWidth`.
    enum Poster {
        /// The 2:3 aspect ratio shared by rail and grid posters.
        static let aspect: CGFloat = 2.0 / 3.0
        /// Default rail/grid poster width in points.
        static let railWidth: CGFloat = 184
        static let gridMin: CGFloat = 168
        static let gridMax: CGFloat = 208
        /// Detail-screen hero poster width.
        static let detailWidth: CGFloat = 300

        /// Compact-width (iPhone) poster sizes: ~3 grid columns / ~3.3 rail posters
        /// visible on a 390-pt screen, in line with phone-class media apps.
        enum Compact {
            static let railWidth: CGFloat = 110
            static let gridMin: CGFloat = 104
            static let gridMax: CGFloat = 150
            /// Compact detail/now-playing hero — the 300-pt hero plus page padding
            /// overflows a 390-pt screen.
            static let detailWidth: CGFloat = 220
        }

        static func railWidth(compact: Bool) -> CGFloat {
            #if os(tvOS)
            236
            #else
            compact ? Compact.railWidth : railWidth
            #endif
        }
        static func gridMin(compact: Bool) -> CGFloat {
            #if os(tvOS)
            220
            #else
            compact ? Compact.gridMin : gridMin
            #endif
        }
        static func gridMax(compact: Bool) -> CGFloat {
            #if os(tvOS)
            260
            #else
            compact ? Compact.gridMax : gridMax
            #endif
        }
        static func detailWidth(compact: Bool) -> CGFloat {
            #if os(tvOS)
            360
            #else
            compact ? Compact.detailWidth : detailWidth
            #endif
        }

        /// Height for a given poster width at the canonical 2:3 ratio.
        static func height(for width: CGFloat) -> CGFloat { width / aspect }
    }

    /// Canonical scroll rhythm for media rails. Horizontal rails should hide scroll indicators
    /// unless a screen documents a deliberate exception; the initializer owns that policy while
    /// this modifier centralizes the shared margins and hover breathing room.
    enum Scroll {
        #if os(tvOS)
        static let railHorizontalMargin: CGFloat = 80
        #else
        static let railHorizontalMargin = Space.xxl
        #endif
        static let compactRailHorizontalMargin = Space.md

        static func railHorizontalMargin(compact: Bool) -> CGFloat {
            compact ? compactRailHorizontalMargin : railHorizontalMargin
        }
    }

    /// Grid gutters: the 24-pt visionOS/iPad gutter would push a compact grid down to
    /// two columns, so compact width tightens to the 12-pt phone gutter.
    static func gridGutter(compact: Bool) -> CGFloat {
        #if os(tvOS)
        36
        #else
        compact ? Space.md : Space.xl
        #endif
    }
    /// Screen-edge padding around grids/pages: 24-pt regular, 16-pt compact.
    static func pagePadding(compact: Bool) -> CGFloat {
        #if os(tvOS)
        80
        #else
        compact ? Space.lg : Space.xl
        #endif
    }

    /// Soft, layered shadow used under posters and cards to lift them off the glass
    /// without looking heavy. visionOS already has real depth; this is a gentle hint.
    static func posterShadow<S: Shape>(_ shape: S) -> some View {
        shape.fill(.clear)
            .shadow(color: .black.opacity(0.35), radius: 14, x: 0, y: 10)
    }
}

extension EnvironmentValues {
    /// One shared definition of "phone-class width": true when the horizontal size
    /// class is compact (iPhone, narrow iPad split view). visionOS windows never
    /// report compact, so this is always false there — the authored visionOS/iPad
    /// metrics remain untouched on that platform by construction.
    var labstreamCompactWidth: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact
        #else
        false
        #endif
    }
}

// MARK: - Reusable view modifiers

/// Lifts a poster/card on visionOS hover: a subtle scale + brighten that gives the
/// browse grid the same tactile, gaze-responsive feel as Apple's own media apps.
/// Hover is the primary "where am I looking" cue on visionOS, so every tappable
/// poster gets it for free via `.posterHover()`. iPad pointer hover is handled by
/// `cardLink`'s platform-native `.hoverEffect(.lift)` instead of stacking this custom
/// scale/shadow animation on top.
#if os(visionOS)
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
#endif

extension View {
    /// Apply the standard poster hover lift. Purely visual; does not affect hit-testing.
    @ViewBuilder
    func posterHover() -> some View {
        #if os(visionOS)
        modifier(PosterHoverEffect())
        #else
        self
        #endif
    }

    /// visionOS-safe style for poster/card `NavigationLink`s. MUST ride a BUILT-IN
    /// button style: any custom `ButtonStyle` gets its gaze/hover region registered
    /// displaced (~1.35× about the window center), so pinches on a rail card route to
    /// a NEIGHBOR card — proven live by bisection, see the gotcha in
    /// docs/DEVELOPMENT.md. `.plain` registers through the correct path and routes
    /// clicks accurately; the `contentShape(.hoverEffect, …)` reshapes its automatic
    /// system highlight to the card's rounded rect.
    @ViewBuilder
    func cardLink(cornerRadius: CGFloat = DS.Radius.poster) -> some View {
        #if os(visionOS)
        self.buttonStyle(.plain)
            .contentShape(.hoverEffect,
                          RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        #elseif os(iOS)
        // iPad pointer idiom: cards lift under the cursor, like Home Screen icons.
        self.buttonStyle(.plain)
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .contentShape(.hoverEffect,
                          RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .hoverEffect(.lift)
        #elseif os(tvOS)
        // The plain style's default tvOS focus treatment is a white platter sized to the
        // whole label — oversized and washed-out behind image cards. `.card` draws its own
        // platter around the full label too (visible as a border above/behind poster text),
        // so image lockups use `.borderless`: tvOS lifts the image itself on focus and
        // leaves the caption text platter-free. Chip-radius rows (song results) keep `.card`
        // because their labels are mostly text and borderless would leave focus invisible.
        if cornerRadius == DS.Radius.chip {
            self.buttonStyle(.card)
        } else {
            self.buttonStyle(.borderless)
        }
        #else
        self.buttonStyle(.plain)
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        #endif
    }

    /// A persistent labelled tab bar already names top-level tvOS destinations. Repeating that
    /// label as a large navigation title burns vertical space without adding information.
    @ViewBuilder
    func labstreamTopLevelNavigationTitle(_ title: String) -> some View {
        #if os(tvOS)
        self
        #else
        self.navigationTitle(title)
        #endif
    }

    /// Platform glass platter. visionOS keeps `glassBackgroundEffect` (materials render
    /// flat and z-fight window edges there); iOS 26 uses Liquid Glass proper.
    @ViewBuilder
    func labstreamGlassBackground<S: InsettableShape>(in shape: S) -> some View {
        #if os(visionOS)
        self.glassBackgroundEffect(in: shape)
        #else
        self.glassEffect(.regular, in: shape)
        #endif
    }

    /// Platter behind controls that float over media (player chrome). visionOS keeps its
    /// proven material look; iOS 26 uses Liquid Glass, the platform idiom for controls
    /// layered above content.
    @ViewBuilder
    func labstreamOverlayPlatter<S: InsettableShape>(_ material: Material = .ultraThinMaterial,
                                                     in shape: S) -> some View {
        #if os(visionOS)
        self.background(material, in: shape)
        #else
        self.glassEffect(.regular, in: shape)
        #endif
    }

    /// Secondary glass button: visionOS `.bordered` (already a glass platter there),
    /// iOS 26 `.glass` (Liquid Glass). Leave tint inheritance to the surrounding
    /// context so the platform can choose the right accent/contrast for toolbar,
    /// login, and player chrome instead of globally forcing every secondary button
    /// into a neutral monochrome treatment.
    @ViewBuilder
    func labstreamGlassButtonStyle() -> some View {
        #if os(visionOS)
        self.buttonStyle(.bordered)
        #elseif os(tvOS)
        self.buttonStyle(.bordered)
        #elseif os(macOS)
        self.buttonStyle(.bordered)
        #else
        self.buttonStyle(.glass)
        #endif
    }

    /// Prominent variant of `labstreamGlassButtonStyle`. Do not force a global label
    /// foreground here: `.glassProminent` and `.borderedProminent` derive contrast
    /// from the active tint/material context, and hard-coded black is wrong for dark
    /// platform surfaces.
    @ViewBuilder
    func labstreamGlassProminentButtonStyle() -> some View {
        #if os(visionOS)
        self.buttonStyle(.borderedProminent)
        #elseif os(tvOS)
        self.buttonStyle(.borderedProminent)
        #elseif os(macOS)
        self.buttonStyle(.borderedProminent)
        #else
        self.buttonStyle(.glassProminent)
        #endif
    }

    /// Shared media-rail scroll content insets. Use with
    /// `ScrollView(.horizontal, showsIndicators: false)` to keep horizontal rails consistent.
    /// With no explicit margin the modifier resolves the compact-aware default from the
    /// environment, so a bare `.mediaRailScrollStyle()` can't silently burn the 32-pt
    /// regular margin on a 390-pt phone.
    func mediaRailScrollStyle(horizontalMargin: CGFloat? = nil,
                              clipDisabled: Bool = true) -> some View {
        modifier(MediaRailScrollStyleModifier(horizontalMargin: horizontalMargin,
                                              clipDisabled: clipDisabled))
    }
}

private struct MediaRailScrollStyleModifier: ViewModifier {
    let horizontalMargin: CGFloat?
    let clipDisabled: Bool

    @Environment(\.labstreamCompactWidth) private var compactWidth

    func body(content: Content) -> some View {
        content
            .contentMargins(.horizontal,
                            horizontalMargin ?? DS.Scroll.railHorizontalMargin(compact: compactWidth),
                            for: .scrollContent)
            .scrollClipDisabled(clipDisabled)
    }
}

/// A pill-shaped spec/metadata chip used across Detail and cards. Centralised so the
/// "4K · HEVC · 24 Mbps" style badges look identical everywhere they appear.
struct SpecChip: View {
    let text: String
    var monospaced: Bool = false

    var body: some View {
        Text(text)
            .font(specFont)
            .padding(.horizontal, DS.Space.md)
            .padding(.vertical, DS.Space.xs + 1)
            .background(.thinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
    }

    private var specFont: Font {
        #if os(tvOS)
        monospaced ? .callout.monospaced() : .callout.weight(.medium)
        #else
        monospaced ? .caption.monospaced() : .caption.weight(.medium)
        #endif
    }
}
