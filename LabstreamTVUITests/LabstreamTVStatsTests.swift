import XCTest

/// #331: on tvOS the Stats summary needs no focus, but See more, the section picker, and Show
/// less must all be reachable with the Siri Remote. Runs against the local player fixture with
/// a synthetic Stats scenario.
@MainActor
final class LabstreamTVStatsTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testStatsExpandsAndCollapsesWithTheRemote() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-testing-fixture", "player",
                               "--ui-testing-stats-reset", "--ui-testing-stats-scenario", "encode"]
        app.launchEnvironment["LABSTREAM_UNIT_TEST_HOST"] = "0"
        app.launch()

        let timeline = app.buttons["tv.player.timeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 25), "player chrome")
        if !waitForFocus(timeline, timeout: 2) {
            XCUIRemote.shared.press(.down)
            XCTAssertTrue(waitForFocus(timeline), "timeline focus")
        }
        XCUIRemote.shared.press(.up)
        let stats = app.buttons["Stats"]
        XCTAssertTrue(stats.waitForExistence(timeout: 3))
        for _ in 0..<6 where !stats.hasFocus {
            XCUIRemote.shared.press(.right)
            if waitForFocus(stats, timeout: 1) { break }
        }
        XCTAssertTrue(stats.hasFocus, "menu strip focus should reach Stats")
        XCUIRemote.shared.press(.select)

        XCTAssertTrue(app.descendants(matching: .any)["playback.stats.summary"]
            .waitForExistence(timeout: 5), "compact summary")
        attachScreen(named: "tv-stats-compact", app: app)

        let seeMore = app.buttons["playback.stats.expand"]
        XCTAssertTrue(seeMore.waitForExistence(timeout: 3))
        try moveFocus(to: seeMore, using: .down)
        XCUIRemote.shared.press(.select)

        let sections = app.descendants(matching: .any)["playback.stats.sections"]
        XCTAssertTrue(sections.waitForExistence(timeout: 5), "expanded section picker")
        attachScreen(named: "tv-stats-expanded", app: app)

        let showLess = app.buttons["playback.stats.collapse"]
        XCTAssertTrue(showLess.waitForExistence(timeout: 3))
        try moveFocus(to: showLess, using: .down)
        attachScreen(named: "tv-stats-expanded-scrolled", app: app)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["playback.stats.expand"].waitForExistence(timeout: 5),
                      "Show less returns to the compact summary")

        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(stats.waitForExistence(timeout: 3),
                      "closing Stats returns to the chrome, not exit playback")
    }

    private func moveFocus(to element: XCUIElement, using direction: XCUIRemote.Button) throws {
        for _ in 0..<8 where !element.hasFocus {
            XCUIRemote.shared.press(direction)
            if waitForFocus(element, timeout: 1) { return }
        }
        XCTAssertTrue(element.hasFocus, "focus should reach \(element.identifier)")
    }

    private func waitForFocus(_ element: XCUIElement, timeout: TimeInterval = 3) -> Bool {
        let focused = expectation(for: NSPredicate(format: "hasFocus == true"), evaluatedWith: element)
        return XCTWaiter().wait(for: [focused], timeout: timeout) == .completed
    }
}
