import XCTest

@MainActor
final class LabstreamTVLaunchTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAppLaunches() throws {
        let app = makeApp()
        app.launch()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(app.buttons["Sign in with Plex"].waitForExistence(timeout: 5))
    }

    func testRemoteChoosesEveryBackendSignInSurface() throws {
        let app = makeApp()
        app.launch()

        XCTAssertTrue(app.buttons["Sign in with Plex"].waitForExistence(timeout: 5))

        XCUIRemote.shared.press(.right)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.textFields["https://jellyfin.example.com"].waitForExistence(timeout: 3))

        XCUIRemote.shared.press(.right)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["Sign in with Emby Connect"].waitForExistence(timeout: 3))
    }

    func testBackendLaunchFixturesAreDeterministic() throws {
        let jellyfin = makeApp(backend: "jellyfin")
        jellyfin.launch()
        XCTAssertTrue(jellyfin.textFields["https://jellyfin.example.com"].waitForExistence(timeout: 5))
        jellyfin.terminate()

        let emby = makeApp(backend: "emby")
        emby.launch()
        XCTAssertTrue(emby.buttons["Sign in with Emby Connect"].waitForExistence(timeout: 5))
    }

    func testRemoteBrowsesFromFixtureHomeIntoDetailAndBack() throws {
        let app = makeApp(backend: "plex", fixture: "browse")
        app.launch()

        XCTAssertTrue(app.staticTexts["The Long Orbit"].waitForExistence(timeout: 5))

        // The native tvOS TabView starts in its top navigation. Move into Home's first rail,
        // then move from the center-aligned initial card to the leading card. Open it and use
        // Menu as the user-facing Back action.
        XCUIRemote.shared.press(.down)
        XCUIRemote.shared.press(.left)
        XCUIRemote.shared.press(.left)
        XCTAssertTrue(app.buttons["tv.home.fixture-resume.plex-orbit"].hasFocus)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["Some signals should stay distant."].waitForExistence(timeout: 3))

        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.staticTexts["Continue Watching"].waitForExistence(timeout: 3))
    }

    private func makeApp(backend: String? = nil, fixture: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        if let backend {
            app.launchArguments += ["--ui-testing-backend", backend]
        }
        if let fixture {
            app.launchArguments += ["--ui-testing-fixture", fixture]
        }
        app.launchEnvironment["LABSTREAM_UNIT_TEST_HOST"] = "0"
        return app
    }
}
