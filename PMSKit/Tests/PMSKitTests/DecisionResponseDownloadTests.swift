import Testing
import Foundation
@testable import PMSKit

// `playsWholeFileDirectly` (offline-download redesign): STRICTER than `savesVideoEncode`.
// True only when PMS plays the WHOLE file as-is (so the original file can be downloaded).
// Direct Stream (copy video / transcode audio) is NOT enough — it would need a rendered file.

@Test func wholeFileDirectViaMdeCode1000() throws {
    // Live shape: mdeDecisionCode 1000 + Part decision "directplay", per-stream nil.
    let json = """
    {"MediaContainer":{"mdeDecisionCode":1000,"mdeDecisionText":"Direct play OK.",
       "Metadata":[{"Media":[{"Part":[{"decision":"directplay","Stream":[
         {"streamType":1},{"streamType":2}
       ]}]}]}]
    }}
    """.data(using: .utf8)!
    let r = try JSONDecoder().decode(DecisionResponse.self, from: json)
    #expect(r.playsWholeFileDirectly == true)
    #expect(r.savesVideoEncode == true)        // regression guard: unchanged
}

@Test func wholeFileDirectViaGeneralCode1000() throws {
    let json = """
    {"MediaContainer":{"generalDecisionCode":1000,"generalDecisionText":"Direct Play"}}
    """.data(using: .utf8)!
    let r = try JSONDecoder().decode(DecisionResponse.self, from: json)
    #expect(r.decision == .directPlay)
    #expect(r.playsWholeFileDirectly == true)
}

@Test func wholeFileDirectViaPartDirectplayWithSpaces() throws {
    let json = """
    {"MediaContainer":{"Metadata":[{"Media":[{"Part":[{"decision":"Direct Play"}]}]}]}}
    """.data(using: .utf8)!
    let r = try JSONDecoder().decode(DecisionResponse.self, from: json)
    #expect(r.playsWholeFileDirectly == true)
}

@Test func directStreamDoesNotPlayWholeFileDirectly() throws {
    // Copy video / transcode audio: savesVideoEncode true, but NOT a whole-file direct play,
    // so a download must render a file (optimizer), not pull the original.
    let json = """
    {"MediaContainer":{"generalDecisionCode":1001,
       "mdeDecisionText":"Convert to HLS, copy video, transcode audio",
       "Metadata":[{"Media":[{"Part":[{"decision":"transcode","Stream":[
         {"streamType":1,"decision":"copy"},
         {"streamType":2,"decision":"transcode"}
       ]}]}]}]
    }}
    """.data(using: .utf8)!
    let r = try JSONDecoder().decode(DecisionResponse.self, from: json)
    #expect(r.savesVideoEncode == true)            // unchanged
    #expect(r.playsWholeFileDirectly == false)     // stricter
}

@Test func partLevelCopyDoesNotPlayWholeFileDirectly() throws {
    // Remux (part "copy"): saves the video encode, but is NOT a byte-for-byte original.
    let json = """
    {"MediaContainer":{"generalDecisionCode":1001,
       "Metadata":[{"Media":[{"Part":[{"decision":"copy"}]}]}]}}
    """.data(using: .utf8)!
    let r = try JSONDecoder().decode(DecisionResponse.self, from: json)
    #expect(r.savesVideoEncode == true)
    #expect(r.playsWholeFileDirectly == false)
}

@Test func fullTranscodeDoesNotPlayWholeFileDirectly() throws {
    let json = """
    {"MediaContainer":{"generalDecisionCode":1001,
       "Metadata":[{"Media":[{"Part":[{"decision":"transcode","Stream":[
         {"streamType":1,"decision":"transcode"},
         {"streamType":2,"decision":"transcode"}
       ]}]}]}]
    }}
    """.data(using: .utf8)!
    let r = try JSONDecoder().decode(DecisionResponse.self, from: json)
    #expect(r.playsWholeFileDirectly == false)
    #expect(r.savesVideoEncode == false)
}
