import Foundation

/// Stable categories used by VisionPlex's opt-in diagnostic report.
///
/// Keep these raw values human-readable and durable: they are written into user-exported
/// reports and are intentionally broader than implementation file names.
public enum DiagnosticCategory: String, CaseIterable, Codable, Sendable, Equatable {
    case playback = "Playback"
    case transcode = "Transcode"
    case downloads = "Downloads"
    case music = "Music"
    case timeline = "Timeline"
    case auth = "Auth"
    case discovery = "Discovery"
    case networking = "Networking"
    case settingsUI = "Settings/UI"

    public var logCategory: String { rawValue }
}

/// A single field value for a diagnostic event.
///
/// String-producing cases pass through `DiagnosticRedactor` before storage, so callers can
/// describe errors, labels and URL shapes without exporting tokens, hosts, paths or filenames.
/// Media titles and user/library names should still not be passed in the first place: the
/// diagnostics API is for reproduction facts and shape-level identifiers only.
public enum DiagnosticFieldValue: Codable, Equatable, Sendable, CustomStringConvertible {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)

    public var description: String {
        switch self {
        case .string(let value): value
        case .int(let value): String(value)
        case .double(let value): Self.format(value)
        case .bool(let value): value ? "true" : "false"
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        }
    }

    public static func text(_ value: String?) -> DiagnosticFieldValue {
        .string(DiagnosticRedactor.redact(value ?? "unknown"))
    }

    public static func label(_ value: String?) -> DiagnosticFieldValue {
        .string(DiagnosticRedactor.redact(value ?? "unknown"))
    }

    public static func urlShape(_ url: URL?) -> DiagnosticFieldValue {
        .string(DiagnosticRedactor.urlShape(url))
    }

    public static func error(_ error: Error?) -> DiagnosticFieldValue {
        guard let error else { return .string("none") }
        let nsError = error as NSError
        let kind = DiagnosticRedactor.errorClass(for: nsError)
        return .string("class=\(kind) domain=\(DiagnosticRedactor.redact(nsError.domain)) code=\(nsError.code)")
    }

    public static func identifier(_ raw: String?) -> DiagnosticFieldValue {
        guard let raw, !raw.isEmpty else { return .string("id=unknown") }
        return .string("id=\(DiagnosticRedactor.stableIdentifier(for: raw))")
    }

    public static func bytes(_ bytes: Int?) -> DiagnosticFieldValue {
        guard let bytes, bytes >= 0 else { return .string("unknown") }
        return .string(DiagnosticRedactor.byteBucket(bytes))
    }

    public static func millisecondsBucket(_ milliseconds: Int?) -> DiagnosticFieldValue {
        guard let milliseconds, milliseconds > 0 else { return .string("0s") }
        let seconds = milliseconds / 1000
        switch seconds {
        case 0..<10: return .string("<10s")
        case 10..<60: return .string("\(seconds)s")
        case 60..<600: return .string("\(seconds / 60)m")
        default: return .string("\(seconds / 60)m+")
        }
    }

    public static func secondsBucket(_ seconds: Double?) -> DiagnosticFieldValue {
        guard let seconds, seconds.isFinite, seconds > 0 else { return .string("0s") }
        switch seconds {
        case 0..<10: return .string("<10s")
        case 10..<60: return .string("\(Int(seconds))s")
        case 60..<600: return .string("\(Int(seconds / 60))m")
        default: return .string("\(Int(seconds / 60))m+")
        }
    }

    private static func format(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        return String(format: "%.2f", value)
    }
}

/// Redaction helpers used at the diagnostics API boundary and again while rendering reports.
public enum DiagnosticRedactor {
    public static func redact(_ input: String) -> String {
        guard !input.isEmpty else { return input }
        var output = input

        // Header/query-style secrets and client identifiers.
        output = replace(output,
                         pattern: #"(?i)\b(X-Plex-Token|token|access[_-]?token|api[_-]?key|apikey|password|client[_-]?identifier|X-Plex-Client-Identifier)=([^\s&;,)]+)"#,
                         template: "$1=[redacted]")
        output = replace(output,
                         pattern: #"(?i)\b(Authorization:\s*)(Bearer\s+)?[^\s,;)]+"#,
                         template: "$1[redacted]")
        output = replace(output,
                         pattern: #"(?i)\b(user(name)?|account|owner)=([^\s&;,)]+)"#,
                         template: "$1=[redacted]")

        // Full URLs first, before hostname/path rules can leave pieces behind.
        output = replace(output,
                         pattern: #"\b([A-Za-z][A-Za-z0-9+.-]*)://[^\s)\]}>\"']+"#,
                         template: "[url:$1]")

        // Common local/library paths and anything that looks like a media filename.
        output = replace(output,
                         pattern: #"(?i)(?:/Users/|/home/|/Volumes/|/mnt/|/media/|/storage/|/private/|/var/|/tmp/)[^\s,;)]*"#,
                         template: "[path]")
        output = replace(output,
                         pattern: #"(?i)\b[^\s/]+\.(mkv|mp4|m4v|mov|avi|ts|m3u8|mp3|flac|srt|ass|jpg|jpeg|png|webp)\b"#,
                         template: "[file]")

        // Network locations and stable IDs.
        output = replace(output,
                         pattern: #"(?<![0-9])(?:\d{1,3}\.){3}\d{1,3}(?![0-9])"#,
                         template: "[ip]")
        output = replace(output,
                         pattern: #"\[[0-9A-Fa-f:]{3,}\]"#,
                         template: "[ip]")
        output = replace(output,
                         pattern: #"\b(?:[A-Za-z0-9-]+\.)+(?:local|lan|home|internal|plex\.direct|com|net|org|io|tv|me|dev|app)\b"#,
                         template: "[host]")
        output = replace(output,
                         pattern: #"\b[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}\b"#,
                         template: "[id]")
        output = replace(output,
                         pattern: #"\b[A-Za-z0-9_=-]{24,}\b"#,
                         template: "[token]")
        output = replace(output,
                         pattern: #"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#,
                         options: [.caseInsensitive],
                         template: "[email]")

        return output
    }

