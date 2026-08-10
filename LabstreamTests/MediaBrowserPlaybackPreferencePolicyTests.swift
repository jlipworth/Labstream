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

    @Test func multiVersionSelectionKeepsSourceIdentityAndStreamIndicesTogether() throws {
        let defaults = try makeDefaults()
        defaults.set(SubtitleAutoSelectMode.always.rawValue,
                     forKey: PlaybackPreferences.Keys.subtitleAutoSelectMode)
        defaults.set("da", forKey: PlaybackPreferences.Keys.preferredSubtitleLanguage)
        let item = MediaItem(ratingKey: "item-1", title: "Test", type: "movie", media: [
            Media(id: 1, part: [Part(id: 1,
                                    key: "emby://item/item-1/media/alternate",
                                    streams: [audio(id: 2, isDefault: true),
                                              subtitle(id: 3, languageCode: "eng")])]),
            Media(id: 2, part: [Part(id: 2,
                                    key: "emby://item/item-1/media/selected",
                                    streams: [audio(id: 12, isDefault: true),
                                              subtitle(id: 19, languageCode: "dan")])]),
        ])

        #expect(MediaBrowserPlaybackPreferencePolicy.mediaSourceID(for: item, mediaIndex: 1) == "selected")
        let selected = MediaBrowserPlaybackPreferencePolicy.initialSelection(
            for: item, mediaIndex: 1, defaults: defaults)
        #expect(selected.audioStreamIndex == 12)
        #expect(selected.subtitleStreamIndex == 19)
        #expect(MediaBrowserPlaybackPreferencePolicy.initialAudioStreamIndex(
            for: item, mediaIndex: 0, defaults: defaults) == 2)
    }

    @Test func ordinaryAudioPreferenceRejectsCommentaryAndDescriptionDeterministically() throws {
        let defaults = try makeDefaults()
        defaults.set("en", forKey: PlaybackPreferences.Keys.preferredAudioLanguage)
        let item = itemWithAudioStreams([
            audio(id: 8, languageCode: "eng", commentary: true, isDefault: true),
            audio(id: 7, languageCode: "eng", visualImpaired: true),
            audio(id: 4, languageCode: "eng"),
            audio(id: 2, languageCode: "eng"),
        ])
        #expect(MediaBrowserPlaybackPreferencePolicy.preferredAudioStreamIndex(
            for: item, defaults: defaults) == 2)
    }

    @Test func explicitAudioRoleSurvivesSameLanguageOnLaterItem() throws {
        let defaults = try makeDefaults()
        defaults.set("en", forKey: PlaybackPreferences.Keys.preferredAudioLanguage)
        defaults.set(AudioStreamRole.commentary.rawValue,
                     forKey: PlaybackPreferences.Keys.preferredAudioRole)
        let item = itemWithAudioStreams([
            audio(id: 1, languageCode: "eng"),
            audio(id: 9, languageCode: "eng", commentary: true),
        ])
        #expect(MediaBrowserPlaybackPreferencePolicy.preferredAudioStreamIndex(
            for: item, defaults: defaults) == 9)
    }

    @Test func subtitleModesRespectRolesAndManualOff() throws {
        let defaults = try makeDefaults()
        defaults.set("en", forKey: PlaybackPreferences.Keys.preferredAudioLanguage)
        defaults.set("en", forKey: PlaybackPreferences.Keys.preferredSubtitleLanguage)
        let item = itemWithAudioStreams([
            audio(id: 1, languageCode: "jpn", isDefault: true),
            subtitle(id: 8, languageCode: "eng", hearingImpaired: true),
            subtitle(id: 6, languageCode: "eng"),
            subtitle(id: 7, languageCode: "eng", forced: true),
        ])
        #expect(MediaBrowserPlaybackPreferencePolicy.preferredSubtitleStreamIndex(
            for: item, defaults: defaults) == MediaBrowserPlaybackPreferencePolicy.subtitleOffStreamIndex)

        defaults.set(SubtitleAutoSelectMode.foreignAudio.rawValue,
                     forKey: PlaybackPreferences.Keys.subtitleAutoSelectMode)
        #expect(MediaBrowserPlaybackPreferencePolicy.preferredSubtitleStreamIndex(
            for: item, defaults: defaults) == 7)

        defaults.set(SubtitleAutoSelectMode.always.rawValue,
                     forKey: PlaybackPreferences.Keys.subtitleAutoSelectMode)
        defaults.set(SubtitleStreamRole.hearingImpaired.rawValue,
                     forKey: PlaybackPreferences.Keys.preferredSubtitleRole)
        #expect(MediaBrowserPlaybackPreferencePolicy.preferredSubtitleStreamIndex(
            for: item, defaults: defaults) == 8)
    }

    @Test func foreignAudioDoesNotSubstituteFullCaptionsWhenForcedIsMissing() throws {
        let defaults = try makeDefaults()
        defaults.set("en", forKey: PlaybackPreferences.Keys.preferredAudioLanguage)
        defaults.set("en", forKey: PlaybackPreferences.Keys.preferredSubtitleLanguage)
        defaults.set(SubtitleAutoSelectMode.foreignAudio.rawValue,
                     forKey: PlaybackPreferences.Keys.subtitleAutoSelectMode)
        let item = itemWithAudioStreams([
            audio(id: 1, languageCode: "jpn", isDefault: true),
            subtitle(id: 2, languageCode: "eng"),
        ])
        #expect(MediaBrowserPlaybackPreferencePolicy.preferredSubtitleStreamIndex(
            for: item, defaults: defaults) == MediaBrowserPlaybackPreferencePolicy.subtitleOffStreamIndex)
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
                       commentary: Bool? = nil,
                       visualImpaired: Bool? = nil,
                       isDefault: Bool? = nil) -> Stream {
        Stream(id: id,
               streamType: StreamType.audio.rawValue,
               languageCode: languageCode,
               selected: selected,
               isDefault: isDefault,
               visualImpaired: visualImpaired,
               commentary: commentary)
    }

    private func subtitle(id: Int, languageCode: String,
                          forced: Bool? = nil,
                          hearingImpaired: Bool? = nil) -> Stream {
        Stream(id: id,
               streamType: StreamType.subtitle.rawValue,
               languageCode: languageCode,
               forced: forced,
               hearingImpaired: hearingImpaired)
    }
}
