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
        #if os(iOS)
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
            .font(.largeTitle.bold())
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

/// Full-bleed branded login backdrop for iOS. In light appearance, a subtle veil keeps
/// the gradient from fighting adaptive light panels while preserving the Labstream color.
struct LoginBrandBackdrop: View {
    #if os(iOS)
    @Environment(\.colorScheme) private var colorScheme
    #endif

    var body: some View {
        #if os(iOS)
        DS.Brand.iconPlateGradient
            .ignoresSafeArea()
            .overlay {
                if colorScheme == .light {
                    Color.white.opacity(0.10)
                        .ignoresSafeArea()
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
