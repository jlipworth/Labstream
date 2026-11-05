import SwiftUI

/// The app icon in miniature: the black tile with the white L. `LabstreamGlyph` uses the app
/// icon's own 1024-pt canvas and L placement (`scripts/generate-brand-assets.py`), so it fills
/// the whole tile and stays optically identical to the Home Screen icon.
struct BrandMarkTile: View {
    let side: CGFloat
    let cornerRadius: CGFloat
    var strokeOpacity: Double = 0.14
    var strokeWidth: CGFloat = 0.75

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(DS.Brand.ink)
            Image("LabstreamGlyph")
                .resizable()
                .scaledToFit()
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(DS.Brand.paper.opacity(strokeOpacity), lineWidth: strokeWidth)
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}

/// App-icon-style brand lockup for the sign-in screen: the icon tile above a one-color
/// "Labstream" wordmark (the logo is pure black and white; no accent half).
struct LoginBrandHeader: View {
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    /// Slightly smaller lockup on compact phones so the sign-in form keeps room
    /// above the keyboard; regular width keeps the authored visionOS/iPad size.
    private var markSide: CGFloat {
        #if os(tvOS)
        148
        #elseif os(iOS)
        horizontalSizeClass == .compact ? 84 : 112
        #else
        112
        #endif
    }

    var body: some View {
        VStack(spacing: DS.Space.md) {
            brandMark

            Text("Labstream")
            #if os(tvOS)
            .font(.system(size: 58, weight: .bold, design: .rounded))
            #else
            .font(.largeTitle.bold())
            #endif
            .lineLimit(1)
            .minimumScaleFactor(0.6)
        }
    }

    private var brandMark: some View {
        BrandMarkTile(side: markSide, cornerRadius: (DS.Radius.card + 14) * (markSide / 112))
            .shadow(color: .black.opacity(0.32), radius: 14, x: 0, y: 8)
    }
}

/// Compact iPhone's setup-style header. It deliberately avoids repeating the large,
/// centered welcome lockup used by the regular-width card: on a phone that treatment
/// consumed the top half of the screen and made the rest of the flow feel bolted on.
struct CompactLoginHeader: View {
    var body: some View {
        HStack(spacing: DS.Space.md) {
            BrandMarkTile(side: 56, cornerRadius: 16, strokeOpacity: 0.24, strokeWidth: 0.5)

            VStack(alignment: .leading, spacing: 2) {
                Text("Labstream")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.primary)

                Text("Connect your media library.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Labstream. Connect your media library.")
    }
}

/// Full-bleed branded login backdrop: the graphite-to-black brand gradient. On iPad in light
/// appearance a subtle veil keeps it from fighting the adaptive light panels.
struct LoginBrandBackdrop: View {
    #if os(iOS)
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    var body: some View {
        #if os(iOS)
        if horizontalSizeClass == .compact {
            // A full brand slab made the phone login read as a splash screen and
            // swallowed the segmented backend picker. Keep the native grouped
            // surface, with only a quiet neutral wash behind the onboarding content.
            Color(uiColor: .systemGroupedBackground)
                .ignoresSafeArea()
                .overlay(alignment: .top) {
                    LinearGradient(colors: [
                        DS.Brand.wash.opacity(colorScheme == .light ? 0.18 : 0.28),
                        Color.clear
                    ], startPoint: .top, endPoint: .bottom)
                    .frame(height: 430)
                    // Extend under the top AND both side insets. Top-only left the wash
                    // stopping at the trailing safe edge, which on the folded iPhone Duo
                    // (vertical status bar on the trailing edge) cut it off short of the
                    // screen as a visible box.
                    .ignoresSafeArea(edges: [.top, .horizontal])
                }
        } else {
            DS.Brand.backdropGradient
                .ignoresSafeArea()
                .overlay {
                    if colorScheme == .light {
                        Color.white.opacity(0.10)
                            .ignoresSafeArea()
                    }
                }
            }
        #else
        DS.Brand.backdropGradient
            .ignoresSafeArea()
        #endif
    }
}

/// Shared visual container for the sign-in panel.
struct LoginPanelBackground: View {
    #if os(iOS)
    @Environment(\.colorScheme) private var colorScheme
    #endif

    var body: some View {
        panelShape
            .fill(panelFill)
            .background(.regularMaterial, in: panelShape)
            .overlay(panelShape.strokeBorder(panelStroke, lineWidth: 0.5))
    }

    private var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
    }

    private var panelFill: Color {
        #if os(iOS)
        colorScheme == .light ? Color.white.opacity(0.72) : Color.black.opacity(0.58)
        #else
        Color.black.opacity(0.58)
        #endif
    }

    private var panelStroke: Color {
        #if os(iOS)
        colorScheme == .light ? Color.black.opacity(0.08) : Color.white.opacity(0.10)
        #else
        Color.white.opacity(0.10)
        #endif
    }
}
