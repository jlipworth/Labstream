import XCTest

/// Opt-in live check of the Downloads queue controls against the Jellyfin review catalog: the
/// simultaneous-downloads setting (#404), Pause All / Resume All on a mixed queue (#410) and the
/// poster on a queued row (#412, judged from the `limit-one` checkpoint capture).
///
/// It uses the same private runner configuration as `LabstreamMobileLiveCatalogUITests` and skips
/// without it. It downloads the catalog's two open films, deletes them again, and restores the
/// default limit. Simulator evidence only: background transfer behaviour needs a device.
final class LabstreamMobileLiveDownloadQueueUITests: XCTestCase {
    private static let defaultLimit = 3
    private static let slowQuality = "480p"

    @MainActor
    func testQueueLimitAndPauseResumeAll() throws {
        let config = try LiveCatalogConfig.load()
        let second = ProcessInfo.processInfo.environment["LABSTREAM_LIVE_SECOND_TITLE"]
            .flatMap { $0.isEmpty ? nil : $0 } ?? "Wing It!"
        let titles = [config.title, second]
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["LABSTREAM_UNIT_TEST_HOST"] = "0"
        app.launchArguments = []
        app.launch()

        signInIfNeeded(app, config)
        XCTAssertTrue(app.tabBars.buttons["Home"].firstMatch.waitForExistence(timeout: 60),
                      "Sign-in did not reach the browse UI.")
        deleteDownloads(app, titles: titles)

        // Part 1, server-converted downloads. They arrive at encode speed, which leaves time to
        // watch the queue, and Jellyfin conversions run one at a time whatever the setting.
        startDownload(app, library: config.library, title: titles[0], converted: true)
        openOffline(app)
        tapQueueAction(app, "Pause All")
        XCTAssertTrue(queueAction(app, "Resume All").waitForExistence(timeout: 20), "no Resume All after Pause All")
        startDownload(app, library: config.library, title: titles[1], converted: true)
        openOffline(app)
        waitForStatuses(app, "paused queue holds both rows") { $0.downloading == 0 && $0.paused == 2 }
        // The row added behind the pause reads "Paused", so its own action is Resume.
        XCTAssertTrue(app.buttons["Resume download: \(titles[1])"].firstMatch.waitForExistence(timeout: 5),
                      "the row held behind Pause All does not offer Resume")
        settle(app, seconds: 6)
        checkpoint("added-while-paused")

        // #410 Resume All: one transfer, the other waits (#412: its poster is in the capture).
        resumeAll(app)
        waitForStatuses(app, "Resume All: one transfer, one waiting, none paused") {
            $0.downloading == 1 && $0.paused == 0 && $0.total == 2
        }
        settle(app)
        checkpoint("resumed-all")

        // #410, mixed queue: pausing the active row by hand gives its lane to the waiting one.
        let row = app.staticTexts[titles[0]].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no row for \(titles[0])")
        row.tap()
        let pauseRow = app.buttons["Pause"].firstMatch
        XCTAssertTrue(pauseRow.waitForExistence(timeout: 5), "row actions have no Pause")
        pauseRow.tap()
        waitForStatuses(app, "mixed: one paused, one transferring") { $0.downloading == 1 && $0.paused == 1 }
        settle(app)
        checkpoint("mixed")
        tapQueueAction(app, "Pause All")
        waitForStatuses(app, "mixed Pause All: both paused") { $0.downloading == 0 && $0.paused == 2 }
        settle(app)
        checkpoint("mixed-paused")
        resumeAll(app)
        waitForStatuses(app, "mixed Resume All: one transfer, none paused") {
            $0.downloading == 1 && $0.paused == 0 && $0.total == 2
        }
        settle(app)
        checkpoint("mixed-resumed")

        // Part 2, #404 with original files. Pause, clear the rows (the queue stays paused), add
        // both originals behind the pause, then release them under each limit.
        tapQueueAction(app, "Pause All")
        waitForStatuses(app, "Pause All before part 2") { $0.downloading == 0 }
        deleteDownloads(app, titles: titles)
        setLimit(app, 3)
        for title in titles { startDownload(app, library: config.library, title: title, converted: false) }
        openOffline(app)
        resumeAll(app)
        let three = watchUntilDone(app)
        XCTAssertTrue(three.contains { $0.filter { $0 == "Downloading" }.count == 2 },
                      "limit 3: the two originals never transferred together; rows went \(three)")

        deleteDownloads(app, titles: titles)
        setLimit(app, 1)
        for title in titles { startDownload(app, library: config.library, title: title, converted: false) }
        openOffline(app)
        let one = watchUntilDone(app)
        XCTAssertFalse(one.contains { $0.filter { $0 == "Downloading" }.count == 2 },
                       "limit 1: two originals transferred together; rows went \(one)")
        print("QUEUE-CHECK limit3 \(three)")
        print("QUEUE-CHECK limit1 \(one)")

        deleteDownloads(app, titles: titles)
        setLimit(app, Self.defaultLimit)
    }

