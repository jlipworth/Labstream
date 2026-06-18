import Testing
@testable import PMSKit

@Suite("Playback failure policy")
struct PlaybackFailurePolicyTests {
    @Test func ignoresStaleItemFailures() {
        let snapshot = PlaybackFailureSnapshot(source: .failedToPlayToEnd,
                                               path: .remoteHLS,
                                               isCurrentItem: false,
                                               isItemReadyToPlay: false,
                                               isPlayerPlaying: false,
                                               bufferedAheadSeconds: 0,
                                               notificationErrorCode: -66681,
                                               itemErrorCode: nil,
                                               playerErrorCode: nil)

        #expect(PlaybackFailurePolicy.action(for: snapshot) == .ignoreStaleItem)
    }

    @Test func suppressesFirstBufferedRemoteHLSFailedToEndCodeOnly() {
        let snapshot = PlaybackFailureSnapshot(source: .failedToPlayToEnd,
                                               path: .remoteHLS,
                                               isCurrentItem: true,
                                               isItemReadyToPlay: true,
                                               isPlayerPlaying: true,
                                               bufferedAheadSeconds: 4.7,
                                               notificationErrorCode: -66681,
                                               itemErrorCode: nil,
                                               playerErrorCode: nil)

        #expect(PlaybackFailurePolicy.action(for: snapshot) == .ignoreRecoverableBufferedRemoteHLS)
    }

    @Test func surfacesRepeatedOrUnbufferedRemoteHLSFailures() {
        let repeated = PlaybackFailureSnapshot(source: .failedToPlayToEnd,
                                               path: .remoteHLS,
                                               isCurrentItem: true,
                                               isItemReadyToPlay: true,
                                               isPlayerPlaying: true,
                                               bufferedAheadSeconds: 4.7,
                                               notificationErrorCode: -66681,
                                               itemErrorCode: nil,
                                               playerErrorCode: nil,
                                               ignoredRecoverableFailureCount: 1)
        let unbuffered = PlaybackFailureSnapshot(source: .failedToPlayToEnd,
                                                 path: .remoteHLS,
                                                 isCurrentItem: true,
                                                 isItemReadyToPlay: true,
                                                 isPlayerPlaying: true,
                                                 bufferedAheadSeconds: 0.5,
                                                 notificationErrorCode: -66681,
                                                 itemErrorCode: nil,
                                                 playerErrorCode: nil)

        #expect(PlaybackFailurePolicy.action(for: repeated) == .surface)
        #expect(PlaybackFailurePolicy.action(for: unbuffered) == .surface)
    }

    @Test func surfacesNonNotificationAndCurrentItemFailures() {
        let statusFailed = PlaybackFailureSnapshot(source: .itemStatusFailed,
                                                   path: .remoteHLS,
                                                   isCurrentItem: true,
                                                   isItemReadyToPlay: false,
                                                   isPlayerPlaying: false,
                                                   bufferedAheadSeconds: 0,
                                                   notificationErrorCode: -66681,
                                                   itemErrorCode: -66681,
                                                   playerErrorCode: nil)
        let otherCode = PlaybackFailureSnapshot(source: .failedToPlayToEnd,
                                                path: .remoteHLS,
                                                isCurrentItem: true,
                                                isItemReadyToPlay: true,
                                                isPlayerPlaying: true,
                                                bufferedAheadSeconds: 4.7,
                                                notificationErrorCode: -1008,
                                                itemErrorCode: nil,
                                                playerErrorCode: nil)

        #expect(PlaybackFailurePolicy.action(for: statusFailed) == .surface)
        #expect(PlaybackFailurePolicy.action(for: otherCode) == .surface)
    }

    @Test func surfacesNonRemoteHLSFailures() {
        let snapshot = PlaybackFailureSnapshot(source: .failedToPlayToEnd,
                                               path: .other,
                                               isCurrentItem: true,
                                               isItemReadyToPlay: true,
                                               isPlayerPlaying: true,
                                               bufferedAheadSeconds: 4.7,
                                               notificationErrorCode: -66681,
                                               itemErrorCode: nil,
                                               playerErrorCode: nil)

        #expect(PlaybackFailurePolicy.action(for: snapshot) == .surface)
    }
}
