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

    func testLaunchUsesStreamingOnlyComposition() throws {
        let app = makeApp()
        app.launchArguments.append("--ui-testing-download-composition-evidence")
        app.launch()

        XCTAssertTrue(app.staticTexts["tv.download-subsystem.absent"].waitForExistence(timeout: 5),
                      "tvOS must reach first render with DownloadManager's independent construction count still zero")
        XCTAssertFalse(app.staticTexts["tv.download-subsystem.present"].exists,
                       "the download subsystem must never be constructed by tvOS composition")
    }

    func testSeasonSurfaceHasNoDownloadAction() throws {
        let app = makeApp(backend: "plex", fixture: "season")
        app.launch()

        XCTAssertTrue(app.staticTexts["container.episode.title.tv-season-surface-e1"]
            .waitForExistence(timeout: 5),
                      "the real season browser must load before checking its available actions")
        XCTAssertFalse(app.buttons["Download Season"].exists,
                       "tvOS season browsing is streaming-only and must not offer an unusable planner")
        XCTAssertFalse(app.staticTexts["Download Season"].exists,
                       "the season download planner must not be present on tvOS")
    }

    func testRemoteChoosesEveryBackendSignInSurface() throws {
        let app = makeApp()
        app.launch()

        XCTAssertTrue(app.buttons["Sign in with Plex"].waitForExistence(timeout: 5))
        attachScreen(named: "Plex sign-in", app: app)

        XCUIRemote.shared.press(.right)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.textFields["https://jellyfin.example.com"].waitForExistence(timeout: 3))
        attachScreen(named: "Jellyfin sign-in methods", app: app)

        XCUIRemote.shared.press(.right)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["Sign in with Emby Connect"].waitForExistence(timeout: 3))
        attachScreen(named: "Emby sign-in methods", app: app)
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
        XCTAssertTrue(app.buttons["labstream.home.fixture-resume.plex-orbit"].hasFocus)
        attachScreen(named: "focused home card", app: app)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["Some signals should stay distant."].waitForExistence(timeout: 3))
        attachScreen(named: "TV leaf detail", app: app)

        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.staticTexts["Continue Watching"].waitForExistence(timeout: 3))
    }

    /// Regression for the 2026-07-21 manual-session crash: SwiftUI DynamicContainer fatal
    /// error (lazy-container item removal) fired on a Down row change while browsing Home.
    /// Replays that session's shape — sweep right along a rail, back left, then repeated
    /// row changes — and requires the process to survive with both rails intact.
    func testRemoteRowAndRailTraversalSurvivesLazyContainerUpdates() throws {
        let app = makeApp(backend: "plex", fixture: "browse")
        app.launch()
        XCTAssertTrue(app.staticTexts["The Long Orbit"].waitForExistence(timeout: 5))

        XCUIRemote.shared.press(.down)
        for _ in 0..<6 { XCUIRemote.shared.press(.right) }
        for _ in 0..<3 { XCUIRemote.shared.press(.left) }
        XCUIRemote.shared.press(.down)
        for _ in 0..<8 { XCUIRemote.shared.press(.right) }
        XCTAssertTrue(app.buttons["View all Recently Added"].waitForExistence(timeout: 3),
                      "the trailing View All card should terminate the Recently Added rail")
        for _ in 0..<8 { XCUIRemote.shared.press(.left) }

        // Deep vertical sweep through the fixture shelves and back: forces the Home
        // LazyVStack to derealize scrolled-away rows (where the crash's item removal
        // runs), with horizontal movement in between so rail focus state is live too.
        for _ in 0..<7 {
            XCUIRemote.shared.press(.down)
            XCUIRemote.shared.press(.right)
            XCUIRemote.shared.press(.left)
        }
        for _ in 0..<8 { XCUIRemote.shared.press(.up) }
        XCUIRemote.shared.press(.down)
        XCUIRemote.shared.press(.up)

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 2),
                      "row/rail traversal must not crash the app")
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

    private func attachScreen(named name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
