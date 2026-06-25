import Testing
import Foundation
@testable import PMSKit

/// Hermetic tests for the Emby "Convert Media" request layer (`EmbyConvertRequest`).
/// No network: every test exercises pure request builders / decoders with placeholder
/// ids/host (repo goes public).
@Suite("Emby convert job (request layer)")
struct EmbyConvertJobTests {
    private let identity = EmbyClientIdentity(
        client: "VisionPlay", device: "Vision Pro", deviceId: "device-placeholder", version: "1.0")
    private let server = URL(string: "https://emby.example.internal")!
    private let token = "token-placeholder"
    private let userId = "user-placeholder"

    // MARK: - Status decoding

    @Test("Each observed server status string decodes to its case")
    func decodesEachStatus() throws {
        let cases: [(String, EmbyConvertJobStatus)] = [
            ("Queued", .queued),
            ("Converting", .converting),
            ("Transferring", .transferring),
            ("Completed", .completed),
            ("Failed", .failed),
            ("Cancelled", .cancelled),
        ]
        for (raw, expected) in cases {
            let job = try EmbyConvertRequest.decodeJob(
                from: Data("{\"Id\":42,\"Status\":\"\(raw)\",\"Progress\":12.5}".utf8))
            #expect(job.status == expected)
            #expect(job.id == 42)
            #expect(job.progress == 12.5)
        }
    }

    @Test("An unrecognized status string decodes to .unknown (forward-compat, never crashes)")
    func unknownStatusFallsBack() throws {
        let job = try EmbyConvertRequest.decodeJob(
            from: Data("{\"Id\":1,\"Status\":\"SomethingNew\"}".utf8))
        #expect(job.status == .unknown)
        #expect(job.progress == nil)
    }

    @Test("Absent Status decodes to .unknown; absent Progress is nil")
    func absentFieldsTolerated() throws {
        let job = try EmbyConvertRequest.decodeJob(from: Data("{\"Id\":7}".utf8))
        #expect(job.status == .unknown)
        #expect(job.progress == nil)
        #expect(job.id == 7)
    }

    // MARK: - create-response (SyncJobCreationResult) decoding

    /// The exact `POST /Sync/Jobs` response shape verified live (Emby 4.9.3): the created job is
    /// nested under `"Job"`, alongside a `"JobItems"` array. Decoding this as a BARE job (the
    /// single-job-GET shape) threw `keyNotFound("Id")` — the create-phase "Download failed" crash.
    private let createResponseJSON = """
    {"Job":{"Id":314,"TargetId":"originalmediafolder","Quality":"custom","Bitrate":4000000,
            "Profile":"tv","Progress":0,"Name":"Some Title","Status":"Queued","ItemId":50459},
     "JobItems":[]}
    """

    @Test("decodeCreatedJob unwraps the nested \"Job\" envelope (regression: create-phase keyNotFound)")
    func decodeCreatedJobUnwrapsEnvelope() throws {
        let job = try EmbyConvertRequest.decodeCreatedJob(from: Data(createResponseJSON.utf8))
        #expect(job.id == 314)
        #expect(job.status == .queued)
        #expect(job.progress == 0)
    }

