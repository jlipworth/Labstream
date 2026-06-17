import XCTest
@testable import PMSKit

final class DiagnosticLoggingTests: XCTestCase {
    func testStoreIsOffByDefaultAndBoundedWhenEnabled() {
        let store = DiagnosticLogStore(capacity: 2, clock: { Date(timeIntervalSince1970: 1_000) })

        XCTAssertFalse(store.isEnabled)
        XCTAssertNil(store.record(category: .playback, name: "ignored"))
        XCTAssertTrue(store.snapshot().isEmpty)

        store.setEnabled(true)
        XCTAssertNotNil(store.record(category: .playback, name: "one"))
        XCTAssertNotNil(store.record(category: .downloads, name: "two"))
        XCTAssertNotNil(store.record(category: .music, name: "three"))

        let events = store.snapshot()
        XCTAssertEqual(events.map(\.name), ["two", "three"])
    }

    func testRedactionRemovesSecretsUrlsHostsPathsFilenamesAndRawIdentifiers() {
        let raw = "https://alice.example.com:32400/library/metadata/1?X-Plex-Token=secret-token clientIdentifier=ABCDEF0123456789ABCDEF0123456789 host=192.0.2.10 file=/path/to/user/Movies/Blade Runner 2049.mkv email=alice@example.com"
        let redacted = DiagnosticRedactor.redact(raw)

        XCTAssertFalse(redacted.contains("secret-token"))
        XCTAssertFalse(redacted.contains("alice.example.com"))
        XCTAssertFalse(redacted.contains("192.0.2.10"))
        XCTAssertFalse(redacted.contains("/path/to/user"))
        XCTAssertFalse(redacted.contains("Blade Runner 2049.mkv"))
        XCTAssertFalse(redacted.contains("alice@example.com"))
        XCTAssertFalse(redacted.contains("ABCDEF0123456789ABCDEF0123456789"))
        XCTAssertTrue(redacted.contains("[url:https]"))
        XCTAssertTrue(redacted.contains("clientIdentifier=[redacted]") || redacted.contains("clientidentifier=[redacted]"))
    }

    func testReportRenderingIncludesContextSnapshotAndRedactedJSONL() throws {
        let store = DiagnosticLogStore(capacity: 10, enabled: true, clock: { Date(timeIntervalSince1970: 1_700_000_000) })
        store.record(category: .playback, name: "playback.snapshot", fields: [
            "observed_bitrate_kbps": .double(4200.25),
            "stream_url": .text("https://plex.internal:32400/video/:/transcode/universal/start.m3u8?X-Plex-Token=topsecret"),
            "session_id": .identifier("plex-avp-ABCDEF0123456789ABCDEF0123456789")
        ])
        store.record(category: .transcode, name: "decision", fields: [
            "source_container": .label("mkv"),
            "video_decision": .label("copy"),
            "client": .text("X-Plex-Client-Identifier=ABCDEF0123456789ABCDEF0123456789"),
            "media_title": .text("Blade Runner 2049"),
            "full_url": .text("https://example.com/library/metadata/1?X-Plex-Token=anothersecret")
        ])

        let context = DiagnosticReportContext(product: "VisionPlex",
                                              appVersion: "1.0",
                                              appBuild: "42",
                                              operatingSystem: "visionOS 26.5",
                                              deviceName: "Apple Vision Pro",
                                              backend: "Plex",
                                              server: "Plex Media Server 1.40",
                                              connectionScheme: "https",
                                              selectedQuality: "8 Mbps",
                                              loggingEnabled: true)
        let report = DiagnosticReportRenderer.render(context: context,
                                                     events: store.snapshot(),
                                                     generatedAt: Date(timeIntervalSince1970: 1_700_000_010))

        XCTAssertTrue(report.contains("VisionPlex Diagnostic Report"))
        XCTAssertTrue(report.contains("Diagnostic logging enabled: yes"))
        XCTAssertTrue(report.contains("observed_bitrate_kbps"))
        XCTAssertTrue(report.contains("Recent redacted events"))
        XCTAssertFalse(report.contains("topsecret"))
        XCTAssertFalse(report.contains("anothersecret"))
        XCTAssertFalse(report.contains("plex.internal"))
        XCTAssertFalse(report.contains("example.com"))
        XCTAssertFalse(report.contains("Blade Runner 2049"))
        XCTAssertFalse(report.contains("ABCDEF0123456789ABCDEF0123456789"))
        XCTAssertFalse(report.contains("start.m3u8?"))
        XCTAssertTrue(report.contains("\"media_title\":\"[omitted]\""))
    }

    func testJSONLineDoesNotRedactSafeLongKeysOrEventNamesAsTokens() {
        let streamURL = URL(string: "https://plex.internal:32400/video/:/transcode/universal/start.m3u8?X-Plex-Token=secret")
        let event = DiagnosticEvent(category: .playback,
                                    name: "playback.stall_watchdog_cancelled",
                                    fields: [
                                        "plays_whole_file_directly": .bool(false),
                                        "stall_watchdog_timeout_seconds": .int(15),
                                        "stream_url_shape": .urlShape(streamURL)
                                    ])

        let line = event.jsonLine()

        XCTAssertTrue(line.contains("playback.stall_watchdog_cancelled"))
        XCTAssertTrue(line.contains("plays_whole_file_directly"))
        XCTAssertTrue(line.contains("stall_watchdog_timeout_seconds"))
        XCTAssertTrue(line.contains("stream_url_shape"))
        XCTAssertFalse(line.contains("[token]"))
        XCTAssertFalse(line.contains("plex.internal"))
        XCTAssertFalse(line.contains("secret"))
    }

}
