import SwiftUI

struct CustomTransportStatusOverlay: View {
    let status: PlaybackTransportStatus
    let onRetry: () -> Void
    let onClose: (() -> Void)?
    let onTogglePause: () -> Void
    /// On a compact phone (and a 320-pt Slide Over pane) a fixed 340-pt platter overflows the
    /// 40-pt-padded region, so cap instead of pinning the width there. Regular width / visionOS
    /// keep the exact 340-pt platter.
    var isCompact: Bool = false

    private var title: String {
        switch status {
        case .none: ""
        case .buffering: "Buffering…"
        case .pausedBuffering: "Paused — buffering…"
        case .reconnecting: "Reconnecting…"
        case .failed: "Playback failed"
        }
    }

    private var detail: String? {
        switch status {
        case .none:
            nil
        case .buffering:
            "You can pause now and let the stream build buffer before playing."
        case .pausedBuffering:
            "Playback will stay paused once the stream is ready."
        case .reconnecting:
            nil
        case .failed(let message):
            message?.isEmpty == false ? message : nil
        }
    }

    var body: some View {
        VStack(spacing: statusSpacing) {
            switch status {
            case .failed:
                Label(title, systemImage: "exclamationmark.triangle")
                    .font(titleFont)
            default:
                ProgressView()
                    .controlSize(.large)
                Text(title)
                    .font(titleFont)
            }
            if let detail {
                Text(detail)
                    .font(detailFont)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            switch status {
            case .buffering, .pausedBuffering:
                Button {
                    onTogglePause()
                } label: {
                    Label(isPausedBuffering ? "Resume when ready" : "Pause",
                          systemImage: isPausedBuffering ? "play.fill" : "pause.fill")
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                }
                .playerTransportProminentButtonStyle()
                .controlSize(statusControlSize)
            case .reconnecting:
                if let onClose {
                    Button(role: .cancel, action: onClose) {
                        Text("Close")
                            .frame(width: 150)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }
            case .failed:
                VStack(spacing: 8) {
                    Button(action: onRetry) {
                        Label("Retry", systemImage: "arrow.clockwise")
                            .frame(minWidth: 160)
                    }
                    .playerTransportProminentButtonStyle()
                    if let onClose {
                        Button(action: onClose) {
                            Text("Close")
                                .frame(minWidth: 160)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.top, 2)
            case .none:
                EmptyView()
            }
        }
        .padding(.horizontal, statusHorizontalPadding)
        .padding(.vertical, statusVerticalPadding)
        .frame(maxWidth: statusWidth)
        .frame(width: isCompact ? nil : statusWidth)
        .labstreamOverlayPlatter(in: RoundedRectangle(cornerRadius: statusCornerRadius, style: .continuous))
        .shadow(radius: 18)
    }

    private var statusWidth: CGFloat {
        #if os(tvOS)
        // Wide enough that the buffering guidance runs one to two lines instead of
        // stacking into a tall narrow card at TV viewing distance.
        760
        #else
        340
        #endif
    }

    private var statusSpacing: CGFloat {
        #if os(tvOS)
        18
        #else
        14
        #endif
    }

    private var statusHorizontalPadding: CGFloat {
        #if os(tvOS)
        38
        #else
        24
        #endif
    }

    private var statusVerticalPadding: CGFloat {
        #if os(tvOS)
        30
        #else
        22
        #endif
    }

    private var statusCornerRadius: CGFloat {
        #if os(tvOS)
        28
        #else
        24
        #endif
    }

    private var titleFont: Font {
        #if os(tvOS)
        .title3.weight(.semibold)
        #else
        .headline
        #endif
    }

    private var detailFont: Font {
        #if os(tvOS)
        .callout
        #else
        .caption
        #endif
    }

    private var statusControlSize: ControlSize {
        #if os(tvOS)
        .regular
        #else
        .small
        #endif
    }

    private var isPausedBuffering: Bool {
        if case .pausedBuffering = status { return true }
        return false
    }
}

private extension View {
    /// Player status CTAs live under the iOS player-wide `.tint(.white)`. Plainly inheriting that
    /// into `.glassProminent` can produce a low-contrast white-on-white buffering action, so pin the
    /// label to dark text only for these high-contrast monochrome player status buttons.
    @ViewBuilder
    func playerTransportProminentButtonStyle() -> some View {
        #if os(visionOS)
        self.labstreamGlassProminentButtonStyle()
        #else
        self.buttonStyle(.glassProminent)
            .tint(.white)
            .foregroundStyle(.black)
        #endif
    }
}
