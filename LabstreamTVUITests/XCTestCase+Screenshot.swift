import XCTest

extension XCTestCase {
    /// Attach a full-screen screenshot that survives a passing run.
    @MainActor
    func attachScreen(named name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
