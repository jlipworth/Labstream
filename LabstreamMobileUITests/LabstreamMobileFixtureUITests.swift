import XCTest

final class LabstreamMobileFixtureUITests: XCTestCase {
    @MainActor
    func testFixtureHomeOpensDetailSemantically() {
        let app = XCUIApplication()
        app.launchEnvironment["LABSTREAM_UNIT_TEST_HOST"] = "0"
        app.launchArguments = ["--ui-testing", "--ui-testing-backend", "plex",
                               "--ui-testing-fixture", "browse"]
        app.launch()

        let item = app.buttons["labstream.home.fixture-resume.plex-orbit"]
        XCTAssertTrue(item.waitForExistence(timeout: 10))
        item.tap()

        let detail = app.staticTexts["Some signals should stay distant."]
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "fixture-detail"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
