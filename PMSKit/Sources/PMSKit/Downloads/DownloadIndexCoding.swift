import Foundation

/// Resilient (de)serialization for the offline download index (`index.json`).
///
/// Current-schema serialization for the offline download index (`index.json`).
/// Kept in PMSKit so the envelope and per-row fail-closed behavior are unit-testable.
///
///   • Per-row decode isolation — the array is decoded element-by-element; a row that
///     fails to decode is skipped and counted, and every healthy row still loads.
///   • Versioned envelope — writes wrap rows in `{ schemaVersion, rows }`; unsupported
///     top-level shapes are classified by `startupProbe` and never decoded as rows.
///
/// The type is generic over the row so the persistence struct can stay private to
/// `DownloadStore`; the tests exercise the isolation/versioning with a stand-in row.
public enum DownloadIndexCoding {

    /// Schema version stamped once an index has been upgraded. Bump when the on-disk row shape
    /// changes in a way a loader must branch on.
    public static let currentSchemaVersion = 5

    /// Versions this binary loads as current (P3b). v4 and v5 share the row and envelope shape;
    /// a v4 index keeps being written as v4 until the store's upgrade stamps it v5, so a v4 file
    /// never contains a row created after the upgrade.
    public static let admissibleSchemaVersions: ClosedRange<Int> = 4...5

    /// A mutation-free startup classification. The app must run this before constructing any
    /// persistence writer, cleaning temporary files, or creating/protecting the Downloads root.
    /// Only an absent index and an admissible (v4 or v5) envelope are admissible. Older schemas are reset
    /// as one opaque root. A NEWER schema (written by a later app version, then downgraded) is
    /// classified unreadable: it is kept in place and fails closed, never reset, so reinstalling
    /// the newer app recovers every download.
    public enum StartupProbe: Sendable, Equatable {
        case missing
        case current
        case unsupported(schemaVersion: Int?)
        case unreadable
    }

    public static func startupProbe(data: Data?) -> StartupProbe {
        guard let data else { return .missing }
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return .unreadable
        }
        guard let envelope = object as? [String: Any] else {
            // The former bare-array schema is deliberately unsupported now.
            return object is [Any] ? .unsupported(schemaVersion: 1) : .unreadable
        }
        guard let rawVersion = envelope["schemaVersion"] else {
            return .unsupported(schemaVersion: nil)
        }
        guard let version = rawVersion as? Int,
              envelope["rows"] is [Any] else {
            return .unreadable
        }
        if admissibleSchemaVersions.contains(version) { return .current }
        if version > currentSchemaVersion { return .unreadable }
        return .unsupported(schemaVersion: version)
    }

    /// Outcome of a current-envelope load: the rows that decoded, the schema version, and how many rows were
    /// skipped because they failed to decode. A non-zero `skippedRowCount` is the
    /// caller's cue to log — silent truncation is exactly the failure this guards against.
    public struct DecodeResult<Row> {
        public let rows: [Row]
        public let schemaVersion: Int
        public let skippedRowCount: Int

        public init(rows: [Row], schemaVersion: Int, skippedRowCount: Int) {
            self.rows = rows
            self.schemaVersion = schemaVersion
            self.skippedRowCount = skippedRowCount
        }
    }

    /// Per-element wrapper that swallows a row's decode error instead of aborting the
    /// whole array. Decoding each element through a `singleValueContainer` advances the
    /// outer unkeyed container's cursor even when the inner `Row` decode fails, so one
    /// bad row never derails the rows that follow it.
    private struct LenientRow<Row: Decodable>: Decodable {
        let row: Row?
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            row = try? container.decode(Row.self)
        }
    }

    private struct DecodeEnvelope<Row: Decodable>: Decodable {
        let schemaVersion: Int
        let rows: [LenientRow<Row>]
    }

    private struct EncodeEnvelope<Row: Encodable>: Encodable {
        let schemaVersion: Int
        let rows: [Row]
    }

    /// Decode the on-disk index, skipping (and counting) any row that fails to decode.
    ///
    /// Only the versioned envelope is decoded. Startup probing owns unsupported-shape reset.
    public static func decode<Row: Decodable>(_ type: Row.Type, from data: Data) -> DecodeResult<Row> {
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(DecodeEnvelope<Row>.self, from: data),
           admissibleSchemaVersions.contains(envelope.schemaVersion) {
            let rows = envelope.rows.compactMap(\.row)
            return DecodeResult(rows: rows,
                                schemaVersion: envelope.schemaVersion,
                                skippedRowCount: envelope.rows.count - rows.count)
        }
        return DecodeResult(rows: [], schemaVersion: currentSchemaVersion, skippedRowCount: 0)
    }

    /// Encode rows into a versioned envelope; `schemaVersion` must be admissible (P3b writes v4
    /// until the upgrade stamp, v5 after it).
    public static func encode<Row: Encodable>(
        _ rows: [Row], schemaVersion: Int = currentSchemaVersion
    ) throws -> Data {
        precondition(admissibleSchemaVersions.contains(schemaVersion))
        let encoder = JSONEncoder()
        // Store recovery compares an ambiguous post-replace canonical file with the exact
        // candidate submitted to the persistence writer. JSON object key order is otherwise
        // unspecified, so two encodes of the same snapshot can produce different bytes.
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(EncodeEnvelope(schemaVersion: schemaVersion, rows: rows))
    }
}
