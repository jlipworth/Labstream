import XCTest

/// Explicitly opted-in live authentication using the ordinary app UI. No token injection.
/// Keep the xctestrun configuration, screenshots and result bundle in ignored local storage.
final class LabstreamMobileLiveAuthUITests: XCTestCase {
    @MainActor
    func testPlexLink() throws {
        guard ProcessInfo.processInfo.environment["LABSTREAM_LIVE_PLEX_AUTH_ALLOWED"] == "1" else {
            throw XCTSkip("Live authentication requires explicit local opt-in.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["LABSTREAM_UNIT_TEST_HOST"] = "0"
        app.launchArguments = ["--vp-probe-backend", "plex"]
        app.launch()
        let connect = app.buttons["Sign in with Plex"]
        XCTAssertTrue(connect.waitForExistence(timeout: 20), "Expected signed-out app; never sign out automatically.")
        connect.tap()
        let prompt = app.buttons["Copy Plex pairing code"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 30))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "private-plex-link-code"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertTrue(app.buttons["Home"].firstMatch.waitForExistence(timeout: 240),
                      "Browser authorization and server selection did not complete.")
        XCTAssertFalse(prompt.exists)
    }

    @MainActor
    func testSelectPlexServer() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["LABSTREAM_LIVE_PLEX_AUTH_ALLOWED"] == "1",
              let name = environment["LABSTREAM_LIVE_PLEX_SERVER_NAME"], !name.isEmpty else {
            throw XCTSkip("Explicit normal-UI server selection requires a private exact server label.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["LABSTREAM_UNIT_TEST_HOST"] = "0"
        app.launchArguments = ["--vp-probe-backend", "plex"]
        app.launch()
        let settings = app.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 30))
        settings.tap()
        let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Plex Server")).firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        picker.tap()
        let server = app.buttons[name]
        XCTAssertTrue(server.waitForExistence(timeout: 10))
        server.tap()
        let selected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", name), object: picker)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 45), .completed,
                       "Server selection must finish before test teardown terminates the app.")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "private-plex-server-selection"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testJellyfinQuickConnect() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["LABSTREAM_LIVE_AUTH_ALLOWED"] == "1",
              let server = environment["LABSTREAM_LIVE_AUTH_SERVER"] else {
            throw XCTSkip("Live authentication requires explicit local opt-in.")
        }
        guard let url = URL(string: server), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            XCTFail("Use an HTTPS server address without credentials, query or fragment.")
            return
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["LABSTREAM_UNIT_TEST_HOST"] = "0"
        app.launchArguments = []
        app.launch()
        let backend = app.segmentedControls.buttons["Jellyfin"]
        XCTAssertTrue(backend.waitForExistence(timeout: 15), "Expected signed-out app; never sign out automatically.")
        backend.tap()
        let field = app.textFields["https://jellyfin.example.com"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        if let value = field.value as? String, !value.isEmpty, value != field.placeholderValue {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
        }
        field.typeText(server + "\n")
        let connect = app.buttons["Quick Connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 5))
        XCTAssertTrue(connect.isEnabled)
        connect.tap()
        let prompt = app.staticTexts["Enter this code in Jellyfin"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 20))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "private-quick-connect-code"
        attachment.lifetime = .keepAlways
        add(attachment)
        // The operator/agent approves only this app-generated code in an authenticated browser.
        // Disappearance alone isn't enough: the browse tab must become available too.
        let home = app.tabBars.buttons["Home"]
        XCTAssertTrue(home.waitForExistence(timeout: 240), "Browser authorization did not complete.")
        XCTAssertFalse(prompt.exists)
    }
    @MainActor
    func testEmbyConnect() throws {
        guard ProcessInfo.processInfo.environment["LABSTREAM_LIVE_EMBY_AUTH_ALLOWED"] == "1" else {
            throw XCTSkip("Live authentication requires explicit local opt-in.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["LABSTREAM_UNIT_TEST_HOST"] = "0"
        app.launchArguments = ["--vp-probe-backend", "emby"]
        app.launch()
        let connect = app.buttons["Sign in with Emby Connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 20))
        connect.tap()
        let prompt = app.staticTexts["Enter this code at"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 30))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "private-emby-connect-code"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 240))
    }
    @MainActor
    func testEmbyServerCredentials() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["LABSTREAM_LIVE_EMBY_AUTH_ALLOWED"] == "1",
              let server = env["LABSTREAM_LIVE_AUTH_SERVER"],
              let username = env["LABSTREAM_LIVE_AUTH_USERNAME"],
              let password = env["LABSTREAM_LIVE_AUTH_PASSWORD"] else {
            throw XCTSkip("Private live authentication configuration required.")
        }
        guard let url = URL(string: server), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil else {
            XCTFail("HTTPS origin required."); return
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["LABSTREAM_UNIT_TEST_HOST"] = "0"
        app.launchArguments = ["--vp-probe-backend", "emby"]
        app.launch()
        let method = app.buttons["Sign in with server URL"]
        XCTAssertTrue(method.waitForExistence(timeout: 20))
        method.tap()
        let field = app.textFields["https://emby.example.com"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText(server + "\n")
        app.textFields["Username"].tap(); app.textFields["Username"].typeText(username)
        app.secureTextFields["Password"].tap(); app.secureTextFields["Password"].typeText(password + "\n")
        let submit = app.buttons["Sign in with Emby"]
        if submit.exists && submit.isEnabled { submit.tap() }
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 60))
    }
}
