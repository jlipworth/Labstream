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
        for (aspect, allMenus) in [("16x9", false), ("239x100", false), ("4x3", false),
                                   ("16x9", true), ("239x100", true)] {
            let frames = try chromeFrames(aspect: aspect, allMenus: allMenus,
                                          orientationLabel: orientationLabel)
            if let reference {
                for (label, frame) in reference {
                    let other = try XCTUnwrap(frames[label], "\(label) missing for \(aspect)")
                    XCTAssertEqual(frame.minX, other.minX, accuracy: 0.5, "\(label) x for \(aspect)")
                    XCTAssertEqual(frame.minY, other.minY, accuracy: 0.5, "\(label) y for \(aspect)")
                    XCTAssertEqual(frame.width, other.width, accuracy: 0.5, "\(label) width for \(aspect)")
                }
            } else {
                reference = frames
            }
        }
    }

    @MainActor
    private func chromeFrames(aspect: String, allMenus: Bool,
                              orientationLabel: String) throws -> [String: CGRect] {
        let app = XCUIApplication()
        app.launchEnvironment["LABSTREAM_UNIT_TEST_HOST"] = "0"
        app.launchArguments = ["--ui-testing", "--ui-testing-fixture", "player",
                               "--ui-testing-player-aspect", aspect, "--ui-testing-player-paused",
                               "--ui-testing-player-geometry"]
            + (allMenus ? ["--ui-testing-player-all-menus"] : [])
        app.launch()
        defer { app.terminate() }

        let close = app.buttons["Close"]
        XCTAssertTrue(close.waitForExistence(timeout: 30), "player chrome for \(aspect)")
        let play = app.buttons["Play"]
        XCTAssertTrue(play.waitForExistence(timeout: 15), "paused chrome for \(aspect)")
        let timeline = app.sliders["playback.timeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 5))
        let stats = app.buttons["Stats"]
        XCTAssertTrue(stats.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(close.frame.width, 44)
        XCTAssertGreaterThanOrEqual(stats.frame.height, 44)

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "player-chrome-\(orientationLabel)-\(aspect)\(allMenus ? "-all-menus" : "")"
        attachment.lifetime = .keepAlways
        add(attachment)
        return ["close": close.frame, "play": play.frame, "timeline": timeline.frame,
                "stats": stats.frame]
    }
}
