import XCTest

/// Opt-in live sign-in and navigation against the Jellyfin review catalog, for App Store
/// screenshot capture through `scripts/app-store-screenshots.py live drive`.
///
/// Private values come only from the runner environment (xcodebuild `TEST_RUNNER_` variables
/// loaded from the gitignored `scripts/app-review-live.env`); nothing is hard-coded, attached,
/// or printed by the test itself. Without them every test skips. The test never signs out: an app
/// already signed in to another account fails at the catalog check instead.
///
/// Flow: sign in with username/password (when signed out) → Home → Movies → Spring details →
/// play, holding at the `home`, `library`, `detail` and `playback` checkpoints so the host can
/// capture each screen (`UITestCheckpoint`). `LABSTREAM_LIVE_ATTACH=1` attaches to the process
/// that `live start` launched without arguments instead of launching a new one.
final class LabstreamMobileLiveCatalogUITests: XCTestCase {
    /// 30-second skips past the opening title cards before the playback capture.
    private static let playbackSkips = 3

    @MainActor
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

        signInIfNeeded(app, config)
        let homeTab = app.tabBars.buttons["Home"].firstMatch
        XCTAssertTrue(homeTab.waitForExistence(timeout: 60), "Sign-in did not reach the browse UI.")
        homeTab.tap()
        let title = titleButton(app, config.title)
        XCTAssertTrue(title.waitForExistence(timeout: 30),
                      "Home does not show \(config.title); is the app signed in to the review catalog?")
        settle(app)
        checkpoint("home")

        let librariesTab = app.tabBars.buttons["Libraries"].firstMatch
        XCTAssertTrue(librariesTab.waitForExistence(timeout: 10))
        librariesTab.tap()
        libraryChooserConfirm(app)?.tap()
        let library = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", config.library)).firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 20), "No \(config.library) library")
        library.tap()
        let gridTitle = titleButton(app, config.title)
        XCTAssertTrue(gridTitle.waitForExistence(timeout: 20), "\(config.library) does not list \(config.title)")
        settle(app)
        checkpoint("library")

        gridTitle.tap()
        let play = app.buttons.matching(NSPredicate(format: "label IN %@", ["Play", "Resume"])).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 20), "\(config.title) detail has no Play button")
        settle(app)
        checkpoint("detail")

        play.tap()
        let chrome = app.buttons["Close"].firstMatch
        XCTAssertTrue(chrome.waitForExistence(timeout: 45), "Player did not present")
        // A playing video never gives the host two identical frames, and the opening seconds are
        // title cards: pause, then skip past the opening so the capture holds a still scene.
        sleep(4)
        let pause = app.buttons["Pause"].firstMatch
        if !pause.isHittable { app.windows.firstMatch.tap() }
        XCTAssertTrue(pause.waitForExistence(timeout: 5), "Player chrome has no Pause button")
        pause.tap()
        let skip = app.buttons["Skip forward 30 seconds"].firstMatch
        XCTAssertTrue(skip.waitForExistence(timeout: 5), "Player chrome has no skip-forward button")
        for _ in 0..<Self.playbackSkips { skip.tap(); usleep(500_000) }
        XCTAssertTrue(app.buttons["Play"].firstMatch.waitForExistence(timeout: 5), "Player did not stay paused")
        // Let the paused frame decode after the seek.
        sleep(4)
        checkpoint("playback")
    }

    @MainActor
    private func signInIfNeeded(_ app: XCUIApplication, _ config: LiveCatalogConfig) {
        let backend = app.buttons["Jellyfin"].firstMatch
        let home = app.tabBars.buttons["Home"].firstMatch
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline, !backend.exists, !home.exists { usleep(250_000) }
        guard backend.exists, !home.exists else { return }
        backend.tap()
        let field = app.textFields["https://jellyfin.example.com"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        replaceText(in: field, with: config.server)
        let method = app.buttons["Username / Password"]
        XCTAssertTrue(method.waitForExistence(timeout: 5))
        method.tap()
        let username = app.textFields["Username"]
        XCTAssertTrue(username.waitForExistence(timeout: 5))
        replaceText(in: username, with: config.username)
        let password = app.secureTextFields["Password"]
        XCTAssertTrue(password.waitForExistence(timeout: 5))
        password.tap()
        password.typeText(config.password)
        let submit = app.buttons["Sign in with Jellyfin"]
        XCTAssertTrue(submit.waitForExistence(timeout: 5))
        XCTAssertTrue(submit.isEnabled, "Sign in stayed disabled after entering credentials")
        submit.tap()
    }
}
