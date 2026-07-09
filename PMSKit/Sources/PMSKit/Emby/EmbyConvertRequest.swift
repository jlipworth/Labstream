import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Status of an Emby "Convert Media" Sync job (`GET /Sync/Jobs/{id}` → `Status`).
///
/// The observed server strings (Emby 4.9.3) are `Queued` → `Converting`/`Transferring` →
/// `Completed` / `Failed` / `Cancelled`. An unrecognized/absent string decodes to `.unknown`
/// rather than throwing, so a forward-incompatible server value never crashes polling — it is
/// simply treated as non-terminal (keep polling).
public enum EmbyConvertJobStatus: String, Decodable, Sendable, Equatable {
    case queued = "Queued"
    case converting = "Converting"
    case transferring = "Transferring"
    case completed = "Completed"
    case failed = "Failed"
    case cancelled = "Cancelled"
    /// Any server string we don't recognize (forward-compat). Never terminal.
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = EmbyConvertJobStatus(rawValue: raw) ?? .unknown
    }

    /// True once the job has reached a final state (success OR failure/cancel) — stop polling.
    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            return true
        case .queued, .converting, .transferring, .unknown:
            return false
        }
    }

    /// True only when the job finished and produced the converted file.
    public var didSucceed: Bool {
        self == .completed
    }
}

/// A single Emby Convert-Media Sync job (`POST /Sync/Jobs` result / `GET /Sync/Jobs/{id}`).
///
/// `progress` is a 0–100 percentage (`null` until the job starts converting). All fixtures /
/// callers use placeholder ids (repo goes public).
public struct EmbyConvertJob: Decodable, Sendable, Equatable {
    public let id: Int
    public let status: EmbyConvertJobStatus
    public let progress: Double?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case status = "Status"
        case progress = "Progress"
    }

    public init(id: Int, status: EmbyConvertJobStatus, progress: Double?) {
        self.id = id
        self.status = status
        self.progress = progress
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        status = try c.decodeIfPresent(EmbyConvertJobStatus.self, forKey: .status) ?? .unknown
        progress = try c.decodeIfPresent(Double.self, forKey: .progress)
    }
}

/// Pure request builders + response models for the Emby "Convert Media" Sync job lane (the
/// server-side prepare-then-download path). Mirrors the existing `EmbyPlayback` request style:
/// auth via `EmbyAuth.applyAuth`, base-path-preserving URL join via `EmbyPlayback.embyURL`.
///
/// Verified live (Emby 4.9.3): `POST /Sync/Jobs` body keys are **lowercase camelCase**
/// (PascalCase returns HTTP 500); `targetId:"originalmediafolder"` = persistent "next to
/// original files" (NEVER `originalmediafolderreplace`, which is destructive).
public enum EmbyConvertRequest {
    /// Picker-preset → Emby convert (`quality`, `profile`, `bitrate`) mapping.
    ///
    /// The `originalmediafolder` target rejects the literal `quality:"original"` token (HTTP 500),
    /// so "Original video quality" maps to a high keep-quality bitrate (`keepQualityBitrate`) with
    /// `profile:"tv"` — NOT `"original"`. Bitrate presets map to `quality:"custom"` +
    /// `bitrate:<bps>` + `profile:"tv"`. Live-verified (Emby 4.9.3): the target honors arbitrary
    /// custom bitrates (40 Mbps accepted + actively transcoding), so there is NO 8 Mbps cap.
    public struct ConvertQuality: Sendable, Equatable {
        public let quality: String
        public let profile: String
        public let bitrate: Int?
        /// Custom-profile target criteria (#128). Non-nil ONLY for `profile:"custom"`: Emby's
        /// "Convert → Custom" path REQUIRES `Container`/`VideoCodec`/`AudioCodec` (a bare custom job is
        /// rejected HTTP 400) and, unlike `tv`, applies no 1080p downscale — so this is the true-4K lane.
        public let container: String?
        public let videoCodec: String?
        public let audioCodec: String?

        public init(quality: String, profile: String, bitrate: Int?,
                    container: String? = nil, videoCodec: String? = nil, audioCodec: String? = nil) {
            self.quality = quality
            self.profile = profile
            self.bitrate = bitrate
            self.container = container
            self.videoCodec = videoCodec
            self.audioCodec = audioCodec
        }
    }

    /// True-4K custom-profile criteria (#128). h264/mp4/aac: the convert lane only ever runs for
    /// sources that CAN'T direct-play, so a universally playable target codec is the safe pick.
    /// `profile:"custom"` preserves the source resolution (no `tv` downscale) → genuine 4K output.
    /// The codec/container triple is REQUIRED — Emby rejects a bare custom job with HTTP 400.
    public static func customFourKQuality(bitrate: Int) -> ConvertQuality {
        ConvertQuality(quality: "custom", profile: "custom", bitrate: bitrate,
                       container: "mp4", videoCodec: "h264", audioCodec: "aac")
    }

