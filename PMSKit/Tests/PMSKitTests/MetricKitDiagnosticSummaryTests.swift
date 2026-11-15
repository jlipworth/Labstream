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
            terminationReason: "Namespace SIGNAL, Code 11 at /Users/someone/Library/foo.dylib"
        )
        let summary = MetricKitDiagnosticSummarizer.summarize(input)
        XCTAssertTrue(summary.headline.contains("[path]"), summary.headline)
        XCTAssertFalse(summary.headline.contains("/Users/"))
        XCTAssertFalse(summary.headline.contains("someone"))
    }

    func testCallStackFramesAreCappedAndRedacted() {
        let frames = (0..<20).map { "Labstream frame\($0) /Users/dev/build/Labstream.app/bin" }
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

final class MetricKitCallStackParserTests: XCTestCase {
    private let crashTree = Data("""
    {"callStackPerThread": true, "callStacks": [
      {"threadAttributed": false, "callStackRootFrames": [
        {"binaryUUID": "11111111-2222-3333-4444-555555555555", "offsetIntoBinaryTextSegment": 100,
         "sampleCount": 1, "binaryName": "libsystem_kernel.dylib", "address": 7000000100}]},
      {"threadAttributed": true, "callStackRootFrames": [
        {"binaryUUID": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", "offsetIntoBinaryTextSegment": 1715772,
         "sampleCount": 1, "binaryName": "Labstream", "address": 4311765564,
         "subFrames": [
           {"binaryUUID": "99999999-2222-3333-4444-555555555555", "offsetIntoBinaryTextSegment": 4096,
            "sampleCount": 1, "binaryName": "SwiftUI", "address": 6900004096}]}]}
    ]}
    """.utf8)

    func testKeepsOnlyTheAttributedThreadAsBinaryOffsets() {
        let stack = MetricKitCallStackParser.stack(fromJSON: crashTree, appBinaryName: "Labstream")
        XCTAssertEqual(stack.frames, ["Labstream +0x1a2e3c", "SwiftUI +0x1000"])
        XCTAssertEqual(stack.appBinaryUUID, "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
    }

    func testSampledTreeFollowsTheHeaviestBranch() {
        let tree = Data("""
        {"callStackPerThread": false, "callStacks": [{"callStackRootFrames": [
          {"binaryName": "Labstream", "offsetIntoBinaryTextSegment": 16, "sampleCount": 9, "subFrames": [
            {"binaryName": "Labstream", "offsetIntoBinaryTextSegment": 32, "sampleCount": 2},
            {"binaryName": "Foundation", "offsetIntoBinaryTextSegment": 48, "sampleCount": 7}]}]}]}
        """.utf8)
        let stack = MetricKitCallStackParser.stack(fromJSON: tree, appBinaryName: "Labstream")
        XCTAssertEqual(stack.frames, ["Labstream +0x10", "Foundation +0x30"])
        XCTAssertNil(stack.appBinaryUUID)
    }

    func testMalformedTreeYieldsNoFrames() {
        XCTAssertEqual(MetricKitCallStackParser.stack(fromJSON: Data("nope".utf8), appBinaryName: nil).frames, [])
    }

    func testOffsetFramesAndBinaryUUIDSurviveSummaryRendering() {
        let stack = MetricKitCallStackParser.stack(fromJSON: crashTree, appBinaryName: "Labstream")
        let summary = MetricKitDiagnosticSummarizer.summarize(MetricKitDiagnosticInput(
            kind: .crash, date: Date(timeIntervalSince1970: 1_700_000_000), exceptionType: "EXC_BREAKPOINT",
            callStackFrames: stack.frames, appBinaryUUID: stack.appBinaryUUID))
        let lines = MetricKitDiagnosticSummarizer.reportLines(for: summary)
        XCTAssertTrue(lines.contains("    Labstream +0x1a2e3c"), "\(lines)")
        XCTAssertTrue(lines.contains("    app binary UUID: AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"), "\(lines)")
    }

    func testSummaryStoredByAnEarlierBuildStillDecodes() throws {
        let old = Data(#"[{"kind":"Crash","timestamp":"2026-11-01T00:00:00Z","headline":"x","topFrames":["a"]}]"#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([MetricKitDiagnosticSummary].self, from: old)
        XCTAssertNil(decoded.first?.appBinaryUUID)
    }
}
