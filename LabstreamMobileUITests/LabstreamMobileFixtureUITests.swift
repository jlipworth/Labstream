import XCTest

final class LabstreamMobileFixtureUITests: XCTestCase {
    @MainActor
    func testFixtureHomeOpensDetailSemantically() {
        let app = XCUIApplication()
        app.launchEnvironment["LABSTREAM_UNIT_TEST_HOST"] = "0"
        app.launchArguments = ["--ui-testing", "--ui-testing-backend", "plex",
                               "--ui-testing-fixture", "browse"]
        app.launch()

        let item = app.buttons["labstream.home.fixture-resume.plex-orbit"]
        XCTAssertTrue(item.waitForExistence(timeout: 10))
        item.tap()

        let detail = app.staticTexts["Some signals should stay distant."]
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "fixture-detail"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// #258: for a fixed device, orientation, and chrome state, the player chrome must occupy the
    /// same screen-relative frames whatever the source aspect (pillarboxed 4:3/16:9 or
    /// letterboxed 2.39:1) and whatever menu set the item offers.
    @MainActor
    func testPlayerChromeFramesAreStableAcrossSourceAspects() throws {
        // iPhone: the player forces landscape. iPad keeps the device orientation, so audit both.
        let orientations: [UIDeviceOrientation] = UIDevice.current.userInterfaceIdiom == .pad
            ? [.portrait, .landscapeLeft] : [.portrait]
        defer { XCUIDevice.shared.orientation = .portrait }
        for orientation in orientations {
            XCUIDevice.shared.orientation = orientation
            try assertStableChrome(orientationLabel: orientation == .portrait ? "portrait" : "landscape")
        }
    }

    @MainActor
    private func assertStableChrome(orientationLabel: String) throws {
        var reference: [String: CGRect]?
        // Skip-button slots legitimately differ between menu sets (the six-pill streaming set can
        // drop to the -10/+30 pair on a phone), so compare those only within one menu set.
        var skipReference: [Bool: [String: CGRect]] = [:]
        for (aspect, allMenus) in [("16x9", false), ("239x100", false), ("4x3", false),
                                   ("16x9", true), ("239x100", true)] {
            let (frames, skips) = try chromeFrames(aspect: aspect, allMenus: allMenus,
                                                   orientationLabel: orientationLabel)
            if let reference {
                try assertSameFrames(reference, frames, context: "\(orientationLabel) \(aspect)")
            } else {
                reference = frames
            }
            if let skipFrames = skipReference[allMenus] {
                try assertSameFrames(skipFrames, skips,
                                     context: "\(orientationLabel) \(aspect) all-menus=\(allMenus)")
            } else {
                XCTAssertFalse(skips.isEmpty, "skip buttons for \(aspect)")
                skipReference[allMenus] = skips
            }
        }
    }

    private func assertSameFrames(_ reference: [String: CGRect], _ frames: [String: CGRect],
                                  context: String) throws {
        for (label, frame) in reference {
            let other = try XCTUnwrap(frames[label], "\(label) missing for \(context)")
            XCTAssertEqual(frame.minX, other.minX, accuracy: 0.5, "\(label) x for \(context)")
            XCTAssertEqual(frame.minY, other.minY, accuracy: 0.5, "\(label) y for \(context)")
            XCTAssertEqual(frame.width, other.width, accuracy: 0.5, "\(label) width for \(context)")
            XCTAssertEqual(frame.height, other.height, accuracy: 0.5, "\(label) height for \(context)")
        }
    }

    @MainActor
    private func launchPlayerFixture(aspect: String, paused: Bool, allMenus: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["LABSTREAM_UNIT_TEST_HOST"] = "0"
        app.launchArguments = ["--ui-testing", "--ui-testing-fixture", "player",
                               "--ui-testing-player-aspect", aspect, "--ui-testing-player-geometry"]
            + (paused ? ["--ui-testing-player-paused"] : [])
            + (allMenus ? ["--ui-testing-player-all-menus"] : [])
        app.launch()
        return app
    }

    @MainActor
    private func chromeFrames(aspect: String, allMenus: Bool,
                              orientationLabel: String) throws -> ([String: CGRect], [String: CGRect]) {
        let app = launchPlayerFixture(aspect: aspect, paused: true, allMenus: allMenus)
        defer { app.terminate() }

        let close = app.buttons["Close"]
        XCTAssertTrue(close.waitForExistence(timeout: 30), "player chrome for \(aspect)")
        let play = app.buttons["Play"]
        XCTAssertTrue(play.waitForExistence(timeout: 15), "paused chrome for \(aspect)")
        let timeline = app.sliders["playback.timeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 5))
        let displayMode = app.buttons["Zoom video to fill"]
        XCTAssertTrue(displayMode.waitForExistence(timeout: 5), "display-mode button for \(aspect)")
        let airPlay = app.descendants(matching: .any)["AirPlay"].firstMatch
        XCTAssertTrue(airPlay.waitForExistence(timeout: 5), "AirPlay button for \(aspect)")

        var frames = ["close": close.frame, "play": play.frame, "timeline": timeline.frame,
                      "displayMode": displayMode.frame, "airPlay": airPlay.frame]
        for control in [close, play, displayMode, airPlay] {
            assertHitTarget(control, "\(control.label) for \(aspect)")
        }

        // iPhone pills expose the full menu title; iPad's labeled strip exposes the short title.
        let pills = [("Quality", "Quality"), ("Subtitles", "Subs"), ("Audio", "Audio"),
                     ("Chapters", "Chapters"), ("Speed", "Speed"), ("Stats", "Stats")]
            .filter { allMenus || $0.0 != "Quality" }
        for (pill, shortTitle) in pills {
            let element = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@",
                                                           pill, shortTitle)).firstMatch
            XCTAssertTrue(element.waitForExistence(timeout: 5), "\(pill) pill for \(aspect)")
            assertHitTarget(element, "\(pill) pill for \(aspect)")
            frames["pill.\(pill)"] = element.frame
        }

        var skips: [String: CGRect] = [:]
        for label in ["Skip back 30 seconds", "Skip back 10 seconds",
                      "Skip forward 10 seconds", "Skip forward 30 seconds"] {
            // The zero-size hardware-keyboard shortcut buttons share these labels; skip them.
            guard let element = app.buttons.matching(identifier: label).allElementsBoundByIndex
                .first(where: { $0.frame.width > 0 && $0.isHittable }) else { continue }
            assertHitTarget(element, "\(label) for \(aspect)")
            skips[label] = element.frame
        }

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "player-chrome-\(orientationLabel)-\(aspect)\(allMenus ? "-all-menus" : "")"
        attachment.lifetime = .keepAlways
        add(attachment)
        return (frames, skips)
    }

