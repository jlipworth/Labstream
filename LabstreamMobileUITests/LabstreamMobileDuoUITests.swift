import XCTest

/// iPhone Duo smoke (credential-free fixtures): browse → detail → playback in folded portrait and
/// both folded-landscape rotations.
///
/// - Folded landscape: the Duo simulator on Xcode 27.1 ignores `XCUIDevice.orientation`, so the
///   rotations come from the DEBUG `--ui-testing-orientation` capture route (a scene geometry
///   request, the same mechanism the player lock uses).
/// - Inner size (669×951 / 951×669) and resize-during-playback are not covered here: on Xcode
///   27.1 XCUITest keeps reporting the outer-display window (466×678) while a host
///   `devicectl device appResize` session (`scripts/duo-appresize.sh`) has moved the app to the
///   Resizable display. That proxy is judged from screenshots and `AppDiagnostics` instead; the
///   DEBUG book override on a folded landscape player is
///   `LabstreamMobileFixtureUITests.testBookPoseMovesTheControlGroupIntoTheTrailingHalf`.
/// - "Nothing under the system column" compares element frames with the vertical bar's measured
///   frame (the tab buttons' and toolbar items' union), never a hardcoded inset.
final class LabstreamMobileDuoUITests: XCTestCase {
    private static let duoModel = "iPhone19,4"
    private static let phoneShortSideLimit: CGFloat = 500

    override func setUpWithError() throws {
        continueAfterFailure = true
        let model = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? ""
        try XCTSkipUnless(model == Self.duoModel, "iPhone Duo only (model \(model))")
    }

    // MARK: - Folded browse → detail → playback

    @MainActor
    func testFoldedPortraitBrowseDetailPlayback() throws {
        try browseDetailPlayback(orientation: nil, expectLandscape: false)
    }

    @MainActor
    func testFoldedLandscapeLeftBrowseDetailPlayback() throws {
        try browseDetailPlayback(orientation: "landscape-left", expectLandscape: true)
    }

    @MainActor
    func testFoldedLandscapeRightBrowseDetailPlayback() throws {
        try browseDetailPlayback(orientation: "landscape-right", expectLandscape: true)
    }

