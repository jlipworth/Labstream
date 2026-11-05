import XCTest

/// Opt-in live sign-in and navigation against the Jellyfin review catalog on visionOS, for App
/// Store screenshot capture through `scripts/app-store-screenshots.py live drive`.
///
/// Same contract as the iPhone/iPad `LabstreamMobileLiveCatalogUITests`: private values come only
/// from runner environment variables, every test skips without them, and the test never signs out.
/// (The visionOS golden-clone simulator is signed in to Plex, so the catalog check fails there by
/// design; sign out by hand or use a signed-out simulator.) Element queries only, no coordinates;
/// the host captures each checkpoint because in-process visionOS screenshots are 1×1.
final class LabstreamVisionLiveCatalogUITests: XCTestCase {
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
        // The ornament tab bar's buttons carry their SF Symbol names as identifiers.
        let homeTab = app.buttons["house"].firstMatch
        XCTAssertTrue(homeTab.waitForExistence(timeout: 60), "Sign-in did not reach the browse UI.")
        homeTab.tap()
        let title = titleButton(app, config.title)
        XCTAssertTrue(title.waitForExistence(timeout: 30),
                      "Home does not show \(config.title); is the app signed in to the review catalog?")
        settle(app)
        checkpoint("home")

        app.buttons["rectangle.stack"].firstMatch.tap()
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

        let windowsBefore = app.windows.count
        play.tap()
        // The visionOS player opens its own window; wait for the window set to change.
        let opened = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in app.windows.count != windowsBefore }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [opened], timeout: 45), .completed, "Player window did not open")
        sleep(8)
        checkpoint("playback")
    }

    @MainActor
    private func signInIfNeeded(_ app: XCUIApplication, _ config: LiveCatalogConfig) {
        let backend = app.buttons["Jellyfin"].firstMatch
        let home = app.buttons["house"].firstMatch
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