    /// Keep-quality stand-in bitrate for "Original video quality". The `originalmediafolder` target
    /// rejects the literal `quality:"original"` token (HTTP 500), so we send a high custom bitrate
    /// that preserves quality instead. Live-verified that arbitrary high bitrates are honored.
    public static let keepQualityBitrate = 80_000_000

    /// Map a download-picker preset label to an Emby convert `(quality, profile, bitrate[, criteria])`.
    ///
    /// Resolution-preserving presets route through `profile:"custom"` (the true-4K lane, #128); the
    /// rest keep `profile:"tv"` (whose 1080p ceiling is exactly what a sub-1080p preset wants):
    /// - "Original video quality" → `profile:"custom"` + mp4/h264/aac at `keepQualityBitrate` (80 Mbps).
    ///   Preserves the source resolution; `tv` would silently downscale a 4K "Original" to 1080p.
    /// - A 4K/2160 preset (e.g. "4K 40 Mbps") → `profile:"custom"` + mp4/h264/aac at its labelled bps.
    /// - A 1080p/720p/480p preset → `quality:"custom"`, `bitrate:<bps>`, `profile:"tv"` (the `tv`
    ///   ceiling delivers the requested downscale; no cap on bitrate — Emby honors it).
    /// - Unrecognized label → keep-quality fallback via the resolution-preserving custom path.
    public static func convertQuality(forPresetLabel label: String) -> ConvertQuality {
        let normalized = label.lowercased()

        // "Original video quality" — preserve the source resolution via custom (tv downscales 4K→1080p).
        if normalized.contains("original") {
            return customFourKQuality(bitrate: keepQualityBitrate)
        }

        if let bps = bitrate(forPresetLabel: normalized) {
            // 4K / 2160p presets need custom to escape the tv profile's 1080p ceiling (#128); the
            // lower tiers explicitly want a downscale, which tv already provides.
            if normalized.contains("4k") || normalized.contains("2160") {
                return customFourKQuality(bitrate: bps)
            }
            return ConvertQuality(quality: "custom", profile: "tv", bitrate: bps)
        }

        // Unknown preset → keep-quality fallback (resolution-preserving custom path).
        return customFourKQuality(bitrate: keepQualityBitrate)
    }

    /// Extract a bits-per-second value from a picker preset label (e.g. "4K · 40 Mbps" → 40_000_000,
    /// "1080p · 8 Mbps" → 8_000_000, "480p · 1.5 Mbps" → 1_500_000). NOT capped: the
    /// `originalmediafolder` target honors arbitrary custom bitrates (live-verified). Returns nil
    /// when no "<n> Mbps" token is present.
    static func bitrate(forPresetLabel normalizedLabel: String) -> Int? {
        // Find a "<number> mbps" token; the number may be fractional (e.g. 1.5).
        guard let mbpsRange = normalizedLabel.range(of: "mbps") else { return nil }

        // Pull the last numeric run that precedes "mbps".
        var lastNumber: Double?
        let prefix = String(normalizedLabel[..<mbpsRange.lowerBound])
        var current = ""
        for ch in prefix {
            if ch.isNumber || ch == "." {
                current.append(ch)
            } else if !current.isEmpty {
                lastNumber = Double(current) ?? lastNumber
                current = ""
            }
        }
        if !current.isEmpty { lastNumber = Double(current) ?? lastNumber }

        guard let mbps = lastNumber, mbps > 0 else { return nil }
        return Int((mbps * 1_000_000).rounded())
    }

    /// `POST {server}/Sync/Jobs` — create an Emby "Convert Media" job for `itemId` targeting
    /// `originalmediafolder` (persistent "next to original files"). Body is **lowercase camelCase**
    /// (the existing convention; live-verified that camelCase keys bind). Standard Emby auth via
    /// `EmbyAuth.applyAuth`.
    ///
    /// `container`/`videoCodec`/`audioCodec` are the `profile:"custom"` target criteria (#128) and
    /// MUST be supplied together for a custom job (Emby rejects a bare custom job HTTP 400); they are
    /// omitted entirely for the `tv`/`mobile` profiles, which carry their own built-in targets.
    /// `audioStreamIndex` is best-effort download-track steering for single-audio converted outputs.
    /// It follows Emby's lowercase-camel Sync job body convention used by the rest of this request.
    public static func createJobRequest(server: URL,
                                        token: String,
                                        identity: EmbyClientIdentity,
                                        userId: String,
                                        itemId: String,
                                        quality: String,
                                        profile: String,
                                        bitrate: Int?,
                                        name: String,
                                        container: String? = nil,
                                        videoCodec: String? = nil,
                                        audioCodec: String? = nil,
                                        audioStreamIndex: Int? = nil) throws -> URLRequest {
        let url = try EmbyPlayback.embyURL(server: server, path: "/Sync/Jobs")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        EmbyAuth.applyAuth(to: &req, identity: identity, userId: userId, token: token)

        var body: [String: Any] = [
            "userId": userId,
            "itemIds": [itemId],
            "category": NSNull(),
            "parentId": NSNull(),
            "targetId": "originalmediafolder",
            "quality": quality,
            "profile": profile,
            "bitrate": bitrate.map { $0 as Any } ?? NSNull(),
            "name": name,
            "unwatchedOnly": false,
            "syncNewContent": false,
            "itemLimit": NSNull(),
        ]
        // Custom-profile criteria (#128) — only present for the true-4K path.
        if let container { body["container"] = container }
        if let videoCodec { body["videoCodec"] = videoCodec }
        if let audioCodec { body["audioCodec"] = audioCodec }
        if let audioStreamIndex, audioStreamIndex >= 0 { body["audioStreamIndex"] = audioStreamIndex }
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return req
    }

