import XCTest
@testable import PMSKit

final class RemotePlaybackPositionPolicyTests: XCTestCase {
    func testNoBaseLeavesPlayerTimeUnchanged() {
        XCTAssertEqual(RemotePlaybackPositionPolicy.absolutePositionMs(playerTimeMs: 12_000,
                                                                       streamBaseMs: nil),
                       12_000)
        XCTAssertEqual(RemotePlaybackPositionPolicy.absolutePositionMs(playerTimeMs: 12_000,
                                                                       streamBaseMs: 0),
                       12_000)
    }

    func testItemRelativeClockAddsStreamBase() {
        XCTAssertEqual(RemotePlaybackPositionPolicy.absolutePositionMs(playerTimeMs: 10_000,
                                                                       streamBaseMs: 416_000),
                       426_000)
    }

    func testZeroClockAtPrimedOffsetReportsBase() {
        XCTAssertEqual(RemotePlaybackPositionPolicy.absolutePositionMs(playerTimeMs: 0,
                                                                       streamBaseMs: 416_000),
                       416_000)
    }

    func testAlreadyAbsoluteClockIsNotDoubleCounted() {
        XCTAssertEqual(RemotePlaybackPositionPolicy.absolutePositionMs(playerTimeMs: 420_000,
                                                                       streamBaseMs: 416_000),
                       420_000)
    }

    func testSlightlyBeforeBaseCanBeSegmentBoundarySnap() {
        XCTAssertEqual(RemotePlaybackPositionPolicy.absolutePositionMs(playerTimeMs: 412_000,
                                                                       streamBaseMs: 416_000),
                       412_000)
    }
}
