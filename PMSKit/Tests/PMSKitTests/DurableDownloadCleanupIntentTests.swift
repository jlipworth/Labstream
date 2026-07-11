import Foundation
import Testing
@testable import PMSKit

@Suite("Durable download cleanup intent")
struct DurableDownloadCleanupIntentTests {
    private let attempt = DownloadAttemptKey(
        ratingKey: "emby:item", attemptID: DownloadAttemptID(uuid: UUID(int: 1)))
    private let server = DurableDownloadCleanupIntent.ServerIdentity(
        baseURL: URL(string: "HTTPS://User:secret@Example.COM:443/emby/?api_key=secret#x")!,
        serverID: " server-1 ", userID: " user-1 ")!

    @Test func activeEncodingRoundTripsWithoutCredentials() throws {
        let value = DurableDownloadCleanupIntent(
            id: UUID(int: 2), attemptKey: attempt, backend: .jellyfin, server: server,
            operation: .activeEncoding(playSessionID: "play-1"))!
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(DurableDownloadCleanupIntent.self, from: data) == value)
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("secret"))
        #expect(json.contains("activeEncoding"))
    }

    @Test func knownEmbyJobRoundTripsWithStableTag() throws {
        let value = DurableDownloadCleanupIntent(
            attemptKey: attempt, backend: .emby, server: server,
            operation: .embyConvert(.knownJob(jobID: 42)))!
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(DurableDownloadCleanupIntent.self, from: data) == value)
        #expect(String(decoding: data, as: UTF8.self).contains("knownJob"))
    }

    @Test func ambiguousCreatePreservesExactRecoveryIdentity() throws {
        let fingerprint = EmbyConvertRecoveryPolicy.Fingerprint(
            itemId: "item", quality: "Custom", profile: "profile", bitrate: 4_000_000,
            userId: "user-1", container: "mp4", videoCodec: "h264", audioCodec: "aac",
            audioStreamIndex: 2)
        let operation = DurableDownloadCleanupIntent.Operation.embyConvert(.ambiguousCreate(
            baselineJobIDs: [9, 2, 9], fingerprint: fingerprint,
            attemptStartedAtEpochSeconds: 1234.5, phase: .dispatchAmbiguous))
        let value = DurableDownloadCleanupIntent(
            attemptKey: attempt, backend: .emby, server: server, operation: operation)!
        let decoded = try JSONDecoder().decode(DurableDownloadCleanupIntent.self,
                                               from: JSONEncoder().encode(value))
        #expect(decoded.operation == operation)
    }

    @Test func backendAndServerMatchingFailsClosed() {
        let value = DurableDownloadCleanupIntent(
            attemptKey: attempt, backend: .emby, server: server,
            operation: .activeEncoding(playSessionID: "play"))!
        #expect(value.matches(session: BackendSession(
            kind: .emby, baseURL: URL(string: "https://example.com/emby")!, token: "token",
            userID: "user-1", serverID: "server-1")))
        #expect(!value.matches(session: BackendSession(
            kind: .emby, baseURL: URL(string: "https://example.com/emby")!, token: "token",
            userID: "other", serverID: "server-1")))
        #expect(!value.matches(session: BackendSession(
            kind: .jellyfin, baseURL: URL(string: "https://example.com/emby")!, token: "token",
            userID: "user-1", serverID: "server-1")))
    }

    @Test func invalidBackendOperationAndStaleClearAreRejected() {
        #expect(DurableDownloadCleanupIntent(
            attemptKey: attempt, backend: .plex, server: server,
            operation: .activeEncoding(playSessionID: "play")) == nil)
        #expect(DurableDownloadCleanupIntent(
            attemptKey: attempt, backend: .jellyfin, server: server,
            operation: .embyConvert(.knownJob(jobID: 1))) == nil)
        let value = DurableDownloadCleanupIntent(
            id: UUID(int: 3), attemptKey: attempt, backend: .emby, server: server,
            operation: .activeEncoding(playSessionID: "play"))!
        #expect(value.matchesForClear(id: value.id, attemptKey: attempt, operation: value.operation))
        #expect(!value.matchesForClear(id: UUID(int: 4), attemptKey: attempt, operation: value.operation))
    }

    @Test func decodedServerIdentityRejectsMalformedOrBlankIdentity() throws {
        let value = DurableDownloadCleanupIntent(
            attemptKey: attempt, backend: .emby, server: server,
            operation: .activeEncoding(playSessionID: "play"))!
        let encoded = try JSONEncoder().encode(value)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var serverObject = try #require(object["server"] as? [String: Any])
        serverObject["baseURLString"] = "ftp://example.com"
        object["server"] = serverObject
        let invalidScheme = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(DurableDownloadCleanupIntent.self, from: invalidScheme)
        }

        serverObject["baseURLString"] = "https://example.com"
        serverObject["userID"] = "  "
        object["server"] = serverObject
        let blankUser = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(DurableDownloadCleanupIntent.self, from: blankUser)
        }
    }
}

private extension UUID {
    init(int: UInt8) {
        self.init(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, int))
    }
}
