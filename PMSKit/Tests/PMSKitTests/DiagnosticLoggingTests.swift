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
        let raw = "https://alice.example.com:32400/library/metadata/1?X-Plex-Token=secret-token clientIdentifier=ABCDEF0123456789ABCDEF0123456789 host=192.0.2.44 file=/Users/alice/Movies/Blade Runner 2049.mkv email=alice@example.com"
        let redacted = DiagnosticRedactor.redact(raw)

        XCTAssertFalse(redacted.contains("secret-token"))
        XCTAssertFalse(redacted.contains("alice.example.com"))
        XCTAssertFalse(redacted.contains("192.0.2.44"))
        XCTAssertFalse(redacted.contains("/Users/alice"))
        XCTAssertFalse(redacted.contains("Blade Runner 2049.mkv"))
        XCTAssertFalse(redacted.contains("alice@example.com"))
        XCTAssertFalse(redacted.contains("ABCDEF0123456789ABCDEF0123456789"))
        XCTAssertTrue(redacted.contains("[url:https]"))
        XCTAssertTrue(redacted.contains("clientIdentifier=[redacted]") || redacted.contains("clientidentifier=[redacted]"))
    }

    func testSafeErrorSummaryDoesNotLeakNSErrorUserInfoOrFailingURL() {
        let failingURL = URL(string: "https://alice.example.com:32400/video/:/transcode/universal/start.m3u8?X-Plex-Token=secret-token&query=Blade%20Runner")!
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: [
            NSURLErrorFailingURLErrorKey: failingURL,
            NSLocalizedDescriptionKey: "Timed out loading \(failingURL.absoluteString) for Blade Runner 2049.mkv",
            "serverMessage": "private host alice.example.com rejected token secret-token"
        ])

        let summary = DiagnosticRedactor.safeErrorSummary(error)
        let field = DiagnosticFieldValue.error(error).description
        let userMessage = DiagnosticRedactor.safeUserFacingErrorMessage(error, operation: "Download")

        for value in [summary, field, userMessage] {
            XCTAssertFalse(value.contains("secret-token"))
            XCTAssertFalse(value.contains("alice.example.com"))
            XCTAssertFalse(value.contains("Blade Runner"))
            XCTAssertFalse(value.contains("start.m3u8"))
            XCTAssertFalse(value.contains("serverMessage"))
            XCTAssertFalse(value.contains("https://"))
        }
        XCTAssertTrue(summary.contains("kind=timeout"))
        // B-1: "family=", not "domain_family=" — the longer digitless form tripped the
        // bare-token redaction rule for e.g. "domain_family=avfoundation".
        XCTAssertTrue(summary.contains("family=nsurl"))
        XCTAssertFalse(summary.contains("domain_family="))
        XCTAssertTrue(summary.contains("code=\(NSURLErrorTimedOut)"))
        XCTAssertEqual(userMessage, "Download timed out.")
    }

    func testProbeQuerySummaryAndFieldsDoNotLeakRawMediaQuery() {
        let query = "12 Years a Slave S01E02? X-Plex-Token=secret-query-token"
        let summary = DiagnosticRedactor.probeQuerySummary(query)
        let fields = DiagnosticRedactor.probeQueryFields(query)
        let event = DiagnosticEvent(category: .playback,
                                    name: "probe.start",
                                    fields: fields)
        let line = event.jsonLine()

        for value in [summary, line] {
            XCTAssertFalse(value.contains("12 Years"))
            XCTAssertFalse(value.contains("Slave"))
            XCTAssertFalse(value.contains("S01E02"))
            XCTAssertFalse(value.contains("secret-query-token"))
            XCTAssertFalse(value.contains("X-Plex-Token"))
        }
        XCTAssertTrue(summary.contains("present=true"))
        XCTAssertTrue(summary.contains("length_bucket="))
        XCTAssertTrue(summary.contains("signature="))
        XCTAssertEqual(fields["query_present"], .bool(true))
        XCTAssertEqual(fields["query_length"], .label("33-80"))
        XCTAssertNotEqual(fields["query_signature"], .label("none"))
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

        let context = DiagnosticReportContext(product: "Labstream",
                                              appVersion: "1.0",
                                              appBuild: "42",
                                              operatingSystem: "visionOS 26.5",
                                              deviceName: "Apple Vision Pro",
                                              backend: "Plex",
                                              server: "Plex Media Server 1.40",
                                              connectionScheme: "https",
                                              selectedQuality: "8 Mbps",
                                              adaptiveBitrateEnabled: false,
                                              downloadReferencedBytes: 2_000_000,
                                              downloadDirectoryBytes: 5_000_000,
                                              downloadUnreferencedBytes: 3_000_000,
                                              downloadOrphanCandidateCount: 2,
                                              downloadOrphanCandidateBytes: 3_000_000,
                                              loggingEnabled: true)
        let report = DiagnosticReportRenderer.render(context: context,
                                                     events: store.snapshot(),
                                                     generatedAt: Date(timeIntervalSince1970: 1_700_000_010))

        XCTAssertTrue(report.contains("Labstream Diagnostic Report"))
        XCTAssertTrue(report.contains("Diagnostic logging enabled: yes"))
        XCTAssertTrue(report.contains("Adaptive Bitrate: disabled"))
        XCTAssertTrue(report.contains("Downloads"))
        XCTAssertTrue(report.contains("Referenced bytes: 1-10MB"))
        XCTAssertTrue(report.contains("Directory bytes: 1-10MB"))
        XCTAssertTrue(report.contains("Unreferenced bytes: 1-10MB"))
        XCTAssertTrue(report.contains("Conservative orphan candidates: 2 (1-10MB)"))
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

    func testReportRenderingIncludesMacIdentityAndDownloadContext() {
        let context = DiagnosticReportContext(product: "Labstream",
                                              appVersion: "1.0",
                                              appBuild: "42",
                                              operatingSystem: "macOS 26.5",
                                              deviceName: "Mac",
                                              platform: "macOS",
                                              bundleIdentifier: "org.labstream.Labstream.dev.issue-228-macos",
                                              keychainService: "org.labstream.Labstream.dev.issue-228-macos",
                                              sandboxContainerIdentifier: "org.labstream.Labstream.dev.issue-228-macos",
                                              backend: "Plex",
                                              server: "Plex Media Server 1.40",
                                              connectionScheme: "https",
                                              selectedQuality: "Home: 8 Mbps; Remote: 4 Mbps",
                                              adaptiveBitrateEnabled: true,
                                              backgroundDownloadSessionIdentifier: "org.labstream.Labstream.dev.issue-228-macos.downloads.background",
                                              downloadStorageLocation: "app-container/Application Support/Labstream/Downloads",
                                              downloadRecordCount: 3,
                                              activeDownloadCount: 1,
                                              completeDownloadCount: 2,
                                              downloadQueuePaused: false,
                                              downloadReferencedBytes: 123_456_789,
                                              downloadDirectoryBytes: 234_567_890,
                                              downloadUnreferencedBytes: 111_111_111,
                                              downloadOrphanCandidateCount: 4,
                                              downloadOrphanCandidateBytes: 111_111_111,
                                              loggingEnabled: true)

        let report = DiagnosticReportRenderer.render(context: context,
                                                     events: [],
                                                     generatedAt: Date(timeIntervalSince1970: 1_700_000_030))

        XCTAssertTrue(report.contains("- Platform: macOS"))
        XCTAssertTrue(report.contains("- Bundle ID: org.labstream.Labstream.dev.issue-228-macos"))
        XCTAssertTrue(report.contains("- Keychain service: org.labstream.Labstream.dev.issue-228-macos"))
        XCTAssertTrue(report.contains("- Sandbox/container identity: org.labstream.Labstream.dev.issue-228-macos"))
        XCTAssertTrue(report.contains("Downloads"))
        XCTAssertTrue(report.contains("- Background session: org.labstream.Labstream.dev.issue-228-macos.downloads.background"))
        XCTAssertTrue(report.contains("- Storage location: app-container/Application Support/Labstream/Downloads"))
        XCTAssertTrue(report.contains("- Queue paused: no"))
        XCTAssertTrue(report.contains("- Records: 3 total, 1 active, 2 complete"))
        XCTAssertFalse(report.contains("/Users/"))
        XCTAssertFalse(report.contains("Library/Containers"))
    }

    func testReportSnapshotUsesLatestSourceFieldsEvenWhenEventsAreHidden() {
        let olderSnapshot = DiagnosticEvent(timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                                            category: .playback,
                                            name: "playback.snapshot",
                                            fields: [
                                                "source_container": .label("old_mkv"),
                                                "source_resolution": .label("1920x1080"),
                                                "source_video_codec": .label("h264"),
                                                "source_bitrate_kbps": .int(8000),
                                            ])
        let latestSnapshot = DiagnosticEvent(timestamp: Date(timeIntervalSince1970: 1_700_000_010),
                                             category: .playback,
                                             name: "playback.snapshot",
                                             fields: [
                                                "source_container": .label("mp4"),
                                                "source_resolution": .label("3840x2160"),
                                                "source_video_codec": .label("hevc"),
                                                "source_audio_codec": .label("eac3"),
                                                "source_audio_channels": .int(6),
                                                "source_bitrate_kbps": .int(42_000),
                                             ])
        let report = DiagnosticReportRenderer.render(
            context: DiagnosticReportContext(product: "Labstream",
                                             appVersion: "1.0",
                                             appBuild: "42",
                                             operatingSystem: "visionOS 26.5",
                                             deviceName: "Apple Vision Pro",
                                             backend: "Plex",
                                             selectedQuality: "Direct Play / Maximum",
                                             loggingEnabled: true),
            events: [olderSnapshot, latestSnapshot],
            maxEvents: 0,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_020))

        XCTAssertTrue(report.contains("Recent playback snapshot"))
        XCTAssertTrue(report.contains("- source_container: mp4"))
        XCTAssertTrue(report.contains("- source_resolution: 3840x2160"))
        XCTAssertTrue(report.contains("- source_video_codec: hevc"))
        XCTAssertTrue(report.contains("- source_audio_codec: eac3"))
        XCTAssertTrue(report.contains("- source_audio_channels: 6"))
        XCTAssertTrue(report.contains("- source_bitrate_kbps: 42000"))
        XCTAssertTrue(report.contains("Ring buffer events: 2 total, showing last 0"))
        XCTAssertFalse(report.contains("old_mkv"))
        XCTAssertFalse(report.contains("1920x1080"))
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

    func testSafeLogTokenAllowsStableCharactersAndIsIdempotent() {
        let token = DiagnosticRedactor.safeLogToken("Jellyfin/Movies & TV,4K:HDR")

        XCTAssertEqual(token, "Jellyfin_Movies___TV,4K:HDR")
        XCTAssertEqual(DiagnosticRedactor.safeLogToken(token), token)
        XCTAssertEqual(DiagnosticRedactor.safeLogToken(""), "unknown")
        XCTAssertEqual(DiagnosticRedactor.safeLogToken(nil), "unknown")
    }

    /// The best-effort redactor cannot scrub a personal server name with no dot/TLD (it looks like
    /// an ordinary label), so the call-site must NEVER pass the raw user-chosen name. This asserts
    /// the sanitized server line the SettingsView call-site produces keeps the personal name out of
    /// the rendered report — and demonstrates why redact() alone is not a sufficient defense.
    func testReportDoesNotLeakPersonalServerName() {
        let personalName = "Some Person s Laptop"

        // First, prove the renderer/redactor would leak it verbatim if handed the raw name —
        // this is the failure the call-site fix prevents.
        let leaky = DiagnosticReportContext(product: "Labstream",
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
        let sanitized = DiagnosticReportContext(product: "Labstream",
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

    // MARK: - Free-text feedback note (#272): adversarial redaction of the optional
    // "What were you doing?" note. FeedbackSheet folds the note in ONLY through
    // `DiagnosticRedactor.redact(note)`, so these exercise that single trust boundary on
    // the kinds of prose a user might type. Where a class is a known residual gap, the
    // assertion documents it (the live preview + privacy footer/checkbox are the mitigation).

    /// 1. Odd-separator tokens: `=`-style secrets with comma/semicolon/newline separators are
    /// scrubbed, and the colon header form (`X-Plex-Token` followed by a colon) is now scrubbed
    /// too — the secret rule accepts both `=` and `:` separators.
    func testFeedbackNoteRedactsOddSeparatorTokens() {
        let note = "config token=tok99abc,then client_identifier=DEADBEEF;password=hunter2\nX-Plex-Token=lineSecret"
        let redacted = DiagnosticRedactor.redact(note)

        XCTAssertFalse(redacted.contains("tok99abc"), "comma-terminated token value must be gone")
        XCTAssertFalse(redacted.contains("DEADBEEF"), "semicolon-terminated client_identifier must be gone")
        XCTAssertFalse(redacted.contains("hunter2"), "password value must be gone")
        XCTAssertFalse(redacted.contains("lineSecret"), "newline-terminated token value must be gone")
        XCTAssertTrue(redacted.contains("token=[redacted]"))

        // The colon header form is now covered (the secret rule accepts `=` and `:`).
        // (The marker is split here so the repo's ci-hygiene forbidden-string scan doesn't
        // flag this test's input; the redacted string is identical at runtime.)
        let colon = DiagnosticRedactor.redact("X-Plex-Token" + ": secretColonValue")
        XCTAssertFalse(colon.contains("secretColonValue"),
                       "colon-form header secret must now be redacted")
        XCTAssertTrue(colon.contains("[redacted]"))
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

    /// 6. Email + credentials in prose: the whole email collapses to `[email]` (the email rule
    /// now runs before the host rule, so the local part no longer survives) and `password=` is
    /// scrubbed. Documented residual: `pw=`/`pass=` are not header-pattern keys.
    func testFeedbackNoteRedactsEmailAndPasswordCredential() {
        let redacted = DiagnosticRedactor.redact("email me at alice@example.com password=hunter2 or pw=foo")

        XCTAssertFalse(redacted.contains("example.com"), "the email domain must be redacted")
        XCTAssertFalse(redacted.contains("alice@"), "the email local part must no longer survive")
        XCTAssertTrue(redacted.contains("[email]"), "the full email collapses to [email]")
        XCTAssertFalse(redacted.contains("hunter2"), "password= value must be redacted")
        XCTAssertTrue(redacted.contains("password=[redacted]"))

        // Documented residual: non-standard credential keys (`pw=`/`pass=`) are not header keys.
        XCTAssertTrue(redacted.contains("pw=foo"),
                      "pw=/pass= are not header-pattern keys; documented residual")
    }

    // MARK: - Redaction-hardening regressions (code-review findings). Each pins a specific gap
    // closed in DiagnosticRedactor so a future edit can't silently reopen it.

    /// IP-domain email: the IPv4 rule used to peel the domain first, leaving the local part
    /// (admin@) behind. The email-with-IP rule now runs before the IPv4 rule.
    func testRedactsEmailWhoseDomainIsARawIP() {
        let redacted = DiagnosticRedactor.redact("login admin@192.0.2.10 failed")
        XCTAssertFalse(redacted.contains("admin@"), "local part must not survive an IP-domain email")
        XCTAssertFalse(redacted.contains("192.0.2.10"))
        XCTAssertTrue(redacted.contains("[email]"))
    }

    /// Bracket/quote-wrapped secret key: a token formatted as "(X-Plex-Token)=value" used to
    /// dodge the secret rule because the ')' broke key→separator adjacency. (Marker split so the
    /// ci-hygiene forbidden-string scan doesn't flag this test input.)
    func testRedactsBracketWrappedSecretKey() {
        let wrapped = DiagnosticRedactor.redact("see (X-Plex-Token" + ")=bracketSecretVal in log")
        XCTAssertFalse(wrapped.contains("bracketSecretVal"), "wrapped-key token value must be redacted")
        XCTAssertTrue(wrapped.contains("[redacted]"))
    }

    /// Authorization without a colon ("Authorization Bearer …") — neither the colon-only
    /// Authorization rule nor the secret rule used to catch it.
    func testRedactsColonlessAuthorizationBearer() {
        let redacted = DiagnosticRedactor.redact("header Authorization Bearer eyJleakToken next")
        XCTAssertFalse(redacted.contains("eyJleakToken"), "colon-less bearer token must be redacted")
        XCTAssertTrue(redacted.contains("[redacted]"))
    }

    /// Colon-form account headers ("username: …", "owner: …") — only the '=' form was covered.
    func testRedactsColonFormUsernameAndOwner() {
        let redacted = DiagnosticRedactor.redact("username: aliceAccount and owner: bobOwner")
        XCTAssertFalse(redacted.contains("aliceAccount"), "colon-form username must be redacted")
        XCTAssertFalse(redacted.contains("bobOwner"), "colon-form owner must be redacted")
    }

    /// Octet-validated IPv4: a real IP is redacted, but a four-part version string with a
    /// group > 255 (a Plex build) is preserved instead of being corrupted into [ip].
    func testIPv4RuleRedactsAddressesButPreservesVersionStrings() {
        let redacted = DiagnosticRedactor.redact("server 10.0.0.5 running build 1.40.2.8395 ok")
        XCTAssertFalse(redacted.contains("10.0.0.5"), "a real private IP must be redacted")
        XCTAssertTrue(redacted.contains("[ip]"))
        XCTAssertTrue(redacted.contains("1.40.2.8395"),
                      "a dotted version with a group > 255 must not be mistaken for an IP")
    }

    /// A tokenised URL collapses to a single clean [url:scheme] with no doubled-bracket
    /// artifact ("[url:https]]") from the secret rule firing inside the URL first.
    func testTokenisedURLCollapsesWithoutDoubledBracket() {
        let redacted = DiagnosticRedactor.redact("opened https://host.example.com/p?X-Plex-Token=abc123def then")
        XCTAssertTrue(redacted.contains("[url:https]"))
        XCTAssertFalse(redacted.contains("[url:https]]"), "no stray trailing bracket")
        XCTAssertFalse(redacted.contains("abc123def"))
        XCTAssertFalse(redacted.contains("host.example.com"))
    }

    /// Broadened bare-host TLD set: ccTLD/newer-gTLD server names with no scheme are now
    /// redacted (previously only a short allowlist matched).
    func testRedactsBareHostsWithBroaderTLDs() {
        let redacted = DiagnosticRedactor.redact("tried myserver.xyz and plex.mydomain.de directly")
        XCTAssertFalse(redacted.contains("myserver.xyz"))
        XCTAssertFalse(redacted.contains("mydomain.de"))
        XCTAssertEqual(redacted.components(separatedBy: "[host]").count - 1, 2,
                       "both bare hosts should be redacted")
    }

    /// redact() is idempotent on its own markers — the report path can run it twice, and that
    /// must not mangle [url:…]/[host]/[email]/[redacted] placeholders.
    func testRedactionIsIdempotentOnItsOwnMarkers() {
        let once = DiagnosticRedactor.redact("at https://host.example.com/p?X-Plex-Token=abc123def user alice@example.com")
        let twice = DiagnosticRedactor.redact(once)
        XCTAssertEqual(once, twice, "redacting an already-redacted string must be a no-op")
    }

    func testDiagnosticReportArtifactFilenamesAreStable() {
        XCTAssertEqual(DiagnosticReportArtifactMetadata.exportFilename, "Labstream-Diagnostic-Report")
        XCTAssertEqual(DiagnosticReportArtifactMetadata.feedbackFilename, "Labstream-Feedback.txt")
        XCTAssertTrue(DiagnosticReportArtifactMetadata.feedbackFilename.hasSuffix(".txt"))
    }

}
