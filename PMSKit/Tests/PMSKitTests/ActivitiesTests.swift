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
    let match = try #require(a.optimizeActivity(ratingKey: "101", queueTitle: "Blade Runner"))
    #expect(match.progress == 42)
    #expect(match.contextRatingKey == "101")
}

@Test func matchingHelperFallsBackToTitle() throws {
    let json = """
    {"MediaContainer":{"Activity":[
      {"type":"media.optimize","title":"Optimizing Blade Runner (1982)","progress":42}
    ]}}
    """.data(using: .utf8)!
    let a = try JSONDecoder().decode(Activities.self, from: json)
    // No Context.ratingKey; match on queue title substring.
    let match = try #require(a.optimizeActivity(ratingKey: "101", queueTitle: "Blade Runner"))
    #expect(match.progress == 42)
}

@Test func matchingHelperTakesSoleOptimizerWhenAmbiguous() throws {
    let json = """
    {"MediaContainer":{"Activity":[
      {"type":"library.update.section","progress":80},
      {"type":"media.optimize","progress":17}
    ]}}
    """.data(using: .utf8)!
    let a = try JSONDecoder().decode(Activities.self, from: json)
    // ratingKey/title don't match, but a single optimize job is running.
    let match = try #require(a.optimizeActivity(ratingKey: "nope", queueTitle: "nope"))
    #expect(match.progress == 17)
}

@Test func matchingHelperReturnsNilWhenNoOptimizers() throws {
    let json = """
    {"MediaContainer":{"Activity":[
      {"type":"library.update.section","progress":80}
    ]}}
    """.data(using: .utf8)!
    let a = try JSONDecoder().decode(Activities.self, from: json)
    #expect(a.optimizeActivity(ratingKey: "101", queueTitle: "T") == nil)
}

@Test func probeShapeOmitsTitleValues() throws {
    let json = """
    {"MediaContainer":{"Activity":[
      {"type":"media.optimize","title":"Blade Runner","subtitle":"Secret Library","progress":37,
       "uuid":"u","Context":{"ratingKey":"101"}}
    ]}}
    """.data(using: .utf8)!
    let a = try JSONDecoder().decode(Activities.self, from: json)
    let shape = a.probeShape(ratingKey: "101", queueTitle: "Blade Runner")
    // Structural facts only — no media-title VALUES anywhere in the probe payload.
    let serialized = shape.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
    #expect(!serialized.contains("Blade Runner"))
    #expect(!serialized.contains("Secret Library"))
    #expect(shape["match_progress"] == "37")
    #expect(shape["match_has_title"] == "1")
    #expect(shape["matched"] == "yes")
    #expect(shape["optimize_count"] == "1")
}
