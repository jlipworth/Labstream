import PMSKit
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

    /// Section title over a rail, a song list or a result group. iPhone/iPad use the single
    /// Title style of the three-style type pass (`.title3` semibold, iPhone Duo design spec,
    /// Color & type); tvOS and visionOS/macOS keep their authored sizes.
    static func railSectionTitleFont(compact: Bool) -> Font {
        #if os(tvOS)
        // TV type sizes run big: title3 (48pt) dwarfs the cards beneath it.
        .headline
        #elseif os(iOS)
        .title3.weight(.semibold)
        #else
        compact ? .title3.bold() : .title2.bold()
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

/// Display envelopes for numeric values that update in place. These are deliberately semantic:
/// callers choose the largest honest shape their field supports rather than scattering unrelated
/// magic widths. Widths scale with Dynamic Type and reserve punctuation/unit transitions that
/// `.monospacedDigit()` alone cannot reserve.
enum HotMetricEnvelope: Sendable {
    case percent
    case rate
    case annotatedRate
    case bytes
    case storageTotal
    case duration
    case bitrate
    case annotatedBitrate
    case counter

    var baseWidth: CGFloat {
        switch self {
        case .percent: 42       // "~100%"
        case .rate: 82          // "999.9 MB/s"
        case .annotatedRate: 132 // "999.9 MB/s server-paced"
        case .bytes: 108        // "999.9 GB media/extras"
        case .storageTotal: 72  // "999.9 GB"
        case .duration: 82      // "~23h 59m"
        case .bitrate: 96       // "999.9 Mbps"
        case .annotatedBitrate: 150 // "idle (last 999.9 Mbps)"
        case .counter: 52       // common 4–5 digit counters
        }
    }
}

private struct StableHotMetricModifier: ViewModifier {
    let envelope: HotMetricEnvelope
    let alignment: Alignment
    @ScaledMetric(relativeTo: .caption) private var scale = 1.0

    func body(content: Content) -> some View {
        // Width grows for accessibility sizes, but a semantic field must not become wider than
        // the compact phone row that is meant to stack it. Text may scale down visually inside
        // this capped envelope; call sites retain the full accessibility value.
        let boundedScale = min(scale, 1.35)
        content
            .monospacedDigit()
            .frame(width: envelope.baseWidth * boundedScale, alignment: alignment)
    }
}

extension View {
    /// Stabilize an in-place numeric field, including decimal separators and unit shape.
    ///
    /// Keep the full value in `accessibilityValue` at the call site when a visual field also uses
    /// line limiting or abbreviation for a compact presentation.
    func stableHotMetric(
        _ envelope: HotMetricEnvelope,
        alignment: Alignment = .trailing
    ) -> some View {
        modifier(StableHotMetricModifier(envelope: envelope, alignment: alignment))
    }
}

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

#if os(tvOS)
extension View {
    /// `prefersDefaultFocus` behind an optional namespace, so rails shared across hosts
    /// can mark a default-focus card only when their screen provides a focus scope.
    @ViewBuilder
    func tvPrefersDefaultFocus(_ prefers: Bool, in namespace: Namespace.ID?) -> some View {
        if let namespace {
            prefersDefaultFocus(prefers, in: namespace)
        } else {
            self
        }
    }

    /// `focused(_:equals:)` behind an optional binding — grids that redirect directional
    /// entry (`prefersDefaultFocus` only governs initial/programmatic focus, not dpad
    /// entry) track per-card focus this way, while other hosts of the same cell pass nil.
    @ViewBuilder
    func tvFocusTracked<Value: Hashable>(_ binding: FocusState<Value?>.Binding?,
                                         equals value: Value) -> some View {
        if let binding {
            focused(binding, equals: value)
        } else {
            self
        }
    }
}

/// Bare tvOS button chrome for poster/card lockups: renders the label with no system
/// focus platter or lift. A custom ButtonStyle on tvOS still participates in the focus
/// engine and receives Select (proven by the player's hidden-surface owner); the visible
/// focus treatment is drawn by `tvFocusHighlight` on the artwork inside the label.
private struct TVPosterCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

/// Explicit tvOS focus treatment for card artwork: a white ring, a gentle lift, and a
/// drop shadow whenever the enclosing focusable (the card's button) holds focus. Owned
/// by us — unlike `.borderless`'s image lift — so the highlight is unmistakable from
/// couch distance and identical across poster, still, and chapter cards.
private struct TVFocusHighlight: ViewModifier {
    @Environment(\.isFocused) private var isFocused
    var cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.white, lineWidth: isFocused ? 4 : 0)
            }
            .scaleEffect(isFocused ? 1.07 : 1.0)
            .shadow(color: .black.opacity(isFocused ? 0.45 : 0), radius: 16, y: 10)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isFocused)
    }
}
#endif