    public static func fieldKey(_ key: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.:")
        let scalars = key.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let sanitized = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "_.:-"))
        return sanitized.isEmpty ? "field" : sanitized
    }

    public static func redactedFieldValue(_ value: DiagnosticFieldValue,
                                          forKey key: String) -> DiagnosticFieldValue {
        switch value {
        case .string(let raw):
            let lowerKey = key.lowercased()
            if lowerKey.contains("title")
                || lowerKey.contains("filename")
                || lowerKey.contains("file_name")
                || lowerKey.contains("library_path")
                || lowerKey == "path"
                || lowerKey.hasSuffix("_path")
                || lowerKey == "host"
                || lowerKey.contains("hostname")
                || lowerKey.contains("ip_address")
                || lowerKey.contains("username") {
                return .string("[omitted]")
            }
            if lowerKey.contains("url"), !lowerKey.contains("shape") {
                return .string(URL(string: raw).map(urlShape) ?? redact(raw))
            }
            return .string(redact(raw))
        case .int, .double, .bool:
            return value
        }
    }

    public static func eventName(_ name: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.:-")
        let scalars = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let sanitized = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "_.:-"))
        return sanitized.isEmpty ? "event" : sanitized
    }

    public static func urlShape(_ url: URL?) -> String {
        guard let url else { return "scheme=none path=none" }
        let scheme = redact(url.scheme?.lowercased() ?? "unknown")
        if scheme == "file" { return "scheme=file path=local-file" }
        let family = pathFamily(for: url.path)
        return "scheme=\(scheme) path=\(family)"
    }

    public static func errorClass(for error: NSError) -> String {
        if error.domain == NSURLErrorDomain {
            switch error.code {
            case NSURLErrorCancelled: return "cancelled"
            case NSURLErrorTimedOut: return "timeout"
            case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost,
                 NSURLErrorDNSLookupFailed, NSURLErrorNotConnectedToInternet:
                return "server_unreachable"
            case NSURLErrorUserAuthenticationRequired: return "unauthorized"
            default: return "urlsession"
            }
        }
        if error.domain == CocoaError.errorDomain { return "cocoa" }
        if error.domain == POSIXError.errorDomain { return "posix" }
        return "error"
    }

    public static func byteBucket(_ bytes: Int) -> String {
        switch bytes {
        case 0..<1_000_000: return "<1MB"
        case 1_000_000..<10_000_000: return "1-10MB"
        case 10_000_000..<100_000_000: return "10-100MB"
        case 100_000_000..<1_000_000_000: return "100MB-1GB"
        case 1_000_000_000..<10_000_000_000: return "1-10GB"
        default: return "10GB+"
        }
    }

    public static func stableIdentifier(for raw: String) -> String {
        // FNV-1a: deterministic and non-raw, used only to correlate events inside a local report.
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in raw.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }

    private static func pathFamily(for path: String) -> String {
        let components = path.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return "/" }
        let mapped = components.prefix(4).map { component -> String in
            let trimmed = component.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == ":" { return ":" }
            if trimmed.range(of: #"^[0-9]+$"#, options: .regularExpression) != nil { return ":id" }
            if trimmed.range(of: #"^[A-Fa-f0-9-]{12,}$"#, options: .regularExpression) != nil { return ":id" }
            if trimmed.contains(".") { return "[file]" }
            return redact(trimmed)
        }
        return mapped.joined(separator: "/")
    }

    private static func replace(_ input: String,
                                pattern: String,
                                options: NSRegularExpression.Options = [],
                                template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return input }
        let range = NSRange(location: 0, length: (input as NSString).length)
        return regex.stringByReplacingMatches(in: input, options: [], range: range, withTemplate: template)
    }
}

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

/// Bounded in-memory ring buffer for opt-in diagnostics.
public final class DiagnosticLogStore: @unchecked Sendable {
    public let capacity: Int

    private let lock = NSLock()
    private var events: [DiagnosticEvent] = []
    private var enabled: Bool
    private let clock: @Sendable () -> Date

