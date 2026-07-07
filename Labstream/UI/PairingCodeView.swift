import SwiftUI

/// Shared glass pairing-code presentation for Plex link, Jellyfin Quick Connect,
/// and Emby Connect PIN flows.
struct PairingCodeCells: View {
    let code: String
    let width: CGFloat
    let height: CGFloat
    let fontSize: CGFloat

    private var cellShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DS.Radius.poster, style: .continuous)
    }

    var body: some View {
        HStack(spacing: DS.Space.md) {
            ForEach(Array(code.enumerated()), id: \.offset) { _, character in
                Text(String(character))
                    .font(.system(size: fontSize, weight: .semibold, design: .monospaced))
                    .frame(width: width, height: height)
                    .background(.thinMaterial, in: cellShape)
                    .overlay(cellShape.strokeBorder(.primary.opacity(0.10), lineWidth: 0.5))
            }
        }
        .padding(.vertical, DS.Space.xs)
    }
}

/// Shared "enter this code / waiting for authorization" screen used by device-friendly
/// backend pairing-code flows. Callers provide backend-specific instructions and fallback action.
struct PairingCodeView<Header: View>: View {
    let code: String
    let cellWidth: CGFloat
    let cellHeight: CGFloat
    let fontSize: CGFloat
    let fallbackTitle: String?
    let onFallback: (() -> Void)?
    @ViewBuilder let header: Header

    init(code: String,
         cellWidth: CGFloat = 64,
         cellHeight: CGFloat = 82,
         fontSize: CGFloat = 44,
         fallbackTitle: String? = nil,
         onFallback: (() -> Void)? = nil,
         @ViewBuilder header: () -> Header) {
        self.code = code
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.fontSize = fontSize
        self.fallbackTitle = fallbackTitle
        self.onFallback = onFallback
        self.header = header()
    }

    var body: some View {
        VStack(spacing: DS.Space.lg) {
            header

            PairingCodeCells(code: code, width: cellWidth, height: cellHeight, fontSize: fontSize)

            HStack(spacing: DS.Space.sm) {
                ProgressView()
                Text("Waiting for authorization…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let fallbackTitle, let onFallback {
                Button(fallbackTitle, action: onFallback)
                    .labstreamGlassButtonStyle()
            }
        }
    }
}
