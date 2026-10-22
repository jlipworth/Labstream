import Foundation
import PMSKit
import Testing
@testable import Labstream

@Suite("Download index explicit file committer", .downloadTestFiles)
struct DownloadIndexFileCommitterTests {
    @Test func atomicallyReplacesCanonicalBytesAndLeavesNoTemporaryFile() throws {
        try withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("index.json")
            try Data("old".utf8).write(to: destination)

            try DownloadIndexFileCommitter().commit(Data("new".utf8), to: destination)

            #expect(try Data(contentsOf: destination) == Data("new".utf8))
            #expect(try commitTemps(in: directory).isEmpty)
            #expect(try destination.resourceValues(
                forKeys: [.isExcludedFromBackupKey]
            ).isExcludedFromBackup == true)
            if CredentialArtifactStorage.supportsFileProtectionAttributes {
                #if targetEnvironment(simulator)
                // The iOS/visionOS simulators accept the protection attribute but omit it from
                // `attributesOfItem`; a signed physical-platform run performs the readback.
                #else
                let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
                #expect(attributes[.protectionKey] as? FileProtectionType
                        == CredentialArtifactStorage.authArtifactProtection)
                #endif
            }
        }
    }

    /// A stage-hook failure must report its stage and whether replacement may have occurred,
    /// leave the canonical bytes that stage implies, and never strand a sibling temp.
    @Test(arguments: [
        (DownloadIndexFileCommitter.Stage.afterTempWrite, false, "old"),
        (DownloadIndexFileCommitter.Stage.beforeReplace, false, "old"),
        (DownloadIndexFileCommitter.Stage.afterReplace, true, "new"),
    ] as [(DownloadIndexFileCommitter.Stage, Bool, String)])
    func stageFailureReportsAmbiguityAndCleansTemporaryFile(
        failingStage: DownloadIndexFileCommitter.Stage,
        replacementMayHaveOccurred: Bool,
        expectedCanonical: String
    ) throws {
        try withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("index.json")
            try Data("old".utf8).write(to: destination)
            let committer = DownloadIndexFileCommitter(stageHook: { stage in
                if stage == failingStage { throw InjectedFailure() }
            })

            do {
                try committer.commit(Data("new".utf8), to: destination)
                Issue.record("expected injected \(failingStage) failure")
            } catch let failure as DownloadIndexFileCommitter.CommitFailure {
                #expect(failure.stage == failingStage)
                #expect(failure.replacementMayHaveOccurred == replacementMayHaveOccurred)
            }
            #expect(try Data(contentsOf: destination) == Data(expectedCanonical.utf8))
            #expect(try commitTemps(in: directory).isEmpty)
        }
    }

    @Test func startupRecoverySweepsOnlyAgedAbandonedSiblingTemps() throws {
        try withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("index.json")
            let stale = directory.appendingPathComponent(".index.json.commit-stale")
            let active = directory.appendingPathComponent(".index.json.commit-active")
            try Data("stale".utf8).write(to: stale)
            try Data("active".utf8).write(to: active)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-7_200)],
                ofItemAtPath: stale.path)

            try DownloadIndexFileCommitter.cleanupAbandonedTemps(for: destination)

            #expect(!FileManager.default.fileExists(atPath: stale.path))
            #expect(FileManager.default.fileExists(atPath: active.path))
        }
    }

    /// Each injected durability errno must report its exact stage and post-replace ambiguity,
    /// leaving the canonical bytes that stage implies.
    @Test(arguments: [
        (DurabilityFault.fullSync, DownloadIndexFileCommitter.Stage.afterTempWrite, false, "old"),
        (DurabilityFault.directorySync, DownloadIndexFileCommitter.Stage.afterReplace, true, "new"),
    ] as [(DurabilityFault, DownloadIndexFileCommitter.Stage, Bool, String)])
    func durabilitySyncFailureReportsStageAndAmbiguity(
        fault: DurabilityFault,
        expectedStage: DownloadIndexFileCommitter.Stage,
        replacementMayHaveOccurred: Bool,
        expectedCanonical: String
    ) throws {
        try withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("index.json")
            try Data("old".utf8).write(to: destination)
            let committer = DownloadIndexFileCommitter(
                durability: .init(
                    fullSync: { _ in fault == .fullSync ? EIO : nil },
                    directorySync: { _ in fault == .directorySync ? EIO : nil }))

            do {
                try committer.commit(Data("new".utf8), to: destination)
                Issue.record("expected \(fault) failure")
            } catch let failure as DownloadIndexFileCommitter.CommitFailure {
                #expect(failure.stage == expectedStage)
                #expect(failure.errnoCode == EIO)
                #expect(failure.replacementMayHaveOccurred == replacementMayHaveOccurred)
            }
            #expect(try Data(contentsOf: destination) == Data(expectedCanonical.utf8))
        }
    }

    enum DurabilityFault: Sendable, CustomStringConvertible {
        case fullSync
        case directorySync

        var description: String {
            switch self {
            case .fullSync: "full-sync"
            case .directorySync: "directory-sync"
            }
        }
    }

    private func commitTemps(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".index.json.commit-") }
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = DownloadTestFiles.temporaryDirectory
            .appendingPathComponent("DownloadIndexFileCommitterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        try body(directory)
    }

    private struct InjectedFailure: Error {}
}
