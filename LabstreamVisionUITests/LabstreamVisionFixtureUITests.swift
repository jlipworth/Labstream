import XCTest

/// visionOS XCUITest smoke against the server-free browse fixture: launch, find a Home item by
/// accessibility identifier, open its detail page, and press Play/Resume. Element queries only;
/// never coordinates. In-process screenshots are 1×1 on the visionOS simulator, so each
/// `checkpoint` lets a host driver capture the display (see `UITestCheckpoint`).
final class LabstreamVisionFixtureUITests: XCTestCase {
    @MainActor
    func testFixtureHomeOpensDetailAndPlay() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["LABSTREAM_UNIT_TEST_HOST"] = "0"
        app.launchArguments = ["--ui-testing", "--ui-testing-backend", "plex",
                               "--ui-testing-fixture", "browse"]
        app.launch()

        let item = app.buttons["labstream.home.fixture-resume.plex-orbit"]
        XCTAssertTrue(item.waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["house"].isSelected, "Home tab is selected at launch")
        checkpoint("1-home")
        item.tap()

        XCTAssertTrue(app.staticTexts["Some signals should stay distant."].waitForExistence(timeout: 10),
                      "detail page for the tapped item")
        let play = app.buttons.matching(NSPredicate(format: "label IN %@", ["Play", "Resume"])).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        checkpoint("2-detail")
        play.tap()

        // The fixture's media URL is a non-resolving placeholder; this proves the tap reaches the
        // player path. Wait for the UI to change before the host capture.
        sleep(5)
        checkpoint("3-after-play")
        print(app.debugDescription)
    }
}
