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

        public init(quality: String, profile: String, bitrate: Int?) {
            self.quality = quality
            self.profile = profile
            self.bitrate = bitrate
        }
    }

    /// Keep-quality stand-in bitrate for "Original video quality". The `originalmediafolder` target
    /// rejects the literal `quality:"original"` token (HTTP 500), so we send a high custom bitrate
    /// that preserves quality instead. Live-verified that arbitrary high bitrates are honored.
    public static let keepQualityBitrate = 80_000_000

    /// Map a download-picker preset label to an Emby convert `(quality, profile, bitrate)`.
    ///
    /// - "Original video quality" → `keepQualityBitrate` (80 Mbps) + `profile:"tv"`
    ///   (the literal `"original"` token 500s on `originalmediafolder`).
    /// - A bitrate preset (e.g. "4K 40 Mbps", "1080p 8 Mbps", "480p 1.5 Mbps") →
    ///   `quality:"custom"`, `bitrate:<its true bps>`, `profile:"tv"` (no cap — Emby honors it).
    /// - Unrecognized label → falls back to `keepQualityBitrate` (custom/tv).
    public static func convertQuality(forPresetLabel label: String) -> ConvertQuality {
        let normalized = label.lowercased()

        // "Original video quality" — never the literal "original" token (500s on this target).
        if normalized.contains("original") {
            return ConvertQuality(quality: "custom", profile: "tv", bitrate: keepQualityBitrate)
        }

        if let bps = bitrate(forPresetLabel: normalized) {
            return ConvertQuality(quality: "custom", profile: "tv", bitrate: bps)
        }

        // Unknown preset → keep-quality fallback.
        return ConvertQuality(quality: "custom", profile: "tv", bitrate: keepQualityBitrate)
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
    /// (PascalCase returns HTTP 500). Standard Emby auth via `EmbyAuth.applyAuth`.
    public static func createJobRequest(server: URL,
                                        token: String,
                                        identity: EmbyClientIdentity,
                                        userId: String,
                                        itemId: String,
                                        quality: String,
                                        profile: String,
                                        bitrate: Int?,
                                        name: String) throws -> URLRequest {
        let url = try EmbyPlayback.embyURL(server: server, path: "/Sync/Jobs")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        EmbyAuth.applyAuth(to: &req, identity: identity, userId: userId, token: token)

        let body: [String: Any] = [
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

    /// Decode a `GET /Sync/Jobs/{id}` (or create) response body into an `EmbyConvertJob`.
    public static func decodeJob(from data: Data) throws -> EmbyConvertJob {
        try JSONDecoder().decode(EmbyConvertJob.self, from: data)
    }
}
