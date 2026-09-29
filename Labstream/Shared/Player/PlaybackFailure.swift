import Foundation
import PMSKit

/// Closed, privacy-safe playback failure vocabulary. Never derives UI text from server bodies,
/// error comments, URLs, filenames, or localized framework descriptions.
struct PlaybackFailure: LocalizedError, Equatable, Sendable {
    enum Code: String, Sendable {
        case backendUnsupported = "LS-PB-001"
        case serverHTTP = "LS-PB-002"
        case mediaDeliveryTimeout = "LS-PB-003"
        case safetyBlocked = "LS-PB-004"
        case consentRequired = "LS-PB-005"
        case connectionUnavailable = "LS-PB-006"
        case authenticationRequired = "LS-PB-007"
        case unknown = "LS-PB-999"
    }

    struct Signal: Sendable {
        let domain: String
        let code: Int
        var date: Date? = nil
    }

    let code: Code
    var httpStatus: Int?
    var backendDecision: Int?

    var errorDescription: String? { message }
    var message: String {
        let explanation: String
        switch code {
        case .backendUnsupported:
            explanation = "The server does not support this playback request. Try another version or contact the server administrator."
        case .serverHTTP:
            if httpStatus == 401 || httpStatus == 403 {
                explanation = "The server denied access to this stream. Check your sign-in and library access, then try again."
            } else {
                explanation = "The server could not deliver this stream. Check the server, then tap Retry."
            }
        case .mediaDeliveryTimeout:
            explanation = "Media did not arrive in time. Check the server and network, then tap Retry."
        case .safetyBlocked:
            explanation = "This video cannot be played safely through the server's current playback path. Try another version or contact the server administrator."
        case .consentRequired:
            explanation = "Original video could not be played. Video transcoding requires your permission."
        case .connectionUnavailable:
            explanation = "The server could not be reached. Check the server and network, then tap Retry."
        case .authenticationRequired:
            explanation = "Sign in to the server before trying playback again."
        case .unknown:
            explanation = "Playback failed for an unknown reason. Tap Retry; if it fails again, share this error code and app diagnostics."
        }
        let status = httpStatus.map { " · HTTP \($0)" } ?? ""
        return "\(explanation) [\(code.rawValue)\(status)]"
    }

    /// The caller supplies only this item's recent (30 second) error-log window.
    /// Concrete HTTP failures are terminal. Sustained delivery deadlines stop resource
    /// retries even when an audio-only clock appears to keep playing. AVPlayer may emit
    /// duplicate entries per request: counts alone must not reject a slow working prime.
    @MainActor
    static func deliveryFailure(signals: [Signal]) -> PlaybackFailure? {
        let classified = classify(nil, signals: signals)
        if classified.code == .serverHTTP { return classified }
        let deadlines = signals.filter {
            ($0.domain == "CoreMediaErrorDomain" && [-12889, -16830].contains($0.code))
                || ($0.domain == NSURLErrorDomain && $0.code == -1001)
        }
        let dates = deadlines.compactMap(\.date)
        guard deadlines.count >= 4, let first = dates.min(), let last = dates.max(),
              last.timeIntervalSince(first) >= 20 else { return nil }
        return .init(code: .mediaDeliveryTimeout)
    }

    @MainActor
    static func classify(_ error: Error?, signals: [Signal] = []) -> PlaybackFailure {
        if let failure = error as? PlaybackFailure { return failure }
        if let error = error as? PlexError {
            switch error {
            case .unauthorized: return .init(code: .serverHTTP, httpStatus: 401)
            case .serverUnreachable: return .init(code: .connectionUnavailable)
            case .http(let status) where (400...599).contains(status):
                return .init(code: .serverHTTP, httpStatus: status)
            default: break
            }
        }
        if let error = error as? MediaBrowserRequestError,
           case .httpStatus(let status) = error, (400...599).contains(status) {
            return .init(code: .serverHTTP, httpStatus: status)
        }
        if let error = error as? JellyfinBrowseService.ServiceError {
            switch error {
            case .http(let status) where (400...599).contains(status):
                return .init(code: .serverHTTP, httpStatus: status)
            case .notAuthenticated: return .init(code: .authenticationRequired)
            default: break
            }
        }
        if let error = error as? EmbyBrowseService.ServiceError {
            switch error {
            case .http(let status) where (400...599).contains(status):
                return .init(code: .serverHTTP, httpStatus: status)
            case .notAuthenticated: return .init(code: .authenticationRequired)
            default: break
            }
        }
        if error is ReconnectTimeoutError { return .init(code: .mediaDeliveryTimeout) }
        var facts = signals
        var current = error as NSError?
        // Bound traversal even for a malformed/cyclic underlying-error graph.
        for _ in 0..<8 {
            guard let value = current else { break }
            facts.append(.init(domain: value.domain, code: value.code))
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        for fact in facts.reversed() {
            if (fact.domain == "HTTP" || fact.domain == "HTTPErrorDomain"),
               (400...599).contains(fact.code) {
                return .init(code: .serverHTTP, httpStatus: fact.code)
            }
            // Observed AVPlayer error-log shape: CoreMedia -12938 = HTTP 404.
            if fact.domain == "CoreMediaErrorDomain" {
                if fact.code == -12938 { return .init(code: .serverHTTP, httpStatus: 404) }
                if fact.code == -16847 { return .init(code: .serverHTTP, httpStatus: 500) }
            }
        }
        if facts.contains(where: { $0.domain == "Labstream.Playback" && $0.code == -196 }) {
            return .init(code: .safetyBlocked)
        }
        if facts.contains(where: { $0.domain == "Labstream.Playback" && $0.code == -290 }) {
            return .init(code: .consentRequired)
        }
        if facts.contains(where: {
            (($0.domain == NSURLErrorDomain || $0.domain == "Labstream.Playback") && $0.code == -1001)
                || ($0.domain == "CoreMediaErrorDomain" && [-12889, -16830].contains($0.code))
        }) { return .init(code: .mediaDeliveryTimeout) }
        if facts.contains(where: { $0.domain == NSURLErrorDomain && [-1003, -1004, -1005, -1009].contains($0.code) }) {
            return .init(code: .connectionUnavailable)
        }
        if facts.contains(where: { $0.domain == NSURLErrorDomain && $0.code == -1011 }) {
            return .init(code: .serverHTTP)
        }
        return .init(code: .unknown)
    }
}
