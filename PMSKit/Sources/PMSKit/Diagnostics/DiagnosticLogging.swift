import Foundation

/// Stable categories used by VisionPlay's opt-in diagnostic report.
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
    case browse = "Browse"
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
        .string(DiagnosticRedactor.safeErrorSummary(error))
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

        // Full URLs FIRST: collapse the whole URL (scheme://…) to [url:scheme] so any
        // embedded token/host/path goes with it. Running the secret rules first would
        // rewrite an inline ?X-Plex-Token=… to [redacted]; the URL terminator below then
        // stops on the ']' of [redacted] and leaves a malformed "[url:https]]".
        output = replace(output,
                         pattern: #"\b([A-Za-z][A-Za-z0-9+.-]*)://[^\s)\]}>\"']+"#,
                         template: "[url:$1]")

        // Header/query-style secrets and client identifiers, for bare (non-URL) occurrences.
        // Accept `key=value` and the `key: value` header form, and tolerate the key being
        // wrapped/suffixed by quotes or brackets (e.g. "(X-Plex-Token)=", token"=). The
        // separator (incl. any wrapper) is preserved via $2.
        output = replace(output,
                         pattern: #"(?i)\b(X-Plex-Token|tokens?|access[_-]?token|api[_-]?key|apikey|password|passwd|pwd|secret|client[_-]?identifier|X-Plex-Client-Identifier)([\s"'\)\]]*[=:]\s*)([^\s&;,)]+)"#,
                         template: "$1$2[redacted]")
        // Authorization header, with or without a colon ("Authorization: Bearer x",
        // "Authorization Bearer x", "authorization = x").
        output = replace(output,
                         pattern: #"(?i)\b(Authorization\b[\s"'\)\]]*:?\s*)(Bearer\s+)?[^\s,;)]+"#,
                         template: "$1[redacted]")
        // Account/owner identifiers, both `=` and `:` forms (separator preserved via $2).
        output = replace(output,
                         pattern: #"(?i)\b(username|user|account|owner)(\s*[=:]\s*)([^\s&;,)]+)"#,
                         template: "$1$2[redacted]")

        // Common local/library paths and anything that looks like a media filename.
        output = replace(output,
                         pattern: #"(?i)(?:/Users/|/home/|/Volumes/|/mnt/|/media/|/storage/|/private/|/var/|/tmp/)[^\s,;)]*"#,
                         template: "[path]")
        output = replace(output,
                         pattern: #"(?i)\b[^\s/]+\.(mkv|mp4|m4v|mov|avi|ts|m3u8|mp3|flac|srt|ass|jpg|jpeg|png|webp)\b"#,
                         template: "[file]")

        // Emails whose domain is a raw IP (admin@192.0.2.10) must be redacted before the
        // IPv4 rule, otherwise the IP is peeled to [ip] and the local-part survives.
        output = replace(output,
                         pattern: #"\b[A-Z0-9._%+-]+@(?:\d{1,3}\.){3}\d{1,3}\b"#,
                         options: [.caseInsensitive],
                         template: "[email]")
        // IPv4, validating each octet is 0-255 so dotted version strings such as a Plex
        // build "1.40.2.8395" (4th group > 255) are not corrupted into [ip].
        output = replace(output,
                         pattern: #"(?<![\d.])(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(?![\d.])"#,
                         template: "[ip]")
        output = replace(output,
                         pattern: #"\[[0-9A-Fa-f:]{3,}\]"#,
                         template: "[ip]")
        // Emails (hostname domains) before the hostname rule, otherwise the domain is peeled
        // into [host] and the local-part survives (alice@example.com -> alice@[host]).
        output = replace(output,
                         pattern: #"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#,
                         options: [.caseInsensitive],
                         template: "[email]")
        // Bare hostnames (no scheme). Best-effort TLD allowlist — broad enough to cover
        // common server domains; the live preview + privacy ack are the backstop for the rest.
        output = replace(output,
                         pattern: #"\b(?:[A-Za-z0-9-]+\.)+(?:local|lan|home|internal|plex\.direct|com|net|org|io|tv|me|dev|app|co|us|uk|ca|de|fr|es|it|nl|au|eu|se|ch|info|biz|xyz|cloud|site|online|live|pro|direct)\b"#,
                         template: "[host]")
        output = replace(output,
                         pattern: #"\b[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}\b"#,
                         template: "[id]")
        output = replace(output,
                         pattern: #"\b[A-Za-z0-9_=-]{24,}\b"#,
                         template: "[token]")

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

    /// Broad NSError domain family used in logs and diagnostics instead of raw domains/userInfo.
    ///
    /// Raw `NSError` descriptions can include failing URLs, headers, local paths, server bodies, or
    /// other userInfo values. Public issue workflows should use this family plus the numeric code
    /// and class/kind, never `String(describing: error)` or `localizedDescription`.
    public static func errorDomainFamily(_ domain: String) -> String {
        switch domain {
        case NSURLErrorDomain:
            return "nsurl"
        // Avoid importing AVFoundation into PMSKit solely for `AVFoundationErrorDomain`; the public
        // constant's string value is stable and keeps this shared diagnostics helper lightweight.
        case "AVFoundationErrorDomain":
            return "avfoundation"
        case NSOSStatusErrorDomain:
            return "osstatus"
        case CocoaError.errorDomain:
            return "cocoa"
        case POSIXError.errorDomain:
            return "posix"
        default:
            let lower = domain.lowercased()
            if lower.contains("coremedia") { return "coremedia" }
            if lower.contains("fig") { return "fig" }
            if lower.contains("audio") { return "audio" }
            return "other"
        }
    }

    /// Redaction-safe error summary for public logs, diagnostics labels, and handoff text.
    ///
    /// The summary intentionally excludes `localizedDescription`, `debugDescription`, userInfo,
    /// failing URLs, request paths, server messages, and filenames. It keeps only structural facts
    /// useful for triage: Swift class name, broad URLSession/error kind, domain family, and code.
    public static func safeErrorSummary(_ error: Error?) -> String {
        guard let error else { return "class=none kind=none domain_family=none code=0" }
        let nsError = error as NSError
        return [
            "class=\(safeErrorTypeName(error))",
            "kind=\(errorClass(for: nsError))",
            "domain_family=\(errorDomainFamily(nsError.domain))",
            "code=\(nsError.code)"
        ].joined(separator: " ")
    }

    /// Short, user-facing message that remains useful without echoing raw URLSession/server text.
    public static func safeUserFacingErrorMessage(_ error: Error?,
                                                  operation: String = "Operation") -> String {
        guard let error else { return "\(operation) failed." }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorCancelled:
                return "\(operation) was cancelled."
            case NSURLErrorTimedOut:
                return "\(operation) timed out."
            case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost,
                 NSURLErrorDNSLookupFailed, NSURLErrorNotConnectedToInternet:
                return "\(operation) couldn't reach the server."
            case NSURLErrorUserAuthenticationRequired:
                return "\(operation) needs authentication."
            default:
                return "\(operation) failed (network code \(nsError.code))."
            }
        }

        switch errorDomainFamily(nsError.domain) {
        case "cocoa":
            return "\(operation) failed (system code \(nsError.code))."
        case "posix":
            return "\(operation) failed (POSIX code \(nsError.code))."
        case "avfoundation", "coremedia", "fig":
            return "\(operation) failed (media code \(nsError.code))."
        default:
            return "\(operation) failed (error code \(nsError.code))."
        }
    }

    /// Public-safe shape of a debug probe's media search query. Never includes the raw query.
    public static func probeQuerySummary(_ raw: String?) -> String {
        let normalized = normalizedProbeQuery(raw)
        guard !normalized.isEmpty else {
            return "present=false length_bucket=0 signature=none"
        }
        return "present=true length_bucket=\(probeQueryLengthBucket(normalized)) signature=\(stableIdentifier(for: normalized))"
    }

    /// Diagnostic fields for a debug probe query without storing media titles/search terms.
    public static func probeQueryFields(_ raw: String?) -> [String: DiagnosticFieldValue] {
        let normalized = normalizedProbeQuery(raw)
        guard !normalized.isEmpty else {
            return [
                "query_present": .bool(false),
                "query_length": .label("0"),
                "query_signature": .label("none")
            ]
        }
        return [
            "query_present": .bool(true),
            "query_length": .label(probeQueryLengthBucket(normalized)),
            "query_signature": .label(stableIdentifier(for: normalized))
        ]
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

    private static func safeErrorTypeName(_ error: Error) -> String {
        let raw = String(describing: type(of: error))
        let leaf = raw.split(separator: ".").last.map(String.init) ?? raw
        let safe = fieldKey(leaf)
        return safe.count > 80 ? String(safe.prefix(80)) : safe
    }

    private static func normalizedProbeQuery(_ raw: String?) -> String {
        (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func probeQueryLengthBucket(_ query: String) -> String {
        switch query.count {
        case 0: return "0"
        case 1...8: return "1-8"
        case 9...32: return "9-32"
        case 33...80: return "33-80"
        default: return "81+"
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

    /// Compiled-regex cache. `redact` runs ~14 patterns per call and the feedback sheet
    /// re-redacts the note live on every keystroke, so recompiling from source each time
    /// produced visible input lag. NSCache is internally thread-safe (its own locking is the
    /// external synchronization that justifies nonisolated(unsafe)); patterns are static literals.
    nonisolated(unsafe) private static let regexCache = NSCache<NSString, NSRegularExpression>()

    private static func cachedRegex(_ pattern: String,
                                    _ options: NSRegularExpression.Options) -> NSRegularExpression? {
        let key = "\(options.rawValue)\u{1}\(pattern)" as NSString
        if let cached = regexCache.object(forKey: key) { return cached }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        regexCache.setObject(regex, forKey: key)
        return regex
    }

    private static func replace(_ input: String,
                                pattern: String,
                                options: NSRegularExpression.Options = [],
                                template: String) -> String {
        guard let regex = cachedRegex(pattern, options) else { return input }
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
    public var adaptiveBitrateEnabled: Bool?
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
                adaptiveBitrateEnabled: Bool? = nil,
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
        self.adaptiveBitrateEnabled = adaptiveBitrateEnabled
        self.loggingEnabled = loggingEnabled
    }
}

public enum DiagnosticReportRenderer {
    public static func render(context: DiagnosticReportContext,
                              events: [DiagnosticEvent],
                              metricKitSummaries: [MetricKitDiagnosticSummary] = [],
                              maxEvents: Int = 80,
                              generatedAt: Date = Date()) -> String {
        let shownEvents = Array(events.suffix(max(0, maxEvents)))
        var lines: [String] = []
        lines.append("VisionPlay Diagnostic Report")
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
        if let adaptiveBitrateEnabled = context.adaptiveBitrateEnabled {
            lines.append("- Adaptive Bitrate: \(adaptiveBitrateEnabled ? "enabled" : "disabled")")
        }
        lines.append("")
        lines.append("Diagnostics")
        lines.append("- Diagnostic logging enabled: \(context.loggingEnabled ? "yes" : "no")")
        lines.append("- Ring buffer events: \(events.count) total, showing last \(shownEvents.count)")
        lines.append("- Collection is local and export is user-initiated.")
        lines.append("")
        lines.append(contentsOf: MetricKitDiagnosticSummarizer.reportSection(for: metricKitSummaries))
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
