import XCTest

/// Host-capture handshake shared by the UI-test targets (identical copy in each target folder).
///
/// When the runner environment names `LABSTREAM_UI_CHECKPOINT_DIR` (a host path; simulator
/// processes share the host file system), `checkpoint("detail")` writes `detail.ready` there and
/// waits for the host driver to write `detail.done` after it has captured the simulator display.
/// Without the variable a checkpoint only attaches an in-process screenshot, so the tests stay
/// runnable from Xcode. visionOS in-process screenshots are 1×1, which is why the host captures.
enum UITestCheckpoint {
    static let directoryKey = "LABSTREAM_UI_CHECKPOINT_DIR"

    static var directory: URL? {
        guard let path = ProcessInfo.processInfo.environment[directoryKey], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}

extension XCTestCase {
    /// Pause at a named screen until the host driver has captured it. Fails the test when the
    /// driver is configured but never acknowledges, so a half-captured run cannot look complete.
    @MainActor
    func checkpoint(_ name: String, timeout: TimeInterval = 180) {
        guard let directory = UITestCheckpoint.directory else {
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            return
        }
        let ready = directory.appendingPathComponent("\(name).ready")
        let done = directory.appendingPathComponent("\(name).done")
        try? FileManager.default.removeItem(at: done)
        XCTAssertTrue(FileManager.default.createFile(atPath: ready.path, contents: Data()),
                      "cannot write the checkpoint marker for \(name)")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: done.path) {
                if let reason = try? String(contentsOf: done, encoding: .utf8), reason.hasPrefix("fail") {
                    XCTFail("host capture failed at \(name): \(reason)")
                }
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTFail("host driver did not acknowledge checkpoint \(name) within \(Int(timeout))s")
    }
}