extension View {
    /// tvOS: draw the standard focus ring + lift on this artwork view when the nearest
    /// focusable ancestor (its card's button) is focused. No-op on other platforms.
    @ViewBuilder
    func tvFocusHighlight(cornerRadius: CGFloat = DS.Radius.poster) -> some View {
        #if os(tvOS)
        modifier(TVFocusHighlight(cornerRadius: cornerRadius))
        #else
        self
        #endif
    }

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
        // whole label — oversized and washed-out behind image cards — and `.card` draws its
        // own platter around the full label too (a visible border above/behind poster
        // captions). `.borderless` lifts only the image, which proved too subtle to track
        // from across a room. Poster lockups therefore use a bare custom style and draw
        // their own focus ring + lift at the artwork level via `tvFocusHighlight`.
        // Chip-radius rows (song results) keep `.card` because their labels are mostly
        // text and have no artwork to carry a highlight.
        if cornerRadius == DS.Radius.chip {
            self.buttonStyle(.card)
        } else {
            self.buttonStyle(TVPosterCardButtonStyle())
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

    /// Prominent variant of `labstreamGlassButtonStyle`. Do not force a hard-coded label
    /// foreground here: `.glassProminent` and `.borderedProminent` derive contrast
    /// from the active tint/material context, and hard-coded black is wrong for dark
    /// platform surfaces.
    ///
    /// iPhone/iPad: the prominent capsule (Play/Resume, sign-in, Reconnect) is filled with the
    /// label color with the background color as its text — the TV app's white Play capsule in
    /// dark mode — because amber means "selected" only (iPhone Duo design spec, Color & type).
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
            .tint(.primary)
            .foregroundStyle(Color(uiColor: .systemBackground))
        #endif
    }

    /// Shared media-rail scroll content insets. Use with
    /// `ScrollView(.horizontal, showsIndicators: false)` to keep horizontal rails consistent.
    /// With no explicit margin the modifier resolves the compact-aware default from the
    /// environment, so a bare `.mediaRailScrollStyle()` can't silently burn the 32-pt
    /// regular margin on a 390-pt phone.
    ///
    /// iPhone/iPad (iPhone Duo design spec, global rule 6, Resolved decision 1): the rail's
    /// viewport is its own layout frame, which is the content region — the vertical bar's inset
    /// is already outside it on whichever edge carries the bar. Cards are clipped there
    /// horizontally, so at rest no card, title or year rests under the bar, while the leading
    /// and trailing content margins stay equal so the last card scrolls fully into view and stops
    /// one margin short of the bar. Vertically the rail keeps drawing past its frame (shadows,
    /// hover lift) through `verticalOverflow`. `clipDisabled: false` keeps a hard clip on all
    /// four edges. Other platforms keep their authored pass-through behaviour.
    func mediaRailScrollStyle(horizontalMargin: CGFloat? = nil,
                              clipDisabled: Bool = true) -> some View {
        modifier(MediaRailScrollStyleModifier(horizontalMargin: horizontalMargin,
                                              clipDisabled: clipDisabled))
    }

