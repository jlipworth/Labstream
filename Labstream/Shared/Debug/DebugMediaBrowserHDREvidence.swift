#if DEBUG
import Foundation
import PMSKit

/// Explicit read-only wire-initialization evidence for an already source-bound playback open.
/// No credentials, transport URLs, playlist bodies or media fragments are written.
@MainActor
enum DebugMediaBrowserHDREvidence {
    static func capture(url: URL, headers: [String: String], backend: String, generation: Int) async {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("--vp-probe-allow-live"), args.contains("--vp-probe-hdr-evidence"),
              ["jellyfin", "emby"].contains(backend) else { return }
        let directory = URL.documentsDirectory.appendingPathComponent("HDRPackaging", isDirectory: true)
            .appendingPathComponent(backend, isDirectory: true)
        let output = directory.appendingPathComponent("init-\(generation).mp4")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: output.path) { try FileManager.default.removeItem(at: output) }
            guard url.pathExtension.lowercased() == "m3u8" else { return }
            let master = try await read(url, headers: headers, limit: 262_144)
            guard let text = String(data: master, encoding: .utf8), text.hasPrefix("#EXTM3U") else { return }
            var playlist = text
            var base = url
            let lines = text.split(whereSeparator: \.isNewline).map(String.init)
            let variants = lines.indices.filter { lines[$0].hasPrefix("#EXT-X-STREAM-INF:") }
            if !variants.isEmpty {
                // With more than one variant, a guessed child is not the player's wire evidence.
                guard variants.count == 1, variants[0] + 1 < lines.count,
                      !lines[variants[0] + 1].hasPrefix("#"),
                      let child = resolve(lines[variants[0] + 1], relativeTo: url) else { return }
                base = child
                guard let childText = String(data: try await read(child, headers: headers, limit: 262_144),
                                             encoding: .utf8), childText.hasPrefix("#EXTM3U") else { return }
                playlist = childText
            }
            guard !playlist.contains("#EXT-X-KEY:"), !playlist.contains("BYTERANGE") else { return }
            let maps = playlist.split(whereSeparator: \.isNewline).filter { $0.hasPrefix("#EXT-X-MAP:") }
            let prefix = "#EXT-X-MAP:URI=\""
            guard maps.count == 1, let map = maps.first, map.hasPrefix(prefix), map.hasSuffix("\"") else { return }
            let reference = String(map.dropFirst(prefix.count).dropLast())
            guard !reference.contains("\""), let initialization = resolve(reference, relativeTo: base) else { return }
            let data = try await read(initialization, headers: headers, limit: 1_048_576)
            guard isInitialization(data), !Task.isCancelled else { return }
            try data.write(to: output, options: .atomic)
        } catch {
            // No old file survives this attempt; evidence failure does not change playback policy.
        }
    }

    private static func resolve(_ value: String, relativeTo base: URL) -> URL? {
        guard let url = URL(string: value, relativeTo: base)?.absoluteURL,
              url.scheme == base.scheme, url.host == base.host, url.port == base.port,
              url.user == nil, url.password == nil, url.fragment == nil else { return nil }
        return url
    }

    private static func isInitialization(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        var offset = 0
        var types: [String] = []
        while offset < bytes.count {
            guard bytes.count - offset >= 8 else { return false }
            let size = (0..<4).reduce(0) { ($0 << 8) | Int(bytes[offset + $1]) }
            guard size >= 8, size <= bytes.count - offset else { return false }
            let type = String(decoding: bytes[(offset + 4)..<(offset + 8)], as: UTF8.self)
            guard ["ftyp", "moov", "free"].contains(type) else { return false }
            types.append(type)
            offset += size
        }
        return types.first == "ftyp" && types.filter { $0 == "ftyp" }.count == 1
            && types.filter { $0 == "moov" }.count == 1
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private static func read(_ url: URL, headers: [String: String], limit: Int) async throws -> Data {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        let session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.allHTTPHeaderFields = headers
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, response.url == url,
              response.expectedContentLength <= Int64(limit) else { throw URLError(.badServerResponse) }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit, !Task.isCancelled else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        return data
    }
}
#endif
