import Foundation
import PMSKit
import struct PMSKit.Stream
import Testing
@testable import Labstream

struct MediaBrowserPlaybackPreferencePolicyTests {
    @Test func initialAudioUsesMetadataDefaultWhenNoLanguagePreferenceExists() throws {
        let defaults = try makeDefaults()
        let item = itemWithAudioStreams([
            audio(id: 0, languageCode: "eng", isDefault: true),
            audio(id: 1, languageCode: "eng"),
        ])

        #expect(MediaBrowserPlaybackPreferencePolicy.initialAudioStreamIndex(
            for: item, defaults: defaults) == 0)
        #expect(MediaBrowserPlaybackPreferencePolicy.initialSelection(
            for: item, defaults: defaults).audioStreamIndex == 0)
    }

    @Test func initialAudioFallbackMatchesPickerSelectedDefaultFirstOrder() throws {
        let defaults = try makeDefaults()

        #expect(MediaBrowserPlaybackPreferencePolicy.initialAudioStreamIndex(
            for: itemWithAudioStreams([
                audio(id: 3, isDefault: true),
                audio(id: 8, selected: true),
            ]), defaults: defaults) == 8)
        #expect(MediaBrowserPlaybackPreferencePolicy.initialAudioStreamIndex(
            for: itemWithAudioStreams([
                audio(id: 3),
                audio(id: 8, isDefault: true),
            ]), defaults: defaults) == 8)
        #expect(MediaBrowserPlaybackPreferencePolicy.initialAudioStreamIndex(
            for: itemWithAudioStreams([
                audio(id: 3),
                audio(id: 8),
            ]), defaults: defaults) == 3)
    }

    @Test func savedLanguageOverridesMetadataDefaultAndUnmatchedLanguageFallsBack() throws {
        let defaults = try makeDefaults()
        let item = itemWithAudioStreams([
            audio(id: 0, languageCode: "eng", isDefault: true),
            audio(id: 4, languageCode: "spa"),
        ])

        defaults.set("es", forKey: PlaybackPreferences.Keys.preferredAudioLanguage)
        #expect(MediaBrowserPlaybackPreferencePolicy.initialAudioStreamIndex(
            for: item, defaults: defaults) == 4)

        defaults.set("de", forKey: PlaybackPreferences.Keys.preferredAudioLanguage)
        #expect(MediaBrowserPlaybackPreferencePolicy.initialAudioStreamIndex(
            for: item, defaults: defaults) == 0)
    }

    private func makeDefaults() throws -> UserDefaults {
        let suite = "MediaBrowserPlaybackPreferencePolicyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func itemWithAudioStreams(_ streams: [Stream]) -> MediaItem {
        MediaItem(ratingKey: "item-1", title: "Test", type: "movie", media: [
            Media(id: 1, part: [Part(id: 1, key: "/part/1", streams: streams)]),
        ])
    }

    private func audio(id: Int,
                       languageCode: String? = nil,
                       selected: Bool? = nil,
                       isDefault: Bool? = nil) -> Stream {
        Stream(id: id,
               streamType: StreamType.audio.rawValue,
               languageCode: languageCode,
               selected: selected,
               isDefault: isDefault)
    }
}
