import Foundation
import Testing
@testable import PMSKit

@Suite("Playback buffering policy")
struct PlaybackBufferingPolicyTests {
    @Test func usesSteadyStateBufferForPlexStaticAndInitialRemoteHLS() {
        let staticOrPlex = PlaybackBufferingPolicy.configuration(
            isRemoteServerEncodedHLS: false,
            preferShortRemoteHLSBuffer: false)
        #expect(staticOrPlex.preferredForwardBufferSeconds == PlaybackBufferingPolicy.steadyStateForwardBufferSeconds)
        #expect(staticOrPlex.automaticallyWaitsToMinimizeStalling)
        #expect(!staticOrPlex.canUseNetworkResourcesForLiveStreamingWhilePaused)
        #expect(!staticOrPlex.usesShortRemoteHLSBuffer)

        let initialRemoteHLS = PlaybackBufferingPolicy.configuration(
            isRemoteServerEncodedHLS: true,
            preferShortRemoteHLSBuffer: false)
        #expect(initialRemoteHLS.preferredForwardBufferSeconds == PlaybackBufferingPolicy.steadyStateForwardBufferSeconds)
        #expect(initialRemoteHLS.automaticallyWaitsToMinimizeStalling)
        #expect(initialRemoteHLS.canUseNetworkResourcesForLiveStreamingWhilePaused)
        #expect(!initialRemoteHLS.usesShortRemoteHLSBuffer)
    }

    @Test func embyCopyReopenKeepsAutomaticRecoveryWithTheSameShortBuffer() {
        let baseline = PlaybackBufferingPolicy.configuration(
            isRemoteServerEncodedHLS: true, preferShortRemoteHLSBuffer: true)
        let copy = PlaybackBufferingPolicy.configuration(
            isRemoteServerEncodedHLS: true, preferShortRemoteHLSBuffer: true,
            isEmbyVideoCopyHLS: true)
        #expect(copy.automaticallyWaitsToMinimizeStalling)
        #expect(!baseline.automaticallyWaitsToMinimizeStalling)
        #expect(copy.preferredForwardBufferSeconds == baseline.preferredForwardBufferSeconds)
        #expect(copy.usesShortRemoteHLSBuffer == baseline.usesShortRemoteHLSBuffer)
        #expect(copy.canUseNetworkResourcesForLiveStreamingWhilePaused == baseline.canUseNetworkResourcesForLiveStreamingWhilePaused)
    }

    @Test func recognizesServerEncodedHLSPlaylistURLs() {
        // Plex serves ALL playback — Direct Play / Direct Stream included — as a
        // `start.m3u8` transcode-session playlist, which is EVENT-style (live-ish to
        // AVPlayer) while the session runs. Those URLs must be classified as
        // server-encoded HLS so paused pre-buffering keeps loading (GH #195 live test:
        // Buffer ahead pinned at 0.0s while paused on a Plex Direct Stream).
        let plexSession = URL(string: "https://plex.example.internal:32400/video/:/transcode/universal/start.m3u8?protocol=hls")!
        #expect(PlaybackBufferingPolicy.isServerEncodedHLSPlaylist(url: plexSession))

        let localProxy = URL(string: "http://127.0.0.1:8888/proxy/start.m3u8")!
        #expect(PlaybackBufferingPolicy.isServerEncodedHLSPlaylist(url: localProxy))

        // Progressive/static file lanes (Jellyfin/Emby direct play + direct stream,
        // offline files) are true VOD — AVPlayer buffers them while paused natively.
        let jellyfinDirect = URL(string: "https://jf.example.internal/Videos/abc/stream.mkv?Static=true")!
        #expect(!PlaybackBufferingPolicy.isServerEncodedHLSPlaylist(url: jellyfinDirect))
        let localFile = URL(fileURLWithPath: "/tmp/movie.mp4")
        #expect(!PlaybackBufferingPolicy.isServerEncodedHLSPlaylist(url: localFile))
        #expect(!PlaybackBufferingPolicy.isServerEncodedHLSPlaylist(url: nil))
    }

    @Test func usesShortBufferOnlyForExplicitRemoteHLSSeekReopens() {
        let remoteSeekReopen = PlaybackBufferingPolicy.configuration(
            isRemoteServerEncodedHLS: true,
            preferShortRemoteHLSBuffer: true)
        #expect(remoteSeekReopen.preferredForwardBufferSeconds == PlaybackBufferingPolicy.remoteHLSSeekReopenForwardBufferSeconds)
        #expect(!remoteSeekReopen.automaticallyWaitsToMinimizeStalling)
        #expect(!remoteSeekReopen.canUseNetworkResourcesForLiveStreamingWhilePaused)
        #expect(remoteSeekReopen.usesShortRemoteHLSBuffer)

        let nonRemoteLoad = PlaybackBufferingPolicy.configuration(
            isRemoteServerEncodedHLS: false,
            preferShortRemoteHLSBuffer: true)
        #expect(nonRemoteLoad.preferredForwardBufferSeconds == PlaybackBufferingPolicy.steadyStateForwardBufferSeconds)
        #expect(nonRemoteLoad.automaticallyWaitsToMinimizeStalling)
        #expect(!nonRemoteLoad.usesShortRemoteHLSBuffer)
    }
}
