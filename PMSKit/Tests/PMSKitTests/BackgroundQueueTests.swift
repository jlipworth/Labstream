import Testing
import Foundation
@testable import PMSKit

private let server = URL(string: "https://192.0.2.10:32400")!
private let id = ClientIdentity(clientIdentifier: "CID", product: "VisionPlay",
                               version: "0.1.0", deviceName: "AVP")

// MARK: - Request builders

@Test func transcodeJobsRequestTargetsBackgroundSessionsAsJSON() {
    let r = BackgroundQueueRequest.transcodeJobsRequest(server: server, token: "tok", identity: id)
    #expect(r.url.path == "/status/sessions/background")
    #expect(r.method == "GET")
    #expect(r.headers["Accept"] == "application/json")
    #expect(r.headers["X-Plex-Token"] == "tok")
}

@Test func conversionQueueRequestTargetsPlayQueue1() {
    let r = BackgroundQueueRequest.conversionQueueRequest(server: server, token: "tok", identity: id)
    #expect(r.url.path == "/playQueues/1")
    #expect(r.method == "GET")
    #expect(r.headers["X-Plex-Token"] == "tok")
}

@Test func prefsRequestTargetsPrefsAsGET() {
    let r = BackgroundQueueRequest.prefsRequest(server: server, token: "tok", identity: id)
    #expect(r.url.path == "/:/prefs")
    #expect(r.method == "GET")
    #expect(r.headers["X-Plex-Token"] == "tok")
}

@Test func unpausePutsBackgroundQueueIdlePausedZero() {
    let r = BackgroundQueueRequest.setBackgroundQueueIdlePausedRequest(
        server: server, token: "tok", identity: id, paused: false)
    #expect(r.url.path == "/:/prefs")
    #expect(r.method == "PUT")
    func v(_ n: String) -> String? { r.queryItems.first { $0.name == n }?.value }
    #expect(v("BackgroundQueueIdlePaused") == "0")
    #expect(r.headers["X-Plex-Token"] == "tok")
}

@Test func pauseVariantPutsBackgroundQueueIdlePausedOne() {
    let r = BackgroundQueueRequest.setBackgroundQueueIdlePausedRequest(
        server: server, token: "tok", identity: id, paused: true)
    #expect(r.queryItems.first { $0.name == "BackgroundQueueIdlePaused" }?.value == "1")
}

// MARK: - BackgroundTranscodeJobs (running/paused optimization)

@Test func decodesRunningTranscodeJobWithProgressAndState() throws {
    let json = """
    {"MediaContainer":{"size":1,"TranscodeJob":[
      {"progress":42,"ratingKey":"101","Status":{"state":"running"}}
    ]}}
    """.data(using: .utf8)!
    let j = try JSONDecoder().decode(BackgroundTranscodeJobs.self, from: json)
    #expect(j.jobs.count == 1)
    #expect(j.firstProgress == 42)
    #expect(j.firstState == "running")
}

@Test func decodesTranscodeJobTopLevelStateAndStringProgress() throws {
    let json = """
    {"MediaContainer":{"TranscodeJob":[{"progress":"7","state":"paused"}]}}
    """.data(using: .utf8)!
    let j = try JSONDecoder().decode(BackgroundTranscodeJobs.self, from: json)
    #expect(j.firstProgress == 7)
    #expect(j.firstState == "paused")
}

