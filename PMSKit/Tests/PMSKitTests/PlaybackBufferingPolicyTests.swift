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
