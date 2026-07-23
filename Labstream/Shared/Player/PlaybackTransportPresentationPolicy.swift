/// Source-aware, user-facing transport presentation derived from technical player facts.
///
/// AVPlayer uses the same waiting status for remote starvation and local-file opening, demuxing,
/// decoding, or priming. Keep those technical facts and watchdogs shared while presenting honest
/// wording for the known source.
enum PlaybackTransportPresentationPolicy {
    enum Source: Equatable {
        case remote
        case localFile
    }

    struct Context: Equatable {
        let source: Source
        let isFailed: Bool
        let failureMessage: String?
        let isReconnecting: Bool
        let isWaitingForMedia: Bool
        let isPaused: Bool
        let hasObservedPlayback: Bool
    }

    static func status(_ context: Context) -> PlaybackTransportStatus {
        if context.isFailed {
            return .failed(message: context.failureMessage)
        }
        if context.isReconnecting {
            return .reconnecting
        }
        guard context.isWaitingForMedia else {
            return .none
        }
        switch context.source {
        case .remote:
            return context.isPaused ? .pausedBuffering : .buffering
        case .localFile:
            return .preparingLocal(
                isPaused: context.isPaused,
                hasObservedPlayback: context.hasObservedPlayback
            )
        }
    }
}

/// Copy for the transport overlay, kept separate from SwiftUI so source-aware wording is pinned by
/// focused app tests rather than inferred from a rendered view.
struct PlayerTransportStatusContent: Equatable {
    let title: String
    let detail: String?

    init(status: PlaybackTransportStatus) {
        switch status {
        case .none:
            title = ""
            detail = nil
        case .buffering:
            title = "Buffering…"
            detail = "You can pause now and let the stream build buffer before playing."
        case .pausedBuffering:
            title = "Paused — buffering…"
            detail = "Playback will stay paused once the stream is ready."
        case .preparingLocal(let isPaused, let hasObservedPlayback):
            title = isPaused ? "Paused — preparing…" : "Preparing…"
            if hasObservedPlayback {
                detail = isPaused
                    ? "Playback will stay paused once the downloaded video is ready."
                    : "Preparing the downloaded video on this device."
            } else {
                detail = isPaused
                    ? "Playback will stay paused once the downloaded video is ready."
                    : "Opening the downloaded video on this device."
            }
        case .reconnecting:
            title = "Reconnecting…"
            detail = nil
        case .failed(let message):
            title = "Playback failed"
            detail = message?.isEmpty == false ? message : nil
        }
    }
}
