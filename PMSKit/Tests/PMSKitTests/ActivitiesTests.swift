import Testing
import Foundation
@testable import PMSKit

private let server = URL(string: "https://192.0.2.10:32400")!
private let id = ClientIdentity(clientIdentifier: "CID", product: "VisionPlay",
                               version: "0.1.0", deviceName: "AVP")

@Test func activitiesRequestTargetsActivitiesAsJSON() {
    let r = ActivitiesRequest.list(server: server, token: "tok", identity: id)
    #expect(r.url.path == "/activities")
    #expect(r.method == "GET")
    #expect(r.headers["Accept"] == "application/json")
    #expect(r.headers["X-Plex-Token"] == "tok")
}

@Test func decodesNormalActivity() throws {
    let json = """
    {"MediaContainer":{"size":1,"Activity":[
      {"uuid":"abc-123","type":"media.optimize","cancellable":1,"userID":1,
       "title":"Optimizing","subtitle":"Blade Runner","progress":37,
       "Context":{"ratingKey":"101","librarySectionID":1}}
    ]}}
    """.data(using: .utf8)!
    let a = try JSONDecoder().decode(Activities.self, from: json)
    #expect(a.activities.count == 1)
    let act = try #require(a.activities.first)
    #expect(act.uuid == "abc-123")
    #expect(act.type == "media.optimize")
    #expect(act.progress == 37)
    #expect(act.cancellable == true)
    #expect(act.title == "Optimizing")
    #expect(act.subtitle == "Blade Runner")
    #expect(act.contextRatingKey == "101")
    #expect(act.looksLikeOptimize)
}

@Test func decodesMissingProgressAsNil() throws {
    let json = """
    {"MediaContainer":{"Activity":[
      {"uuid":"u","type":"media.optimize","title":"t"}
    ]}}
    """.data(using: .utf8)!
    let a = try JSONDecoder().decode(Activities.self, from: json)
    #expect(a.activities.first?.progress == nil)
}

@Test func decodesIndeterminateAndStringProgress() throws {
    let json = """
    {"MediaContainer":{"Activity":[
      {"type":"media.optimize","progress":-1},
      {"type":"media.optimize","progress":"50"}
    ]}}
    """.data(using: .utf8)!
    let a = try JSONDecoder().decode(Activities.self, from: json)
    #expect(a.activities[0].progress == -1)
    #expect(a.activities[1].progress == 50)
}

@Test func toleratesAlternateTypeStringsAndCasing() throws {
    // Capitalized keys + an undocumented optimize-ish type.
    let json = """
    {"MediaContainer":{"Activity":[
      {"UUID":"x","Type":"library.optimize.section","Title":"T","progress":10},
      {"type":"provider.subscriptions.process.optimization","progress":20},
      {"type":"library.update.section","progress":5}
    ]}}
    """.data(using: .utf8)!
    let a = try JSONDecoder().decode(Activities.self, from: json)
    #expect(a.activities[0].type == "library.optimize.section")
    #expect(a.activities[0].title == "T")
    #expect(a.activities[0].looksLikeOptimize)
    #expect(a.activities[1].looksLikeOptimize)
    #expect(!a.activities[2].looksLikeOptimize)  // library scan is not an optimize job
}

@Test func emptyContainerOmitsActivityArray() throws {
    let json = """
    {"MediaContainer":{"size":0}}
    """.data(using: .utf8)!
    let a = try JSONDecoder().decode(Activities.self, from: json)
    #expect(a.activities.isEmpty)
}

@Test func garbageShapeDoesNotThrow() throws {
    let json = """
    {"unexpected":true,"foo":[1,2,3]}
    """.data(using: .utf8)!
    let a = try JSONDecoder().decode(Activities.self, from: json)
    #expect(a.activities.isEmpty)
}

@Test func matchingHelperPrefersContextRatingKey() throws {
    let json = """
    {"MediaContainer":{"Activity":[
      {"type":"media.optimize","title":"Some Other Movie","progress":12,
       "Context":{"ratingKey":"999"}},
      {"type":"media.optimize","title":"Blade Runner","progress":42,
       "Context":{"ratingKey":"101"}}
    ]}}
    """.data(using: .utf8)!
    let a = try JSONDecoder().decode(Activities.self, from: json)
    let match = try #require(a.optimizeActivity(ratingKey: "101", title: "Blade Runner"))
    #expect(match.progress == 42)
    #expect(match.contextRatingKey == "101")
}

@Test func matchingHelperFallsBackToBareTitle() throws {
    // Server shape: generic title "Optimizing", subtitle is the bare media name. We match
    // on the BARE media title (not our suffixed optimize-queue title).
    let json = """
    {"MediaContainer":{"Activity":[
      {"type":"media.optimize","title":"Optimizing","subtitle":"Blade Runner","progress":42}
    ]}}
    """.data(using: .utf8)!
    let a = try JSONDecoder().decode(Activities.self, from: json)
    let match = try #require(a.optimizeActivity(ratingKey: "101", title: "Blade Runner"))
    #expect(match.progress == 42)
}

@Test func suffixedQueueTitleDoesNotMatchBareServerSubtitle() throws {
    // Regression guard for the dead-code bug: our queue title carries a unique
    // "[VisionPlay abcd1234]" suffix the server activity never contains, so passing the
    // SUFFIXED title must NOT match — only the bare title does.
    let json = """
    {"MediaContainer":{"Activity":[
      {"type":"media.optimize","title":"Optimizing","subtitle":"Blade Runner","progress":42}
    ]}}
    """.data(using: .utf8)!
    let a = try JSONDecoder().decode(Activities.self, from: json)
    #expect(a.optimizeActivity(ratingKey: nil, title: "Blade Runner [VisionPlay abcd1234]") == nil)
    #expect(a.optimizeActivity(ratingKey: nil, title: "Blade Runner") != nil)
}

