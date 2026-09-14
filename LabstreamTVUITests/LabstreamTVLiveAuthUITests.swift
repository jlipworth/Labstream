import XCTest

/// Explicit normal pairing only; never resets a saved session or supplies credentials.
@MainActor
final class LabstreamTVLiveAuthUITests: XCTestCase {
    func testPlexLink() throws {
        guard ProcessInfo.processInfo.environment["LABSTREAM_LIVE_PLEX_AUTH_ALLOWED"] == "1" else {
            throw XCTSkip("Live authentication requires explicit local opt-in.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["LABSTREAM_UNIT_TEST_HOST"] = "0"
        app.launchArguments = ["--vp-probe-backend", "plex"]
        app.launch()
        XCTAssertTrue(app.buttons["Sign in with Plex"].waitForExistence(timeout: 20),
                      "Expected signed-out app; never sign out automatically.")
        XCUIRemote.shared.press(.down)
        XCUIRemote.shared.press(.select)
        let prompt = app.staticTexts["Waiting for authorization…"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 30))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "private-plex-link-code"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertTrue(app.buttons["Home"].waitForExistence(timeout: 240),
                      "Browser authorization and server selection did not complete.")
        XCTAssertFalse(prompt.exists)
    }
}
