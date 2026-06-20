import Foundation

public enum JellyfinServerURLError: Error, Sendable, Equatable {
    case invalid
}

public enum JellyfinServerURL {
    public static func normalized(_ input: String) throws -> URL {
        guard let url = MediaBrowserURL.normalizedServerURL(input) else {
            throw JellyfinServerURLError.invalid
        }
        return url
    }
}
