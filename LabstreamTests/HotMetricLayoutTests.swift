import SwiftUI
import XCTest
@testable import Labstream

@MainActor
final class HotMetricLayoutTests: XCTestCase {
    func testStableMetricEnvelopeDoesNotChangeWidthAcrossFormattingBoundaries() throws {
        try assertEqualRenderedWidths(
            ["5 MB/s", "5.1 MB/s", "9.9 MB/s", "10.0 MB/s", "999.9 MB/s"],
            envelope: .rate
        )
        try assertEqualRenderedWidths(
            ["9%", "10%", "99%", "100%", "~100%"],
            envelope: .percent
        )
        try assertEqualRenderedWidths(
            ["999 kbps", "1.0 Mbps", "9.9 Mbps", "10.0 Mbps"],
            envelope: .bitrate
        )
    }

    func testStableMetricEnvelopeScalesAsAUnitForAccessibilitySizes() throws {
        let normal = try renderedWidth(
            "10.0 MB/s", envelope: .rate, dynamicTypeSize: .medium
        )
        let accessibility = try renderedWidth(
            "10.0 MB/s", envelope: .rate, dynamicTypeSize: .accessibility3
        )
        XCTAssertGreaterThan(accessibility, normal)
    }

    func testRealisticActiveDownloadCaptionProducesIntentionalAtomicFields() {
        let caption = "Downloading transcode • ~9% • roughly 1h 8m left"
            + " • 12.4 GB media • 86.2 MB extras • 10.0 MB/s server-paced"
        let tokens = OfflineMetricToken.tokenize(caption)

        XCTAssertEqual(tokens.map(\.text), [
            "Downloading transcode",
            "~9%",
            "roughly 1h 8m left",
            "12.4 GB media",
            "86.2 MB extras",
            "10.0 MB/s server-paced",
        ])
        XCTAssertEqual(tokens.map(\.envelope), [
            nil, .percent, .duration, .bytes, .bytes, .annotatedRate,
        ])
    }

    func testCompactPortraitMetricFlowWrapsWholeFieldsInsteadOfClipping() throws {
        let tokens = OfflineMetricToken.tokenize(
            "Downloading original • 99% • ~12 min left • 12.4 GB • 10.0 MB/s"
        )
        let content = OfflineMetricFlowLayout(horizontalSpacing: 8, verticalSpacing: 3) {
            ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                if let envelope = token.envelope {
                    Text(token.text)
                        .font(.caption)
                        .stableHotMetric(envelope, alignment: .leading)
                        .lineLimit(1)
                } else {
                    Text(token.text).font(.caption).lineLimit(1)
                }
            }
        }
        .frame(width: 180, alignment: .leading)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        XCTAssertEqual(image.width, 180)
        XCTAssertGreaterThan(image.height, 40, "representative portrait metrics should stack")
    }

    private func assertEqualRenderedWidths(
        _ values: [String],
        envelope: HotMetricEnvelope
    ) throws {
        let widths = try values.map {
            try renderedWidth($0, envelope: envelope, dynamicTypeSize: .medium)
        }
        XCTAssertEqual(Set(widths).count, 1, "widths were \(widths)")
    }

    private func renderedWidth(
        _ value: String,
        envelope: HotMetricEnvelope,
        dynamicTypeSize: DynamicTypeSize
    ) throws -> Int {
        let renderer = ImageRenderer(content:
            Text(value)
                .font(.caption)
                .stableHotMetric(envelope)
                .environment(\.dynamicTypeSize, dynamicTypeSize)
        )
        renderer.scale = 1
        return try XCTUnwrap(renderer.cgImage).width
    }
}