    public init(capacity: Int = 300,
                enabled: Bool = false,
                clock: @escaping @Sendable () -> Date = Date.init) {
        self.capacity = max(1, capacity)
        self.enabled = enabled
        self.clock = clock
    }

    public var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabled
    }

    public func setEnabled(_ enabled: Bool) {
        lock.lock()
        self.enabled = enabled
        lock.unlock()
    }

    @discardableResult
    public func record(category: DiagnosticCategory,
                       name: String,
                       fields: [String: DiagnosticFieldValue] = [:]) -> DiagnosticEvent? {
        lock.lock()
        guard enabled else {
            lock.unlock()
            return nil
        }
        let event = DiagnosticEvent(timestamp: clock(), category: category, name: name, fields: fields)
        events.append(event)
        if events.count > capacity {
            events.removeFirst(events.count - capacity)
        }
        lock.unlock()
        return event
    }

    public func snapshot(limit: Int? = nil) -> [DiagnosticEvent] {
        lock.lock()
        let current = events
        lock.unlock()
        guard let limit, limit >= 0, current.count > limit else { return current }
        return Array(current.suffix(limit))
    }

    public func clear() {
        lock.lock()
        events.removeAll(keepingCapacity: true)
        lock.unlock()
    }
}

public struct DiagnosticReportContext: Sendable, Equatable {
    public var product: String
    public var appVersion: String
    public var appBuild: String
    public var buildID: String?
    public var builtAt: String?
    public var operatingSystem: String
    public var deviceName: String
    public var backend: String
    public var server: String?
    public var connectionScheme: String?
    public var selectedQuality: String
    public var loggingEnabled: Bool

    public init(product: String,
                appVersion: String,
                appBuild: String,
                buildID: String? = nil,
                builtAt: String? = nil,
                operatingSystem: String,
                deviceName: String,
                backend: String,
                server: String? = nil,
                connectionScheme: String? = nil,
                selectedQuality: String,
                loggingEnabled: Bool) {
        self.product = product
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.buildID = buildID
        self.builtAt = builtAt
        self.operatingSystem = operatingSystem
        self.deviceName = deviceName
        self.backend = backend
        self.server = server
        self.connectionScheme = connectionScheme
        self.selectedQuality = selectedQuality
        self.loggingEnabled = loggingEnabled
    }
}

public enum DiagnosticReportRenderer {
    public static func render(context: DiagnosticReportContext,
                              events: [DiagnosticEvent],
                              maxEvents: Int = 80,
                              generatedAt: Date = Date()) -> String {
        let shownEvents = Array(events.suffix(max(0, maxEvents)))
        var lines: [String] = []
        lines.append("VisionPlex Diagnostic Report")
        lines.append("Generated: \(ISO8601DateFormatter().string(from: generatedAt))")
        lines.append("Sensitive values are omitted: tokens, client identifiers, hostnames/IPs, full URLs, usernames, library paths, filenames, and media titles should not appear in this report.")
        lines.append("")
        lines.append("App")
        lines.append("- Product: \(redact(context.product))")
        lines.append("- Version: \(redact(context.appVersion)) (\(redact(context.appBuild)))")
        lines.append("- Build ID: \(redact(context.buildID ?? "unknown"))")
        lines.append("- Built: \(redact(context.builtAt ?? "unknown"))")
        lines.append("- OS: \(redact(context.operatingSystem))")
        lines.append("- Device: \(redact(context.deviceName))")
        lines.append("- Backend: \(redact(context.backend))")
        if let server = context.server, !server.isEmpty {
            lines.append("- Server: \(redact(server))")
        }
        if let scheme = context.connectionScheme, !scheme.isEmpty {
            lines.append("- Connection scheme: \(redact(scheme))")
        }
        lines.append("- Selected quality: \(redact(context.selectedQuality))")
        lines.append("")
        lines.append("Diagnostics")
        lines.append("- Diagnostic logging enabled: \(context.loggingEnabled ? "yes" : "no")")
        lines.append("- Ring buffer events: \(events.count) total, showing last \(shownEvents.count)")
        lines.append("- Collection is local and export is user-initiated.")
        lines.append("")
        lines.append("Recent playback snapshot")
        if let snapshot = latestPlaybackSnapshot(in: events) {
            for key in snapshot.fields.keys.sorted() {
                lines.append("- \(key): \(snapshot.fields[key]?.description ?? "")")
            }
        } else {
            lines.append("- No playback snapshot captured in this app run.")
        }
        lines.append("")
        lines.append("Recent redacted events (JSONL, oldest to newest)")
        if shownEvents.isEmpty {
            lines.append("(none)")
        } else {
            lines.append(contentsOf: shownEvents.map { $0.jsonLine() })
        }
        return lines.joined(separator: "\n")
    }

    private static func latestPlaybackSnapshot(in events: [DiagnosticEvent]) -> DiagnosticEvent? {
        events.last { event in
            event.category == .playback && event.name == "playback.snapshot"
        }
    }

    private static func redact(_ value: String) -> String {
        DiagnosticRedactor.redact(value)
    }
}
