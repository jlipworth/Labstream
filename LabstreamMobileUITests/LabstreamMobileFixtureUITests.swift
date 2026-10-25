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

    /// #360: use the real Home LazyHStack with landscape-first mixed artwork. Test both
    /// visible cards and a later card after horizontal realization changes the lazy row.
    @MainActor
    func testHomeMixedArtworkShelvesHaveStableGeometry() {
        for backend in ["plex", "jellyfin", "emby"] {
            let app = XCUIApplication()
            app.launchEnvironment["LABSTREAM_UNIT_TEST_HOST"] = "0"
            app.launchArguments = ["--ui-testing", "--ui-testing-backend", backend,
                                   "--ui-testing-fixture", "browse"]
            app.launch()
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier CONTAINS %@", "-orbit"))
                .firstMatch.waitForExistence(timeout: 10))

            for (kind, title, nextTitle) in [
                ("movie", "Mixed Artwork Movies", "Mixed Artwork Shows"),
                ("show", "Mixed Artwork Shows", "Mixed Artwork Episodes"),
                ("episode", "Mixed Artwork Episodes", "")
            ] {
                let railID = backend == "plex" ? "fixture-shapes-\(kind)"
                    : "\(backend)-fixture-shapes-\(kind)"
                let first = app.buttons["labstream.home.\(railID).\(backend)-shapes-\(kind)-0"]
                let rail = app.scrollViews["labstream.home.rail.\(railID)"]
                let viewport = app.windows.firstMatch.frame.insetBy(dx: 0, dy: 90)
                for _ in 0..<12 {
                    // A partially visible row can report a hittable first card while its
                    // scroll view's gesture center remains under the bottom tab bar.
                    if first.exists && rail.exists,
                       rail.frame.minY >= viewport.minY, rail.frame.maxY <= viewport.maxY,
                       nextTitle.isEmpty || app.staticTexts[nextTitle].isHittable { break }
                    if rail.exists {
                        let frame = rail.frame
                        let delta = frame.minY < viewport.minY
                            ? max(-220, frame.minY - viewport.minY - 20)
                            : min(220, max(80, frame.maxY - viewport.maxY + 20))
                        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
                        start.press(forDuration: 0.01,
                                    thenDragTo: start.withOffset(CGVector(dx: 0, dy: -delta)))
                    } else {
                        app.swipeUp()
                    }
                }
                XCTAssertTrue(first.isHittable, "\(backend) \(kind) shelf should be reachable")
                let second = app.buttons["labstream.home.\(railID).\(backend)-shapes-\(kind)-1"]
                XCTAssertTrue(second.exists)
                let firstFrame = first.frame
                XCTAssertGreaterThan(firstFrame.height, 0)
                XCTAssertEqual(firstFrame.height, second.frame.height, accuracy: 1)
                XCTAssertEqual(firstFrame.minY, second.frame.minY, accuracy: 1)
                XCTAssertTrue(app.staticTexts[title].exists)
                XCTAssertLessThanOrEqual(app.staticTexts[title].frame.maxY, firstFrame.minY,
                                         "Cards must start below their own header")
                if !nextTitle.isEmpty {
                    XCTAssertTrue(app.staticTexts[nextTitle].exists)
                    XCTAssertLessThanOrEqual(firstFrame.maxY, app.staticTexts[nextTitle].frame.minY,
                                             "Labels must finish before the next header")
                }
                XCTAssertTrue(rail.exists)
                let last = app.buttons["labstream.home.\(railID).\(backend)-shapes-\(kind)-7"]
                for _ in 0..<8 {
                    if last.exists, viewport.contains(last.frame), !last.frame.isEmpty { break }
                    rail.swipeLeft()
                }
                XCTAssertTrue(last.isHittable)
                XCTAssertEqual(firstFrame.height, last.frame.height, accuracy: 1,
                               "Realizing later artwork must not resize the shelf")
                XCTAssertEqual(firstFrame.minY, last.frame.minY, accuracy: 1)
                let attachment = XCTAttachment(screenshot: app.screenshot())
                attachment.name = "home-mixed-artwork-\(backend)-\(kind)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            app.terminate()
        }
    }

    /// #415: the restricted Offline surface keeps its status in navigation chrome. Reconnect,
    /// Sign In, and Settings must all be reachable (the old top inset covered the toolbar).
    @MainActor
    func testOfflineLaunchKeepsToolbarActionsReachable() {
        let app = XCUIApplication()
        app.launchEnvironment["LABSTREAM_UNIT_TEST_HOST"] = "0"
        app.launchArguments = ["--ui-testing", "--ui-testing-fixture", "offline"]
        app.launch()

        let reconnect = app.buttons["labstream.offline-launch.reconnect"]
        XCTAssertTrue(reconnect.waitForExistence(timeout: 10))
        XCTAssertTrue(reconnect.isHittable)
        XCTAssertTrue(app.buttons["Sign In"].isHittable)
        XCTAssertTrue(app.buttons["Settings"].isHittable)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "offline-launch"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// #258: for a fixed device, orientation, and chrome state, the player chrome must occupy the
    /// same screen-relative frames whatever the source aspect (pillarboxed 4:3/16:9 or
    /// letterboxed 2.39:1) and whatever menu set the item offers.
    @MainActor
    func testPlayerChromeFramesAreStableAcrossSourceAspects() throws {
        // A phone-class player scene (slab iPhone, folded iPhone Duo) is locked to landscape; a
        // large scene (iPad, unfolded Duo) keeps the device orientation, so audit both there.
        let orientations = playerAuditOrientations()
        defer { XCUIDevice.shared.orientation = .portrait }
        for orientation in orientations {
            XCUIDevice.shared.orientation = orientation
            try assertStableChrome(orientationLabel: orientation == .portrait ? "portrait" : "landscape")
        }
    }

    @MainActor
    private func assertStableChrome(orientationLabel: String) throws {
        var reference: [String: CGRect]?
        // Skip-button slots legitimately differ between menu sets (the six-pill streaming set can
        // drop to the -10/+30 pair on a phone), so compare those only within one menu set.
        var skipReference: [Bool: [String: CGRect]] = [:]
        for (aspect, allMenus) in [("16x9", false), ("239x100", false), ("4x3", false),
                                   ("16x9", true), ("239x100", true)] {
            let (frames, skips) = try chromeFrames(aspect: aspect, allMenus: allMenus,
                                                   orientationLabel: orientationLabel)
            if let reference {
                try assertSameFrames(reference, frames, context: "\(orientationLabel) \(aspect)")
            } else {
                reference = frames
            }
            if let skipFrames = skipReference[allMenus] {
                try assertSameFrames(skipFrames, skips,
                                     context: "\(orientationLabel) \(aspect) all-menus=\(allMenus)")
            } else {
                XCTAssertFalse(skips.isEmpty, "skip buttons for \(aspect)")
                skipReference[allMenus] = skips
            }
        }
    }

    private func assertSameFrames(_ reference: [String: CGRect], _ frames: [String: CGRect],
                                  context: String) throws {
        for (label, frame) in reference {
            let other = try XCTUnwrap(frames[label], "\(label) missing for \(context)")
            XCTAssertEqual(frame.minX, other.minX, accuracy: 0.5, "\(label) x for \(context)")
            XCTAssertEqual(frame.minY, other.minY, accuracy: 0.5, "\(label) y for \(context)")
            XCTAssertEqual(frame.width, other.width, accuracy: 0.5, "\(label) width for \(context)")
            XCTAssertEqual(frame.height, other.height, accuracy: 0.5, "\(label) height for \(context)")
        }
    }

    /// The player's landscape lock is decided from the measured scene (short side below 500 pt
    /// is phone-class), never from the idiom. Started in portrait, a phone-class player scene
    /// must come up landscape; a large scene (iPad, the unfolded iPhone Duo) must not be rotated.
    /// On the Duo simulator this exercises whichever display it booted on (folded by default).
    @MainActor
    func testPlayerLandscapeLockFollowsMeasuredSceneClass() throws {
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = launchPlayerFixture(aspect: "16x9", paused: true)
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 30), "player chrome")
        XCTAssertTrue(app.sliders["playback.timeline"].waitForExistence(timeout: 5), "timeline")

        let window = app.windows.firstMatch.frame
        let shortSide = min(window.width, window.height)
        if shortSide < Self.phoneShortSideLimit {
            let landscape = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in
                    let frame = app.windows.firstMatch.frame
                    return frame.width > frame.height
                }, object: nil)
            XCTAssertEqual(XCTWaiter().wait(for: [landscape], timeout: 5), .completed,
                           "phone-class player scene \(window.size) locks to landscape")
        } else {
            XCTAssertGreaterThan(window.height, window.width,
                                 "large player scene \(window.size) keeps the portrait device orientation")
        }
        assertControlsInside(app.windows.firstMatch.frame, app: app, context: "lock")
        attachScreenshot(app, name: "player-lock-\(Int(window.width))x\(Int(window.height))")
    }

    /// Mirrors `MobilePlayerOrientationLockPolicy.phoneShortSideLimit`.
    private static let phoneShortSideLimit: CGFloat = 500

    /// Orientations a player audit should cover, from the measured player scene: a large scene
    /// keeps the device orientation (audit portrait and landscape), a phone-class one is locked.
    @MainActor
    private func playerAuditOrientations() -> [UIDeviceOrientation] {
        XCUIDevice.shared.orientation = .portrait
        let app = launchPlayerFixture(aspect: "16x9", paused: true)
        defer { app.terminate() }
        _ = app.buttons["Close"].waitForExistence(timeout: 30)
        let window = app.windows.firstMatch.frame
        return min(window.width, window.height) >= Self.phoneShortSideLimit
            ? [.portrait, .landscapeLeft] : [.portrait]
    }

    @MainActor
    private func assertControlsInside(_ window: CGRect, app: XCUIApplication, context: String) {
        for element in [app.buttons["Close"], app.sliders["playback.timeline"]] where element.exists {
            XCTAssertTrue(window.contains(element.frame),
                          "\(element.identifier.isEmpty ? element.label : element.identifier) inside window (\(context))")
        }
    }

    @MainActor
    private func launchPlayerFixture(aspect: String, paused: Bool, allMenus: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["LABSTREAM_UNIT_TEST_HOST"] = "0"
        app.launchArguments = ["--ui-testing", "--ui-testing-fixture", "player",
                               "--ui-testing-player-aspect", aspect, "--ui-testing-player-geometry"]
            + (paused ? ["--ui-testing-player-paused"] : [])
            + (allMenus ? ["--ui-testing-player-all-menus"] : [])
        app.launch()
        return app
    }

    @MainActor
    private func chromeFrames(aspect: String, allMenus: Bool,
                              orientationLabel: String) throws -> ([String: CGRect], [String: CGRect]) {
        let app = launchPlayerFixture(aspect: aspect, paused: true, allMenus: allMenus)
        defer { app.terminate() }

        let close = app.buttons["Close"]
        XCTAssertTrue(close.waitForExistence(timeout: 30), "player chrome for \(aspect)")
        let play = app.buttons["Play"]
        XCTAssertTrue(play.waitForExistence(timeout: 15), "paused chrome for \(aspect)")
        let timeline = app.sliders["playback.timeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 5))
        let displayMode = app.buttons["Zoom video to fill"]
        XCTAssertTrue(displayMode.waitForExistence(timeout: 5), "display-mode button for \(aspect)")
        let airPlay = app.descendants(matching: .any)["AirPlay"].firstMatch
        XCTAssertTrue(airPlay.waitForExistence(timeout: 5), "AirPlay button for \(aspect)")

        var frames = ["close": close.frame, "play": play.frame, "timeline": timeline.frame,
                      "displayMode": displayMode.frame, "airPlay": airPlay.frame]
        for control in [close, play, displayMode, airPlay] {
            assertHitTarget(control, "\(control.label) for \(aspect)")
        }

        // iPhone pills expose the full menu title; iPad's labeled strip exposes the short title.
        let pills = [("Quality", "Quality"), ("Subtitles", "Subs"), ("Audio", "Audio"),
                     ("Chapters", "Chapters"), ("Speed", "Speed"), ("Stats", "Stats")]
            .filter { allMenus || $0.0 != "Quality" }
        for (pill, shortTitle) in pills {
            let element = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@",
                                                           pill, shortTitle)).firstMatch
            XCTAssertTrue(element.waitForExistence(timeout: 5), "\(pill) pill for \(aspect)")
            assertHitTarget(element, "\(pill) pill for \(aspect)")
            frames["pill.\(pill)"] = element.frame
        }

        var skips: [String: CGRect] = [:]
        for label in ["Skip back 30 seconds", "Skip back 10 seconds",
                      "Skip forward 10 seconds", "Skip forward 30 seconds"] {
            // The zero-size hardware-keyboard shortcut buttons share these labels; skip them.
            guard let element = app.buttons.matching(identifier: label).allElementsBoundByIndex
                .first(where: { $0.frame.width > 0 && $0.isHittable }) else { continue }
            assertHitTarget(element, "\(label) for \(aspect)")
            skips[label] = element.frame
        }

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "player-chrome-\(orientationLabel)-\(aspect)\(allMenus ? "-all-menus" : "")"
        attachment.lifetime = .keepAlways
        add(attachment)
        return (frames, skips)
    }

    private func assertHitTarget(_ element: XCUIElement, _ context: String) {
        XCTAssertGreaterThanOrEqual(element.frame.width, 44, "hit width: \(context)")
        XCTAssertGreaterThanOrEqual(element.frame.height, 44, "hit height: \(context)")
    }

    /// Buffering overlay staging: the held `.buffering` fixture shows the stage-1 spinner after
    /// the show delay, escalates to the stage-2 card, and a paused wait presents the card
    /// directly. With chrome visible each stage sits between the top bar and the scrubber.
    @MainActor
    func testBufferingStatusStagesSitBetweenChrome() throws {
        // Phone-class player scenes are locked to landscape; large scenes are audited both ways.
        let orientations = playerAuditOrientations()
        defer { XCUIDevice.shared.orientation = .portrait }
        for orientation in orientations {
            XCUIDevice.shared.orientation = orientation
            let label = orientation == .portrait ? "portrait" : "landscape"

            let app = XCUIApplication()
            app.launchEnvironment["LABSTREAM_UNIT_TEST_HOST"] = "0"
            app.launchArguments = ["--ui-testing", "--ui-testing-fixture", "player",
                                   "--ui-testing-player-buffering"]
            app.launch()
            let spinner = app.descendants(matching: .any)["playback.transportStatus.spinner"]
            XCTAssertTrue(spinner.waitForExistence(timeout: 30), "stage-1 spinner (\(label))")
            XCTAssertFalse(app.buttons["playback.buffer.playPause"].exists,
                           "stage 1 must not show the card action (\(label))")
            assertBetweenVisibleChrome(spinner.frame, in: app, context: "spinner \(label)")
            attachScreenshot(app, name: "buffering-stage1-spinner-\(label)")
            let cardAction = app.buttons["playback.buffer.playPause"]
            XCTAssertTrue(cardAction.waitForExistence(timeout: 10), "stage-2 card (\(label))")
            attachScreenshot(app, name: "buffering-stage2-card-\(label)")
            app.terminate()

            let paused = XCUIApplication()
            paused.launchEnvironment["LABSTREAM_UNIT_TEST_HOST"] = "0"
            paused.launchArguments = ["--ui-testing", "--ui-testing-fixture", "player",
                                      "--ui-testing-player-buffering", "--ui-testing-player-paused"]
            paused.launch()
            let resume = paused.buttons["playback.buffer.playPause"]
            XCTAssertTrue(resume.waitForExistence(timeout: 30), "paused card (\(label))")
            XCTAssertEqual(resume.label, "Resume when ready")
            XCTAssertTrue(paused.buttons["Close"].waitForExistence(timeout: 5))
            assertBetweenVisibleChrome(resume.frame, in: paused, context: "paused card \(label)")
            attachScreenshot(paused, name: "buffering-paused-card-chrome-\(label)")
            paused.terminate()
        }
    }

    @MainActor
    private func assertBetweenVisibleChrome(_ frame: CGRect, in app: XCUIApplication, context: String) {
        let close = app.buttons["Close"]
        let timeline = app.sliders["playback.timeline"]
        guard close.exists, close.isHittable, timeline.exists, timeline.isHittable else { return }
        XCTAssertGreaterThan(frame.minY, close.frame.maxY, "\(context) clears the top bar")
        XCTAssertLessThan(frame.maxY, timeline.frame.minY, "\(context) clears the scrubber")
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// #258 on iPad: the chrome shows/hides the status bar with itself. Hiding and revealing the
    /// chrome must not move the chrome envelope (and so must not move the top controls or the
    /// centered overlays) by the status-bar inset.
    @MainActor
    func testPlayerChromeEnvelopeIsStableAcrossRevealAndHide() throws {
        let app = launchPlayerFixture(aspect: "16x9", paused: false)
        defer { app.terminate() }

        let surface = app.descendants(matching: .any)["playback.debug.chromeEnvelope"]
        let close = app.buttons["Close"]
        XCTAssertTrue(close.waitForExistence(timeout: 30))
        XCTAssertTrue(surface.waitForExistence(timeout: 5))
        let revealedSurface = surface.frame
        let revealedClose = close.frame
        let revealedTimeline = app.sliders["playback.timeline"].frame

        // Playing chrome auto-hides after a few seconds.
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                               object: close)
        XCTAssertEqual(XCTWaiter().wait(for: [hidden], timeout: 20), .completed, "chrome auto-hide")
        let hiddenSurface = surface.frame
        XCTAssertEqual(hiddenSurface.minY, revealedSurface.minY, accuracy: 0.5, "envelope top while hidden")
        XCTAssertEqual(hiddenSurface.height, revealedSurface.height, accuracy: 0.5, "envelope height while hidden")
        XCTAssertEqual(hiddenSurface.minX, revealedSurface.minX, accuracy: 0.5, "envelope leading while hidden")
        XCTAssertEqual(hiddenSurface.width, revealedSurface.width, accuracy: 0.5, "envelope width while hidden")

        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        XCTAssertTrue(close.waitForExistence(timeout: 5), "chrome reveal")
        XCTAssertEqual(close.frame.minY, revealedClose.minY, accuracy: 0.5, "close after reveal")
        XCTAssertEqual(close.frame.minX, revealedClose.minX, accuracy: 0.5, "close after reveal")
        XCTAssertEqual(app.sliders["playback.timeline"].frame.minY, revealedTimeline.minY,
                       accuracy: 0.5, "timeline after reveal")
    }
}
