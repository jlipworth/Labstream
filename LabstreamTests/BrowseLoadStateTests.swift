import XCTest
@testable import Labstream

final class BrowseLoadStateTests: XCTestCase {
    func testHostedAppUsesInertUnitTestLaunchMode() {
        XCTAssertTrue(AppLaunchMode.isUnitTestHost)
    }

    func testFailureStatePreservesItsDiagnosticMessage() {
        let state = BrowseLoadState.failed("request failed")

        XCTAssertEqual(state, .failed("request failed"))
        XCTAssertNotEqual(state, .failed("a different failure"))
    }
}
