import Foundation
import Testing
@testable import PMSKit

@Suite("Cross-backend stream roles")
struct StreamRoleMappingTests {
    @Test func plexExplicitRoleFlagsWinOverDisplayTitles() throws {
        let json = """
        {"id":1,"streamType":2,"languageCode":"eng","displayTitle":"English",
         "commentary":true,"visualImpaired":false}
        """
        let stream = try JSONDecoder().decode(Stream.self, from: Data(json.utf8))
        #expect(stream.audioRole == .commentary)
        #expect(stream.pickerLabel(fallback: "Track") == "English (Commentary)")

        let subtitleJSON = """
        {"id":2,"streamType":3,"languageCode":"eng","displayTitle":"English",
         "hearingImpaired":true,"forced":false,"external":true,"textSubtitle":true}
        """
        let subtitle = try JSONDecoder().decode(Stream.self, from: Data(subtitleJSON.utf8))
        #expect(subtitle.subtitleRole == .hearingImpaired)
        #expect(subtitle.pickerLabel(fallback: "Subtitle") == "English (SDH/CC) (External) (Text)")
    }

    @Test func jellyfinAndEmbyExplicitFactsBridgeToCanonicalStreams() throws {
        let jellyfin = try decodeMediaBrowser("""
        {"Index":4,"Type":"Subtitle","Codec":"srt","Language":"eng","DisplayTitle":"English",
         "IsForced":true,"IsHearingImpaired":false,"IsExternal":true,"IsTextSubtitleStream":true}
        """)
        let jellyfinStream = try #require(jellyfin.toCanonicalStream(fallbackID: 1))
        #expect(jellyfinStream.subtitleRole == .forced)
        #expect(jellyfinStream.external == true)
        #expect(jellyfinStream.textSubtitle == true)

        let emby = try decodeMediaBrowser("""
        {"Index":2,"Type":"Audio","Language":"eng","DisplayTitle":"English",
         "IsCommentary":false,"IsVisualImpaired":true,"IsDefault":true,"IsSelected":true}
        """)
        let embyStream = try #require(emby.toCanonicalStream(fallbackID: 1))
        #expect(embyStream.audioRole == .audioDescription)
        #expect(embyStream.isDefault == true)
        #expect(embyStream.selected == true)
    }

    @Test func titleParsingIsOnlyFallbackAndOfflineTrackKeepsRole() throws {
        let legacy = Stream(id: 7, streamType: StreamType.audio.rawValue,
                            languageCode: "eng", title: "Director Commentary")
        #expect(legacy.audioRole == .commentary)
        let explicit = Stream(id: 8, streamType: StreamType.audio.rawValue,
                              displayTitle: "Director Commentary", commentary: false)
        // An explicit backend fact wins over a contradictory display title.
        #expect(explicit.audioRole == .main)
        let explicitMain = Stream(id: 10, streamType: StreamType.audio.rawValue,
                                  displayTitle: "Director Commentary", visualImpaired: false,
                                  commentary: false)
        #expect(explicitMain.audioRole == .main)

        let subtitle = Stream(id: 9, streamType: StreamType.subtitle.rawValue,
                              codec: "srt", languageCode: "eng", forced: true, external: true,
                              textSubtitle: true)
        let track = try #require(OfflineTextSubtitleCachePlanner.track(
            for: subtitle, relativePath: "fixture.sub.9.srt", fallbackIndex: 0))
        #expect(track.role == .forced)
        #expect(track.displayName.contains("Forced"))
    }

    private func decodeMediaBrowser(_ json: String) throws -> MediaBrowserItemMediaStreamDto {
        try JSONDecoder().decode(MediaBrowserItemMediaStreamDto.self, from: Data(json.utf8))
    }
}
