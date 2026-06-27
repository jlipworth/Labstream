/// Backend-neutral seek-mode selection for the custom scrubber.
///
/// The player has two fundamentally different seek mechanisms:
/// - a native `AVPlayer.seek`, which is correct for local files, static/range-friendly
///   remote files, and targets already inside the loaded buffer;
/// - a server-side stream reopen/rebuild at the final target, which is only justified
///   for HLS sessions whose produced segment window cannot satisfy a deep target.
///
/// Keep this policy free of proxy details: a caller may implement the reopen via Plex
/// universal transcode, Jellyfin/Emby PlaybackInfo, or another future mechanism.
public enum RemoteSeekModePolicy {
    public enum StreamKind: Sendable, Equatable {
        case localFile
        case plexStreamingHLS
        case mediaBrowserDirectOrStatic
        case mediaBrowserServerEncodedHLS
        case otherRemote
    }

    public enum SeekMode: Sendable, Equatable {
        case nativeAVPlayerSeek
        case reopenStreamAtTarget
    }

    public static func streamKind(isLocalFile: Bool,
                                  isPlexStreaming: Bool,
                                  hasRemoteStream: Bool,
                                  mediaBrowserPlayMethod: MediaBrowserPlayMethod?) -> StreamKind {
        if isLocalFile { return .localFile }
        if isPlexStreaming { return .plexStreamingHLS }
        guard hasRemoteStream else { return .otherRemote }
        guard let mediaBrowserPlayMethod else { return .otherRemote }
        switch mediaBrowserPlayMethod {
        case .directPlay, .directStream:
            return .mediaBrowserDirectOrStatic
        case .transcode:
            return .mediaBrowserServerEncodedHLS
        }
    }

    public static func seekMode(streamKind: StreamKind,
                                targetIsWithinLoadedRange: Bool) -> SeekMode {
        if targetIsWithinLoadedRange {
            return .nativeAVPlayerSeek
        }
        return supportsOutOfBufferReopen(streamKind: streamKind)
            ? .reopenStreamAtTarget
            : .nativeAVPlayerSeek
    }

    public static func supportsOutOfBufferReopen(streamKind: StreamKind) -> Bool {
        switch streamKind {
        case .plexStreamingHLS, .mediaBrowserServerEncodedHLS:
            return true
        case .localFile, .mediaBrowserDirectOrStatic, .otherRemote:
            return false
        }
    }
}
