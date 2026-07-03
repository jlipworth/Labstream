import Foundation

/// GH #196 — copy-lane startup hardening for Plex universal-transcode HLS.
///
/// PMS's HEVC video-copy lane emits a SINGLE-variant master playlist whose fMP4 segments
/// are 10 seconds / tens of MB each. AVFoundation enforces hard per-file startup deadlines
/// (-12889 "no response in 10s", -16830 "media file not received in 20s"); on a miss it
/// removes the variant, and with only one variant playback dies permanently
/// (-12880 "can not proceed after removing variants") instead of buffering. On a cold
/// session the PMS transcoder only starts writing once the child playlist is fetched, so
/// under server load the first segment can miss those deadlines even on a healthy link.
///
/// Two complementary mitigations live here:
///  - `HLSStartupDeadlinePolicy`: classify the CoreMedia error-log codes so the controller
///    can auto-retry once (segments written during the failed attempt make the retry warm)
///    and surface an accurate message instead of a generic capacity hint.
///  - `PlexHLSPrewarmer`: fetch master + child playlist (which starts the transcoder) and
///    poll the init header / first segment until PMS actually has bytes, BEFORE AVPlayer
///    attaches — so AVPlayer's deadlines start with media already on disk.
enum HLSStartupDeadlinePolicy {
    /// "No response for media file in 10 seconds" — AVFoundation abandons the file.
    static let noResponseCode = -12889
    /// "Media file not received in 20s" — AVFoundation abandons the file.
    static let notReceivedCode = -16830
    /// "Can not proceed after removing variants" — terminal: the only variant is gone.
    static let variantsRemovedCode = -12880

    static func isStartupDeadlineCode(_ code: Int) -> Bool {
        code == noResponseCode || code == notReceivedCode || code == variantsRemovedCode
    }

    /// User-facing message for a startup-deadline abandonment on the copy lane.
    static func failureMessage(errorLogCodes: [Int]) -> String {
        let codes = errorLogCodes.map(String.init).joined(separator: ", ")
        return "The server was too slow to deliver the first video segments, so the player "
            + "gave up on the stream (CoreMedia \(codes)). The segments are usually ready on "
            + "a second attempt — tap Retry, or choose a lower quality."
    }
}

/// Warms a PMS `start.m3u8` transcode session before AVPlayer attaches: fetches the master
/// playlist, fetches the child playlist (this is what actually starts the transcoder), then
/// polls the `#EXT-X-MAP` init header and the first media segment until the server serves
/// them. All failures are soft — the caller proceeds to AVPlayer regardless; the prewarm
/// only buys head start, never gates playback.
enum PlexHLSPrewarmer {
    struct Result {
        enum Outcome: String {
            case ready              // header (and first-segment first byte) confirmed served
            case timedOut           // budget elapsed before media appeared
            case playlistUnavailable // master/child fetch failed or unparseable
            case cancelled
        }
        let outcome: Outcome
        let elapsedSeconds: Double
        let polls: Int
    }

    /// Always warms the init header + segment 0: with `offset=` dropped the playlist has no
    /// `EXT-X-START`, so AVPlayer primes at position 0 first (segment 0) and only then does
    /// the client-side resume seek jump the transcoder to the playhead. Segment 0 existing
    /// is what gets the item to `readyToPlay` inside AVFoundation's deadlines.
    static func prewarm(startURL: URL,
                        headers: [String: String],
                        budgetSeconds: Double = 20) async -> Result {
        let clock = ContinuousClock.now
        func elapsed() -> Double {
            Double(clock.duration(to: .now).components.seconds)
                + Double(clock.duration(to: .now).components.attoseconds) / 1e18
        }
        func remaining() -> Double { budgetSeconds - elapsed() }

        guard let master = await fetchPlaylist(startURL, headers: headers, timeout: remaining()),
              let childURL = firstMediaPlaylistURL(inMaster: master, baseURL: startURL) else {
            return Result(outcome: .playlistUnavailable, elapsedSeconds: elapsed(), polls: 0)
        }
        guard let child = await fetchPlaylist(childURL, headers: headers, timeout: remaining()) else {
            return Result(outcome: .playlistUnavailable, elapsedSeconds: elapsed(), polls: 0)
        }
        let headerURL = mapURI(inChild: child, baseURL: childURL)
        let segmentURL = firstSegmentURL(inChild: child, baseURL: childURL)
        guard headerURL != nil || segmentURL != nil else {
            return Result(outcome: .playlistUnavailable, elapsedSeconds: elapsed(), polls: 0)
        }

        var polls = 0
        // Header first (small; written as soon as the transcoder starts), then confirm the
        // first media segment has begun to exist (first byte only — segments are huge).
        var targets: [(URL, Bool)] = []
        if let headerURL { targets.append((headerURL, true)) }   // fetch fully (tiny)
        if let segmentURL { targets.append((segmentURL, false)) } // first byte only
        for (url, fully) in targets {
            var served = false
            while remaining() > 0, !Task.isCancelled {
                polls += 1
                if await probeServed(url, headers: headers, fully: fully, timeout: remaining()) {
                    served = true
                    break
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
            if Task.isCancelled {
                return Result(outcome: .cancelled, elapsedSeconds: elapsed(), polls: polls)
            }
            if !served {
                return Result(outcome: .timedOut, elapsedSeconds: elapsed(), polls: polls)
            }
        }
        return Result(outcome: .ready, elapsedSeconds: elapsed(), polls: polls)
    }

    // MARK: - Playlist parsing (line-oriented; PMS output is simple)

    static func firstMediaPlaylistURL(inMaster playlist: String, baseURL: URL) -> URL? {
        for line in playlist.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            return URL(string: trimmed, relativeTo: baseURL)?.absoluteURL
        }
        return nil
    }

    static func mapURI(inChild playlist: String, baseURL: URL) -> URL? {
        for line in playlist.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("#EXT-X-MAP:") else { continue }
            guard let range = line.range(of: "URI=\"") else { continue }
            let rest = line[range.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { continue }
            return URL(string: String(rest[..<end]), relativeTo: baseURL)?.absoluteURL
        }
        return nil
    }

    static func firstSegmentURL(inChild playlist: String, baseURL: URL) -> URL? {
        for line in playlist.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            return URL(string: trimmed, relativeTo: baseURL)?.absoluteURL
        }
        return nil
    }

    // MARK: - Transport

    private static func request(_ url: URL, headers: [String: String], timeout: Double) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = max(2, min(timeout, 30))
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        return request
    }

    private static func fetchPlaylist(_ url: URL, headers: [String: String], timeout: Double) async -> String? {
        guard timeout > 0 else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(for: request(url, headers: headers, timeout: timeout))
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    /// True once the server serves the resource. `fully: false` reads only the first byte
    /// (session segments are tens of MB) — a served first byte is the signal AVPlayer's
    /// "no response" deadline needs.
    private static func probeServed(_ url: URL, headers: [String: String], fully: Bool, timeout: Double) async -> Bool {
        guard timeout > 0 else { return false }
        do {
            if fully {
                let (_, response) = try await URLSession.shared.data(for: request(url, headers: headers, timeout: timeout))
                return (response as? HTTPURLResponse)?.statusCode == 200
            }
            let (bytes, response) = try await URLSession.shared.bytes(for: request(url, headers: headers, timeout: timeout))
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return false }
            for try await _ in bytes { return true } // first byte is enough; dropping the sequence cancels the task
            return false
        } catch {
            return false
        }
    }
}
