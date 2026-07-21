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

    /// A single Down press must reveal auto-hidden chrome without seeking or activating
    /// another control. (Side presses are exercised separately: on hidden chrome they are
    /// an instant ±10s skip PLUS a reveal by design.)
    func testDirectionalPressRevealsHiddenChrome() throws {
        let app = launchPlayerFixture()
        try awaitAutoHide(app)

        XCUIRemote.shared.press(.down)
        XCTAssertTrue(app.buttons["tv.player.timeline"].waitForExistence(timeout: 4),
                      "directional press should reveal hidden chrome")
        attachScreen(named: "chrome revealed by down press", app: app)
    }

    /// Select on hidden chrome must reveal it (and not activate a control or seek).
    func testSelectPressRevealsHiddenChrome() throws {
        let app = launchPlayerFixture()
        try awaitAutoHide(app)

        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["tv.player.timeline"].waitForExistence(timeout: 4),
                      "Select should reveal hidden chrome without activating a control")
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

    /// Menu/Back on hidden chrome must exit playback (fixture shows its closed marker).
    func testBackExitsPlayback() throws {
        let app = launchPlayerFixture()
        try awaitAutoHide(app)

        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.staticTexts["tv.fixture.player.closed"].waitForExistence(timeout: 4),
                      "Menu/Back should exit playback")
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

    /// TVUI-004 baseline: the bare default `TextField`. Types one letter through the
    /// system keyboard with remote Select and checks insertion.
    func testSystemKeyboardInsertsLetterIntoMinimalTextField() throws {
        let app = launchKeyboardFixture()
        let field = app.textFields["tv.fixture.keyboard.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(focusField(field, byPressing: .up),
                      "bare field (topmost) should be reachable with Up presses")
        try assertKeyboardInsertsLetter(app: app, field: field,
                                        echoID: "tv.fixture.keyboard.echo", prefix: "typed:")
    }

    /// TVUI-004 bisection step 1: SearchView's visual modifiers (`.plain` style, font,
    /// capsule frame) WITHOUT a focus binding.
    func testSystemKeyboardInsertsLetterIntoStyledTextField() throws {
        let app = launchKeyboardFixture()
        let bare = app.textFields["tv.fixture.keyboard.field"]
        XCTAssertTrue(bare.waitForExistence(timeout: 5))
        _ = focusField(bare, byPressing: .up)
        let styled = app.textFields["tv.fixture.keyboard.styled.field"]
        XCTAssertTrue(focusField(styled, byPressing: .down, times: 2),
                      "styled field should be one focus step below the bare field")
        try assertKeyboardInsertsLetter(app: app, field: styled,
                                        echoID: "tv.fixture.keyboard.styled.echo",
                                        prefix: "styled:")
    }

    /// TVUI-004 bisection step 2: the full SearchView replica — visual modifiers PLUS
    /// `.focused($…)` and the on-appear programmatic focus write. If this fails while
    /// the styled field passes, the focus binding is what breaks keyboard insertion.
    func testSystemKeyboardInsertsLetterIntoSearchReplicaTextField() throws {
        let app = launchKeyboardFixture()
        let replica = app.textFields["tv.fixture.keyboard.replica.field"]
        XCTAssertTrue(replica.waitForExistence(timeout: 5))
        XCTAssertTrue(focusField(replica, byPressing: .down),
                      "replica field (bottom) should be reachable with Down presses")
        try assertKeyboardInsertsLetter(app: app, field: replica,
                                        echoID: "tv.fixture.keyboard.replica.echo",
                                        prefix: "replica:")
    }

    /// TVUI-004 bisection step 3: the replica field hosted inside the live Search tab's
    /// shell layers (TabView + NavigationStack + results ScrollView + conditional Clear
    /// button). The bare-hosted replica passes, so a failure here pins the defect on the
    /// shell; a pass moves suspicion to the remaining live-only layers (environment,
    /// session-key `.id`, safe-area inset).
    func testSystemKeyboardInsertsLetterInsideTabViewShell() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-testing-fixture", "keyboard-shell"]
        app.launchEnvironment["LABSTREAM_UNIT_TEST_HOST"] = "0"
        app.launch()

        let field = app.textFields["tv.fixture.keyboard.shell.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        // The fixture auto-focuses the field on tab appearance, same as the live Search tab.
        XCTAssertTrue(waitForFocus(field, timeout: 4) || focusField(field, byPressing: .down),
                      "shell fixture should land focus on the search field")
        try assertKeyboardInsertsLetter(app: app, field: field,
                                        echoID: "tv.fixture.keyboard.shell.echo",
                                        prefix: "shell:")
    }

    /// TVUI-004 live repro: drives the REAL Search tab (browse fixture hosts the production
    /// RootView/SearchView) with the same remote presses as the failing manual session —
    /// focus the field, Select to open the keyboard, Select on a letter. The shell replica
    /// passes, so this is the test that should reproduce the live teardown-on-letter defect;
    /// once it fails here, the live-only layers can be bisected in place.
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

    private func launchKeyboardFixture() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-testing-fixture", "keyboard"]
        app.launchEnvironment["LABSTREAM_UNIT_TEST_HOST"] = "0"
        app.launch()
        return app
    }

    /// Walks remote focus to `field` one press at a time (the fixture stacks its fields
    /// vertically with non-focusable labels between them).
    private func focusField(_ field: XCUIElement,
                            byPressing direction: XCUIRemote.Button,
                            times: Int = 6) -> Bool {
        for _ in 0..<times {
            if field.hasFocus { return true }
            XCUIRemote.shared.press(direction)
            if waitForFocus(field, timeout: 1) { return true }
        }
        return field.hasFocus
    }

    /// Shared TVUI-004 assertion: Select opens the keyboard, Select on a letter must grow
    /// the field's echo label past its static prefix.
    private func assertKeyboardInsertsLetter(app: XCUIApplication,
                                             field: XCUIElement,
                                             echoID: String,
                                             prefix: String) throws {
        XCUIRemote.shared.press(.select)

        // Don't press blind: wait for the system keyboard surface to be up before the next
        // Select. Prefer proof that a key holds focus, but the tvOS grid keyboard does not
        // reliably expose keys (or their focus) through the app's accessibility tree, so
        // fall back to any key existing, then to the field reporting keyboard focus.
        let focusedKey = app.keys.matching(NSPredicate(format: "hasFocus == true")).firstMatch
        if !focusedKey.waitForExistence(timeout: 4),
           !app.keys.firstMatch.waitForExistence(timeout: 2) {
            XCTAssertTrue(waitForFocus(field, timeout: 4),
                          "after Select the keyboard should be up (no key elements exposed; "
                          + "field should at least report focus)")
        }
        attachScreen(named: "keyboard entry surface (\(echoID))", app: app)

        XCUIRemote.shared.press(.select)
        let echo = app.staticTexts[echoID]
        let grew = expectation(for: NSPredicate(format: "label.length > %d", prefix.count),
                               evaluatedWith: echo)
        if XCTWaiter().wait(for: [grew], timeout: 4) != .completed {
            let dump = XCTAttachment(string: app.debugDescription)
            dump.name = "keyboard hierarchy at failure (\(echoID))"
            dump.lifetime = .keepAlways
            add(dump)
            XCTFail("system keyboard Select should insert a letter; \(echoID) shows '\(echo.label)'")
        }
        attachScreen(named: "after select on letter (\(echoID))", app: app)
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
