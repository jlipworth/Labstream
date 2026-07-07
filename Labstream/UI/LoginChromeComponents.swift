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

/// Shared visual container for the sign-in panel.
struct LoginPanelBackground: View {
    var body: some View {
        panelShape
            .fill(Color.black.opacity(0.58))
            .background(.regularMaterial, in: panelShape)
            .overlay(panelShape.strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
    }

    private var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
    }
}
