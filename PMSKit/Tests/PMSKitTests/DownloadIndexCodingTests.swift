import Foundation
import Testing
@testable import PMSKit

/// #135 Stage 6 — resilient offline-index (de)serialization. Exercises the per-row
/// decode isolation (H8) and current versioned-envelope behavior with a stand-in row,
/// so the silent-data-loss surface is covered without an app
/// test target (mirrors `OfflineDownloadModelsTests`).
struct DownloadIndexCodingTests {

    /// Stand-in for `DownloadStore.Row`: a couple of required fields plus an optional
    /// one. `key` being required is what a corrupt row can violate.
    private struct StubRow: Codable, Equatable {
        let key: String
        let bytes: Int
        var note: String?
    }

    private func data(_ json: String) -> Data { Data(json.utf8) }

    @Test func startupProbeSeparatesMissingCurrentUnsupportedAndUnreadable() throws {
        #expect(DownloadIndexCoding.startupProbe(data: nil) == .missing)
        #expect(DownloadIndexCoding.startupProbe(data: try DownloadIndexCoding.encode([StubRow]())) == .current)
        #expect(DownloadIndexCoding.startupProbe(data: data("[]")) == .unsupported(schemaVersion: 1))
        #expect(DownloadIndexCoding.startupProbe(
            data: data(#"{"schemaVersion":2,"rows":[]}"#)) == .unsupported(schemaVersion: 2))
        #expect(DownloadIndexCoding.startupProbe(
            data: data(#"{"schemaVersion":99,"rows":[]}"#)) == .unsupported(schemaVersion: 99))
        #expect(DownloadIndexCoding.startupProbe(data: data("not-json")) == .unreadable)
        #expect(DownloadIndexCoding.startupProbe(
            data: data(#"{"schemaVersion":4,"rows":"wrong"}"#)) == .unreadable)
    }

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

    // MARK: - H8: per-row decode isolation

    @Test func oneCorruptRowInEnvelopeDoesNotDropTheRest() {
        let json = #"{"schemaVersion":4,"rows":[{"key":"a","bytes":1},"garbage",{"key":"c","bytes":3}]}"#
        let result = DownloadIndexCoding.decode(StubRow.self, from: data(json))
        #expect(result.rows.map(\.key) == ["a", "c"])
        #expect(result.schemaVersion == 4)
        #expect(result.skippedRowCount == 1)
    }

    @Test func wrongTypedFieldRowIsSkippedNotFatal() {
        // `bytes` as a string can't decode into Int — that one row drops, others survive.
        let json = #"{"schemaVersion":4,"rows":[{"key":"a","bytes":1},{"key":"b","bytes":"oops"}]}"#
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

    @Test func unsupportedVersionEnvelopeIsNotDecoded() {
        let json = #"{"schemaVersion":99,"rows":[{"key":"a","bytes":1},{"key":"bad","bytes":"oops"},{"key":"b","bytes":2}]}"#
        let result = DownloadIndexCoding.decode(StubRow.self, from: data(json))
        #expect(result.rows.isEmpty)
        #expect(result.skippedRowCount == 0)
    }
}
