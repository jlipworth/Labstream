import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import PMSKit

/// GH #196 spike (a): experimental Dolby Vision advertising in the device profiles.
/// Default-off is a hard acceptance criterion — the shipping profiles must be unchanged.
@Suite("Device profile DV advertising (experimental)")
struct DeviceProfileDVTests {
    private let jfServer = URL(string: "https://jellyfin.example.test/base")!
    private let jfIdentity = JellyfinClientIdentity(client: "VisionPlay", device: "Apple Vision Pro",
                                                    deviceId: "device-123", version: "0.1.0")
    private let embyServer = URL(string: "https://emby.example.test/emby")!
    private let embyIdentity = EmbyClientIdentity(client: "VisionPlay", device: "Apple Vision Pro",
                                                  deviceId: "device-123", version: "0.1.0")

    @Test func plexProfilesOmitDVByDefault() {
        let streaming = DeviceProfile.visionOS(maxVideoBitrateKbps: 8000)
        let probe = DeviceProfile.visionOSDirectPlayProbe(maxVideoBitrateKbps: 8000)
        #expect(!streaming.clientProfileExtra.lowercased().contains("dvh"))
        #expect(!probe.clientProfileExtra.lowercased().contains("dvh"))
    }

    @Test func plexProfilesAdvertiseDVWhenEnabled() {
        let streaming = DeviceProfile.visionOS(maxVideoBitrateKbps: 8000, advertiseDolbyVision: true)
        let probe = DeviceProfile.visionOSDirectPlayProbe(maxVideoBitrateKbps: 8000,
                                                          advertiseDolbyVision: true)
        for extra in [streaming.clientProfileExtra, probe.clientProfileExtra] {
            #expect(extra.contains("dvh1"))
            #expect(extra.contains("dvhe"))
            // The DV additions ride the Extra; the base profile name stays Generic
            // (enforced at the request layer) and the existing targets stay present.
            #expect(extra.contains("add-transcode-target"))
        }
    }

    private func deviceProfileJSON(_ request: URLRequest) throws -> String {
        let data = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let profile = try #require(body["DeviceProfile"])
        let profileData = try JSONSerialization.data(withJSONObject: profile)
        return String(decoding: profileData, as: UTF8.self)
    }

    @Test func jellyfinProfileOmitsDVByDefault() throws {
        let req = try JellyfinPlayback.playbackInfoRequest(
            server: jfServer, token: "t", identity: jfIdentity,
            itemId: "m1", userId: "u1", maxStreamingBitrate: 8_000_000)
        let json = try deviceProfileJSON(req)
        #expect(!json.contains("DOVI"))
        #expect(!json.lowercased().contains("dvh"))
    }

    @Test func jellyfinProfileAdvertisesDVWhenEnabled() throws {
        let req = try JellyfinPlayback.playbackInfoRequest(
            server: jfServer, token: "t", identity: jfIdentity,
            itemId: "m1", userId: "u1", maxStreamingBitrate: 8_000_000,
            advertiseDolbyVision: true)
        let json = try deviceProfileJSON(req)
        // VideoRangeType condition is the signal Jellyfin uses to keep dvcC/RPUs on remux.
        #expect(json.contains("VideoRangeType"))
        #expect(json.contains("DOVIWithHDR10"))
    }

    @Test func embyProfileOmitsDVByDefault() throws {
        let req = try EmbyPlayback.playbackInfoRequest(
            server: embyServer, token: "t", identity: embyIdentity,
            userId: "u1", itemId: "m1", maxStreamingBitrate: 8_000_000)
        let json = try deviceProfileJSON(req)
        #expect(!json.contains("DOVI"))
        #expect(!json.lowercased().contains("dvh"))
    }

    @Test func embyProfileAdvertisesDVWhenEnabled() throws {
        let req = try EmbyPlayback.playbackInfoRequest(
            server: embyServer, token: "t", identity: embyIdentity,
            userId: "u1", itemId: "m1", maxStreamingBitrate: 8_000_000,
            advertiseDolbyVision: true)
        let json = try deviceProfileJSON(req)
        #expect(json.contains("VideoRangeType"))
        #expect(json.contains("DOVIWithHDR10"))
    }
}