    /// `GET {server}/Sync/Jobs/{jobId}` — poll a convert job's `Status`/`Progress`.
    public static func jobStatusRequest(server: URL,
                                        token: String,
                                        identity: EmbyClientIdentity,
                                        jobId: Int) throws -> URLRequest {
        let url = try EmbyPlayback.embyURL(server: server, path: "/Sync/Jobs/\(jobId)")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        EmbyAuth.applyAuth(to: &req, identity: identity, userId: nil, token: token)
        return req
    }

    /// `DELETE {server}/Sync/Jobs/{jobId}` — cancel a job the user abandons. Deleting the job does
    /// NOT delete the already-converted file (verified live), so this only ever cancels an
    /// in-flight conversion; never call it on success.
    public static func deleteJobRequest(server: URL,
                                        token: String,
                                        identity: EmbyClientIdentity,
                                        jobId: Int) throws -> URLRequest {
        let url = try EmbyPlayback.embyURL(server: server, path: "/Sync/Jobs/\(jobId)")
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        EmbyAuth.applyAuth(to: &req, identity: identity, userId: nil, token: token)
        return req
    }

    /// `POST {server}/Items/{itemId}/Refresh` — ask Emby to rescan/re-index one item after a
    /// convert job copied a persistent file next to the original. Emby can finish the Sync job and
    /// place the MP4 on disk before PlaybackInfo exposes it as a second `File` MediaSource; a
    /// targeted refresh is the same shape the web client uses and returns HTTP 204 on success.
    public static func itemRefreshRequest(server: URL,
                                          token: String,
                                          identity: EmbyClientIdentity,
                                          userId: String,
                                          itemId: String) throws -> URLRequest {
        var comps = URLComponents(url: try EmbyPlayback.embyURL(server: server, path: "/Items/\(itemId)/Refresh"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "MetadataRefreshMode", value: "Default"),
            URLQueryItem(name: "ImageRefreshMode", value: "Default"),
            URLQueryItem(name: "ReplaceAllMetadata", value: "false"),
            URLQueryItem(name: "ReplaceAllImages", value: "false"),
        ]
        guard let url = comps.url else { throw EmbyPlaybackError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        EmbyAuth.applyAuth(to: &req, identity: identity, userId: userId, token: token)
        return req
    }

    /// Decode a `GET /Sync/Jobs/{id}` (single-job poll) response body into an `EmbyConvertJob`.
    ///
    /// The single-job GET returns the job at the TOP LEVEL (`{ "Id", "Status", "Progress", … }`),
    /// so `EmbyConvertJob` decodes it directly. The `POST /Sync/Jobs` CREATE response is a different
    /// shape — use `decodeCreatedJob(from:)` for that.
    public static func decodeJob(from data: Data) throws -> EmbyConvertJob {
        try JSONDecoder().decode(EmbyConvertJob.self, from: data)
    }

    /// Decode a `POST /Sync/Jobs` (create) response body into the created `EmbyConvertJob`.
    ///
    /// Verified live (Emby 4.9.3): unlike the single-job GET, the create response is a
    /// `SyncJobCreationResult` envelope that NESTS the job under `"Job"`:
    /// `{ "Job": { "Id", "Status", "Progress", … }, "JobItems": [] }`. Decoding it as a bare
    /// `EmbyConvertJob` throws `keyNotFound("Id")` because `"Id"` is not at the top level — that
    /// was the create-phase crash. This unwraps `"Job"` and returns it.
    public static func decodeCreatedJob(from data: Data) throws -> EmbyConvertJob {
        try JSONDecoder().decode(EmbyConvertJobCreationResult.self, from: data).job
    }
}

/// The `POST /Sync/Jobs` create-response envelope (`SyncJobCreationResult`): the created job is
/// nested under `"Job"` (verified live, Emby 4.9.3), distinct from the top-level shape the
/// single-job `GET /Sync/Jobs/{id}` returns. `JobItems` is intentionally ignored.
private struct EmbyConvertJobCreationResult: Decodable {
    let job: EmbyConvertJob
    enum CodingKeys: String, CodingKey {
        case job = "Job"
    }
}