    @MainActor
    private func browseDetailPlayback(orientation: String?, expectLandscape: Bool) throws {
        let label = orientation ?? "portrait"
        let app = launchBrowse(orientation: orientation)
        defer { app.terminate() }

        let card = app.buttons["labstream.home.fixture-resume.plex-orbit"]
        XCTAssertTrue(card.waitForExistence(timeout: 15), "Home card (\(label))")
        try waitForWindow(app, landscape: expectLandscape, context: label)
        let window = app.windows.firstMatch.frame
        let column = try XCTUnwrap(systemColumn(in: app, window: window), "vertical bar (\(label))")
        XCTAssertLessThan(column.width, 100, "a vertical column, not a bottom bar (\(label))")

        // Home: headers, View All and every whole card stay in the content region.
        for header in ["Continue Watching", "Recently Added"] {
            let element = app.staticTexts[header]
            XCTAssertTrue(element.waitForExistence(timeout: 5), "\(header) (\(label))")
            assertClear(element, of: column, window: window, context: "\(header) \(label)")
        }
        let viewAll = app.buttons["View all Recently Added"]
        XCTAssertTrue(viewAll.exists, "View All (\(label))")
        assertClear(viewAll, of: column, window: window, context: "View All \(label)")
        XCTAssertTrue(card.isHittable, "first card hittable (\(label))")
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@",
                                                     "labstream.home.fixture-resume."))
            .allElementsBoundByIndex
        let wholeCards = cards.filter { clears($0.frame, of: column, window: window) }
        XCTAssertGreaterThanOrEqual(wholeCards.count, 3, "at least 3 whole cards (\(label))")
        // A card clipped at the content edge must not take taps through the column's empty
        // stretch (between the toolbar items and the tab capsule). Tap there and stay on Home.
        // (XCUI's `isHittable` uses accessibility hit testing, which ignores the clip, so the
        // check is a real tap.)
        if let cue = cards.first(where: { column.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }) {
            let point = CGPoint(x: cue.frame.midX, y: cue.frame.midY)
            let onControl = app.buttons.allElementsBoundByIndex.contains {
                !$0.identifier.hasPrefix("labstream.home.") && $0.frame.insetBy(dx: -6, dy: -6).contains(point)
            }
            if !onControl {
                app.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: point.x, dy: point.y)).tap()
                Thread.sleep(forTimeInterval: 1.5)
                XCTAssertTrue(app.staticTexts["Continue Watching"].isHittable,
                              "a tap on the column over the clipped cue card stays on Home (\(label))")
            }
        }
        // The Settings toolbar item sits in the column, never over a card.
        let settings = app.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.exists && settings.isHittable, "Settings toolbar item (\(label))")
        XCTAssertTrue(column.insetBy(dx: -4, dy: 0).contains(CGPoint(x: settings.frame.midX,
                                                                     y: settings.frame.midY)),
                      "Settings lives in the column (\(label))")
        attachScreenshot(app, name: "duo-home-\(label)")

        // Detail: one title, the prominent Resume capsule and the circles, clear of the column.
        card.tap()
        let title = app.staticTexts["The Long Orbit"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10), "movie detail (\(label))")
        let resume = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Resume")).firstMatch
        XCTAssertTrue(resume.waitForExistence(timeout: 5), "Resume capsule (\(label))")
        XCTAssertTrue(resume.isHittable, "Resume hittable (\(label))")
        assertClear(title, of: column, window: window, context: "detail title \(label)")
        assertClear(resume, of: column, window: window, context: "Resume \(label)")
        attachScreenshot(app, name: "duo-detail-\(label)")
        app.terminate()

        // Playback: the credential-free player fixture (the browse fixture has no stream).
        try assertPlaybackAdvances(orientation: orientation, context: label)
    }

    @MainActor
    private func assertPlaybackAdvances(orientation: String?, context: String) throws {
        let app = launchPlayer(orientation: orientation, paused: false)
        defer { app.terminate() }
        let surface = app.descendants(matching: .any)["playback.surface"].firstMatch
        XCTAssertTrue(surface.waitForExistence(timeout: 30), "player surface (\(context))")
        // The player locks a phone-class scene to landscape.
        try waitForWindow(app, landscape: true, context: "player \(context)")
        let first = try remainingSeconds(app, context: context)
        Thread.sleep(forTimeInterval: 4)
        let second = try remainingSeconds(app, context: context)
        XCTAssertLessThan(second, first, "playhead advances (\(context)): \(first)s → \(second)s")
        let window = app.windows.firstMatch.frame
        for element in [app.buttons["Close"], app.sliders["playback.timeline"]] where element.exists {
            XCTAssertTrue(window.contains(element.frame), "\(element.label) inside window (\(context))")
            XCTAssertTrue(element.isHittable, "\(element.label) hittable (\(context))")
        }
        attachScreenshot(app, name: "duo-player-\(context)")
    }

    // MARK: - Helpers

    @MainActor
    private func launchBrowse(orientation: String?) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["LABSTREAM_UNIT_TEST_HOST"] = "0"
        app.launchArguments = ["--ui-testing", "--ui-testing-backend", "plex", "--ui-testing-fixture", "browse"]
            + (orientation.map { ["--ui-testing-orientation", $0] } ?? [])
        app.launch()
        return app
    }

    @MainActor
    private func launchPlayer(orientation: String?, paused: Bool, pose: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["LABSTREAM_UNIT_TEST_HOST"] = "0"
        if let pose { app.launchEnvironment["LABSTREAM_DEBUG_DUO_POSE"] = pose }
        app.launchArguments = ["--ui-testing", "--ui-testing-fixture", "player",
                               "--ui-testing-player-aspect", "16x9", "--ui-testing-player-geometry"]
            + (paused ? ["--ui-testing-player-paused"] : [])
            + (orientation.map { ["--ui-testing-orientation", $0] } ?? [])
        app.launch()
        return app
    }

    @MainActor
    private func waitForWindow(_ app: XCUIApplication, landscape: Bool, context: String) throws {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let frame = app.windows.firstMatch.frame
            return landscape ? frame.width > frame.height : frame.height > frame.width
        }, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 10), .completed,
                       "\(landscape ? "landscape" : "portrait") scene (\(context)): \(app.windows.firstMatch.frame.size)")
    }

    /// The vertical bar's frame, measured from the tab buttons and the Settings toolbar item,
    /// extended to the full window height. `nil` when no tab button is found.
    @MainActor
    private func systemColumn(in app: XCUIApplication, window: CGRect) -> CGRect? {
        var union = CGRect.null
        for name in ["Home", "Libraries", "Music", "Offline", "Search"] {
            let button = app.buttons.matching(NSPredicate(format: "label == %@", name))
                .allElementsBoundByIndex.first { $0.frame.width > 0 && $0.frame.width < 120 }
            if let button { union = union.union(button.frame) }
        }
        guard !union.isNull else { return nil }
        guard union.height > union.width else { return union } // a horizontal bar
        return CGRect(x: union.minX - 2, y: window.minY, width: union.width + 4, height: window.height)
    }

    private func clears(_ frame: CGRect, of column: CGRect, window: CGRect) -> Bool {
        column.midX > window.midX ? frame.maxX <= column.minX + 0.5 : frame.minX >= column.maxX - 0.5
    }

    @MainActor
    private func assertClear(_ element: XCUIElement, of column: CGRect, window: CGRect, context: String) {
        guard element.exists else { return XCTFail("\(context) missing") }
        XCTAssertTrue(clears(element.frame, of: column, window: window),
                      "\(context) \(element.frame) clears the column \(column)")
    }

    /// Seconds remaining from the scrubber's "Remaining m:ss" label, revealing the chrome first.
    @MainActor
    private func remainingSeconds(_ app: XCUIApplication, context: String) throws -> Int {
        let label = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Remaining ")).firstMatch
        if !label.exists {
            app.descendants(matching: .any)["playback.surface"].firstMatch
                .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
            _ = label.waitForExistence(timeout: 3)
        }
        let text = label.label.replacingOccurrences(of: "Remaining ", with: "")
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard !parts.isEmpty else { throw NSError(domain: "duo", code: 1, userInfo: [NSLocalizedDescriptionKey: "no remaining time (\(context)): \(label.label)"]) }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
