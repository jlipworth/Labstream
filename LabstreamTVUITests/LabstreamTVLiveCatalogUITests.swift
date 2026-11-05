import XCTest

/// Opt-in live sign-in and navigation against the Jellyfin review catalog on Apple TV, for App
/// Store screenshot capture through `scripts/app-store-screenshots.py live drive`.
///
/// Same contract as the iPhone/iPad `LabstreamMobileLiveCatalogUITests`: private values come only
/// from runner environment variables, every test skips without them, and the test never signs
/// out. tvOS has no taps, so every step moves Siri Remote focus to a queried element (the focus
/// engine decides; the element frames only choose the press direction) and presses Select.
@MainActor
final class LabstreamTVLiveCatalogUITests: XCTestCase {
    private let remote = XCUIRemote.shared

    func testSignInAndBrowseReviewCatalog() throws {
        let config = try LiveCatalogConfig.load()
        continueAfterFailure = false
        let app = XCUIApplication()
        if config.attach {
            app.activate()
        } else {
            app.launchEnvironment["LABSTREAM_UNIT_TEST_HOST"] = "0"
            app.launchArguments = []
            app.launch()
        }

        try signInIfNeeded(app, config)
        let homeTab = app.buttons["Home"].firstMatch
        XCTAssertTrue(homeTab.waitForExistence(timeout: 60), "Sign-in did not reach the browse UI.")
        let title = titleButton(app, config.title)
        XCTAssertTrue(title.waitForExistence(timeout: 30),
                      "Home does not show \(config.title); is the app signed in to the review catalog?")
        settle(app)
        checkpoint("home")

        try select(app.buttons["Libraries"].firstMatch, in: app)
        if let confirm = libraryChooserConfirm(app) { try select(confirm, in: app) }
        let library = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", config.library)).firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 20), "No \(config.library) library")
        try select(library, in: app)
        let gridTitle = titleButton(app, config.title)
        XCTAssertTrue(gridTitle.waitForExistence(timeout: 20), "\(config.library) does not list \(config.title)")
        try focus(gridTitle, in: app)
        settle(app)
        checkpoint("library")

        remote.press(.select)
        let play = app.buttons.matching(NSPredicate(format: "label IN %@", ["Play", "Resume"])).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 20), "\(config.title) detail has no Play button")
        try focus(play, in: app)
        settle(app)
        checkpoint("detail")

        remote.press(.select)
        // Playing chrome auto-hides; the timeline appears on a reveal press once the player is up.
        sleep(8)
        remote.press(.down)
        XCTAssertTrue(app.buttons["tv.player.timeline"].waitForExistence(timeout: 30), "Player did not present")
        sleep(6)  // let the chrome auto-hide so the capture shows the picture
        checkpoint("playback")
    }

    private func signInIfNeeded(_ app: XCUIApplication, _ config: LiveCatalogConfig) throws {
        let backend = app.buttons["Jellyfin"].firstMatch
        let home = app.buttons["Home"].firstMatch
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline, !backend.exists, !home.exists { usleep(250_000) }
        guard backend.exists, !home.exists else { return }
        try select(backend, in: app)
        let field = app.textFields["https://jellyfin.example.com"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        try enter(config.server, into: field, in: app)
        try select(app.buttons["Username / Password"], in: app)
        let username = app.textFields["Username"]
        XCTAssertTrue(username.waitForExistence(timeout: 5))
        try enter(config.username, into: username, in: app)
        let password = app.secureTextFields["Password"]
        XCTAssertTrue(password.waitForExistence(timeout: 5))
        try enter(config.password, into: password, in: app)
        let submit = app.buttons["Sign in with Jellyfin"]
        XCTAssertTrue(submit.waitForExistence(timeout: 5))
        XCTAssertTrue(submit.isEnabled, "Sign in stayed disabled after entering credentials")
        try select(submit, in: app)
    }

    /// Focus a text field, open the system keyboard, type, and return to the form.
    private func enter(_ value: String, into field: XCUIElement, in app: XCUIApplication) throws {
        try select(field, in: app)
        sleep(1)
        app.typeText(value)
        remote.press(.menu)
        sleep(1)
    }

    private func select(_ element: XCUIElement, in app: XCUIApplication) throws {
        try focus(element, in: app)
        remote.press(.select)
    }

    /// Move focus toward `element` one press at a time, choosing the direction from the currently
    /// focused element's frame. Bounded; fails rather than wandering.
    private func focus(_ element: XCUIElement, in app: XCUIApplication, limit: Int = 30) throws {
        XCTAssertTrue(element.waitForExistence(timeout: 15), "\(element) never appeared")
        for _ in 0..<limit {
            if element.hasFocus { return }
            let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
            guard focused.exists else { remote.press(.down); continue }
            let from = focused.frame, to = element.frame
            let dx = to.midX - from.midX, dy = to.midY - from.midY
            if abs(dy) > from.height / 2, abs(dy) >= abs(dx) / 3 {
                remote.press(dy > 0 ? .down : .up)
            } else {
                remote.press(dx > 0 ? .right : .left)
            }
            usleep(300_000)
        }
        XCTAssertTrue(element.hasFocus, "Could not move focus to \(element)")
    }
}
