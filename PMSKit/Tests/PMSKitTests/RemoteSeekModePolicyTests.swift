import Testing
@testable import PMSKit

@Suite("Remote seek mode policy")
struct RemoteSeekModePolicyTests {
    @Test func derivesStreamKindsWithoutProxyKnowledge() {
        #expect(RemoteSeekModePolicy.streamKind(isLocalFile: true,
                                                isPlexStreaming: false,
                                                hasRemoteStream: false,
                                                mediaBrowserPlayMethod: nil) == .localFile)
        #expect(RemoteSeekModePolicy.streamKind(isLocalFile: false,
                                                isPlexStreaming: true,
                                                hasRemoteStream: false,
                                                mediaBrowserPlayMethod: nil) == .plexStreamingHLS)
        #expect(RemoteSeekModePolicy.streamKind(isLocalFile: false,
                                                isPlexStreaming: false,
                                                hasRemoteStream: true,
                                                mediaBrowserPlayMethod: .directPlay) == .mediaBrowserDirectOrStatic)
        #expect(RemoteSeekModePolicy.streamKind(isLocalFile: false,
                                                isPlexStreaming: false,
                                                hasRemoteStream: true,
                                                mediaBrowserPlayMethod: .directStream) == .mediaBrowserDirectOrStatic)
        #expect(RemoteSeekModePolicy.streamKind(isLocalFile: false,
                                                isPlexStreaming: false,
                                                hasRemoteStream: true,
                                                mediaBrowserPlayMethod: .transcode) == .mediaBrowserServerEncodedHLS)
        #expect(RemoteSeekModePolicy.streamKind(isLocalFile: false,
                                                isPlexStreaming: false,
                                                hasRemoteStream: true,
                                                mediaBrowserPlayMethod: nil) == .otherRemote)
    }

    @Test func bufferedTargetsAlwaysUseNativeSeek() {
        let kinds: [RemoteSeekModePolicy.StreamKind] = [
            .localFile,
            .plexStreamingHLS,
            .mediaBrowserDirectOrStatic,
            .mediaBrowserServerEncodedHLS,
            .otherRemote,
        ]

        for kind in kinds {
            #expect(RemoteSeekModePolicy.seekMode(streamKind: kind,
                                                  targetIsWithinLoadedRange: true) == .nativeAVPlayerSeek)
        }
    }

    @Test func onlyServerEncodedHLSKindsReopenForOutOfBufferTargets() {
        #expect(RemoteSeekModePolicy.seekMode(streamKind: .plexStreamingHLS,
                                              targetIsWithinLoadedRange: false) == .reopenStreamAtTarget)
        #expect(RemoteSeekModePolicy.seekMode(streamKind: .mediaBrowserServerEncodedHLS,
                                              targetIsWithinLoadedRange: false) == .reopenStreamAtTarget)

        #expect(RemoteSeekModePolicy.seekMode(streamKind: .localFile,
                                              targetIsWithinLoadedRange: false) == .nativeAVPlayerSeek)
        #expect(RemoteSeekModePolicy.seekMode(streamKind: .mediaBrowserDirectOrStatic,
                                              targetIsWithinLoadedRange: false) == .nativeAVPlayerSeek)
        #expect(RemoteSeekModePolicy.seekMode(streamKind: .otherRemote,
                                              targetIsWithinLoadedRange: false) == .nativeAVPlayerSeek)
    }
}
