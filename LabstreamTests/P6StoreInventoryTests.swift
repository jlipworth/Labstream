#if !os(tvOS)
import Foundation
import PMSKit
import Testing
@testable import Labstream

struct P6StoreInventoryTests {
    @Test("P6-pin-12 audit accounts for hidden working/held/temp bytes and protects intent paths")
    func auditAllBytes() async throws {
        let fixture = try P6Fixture()
        let initial = fixture.store()
        let key = try fixture.seed(initial)
        let working = try fixture.working(initial, key)
        let held = ".attempt-stage-v1-" + String(repeating: "b", count: 64) + ".stage"
        try Data([6, 7]).write(to: fixture.directory.appendingPathComponent(held))
        let segment = OfflineHeldRangeSegment(offset: 3, length: 2, relativePath: held)
        guard case .accepted(let heldSeed1) = initial.submitHeldRangeSegment(for: key, segment: segment) else {
            Issue.record("held seed failed"); return
        }
        #expect(await initial.resolveArtifact(heldSeed1.ticket, deadline: .after(30)) == .completed)
        #expect(await initial.resolve(initial.submitResumeData(for: key, Data([8])), deadline: .after(30)) == .applied)
        let resume = try #require(initial.record(for: key)?.metadata?.resumeDataRelativePath)
        let temporary = ".index.json.commit-00000000-0000-0000-0000-000000000001"
        for name in [temporary, "foreign.bin"] {
            try Data([4, 5]).write(to: fixture.directory.appendingPathComponent(name))
        }
        let hold = P6Hold()
        let store = fixture.store(index: .init { data, url in
            hold.hit()
            try DownloadIndexFileCommitter().commit(data, to: url)
        })
        defer { hold.release.signal() }
        hold.arm()
        let pending = store.submitValidatedPromotion(for: key, terminalStatus: .complete)
        guard case .accepted = pending else { Issue.record("promotion seed rejected"); return }
        try #require(await p6Signal(hold.entered))
        let before = try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).sorted()
        let everyByte = try before.reduce(0) { total, name in
            total + (try Data(contentsOf: fixture.directory.appendingPathComponent(name))).count
        }
        let audit = store.storageAudit()
        #expect(audit.directoryBytes == everyByte)
        #expect(audit.referencedRelativePaths.contains(working.lastPathComponent))

        #expect(audit.referencedRelativePaths.contains(held))
        #expect(audit.referencedRelativePaths.contains(resume))
        #expect(audit.referencedBytes + audit.unreferencedBytes == audit.directoryBytes)
        #expect(!audit.orphanCandidates.contains { ["foreign.bin", temporary, "index.json", held, resume].contains($0.relativePath) })
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).sorted() == before)
        #expect(OfflineDownloadFileInventory.isLabstreamOwnedDownloadFilename(held))

        hold.release.signal()
        _ = await store.resolveValidatedPromotion(pending, deadline: .after(30))
    }
}
#endif
