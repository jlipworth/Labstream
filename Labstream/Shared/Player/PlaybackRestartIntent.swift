/// The user or controller action that intentionally replaces the current player item while
/// preserving the playhead. Keeping the reason typed prevents call sites from independently
/// assembling subtly different Boolean restart recipes.
enum PlaybackRestartIntent: CaseIterable, Sendable {
    case subtitleTrackChange
    case audioTrackChange
    case qualityChange
    case explicitRetry
    case adaptiveBitrate

    var plan: PlaybackRestartPlan {
        switch self {
        case .subtitleTrackChange, .audioTrackChange, .qualityChange, .adaptiveBitrate:
            PlaybackRestartPlan(
                preparationSteps: [
                    .resetFinalTarget,
                    .rearmStartupDeadlineRetry,
                    .removeObservers,
                ],
                plexControlClient: .preserve,
                remoteBuffering: .standard
            )
        case .explicitRetry:
            PlaybackRestartPlan(
                preparationSteps: [
                    .resetFinalTarget,
                    .resetAdaptiveBitrate,
                    .rearmStartupDeadlineRetry,
                    .clearPlaybackError,
                    .removeObservers,
                ],
                plexControlClient: .refreshForRecovery,
                remoteBuffering: .standard
            )
        }
    }
}

/// An ordered, value-only recipe for one intentional in-place playback restart.
///
/// Backend replacement ordering is deliberately not represented here. `PlaybackController`
/// still owns the load-bearing fork: Plex refreshes its control client when requested and stops
/// the superseded transcode before replacement, while MediaBrowser sessions detach and reopen
/// before deferring prior-session cleanup.
struct PlaybackRestartPlan: Equatable, Sendable {
    enum PreparationStep: Equatable, Sendable {
        case resetFinalTarget
        case resetAdaptiveBitrate
        case rearmStartupDeadlineRetry
        case clearPlaybackError
        case removeObservers
    }

    enum PlexControlClientPolicy: Equatable, Sendable {
        case preserve
        case refreshForRecovery
    }

    enum RemoteBufferingPolicy: Equatable, Sendable {
        case standard
        case shortReopen

        var prefersShortBuffer: Bool {
            self == .shortReopen
        }
    }

    let preparationSteps: [PreparationStep]
    let plexControlClient: PlexControlClientPolicy
    let remoteBuffering: RemoteBufferingPolicy
}
