import Testing
@testable import PMSKit

struct TrickPlayPreviewResolutionPolicyTests {
    @Test("Seek label uses target rather than a sparse thumbnail capture time")
    func targetTimeWinsOverCaptureTime() {
        #expect(TrickPlayPreviewResolutionPolicy.displayedTimeMs(
            targetMs: 9 * 60_000,
            thumbnailCaptureTimeMs: 0,
            fallbackMs: 15_000
        ) == 9 * 60_000)
    }

    @Test("Current request with no decodable thumbnail clears stale imagery")
    func currentNilResultClearsImage() {
        #expect(TrickPlayPreviewResolutionPolicy.completion(
            requestGeneration: 4,
            currentGeneration: 4,
            requestTargetMs: 540_000,
            activeTargetMs: 540_000,
            decodedThumbnailTimeMs: nil
        ) == .clearImage)
    }

    @Test("Superseded generation cannot mutate the current preview")
    func staleGenerationIsIgnored() {
        #expect(TrickPlayPreviewResolutionPolicy.completion(
            requestGeneration: 3,
            currentGeneration: 4,
            requestTargetMs: 500_000,
            activeTargetMs: 540_000,
            decodedThumbnailTimeMs: 0
        ) == .ignoredStale)
    }

    @Test("Sparse Emby chapter boundary changes at the exact chapter start")
    func sparseChapterBoundary() {
        let goldenEyeChapterTimes = [0, 629_940, 800_140]

        #expect(SparseTrickPlayFrameSelectionPolicy.frameIndex(
            nearMs: 629_939,
            sortedFrameTimesMs: goldenEyeChapterTimes
        ) == 0)
        #expect(SparseTrickPlayFrameSelectionPolicy.frameIndex(
            nearMs: 629_940,
            sortedFrameTimesMs: goldenEyeChapterTimes
        ) == 1)
        #expect(SparseTrickPlayFrameSelectionPolicy.frameIndex(
            nearMs: 800_140,
            sortedFrameTimesMs: goldenEyeChapterTimes
        ) == 2)
    }
}
