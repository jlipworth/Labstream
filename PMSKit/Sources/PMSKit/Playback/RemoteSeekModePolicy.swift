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
        /// Plex video-copy (Direct Play / Maximum) transcode session. Seeks stay NATIVE even
        /// out of buffer (GH #196): the session playlist is a full VOD list and PMS jumps its
        /// remux transcoder to whichever segment the player requests (proven live — the
        /// client-side resume seek rides exactly this). A reopen actively breaks this lane:
        /// killing and re-minting the same session id back-to-back was observed leaving the
        /// fresh session header-less for 20s+ and then HTTP-400ing the restart.
        case plexStreamingCopyHLS
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
                                  isPlexVideoCopyLane: Bool = false,
                                  hasRemoteStream: Bool,
                                  mediaBrowserPlayMethod: MediaBrowserPlayMethod?) -> StreamKind {
        if isLocalFile { return .localFile }
        if isPlexStreaming { return isPlexVideoCopyLane ? .plexStreamingCopyHLS : .plexStreamingHLS }
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
        case .localFile, .plexStreamingCopyHLS, .mediaBrowserDirectOrStatic, .otherRemote:
            return false
        }
    }
}
