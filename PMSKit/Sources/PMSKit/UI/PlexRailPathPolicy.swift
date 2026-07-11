import Foundation

public enum PlexRailPathPolicy {
    public struct Selection: Equatable, Sendable {
        public let path: String
        public let type: Int?
        public init(path: String, type: Int?) { self.path = path; self.type = type }
    }

    public static func recentlyAddedSelection(_ rawValue: String) -> Selection? {
        guard !rawValue.contains(".."), let components = URLComponents(string: rawValue),
              components.scheme == nil, components.host == nil else { return nil }
        if components.path.hasPrefix("/library/sections/"),
           components.path.hasSuffix("/recentlyAdded"), components.queryItems?.isEmpty ?? true {
            let parts = components.path.split(separator: "/", omittingEmptySubsequences: true)
            guard parts.count == 4, parts[0] == "library", parts[1] == "sections",
                  !parts[2].isEmpty, parts[3] == "recentlyAdded" else { return nil }
            return Selection(path: components.path, type: nil)
        }
        guard components.path == "/hubs/home/recentlyAdded",
              let query = components.queryItems, query.count == 1,
              query[0].name == "type", let rawType = query[0].value,
              let type = Int(rawType), [1, 2].contains(type) else { return nil }
        return Selection(path: components.path, type: type)
    }
}
