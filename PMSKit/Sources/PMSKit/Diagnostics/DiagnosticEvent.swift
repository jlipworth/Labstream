import Foundation

public struct DiagnosticEvent: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let category: DiagnosticCategory
    public let name: String
    public let fields: [String: DiagnosticFieldValue]

    public init(timestamp: Date = Date(),
                category: DiagnosticCategory,
                name: String,
                fields: [String: DiagnosticFieldValue] = [:]) {
        self.timestamp = timestamp
        self.category = category
        self.name = DiagnosticRedactor.eventName(name)
        self.fields = Dictionary(uniqueKeysWithValues: fields.map { key, value in
            let safeKey = DiagnosticRedactor.fieldKey(key)
            return (safeKey, DiagnosticRedactor.redactedFieldValue(value, forKey: safeKey))
        })
    }

    public func jsonLine() -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self),
              let string = String(data: data, encoding: .utf8) else {
            return #"{"category":"Diagnostics","name":"render_failed"}"#
        }
        // Field names and string field values are sanitized/redacted when the event is created.
        // Running the free-form redactor over the whole JSON line would also inspect JSON keys
        // and event names, which can falsely replace long safe identifiers such as
        // `plays_whole_file_directly` with `[token]`.
        return string
    }

    public var summaryLine: String {
        let fieldText = fields.keys.sorted().map { key in
            "\(key)=\(fields[key]?.description ?? "")"
        }.joined(separator: " ")
        let base = "[\(category.rawValue)] \(name)"
        return fieldText.isEmpty ? base : "\(base) \(fieldText)"
    }
}
