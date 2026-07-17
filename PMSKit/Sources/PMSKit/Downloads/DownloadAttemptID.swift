import Foundation

/// Durable identity for one attempt to download a rating key.
///
/// The raw representation is intentionally a non-empty `String`, not a `UUID`. Existing download
/// indexes and background-task descriptions may contain arbitrary legacy tokens; preserving them
/// verbatim is required when they are promoted to the typed schema-v3 authority.
public struct DownloadAttemptID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard !rawValue.isEmpty else { return nil }
        self.rawValue = rawValue
    }

    /// Create an ID from a specific UUID. The injectable value keeps migration and marker tests
    /// deterministic while production callers can use `generated()`.
    public init(uuid: UUID) {
        rawValue = uuid.uuidString
    }

    public static func generated() -> Self {
        Self(uuid: UUID())
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let value = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "A download attempt ID must not be empty."
            )
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Complete ownership key for asynchronous download work. A rating key can be reused after delete
/// or retry, so neither component is sufficient on its own.
public struct DownloadAttemptKey: Codable, Hashable, Sendable {
    public let ratingKey: String
    public let attemptID: DownloadAttemptID

    public init(ratingKey: String, attemptID: DownloadAttemptID) {
        self.ratingKey = ratingKey
        self.attemptID = attemptID
    }
}
