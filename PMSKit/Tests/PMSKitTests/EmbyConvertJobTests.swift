import Testing
import Foundation
@testable import PMSKit

/// Hermetic tests for the Emby "Convert Media" request layer (`EmbyConvertRequest`).
/// No network: every test exercises pure request builders / decoders with placeholder
/// ids/host (repo goes public).
@Suite("Emby convert job (request layer)")
struct EmbyConvertJobTests {
    private let identity = EmbyClientIdentity(
        client: "Labstream", device: "Vision Pro", deviceId: "device-placeholder", version: "1.0")
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

    // MARK: - list/recovery

    private let listResponseJSON = """
    {"Items":[
      {"Id":90,"RequestedItemIds":[1200],"ItemId":1200,"TargetId":"originalmediafolder",
       "Quality":"custom","Profile":"tv","Bitrate":8000000,"Status":"Completed",
       "Progress":100,"DateCreated":"2026-07-01T00:00:00Z","SyncNewContent":false,"UnwatchedOnly":false},
      {"Id":91,"RequestedItemIds":["1200"],"ItemId":"1200","TargetId":"originalmediafolder",
       "Quality":"custom","Profile":"tv","Bitrate":8000000,"Status":"Queued","Progress":0,
       "SyncNewContent":false,"UnwatchedOnly":false}
    ],"TotalRecordCount":2}
    """

    @Test("job-list decoder preserves recovery identity and normalizes numeric item ids")
    func jobListDecode() throws {
        let list = try EmbyConvertRequest.decodeJobList(from: Data(listResponseJSON.utf8))
        #expect(list.totalRecordCount == 2)
        #expect(list.isComplete)
        #expect(list.items.map(\.id) == [90, 91])
        #expect(list.items[0].requestedItemIds == ["1200"])
        #expect(list.items[0].itemId == "1200")
        #expect(list.items[0].targetId == "originalmediafolder")
        #expect(list.items[0].quality == "custom")
        #expect(list.items[0].profile == "tv")
        #expect(list.items[0].bitrate == 8_000_000)
        #expect(list.items[0].status == .completed)
        #expect(list.items[0].progress == 100)
        #expect(list.items[0].dateCreated != nil)
        #expect(list.items[1].requestedItemIds == ["1200"])
        let truncated = try EmbyConvertRequest.decodeJobList(
            from: Data(listResponseJSON.replacingOccurrences(
                of: "\"TotalRecordCount\":2", with: "\"TotalRecordCount\":3").utf8))
        #expect(!truncated.isComplete)
    }

