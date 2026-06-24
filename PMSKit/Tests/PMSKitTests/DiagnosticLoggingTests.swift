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
        let raw = "https://alice.example.com:32400/library/metadata/1?X-Plex-Token=secret-token clientIdentifier=ABCDEF0123456789ABCDEF0123456789 host=192.168.1.44 file=/Users/alice/Movies/Blade Runner 2049.mkv email=alice@example.com"
        let redacted = DiagnosticRedactor.redact(raw)

        XCTAssertFalse(redacted.contains("secret-token"))
        XCTAssertFalse(redacted.contains("alice.example.com"))
        XCTAssertFalse(redacted.contains("192.168.1.44"))
        XCTAssertFalse(redacted.contains("/Users/alice"))
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

        let context = DiagnosticReportContext(product: "VisionPlay",
                                              appVersion: "1.0",
                                              appBuild: "42",
                                              operatingSystem: "visionOS 26.5",
                                              deviceName: "Apple Vision Pro",
                                              backend: "Plex",
                                              server: "Plex Media Server 1.40",
                                              connectionScheme: "https",
                                              selectedQuality: "8 Mbps",
                                              adaptiveBitrateEnabled: false,
                                              loggingEnabled: true)
        let report = DiagnosticReportRenderer.render(context: context,
                                                     events: store.snapshot(),
                                                     generatedAt: Date(timeIntervalSince1970: 1_700_000_010))

        XCTAssertTrue(report.contains("VisionPlay Diagnostic Report"))
        XCTAssertTrue(report.contains("Diagnostic logging enabled: yes"))
        XCTAssertTrue(report.contains("Adaptive Bitrate: disabled"))
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

    /// The best-effort redactor cannot scrub a personal server name with no dot/TLD (it looks like
    /// an ordinary label), so the call-site must NEVER pass the raw user-chosen name. This asserts
    /// the sanitized server line the SettingsView call-site produces keeps the personal name out of
    /// the rendered report — and demonstrates why redact() alone is not a sufficient defense.
    func testReportDoesNotLeakPersonalServerName() {
        let personalName = "Some Person s Laptop"

        // First, prove the renderer/redactor would leak it verbatim if handed the raw name —
        // this is the failure the call-site fix prevents.
        let leaky = DiagnosticReportContext(product: "VisionPlay",
                                            appVersion: "1.0",
                                            appBuild: "42",
                                            operatingSystem: "visionOS 26.5",
                                            deviceName: "Apple Vision Pro",
                                            backend: "Plex",
                                            server: "\(personalName) 1.40",
                                            connectionScheme: "https",
                                            selectedQuality: "8 Mbps",
                                            loggingEnabled: true)
        XCTAssertTrue(DiagnosticReportRenderer.render(context: leaky, events: []).contains(personalName),
                      "redact() is not expected to scrub a dotless personal name; the call-site must sanitize")

        // The fixed call-site emits only the product + version, never the user's server name.
        let sanitized = DiagnosticReportContext(product: "VisionPlay",
                                                appVersion: "1.0",
                                                appBuild: "42",
                                                operatingSystem: "visionOS 26.5",
                                                deviceName: "Apple Vision Pro",
                                                backend: "Plex",
                                                server: "Plex Media Server 1.40",
                                                connectionScheme: "https",
                                                selectedQuality: "8 Mbps",
                                                loggingEnabled: true)
        let report = DiagnosticReportRenderer.render(context: sanitized, events: [])
        XCTAssertFalse(report.contains(personalName),
                       "rendered report must not contain the personal server name")
        XCTAssertTrue(report.contains("Plex Media Server 1.40"))
    }

    // MARK: - Free-text feedback note (#85): adversarial redaction of the optional
    // "What were you doing?" note. FeedbackSheet folds the note in ONLY through
    // `DiagnosticRedactor.redact(note)`, so these exercise that single trust boundary on
    // the kinds of prose a user might type. Where a class is a known residual gap, the
    // assertion documents it (the live preview + privacy footer/checkbox are the mitigation).

    /// 1. Odd-separator tokens: `=`-style secrets with comma/semicolon/newline separators are
    /// scrubbed. The colon form (`X-Plex-Token: …`) is a documented residual — the redactor's
    /// secret rules key off `=`, so a value after a colon survives.
    func testFeedbackNoteRedactsOddSeparatorTokens() {
        let note = "config token=tok99abc,then client_identifier=DEADBEEF;password=hunter2\nX-Plex-Token=lineSecret"
        let redacted = DiagnosticRedactor.redact(note)

        XCTAssertFalse(redacted.contains("tok99abc"), "comma-terminated token value must be gone")
        XCTAssertFalse(redacted.contains("DEADBEEF"), "semicolon-terminated client_identifier must be gone")
        XCTAssertFalse(redacted.contains("hunter2"), "password value must be gone")
        XCTAssertFalse(redacted.contains("lineSecret"), "newline-terminated token value must be gone")
        XCTAssertTrue(redacted.contains("token=[redacted]"))

        // Documented residual: the colon header form is NOT covered by the `=`-based rules.
        let colon = DiagnosticRedactor.redact("X-Plex-Token: secretColonValue")
        XCTAssertTrue(colon.contains("secretColonValue"),
                      "colon-form header secret is a known residual; preview + privacy ack are the mitigation")
    }

    /// 2. Prose URLs / bare hosts / IPs embedded in free text → [url:…] / [host] / [ip].
    func testFeedbackNoteRedactsProseUrlsHostsAndIPs() {
        let note = "I opened https://alice.example.com/library and it pointed at server.lan, also 192.0.2.10 failed"
        let redacted = DiagnosticRedactor.redact(note)

        XCTAssertFalse(redacted.contains("alice.example.com"))
        XCTAssertFalse(redacted.contains("server.lan"))
        XCTAssertFalse(redacted.contains("192.0.2.10"))
        XCTAssertTrue(redacted.contains("[url:https]"))
        XCTAssertTrue(redacted.contains("[host]"))
        XCTAssertTrue(redacted.contains("[ip]"))
    }

    /// 3. File-shaped media title (`… .mkv`) → [file]; a BARE prose title is an accepted
    /// residual (the user can see it in the preview and edit it out).
    func testFeedbackNoteRedactsFileShapedTitleButNotBareProseTitle() {
        let fileShaped = DiagnosticRedactor.redact("crash while playing Blade Runner 2049.mkv")
        XCTAssertFalse(fileShaped.contains("Blade Runner 2049.mkv"))
        XCTAssertFalse(fileShaped.contains("2049.mkv"))
        XCTAssertTrue(fileShaped.contains("[file]"))

        // Documented residual: a title with no filename extension looks like ordinary prose.
        let bareTitle = DiagnosticRedactor.redact("crash while watching Blade Runner 2049")
        XCTAssertTrue(bareTitle.contains("Blade Runner 2049"),
                      "a bare prose media title is an accepted residual; the live preview is the mitigation")
    }

    /// 4. A dotless personal name (`Bob's Laptop`) survives — documents the redactor limit
    /// that motivates the SettingsView call-site never passing the raw Plex server name.
    func testFeedbackNoteDotlessPersonalNameIsAcceptedResidual() {
        let redacted = DiagnosticRedactor.redact("it broke on Bob's Laptop after dinner")
        XCTAssertTrue(redacted.contains("Bob's Laptop"),
                      "a dotless personal name looks like an ordinary label; documented residual")
    }

    /// 5. Bracketed IPv6 → [ip]. A zone-id'd literal (`[fe80::1%en0]`) and a bare,
    /// bracket-less IPv6 are documented residuals (the `%`/letters break the bracket rule).
    func testFeedbackNoteRedactsBracketedIPv6AndDocumentsResiduals() {
        let redacted = DiagnosticRedactor.redact("reached [2001:db8::1] but [fe80::1%en0] and bare 2001:db8::1 failed")

        XCTAssertFalse(redacted.contains("[2001:db8::1]"), "bracketed IPv6 must collapse to [ip]")
        XCTAssertTrue(redacted.contains("[ip]"))

        // Documented residuals: zone-id'd and bare-IPv6 forms are not caught by the bracket rule.
        XCTAssertTrue(redacted.contains("fe80::1%en0"),
                      "zone-id'd IPv6 is a known residual (the %en0 suffix breaks the bracket class)")
        XCTAssertTrue(redacted.contains("bare 2001:db8::1"),
                      "bracket-less IPv6 is a known residual")
    }

    /// 6. Email + credentials in prose: the email's DOMAIN is host-redacted and `password=` is
    /// scrubbed. Documented residuals: the host rule fires before the email rule so the local
    /// part survives (`alice@[host]`, not `[email]`), and `pw=`/`pass=` are not header-pattern keys.
    func testFeedbackNoteRedactsEmailDomainAndPasswordCredential() {
        let redacted = DiagnosticRedactor.redact("email me at alice@example.com password=hunter2 or pw=foo")

        XCTAssertFalse(redacted.contains("example.com"), "the email domain must be host-redacted")
        XCTAssertFalse(redacted.contains("hunter2"), "password= value must be redacted")
        XCTAssertTrue(redacted.contains("password=[redacted]"))

        // Documented residuals: local-part survives (host rule pre-empts the email rule), and
        // non-standard credential keys (`pw=`/`pass=`) are not in the header pattern.
        XCTAssertTrue(redacted.contains("alice@[host]"),
                      "host rule pre-empts the email rule, leaving the local part — documented residual")
        XCTAssertTrue(redacted.contains("pw=foo"),
                      "pw=/pass= are not header-pattern keys; documented residual")
    }

}
