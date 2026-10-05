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
///  - `HLSSessionPrewarmer`: fetch master + child playlist (which starts the transcoder) and
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
enum HLSSessionPrewarmer {
    /// Privacy-bounded observations: never retain request URLs, bodies, or error descriptions.
    struct Observation: Sendable {
        enum Phase: String, Sendable { case master, child, `init`, segment }
        enum PlaylistKind: String, Sendable { case master, media, unknown }
        let phase: Phase
        let elapsedMS: Int
        let httpStatus: Int?
        let urlErrorCode: Int?
        let success: Bool
        let startTimeTicksPresent: Bool
        let playlistKind: PlaylistKind?
        let ordinaryURIsWithStartTimeTicks: Int?
        let quotedURIsWithStartTimeTicks: Int?
        let timeline: TimelineTopology?
    }

    struct TimelineTopology: Sendable {
        enum SegmentExtension: String, Sendable { case ts, m4s, mp4, other }
        let mediaSequence: Int?
        let segmentCount: Int
        let totalDurationMS: Int?
        let startOffsetMS: Int?
        let endList: Bool
        let firstSegmentExtension: SegmentExtension?
        let firstSegmentOrdinal: Int?
    }

    /// Only timeline numbers and allowlisted format labels survive parsing.
    static func playlistTimeline(_ playlist: String) -> TimelineTopology {
        var sequence: Int?
        var count = 0
        var total: Double = 0
        var validDurations = true
        var start: Int?
        var endList = false
        var awaitsSegment = false
        var firstExtension: TimelineTopology.SegmentExtension?
        var firstOrdinal: Int?
        func milliseconds(_ seconds: Double) -> Int? {
            let value = (seconds * 1000).rounded()
            guard value.isFinite, value >= Double(Int.min), value < Double(Int.max) else { return nil }
            return Int(value)
        }
        for line in playlist.split(whereSeparator: \.isNewline) {
            let raw = line.trimmingCharacters(in: .whitespaces)
            if raw.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                let value = raw.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)
                if let parsed = Int(value), parsed >= 0 { sequence = parsed }
            } else if raw.hasPrefix("#EXTINF:") {
                count += 1
                awaitsSegment = true
                let value = raw.dropFirst("#EXTINF:".count).split(separator: ",", omittingEmptySubsequences: false).first ?? ""
                if let duration = Double(value), duration.isFinite, duration >= 0 {
                    total += duration
                } else { validDurations = false }
            } else if raw.hasPrefix("#EXT-X-START:") {
                for attribute in raw.dropFirst("#EXT-X-START:".count).split(separator: ",") {
                    let parts = attribute.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
                    if parts.count == 2, parts[0] == "TIME-OFFSET", let seconds = Double(parts[1]) {
                        start = milliseconds(seconds)
                    }
                }
            } else if raw == "#EXT-X-ENDLIST" {
                endList = true
            } else if !raw.isEmpty, !raw.hasPrefix("#"), awaitsSegment {
                awaitsSegment = false
                if firstExtension == nil {
                    let path = URLComponents(string: raw)?.path ?? ""
                    let component = (path as NSString).lastPathComponent
                    let ext = (component as NSString).pathExtension.lowercased()
                    firstExtension = TimelineTopology.SegmentExtension(rawValue: ext) ?? .other
                    let basename = (component as NSString).deletingPathExtension
                    if !basename.isEmpty, basename.utf8.allSatisfy({ (48...57).contains($0) }) {
                        firstOrdinal = Int(basename)
                    }
                }
            }
        }
        return TimelineTopology(mediaSequence: sequence, segmentCount: count,
            totalDurationMS: validDurations ? milliseconds(total) : nil,
            startOffsetMS: start, endList: endList,
            firstSegmentExtension: firstExtension, firstSegmentOrdinal: firstOrdinal)
    }

    static func hasStartTimeTicks(_ uri: String) -> Bool {
        URLComponents(string: uri)?.queryItems?.contains {
            $0.name.caseInsensitiveCompare("StartTimeTicks") == .orderedSame
        } == true
    }

    static func playlistTopology(_ playlist: String) -> (kind: Observation.PlaylistKind, ordinary: Int, quoted: Int) {
        var ordinary = 0
        var quoted = 0
        for line in playlist.split(whereSeparator: \.isNewline) {
            let raw = line.trimmingCharacters(in: .whitespaces)
            if !raw.hasPrefix("#") {
                if hasStartTimeTicks(raw) { ordinary += 1 }
            } else {
                var remaining = raw[...]
                while let marker = remaining.range(of: "URI=\"") {
                    remaining = remaining[marker.upperBound...]
                    guard let end = remaining.firstIndex(of: "\"") else { break }
                    if hasStartTimeTicks(String(remaining[..<end])) { quoted += 1 }
                    remaining = remaining[remaining.index(after: end)...]
                }
            }
        }
        let kind: Observation.PlaylistKind = playlist.contains("#EXT-X-STREAM-INF:") ? .master
            : playlist.contains("#EXTINF:") ? .media : .unknown
        return (kind, ordinary, quoted)
    }

    private static func observation(phase: Observation.Phase, started: ContinuousClock.Instant,
                                    url: URL, status: Int?, error: Int?, success: Bool,
                                    playlist: String? = nil) -> Observation {
        let duration = started.duration(to: .now).components
        let topology = playlist.map(playlistTopology)
        return Observation(phase: phase,
                           elapsedMS: Int(duration.seconds * 1000 + duration.attoseconds / 1_000_000_000_000_000),
                           httpStatus: status, urlErrorCode: error, success: success,
                           startTimeTicksPresent: hasStartTimeTicks(url.absoluteString),
                           playlistKind: topology?.kind,
                           ordinaryURIsWithStartTimeTicks: topology?.ordinary,
                           quotedURIsWithStartTimeTicks: topology?.quoted,
                           timeline: playlist.map(playlistTimeline))
    }

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
                        budgetSeconds: Double = 20,
                        observe: (@Sendable (Observation) -> Void)? = nil) async -> Result {
        let clock = ContinuousClock.now
        func elapsed() -> Double {
            Double(clock.duration(to: .now).components.seconds)
                + Double(clock.duration(to: .now).components.attoseconds) / 1e18
        }
        func remaining() -> Double { budgetSeconds - elapsed() }

        guard let master = await fetchPlaylist(startURL, headers: headers, timeout: remaining(), phase: .master, observe: observe),
              let childURL = firstMediaPlaylistURL(inMaster: master, baseURL: startURL) else {
            return Result(outcome: .playlistUnavailable, elapsedSeconds: elapsed(), polls: 0)
        }
        guard let child = await fetchPlaylist(childURL, headers: headers, timeout: remaining(), phase: .child, observe: observe) else {
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
                if await probeServed(url, headers: headers, fully: fully, timeout: remaining(),
                                     phase: fully ? .`init` : .segment, observe: observe) {
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

    private static func fetchPlaylist(_ url: URL, headers: [String: String], timeout: Double,
                                      phase: Observation.Phase,
                                      observe: (@Sendable (Observation) -> Void)?) async -> String? {
        guard timeout > 0 else { return nil }
        let started = ContinuousClock.now
        var status: Int?
        var errorCode: Int?
        var playlist: String?
        defer { observe?(observation(phase: phase, started: started, url: url, status: status,
                                    error: errorCode, success: playlist != nil, playlist: playlist)) }
        do {
            let (data, response) = try await URLSession.shared.data(for: request(url, headers: headers, timeout: timeout))
            status = (response as? HTTPURLResponse)?.statusCode
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            playlist = String(data: data, encoding: .utf8)
            return playlist
        } catch {
            errorCode = (error as? URLError)?.code.rawValue
            return nil
        }
    }

    /// True once the server serves the resource. `fully: false` reads only the first byte
    /// (session segments are tens of MB) — a served first byte is the signal AVPlayer's
    /// "no response" deadline needs.
    private static func probeServed(_ url: URL, headers: [String: String], fully: Bool, timeout: Double,
                                    phase: Observation.Phase,
                                    observe: (@Sendable (Observation) -> Void)?) async -> Bool {
        guard timeout > 0 else { return false }
        let started = ContinuousClock.now
        var status: Int?
        var errorCode: Int?
        var success = false
        defer { observe?(observation(phase: phase, started: started, url: url, status: status,
                                    error: errorCode, success: success)) }
        do {
            if fully {
                let (_, response) = try await URLSession.shared.data(for: request(url, headers: headers, timeout: timeout))
                status = (response as? HTTPURLResponse)?.statusCode
                success = status == 200
                return success
            }
            let (bytes, response) = try await URLSession.shared.bytes(for: request(url, headers: headers, timeout: timeout))
            status = (response as? HTTPURLResponse)?.statusCode
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return false }
            for try await _ in bytes { success = true; return true } // first byte is enough; dropping the sequence cancels the task
            return false
        } catch {
            errorCode = (error as? URLError)?.code.rawValue
            return false
        }
    }
}