@Test func transcodeJobsEmptyWhenNoJobsRunning() throws {
    // The array is omitted entirely when zero jobs run — must decode to [] not throw.
    let j = try JSONDecoder().decode(BackgroundTranscodeJobs.self,
                                     from: #"{"MediaContainer":{"size":0}}"#.data(using: .utf8)!)
    #expect(j.jobs.isEmpty)
    #expect(j.firstProgress == nil)
    #expect(j.firstState == nil)
}

@Test func transcodeJobsGarbageShapeDoesNotThrow() throws {
    let j = try JSONDecoder().decode(BackgroundTranscodeJobs.self,
                                     from: #"{"nope":1}"#.data(using: .utf8)!)
    #expect(j.jobs.isEmpty)
}

@Test func decodesTranscodeSpeedAsDouble() throws {
    let json = """
    {"MediaContainer":{"TranscodeJob":[{"progress":50,"speed":1.75,"Status":{"state":"running"}}]}}
    """.data(using: .utf8)!
    let j = try JSONDecoder().decode(BackgroundTranscodeJobs.self, from: json)
    #expect(j.firstSpeed == 1.75)
}

@Test func decodesTranscodeSpeedFromIntAndString() throws {
    let intSpeed = try JSONDecoder().decode(BackgroundTranscodeJobs.self, from: """
    {"MediaContainer":{"TranscodeJob":[{"progress":10,"speed":2}]}}
    """.data(using: .utf8)!)
    #expect(intSpeed.firstSpeed == 2.0)

    let strSpeed = try JSONDecoder().decode(BackgroundTranscodeJobs.self, from: """
    {"MediaContainer":{"TranscodeJob":[{"progress":10,"speed":"3.5"}]}}
    """.data(using: .utf8)!)
    #expect(strSpeed.firstSpeed == 3.5)
}

@Test func decodesTranscodeSpeedFromTranscodeSpeedFallbackKey() throws {
    // If `speed` is absent but `transcodeSpeed` is present, use the latter.
    let json = """
    {"MediaContainer":{"TranscodeJob":[{"progress":10,"transcodeSpeed":1.2}]}}
    """.data(using: .utf8)!
    let j = try JSONDecoder().decode(BackgroundTranscodeJobs.self, from: json)
    #expect(j.firstSpeed == 1.2)
}

@Test func transcodeSpeedAbsentOrNonPositiveIsNil() throws {
    // No speed key at all → nil (the EMA fallback then drives the ETA).
    let none = try JSONDecoder().decode(BackgroundTranscodeJobs.self, from: """
    {"MediaContainer":{"TranscodeJob":[{"progress":42,"Status":{"state":"running"}}]}}
    """.data(using: .utf8)!)
    #expect(none.firstSpeed == nil)

    // A zero/garbage speed is meaningless for an ETA → nil, never a divide-by-zero.
    let zero = try JSONDecoder().decode(BackgroundTranscodeJobs.self, from: """
    {"MediaContainer":{"TranscodeJob":[{"progress":42,"speed":0}]}}
    """.data(using: .utf8)!)
    #expect(zero.firstSpeed == nil)

    let garbage = try JSONDecoder().decode(BackgroundTranscodeJobs.self, from: """
    {"MediaContainer":{"TranscodeJob":[{"progress":42,"speed":"fast"}]}}
    """.data(using: .utf8)!)
    #expect(garbage.firstSpeed == nil)
}


@Test func uniqueJobTitleFallbackRejectsSubstringCollisions() throws {
    let json = """
    {"MediaContainer":{"TranscodeJob":[
      {"title":"The Matrix Reloaded","progress":26},
      {"title":"The Matrix Revolutions","progress":10}
    ]}}
    """.data(using: .utf8)!
    let jobs = try JSONDecoder().decode(BackgroundTranscodeJobs.self, from: json)
    #expect(jobs.uniqueJob(title: "The Matrix") == nil)
    #expect(jobs.uniqueJob(title: "  THE   MATRIX   RELOADED ")?.progress == 26)
}

@Test func uniqueJobTitleFallbackRejectsDuplicateExactMatches() throws {
    let json = """
    {"MediaContainer":{"TranscodeJob":[
      {"title":"Pilot","progress":5},
      {"subtitle":"Pilot","progress":15}
    ]}}
    """.data(using: .utf8)!
    let jobs = try JSONDecoder().decode(BackgroundTranscodeJobs.self, from: json)
    #expect(jobs.uniqueJob(title: "Pilot") == nil)
}

// MARK: - ConversionQueue (ordered conversion queue)

@Test func decodesConversionQueueFromVideoElementsWithActiveMarker() throws {
    let json = """
    {"MediaContainer":{"Video":[
      {"playQueueItemID":"-1","order":0,"ratingKey":"101"},
      {"playQueueItemID":"55","order":1,"ratingKey":"102"}
    ]}}
    """.data(using: .utf8)!
    let q = try JSONDecoder().decode(ConversionQueue.self, from: json)
    #expect(q.count == 2)
    // playQueueItemID == "-1" is the active conversion (python-plexapi semantics).
    #expect(q.hasActiveConversion == true)
}

@Test func conversionQueueNonEmptyWithoutMinusOneStillCountsAsActive() throws {
    let json = """
    {"MediaContainer":{"Video":[{"playQueueItemID":"55","order":0}]}}
    """.data(using: .utf8)!
    let q = try JSONDecoder().decode(ConversionQueue.self, from: json)
    #expect(q.count == 1)
    #expect(q.hasActiveConversion == true)   // head of a non-empty queue is being worked
}

@Test func conversionQueueEmptyHasNoActiveConversion() throws {
    let q = try JSONDecoder().decode(ConversionQueue.self,
                                     from: #"{"MediaContainer":{"size":0}}"#.data(using: .utf8)!)
    #expect(q.count == 0)
    #expect(q.hasActiveConversion == false)
}

@Test func conversionQueueGarbageShapeDoesNotThrow() throws {
    let q = try JSONDecoder().decode(ConversionQueue.self,
                                     from: #"{"nope":1}"#.data(using: .utf8)!)
    #expect(q.items.isEmpty)
}

// The live server (PMS 1.43.2.10687) may serialize playQueue items under `Metadata` with the
// active conversion named by a container-level `playQueueSelectedItemID`. Decode that shape,
// read order from `playQueueItemOrder`, and resolve the active/head item correctly.
@Test func decodesConversionQueueFromMetadataWithSelectedItemID() throws {
    let json = """
    {"MediaContainer":{"size":2,"playQueueID":1,"playQueueSelectedItemID":71,
      "Metadata":[
        {"playQueueItemID":71,"playQueueItemOrder":1,"ratingKey":"500"},
        {"playQueueItemID":72,"playQueueItemOrder":2,"ratingKey":"501"}
      ]}}
    """.data(using: .utf8)!
    let q = try JSONDecoder().decode(ConversionQueue.self, from: json)
    #expect(q.count == 2)
    #expect(q.hasActiveConversion == true)
    #expect(q.selectedItemID == "71")
    #expect(q.activeItem?.playQueueItemID == "71")
    #expect(q.activeItem?.ratingKey == "500")
    // Our item matched by ratingKey carries the move handle.
    #expect(q.items.first(where: { $0.ratingKey == "501" })?.playQueueItemID == "72")
}

// The other plausible shape: `Video`-keyed elements (python-plexapi `Conversion.TAG == 'Video'`)
// with no selected-item id; head is the lowest `playQueueItemOrder`.
@Test func decodesConversionQueueFromVideoWithOrderHead() throws {
    let json = """
    {"MediaContainer":{"size":2,"Video":[
      {"playQueueItemID":"88","playQueueItemOrder":2,"ratingKey":"601"},
      {"playQueueItemID":"87","playQueueItemOrder":1,"ratingKey":"600"}
    ]}}
    """.data(using: .utf8)!
    let q = try JSONDecoder().decode(ConversionQueue.self, from: json)
    #expect(q.count == 2)
    #expect(q.selectedItemID == nil)
    // No selected id → head is the lowest-order element (order 1, item 87).
    #expect(q.activeItem?.playQueueItemID == "87")
    #expect(q.hasActiveConversion == true)
}

@Test func decodesConcurrentBackgroundJobsWithRatingKeys() throws {
    let json = """
    {"MediaContainer":{"size":3,"TranscodeJob":[
      {"ratingKey":"34003","key":"/transcode/sessions/a","progress":3.7,"speed":1.0},
      {"ratingKey":"34002","key":"/transcode/sessions/b","progress":95.1},
      {"ratingKey":31910,"key":"/transcode/sessions/c","progress":4,"speed":"0.7"}
    ]}}
    """.data(using: .utf8)!
    let jobs = try JSONDecoder().decode(BackgroundTranscodeJobs.self, from: json)
    #expect(jobs.jobs.count == 3)
    #expect(jobs.job(ratingKey: "34003")?.progress == 3)
    #expect(jobs.job(ratingKey: "34003")?.speed == 1.0)
    #expect(jobs.job(ratingKey: "31910")?.ratingKey == "31910")
    #expect(jobs.job(ratingKey: "31910")?.speed == 0.7)
    #expect(jobs.job(ratingKey: "missing") == nil)
}

@Test func decodesSingleBackgroundJobObjectAndRatingKeyVariants() throws {
    let json = """
    {"MediaContainer":{"size":1,"TranscodeJob":
      {"RatingKey":34003,"key":"/transcode/sessions/a","progress":"12","speed":"1.5"}
    }}
    """.data(using: .utf8)!
    let jobs = try JSONDecoder().decode(BackgroundTranscodeJobs.self, from: json)
    #expect(jobs.jobs.count == 1)
    #expect(jobs.job(ratingKey: "34003")?.progress == 12)
    #expect(jobs.job(ratingKey: "34003")?.speed == 1.5)
}

// Selected id pointing at a non-head element still resolves the active item to the selection.
@Test func selectedItemIDOverridesOrderForActiveItem() throws {
    let json = """
    {"MediaContainer":{"playQueueSelectedItemID":"72","Metadata":[
      {"playQueueItemID":"71","playQueueItemOrder":1,"ratingKey":"500"},
      {"playQueueItemID":"72","playQueueItemOrder":2,"ratingKey":"501"}
    ]}}
    """.data(using: .utf8)!
    let q = try JSONDecoder().decode(ConversionQueue.self, from: json)
    #expect(q.activeItem?.playQueueItemID == "72")
}

// MARK: - moveConversionRequest

@Test func moveConversionRequestTargetsPlayQueueItemMovePath() {
    let r = BackgroundQueueRequest.moveConversionRequest(
        server: server, token: "tok", identity: id,
        playQueueItemID: "72", afterItemID: "71")
    #expect(r.url.path == "/playQueues/1/items/72/move")
    #expect(r.method == "PUT")
    #expect(r.queryItems.first { $0.name == "after" }?.value == "71")
    #expect(r.headers["X-Plex-Token"] == "tok")
}

@Test func moveConversionToFrontUsesAfterMinusOne() {
    let r = BackgroundQueueRequest.moveConversionRequest(
        server: server, token: "tok", identity: id,
        playQueueItemID: "72", afterItemID: "-1")
    #expect(r.url.path == "/playQueues/1/items/72/move")
    #expect(r.queryItems.first { $0.name == "after" }?.value == "-1")
}

// MARK: - ServerPrefs (BackgroundQueueIdlePaused)

@Test func decodesBackgroundQueueIdlePausedTrueFromStringOne() throws {
    let json = """
    {"MediaContainer":{"Setting":[
      {"id":"FriendlyName","value":"My Server"},
      {"id":"BackgroundQueueIdlePaused","value":"1"}
    ]}}
    """.data(using: .utf8)!
    let p = try JSONDecoder().decode(ServerPrefs.self, from: json)
    #expect(p.backgroundQueueIdlePaused == true)
}

@Test func decodesBackgroundQueueIdlePausedFromIntAndBool() throws {
    let intZero = try JSONDecoder().decode(ServerPrefs.self, from: """
    {"MediaContainer":{"Setting":[{"id":"BackgroundQueueIdlePaused","value":0}]}}
    """.data(using: .utf8)!)
    #expect(intZero.backgroundQueueIdlePaused == false)

    let boolTrue = try JSONDecoder().decode(ServerPrefs.self, from: """
    {"MediaContainer":{"Setting":[{"id":"BackgroundQueueIdlePaused","value":true}]}}
    """.data(using: .utf8)!)
    #expect(boolTrue.backgroundQueueIdlePaused == true)
}

@Test func serverPrefsAbsentSettingIsNilNotPaused() throws {
    // Setting list present but no BackgroundQueueIdlePaused → nil ("unknown"), conditional
    // write must then NOT fire.
    let p = try JSONDecoder().decode(ServerPrefs.self, from: """
    {"MediaContainer":{"Setting":[{"id":"FriendlyName","value":"My Server"}]}}
    """.data(using: .utf8)!)
    #expect(p.backgroundQueueIdlePaused == nil)
}

@Test func serverPrefsGarbageShapeDoesNotThrow() throws {
    let p = try JSONDecoder().decode(ServerPrefs.self,
                                     from: #"{"nope":1}"#.data(using: .utf8)!)
    #expect(p.backgroundQueueIdlePaused == nil)
}