    private struct Statuses {
        var values: [String]
        var total: Int { values.count }
        var downloading: Int { values.filter { $0.hasPrefix("Downloading") }.count }
        /// Rows held by a pause: paused themselves, or waiting behind a paused queue.
        var paused: Int { values.filter { $0.hasPrefix("Paused") || $0.contains("downloads paused") }.count }
    }

    @MainActor
    private func statuses(_ app: XCUIApplication) -> Statuses {
        let elements = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Download status")).allElementsBoundByIndex
        return Statuses(values: elements.compactMap { $0.value as? String })
    }

    @MainActor
    private func waitForStatuses(_ app: XCUIApplication, _ what: String, timeout: TimeInterval = 90,
                                 _ condition: (Statuses) -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        var last = statuses(app)
        // The phase word of each row at every change, so a failure shows how the queue moved.
        var history: [String] = []
        func note(_ now: Statuses) {
            let phases = now.values.map { String($0.prefix { $0 != "." }) }.joined(separator: "+")
            if history.last != phases { history.append(phases) }
        }
        note(last)
        while Date() < deadline, !condition(last) {
            usleep(500_000)
            last = statuses(app)
            note(last)
        }
        XCTAssertTrue(condition(last), "\(what); rows went \(history); last \(last.values)")
    }

    @MainActor
    private func queueAction(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.buttons[title].firstMatch
    }

    @MainActor
    private func tapQueueAction(_ app: XCUIApplication, _ title: String) {
        let button = queueAction(app, title)
        XCTAssertTrue(button.waitForExistence(timeout: 20), "Downloads toolbar has no \(title)")
        button.tap()
    }

    /// Resume the queue. A paused queue offers Resume All even when rows were added behind it.
    @MainActor
    private func resumeAll(_ app: XCUIApplication) {
        XCTAssertFalse(queueAction(app, "Pause All").exists, "a paused queue still offers Pause All")
        tapQueueAction(app, "Resume All")
    }

    /// Poll the rows until every one is finished; returns each distinct set of phase words seen.
    @MainActor
    private func watchUntilDone(_ app: XCUIApplication, timeout: TimeInterval = 240) -> [[String]] {
        let deadline = Date().addingTimeInterval(timeout)
        var history: [[String]] = []
        while Date() < deadline {
            let phases = statuses(app).values.map { String($0.prefix { $0 != "." }) }
            if history.last != phases { history.append(phases) }
            if phases.count == 2, phases.allSatisfy({ $0.hasPrefix("Downloaded and verified") }) { break }
            usleep(200_000)
        }
        return history
    }

    @MainActor
    private func openOffline(_ app: XCUIApplication) {
        let tab = app.tabBars.buttons["Offline"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "no Offline tab")
        tab.tap()
    }

