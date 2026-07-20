import SwiftUI

/// App-icon-style brand lockup for the sign-in screen.
///
/// The mark is the same transparent logo-only artwork used by the icon foreground, deliberately
/// avoiding the wordmark in the cropped app icon while still presenting the Labstream name on
/// screen.
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

            HStack(spacing: 0) {
                Text("Lab")
                Text("stream")
                    .foregroundStyle(DS.Brand.amber)
            }
            #if os(tvOS)
            .font(.system(size: 58, weight: .bold, design: .rounded))
            #else
            .font(.largeTitle.bold())
            #endif
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Labstream")
        }
    }

    private var brandMark: some View {
        ZStack {
            logoTileShape
                .fill(DS.Brand.iconPlateGradient)
            logoTileShape
                .strokeBorder(.white.opacity(0.14), lineWidth: 0.75)

            Image("LabstreamGlyph")
                .resizable()
                .scaledToFit()
                .frame(width: markSide * 0.7, height: markSide * 0.7)
        }
        .frame(width: markSide, height: markSide)
        .shadow(color: .black.opacity(0.32), radius: 14, x: 0, y: 8)
    }

    private var logoTileShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: (DS.Radius.card + 14) * (markSide / 112), style: .continuous)
    }
}

/// Compact iPhone's setup-style header. It deliberately avoids repeating the large,
/// centered welcome lockup used by the regular-width card: on a phone that treatment
/// consumed the top half of the screen and made the rest of the flow feel bolted on.
struct CompactLoginHeader: View {
    var body: some View {
        HStack(spacing: DS.Space.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(DS.Brand.iconPlateGradient)
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(.white.opacity(0.24), lineWidth: 0.5)
                    }

                Image("LabstreamGlyph")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 36, height: 36)
            }
            .frame(width: 56, height: 56)

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

/// Full-bleed branded login backdrop for iOS. In light appearance, a subtle veil keeps
/// the gradient from fighting adaptive light panels while preserving the Labstream color.
struct LoginBrandBackdrop: View {
    #if os(iOS)
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    var body: some View {
        #if os(iOS)
        if horizontalSizeClass == .compact {
            // A full teal slab made the phone login read as a splash screen and
            // swallowed the segmented backend picker. Keep the native grouped
            // surface, with only a quiet brand wash behind the onboarding content.
            Color(uiColor: .systemGroupedBackground)
                .ignoresSafeArea()
                .overlay(alignment: .top) {
                    LinearGradient(colors: [
                        DS.Brand.deepTeal.opacity(colorScheme == .light ? 0.14 : 0.28),
                        Color.clear
                    ], startPoint: .top, endPoint: .bottom)
                    .frame(height: 430)
                    .ignoresSafeArea(edges: .top)
                }
        } else {
            DS.Brand.iconPlateGradient
                .ignoresSafeArea()
                .overlay {
                    if colorScheme == .light {
                        Color.white.opacity(0.10)
                            .ignoresSafeArea()
                    }
                }
            }
        #else
        DS.Brand.iconPlateGradient
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
