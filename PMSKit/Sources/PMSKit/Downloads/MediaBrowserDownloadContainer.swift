import Foundation

/// MediaBrowser lists aliases after the actual container. Never search later aliases for a
/// playable format; callers retain their own fallback when the first token is absent.
public enum MediaBrowserDownloadContainer {
    public static func token(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let first = raw.split(separator: ",", omittingEmptySubsequences: false).first ?? ""
        let token = first.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return token.isEmpty ? nil : token
    }
}