    /// `GET /Sync/Jobs` is server-wide: jobs created by OTHER Emby clients can null/omit
    /// Quality/Profile or use numeric TargetId. One foreign entry must never make the whole
    /// baseline undecodable — that hard-failed EVERY Labstream convert start.
    @Test("job-list decoder tolerates foreign clients' Sync jobs without failing the list")
    func jobListDecodeToleratesForeignJobs() throws {
        let foreign = """
        {"Items":[
          {"Id":90,"RequestedItemIds":[1200],"ItemId":1200,"TargetId":"originalmediafolder",
           "Quality":"custom","Profile":"tv","Bitrate":8000000,"Status":"Completed",
           "SyncNewContent":false,"UnwatchedOnly":false},
          {"Id":91,"RequestedItemIds":[7],"ItemId":7,"TargetId":42,
           "Quality":null,"Status":"Queued"},
          {"NotEvenAnId":true}
        ],"TotalRecordCount":3}
        """
        let list = try EmbyConvertRequest.decodeJobList(from: Data(foreign.utf8))
        // Tolerant fields decode in place (numeric TargetId, null Quality, absent Profile)…
        #expect(list.items.map(\.id) == [90, 91])
        #expect(list.items[1].targetId == "42")
        #expect(list.items[1].quality == "")
        #expect(list.items[1].profile == "")
        // …and an entry with no usable Id is dropped but still counted toward completeness.
        #expect(list.undecodableItemCount == 1)
        #expect(list.isComplete)
        // A tolerant-empty quality/profile can never match a Labstream fingerprint.
        let fingerprint = EmbyConvertRecoveryPolicy.Fingerprint(
            itemId: "7", targetId: "42", quality: "custom", profile: "tv", bitrate: nil)
        #expect(EmbyConvertRecoveryPolicy.recoveredJobID(
            baselineJobIDs: [], jobs: [list.items[1]], fingerprint: fingerprint) == nil)
    }

    private func recoveryEntry(id: Int, itemId: String = "1200", targetId: String = "originalmediafolder",
                               quality: String = "custom", profile: String = "tv",
                               bitrate: Int? = 8_000_000, dateCreated: String? = nil) -> EmbyConvertRecoveryEntry {
        .init(id: id, requestedItemIds: [itemId], itemId: itemId, targetId: targetId,
              quality: quality, profile: profile, bitrate: bitrate,
              dateCreated: dateCreated, syncNewContent: false, unwatchedOnly: false)
    }

    @Test("recovery uses the full baseline and adopts one exact new match")
    func recoveryAdoptsExactlyOne() {
        let fingerprint = EmbyConvertRecoveryPolicy.Fingerprint(
            itemId: "1200", quality: "custom", profile: "tv", bitrate: 8_000_000)
        let jobs = [recoveryEntry(id: 100), recoveryEntry(id: 41), recoveryEntry(id: 99)]
        #expect(EmbyConvertRecoveryPolicy.recoveredJobID(
            baselineJobIDs: [41, 99], jobs: jobs, fingerprint: fingerprint) == 100)
    }

    @Test("recovery does not compare public create user GUID with list-internal numeric UserId")
    func recoveryUserIdDomainsAreNotComparable() {
        let fingerprint = EmbyConvertRecoveryPolicy.Fingerprint(
            itemId: "1200", quality: "custom", profile: "tv", bitrate: 8_000_000,
            userId: "public-user-guid")
        let job = EmbyConvertRecoveryEntry(
            id: 100, requestedItemIds: ["1200"], itemId: "1200",
            targetId: "originalmediafolder", quality: "custom", profile: "tv", bitrate: 8_000_000,
            userId: "7", syncNewContent: false, unwatchedOnly: false)
        #expect(EmbyConvertRecoveryPolicy.recoveredJobID(
            baselineJobIDs: [], jobs: [job], fingerprint: fingerprint) == 100)
    }

    @Test("row/tombstone ownership requires all persisted public user ids to match current session")
    func recoveryPublicUserOwnership() {
        #expect(EmbyConvertRecoveryPolicy.publicUserMatches(
            currentSessionUserID: "user-a", persistedBackendUserID: "user-a",
            fingerprintUserID: "user-a"))
        #expect(!EmbyConvertRecoveryPolicy.publicUserMatches(
            currentSessionUserID: "user-b", persistedBackendUserID: "user-a",
            fingerprintUserID: "user-a"))
        #expect(!EmbyConvertRecoveryPolicy.publicUserMatches(
            currentSessionUserID: "user-a", persistedBackendUserID: nil,
            fingerprintUserID: "user-a"))
        #expect(!EmbyConvertRecoveryPolicy.publicUserMatches(
            currentSessionUserID: "user-a", persistedBackendUserID: "user-a",
            fingerprintUserID: nil))
    }

    @Test("cleanup queue preserves multiple attempt UUIDs for the same rating key")
    func cleanupTombstoneIDsAppendWithoutReplacement() {
        let first = UUID()
        let second = UUID()
        #expect(EmbyConvertRecoveryPolicy.appendingCleanupTombstoneID(
            second, to: [first]) == [first, second])
    }

    @Test("recovery fails closed for zero, multiple, baseline, or inexact matches")
    func recoveryFailsClosed() {
        let fingerprint = EmbyConvertRecoveryPolicy.Fingerprint(
            itemId: "1200", quality: "custom", profile: "tv", bitrate: 8_000_000)
        #expect(EmbyConvertRecoveryPolicy.recoveredJobID(
            baselineJobIDs: [], jobs: [], fingerprint: fingerprint) == nil)
        #expect(EmbyConvertRecoveryPolicy.recoveredJobID(
            baselineJobIDs: [], jobs: [recoveryEntry(id: 1), recoveryEntry(id: 2)],
            fingerprint: fingerprint) == nil)
        #expect(EmbyConvertRecoveryPolicy.recoveredJobID(
            baselineJobIDs: [1], jobs: [recoveryEntry(id: 1)], fingerprint: fingerprint) == nil)
        let mismatches = [
            recoveryEntry(id: 1, itemId: "other"),
            recoveryEntry(id: 2, targetId: "other-target"),
            recoveryEntry(id: 3, quality: "other"),
            recoveryEntry(id: 4, profile: "custom"),
            recoveryEntry(id: 5, bitrate: 4_000_000),
        ]
        #expect(EmbyConvertRecoveryPolicy.recoveredJobID(
            baselineJobIDs: [], jobs: mismatches, fingerprint: fingerprint) == nil)
    }

    @Test("bounded recovery requires dispatched phase, creation window, and unexpired evidence")
    func recoveryWindowBounds() throws {
        let fingerprint = EmbyConvertRecoveryPolicy.Fingerprint(
            itemId: "1200", quality: "custom", profile: "tv", bitrate: 8_000_000)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let start = try #require(formatter.date(from: "2026-07-11T08:00:00.000Z")).timeIntervalSince1970
        let inside = recoveryEntry(id: 1, dateCreated: "2026-07-11T08:00:02.000Z")
        #expect(EmbyConvertRecoveryPolicy.recoveredJobID(
            baselineJobIDs: [], jobs: [inside], fingerprint: fingerprint,
            attemptStartedAtEpochSeconds: start, phase: .dispatchAmbiguous,
            nowEpochSeconds: start + 30) == 1)
        #expect(EmbyConvertRecoveryPolicy.recoveredJobID(
            baselineJobIDs: [], jobs: [inside], fingerprint: fingerprint,
            attemptStartedAtEpochSeconds: start, phase: .prepared,
            nowEpochSeconds: start + 30) == nil)
        #expect(EmbyConvertRecoveryPolicy.recoveredJobID(
            baselineJobIDs: [], jobs: [recoveryEntry(id: 2, dateCreated: "2026-07-11T09:00:00.000Z")],
            fingerprint: fingerprint, attemptStartedAtEpochSeconds: start, phase: .dispatchAmbiguous,
            nowEpochSeconds: start + 30) == nil)
        #expect(EmbyConvertRecoveryPolicy.recoveredJobID(
            baselineJobIDs: [], jobs: [inside], fingerprint: fingerprint,
            attemptStartedAtEpochSeconds: start, phase: .dispatchAmbiguous,
            nowEpochSeconds: start + EmbyConvertRecoveryPolicy.recoveryExpirySeconds + 1) == nil)
    }

    @Test("cleanup discards pre-dispatch/expired-empty evidence, cancels one, and retains ambiguity")
    func recoveryCleanupActions() throws {
        let fingerprint = EmbyConvertRecoveryPolicy.Fingerprint(
            itemId: "1200", quality: "custom", profile: "tv", bitrate: 8_000_000)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let start = try #require(formatter.date(from: "2026-07-11T08:00:00.000Z")).timeIntervalSince1970
        let match = recoveryEntry(id: 9, dateCreated: "2026-07-11T08:00:02.000Z")
        #expect(EmbyConvertRecoveryPolicy.cleanupAction(
            baselineJobIDs: [], jobs: [], listIsComplete: true, fingerprint: fingerprint,
            attemptStartedAtEpochSeconds: start, phase: .prepared, nowEpochSeconds: start + 1)
            == .discardTombstone)
        #expect(EmbyConvertRecoveryPolicy.cleanupAction(
            baselineJobIDs: [], jobs: [match], listIsComplete: true, fingerprint: fingerprint,
            attemptStartedAtEpochSeconds: start, phase: .dispatchAmbiguous, nowEpochSeconds: start + 1)
            == .cancel(jobID: 9))
        #expect(EmbyConvertRecoveryPolicy.cleanupAction(
            baselineJobIDs: [], jobs: [match, recoveryEntry(id: 10, dateCreated: "2026-07-11T08:00:03.000Z")],
            listIsComplete: true, fingerprint: fingerprint,
            attemptStartedAtEpochSeconds: start, phase: .dispatchAmbiguous, nowEpochSeconds: start + 1)
            == .retainTombstone)
        #expect(EmbyConvertRecoveryPolicy.cleanupAction(
            baselineJobIDs: [], jobs: [], listIsComplete: true, fingerprint: fingerprint,
            attemptStartedAtEpochSeconds: start, phase: .dispatchAmbiguous,
            nowEpochSeconds: start + EmbyConvertRecoveryPolicy.recoveryExpirySeconds + 1)
            == .discardTombstone)
        #expect(EmbyConvertRecoveryPolicy.cleanupAction(
            baselineJobIDs: [], jobs: [], listIsComplete: false, fingerprint: fingerprint,
            attemptStartedAtEpochSeconds: start, phase: .dispatchAmbiguous,
            nowEpochSeconds: start + EmbyConvertRecoveryPolicy.recoveryExpirySeconds + 1)
            == .retainTombstone)
    }

    /// A tombstone must never cancel a job a LIVE row currently owns: delete + immediate
    /// re-download of the same item/preset creates a fingerprint-identical job inside the
    /// creation window, and cancelling it would kill the user's active conversion.
    @Test("cleanup never cancels a job owned by a live download row")
    func recoveryCleanupExcludesLiveJobs() throws {
        let fingerprint = EmbyConvertRecoveryPolicy.Fingerprint(
            itemId: "1200", quality: "custom", profile: "tv", bitrate: 8_000_000)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let start = try #require(formatter.date(from: "2026-07-11T08:00:00.000Z")).timeIntervalSince1970
        let match = recoveryEntry(id: 9, dateCreated: "2026-07-11T08:00:02.000Z")
        // The sole candidate is live-owned: retain (re-evaluated later), never cancel.
        #expect(EmbyConvertRecoveryPolicy.cleanupAction(
            baselineJobIDs: [], jobs: [match], listIsComplete: true, fingerprint: fingerprint,
            attemptStartedAtEpochSeconds: start, phase: .dispatchAmbiguous,
            nowEpochSeconds: start + 1, liveJobIDs: [9])
            == .retainTombstone)
        // Excluding the live job can also disambiguate down to the true orphan.
        let orphan = recoveryEntry(id: 10, dateCreated: "2026-07-11T08:00:03.000Z")
        #expect(EmbyConvertRecoveryPolicy.cleanupAction(
            baselineJobIDs: [], jobs: [match, orphan], listIsComplete: true, fingerprint: fingerprint,
            attemptStartedAtEpochSeconds: start, phase: .dispatchAmbiguous,
            nowEpochSeconds: start + 1, liveJobIDs: [9])
            == .cancel(jobID: 10))
        // Past expiry with only a live-owned candidate: nothing left to clean.
        #expect(EmbyConvertRecoveryPolicy.cleanupAction(
            baselineJobIDs: [], jobs: [match], listIsComplete: true, fingerprint: fingerprint,
            attemptStartedAtEpochSeconds: start, phase: .dispatchAmbiguous,
            nowEpochSeconds: start + EmbyConvertRecoveryPolicy.recoveryExpirySeconds + 1,
            liveJobIDs: [9])
            == .discardTombstone)
    }

    @Test("relaunch manager policy polls known jobs, recovers only complete identity, and fails partial state")
    func recoveryRelaunchAction() {
        let fingerprint = EmbyConvertRecoveryPolicy.Fingerprint(
            itemId: "1200", quality: "custom", profile: "tv", bitrate: 8_000_000)
        #expect(EmbyConvertRecoveryPolicy.relaunchAction(
            jobID: 7, baselineJobIDs: [1, 2], fingerprint: fingerprint) == .poll(jobID: 7))
        #expect(EmbyConvertRecoveryPolicy.relaunchAction(
            jobID: nil, baselineJobIDs: [1, 2], fingerprint: fingerprint,
            attemptStartedAtEpochSeconds: 100, phase: .dispatchAmbiguous,
            nowEpochSeconds: 130)
            == .recover(baselineJobIDs: [1, 2], fingerprint: fingerprint,
                        attemptStartedAtEpochSeconds: 100, phase: .dispatchAmbiguous))
        #expect(EmbyConvertRecoveryPolicy.relaunchAction(
            jobID: nil, baselineJobIDs: nil, fingerprint: fingerprint) == .failMissingIdentity)
        #expect(EmbyConvertRecoveryPolicy.relaunchAction(
            jobID: nil, baselineJobIDs: [1, 2], fingerprint: nil) == .failMissingIdentity)
    }

    /// Past `recoveryExpirySeconds`, `matchingNewJobIDs` can never adopt again — re-entering
    /// recovery looped `.preparing` → `.failed` on every Retry with delete as the only escape.
    @Test("relaunch expires a crash-window identity older than the adoption deadline")
    func recoveryRelaunchActionExpires() {
        let fingerprint = EmbyConvertRecoveryPolicy.Fingerprint(
            itemId: "1200", quality: "custom", profile: "tv", bitrate: 8_000_000)
        let start: Double = 100
        #expect(EmbyConvertRecoveryPolicy.relaunchAction(
            jobID: nil, baselineJobIDs: [1, 2], fingerprint: fingerprint,
            attemptStartedAtEpochSeconds: start, phase: .dispatchAmbiguous,
            nowEpochSeconds: start + EmbyConvertRecoveryPolicy.recoveryExpirySeconds + 1)
            == .expireRecovery)
        #expect(EmbyConvertRecoveryPolicy.relaunchAction(
            jobID: nil, baselineJobIDs: [1, 2], fingerprint: fingerprint,
            attemptStartedAtEpochSeconds: start, phase: .dispatchAmbiguous,
            nowEpochSeconds: start + EmbyConvertRecoveryPolicy.recoveryExpirySeconds - 1)
            == .recover(baselineJobIDs: [1, 2], fingerprint: fingerprint,
                        attemptStartedAtEpochSeconds: start, phase: .dispatchAmbiguous))
        // A persisted job id still wins regardless of age.
        #expect(EmbyConvertRecoveryPolicy.relaunchAction(
            jobID: 7, baselineJobIDs: [1, 2], fingerprint: fingerprint,
            attemptStartedAtEpochSeconds: start, phase: .dispatchAmbiguous,
            nowEpochSeconds: start + EmbyConvertRecoveryPolicy.recoveryExpirySeconds + 1)
            == .poll(jobID: 7))
    }

    @Test("create failures preserve recovery after ambiguous dispatch but clear on definitive rejection")
    func recoveryCreateFailureDisposition() {
        #expect(EmbyConvertRecoveryPolicy.createFailureDisposition(
            postWasDispatched: false, httpStatusCode: nil) == .clearRecovery)
        #expect(EmbyConvertRecoveryPolicy.createFailureDisposition(
            postWasDispatched: true, httpStatusCode: 400) == .clearRecovery)
        #expect(EmbyConvertRecoveryPolicy.createFailureDisposition(
            postWasDispatched: true, httpStatusCode: 500) == .preserveForRecovery)
        #expect(EmbyConvertRecoveryPolicy.createFailureDisposition(
            postWasDispatched: true, httpStatusCode: nil) == .preserveForRecovery)
        #expect(EmbyConvertRecoveryPolicy.createFailureDisposition(
            postWasDispatched: true, httpStatusCode: 200) == .preserveForRecovery)
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
            quality: "custom", profile: "tv", bitrate: 8_000_000, name: "Title [Labstream abcd1234]")
        let data = try #require(req.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("createJobRequest is a POST application/json to /Sync/Jobs")
    func createJobRequestEnvelope() throws {
        let req = try EmbyConvertRequest.createJobRequest(
            server: server, token: token, identity: identity,
            userId: userId, itemId: "item-placeholder",
            quality: "custom", profile: "tv", bitrate: 8_000_000, name: "Title [Labstream abcd1234]")
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
        #expect(body["name"] as? String == "Title [Labstream abcd1234]")
        #expect(body["unwatchedOnly"] as? Bool == false)
        #expect(body["syncNewContent"] as? Bool == false)
        #expect(body["category"] is NSNull)
        #expect(body["parentId"] is NSNull)
        #expect(body["itemLimit"] is NSNull)
        #expect(body["audioStreamIndex"] == nil)
    }

    @Test("createJobRequest carries selected audio stream when provided")
    func createJobBodyAudioStreamIndex() throws {
        let req = try EmbyConvertRequest.createJobRequest(
            server: server, token: token, identity: identity,
            userId: userId, itemId: "item-placeholder",
            quality: "custom", profile: "tv", bitrate: 8_000_000,
            name: "Title [Labstream abcd1234]",
            audioStreamIndex: 4)
        let data = try #require(req.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["audioStreamIndex"] as? Int == 4)
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

    @Test("jobListRequest is a base-path-preserving authenticated GET")
    func jobListRequestShape() throws {
        let req = try EmbyConvertRequest.jobListRequest(
            server: URL(string: "https://emby.example.internal/emby")!, token: token, identity: identity)
        #expect(req.httpMethod == "GET")
        #expect(req.url?.path == "/emby/Sync/Jobs")
        #expect(req.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(req.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Emby ") == true)
        #expect(req.value(forHTTPHeaderField: "X-Emby-Token") == token)
    }

    @Test("deleteJobRequest is a DELETE to /Sync/Jobs/{id}")
    func deleteJobRequestShape() throws {
        let req = try EmbyConvertRequest.deleteJobRequest(
            server: server, token: token, identity: identity, jobId: 99)
        #expect(req.httpMethod == "DELETE")
        #expect(req.url?.path == "/Sync/Jobs/99")
        #expect(req.value(forHTTPHeaderField: "X-Emby-Token") == token)
    }

    @Test("itemRefreshRequest is a POST to /Items/{id}/Refresh with safe defaults")
    func itemRefreshRequestShape() throws {
        let req = try EmbyConvertRequest.itemRefreshRequest(
            server: server, token: token, identity: identity, userId: userId,
            itemId: "item-placeholder")
        #expect(req.httpMethod == "POST")
        #expect(req.url?.path == "/Items/item-placeholder/Refresh")
        let query = Dictionary(uniqueKeysWithValues: URLComponents(url: try #require(req.url), resolvingAgainstBaseURL: false)!
            .queryItems!
            .map { ($0.name, $0.value ?? "") })
        #expect(query["Recursive"] == "true")
        #expect(query["MetadataRefreshMode"] == "Default")
        #expect(query["ImageRefreshMode"] == "Default")
        #expect(query["ReplaceAllMetadata"] == "false")
        #expect(query["ReplaceAllImages"] == "false")
        #expect(req.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Emby ") == true)
    }

    // MARK: - Quality mapping

    @Test("Original video quality routes through the resolution-preserving custom path (#128), never the original token")
    func originalQualityMapping() {
        let q = EmbyConvertRequest.convertQuality(forPresetLabel: "Original video quality")
        #expect(q.quality != "original")
        #expect(q.quality == "custom")
        // #128: "Original" must preserve source resolution — `tv` would silently downscale 4K to 1080p.
        #expect(q.profile == "custom")
        #expect(q.container == "mp4")
        #expect(q.videoCodec == "h264")
        #expect(q.audioCodec == "aac")
        #expect(q.bitrate == EmbyConvertRequest.keepQualityBitrate)
        #expect(q.bitrate == 80_000_000)
    }

    @Test("Sub-1080p bitrate presets keep profile:tv with NO custom criteria (the tv ceiling is the wanted downscale)")
    func bitratePresetMapping() {
        let p1080 = EmbyConvertRequest.convertQuality(forPresetLabel: "1080p · 8 Mbps")
        #expect(p1080.quality == "custom")
        #expect(p1080.profile == "tv")
        #expect(p1080.bitrate == 8_000_000)
        // tv-profile presets must NOT carry custom criteria.
        #expect(p1080.container == nil)
        #expect(p1080.videoCodec == nil)
        #expect(p1080.audioCodec == nil)

        #expect(EmbyConvertRequest.convertQuality(forPresetLabel: "1080p · 20 Mbps").bitrate == 20_000_000)
        #expect(EmbyConvertRequest.convertQuality(forPresetLabel: "1080p · 12 Mbps").bitrate == 12_000_000)
        #expect(EmbyConvertRequest.convertQuality(forPresetLabel: "1080p · 10 Mbps").bitrate == 10_000_000)

        let p720 = EmbyConvertRequest.convertQuality(forPresetLabel: "720p · 4 Mbps")
        #expect(p720.bitrate == 4_000_000)
        #expect(p720.profile == "tv")
        #expect(EmbyConvertRequest.convertQuality(forPresetLabel: "720p · 3 Mbps").bitrate == 3_000_000)
        #expect(EmbyConvertRequest.convertQuality(forPresetLabel: "720p · 2 Mbps").bitrate == 2_000_000)

        let p480 = EmbyConvertRequest.convertQuality(forPresetLabel: "480p · 1.5 Mbps")
        #expect(p480.bitrate == 1_500_000)
        #expect(p480.profile == "tv")
    }

    @Test("4K preset routes through profile:custom with mp4/h264/aac criteria + uncapped bitrate (#128)")
    func fourKUsesCustomProfile() {
        let p4k = EmbyConvertRequest.convertQuality(forPresetLabel: "4K · 40 Mbps")
        #expect(p4k.quality == "custom")
        // #128: custom (NOT tv) so output keeps true 4K instead of the tv profile's 1080p ceiling.
        #expect(p4k.profile == "custom")
        #expect(p4k.container == "mp4")
        #expect(p4k.videoCodec == "h264")
        #expect(p4k.audioCodec == "aac")
        #expect(p4k.bitrate == 40_000_000)
    }

    @Test("createJobRequest emits the custom criteria only when supplied (#128)")
    func customCriteriaInBody() throws {
        // tv path: no criteria keys at all.
        let tvBody = try createJobBody()
        #expect(tvBody["container"] == nil)
        #expect(tvBody["videoCodec"] == nil)
        #expect(tvBody["audioCodec"] == nil)

        // custom path: the required mp4/h264/aac triple is present (camelCase, binds live).
        let q = EmbyConvertRequest.customFourKQuality(bitrate: 40_000_000)
        let req = try EmbyConvertRequest.createJobRequest(
            server: server, token: token, identity: identity,
            userId: userId, itemId: "item-placeholder",
            quality: q.quality, profile: q.profile, bitrate: q.bitrate,
            name: "Title [Labstream abcd1234]",
            container: q.container, videoCodec: q.videoCodec, audioCodec: q.audioCodec)
        let data = try #require(req.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["profile"] as? String == "custom")
        #expect(body["container"] as? String == "mp4")
        #expect(body["videoCodec"] as? String == "h264")
        #expect(body["audioCodec"] as? String == "aac")
        #expect(body["bitrate"] as? Int == 40_000_000)
        #expect(body["targetId"] as? String == "originalmediafolder")
    }

    @Test("An unrecognized label falls back to the resolution-preserving custom path (#128)")
    func unknownLabelFallsBack() {
        let q = EmbyConvertRequest.convertQuality(forPresetLabel: "Mystery preset")
        #expect(q.quality == "custom")
        #expect(q.profile == "custom")
        #expect(q.bitrate == EmbyConvertRequest.keepQualityBitrate)
    }
}