    @Test("Decoding the create envelope as a BARE job fails — the original bug, now guarded")
    func bareDecodeOfCreateEnvelopeThrows() {
        #expect(throws: (any Error).self) {
            _ = try EmbyConvertRequest.decodeJob(from: Data(createResponseJSON.utf8))
        }
    }

    @Test("decodeCreatedJob tolerates a created job whose Progress is absent (null until converting)")
    func decodeCreatedJobAbsentProgress() throws {
        let json = "{\"Job\":{\"Id\":7,\"Status\":\"Queued\"},\"JobItems\":[]}"
        let job = try EmbyConvertRequest.decodeCreatedJob(from: Data(json.utf8))
        #expect(job.id == 7)
        #expect(job.status == .queued)
        #expect(job.progress == nil)
    }

    // MARK: - isTerminal / didSucceed

    @Test("isTerminal is true only for Completed/Failed/Cancelled")
    func terminalHelper() {
        #expect(EmbyConvertJobStatus.queued.isTerminal == false)
        #expect(EmbyConvertJobStatus.converting.isTerminal == false)
        #expect(EmbyConvertJobStatus.transferring.isTerminal == false)
        #expect(EmbyConvertJobStatus.unknown.isTerminal == false)
        #expect(EmbyConvertJobStatus.completed.isTerminal == true)
        #expect(EmbyConvertJobStatus.failed.isTerminal == true)
        #expect(EmbyConvertJobStatus.cancelled.isTerminal == true)
    }

    @Test("didSucceed is true only for Completed")
    func succeededHelper() {
        #expect(EmbyConvertJobStatus.completed.didSucceed == true)
        for s: EmbyConvertJobStatus in [.queued, .converting, .transferring, .failed, .cancelled, .unknown] {
            #expect(s.didSucceed == false)
        }
    }

    // MARK: - createJobRequest body shape

    private func createJobBody() throws -> [String: Any] {
        let req = try EmbyConvertRequest.createJobRequest(
            server: server, token: token, identity: identity,
            userId: userId, itemId: "item-placeholder",
            quality: "custom", profile: "tv", bitrate: 8_000_000, name: "Title [VisionPlay abcd1234]")
        let data = try #require(req.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("createJobRequest is a POST application/json to /Sync/Jobs")
    func createJobRequestEnvelope() throws {
        let req = try EmbyConvertRequest.createJobRequest(
            server: server, token: token, identity: identity,
            userId: userId, itemId: "item-placeholder",
            quality: "custom", profile: "tv", bitrate: 8_000_000, name: "Title [VisionPlay abcd1234]")
        #expect(req.httpMethod == "POST")
        #expect(req.url?.path == "/Sync/Jobs")
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")
        // Auth applied via the shared Emby helper.
        let auth = try #require(req.value(forHTTPHeaderField: "Authorization"))
        #expect(auth.hasPrefix("Emby "))
        #expect(req.value(forHTTPHeaderField: "X-Emby-Token") == token)
    }

    @Test("createJobRequest body is lowercase camelCase with targetId originalmediafolder")
    func createJobBodyCamelCase() throws {
        let body = try createJobBody()
        #expect(body["targetId"] as? String == "originalmediafolder")
        #expect(body["userId"] as? String == userId)
        #expect(body["quality"] as? String == "custom")
        #expect(body["profile"] as? String == "tv")
        #expect(body["bitrate"] as? Int == 8_000_000)
        #expect(body["name"] as? String == "Title [VisionPlay abcd1234]")
        #expect(body["unwatchedOnly"] as? Bool == false)
        #expect(body["syncNewContent"] as? Bool == false)
        #expect(body["category"] is NSNull)
        #expect(body["parentId"] is NSNull)
        #expect(body["itemLimit"] is NSNull)
    }

    @Test("itemIds is an array containing the single itemId")
    func itemIdsIsArray() throws {
        let body = try createJobBody()
        let itemIds = try #require(body["itemIds"] as? [String])
        #expect(itemIds == ["item-placeholder"])
    }

    @Test("createJobRequest body contains NO PascalCase keys")
    func createJobBodyHasNoPascalCaseKeys() throws {
        let body = try createJobBody()
        for key in body.keys {
            let first = try #require(key.first)
            #expect(first.isLowercase || first.isNumber,
                    "body key \"\(key)\" must be lowercase camelCase (PascalCase 500s on Emby)")
        }
        // Spot-check the exact PascalCase forms that would have 500'd.
        #expect(body["TargetId"] == nil)
        #expect(body["UserId"] == nil)
        #expect(body["ItemIds"] == nil)
    }

    @Test("nil bitrate serializes as JSON null")
    func nilBitrateIsNull() throws {
        let req = try EmbyConvertRequest.createJobRequest(
            server: server, token: token, identity: identity,
            userId: userId, itemId: "item-placeholder",
            quality: "8000000", profile: "mobile", bitrate: nil, name: "n")
        let data = try #require(req.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["bitrate"] is NSNull)
    }

    // MARK: - jobStatusRequest / deleteJobRequest

    @Test("jobStatusRequest is a GET to /Sync/Jobs/{id}")
    func jobStatusRequestShape() throws {
        let req = try EmbyConvertRequest.jobStatusRequest(
            server: server, token: token, identity: identity, jobId: 99)
        #expect(req.httpMethod == "GET")
        #expect(req.url?.path == "/Sync/Jobs/99")
        #expect(req.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Emby ") == true)
    }

    @Test("deleteJobRequest is a DELETE to /Sync/Jobs/{id}")
    func deleteJobRequestShape() throws {
        let req = try EmbyConvertRequest.deleteJobRequest(
            server: server, token: token, identity: identity, jobId: 99)
        #expect(req.httpMethod == "DELETE")
        #expect(req.url?.path == "/Sync/Jobs/99")
        #expect(req.value(forHTTPHeaderField: "X-Emby-Token") == token)
    }

    // MARK: - Quality mapping

    @Test("Original video quality maps to keep-quality bitrate + tv profile, never the original token")
    func originalQualityMapping() {
        let q = EmbyConvertRequest.convertQuality(forPresetLabel: "Original video quality")
        #expect(q.quality != "original")
        #expect(q.quality == "custom")
        #expect(q.profile == "tv")
        #expect(q.bitrate == EmbyConvertRequest.keepQualityBitrate)
        #expect(q.bitrate == 80_000_000)
    }

    @Test("Bitrate presets map to quality:custom + the labelled bps + tv profile (no cap)")
    func bitratePresetMapping() {
        let p1080 = EmbyConvertRequest.convertQuality(forPresetLabel: "1080p · 8 Mbps")
        #expect(p1080.quality == "custom")
        #expect(p1080.profile == "tv")
        #expect(p1080.bitrate == 8_000_000)

        #expect(EmbyConvertRequest.convertQuality(forPresetLabel: "1080p · 20 Mbps").bitrate == 20_000_000)
        #expect(EmbyConvertRequest.convertQuality(forPresetLabel: "1080p · 12 Mbps").bitrate == 12_000_000)
        #expect(EmbyConvertRequest.convertQuality(forPresetLabel: "1080p · 10 Mbps").bitrate == 10_000_000)

        let p720 = EmbyConvertRequest.convertQuality(forPresetLabel: "720p · 4 Mbps")
        #expect(p720.bitrate == 4_000_000)
        #expect(EmbyConvertRequest.convertQuality(forPresetLabel: "720p · 3 Mbps").bitrate == 3_000_000)
        #expect(EmbyConvertRequest.convertQuality(forPresetLabel: "720p · 2 Mbps").bitrate == 2_000_000)

        let p480 = EmbyConvertRequest.convertQuality(forPresetLabel: "480p · 1.5 Mbps")
        #expect(p480.bitrate == 1_500_000)
    }

    @Test("High-bitrate presets are NOT capped — Emby honors arbitrary custom bitrates")
    func highBitrateNotCapped() {
        let p4k = EmbyConvertRequest.convertQuality(forPresetLabel: "4K · 40 Mbps")
        #expect(p4k.quality == "custom")
        #expect(p4k.profile == "tv")
        #expect(p4k.bitrate == 40_000_000)
    }

    @Test("An unrecognized label falls back to the keep-quality bitrate (custom/tv)")
    func unknownLabelFallsBack() {
        let q = EmbyConvertRequest.convertQuality(forPresetLabel: "Mystery preset")
        #expect(q.quality == "custom")
        #expect(q.profile == "tv")
        #expect(q.bitrate == EmbyConvertRequest.keepQualityBitrate)
    }
}
