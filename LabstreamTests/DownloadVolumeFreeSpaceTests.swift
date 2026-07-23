import Foundation
import Testing
@testable import Labstream

struct DownloadVolumeFreeSpaceTests {
    @Test func importantUsageCapacityWinsWhenPositive() {
        let measured = DownloadVolumeFreeSpace.resolve(importantUsageBytes: 87_000_000_000,
                                                       systemFreeBytes: 8_000_000_000)
        #expect(measured == .init(bytes: 87_000_000_000, source: .importantUsage))
    }

    @Test func zeroImportantUsageFallsBackToSystemFree() {
        let measured = DownloadVolumeFreeSpace.resolve(importantUsageBytes: 0,
                                                       systemFreeBytes: 8_000_000_000)
        #expect(measured == .init(bytes: 8_000_000_000, source: .systemFree))
    }

    @Test func missingImportantUsageFallsBackToSystemFree() {
        let measured = DownloadVolumeFreeSpace.resolve(importantUsageBytes: nil,
                                                       systemFreeBytes: 8_000_000_000)
        #expect(measured == .init(bytes: 8_000_000_000, source: .systemFree))
    }

    @Test func bothUnavailableIsUnmeasured() {
        #expect(DownloadVolumeFreeSpace.resolve(importantUsageBytes: nil,
                                                systemFreeBytes: nil) == nil)
    }

    @Test func downloadsContainerVolumeIsMeasurable() throws {
        // On every supported download platform the app container volume must yield a
        // positive measurement through the real resource-value/statfs path.
        let directory = FileManager.default.temporaryDirectory
        let measured = try #require(DownloadVolumeFreeSpace.measure(directory: directory))
        #expect(measured.bytes > 0)
    }
}
