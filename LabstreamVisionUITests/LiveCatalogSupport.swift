import XCTest

/// Live-catalog UI-test support shared by the UI-test targets (identical copy in each target folder).

/// Runner-environment configuration shared by the live catalog tests.
struct LiveCatalogConfig {
    let server: String
    let username: String
    let password: String
    let library: String
    let title: String
    let attach: Bool

    static func load(_ environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Self {
        guard environment["LABSTREAM_LIVE_CATALOG_ALLOWED"] == "1",
              let server = environment["LABSTREAM_LIVE_AUTH_SERVER"], !server.isEmpty,
              let username = environment["LABSTREAM_LIVE_AUTH_USERNAME"], !username.isEmpty,
              let password = environment["LABSTREAM_LIVE_AUTH_PASSWORD"] else {
            throw XCTSkip("Live catalog tests need the private scripts/app-review-live.env configuration.")
        }
        guard let url = URL(string: server), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw XCTSkip("LABSTREAM_LIVE_AUTH_SERVER must be an HTTPS origin without credentials or query.")
        }
        return Self(server: server, username: username, password: password,
                    library: environment["LABSTREAM_LIVE_LIBRARY"].flatMap { $0.isEmpty ? nil : $0 } ?? "Movies",
                    title: environment["LABSTREAM_LIVE_TITLE"].flatMap { $0.isEmpty ? nil : $0 } ?? "Spring",
                    attach: environment["LABSTREAM_LIVE_ATTACH"] == "1")
    }
}

extension XCTestCase {
    /// The first button whose label starts with the catalog title (card labels append metadata).
    @MainActor
    func titleButton(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }

    #if !os(tvOS)
    /// Clear a text field and type a value. Never logs the value itself.
    @MainActor
    func replaceText(in field: XCUIElement, with value: String) {
        field.tap()
        if let current = field.value as? String, !current.isEmpty, current != field.placeholderValue {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        field.typeText(value)
    }
    #endif

    /// Give artwork a moment to load before a capture checkpoint.
    @MainActor
    func settle(_ app: XCUIApplication, seconds: UInt32 = 3) {
        sleep(seconds)
    }

    /// The confirm button ("Done", or "Save Selection" on tvOS) of the first-run Choose Libraries
    /// sheet that opens the first time Libraries is shown, or nil when the sheet is not showing.
    @MainActor
    func libraryChooserConfirm(_ app: XCUIApplication, timeout: TimeInterval = 5) -> XCUIElement? {
        let heading = app.staticTexts["Choose Libraries"].firstMatch
        let navTitle = app.navigationBars["Choose Libraries"].firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !heading.exists, !navTitle.exists { usleep(250_000) }
        guard heading.exists || navTitle.exists else { return nil }
        let confirm = app.buttons.matching(NSPredicate(format: "label IN %@", ["Done", "Save Selection"])).firstMatch
        return confirm.waitForExistence(timeout: 5) ? confirm : nil
    }
}
