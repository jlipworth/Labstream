import Foundation

/// Pure best-effort matching from a surviving background URLSession task back to a download row.
///
/// New tasks set `taskDescription` to the row key; URL fallbacks exist only for older tasks that
/// survived relaunch without that description. Plex static part URLs generally cannot be reverse
/// mapped from `/library/parts/...`, so they intentionally require the explicit task description.
public enum BackgroundDownloadTaskIdentity {
    public static func ratingKey(taskDescription: String?,
                                 requestURL: URL?,
                                 knownKeys: Set<String>) -> String? {
        if let taskDescription, knownKeys.contains(taskDescription) {
            return taskDescription
        }
        guard let url = requestURL,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }

        let candidates: [String]
        if let path = components.queryItems?.first(where: { $0.name == "path" })?.value {
            candidates = [(path as NSString).lastPathComponent]
        } else {
            let parts = components.path.split(separator: "/").map(String.init)
            if let items = parts.firstIndex(of: "Items"), parts.indices.contains(items + 1) {
                candidates = [parts[items + 1]]
            } else if let videos = parts.firstIndex(of: "Videos"), parts.indices.contains(videos + 1) {
                candidates = [parts[videos + 1]]
            } else {
                candidates = []
            }
        }

        let expanded = candidates.flatMap { [$0, "jellyfin:\($0)"] }
        return expanded.first { knownKeys.contains($0) }
    }
}
