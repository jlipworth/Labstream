import Testing
import Foundation
@testable import PMSKit

// GH #135 Stage 5a: characterization of the Emby download route decision extracted from
// DownloadManager.downloadEmby. Pins the #112/#126 existing-version + #83 compatible-remux routing
// against the AUTHORITATIVE negotiated PlaybackInfo verdict.

@Suite("Emby download router")
struct EmbyDownloadRouterTests {

    private func part(container: String?) -> Part {
        Part(id: 1, key: "/library/parts/1/file", file: nil, size: 123, container: container)
    }

    @Test func choiceIntentMapping() {
        #expect(EmbyDownloadRouter.intent(for: .original) == .original)
        #expect(EmbyDownloadRouter.intent(for: .existingVersion) == .existingVersion)
        #expect(EmbyDownloadRouter.intent(for: .optimizeCompatible) == .compatible)
        #expect(EmbyDownloadRouter.intent(for: .optimize(targetName: "1080p 8 Mbps")) == .transcode)
    }

    // MARK: - container gate

    @Test func containerGateAcceptsLocallyPlayablePartEvenWithoutNegotiatedContainer() {
        #expect(EmbyDownloadRouter.containerGate(part: part(container: "mp4"), negotiatedContainer: nil))
        #expect(EmbyDownloadRouter.containerGate(part: part(container: "mov"), negotiatedContainer: nil))
    }

    @Test func containerGateAcceptsNegotiatedMp4FamilyEvenWhenPartIsMkv() {
        #expect(EmbyDownloadRouter.containerGate(part: part(container: "mkv"), negotiatedContainer: "mp4"))
        #expect(EmbyDownloadRouter.containerGate(part: part(container: "mkv"), negotiatedContainer: "M4V"))
    }

    @Test func containerGateRejectsWhenNeitherSideIsPlayable() {
        #expect(!EmbyDownloadRouter.containerGate(part: part(container: "mkv"), negotiatedContainer: "mkv"))
        #expect(!EmbyDownloadRouter.containerGate(part: part(container: "ts"), negotiatedContainer: nil))
        #expect(!EmbyDownloadRouter.containerGate(part: nil, negotiatedContainer: nil))
    }

    // MARK: - .original (user/source original — direct-play gated)

    @Test func directPlayablePlaysOriginalByteForByte() {
        let route = EmbyDownloadRouter.route(intent: .original,
                                             supportsDirectPlay: true, container: "mp4",
                                             videoCodec: "h264", audioCodec: "aac",
                                             part: part(container: "mp4"))
        #expect(route == .original)
    }

    @Test func directPlayButNonPlayableContainerFallsToTranscode() {
        // Server says direct-play, but neither the negotiated nor the source container is a local
        // mp4 family → cannot download byte-for-byte → transcode.
        let route = EmbyDownloadRouter.route(intent: .original,
                                             supportsDirectPlay: true, container: "mkv",
                                             videoCodec: "hevc", audioCodec: "dts",
                                             part: part(container: "mkv"))
        #expect(route == .transcode)
    }

    @Test func originalNoDirectPlayFallsToTranscodeEvenWithPlayableContainer() {
        // A user-original has no server-rendered guarantee, so it keeps the direct-play safety net.
        let route = EmbyDownloadRouter.route(intent: .original,
                                             supportsDirectPlay: false, container: "mp4",
                                             videoCodec: "h264", audioCodec: "aac",
                                             part: part(container: "mp4"))
        #expect(route == .transcode)
    }

    // MARK: - .existingVersion (#126 convert-reuse — container/codec gated, NOT direct-play)

    @Test func existingVersionDownloadsPlayableMp4EvenWhenEmbyDeniesDirectPlay() {
        // Regression: the convert→download reuse handoff GETs a pre-rendered mp4/h264 file byte-for-
        // byte. Emby returns supportsDirectPlay=false for it (observed live), which used to refuse the
        // download (converted_not_directly_downloadable → no row). It must download as .original.
        let route = EmbyDownloadRouter.route(intent: .existingVersion,
                                             supportsDirectPlay: false, container: "mp4",
                                             videoCodec: "h264", audioCodec: "aac",
                                             part: part(container: "mkv"))
        #expect(route == .original)
    }

    @Test func existingVersionTranscodesNonLocallyPlayableContainer() {
        // A converted source that is somehow still an mkv cannot be GET byte-for-byte → transcode.
        let route = EmbyDownloadRouter.route(intent: .existingVersion,
                                             supportsDirectPlay: false, container: "mkv",
                                             videoCodec: "h264", audioCodec: "aac",
                                             part: part(container: "mkv"))
        #expect(route == .transcode)
    }

    @Test func existingVersionFailsClosedOnUnknownVideoCodec() {
        // No preflight on this lane → fail closed on an unknown codec even with a playable container.
        let route = EmbyDownloadRouter.route(intent: .existingVersion,
                                             supportsDirectPlay: true, container: "mp4",
                                             videoCodec: nil, audioCodec: "aac",
                                             part: part(container: "mp4"))
        #expect(route == .transcode)
    }

    // MARK: - .compatible (#83 original-quality remux)

    @Test func compatibleCopyableVideoTakesRemuxLane() {
        // HEVC video is stream-copyable; DTS audio is not — still eligible (audio→AAC), route = remux.
        let route = EmbyDownloadRouter.route(intent: .compatible,
                                             supportsDirectPlay: false, container: "mkv",
                                             videoCodec: "hevc", audioCodec: "dts",
                                             part: part(container: "mkv"))
        #expect(route == .compatibleRemux)
    }

    @Test func compatibleNonCopyableVideoFallsToTranscode() {
        // VC-1 / MPEG-2 etc. cannot be copied into MP4 → transcode.
        let route = EmbyDownloadRouter.route(intent: .compatible,
                                             supportsDirectPlay: false, container: "mkv",
                                             videoCodec: "vc1", audioCodec: "ac3",
                                             part: part(container: "mkv"))
        #expect(route == .transcode)
    }

    @Test func compatibleIgnoresDirectPlayFlagAndContainerGate() {
        // The compatible lane is gated purely on stream-copy eligibility, NOT direct-play / container.
        let route = EmbyDownloadRouter.route(intent: .compatible,
                                             supportsDirectPlay: true, container: "mp4",
                                             videoCodec: "h264", audioCodec: "aac",
                                             part: part(container: "mp4"))
        #expect(route == .compatibleRemux)
    }

    // MARK: - .transcode (explicit optimize preset)

    @Test func transcodeIntentAlwaysTranscodes() {
        for directPlay in [true, false] {
            let route = EmbyDownloadRouter.route(intent: .transcode,
                                                 supportsDirectPlay: directPlay, container: "mp4",
                                                 videoCodec: "h264", audioCodec: "aac",
                                                 part: part(container: "mp4"))
            #expect(route == .transcode)
        }
    }
}
