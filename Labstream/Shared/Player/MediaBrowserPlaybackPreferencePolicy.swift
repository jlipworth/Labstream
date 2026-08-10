import Foundation
import PMSKit

struct MediaBrowserPlaybackStreamSelection: Sendable {
    let audioStreamIndex: Int?
    let subtitleStreamIndex: Int?
}

enum MediaBrowserPlaybackPreferencePolicy {
    /// Jellyfin/Emby treat an omitted subtitle stream as "server default": the server-side
    /// user profile's subtitle mode (Default/Smart/Always) then picks a stream itself and —
    /// on the burn-in path — bakes it into the video while the app's picker still shows
    /// "Off". So the wire value must never be "omitted": send this explicit off sentinel
    /// (both servers read -1 as "no subtitles") whenever no subtitle should be shown.
    static let subtitleOffStreamIndex = -1

    /// The MediaBrowser `MediaSourceId` represented by the detail screen's selected canonical
    /// `Media` entry. Jellyfin/Emby stream indices are scoped to one MediaSource, so this identity
    /// must travel with the selected audio/subtitle indices through every PlaybackInfo request.
    static func mediaSourceID(for item: MediaItem, mediaIndex: Int) -> String? {
        let selection = DownloadMediaSelectionPolicy.selection(item: item,
                                                               mediaIndex: mediaIndex,
                                                               partIndex: 0)
        return selection.mediaSourceID
    }

    static func initialSelection(for item: MediaItem,
                                 mediaIndex: Int = 0,
                                 defaults: UserDefaults = .standard) -> MediaBrowserPlaybackStreamSelection {
        MediaBrowserPlaybackStreamSelection(
            audioStreamIndex: initialAudioStreamIndex(for: item,
                                                      mediaIndex: mediaIndex,
                                                      defaults: defaults),
            subtitleStreamIndex: preferredSubtitleStreamIndex(for: item,
                                                              mediaIndex: mediaIndex,
                                                              defaults: defaults))
    }

