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

    /// Bounded agent evidence path: prove local playback accepts a semantic remote reveal, then
    /// close playback so Xcode can finalize the result bundle without an active media session.
    func testBasicPlaybackRevealAndExit() throws {
        let app = launchPlayerFixture()
        try awaitAutoHide(app)

        XCUIRemote.shared.press(.down)
        let timeline = app.buttons["tv.player.timeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 4),
                      "directional press should reveal hidden playback chrome")
        attachScreen(named: "basic playback chrome revealed", app: app)

        try awaitAutoHide(app)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.staticTexts["tv.fixture.player.closed"].waitForExistence(timeout: 4),
                      "bounded playback evidence must close the local player")
        app.terminate()
    }

    /// Play/Pause on hidden chrome must toggle exactly once and reveal the chrome. There is
    /// no on-screen Play/Pause to read anymore; the paused proof is that paused chrome pins
    /// itself visible past the 5s auto-hide window.
    func testPlayPausePressPausesAndRevealsHiddenChrome() throws {
        let app = launchPlayerFixture()
        try awaitAutoHide(app)

        XCUIRemote.shared.press(.playPause)
        let timeline = app.buttons["tv.player.timeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 4),
                      "Play/Pause should reveal chrome")
        // Playing chrome hides again within ~5s; paused chrome must not.
        sleep(7)
        XCTAssertTrue(timeline.exists,
                      "paused chrome should pin itself visible (playback did not pause?)")
    }

    /// Revealed chrome must give deterministic initial focus to the timeline and allow
    /// remote traversal into EVERY player menu the fixture offers; closing each menu
    /// must restore focus to its originating button. The local fixture has no Quality menu
    /// (no server reload available); Quality is covered by live-Plex validation.
    func testRevealedChromeReachesMenusAndRestoresFocus() throws {
        let app = launchPlayerFixture()
        try awaitAutoHide(app)

        XCUIRemote.shared.press(.down)
        let timeline = app.buttons["tv.player.timeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 4))
        XCTAssertTrue(waitForFocus(timeline), "revealed chrome should focus the timeline")

        // Up moves from the timeline into the menu strip. The full-width timeline gives the
        // engine latitude on WHICH strip button it enters, so walk Left to the strip's start.
        XCUIRemote.shared.press(.up)
        let firstMenu = app.buttons["Subtitles"]
        XCTAssertTrue(firstMenu.waitForExistence(timeout: 3))
        for _ in 0..<5 where !firstMenu.hasFocus {
            XCUIRemote.shared.press(.left)
            if waitForFocus(firstMenu, timeout: 1) { break }
        }

        // Strip order in the fixture (Quality absent): open and close every menu, moving
        // right one button at a time. Auto-hide never fires while a menu is open, and the
        // strip stays visible between menus because closing restores focus into the strip.
        let menus = ["Subtitles", "Audio", "Chapters", "Speed", "Stats"]
        for (index, title) in menus.enumerated() {
            let button = app.buttons[title]
            XCTAssertTrue(button.waitForExistence(timeout: 3), "\(title) button should exist")
            XCTAssertTrue(waitForFocus(button), "menu strip focus should reach \(title)")

            XCUIRemote.shared.press(.select)
            XCTAssertTrue(app.buttons["Close menu"].waitForExistence(timeout: 3),
                          "\(title) menu should open")
            attachScreen(named: "\(title) menu", app: app)

            XCUIRemote.shared.press(.menu)
            XCTAssertTrue(button.waitForExistence(timeout: 3),
                          "closing \(title) should return to the chrome, not exit playback")
            XCTAssertTrue(waitForFocus(button),
                          "closing \(title) should restore focus to its button")

            if index < menus.count - 1 {
                XCUIRemote.shared.press(.right)
            }
        }
    }

    /// Every remote command must reveal the chrome FROM THE HIDDEN STATE — each press gets a
    /// confirmed fresh auto-hide first, so no press is tested against already-visible chrome.
    /// Play/Pause runs last: it pauses playback, and paused chrome pins itself visible.
    func testHiddenChromeEvidenceSweep() throws {
        let app = launchPlayerFixture()
        try awaitAutoHide(app)
        attachScreen(named: "chrome hidden", app: app)

        let timeline = app.buttons["tv.player.timeline"]
        // Side presses additionally perform an instant ±10s skip by design; every press
        // must still reveal the chrome from a confirmed hidden state.
        for press in [XCUIRemote.Button.right, .left, .up, .down, .select] {
            XCUIRemote.shared.press(press)
            XCTAssertTrue(timeline.waitForExistence(timeout: 4),
                          "\(press) on hidden chrome should reveal it")
            let hidden = expectation(for: NSPredicate(format: "exists == false"),
                                     evaluatedWith: timeline)
            wait(for: [hidden], timeout: 12)
        }

        XCUIRemote.shared.press(.playPause)
        XCTAssertTrue(timeline.waitForExistence(timeout: 4),
                      "Play/Pause on hidden chrome should pause and reveal")
        attachScreen(named: "after hidden-chrome press sweep", app: app)
    }

    /// TVUI-004 regression guard: drives the REAL Search tab (browse fixture hosts the production
    /// RootView/SearchView) with the same remote presses as the original failing manual session —
    /// focus the field, Select to open the keyboard, Select on a letter — and requires the
    /// letter to land in the field. It covers every layer the retired bisection fixtures replicated.
    func testLiveSearchTabSystemKeyboardInsertsLetter() throws {
        let app = makeBrowseApp()
        app.launch()
        XCTAssertTrue(app.staticTexts["The Long Orbit"].waitForExistence(timeout: 5))

        // Launch focus starts in the tab bar; walking Right moves Home → Libraries → Search
        // (tvOS tab bars switch selection on focus).
        XCUIRemote.shared.press(.right)
        XCUIRemote.shared.press(.right)
        let field = app.textFields["tv.search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5),
                      "focusing the Search tab should mount SearchView's field")
        // SearchView auto-focuses the field on appearance; fall back to a Down press.
        if !waitForFocus(field, timeout: 4) {
            XCUIRemote.shared.press(.down)
            XCTAssertTrue(waitForFocus(field, timeout: 3), "field should take focus")
        }

        XCUIRemote.shared.press(.select)
        let focusedKey = app.keys.matching(NSPredicate(format: "hasFocus == true")).firstMatch
        if !focusedKey.waitForExistence(timeout: 4),
           !app.keys.firstMatch.waitForExistence(timeout: 2) {
            XCTAssertTrue(waitForFocus(field, timeout: 4),
                          "after Select the keyboard should be up")
        }
        attachScreen(named: "live search keyboard", app: app)

        XCUIRemote.shared.press(.select)
        let inserted = expectation(for: NSPredicate(format: "value.length > 0 AND value != %@",
                                                    "Movies, shows, music…"),
                                   evaluatedWith: field)
        if XCTWaiter().wait(for: [inserted], timeout: 4) != .completed {
            let dump = XCTAttachment(string: app.debugDescription)
            dump.name = "live search hierarchy at failure"
            dump.lifetime = .keepAlways
            add(dump)
            attachScreen(named: "live search after letter select", app: app)
            XCTFail("keyboard Select should insert a letter into the live search field; "
                    + "value is '\(String(describing: field.value))'")
        }
    }

    private func makeBrowseApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-testing-backend", "plex",
                               "--ui-testing-fixture", "browse"]
        app.launchEnvironment["LABSTREAM_UNIT_TEST_HOST"] = "0"
        return app
    }

    private func launchPlayerFixture() -> XCUIApplication {
        let app = XCUIApplication()
        // The exhaustive player suite is an evidence lane. Ordinary Debug and the small PR
        // smoke plan intentionally do not install the UIWindow event-method swizzle.
        app.launchArguments = ["--ui-testing", "--ui-testing-fixture", "player",
                               "--tv-input-evidence"]
        app.launchEnvironment["LABSTREAM_UNIT_TEST_HOST"] = "0"
        app.launch()
        return app
    }

    /// Waits for the chrome to be visible (playing state) and then auto-hide.
    private func awaitAutoHide(_ app: XCUIApplication) throws {
        let timeline = app.buttons["tv.player.timeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 25),
                      "player chrome should appear in playing state")
        let hidden = expectation(for: NSPredicate(format: "exists == false"),
                                 evaluatedWith: timeline)
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
