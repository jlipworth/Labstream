#if DEBUG
import Foundation
import PMSKit

/// Opt-in, bounded packaging evidence. Credentials and playlist URLs are never exported.
@MainActor
enum DebugPlexHDREvidence {
    static var requested: Bool {
        let args = ProcessInfo.processInfo.arguments
        return args.contains("--vp-probe-allow-live") && args.contains("--vp-probe-hdr-evidence")
    }

    static func capture(master: String, baseURL: URL, headers: [String: String]) async {
        guard requested else { return }
        let directory = URL.documentsDirectory.appendingPathComponent("HDRPackaging", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let initFile = directory.appendingPathComponent("init.mp4")
            if FileManager.default.fileExists(atPath: initFile.path) {
                try FileManager.default.removeItem(at: initFile)
            }
            // Only bounded technical attributes; never dump server-authored URLs or comments.
            let patterns = ["CODECS=\"[^\"]{1,160}\"", "VIDEO-RANGE=[A-Z0-9]+",
                            "RESOLUTION=[0-9]+x[0-9]+", "FRAME-RATE=[0-9.]+"]
            let tags = master.split(whereSeparator: \.isNewline)
                .filter { $0.hasPrefix("#EXT-X-STREAM-INF:") }.prefix(8).map(String.init)
            let attributes = tags.flatMap { tag in patterns.flatMap { pattern in
                let regex = try! NSRegularExpression(pattern: pattern)
                return regex.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)).compactMap {
                    Range($0.range, in: tag).map { String(tag[$0]) }
                }
            } }
            let summary: [String: Any] = ["capturedAt": Date().timeIntervalSince1970,
                                          "variantCount": tags.count, "attributes": attributes]
            try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("master-summary.json"), options: .atomic)
            guard let child = PlexHLSMediaPlaylistPolicy.mediaPlaylist(in: master, baseURL: baseURL,
                                                                       hdrDisplayEligible: false),
                  let playlistData = try await read(child, headers: headers, limit: 256_000),
                  let playlist = String(data: playlistData, encoding: .utf8),
                  !playlist.contains("#EXT-X-KEY:"),
                  let map = playlist.split(whereSeparator: \.isNewline).first(where: {
                      $0.hasPrefix("#EXT-X-MAP:")
                  }), let start = map.range(of: "URI=\""),
                  let end = map[start.upperBound...].firstIndex(of: "\""),
                  let url = URL(string: String(map[start.upperBound..<end]), relativeTo: child)?.absoluteURL,
                  sameOrigin(url, child),
                  let data = try await read(url, headers: headers, limit: 1_048_576) else { return }
            try data.write(to: initFile, options: .atomic)
        } catch {
            // Failure leaves no old initialization segment and must not affect playback.
        }
    }

    private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme == rhs.scheme && lhs.host == rhs.host && lhs.port == rhs.port &&
            lhs.user == nil && lhs.password == nil
    }

    private static func read(_ url: URL, headers: [String: String], limit: Int) async throws -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.allHTTPHeaderFields = headers
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let finalURL = response.url, sameOrigin(finalURL, url) else { return nil }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { return nil }
            data.append(byte)
        }
        return data
    }
}
#endif
