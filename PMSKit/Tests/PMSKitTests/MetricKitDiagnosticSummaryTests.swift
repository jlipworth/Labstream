import XCTest
@testable import PMSKit

final class MetricKitDiagnosticSummaryTests: XCTestCase {

    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    func testCrashHeadlineCombinesExceptionSignalAndCode() {
        let input = MetricKitDiagnosticInput(
            kind: .crash,
            date: fixedDate,
            exceptionType: "EXC_BAD_ACCESS",
            exceptionCode: "0x1",
            signal: "SIGSEGV"
        )
        let summary = MetricKitDiagnosticSummarizer.summarize(input)
        XCTAssertEqual(summary.kind, .crash)
        XCTAssertEqual(summary.timestamp, fixedDate)
        XCTAssertTrue(summary.headline.contains("EXC_BAD_ACCESS"))
        XCTAssertTrue(summary.headline.contains("(SIGSEGV)"))
        XCTAssertTrue(summary.headline.contains("code 0x1"))
    }

    func testCrashWithNoDetailStillProducesHeadline() {
        let summary = MetricKitDiagnosticSummarizer.summarize(MetricKitDiagnosticInput(kind: .crash))
        XCTAssertEqual(summary.headline, "crash (no exception detail)")
    }

    func testHangDurationIsBucketedNotExact() {
        let input = MetricKitDiagnosticInput(kind: .hang, hangDurationSeconds: 7.34)
        let summary = MetricKitDiagnosticSummarizer.summarize(input)
        XCTAssertEqual(summary.headline, "hang ~5-10s")
        // Exact duration must not leak.
        XCTAssertFalse(summary.headline.contains("7.34"))
        XCTAssertFalse(summary.headline.contains("7"))
    }

    func testHangUnknownDuration() {
        let summary = MetricKitDiagnosticSummarizer.summarize(MetricKitDiagnosticInput(kind: .hang))
        XCTAssertEqual(summary.headline, "hang (unknown duration)")
    }

    func testTerminationReasonWithPathIsRedacted() {
        let input = MetricKitDiagnosticInput(
            kind: .crash,
            terminationReason: "Namespace SIGNAL, Code 11 at /path/to/user/Library/foo.dylib"
        )
        let summary = MetricKitDiagnosticSummarizer.summarize(input)
        XCTAssertTrue(summary.headline.contains("[path]"), summary.headline)
        XCTAssertFalse(summary.headline.contains("/Users/"))
        XCTAssertFalse(summary.headline.contains("someone"))
    }

    func testCallStackFramesAreCappedAndRedacted() {
        let frames = (0..<20).map { "Labstream frame\($0) /path/to/user/build/Labstream.app/bin" }
        let input = MetricKitDiagnosticInput(kind: .crash, callStackFrames: frames)
        let summary = MetricKitDiagnosticSummarizer.summarize(input)
        XCTAssertEqual(summary.topFrames.count, MetricKitDiagnosticSummarizer.maxFrames)
        for frame in summary.topFrames {
            XCTAssertFalse(frame.contains("/Users/"), frame)
            XCTAssertTrue(frame.contains("[path]"), frame)
        }
    }

    func testEmptyAndWhitespaceFramesAreDropped() {
        let input = MetricKitDiagnosticInput(kind: .crash, callStackFrames: ["", "   ", "realFrame"])
        let summary = MetricKitDiagnosticSummarizer.summarize(input)
        XCTAssertEqual(summary.topFrames, ["realFrame"])
    }

    func testReportSectionEmptyShowsNoneLine() {
        let lines = MetricKitDiagnosticSummarizer.reportSection(for: [])
        XCTAssertEqual(lines.first, "Recent crashes/hangs (MetricKit, redacted, on-device)")
        XCTAssertEqual(lines.last, "- None captured since install.")
    }

    func testReportSectionRendersHeadlineAndIndentedFrames() {
        let summary = MetricKitDiagnosticSummary(
            kind: .crash,
            timestamp: fixedDate,
            headline: "EXC_BAD_ACCESS (SIGSEGV)",
            topFrames: ["Labstream playFoo", "UIKit sendEvent"]
        )
        let lines = MetricKitDiagnosticSummarizer.reportSection(for: [summary])
        XCTAssertEqual(lines[0], "Recent crashes/hangs (MetricKit, redacted, on-device)")
        XCTAssertTrue(lines[1].contains("Crash at"))
        XCTAssertTrue(lines[1].contains("EXC_BAD_ACCESS (SIGSEGV)"))
        XCTAssertEqual(lines[2], "    Labstream playFoo")
        XCTAssertEqual(lines[3], "    UIKit sendEvent")
    }

    func testSummaryRoundTripsThroughCodable() throws {
        let summary = MetricKitDiagnosticSummary(
            kind: .hang,
            timestamp: fixedDate,
            headline: "hang ~5-10s",
            topFrames: ["a", "b"]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(summary)
        let decoded = try decoder.decode(MetricKitDiagnosticSummary.self, from: data)
        XCTAssertEqual(decoded, summary)
    }

    func testReportRendererIncludesMetricKitSection() {
        let context = DiagnosticReportContext(
            product: "Labstream",
            appVersion: "1.2.0",
            appBuild: "1",
            operatingSystem: "visionOS 26.0",
            deviceName: "Apple Vision Pro",
            backend: "Plex",
            selectedQuality: "Original",
            loggingEnabled: true
        )
        let summary = MetricKitDiagnosticSummary(
            kind: .crash,
            timestamp: fixedDate,
            headline: "EXC_BAD_ACCESS (SIGSEGV)",
            topFrames: ["Labstream playFoo"]
        )
        let report = DiagnosticReportRenderer.render(
            context: context,
            events: [],
            metricKitSummaries: [summary]
        )
        XCTAssertTrue(report.contains("Recent crashes/hangs (MetricKit, redacted, on-device)"))
        XCTAssertTrue(report.contains("EXC_BAD_ACCESS (SIGSEGV)"))
        XCTAssertTrue(report.contains("Labstream playFoo"))
    }
}