    private func assertHitTarget(_ element: XCUIElement, _ context: String) {
        XCTAssertGreaterThanOrEqual(element.frame.width, 44, "hit width: \(context)")
        XCTAssertGreaterThanOrEqual(element.frame.height, 44, "hit height: \(context)")
    }

    /// #258 on iPad: the chrome shows/hides the status bar with itself. Hiding and revealing the
    /// chrome must not move the chrome envelope (and so must not move the top controls or the
    /// centered overlays) by the status-bar inset.
    @MainActor
    func testPlayerChromeEnvelopeIsStableAcrossRevealAndHide() throws {
        let app = launchPlayerFixture(aspect: "16x9", paused: false)
        defer { app.terminate() }

        let surface = app.descendants(matching: .any)["playback.debug.chromeEnvelope"]
        let close = app.buttons["Close"]
        XCTAssertTrue(close.waitForExistence(timeout: 30))
        XCTAssertTrue(surface.waitForExistence(timeout: 5))
        let revealedSurface = surface.frame
        let revealedClose = close.frame
        let revealedTimeline = app.sliders["playback.timeline"].frame

        // Playing chrome auto-hides after a few seconds.
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                               object: close)
        XCTAssertEqual(XCTWaiter().wait(for: [hidden], timeout: 20), .completed, "chrome auto-hide")
        let hiddenSurface = surface.frame
        XCTAssertEqual(hiddenSurface.minY, revealedSurface.minY, accuracy: 0.5, "envelope top while hidden")
        XCTAssertEqual(hiddenSurface.height, revealedSurface.height, accuracy: 0.5, "envelope height while hidden")
        XCTAssertEqual(hiddenSurface.minX, revealedSurface.minX, accuracy: 0.5, "envelope leading while hidden")
        XCTAssertEqual(hiddenSurface.width, revealedSurface.width, accuracy: 0.5, "envelope width while hidden")

        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        XCTAssertTrue(close.waitForExistence(timeout: 5), "chrome reveal")
        XCTAssertEqual(close.frame.minY, revealedClose.minY, accuracy: 0.5, "close after reveal")
        XCTAssertEqual(close.frame.minX, revealedClose.minX, accuracy: 0.5, "close after reveal")
        XCTAssertEqual(app.sliders["playback.timeline"].frame.minY, revealedTimeline.minY,
                       accuracy: 0.5, "timeline after reveal")
    }
}
