import XCTest
@testable import PMSKit

final class StreamingQualityTests: XCTestCase {
    func testMaximaLabels() {
        XCTAssertEqual(StreamingQuality.label(kbps: StreamingQuality.maximumOriginalKbps),
                       "Direct Play / Maximum")
        XCTAssertEqual(StreamingQuality.label(kbps: StreamingQuality.maxTranscodedKbps),
                       "Maximum (HLS)")
    }

    func testNumericRungLabelsIncludeResolution() {
        XCTAssertEqual(StreamingQuality.label(kbps: 8000), "8 Mbps · 1080p")
        XCTAssertEqual(StreamingQuality.label(kbps: 2000), "2 Mbps · 720p")
        XCTAssertEqual(StreamingQuality.label(kbps: 40000), "40 Mbps · 4K")
    }

    func testUnknownRungFallsBackToBareMbps() {
        // A kbps not on the ladder (and not a maximum) renders just "<N> Mbps".
        XCTAssertEqual(StreamingQuality.label(kbps: 6000), "6 Mbps")
    }

    func testEveryNumericRungResolves() {
        for option in StreamingQuality.ladder where option.kbps != StreamingQuality.maximumOriginalKbps
            && option.kbps != StreamingQuality.maxTranscodedKbps {
            XCTAssertEqual(StreamingQuality.label(kbps: option.kbps),
                           "\(option.kbps / 1000) Mbps · \(option.resolution)")
        }
    }
}
