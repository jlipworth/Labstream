import Testing
@testable import PMSKit

struct DownloadIntegrityEdgeTests {
    @Test(arguments: ["application/problem+json", "application/xhtml+xml"])
    func structuredErrorBody(mime: String) {
        #expect(ForwardOnlyFinishedBodyPolicy.responseRejection(httpStatus: 200, mimeType: mime) != nil)
        #expect(DownloadCompletionValidation.errorPageReason(httpStatusCode: 200, mimeType: mime) != nil)
    }

    @Test(arguments: ["bytes 0-8/10", "bytes 1-9/10", "bytes 0-9/*", "invalid"])
    func incompleteForwardResponse(range: String) {
        #expect(ForwardOnlyFinishedBodyPolicy.responseRejection(
            httpStatus: 206, mimeType: "video/mp4", contentRange: range, bodyBytes: 9) != nil)
        #expect(ForwardOnlyFinishedBodyPolicy.responseRejection(
            httpStatus: 206, mimeType: "video/mp4", contentRange: "bytes 0-9/10", bodyBytes: 10) == nil)
    }

    @Test func resumedBytesSaturate() {
        var latch: Int?
        #expect(DownloadLiveRangeProgressPolicy.displayBytesForResumedTask(
            taskBytes: 1, baseOffset: 0, resumeDisplayBytes: .max, latchedRebase: &latch) == .max)
        #expect(DownloadLiveRangeProgressPolicy.aggregatedLiveBytes(durableBytes: .max, liveSegmentBodyBytes: [1]) == .max)
        #expect(DownloadLiveRangeProgressPolicy.rateSampleBytes(reportedBytes: .max - 1, previous: .max, bytesAwaitingAppend: 2) == .max)
    }
}