    /// Queue one catalog title at the sheet's default quality.
    @MainActor
    private func startDownload(_ app: XCUIApplication, library: String, title: String, converted: Bool) {
        let librariesTab = app.tabBars.buttons["Libraries"].firstMatch
        XCTAssertTrue(librariesTab.waitForExistence(timeout: 10))
        librariesTab.tap()
        libraryChooserConfirm(app, timeout: 2)?.tap()
        let card = titleButton(app, title)
        if !card.waitForExistence(timeout: 3) {
            // Either the library list, or another title's detail page from the previous download.
            let libraryButton = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", library)).firstMatch
            if !libraryButton.waitForExistence(timeout: 3) { librariesTab.tap() }
            XCTAssertTrue(libraryButton.waitForExistence(timeout: 20), "No \(library) library")
            libraryButton.tap()
        }
        XCTAssertTrue(card.waitForExistence(timeout: 20), "\(library) does not list \(title)")
        card.tap()
        let download = app.buttons["Download"].firstMatch
        XCTAssertTrue(download.waitForExistence(timeout: 20), "\(title) detail has no Download button")
        download.tap()
        let confirm = app.navigationBars["Download"].buttons["Download"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 45), "Download sheet never offered Download for \(title)")
        if converted {
            // The open films are small enough to finish before the queue can be observed, so ask for
            // a server conversion, which arrives at encode speed.
            let slow = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS %@", Self.slowQuality)).firstMatch
            var swipes = 0
            while !(slow.exists && slow.isHittable), swipes < 6 {
                app.swipeUp(velocity: .slow)
                swipes += 1
            }
            let offered = app.staticTexts.allElementsBoundByIndex.map(\.label).filter { $0.contains("Mbps") }
            XCTAssertTrue(slow.exists && slow.isHittable,
                          "Download sheet does not offer \(Self.slowQuality) for \(title); offered \(offered)")
            slow.tap()
        }
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline, !confirm.isEnabled { usleep(250_000) }
        XCTAssertTrue(confirm.isEnabled, "Download stayed disabled for \(title)")
        confirm.tap()
        let close = app.navigationBars["Download"].buttons["Close"].firstMatch
        sleep(1)
        if close.exists { close.tap() }
        // Leave the detail page so the next title is found in the library grid.
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.waitForExistence(timeout: 5) { back.tap() }
    }

    /// Change the simultaneous-downloads setting through Settings, and confirm it took.
    @MainActor
    private func setLimit(_ app: XCUIApplication, _ limit: Int) {
        app.tabBars.buttons["Home"].firstMatch.tap()
        let settings = app.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "Home has no Settings button")
        settings.tap()
        let matches = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "Simultaneous downloads"))
        let picker = matches.firstMatch
        var swipes = 0
        while !(picker.exists && picker.isHittable), swipes < 25 {
            app.swipeUp(velocity: .slow)
            swipes += 1
        }
        let found = matches.allElementsBoundByIndex.map { "\($0.elementType.rawValue):\($0.isHittable)" }
        XCTAssertTrue(picker.exists && picker.isHittable,
                      "Settings has no Simultaneous downloads control; matches \(found)")
        picker.tap()
        let choice = app.buttons["\(limit)"].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 5), "limit menu has no \(limit)")
        choice.tap()
        usleep(800_000)
        let shown = "\(picker.label) \(picker.value as? String ?? "")"
        XCTAssertTrue(shown.contains("\(limit)"), "Simultaneous downloads did not change to \(limit)")
        let close = app.buttons["Close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5), "Settings sheet has no Close button")
        close.tap()
    }

    /// Delete any download rows for the given titles, so the test can be run again.
    @MainActor
    private func deleteDownloads(_ app: XCUIApplication, titles: [String]) {
        openOffline(app)
        sleep(2)
        for title in titles {
            let row = app.staticTexts[title].firstMatch
            guard row.waitForExistence(timeout: 3) else { continue }
            // A tap plays a finished download; the long-press menu offers Delete for every row.
            row.press(forDuration: 1.0)
            let delete = app.buttons["Delete Download"].firstMatch
            XCTAssertTrue(delete.waitForExistence(timeout: 5), "row actions have no Delete Download")
            delete.tap()
            // The confirmation offers the same title again.
            sleep(1)
            let confirm = app.buttons["Delete Download"].firstMatch
            if confirm.waitForExistence(timeout: 5) { confirm.tap() }
            let gone = NSPredicate(format: "exists == false")
            expectation(for: gone, evaluatedWith: row)
            waitForExpectations(timeout: 20)
        }
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
        submit.tap()
    }
}