    /// Reports a rail viewport's measured width (the content region a rail lays out in) for
    /// `DS.Poster.measuredRailWidth`.
    func railViewportWidth(_ width: Binding<CGFloat?>) -> some View {
        onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newWidth in
            if width.wrappedValue != newWidth { width.wrappedValue = newWidth }
        }
    }

    /// Keeps a rail's first visible card across a fold, unfold or resize (global rule 9). The
    /// rail's stack must carry `.railScrollTargetLayout()`. iPhone/iPad only; other platforms
    /// keep their authored focus/scroll behaviour.
    @ViewBuilder
    func railScrollAnchor(_ id: Binding<String?>) -> some View {
        #if os(iOS)
        self.scrollPosition(id: id, anchor: .leading)
        #else
        self
        #endif
    }

    /// Marks a rail's lazy stack as the scroll-target layout for `railScrollAnchor`.
    @ViewBuilder
    func railScrollTargetLayout() -> some View {
        #if os(iOS)
        self.scrollTargetLayout()
        #else
        self
        #endif
    }
}

extension DS.Poster {
    /// Rail poster width from the measured rail viewport (global rule 7: whole cards plus a
    /// ~30% cue, clamped per family). Falls back to the authored constant before the first
    /// measurement and on every non-iOS platform, whose rails keep their authored widths.
    static func measuredRailWidth(viewport: CGFloat?, compact: Bool,
                                  margin: CGFloat, gutter: CGFloat) -> CGFloat {
        #if os(iOS)
        guard let viewport, viewport > 0 else { return railWidth(compact: compact) }
        let metrics = RailCardMetrics.metrics(viewportWidth: Double(viewport),
                                              margin: Double(margin),
                                              gutter: Double(gutter),
                                              family: .poster(compact: compact))
        return CGFloat(metrics.cardWidth)
        #else
        return railWidth(compact: compact)
        #endif
    }

    /// 16:9 landscape rail card width from the measured viewport (global rule 7, landscape
    /// family). `fallback` is the authored width used before the first measurement.
    static func measuredLandscapeRailWidth(viewport: CGFloat?, compact: Bool,
                                           margin: CGFloat, gutter: CGFloat,
                                           fallback: CGFloat) -> CGFloat {
        guard let viewport, viewport > 0 else { return fallback }
        let metrics = RailCardMetrics.metrics(viewportWidth: Double(viewport),
                                              margin: Double(margin),
                                              gutter: Double(gutter),
                                              family: .landscape(compact: compact))
        return CGFloat(metrics.cardWidth)
    }
}

/// Clips a rail at its layout frame horizontally while letting it draw `verticalOverflow`
/// points above and below (poster shadows and lift).
private struct RailViewportClip: Shape {
    let verticalOverflow: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(rect.insetBy(dx: 0, dy: -verticalOverflow))
    }
}

private struct MediaRailScrollStyleModifier: ViewModifier {
    let horizontalMargin: CGFloat?
    let clipDisabled: Bool

    @Environment(\.labstreamCompactWidth) private var compactWidth

    func body(content: Content) -> some View {
        let margined = content
            .contentMargins(.horizontal,
                            horizontalMargin ?? DS.Scroll.railHorizontalMargin(compact: compactWidth),
                            for: .scrollContent)
        #if os(iOS)
        margined
            .scrollClipDisabled(true)
            .clipShape(RailViewportClip(verticalOverflow: clipDisabled ? DS.Space.xxxl : 0))
            // A clip shape does not clip hit testing: the clipped cue card stayed tappable
            // through the empty stretch of the vertical bar's column. Hit-test the rail's own
            // layout frame (the content region) only, without the shadow overflow, so the
            // overflow never steals taps from the header above or the next shelf.
            .contentShape(Rectangle())
        #else
        margined
            .scrollClipDisabled(clipDisabled)
        #endif
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
