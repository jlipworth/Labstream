import SwiftUI

/// Size class of the transport-status overlay. tvOS, visionOS, and macOS always use `.standard`
/// (their established card sizing); iOS/iPadOS resolves from the chrome's size classes and
/// measured viewport so the card fits the phone/tablet it is on.
enum PlayerTransportStatusLayout: Equatable {
    case standard
    /// iPad (or any regular-width, regular-height) viewport.
    case regular
    /// Compact width with regular height: iPhone portrait, iPad Slide Over / narrow split.
    case compact(availableWidth: CGFloat)
    /// Compact height: iPhone landscape. Tight vertical rhythm so the card clears the scrubber.
    case compactHeight(availableWidth: CGFloat)

    static func resolve(usesCompactChrome: Bool,
                        isCompactHeight: Bool,
                        availableWidth: CGFloat) -> PlayerTransportStatusLayout {
        if isCompactHeight { return .compactHeight(availableWidth: availableWidth) }
        if usesCompactChrome { return .compact(availableWidth: availableWidth) }
        return .regular
    }

    /// Card width. Compact layouts scale with the measured viewport instead of pinning a fixed
    /// platter that overflows narrow panes.
    var cardWidth: CGFloat {
        switch self {
        case .standard:
            #if os(tvOS)
            // Wide enough that the buffering guidance runs one to two lines instead of
            // stacking into a tall narrow card at TV viewing distance.
            return 760
            #else
            return 340
            #endif
        case .regular:
            return 420
        case .compact(let width):
            guard width > 0 else { return 320 }
            return max(240, min(width - 48, 380))
        case .compactHeight(let width):
            guard width > 0 else { return 360 }
            return max(260, min(width * 0.55, 400))
        }
    }

}

/// Transport status over the player (see PLAYBACK-ARCHITECTURE.md, "Buffering and stalls").
/// `PlaybackTransportStatusState` owns all timing; this view only renders `status` at `stage`:
/// stage 1 is a spinner without a platter, stage 2 the full card with copy and actions.
struct CustomTransportStatusOverlay: View {
    let status: PlaybackTransportStatus
    var stage: PlaybackTransportStatusStage = .card
    let onRetry: () -> Void
    let onClose: (() -> Void)?
    let onTogglePause: () -> Void
    var layout: PlayerTransportStatusLayout = .standard

    private var content: PlayerTransportStatusContent {
        PlayerTransportStatusContent(status: status)
    }

    private var showsSpinnerOnly: Bool {
        stage == .spinner && status.isWaitingForMedia && !status.presentsCardImmediately
    }

    var body: some View {
        ZStack {
            if showsSpinnerOnly {
                PlayerTransportSpinner(accessibilityLabel: content.title)
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            } else {
                card
                    .transition(.scale(scale: 0.94).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.28), value: showsSpinnerOnly)
    }

    private var card: some View {
        VStack(spacing: statusSpacing) {
            switch status {
            case .failed:
                Label(content.title, systemImage: "exclamationmark.triangle")
                    .font(titleFont)
            default:
                ProgressView()
                    .controlSize(progressControlSize)
                Text(content.title)
                    .font(titleFont)
                    .multilineTextAlignment(.center)
            }
            if let detail = content.detail {
                Text(detail)
                    .font(detailFont)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            switch status {
            case .buffering, .pausedBuffering, .preparingLocal:
                Button {
                    onTogglePause()
                } label: {
                    Label(isPausedBuffering ? "Resume when ready" : "Pause",
                          systemImage: isPausedBuffering ? "play.fill" : "pause.fill")
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                }
                .playerTransportProminentButtonStyle()
                .accessibilityIdentifier("playback.buffer.playPause")
                .controlSize(statusControlSize)
                .padding(.top, buttonTopPadding)
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
                    .accessibilityIdentifier("playback.retry")
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
        .frame(width: layout.cardWidth)
        .labstreamOverlayPlatter(in: RoundedRectangle(cornerRadius: statusCornerRadius, style: .continuous))
        .shadow(radius: 18)
    }

    private var statusSpacing: CGFloat {
        switch layout {
        case .standard:
            #if os(tvOS)
            return 18
            #else
            return 14
            #endif
        case .regular: return 12
        case .compact: return 10
        case .compactHeight: return 6
        }
    }

    private var statusHorizontalPadding: CGFloat {
        switch layout {
        case .standard:
            #if os(tvOS)
            return 38
            #else
            return 24
            #endif
        case .regular: return 28
        case .compact: return 22
        case .compactHeight: return 20
        }
    }

    private var statusVerticalPadding: CGFloat {
        switch layout {
        case .standard:
            #if os(tvOS)
            return 30
            #else
            return 22
            #endif
        case .regular: return 24
        case .compact: return 18
        case .compactHeight: return 12
        }
    }

    private var statusCornerRadius: CGFloat {
        switch layout {
        case .standard:
            #if os(tvOS)
            return 28
            #else
            return 24
            #endif
        case .regular: return 26
        case .compact: return 22
        case .compactHeight: return 20
        }
    }

    private var buttonTopPadding: CGFloat {
        switch layout {
        case .regular, .compact: return 4
        case .standard, .compactHeight: return 0
        }
    }

    private var titleFont: Font {
        switch layout {
        case .standard:
            #if os(tvOS)
            return .title3.weight(.semibold)
            #else
            return .headline
            #endif
        case .regular: return .title3.weight(.semibold)
        case .compact: return .headline
        case .compactHeight: return .subheadline.weight(.semibold)
        }
    }

    private var detailFont: Font {
        switch layout {
        case .standard:
            #if os(tvOS)
            return .callout
            #else
            return .caption
            #endif
        case .regular: return .subheadline
        case .compact: return .footnote
        case .compactHeight: return .caption
        }
    }

    private var progressControlSize: ControlSize {
        switch layout {
        case .standard, .regular: return .large
        case .compact, .compactHeight: return .regular
        }
    }

    private var statusControlSize: ControlSize {
        switch layout {
        case .standard:
            #if os(tvOS)
            return .regular
            #else
            return .small
            #endif
        case .regular, .compact: return .regular
        case .compactHeight: return .small
        }
    }

    private var isPausedBuffering: Bool {
        if case .pausedBuffering = status { return true }
        if case .preparingLocal(isPaused: true, hasObservedPlayback: _) = status { return true }
        return false
    }
}

/// Stage-1 transport status, also used for the pre-controller startup wait so first start and
/// rebuffers share one visual language: a white spinner on a subtle dark disc (legible over
/// bright video) with no platter.
struct PlayerTransportSpinner: View {
    /// One size per platform (not per size class) so the pre-controller wait, first start, and
    /// rebuffers never jump between spinner sizes.
    static var defaultDiameter: CGFloat {
        #if os(tvOS)
        116
        #else
        64
        #endif
    }

    var diameter: CGFloat = PlayerTransportSpinner.defaultDiameter
    var accessibilityLabel: String = "Loading"

    var body: some View {
        ProgressView()
            .controlSize(.large)
            .tint(.white)
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(.black.opacity(0.42)))
            .environment(\.colorScheme, .dark)
            .accessibilityElement()
            .accessibilityLabel(Text(accessibilityLabel))
            .accessibilityIdentifier("playback.transportStatus.spinner")
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
