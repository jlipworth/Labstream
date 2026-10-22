#if !os(tvOS)
import Foundation
import PMSKit
import Testing
@testable import Labstream

@Suite(.downloadTestFiles)
struct P6StoreLoadSafetyTests {
    @Test("P6-pin-10 loader source guard plus duplicate conservation", arguments: [4, 5], [false, true])
    func checkedIngestion(version: Int, differentAttempt: Bool) throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Labstream/Capabilities/Downloads/Core/DownloadStore.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        let load = try #require(text.range(of: "private func load("))
        let usesTrappingInitializer = text[load.lowerBound...].contains("Dictionary(uniqueKeysWithValues:")
        #expect(!usesTrappingInitializer)

        let fixture = try P6Fixture()
        let seed = fixture.store()
        let key = try fixture.seed(seed, status: .paused)
        let working = try fixture.working(seed, key)
        let index = fixture.directory.appendingPathComponent("index.json")
        let original = try Data(contentsOf: index)
        var object = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        let rows = try #require(object["rows"] as? [[String: Any]])
        var duplicate = try #require(rows.first)
        if differentAttempt { duplicate["attemptID"] = "attempt-other" }
        object["schemaVersion"] = version
        object["rows"] = rows + [duplicate]
        let corrupt = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try corrupt.write(to: index)
        let blocked = fixture.store()
        #expect(blocked.startupIndexAdmission() != .current)
        #expect(blocked.record(for: key) == nil)
        #expect(blocked.reprobeBlockedIndex() != .current)
        #expect(try Data(contentsOf: index) == corrupt)
        #expect(try Data(contentsOf: working) == Data([1, 2, 3]))
        try original.write(to: index)
        #expect(blocked.reprobeBlockedIndex() == .current)
        #expect(blocked.record(for: key) != nil)
    }
    @Test("a newer recovery epoch rejects an older held probe observation")
    func supersededRecoveryObservation() async throws {
        let fixture = try P6Fixture()
        let initial = fixture.store()
        let key = try fixture.seed(initial, status: .paused)
        let index = fixture.directory.appendingPathComponent("index.json")
        let valid = try Data(contentsOf: index)
        try Data("invalid".utf8).write(to: index)
        let hold = P6Hold()
        let store = DownloadTestFiles.store(baseDirectory: fixture.directory, indexPersistence: .init(read: { url in
            let data = try Data(contentsOf: url)
            hold.hit()
            return data
        }, atomicWrite: { data, url in try DownloadIndexFileCommitter().commit(data, to: url) }))
        defer { hold.release.signal() }
        hold.arm()
        let old = store.submitReprobeBlockedIndex()
        try #require(await p6Signal(hold.entered))
        try valid.write(to: index)
        let latest = store.submitReprobeBlockedIndex()
        #expect(await store.resolve(latest, deadline: .after(0.01)) == .timedOut(epoch: latest.epoch))
        hold.release.signal()
        _ = await store.resolve(old, deadline: .after(5))
        #expect(await store.resolve(latest, deadline: .after(5)) == .observed(.current))
        #expect(store.startupIndexAdmission() == .current)
        #expect(store.record(for: key) != nil)
        #expect(try Data(contentsOf: index) == valid)
    }

}
#endif
