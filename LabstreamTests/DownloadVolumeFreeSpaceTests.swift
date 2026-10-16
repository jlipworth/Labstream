import Foundation
import Testing
@testable import Labstream

struct DownloadVolumeFreeSpaceTests {
    /// Important-usage capacity wins when positive; zero or missing falls back to the system
    /// free size; neither available is unmeasured.
    @Test(arguments: [
        (87_000_000_000, 8_000_000_000, .init(bytes: 87_000_000_000, source: .importantUsage)),
        (0, 8_000_000_000, .init(bytes: 8_000_000_000, source: .systemFree)),
        (nil, 8_000_000_000, .init(bytes: 8_000_000_000, source: .systemFree)),
        (nil, nil, nil),
    ] as [(Int64?, Int64?, DownloadVolumeFreeSpace.Measurement?)])
    func resolvePrefersPositiveImportantUsageThenSystemFree(
        importantUsageBytes: Int64?,
        systemFreeBytes: Int64?,
        expected: DownloadVolumeFreeSpace.Measurement?
    ) {
        #expect(DownloadVolumeFreeSpace.resolve(importantUsageBytes: importantUsageBytes,
                                                systemFreeBytes: systemFreeBytes) == expected)
    }

    @Test func downloadsContainerVolumeIsMeasurable() throws {
        // On every supported download platform the app container volume must yield a
        // positive measurement through the real resource-value/statfs path.
        let directory = FileManager.default.temporaryDirectory
        let measured = try #require(DownloadVolumeFreeSpace.measure(directory: directory))
        #expect(measured.bytes > 0)
    }
}
