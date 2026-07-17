import Foundation
import PMSKit
import Testing
@testable import Labstream

struct DownloadFileStatTests {
    @Test func largeSparseFileReportsLogicalSizeWithoutReadingItsBody() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("download-file-stat-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let file = directory.appendingPathComponent("large-error-body.tmp")
        #expect(fileManager.createFile(atPath: file.path, contents: nil))
        let logicalBytes: UInt64 = 16 * 1_024 * 1_024 * 1_024
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: logicalBytes)
        try handle.close()

        let values = try file.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey])
        #expect(values.fileSize == Int(logicalBytes))
        if let allocatedBytes = values.totalFileAllocatedSize {
            #expect(allocatedBytes < 64 * 1_024 * 1_024)
        }

        let measured = DownloadFileStat.logicalSize(at: file)
        #expect(measured == Int(logicalBytes))
        #expect(measured.map(DiagnosticRedactor.byteBucket) == "10GB+")
    }

    @Test func zeroByteFileReportsZero() throws {
        let fileManager = FileManager.default
        let file = fileManager.temporaryDirectory
            .appendingPathComponent("download-file-stat-empty-\(UUID().uuidString)")
        #expect(fileManager.createFile(atPath: file.path, contents: nil))
        defer { try? fileManager.removeItem(at: file) }

        #expect(DownloadFileStat.logicalSize(at: file) == 0)
    }

    @Test func missingOrFailedStatReturnsUnknownSize() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("download-file-stat-missing-\(UUID().uuidString)")
        #expect(DownloadFileStat.logicalSize(at: missing) == nil)

        var requestedPath: String?
        let denied = DownloadFileStat.logicalSize(at: missing) { path in
            requestedPath = path
            throw CocoaError(.fileReadNoPermission)
        }
        #expect(denied == nil)
        #expect(requestedPath == missing.path)
    }

    @Test func malformedNegativeAndOverflowingAttributesAreRejected() {
        let url = URL(fileURLWithPath: "/tmp/download-file-stat-fixture")
        #expect(DownloadFileStat.logicalSize(at: url) { _ in [:] } == nil)
        #expect(DownloadFileStat.logicalSize(at: url) { _ in [.size: "large"] } == nil)
        #expect(DownloadFileStat.logicalSize(at: url) { _ in [.size: -1] } == nil)
        #expect(DownloadFileStat.logicalSize(at: url) { _ in [.size: UInt64.max] } == nil)
        #expect(DownloadFileStat.logicalSize(at: url) { _ in [.size: NSNumber(value: true)] } == nil)
        #expect(DownloadFileStat.logicalSize(at: url) { _ in [.size: NSNumber(value: 1.5)] } == nil)
        #expect(DownloadFileStat.logicalSize(at: url) { _ in [.size: NSNumber(value: Double.nan)] } == nil)
        #expect(DownloadFileStat.logicalSize(at: url) { _ in [.size: NSNumber(value: Double.infinity)] } == nil)
    }

    @Test func injectedReaderIsCalledOnceAndAcceptsFoundationSizeShapes() {
        let url = URL(fileURLWithPath: "/tmp/download-file-stat-fixture")
        var callCount = 0
        let measured = DownloadFileStat.logicalSize(at: url) { path in
            callCount += 1
            #expect(path == url.path)
            return [.size: NSNumber(value: 123_456)]
        }

        #expect(callCount == 1)
        #expect(measured == 123_456)
    }
}
