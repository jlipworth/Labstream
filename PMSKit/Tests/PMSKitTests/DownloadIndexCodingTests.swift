import Foundation
import Testing
@testable import PMSKit

/// #135 Stage 6 — resilient offline-index (de)serialization. Exercises the per-row
/// decode isolation (H8) and the versioned-envelope/legacy-bare-array compatibility
/// with a stand-in row, so the silent-data-loss surface is covered without an app
/// test target (mirrors `OfflineDownloadModelsTests`).
struct DownloadIndexCodingTests {

    /// Stand-in for `DownloadStore.Row`: a couple of required fields plus an optional
    /// one. `key` being required is what a corrupt/legacy row can violate.
    private struct StubRow: Codable, Equatable {
        let key: String
        let bytes: Int
        var note: String?
    }

    private func data(_ json: String) -> Data { Data(json.utf8) }

    // MARK: - Round trip + envelope

    @Test func encodeProducesVersionedEnvelope() throws {
        let rows = [StubRow(key: "a", bytes: 1, note: "x"), StubRow(key: "b", bytes: 2, note: nil)]
        let encoded = try DownloadIndexCoding.encode(rows)
        let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        #expect(object?["schemaVersion"] as? Int == DownloadIndexCoding.currentSchemaVersion)
        #expect((object?["rows"] as? [Any])?.count == 2)
    }

    @Test func roundTripPreservesRows() throws {
        let rows = [StubRow(key: "a", bytes: 10, note: "n"), StubRow(key: "b", bytes: 20, note: nil)]
        let result = DownloadIndexCoding.decode(StubRow.self, from: try DownloadIndexCoding.encode(rows))
        #expect(result.rows == rows)
        #expect(result.schemaVersion == DownloadIndexCoding.currentSchemaVersion)
        #expect(result.skippedRowCount == 0)
    }

    // MARK: - Legacy bare array

    @Test func legacyBareArrayStillLoadsAsVersionOne() {
        let json = #"[{"key":"a","bytes":1},{"key":"b","bytes":2,"note":"hi"}]"#
        let result = DownloadIndexCoding.decode(StubRow.self, from: data(json))
        #expect(result.rows.map(\.key) == ["a", "b"])
        #expect(result.schemaVersion == 1)
        #expect(result.skippedRowCount == 0)
    }

    // MARK: - H8: per-row decode isolation

    @Test func oneCorruptRowInBareArrayDoesNotDropTheRest() {
        // Middle row is missing the required `key` — the OLD all-or-nothing decode
        // would return zero rows; the resilient decode keeps the two healthy ones.
        let json = #"[{"key":"a","bytes":1},{"bytes":2},{"key":"c","bytes":3}]"#
        let result = DownloadIndexCoding.decode(StubRow.self, from: data(json))
        #expect(result.rows.map(\.key) == ["a", "c"])
        #expect(result.skippedRowCount == 1)
    }

    @Test func oneCorruptRowInEnvelopeDoesNotDropTheRest() {
        let json = #"{"schemaVersion":2,"rows":[{"key":"a","bytes":1},"garbage",{"key":"c","bytes":3}]}"#
        let result = DownloadIndexCoding.decode(StubRow.self, from: data(json))
        #expect(result.rows.map(\.key) == ["a", "c"])
        #expect(result.schemaVersion == 2)
        #expect(result.skippedRowCount == 1)
    }

    @Test func wrongTypedFieldRowIsSkippedNotFatal() {
        // `bytes` as a string can't decode into Int — that one row drops, others survive.
        let json = #"[{"key":"a","bytes":1},{"key":"b","bytes":"oops"}]"#
        let result = DownloadIndexCoding.decode(StubRow.self, from: data(json))
        #expect(result.rows.map(\.key) == ["a"])
        #expect(result.skippedRowCount == 1)
    }

    // MARK: - Unrecoverable top level

    @Test func unreadableTopLevelYieldsEmptyNotCrash() {
        let result = DownloadIndexCoding.decode(StubRow.self, from: data("not json at all"))
        #expect(result.rows.isEmpty)
        #expect(result.skippedRowCount == 0)
    }

    @Test func forwardVersionEnvelopePreservesHealthyRowsAndSkipsCorruption() {
        let json = #"{"schemaVersion":99,"rows":[{"key":"a","bytes":1},{"key":"bad","bytes":"oops"},{"key":"b","bytes":2}]}"#
        let result = DownloadIndexCoding.decode(StubRow.self, from: data(json))
        #expect(result.schemaVersion == 99)
        #expect(result.rows == [
            StubRow(key: "a", bytes: 1, note: nil),
            StubRow(key: "b", bytes: 2, note: nil),
        ])
        #expect(result.skippedRowCount == 1)
    }

    @Test func emptyArrayLoadsEmpty() {
        let result = DownloadIndexCoding.decode(StubRow.self, from: data("[]"))
        #expect(result.rows.isEmpty)
        #expect(result.skippedRowCount == 0)
    }
}