@Test func soleOptimizerTakenOnlyWhenFallbackAllowed() throws {
    // A single optimize job is running, but it is NOT ours (no ratingKey/title match).
    let json = """
    {"MediaContainer":{"Activity":[
      {"type":"library.update.section","progress":80},
      {"type":"media.optimize","title":"Optimizing","subtitle":"Someone Else's Movie","progress":17}
    ]}}
    """.data(using: .utf8)!
    let a = try JSONDecoder().decode(Activities.self, from: json)
    // Default (fallback disallowed): never mis-attribute another job's progress.
    #expect(a.optimizeActivity(ratingKey: "101", title: "My Movie") == nil)
    // Allowed (this client has a single active download): take the sole optimizer.
    let match = try #require(a.optimizeActivity(ratingKey: "101", title: "My Movie",
                                                allowSoleFallback: true))
    #expect(match.progress == 17)
}

@Test func ambiguousTitleMatchReturnsNil() throws {
    // "Alien" is a substring of both "Alien" and "Aliens": two title matches → ambiguous →
    // return nil rather than guess (no wrong percentage shown).
    let json = """
    {"MediaContainer":{"Activity":[
      {"type":"media.optimize","title":"Optimizing","subtitle":"Alien","progress":30},
      {"type":"media.optimize","title":"Optimizing","subtitle":"Aliens","progress":70}
    ]}}
    """.data(using: .utf8)!
    let a = try JSONDecoder().decode(Activities.self, from: json)
    #expect(a.optimizeActivity(ratingKey: nil, title: "Alien", allowSoleFallback: true) == nil)
    // The longer, unambiguous title still resolves correctly.
    #expect(a.optimizeActivity(ratingKey: nil, title: "Aliens")?.progress == 70)
}

@Test func concurrentJobsDisambiguatedByContextRatingKey() throws {
    // Two concurrent optimize jobs: the right one is picked by Context.ratingKey, even with
    // the sole-optimizer fallback allowed (it must not fire when count > 1).
    let json = """
    {"MediaContainer":{"Activity":[
      {"type":"media.optimize","progress":12,"Context":{"ratingKey":999}},
      {"type":"media.optimize","progress":55,"Context":{"ratingKey":"101"}}
    ]}}
    """.data(using: .utf8)!
    let a = try JSONDecoder().decode(Activities.self, from: json)
    #expect(a.activities[0].contextRatingKey == "999")  // Int ratingKey tolerated
    #expect(a.optimizeActivity(ratingKey: "101", title: "x", allowSoleFallback: true)?.progress == 55)
}

@Test func matchesMediaDownloadByContextMetadataID() throws {
    // CONFIRMED live shape: the conversion activity backing an offline download is
    // type "media.download" with Context.metadataID (no ratingKey), and a progress field.
    let json = """
    {"MediaContainer":{"size":1,"Activity":[
      {"uuid":"u","type":"media.download","cancellable":1,"progress":18,
       "title":"Converting","subtitle":"My Episode",
       "Context":{"deviceID":"d","metadataID":"101","partID":"55"}}
    ]}}
    """.data(using: .utf8)!
    let a = try JSONDecoder().decode(Activities.self, from: json)
    let act = try #require(a.activities.first)
    #expect(act.looksLikeOptimize)              // media.download is recognized
    #expect(act.contextMetadataID == "101")
    #expect(act.correlationID == "101")
    let match = try #require(a.optimizeActivity(ratingKey: "101", title: "anything"))
    #expect(match.progress == 18)
    let shape = a.probeShape(ratingKey: " 101 ", title: "anything")
    #expect(shape["matched"] == "yes")
    #expect(shape["match_has_metadata_id"] == "1")
    #expect(shape["match_correlation_equal"] == "1")
}

@Test func decodesDoubleProgress() throws {
    let json = """
    {"MediaContainer":{"Activity":[{"type":"media.optimize","progress":37.9}]}}
    """.data(using: .utf8)!
    let a = try JSONDecoder().decode(Activities.self, from: json)
    #expect(a.activities.first?.progress == 37)
}

@Test func matchingHelperReturnsNilWhenNoOptimizers() throws {
    let json = """
    {"MediaContainer":{"Activity":[
      {"type":"library.update.section","progress":80}
    ]}}
    """.data(using: .utf8)!
    let a = try JSONDecoder().decode(Activities.self, from: json)
    #expect(a.optimizeActivity(ratingKey: "101", title: "T", allowSoleFallback: true) == nil)
}

@Test func probeShapeOmitsTitleValues() throws {
    let json = """
    {"MediaContainer":{"Activity":[
      {"type":"media.optimize","title":"Blade Runner","subtitle":"Secret Library","progress":37,
       "uuid":"u","Context":{"ratingKey":"101"}}
    ]}}
    """.data(using: .utf8)!
    let a = try JSONDecoder().decode(Activities.self, from: json)
    let shape = a.probeShape(ratingKey: "101", title: "Blade Runner")
    // Structural facts only — no media-title VALUES anywhere in the probe payload.
    let serialized = shape.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
    #expect(!serialized.contains("Blade Runner"))
    #expect(!serialized.contains("Secret Library"))
    #expect(shape["match_progress"] == "37")
    #expect(shape["match_has_title"] == "1")
    #expect(shape["matched"] == "yes")
    #expect(shape["optimize_count"] == "1")
}
