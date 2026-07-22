import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import PMSKit

/// Opt-in, GET-only live proof for #238. Output is deliberately shape-only: no host, token, user,
/// item/media-source id, title, filename, URL, response body, or raw authenticated payload is logged.
@Suite(.serialized)
struct LiveEmbyTrickPlayProbeTests {
    private struct Config {
        let server: URL
        let token: String
        let userId: String
        let itemId: String
        let requestedMediaSourceId: String?
        let identity: EmbyClientIdentity

        init?() {
            let env = ProcessInfo.processInfo.environment
            guard let rawServer = env["EMBY_LIVE_SERVER"],
                  let server = try? EmbyServerURL.normalized(rawServer),
                  let token = env["EMBY_LIVE_TOKEN"], !token.isEmpty,
                  let userId = env["EMBY_LIVE_USER_ID"], !userId.isEmpty,
                  let itemId = env["EMBY_LIVE_ITEM_ID"], !itemId.isEmpty else { return nil }
            self.server = server
            self.token = token
            self.userId = userId
            self.itemId = itemId
            self.requestedMediaSourceId = env["EMBY_LIVE_MEDIA_SOURCE_ID"]?.nilIfEmpty
            self.identity = EmbyClientIdentity(
                client: "Labstream", device: "Headless read-only probe",
                deviceId: env["EMBY_LIVE_DEVICE_ID"] ?? "labstream-emby-trickplay-probe",
                version: "0.1.0")
        }
    }

    private struct ResponseShape {
        let data: Data
        let status: Int
        let mimeType: String?
    }

    @Test func liveReadOnlyEmbyTrickPlayShapes() async throws {
        guard let config = Config() else {
            print(">>> EMBY-TRICKPLAY VERDICT: SKIP — configure the ignored Emby live env file.")
            return
        }

        let itemRequest = try EmbyLibrary.itemRequest(
            server: config.server, token: config.token, identity: config.identity,
            userId: config.userId, itemId: config.itemId)
        let itemResponse = try await send(itemRequest)
        guard itemResponse.status == 200 else {
            print(">>> EMBY-TRICKPLAY VERDICT: FAIL — authenticated item metadata HTTP \(itemResponse.status).")
            Issue.record("read-only Emby item metadata request was not accepted")
            return
        }
        let item = try JSONDecoder().decode(EmbyBaseItemDto.self, from: itemResponse.data)
        let sourceIDs = item.mediaSources.compactMap(\.id).filter { !$0.isEmpty }
        let mediaSourceId: String?
        if let requested = config.requestedMediaSourceId {
            guard sourceIDs.contains(requested) else {
                print(">>> EMBY-TRICKPLAY VERDICT: FAIL — configured media source is not exposed by the item.")
                Issue.record("configured Emby trick-play media source was not present")
                return
            }
            mediaSourceId = requested
        } else {
            mediaSourceId = sourceIDs.first
        }
        guard let mediaSourceId else {
            print(">>> EMBY-TRICKPLAY VERDICT: SKIP — configured item exposes no selectable media source.")
            return
        }
        print(">>> EMBY-TRICKPLAY [source] selected_source_present=true source_count=\(sourceIDs.count)")

        let setRequest = try EmbyTrickPlayRequest.thumbnailSet(
            server: config.server, token: config.token, identity: config.identity,
            userId: config.userId, itemId: config.itemId,
            mediaSourceId: mediaSourceId)
        let setResponse = try await send(setRequest)
        print(">>> EMBY-TRICKPLAY [ThumbnailSet] HTTP \(setResponse.status) mime=\(safeMime(setResponse.mimeType))")

        var thumbnailSet: EmbyThumbnailSetInfo?
        if setResponse.status == 200 {
            do {
                thumbnailSet = try EmbyThumbnailSetInfo.decode(from: setResponse.data)
                print(">>> EMBY-TRICKPLAY [ThumbnailSet] decoded=true frame_count=\(thumbnailSet?.thumbnails.count ?? 0) availability=\(thumbnailSet?.thumbnails.isEmpty == false ? "generated" : "empty")")
            } catch {
                print(">>> EMBY-TRICKPLAY [ThumbnailSet] decoded=false response_bytes=\(setResponse.data.count)")
            }
        } else {
            print(">>> EMBY-TRICKPLAY [ThumbnailSet] availability=unavailable fallback=chapters")
        }

        if let frame = thumbnailSet?.thumbnails.first {
            let imageRequest = try EmbyTrickPlayRequest.thumbnailImage(
                server: config.server, token: config.token, identity: config.identity,
                userId: config.userId, itemId: config.itemId,
                mediaSourceId: mediaSourceId, thumbnail: frame)
            let imageResponse = try await send(imageRequest)
            let imageShape = imageResponse.data.startsWithJPEG || imageResponse.data.startsWithPNG
            print(">>> EMBY-TRICKPLAY [Thumbnail] HTTP \(imageResponse.status) mime=\(safeMime(imageResponse.mimeType)) image_shape=\(imageShape) response_bytes=\(imageResponse.data.count)")
        } else {
            print(">>> EMBY-TRICKPLAY [Thumbnail] SKIP — no advertised position; chapter fallback shape retained.")
        }

        let bifRequest = try EmbyTrickPlayRequest.bifIndex(
            server: config.server, token: config.token, identity: config.identity,
            userId: config.userId, itemId: config.itemId,
            mediaSourceId: mediaSourceId)
        let bifResponse = try await send(bifRequest)
        if bifResponse.status == 200 {
            do {
                let index = try BIFParser.parse(bifResponse.data)
                print(">>> EMBY-TRICKPLAY [index.bif] HTTP 200 parseable=true frame_count=\(index.frameCount) response_bytes=\(bifResponse.data.count)")
            } catch {
                print(">>> EMBY-TRICKPLAY [index.bif] HTTP 200 parseable=false response_bytes=\(bifResponse.data.count) fallback=per_position")
            }
        } else {
            print(">>> EMBY-TRICKPLAY [index.bif] HTTP \(bifResponse.status) parseable=false fallback=\(thumbnailSet?.thumbnails.isEmpty == false ? "per_position" : "chapters")")
        }

        let generated = thumbnailSet?.thumbnails.isEmpty == false
        print(">>> EMBY-TRICKPLAY VERDICT: PASS — read-only authenticated shapes observed; generated_previews=\(generated).")
    }

    private func send(_ request: URLRequest) async throws -> ResponseShape {
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        return ResponseShape(data: data, status: http?.statusCode ?? -1, mimeType: http?.mimeType)
    }

    private func safeMime(_ mime: String?) -> String {
        guard let mime, mime.range(of: #"^[A-Za-z0-9.+-]+/[A-Za-z0-9.+-]+$"#,
                                   options: .regularExpression) != nil else { return "unknown" }
        return mime
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private extension Data {
    var startsWithJPEG: Bool { starts(with: [0xFF, 0xD8, 0xFF]) }
    var startsWithPNG: Bool { starts(with: [0x89, 0x50, 0x4E, 0x47]) }
}