    /// Resolve the concrete audio stream that the initial Jellyfin/Emby PlaybackInfo request
    /// must carry. Omitting `AudioStreamIndex` delegates selection to the server, which can pick
    /// a different track than the metadata-backed player picker displays. Prefer the saved
    /// language when it matches; otherwise mirror the picker's selected/default/first fallback.
    static func initialAudioStreamIndex(for item: MediaItem,
                                        mediaIndex: Int = 0,
                                        defaults: UserDefaults = .standard) -> Int? {
        if let preferred = preferredAudioStreamIndex(for: item,
                                                     mediaIndex: mediaIndex,
                                                     defaults: defaults) {
            return preferred
        }
        guard let part = sourcePart(for: item, mediaIndex: mediaIndex) else { return nil }
        let hasLanguagePreference = defaults.string(forKey: PlaybackPreferences.Keys.preferredAudioLanguage)
            .map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } == true
        let desiredRole = defaults.string(forKey: PlaybackPreferences.Keys.preferredAudioRole)
            .flatMap(AudioStreamRole.init(rawValue:)) ?? .main
        let fallbackStreams = hasLanguagePreference
            ? part.audioStreams.filter { $0.audioRole == desiredRole }
            : part.audioStreams
        return fallbackStream(in: fallbackStreams)?.id ?? fallbackStream(in: part.audioStreams)?.id
    }

    static func preferredAudioStreamIndex(for item: MediaItem,
                                          mediaIndex: Int = 0,
                                          defaults: UserDefaults = .standard) -> Int? {
        guard let preferred = defaults.string(forKey: PlaybackPreferences.Keys.preferredAudioLanguage),
              !preferred.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let part = sourcePart(for: item, mediaIndex: mediaIndex) else {
            return nil
        }
        let role = defaults.string(forKey: PlaybackPreferences.Keys.preferredAudioRole)
            .flatMap(AudioStreamRole.init(rawValue:)) ?? .main
        let matching = part.audioStreams.filter {
            languageMatches(languageTag: $0.languageTag,
                            languageCode: $0.languageCode,
                            language: $0.language,
                            preferredLanguage: preferred)
        }
        return bestStream(in: matching.filter { $0.audioRole == role })?.id
    }

    /// Resolve the subtitle stream index to send on a stream open/reopen. Always concrete —
    /// never nil/omit (see `subtitleOffStreamIndex`):
    ///   - explicit Off, or manual auto-select mode ("Subtitles stay off until selected in
    ///     the player") → the off sentinel;
    ///   - foreign-audio mode with a domestic audio track → the off sentinel;
    ///   - otherwise the first stream matching the saved subtitle language, or the off
    ///     sentinel when nothing matches.
    static func preferredSubtitleStreamIndex(for item: MediaItem,
                                             mediaIndex: Int = 0,
                                             defaults: UserDefaults = .standard) -> Int {
        if defaults.bool(forKey: PlaybackPreferences.Keys.subtitlesOff) {
            return subtitleOffStreamIndex
        }
        let mode = SubtitleAutoSelectMode(
            rawValue: defaults.string(forKey: PlaybackPreferences.Keys.subtitleAutoSelectMode) ?? "")
            ?? .manual
        guard mode != .manual,
              let part = sourcePart(for: item, mediaIndex: mediaIndex) else {
            return subtitleOffStreamIndex
        }
        if mode == .foreignAudio, !sourceAudioIsForeign(part: part, defaults: defaults) {
            return subtitleOffStreamIndex
        }
        guard let preferred = defaults.string(forKey: PlaybackPreferences.Keys.preferredSubtitleLanguage),
              !preferred.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return subtitleOffStreamIndex
        }
        let matching = part.subtitleStreams.filter {
            languageMatches(languageTag: $0.languageTag,
                            languageCode: $0.languageCode,
                            language: $0.language,
                            preferredLanguage: preferred)
        }
        let role: SubtitleStreamRole
        if mode == .foreignAudio {
            // Foreign-audio mode expresses forced/narrative intent. Do not silently promote
            // a full or accessibility caption track when a forced rendition is unavailable.
            role = .forced
        } else {
            role = defaults.string(forKey: PlaybackPreferences.Keys.preferredSubtitleRole)
                .flatMap(SubtitleStreamRole.init(rawValue:)) ?? .full
        }
        return bestStream(in: matching.filter { $0.subtitleRole == role })?.id
            ?? subtitleOffStreamIndex
    }

    /// Whether the source's active (selected/default/first) audio track differs from the
    /// user's preferred audio language — the trigger for the "Shown with Foreign Audio"
    /// subtitle mode. Internal so `PlaybackController` shares this single implementation.
    static func sourceAudioIsForeign(part: Part, defaults: UserDefaults) -> Bool {
        let preferredAudio = defaults.string(forKey: PlaybackPreferences.Keys.preferredAudioLanguage)
            ?? Locale.current.language.languageCode?.identifier
        guard let preferredAudio, !preferredAudio.isEmpty,
              let sourceAudio = part.audioStreams.first(where: { $0.selected == true })
                ?? part.audioStreams.first(where: { $0.isDefault == true })
                ?? part.audioStreams.first else {
            return false
        }
        return !languageMatches(languageTag: sourceAudio.languageTag,
                                languageCode: sourceAudio.languageCode,
                                language: sourceAudio.language,
                                preferredLanguage: preferredAudio)
    }

    private static func sourcePart(for item: MediaItem, mediaIndex: Int) -> Part? {
        let media = item.media.flatMap { mediaItems -> Media? in
            if mediaItems.indices.contains(mediaIndex) { return mediaItems[mediaIndex] }
            return mediaItems.first
        }
        return media?.part.first
    }

    /// Stable tie-breaking for same-language/same-role variants. Metadata order is the last
    /// authority only after the selected/default facts; id breaks otherwise identical fixtures.
    static func bestStream(in streams: [PlexStream]) -> PlexStream? {
        streams.enumerated().min { lhs, rhs in
            let l = (lhs.element.selected == true ? 0 : lhs.element.isDefault == true ? 1 : 2,
                     lhs.element.id, lhs.offset)
            let r = (rhs.element.selected == true ? 0 : rhs.element.isDefault == true ? 1 : 2,
                     rhs.element.id, rhs.offset)
            return l < r
        }?.element
    }

    private static func fallbackStream(in streams: [PlexStream]) -> PlexStream? {
        streams.first(where: { $0.selected == true })
            ?? streams.first(where: { $0.isDefault == true })
            ?? streams.first
    }

    /// Internal (not private) so `PlaybackController` shares this single implementation —
    /// it, `normalizedLanguageCodes`, and the ISO table were previously duplicated there.
    static func languageMatches(languageTag: String?,
                                languageCode: String?,
                                language: String?,
                                preferredLanguage: String) -> Bool {
        let preferred = normalizedLanguageCodes(for: preferredLanguage)
        guard !preferred.isEmpty else { return false }
        let candidates = [languageTag, languageCode, language]
            .compactMap { $0 }
            .flatMap { normalizedLanguageCodes(for: $0) }
        return candidates.contains { preferred.contains($0) }
    }

    private static func normalizedLanguageCodes(for raw: String) -> Set<String> {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return [] }
        let base = value.split(separator: "-").first.map(String.init) ?? value
        var codes: Set<String> = [value, base]
        if let twoLetter = iso639ThreeToTwo[base] {
            codes.insert(twoLetter)
        }
        if let localized = Locale.current.localizedString(forLanguageCode: base)?.lowercased() {
            codes.insert(localized)
        }
        return codes
    }

    private static let iso639ThreeToTwo: [String: String] = [
        "eng": "en", "spa": "es", "fre": "fr", "fra": "fr", "ger": "de", "deu": "de",
        "ita": "it", "por": "pt", "jpn": "ja", "kor": "ko", "chi": "zh", "zho": "zh",
        "dut": "nl", "nld": "nl", "swe": "sv", "nor": "no", "dan": "da", "fin": "fi",
    ]

    /// Normalize a track's language identifiers to the base two-letter code the Settings
    /// picker uses as its ids ("en", not "en-US"/"eng"/"English"). Persisting anything else
    /// still plays back correctly (`languageMatches` normalizes) but desyncs the Settings
    /// checkmark, which matches on the exact stored string. nil when no code-like value exists.
    static func persistableLanguageCode(languageTag: String?, languageCode: String?) -> String? {
        for raw in [languageTag, languageCode] {
            guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  !raw.isEmpty else { continue }
            let base = raw.split(separator: "-").first.map(String.init) ?? raw
            return iso639ThreeToTwo[base] ?? base
        }
        return nil
    }
}
