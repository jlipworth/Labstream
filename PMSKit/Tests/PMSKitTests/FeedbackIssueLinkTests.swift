import XCTest
@testable import PMSKit

final class FeedbackIssueLinkTests: XCTestCase {
    private let base = "https://github.com/example/app/issues/new"

    private func context(serverVersion: String? = nil, server: String? = "Emby") -> DiagnosticReportContext {
        DiagnosticReportContext(product: "Labstream", appVersion: "1.8.0", appBuild: "1657",
                                operatingSystem: "Version 27.1 (Build 24B80)", deviceName: "iPhone",
                                deviceModel: "iPhone17,1", installSource: "TestFlight",
                                backend: "Emby", server: server, serverVersion: serverVersion,
                                connectionScheme: "https", selectedQuality: "Original", loggingEnabled: false)
    }

    func testFourPartServerVersionIsNotRedactedAsAnAddress() {
        let report = DiagnosticReportRenderer.render(context: context(serverVersion: "4.8.11.0"), events: [])
        XCTAssertTrue(report.contains("- Server: Emby 4.8.11.0"), report)
        XCTAssertTrue(report.contains("- Device model: iPhone17,1"), report)
        XCTAssertTrue(report.contains("- Install source: TestFlight"), report)
    }

    func testServerVersionCannotCarryAHostOrPath() {
        XCTAssertEqual(DiagnosticReportRenderer.safeVersion("10.9.11 https://nas.example.com:8096/x"),
                       "10.9.11")
        let line = DiagnosticReportRenderer.environmentLine(context: context(serverVersion: "1/2:3 4"))
        XCTAssertTrue(line.contains("· Emby 1 ·"), line)
    }

    func testEnvironmentLineNamesBuildDeviceSourceServerAndScheme() {
        XCTAssertEqual(DiagnosticReportRenderer.environmentLine(context: context(serverVersion: "4.8.11.0")),
                       "Labstream 1.8.0 (1657) · Version 27.1 (Build 24B80) · iPhone17,1 · TestFlight · Emby 4.8.11.0 · https")
    }

    func testRenderMatchesHeadPlusEvents() {
        let parts = DiagnosticReportRenderer.renderParts(context: context(), events: [])
        XCTAssertEqual(DiagnosticReportRenderer.render(context: context(), events: [],
                                                       generatedAt: Date(timeIntervalSince1970: 0)).hasSuffix("\n(none)"), true)
        XCTAssertTrue(parts.head.hasSuffix("Recent redacted events (JSONL, oldest to newest)"))
        XCTAssertEqual(parts.eventLines, [])
    }

    func testLinkAlwaysCarriesTheHeadAndFitsNewestEvents() throws {
        let head = "HEAD"
        let events = (1...200).map { #"{"n":\#($0),"name":"playback.tick","pad":"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"}"# }
        let result = FeedbackIssueLink.make(base: base, note: "Video froze\nafter a seek", environment: "ENV",
                                            parts: .init(head: head, eventLines: events), maxLength: 3000)
        XCTAssertLessThanOrEqual(result.url.count, 3000)
        XCTAssertTrue(result.includesReport)
        XCTAssertGreaterThan(result.includedEvents, 0)
        XCTAssertLessThan(result.includedEvents, 200)
        let items = try XCTUnwrap(URLComponents(string: result.url)?.queryItems)
        let value = { (name: String) in items.first { $0.name == name }?.value }
        XCTAssertEqual(value("template"), "app_report.yml")
        XCTAssertEqual(value("title"), "Video froze")
        XCTAssertEqual(value("what-happened"), "Video froze\nafter a seek")
        XCTAssertEqual(value("environment"), "ENV")
        let report = try XCTUnwrap(value("report"))
        XCTAssertTrue(report.hasPrefix("HEAD\n("), report)
        XCTAssertTrue(report.contains("older events omitted"))
        XCTAssertTrue(report.hasSuffix(events[199]), "the newest event must be kept")
        XCTAssertFalse(report.contains(#""n":1,"#), "the oldest event must be dropped first")
    }

    func testLinkDropsTheReportOnlyWhenTheHeadCannotFit() {
        let result = FeedbackIssueLink.make(base: base, note: "x", environment: "ENV",
                                            parts: .init(head: String(repeating: "h", count: 500), eventLines: ["e"]),
                                            maxLength: 300)
        XCTAssertFalse(result.includesReport)
        XCTAssertFalse(result.url.contains("report="))
        XCTAssertTrue(result.url.contains("environment=ENV"))
    }

    func testNoPartsBuildsTheShortLinkForAQRCode() {
        let result = FeedbackIssueLink.make(base: base, note: "", environment: "ENV", parts: nil)
        XCTAssertEqual(result.url, "\(base)?template=app_report.yml&environment=ENV")
    }

    func testReservedCharactersAreEscaped() {
        XCTAssertEqual(FeedbackIssueLink.encoded("a&b=c+d #e"), "a%26b%3Dc%2Bd%20%23e")
        XCTAssertEqual(FeedbackIssueLink.title(from: String(repeating: "word ", count: 30)).count, 72)
    }
}
