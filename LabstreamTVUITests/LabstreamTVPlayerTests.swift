import XCTest

/// TVUI-024/TVUI-025 player-chrome remote-input coverage against the deterministic local-file
/// player fixture (`--ui-testing-fixture player`). The app-side evidence recorder logs every
/// window press, focus update, and SwiftUI command receipt with `TVEvidence:` /
/// `TVPlayerEvidence:` prefixes for post-run log analysis.
@MainActor
final class LabstreamTVPlayerTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// A single directional press must reveal auto-hidden chrome without seeking or
    /// activating another control.
    func testDirectionalPressRevealsHiddenChrome() throws {
        let app = launchPlayerFixture()
        try awaitAutoHide(app)

        XCUIRemote.shared.press(.right)
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 4),
                      "directional press should reveal hidden chrome")
        attachScreen(named: "chrome revealed by right press", app: app)
    }

    /// Select on hidden chrome must reveal it (and not activate a control or seek).
    func testSelectPressRevealsHiddenChrome() throws {
        let app = launchPlayerFixture()
        try awaitAutoHide(app)

        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 4),
                      "Select should reveal hidden chrome without activating a control")
        // Still playing: the transport button must still read Pause, not Play.
        XCTAssertFalse(app.buttons["Play"].exists,
                       "Select on hidden chrome must not toggle playback")
    }

    /// Play/Pause on hidden chrome must toggle exactly once and reveal the chrome.
    func testPlayPausePressPausesAndRevealsHiddenChrome() throws {
        let app = launchPlayerFixture()
        try awaitAutoHide(app)

        XCUIRemote.shared.press(.playPause)
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 4),
                      "Play/Pause should pause playback and reveal chrome")
    }

    /// Revealed chrome must give deterministic initial focus to the Play/Pause control and
    /// allow remote traversal into every player menu; closing a menu restores focus to its
    /// originating button.
    func testRevealedChromeReachesMenusAndRestoresFocus() throws {
        let app = launchPlayerFixture()
        try awaitAutoHide(app)

        XCUIRemote.shared.press(.right)
        let pause = app.buttons["Pause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 4))
        XCTAssertTrue(waitForFocus(pause), "revealed chrome should focus Play/Pause")

        // Local fixture has no Quality menu (no server reload); Subtitles is the first
        // menu-strip entry. Up moves from the transport row into the menu strip.
        XCUIRemote.shared.press(.up)
        let subtitles = app.buttons["Subtitles"]
        XCTAssertTrue(subtitles.waitForExistence(timeout: 2))
        XCTAssertTrue(waitForFocus(subtitles), "menu strip should be reachable by one Up press")

        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["Subtitles"].waitForExistence(timeout: 3),
                      "Subtitles menu should open")
        attachScreen(named: "subtitles menu", app: app)

        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(subtitles.waitForExistence(timeout: 3))
        XCTAssertTrue(waitForFocus(subtitles), "closing a menu should restore focus to its button")
    }

    /// Menu/Back on hidden chrome must exit playback (fixture shows its closed marker).
    func testBackExitsPlayback() throws {
        let app = launchPlayerFixture()
        try awaitAutoHide(app)

        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.staticTexts["tv.fixture.player.closed"].waitForExistence(timeout: 4),
                      "Menu/Back should exit playback")
    }

    /// Evidence sweep for log analysis: press every relevant button while chrome is hidden,
    /// with no reveal assertions. The app-side TVEvidence log records deliveries.
    func testHiddenChromeEvidenceSweep() throws {
        let app = launchPlayerFixture()
        try awaitAutoHide(app)
        attachScreen(named: "chrome hidden", app: app)

        for press in [XCUIRemote.Button.right, .left, .up, .down, .select, .playPause] {
            XCUIRemote.shared.press(press)
            Thread.sleep(forTimeInterval: 0.8)
        }
        attachScreen(named: "after hidden-chrome press sweep", app: app)
    }

    /// TVUI-004 classification: the minimal native TextField fixture. Types one letter
    /// through the system keyboard with remote Select and checks insertion.
    func testSystemKeyboardInsertsLetterIntoMinimalTextField() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-testing-fixture", "keyboard"]
        app.launchEnvironment["LABSTREAM_UNIT_TEST_HOST"] = "0"
        app.launch()

        let field = app.textFields["tv.fixture.keyboard.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.select)

        // The system keyboard starts focused on "A" on the grid layout; press Select and
        // check whether any character lands in the query.
        sleep(2)
        attachScreen(named: "keyboard entry surface", app: app)
        XCUIRemote.shared.press(.select)
        sleep(1)
        attachScreen(named: "after select on letter", app: app)

        let echo = app.staticTexts["tv.fixture.keyboard.echo"]
        let value = echo.label
        XCTAssertTrue(value.count > "typed:".count,
                      "system keyboard Select should insert a letter; echo shows '\(value)'")
    }

    private func launchPlayerFixture() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-testing-fixture", "player"]
        app.launchEnvironment["LABSTREAM_UNIT_TEST_HOST"] = "0"
        app.launch()
        return app
    }

    /// Waits for the chrome to be visible (playing state) and then auto-hide.
    private func awaitAutoHide(_ app: XCUIApplication) throws {
        let pause = app.buttons["Pause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 25),
                      "player chrome should appear in playing state")
        let hidden = expectation(for: NSPredicate(format: "exists == false"),
                                 evaluatedWith: pause)
        wait(for: [hidden], timeout: 12)
    }

    /// Focus settles asynchronously after an XCUIRemote press; poll instead of reading
    /// `hasFocus` immediately.
    private func waitForFocus(_ element: XCUIElement, timeout: TimeInterval = 3) -> Bool {
        let focused = expectation(for: NSPredicate(format: "hasFocus == true"),
                                  evaluatedWith: element)
        return XCTWaiter().wait(for: [focused], timeout: timeout) == .completed
    }

    private func attachScreen(named name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
