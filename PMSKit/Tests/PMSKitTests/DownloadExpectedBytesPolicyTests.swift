import Foundation
import Testing
@testable import PMSKit

@Suite("Download expected bytes policy")
struct DownloadExpectedBytesPolicyTests {
    private let url = URL(fileURLWithPath: "/tmp/labstream-expected-bytes.mp4")

    private func record(progress: Double = 0,
                        bytes: Int = 0,
                        resumeMode: DownloadResumeMode = .staticByteRange,
                        sourcePartSize: Int? = 1_000) -> DownloadRecord {
        let ratingKey = DownloadRecordIdentity.recordKey(for: "item", backend: .jellyfin)
        let metadata = OfflineMetadata(ratingKey: ratingKey,
                                       title: "Title",
                                       type: "movie",
                                       sourcePartSize: sourcePartSize,
                                       backendKind: .jellyfin,
                                       downloadLane: .original,
                                       resumeMode: resumeMode)
        return DownloadRecord(ratingKey: ratingKey,
                              title: "Title",
                              localURL: url,
                              bytes: bytes,
                              progress: progress,
                              status: .downloading,
                              metadata: metadata)
    }

    @Test("Static range expected bytes require static resume mode and positive source size")
    func staticRangeExpectedBytes() {
        #expect(DownloadExpectedBytesPolicy.staticRangeExpectedBytes(for: record(sourcePartSize: 42)) == 42)
        #expect(DownloadExpectedBytesPolicy.staticRangeExpectedBytes(for: record(resumeMode: .liveForwardOnly,
                                                                                sourcePartSize: 42)) == nil)
        #expect(DownloadExpectedBytesPolicy.staticRangeExpectedBytes(for: record(sourcePartSize: 0)) == nil)
        #expect(DownloadExpectedBytesPolicy.staticRangeExpectedBytes(for: record(sourcePartSize: nil)) == nil)
    }

    @Test("Expected bytes precedence preserves live, content length, static, estimate order")
    func expectedBytesPrecedence() {
        let row = record(progress: 0.25, bytes: 200)
        #expect(DownloadExpectedBytesPolicy.expectedDownloadBytes(record: row,
                                                                 liveExpectedBytes: 2_000,
                                                                 liveBytes: 300,
                                                                 staticExpectedBytes: 1_500,
                                                                 estimatedTranscodeBytes: 1_200) == 2_000)
        #expect(DownloadExpectedBytesPolicy.expectedDownloadBytes(record: row,
                                                                 liveExpectedBytes: nil,
                                                                 liveBytes: 300,
                                                                 staticExpectedBytes: 1_500,
                                                                 estimatedTranscodeBytes: 1_200) == 1_200)
        #expect(DownloadExpectedBytesPolicy.expectedDownloadBytes(record: record(progress: 0, bytes: 0),
                                                                 liveExpectedBytes: nil,
                                                                 liveBytes: nil,
                                                                 staticExpectedBytes: 1_500,
                                                                 estimatedTranscodeBytes: 1_200) == 1_500)
        #expect(DownloadExpectedBytesPolicy.expectedDownloadBytes(record: record(progress: 0, bytes: 0),
                                                                 liveExpectedBytes: nil,
                                                                 liveBytes: nil,
                                                                 staticExpectedBytes: nil,
                                                                 estimatedTranscodeBytes: 1_200) == 1_200)
    }

    @Test("Zero or missing live expected bytes are ignored")
    func zeroLiveExpectedBytesIgnored() {
        let row = record(progress: 0, bytes: 0)
        #expect(DownloadExpectedBytesPolicy.expectedDownloadBytes(record: row,
                                                                 liveExpectedBytes: 0,
                                                                 liveBytes: nil,
                                                                 staticExpectedBytes: 1_500,
                                                                 estimatedTranscodeBytes: 1_200) == 1_500)
    }
}
