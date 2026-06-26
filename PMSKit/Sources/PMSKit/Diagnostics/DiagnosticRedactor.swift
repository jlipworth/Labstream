import Foundation

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

    /// Compact token for DEBUG text logs and signpost fields that must remain human-readable but
    /// cannot carry arbitrary user/server text. Idempotent by construction.
    public static func safeLogToken(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "unknown" }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.:_,")
        var output = ""
        output.reserveCapacity(value.count)
        for scalar in value.unicodeScalars {
            if allowed.contains(scalar) {
                output.unicodeScalars.append(scalar)
            } else {
                output.append("_")
            }
        }
        return output.isEmpty ? "unknown" : output
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
