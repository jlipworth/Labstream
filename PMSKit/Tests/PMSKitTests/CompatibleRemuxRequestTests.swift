import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import PMSKit

// Request-shape tests for the #83 "Original quality (compatible)" remux download lane.

@Suite("Compatible-remux download requests")
struct CompatibleRemuxRequestTests {
    private let jfServer = URL(string: "https://jellyfin.example.test/base")!
    private let jfIdentity = JellyfinClientIdentity(client: "Labstream", device: "Apple Vision Pro",
                                                    deviceId: "device-123", version: "0.1.0")
    private let embyServer = URL(string: "https://emby.example.test")!
    private let embyIdentity = EmbyClientIdentity(client: "Labstream", device: "Apple Vision Pro",
                                                  deviceId: "device-123", version: "0.1.0")

    private func query(_ req: URLRequest) throws -> [String: String] {
        let url = try #require(req.url)
        let comps = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        return Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    @Test func jellyfinRemuxRequestEnablesVideoStreamCopyForHEVC() throws {
        let req = try JellyfinLibrary.compatibleRemuxDownloadRequest(
            server: jfServer, token: "tok", identity: jfIdentity,
            itemId: "item-1", mediaSourceId: "src-9",
            videoCodec: "hevc", copyAudio: false, playSessionId: "ps-1")
        let q = try query(req)

        #expect(try #require(req.url).path == "/base/Videos/item-1/stream.mp4")
        #expect(q["static"] == "false")
        #expect(q["container"] == "mp4")
        #expect(q["videoCodec"] == "hevc,h264")       // source codec listed first → server can copy
        #expect(q["audioCodec"] == "aac")             // no copy intent → plain AAC target
        #expect(q["maxAudioChannels"] == nil)         // no cap — it forced 5.1 downmixes of copyable 7.1
        #expect(q["allowVideoStreamCopy"] == "true")
        #expect(q["allowAudioStreamCopy"] == "false") // DTS-class source → transcode audio
        #expect(q["enableAutoStreamCopy"] == "true")
        #expect(q["mediaSourceId"] == "src-9")
        #expect(q["playSessionId"] == "ps-1")
        // token rides in the Authorization header, never the stored URL
        #expect(req.value(forHTTPHeaderField: "Authorization")?.contains("Token=\"tok\"") == true)
        #expect(!(req.url?.absoluteString.contains("tok") ?? true))
    }

    @Test func jellyfinRemuxRequestCopiesAudioWhenCompatible() throws {
        let req = try JellyfinLibrary.compatibleRemuxDownloadRequest(
            server: jfServer, token: "tok", identity: jfIdentity,
            itemId: "item-1", mediaSourceId: nil,
            videoCodec: "h264", audioCodec: "eac3", copyAudio: true)
        let q = try query(req)
        #expect(q["videoCodec"] == "h264")            // already h264 → no alias suffix
        // Source codec listed first — copy only engages when the source codec is in the
        // requested list (aac alone silently re-encoded ac3/eac3 to AAC).
        #expect(q["audioCodec"] == "eac3,aac")
        #expect(q["allowAudioStreamCopy"] == "true")
        #expect(q["mediaSourceId"] == nil)
    }

    @Test func jellyfinRemuxRequestKeepsPlainAACTargetWhenSourceCodecUnknown() throws {
        let req = try JellyfinLibrary.compatibleRemuxDownloadRequest(
            server: jfServer, token: "tok", identity: jfIdentity,
            itemId: "item-1", mediaSourceId: nil,
            videoCodec: "h264", audioCodec: nil, copyAudio: true)
        let q = try query(req)
        #expect(q["audioCodec"] == "aac")
    }

    @Test func embyRemuxRequestEnablesVideoStreamCopyAndCarriesPlaySession() throws {
        let req = try EmbyLibrary.compatibleRemuxDownloadRequest(
            server: embyServer, token: "tok", identity: embyIdentity, userId: "user-1",
            itemId: "item-1", mediaSourceId: "src-9", playSessionId: "ps-1",
            videoCodec: "hevc", audioCodec: "ac3", copyAudio: true, audioBitrate: 192_000)
        let q = try query(req)

        #expect(try #require(req.url).path == "/videos/item-1/stream.mp4")
        #expect(q["Static"] == "false")
        #expect(q["VideoCodec"] == "hevc,h264")
        #expect(q["AudioCodec"] == "ac3,aac")         // source codec listed first → server can copy
        #expect(q["AllowVideoStreamCopy"] == "true")
        #expect(q["AllowAudioStreamCopy"] == "true")
        #expect(q["EnableAutoStreamCopy"] == "true")
        #expect(q["PlaySessionId"] == "ps-1")          // required — Emby 400s without it
        #expect(q["MediaSourceId"] == "src-9")
        #expect(q["api_key"] == "tok")
        #expect(req.value(forHTTPHeaderField: "Authorization") != nil)
    }
}
