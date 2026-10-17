import XCTest

/// #331: the player Stats panel opens on a compact summary, expands in place to the detailed
/// engineering view, and keeps its controls at least 44 pt. Runs against the credential-free
/// player fixture; `--ui-testing-stats-scenario` seeds representative synthetic diagnostics.
final class LabstreamMobileStatsUITests: XCTestCase {
    @MainActor
    func testStatsOpensCompactAndExpandsInPlace() throws {
        for scenario in ["direct", "copy", "encode"] {
            try captureStats(scenario: scenario, largeText: false)
        }
    }

    @MainActor
    func testStatsAtAccessibilityTextSize() throws {
        try captureStats(scenario: "encode", largeText: true)
    }

    @MainActor
    private func captureStats(scenario: String, largeText: Bool) throws {
        let app = XCUIApplication()
        app.launchEnvironment["LABSTREAM_UNIT_TEST_HOST"] = "0"
        app.launchArguments = ["--ui-testing", "--ui-testing-fixture", "player",
                               "--ui-testing-player-paused", "--ui-testing-stats-reset",
                               "--ui-testing-stats-scenario", scenario]
            + (largeText ? ["-UIPreferredContentSizeCategoryName",
                            "UICTContentSizeCategoryAccessibilityL"] : [])
        app.launch()
        defer { app.terminate() }
        let suffix = "\(scenario)\(largeText ? "-ax" : "")"

        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 30), "player chrome")
        let statsPill = app.buttons.matching(NSPredicate(format: "label == %@", "Stats")).firstMatch
        XCTAssertTrue(statsPill.waitForExistence(timeout: 10), "Stats pill")
        statsPill.tap()

        let summary = app.descendants(matching: .any)["playback.stats.summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 10), "compact summary")
        attach(app, "stats-compact-\(suffix)")

        let seeMore = app.buttons["playback.stats.expand"]
        XCTAssertTrue(seeMore.waitForExistence(timeout: 5), "See more")
        assertHitTarget(seeMore, "See more")
        seeMore.tap()

        let tabs = app.descendants(matching: .any)["playback.stats.sections"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 5), "expanded section picker")
        for section in ["Video", "Audio", "Network"] {
            let segment = tabs.buttons[section]
            XCTAssertTrue(segment.waitForExistence(timeout: 5), "\(section) segment")
            segment.tap()
            attach(app, "stats-expanded-\(section.lowercased())-\(suffix)")
        }
        let copy = app.buttons["playback.stats.copy"]
        XCTAssertTrue(copy.exists, "Copy diagnostics")
        assertHitTarget(copy, "Copy diagnostics")
        let collapse = app.buttons["playback.stats.collapse"]
        XCTAssertTrue(collapse.exists, "Show less")
        assertHitTarget(collapse, "Show less")
        collapse.tap()
        XCTAssertTrue(app.buttons["playback.stats.expand"].waitForExistence(timeout: 5),
                      "Show less returns to the compact summary")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        // Full-screen capture: `app.screenshot()` crops the landscape-only player out of the
        // simulator's portrait buffer.
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func assertHitTarget(_ element: XCUIElement, _ context: String) {
        XCTAssertGreaterThanOrEqual(element.frame.width, 44, "hit width: \(context)")
        XCTAssertGreaterThanOrEqual(element.frame.height, 44, "hit height: \(context)")
    }
}
