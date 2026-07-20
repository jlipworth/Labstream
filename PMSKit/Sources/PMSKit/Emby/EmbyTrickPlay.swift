import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One server-extracted Emby preview frame advertised by `ThumbnailSet`.
public struct EmbyThumbnailInfo: Decodable, Sendable, Equatable {
    public let positionTicks: Int64
    public let imageTag: String

    enum CodingKeys: String, CodingKey {
        case positionTicks = "PositionTicks"
        case imageTag = "ImageTag"
    }

    public init(positionTicks: Int64, imageTag: String) {
        self.positionTicks = max(0, positionTicks)
        self.imageTag = imageTag
    }

    public var timeMs: Int {
        let milliseconds = positionTicks / 10_000
        return milliseconds > Int64(Int.max) ? Int.max : Int(milliseconds)
    }
}

/// Read-only availability response from Emby's BifService.
public struct EmbyThumbnailSetInfo: Decodable, Sendable, Equatable {
    public let aspectRatio: Double?
    public let thumbnails: [EmbyThumbnailInfo]

    enum CodingKeys: String, CodingKey {
        case aspectRatio = "AspectRatio"
        case thumbnails = "Thumbnails"
    }

    public init(aspectRatio: Double? = nil, thumbnails: [EmbyThumbnailInfo]) {
        self.aspectRatio = aspectRatio
        self.thumbnails = thumbnails
            .filter { !$0.imageTag.isEmpty }
            .sorted { $0.positionTicks < $1.positionTicks }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        aspectRatio = try container.decodeIfPresent(Double.self, forKey: .aspectRatio)
        thumbnails = try container.decodeIfPresent([EmbyThumbnailInfo].self, forKey: .thumbnails)?
            .filter { !$0.imageTag.isEmpty }
            .sorted { $0.positionTicks < $1.positionTicks } ?? []
    }

    public static func decode(from data: Data) throws -> EmbyThumbnailSetInfo {
        try JSONDecoder().decode(Self.self, from: data)
    }

    /// The frame whose capture begins at or before the target, matching chapter fallback selection.
    public func thumbnail(nearMs targetMs: Int) -> EmbyThumbnailInfo? {
        guard let index = SparseTrickPlayFrameSelectionPolicy.frameIndex(
            nearMs: targetMs,
            sortedFrameTimesMs: thumbnails.map(\.timeMs)
        ) else { return nil }
        return thumbnails[index]
    }
}

/// Authenticated, playback-passive Emby trick-play requests. These endpoints read generated
/// preview assets only; they do not mint a PlaybackInfo session or touch an active encoder.
public enum EmbyTrickPlayRequest {
    public static let canonicalWidth = 320

    /// `GET /Items/{Id}/ThumbnailSet?Width=…&MediaSourceId=…`
    public static func thumbnailSet(server: URL,
                                    token: String,
                                    identity: EmbyClientIdentity,
                                    userId: String?,
                                    itemId: String,
                                    mediaSourceId: String,
                                    width: Int = canonicalWidth) throws -> URLRequest {
        let url = try endpoint(
            server: server,
            path: "/Items/\(itemId)/ThumbnailSet",
            queryItems: [
                URLQueryItem(name: "Width", value: String(max(1, width))),
                URLQueryItem(name: "MediaSourceId", value: mediaSourceId),
            ]
        )
        var request = EmbyLibrary.authenticatedRequest(
            url: url, token: token, identity: identity, userId: userId)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// `GET /Items/{Id}/Images/Thumbnail?tag=…&PositionTicks=…&MediaSourceId=…&maxWidth=…`
    public static func thumbnailImage(server: URL,
                                      token: String,
                                      identity: EmbyClientIdentity,
                                      userId: String?,
                                      itemId: String,
                                      mediaSourceId: String,
                                      thumbnail: EmbyThumbnailInfo,
                                      width: Int = canonicalWidth) throws -> URLRequest {
        let url = try endpoint(
            server: server,
            path: "/Items/\(itemId)/Images/Thumbnail",
            queryItems: [
                URLQueryItem(name: "tag", value: thumbnail.imageTag),
                URLQueryItem(name: "PositionTicks", value: String(thumbnail.positionTicks)),
                URLQueryItem(name: "MediaSourceId", value: mediaSourceId),
                URLQueryItem(name: "maxWidth", value: String(max(1, width))),
            ]
        )
        var request = EmbyLibrary.authenticatedRequest(
            url: url, token: token, identity: identity, userId: userId)
        request.httpMethod = "GET"
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        return request
    }

    /// `GET /Videos/{Id}/index.bif?Width=…&MediaSourceId=…`
    ///
    /// Emby versions differ in whether BifService documents `MediaSourceId` on this route. Send the
    /// selected source explicitly; supporting servers bind the asset, while unsupported/invalid
    /// responses fail closed into the per-position provider rather than selecting another source.
    public static func bifIndex(server: URL,
                                token: String,
                                identity: EmbyClientIdentity,
                                userId: String?,
                                itemId: String,
                                mediaSourceId: String,
                                width: Int = canonicalWidth) throws -> URLRequest {
        let url = try endpoint(
            server: server,
            path: "/Videos/\(itemId)/index.bif",
            queryItems: [
                URLQueryItem(name: "Width", value: String(max(1, width))),
                URLQueryItem(name: "MediaSourceId", value: mediaSourceId),
            ]
        )
        var request = EmbyLibrary.authenticatedRequest(
            url: url, token: token, identity: identity, userId: userId)
        request.httpMethod = "GET"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        return request
    }

    private static func endpoint(server: URL,
                                 path: String,
                                 queryItems: [URLQueryItem]) throws -> URL {
        try EmbyPlayback.embyURL(server: server, path: path, queryItems: queryItems)
    }
}
