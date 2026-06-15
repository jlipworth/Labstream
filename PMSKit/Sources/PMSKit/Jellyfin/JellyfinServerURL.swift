import Foundation

public enum JellyfinServerURLError: Error, Sendable, Equatable {
    case invalid
}

public enum JellyfinServerURL {
    public static func normalized(_ input: String) throws -> URL {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw JellyfinServerURLError.invalid }

        let candidate: String
        if trimmed.contains("://") {
            candidate = trimmed
        } else {
            candidate = "https://\(trimmed)"
        }

        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              (scheme == "https" || scheme == "http"),
              let host = url.host,
              !host.isEmpty else {
            throw JellyfinServerURLError.invalid
        }
        return url
    }
}
