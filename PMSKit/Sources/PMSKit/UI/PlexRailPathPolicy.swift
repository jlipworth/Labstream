import Foundation

public enum PlexRailPathPolicy {
    public static func safeRecentlyAddedPath(_ rawPath: String) -> String? {
        guard rawPath.hasPrefix("/library/sections/"),
              rawPath.hasSuffix("/recentlyAdded"),
              !rawPath.contains(".."),
              URL(string: rawPath)?.scheme == nil,
              URL(string: rawPath)?.host == nil else { return nil }
        let parts = rawPath.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 4, parts[0] == "library", parts[1] == "sections",
              !parts[2].isEmpty, parts[3] == "recentlyAdded" else { return nil }
        return rawPath
    }
}
