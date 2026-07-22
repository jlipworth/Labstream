import Foundation
import PMSKit
import Testing
@testable import Labstream

@Suite("Buffered diagnostic file sink")
struct DiagnosticFileLogSinkTests {
    @Test
    func bestEffortEventsStayBufferedUntilExplicitLifecycleFlush() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostic-buffer-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sink = DiagnosticFileLogSink(
            maxBytes: 64_000,
            archiveCount: 1,
            flushInterval: 60,
            flushByteThreshold: 64_000,
            directoryURL: directory
        )

        sink.append(DiagnosticEvent(category: .downloads, name: "buffered"))
        sink.flush()

        let file = directory.appendingPathComponent("app-diagnostics.jsonl")
        let contents = try String(contentsOf: file, encoding: .utf8)
        #expect(contents.contains("buffered"))
    }

    @Test
    func clearDiscardsQueuedEventsAndCannotResurrectThem() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostic-clear-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sink = DiagnosticFileLogSink(
            flushInterval: 0.01,
            flushByteThreshold: 64_000,
            directoryURL: directory
        )

        sink.append(DiagnosticEvent(category: .downloads, name: "discarded"))
        sink.clear()
        Thread.sleep(forTimeInterval: 0.03)
        sink.flush()

        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("app-diagnostics.jsonl").path
        ))
    }

    @Test
    func ephemeralEventsNeverReachTheFileBuffer() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostic-ephemeral-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sink = DiagnosticFileLogSink(directoryURL: directory)

        sink.append(DiagnosticEvent(category: .downloads, name: "ephemeral"),
                    durability: .ephemeral)
        sink.flush()

        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("app-diagnostics.jsonl").path
        ))
    }

    @Test
    func durabilityVocabularyKeepsAllFourContractsExplicit() {
        #expect(Set(PersistenceDurabilityTier.allCases) == [
            .barrier, .recoverableCheckpoint, .bestEffort, .ephemeral,
        ])
    }

    @Test
    func lifecycleFlushRotatesBeforeCrossingTheLiveFileBound() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostic-cross-boundary-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let live = directory.appendingPathComponent("app-diagnostics.jsonl")
        try Data(repeating: 1, count: 63_990).write(to: live)
        let sink = DiagnosticFileLogSink(
            maxBytes: 64_000,
            archiveCount: 1,
            flushInterval: 60,
            flushByteThreshold: 64_000,
            directoryURL: directory)

        sink.append(DiagnosticEvent(category: .downloads, name: "crosses-boundary"))
        sink.flush()

        let liveBytes = try #require(
            FileManager.default.attributesOfItem(atPath: live.path)[.size] as? NSNumber)
            .uint64Value
        #expect(liveBytes <= 64_000)
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("app-diagnostics.jsonl.1").path))
    }
}
