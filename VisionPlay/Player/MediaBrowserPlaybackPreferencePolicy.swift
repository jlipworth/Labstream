import Foundation
import PMSKit

struct MediaBrowserPlaybackStreamSelection: Sendable {
    let audioStreamIndex: Int?
    let subtitleStreamIndex: Int?
}

enum MediaBrowserPlaybackPreferencePolicy {
    /// Jellyfin treats an omitted subtitle stream as "server default". Use a concrete off sentinel
    /// when the user has explicitly disabled subtitles so PlaybackInfo and HLS reopens cannot
    /// silently inherit a server/default subtitle.
    static let subtitleOffStreamIndex = -1

    static func initialSelection(for item: MediaItem,
                                 mediaIndex: Int = 0,
                                 defaults: UserDefaults = .standard) -> MediaBrowserPlaybackStreamSelection {
        MediaBrowserPlaybackStreamSelection(
            audioStreamIndex: preferredAudioStreamIndex(for: item,
                                                        mediaIndex: mediaIndex,
                                                        defaults: defaults),
            subtitleStreamIndex: subtitleStreamIndex(defaults: defaults))
    }

    static func preferredAudioStreamIndex(for item: MediaItem,
                                          mediaIndex: Int = 0,
                                          defaults: UserDefaults = .standard) -> Int? {
        guard let preferred = defaults.string(forKey: PlaybackPreferences.Keys.preferredAudioLanguage),
              !preferred.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let part = sourcePart(for: item, mediaIndex: mediaIndex) else {
            return nil
        }
        return part.audioStreams.first {
            languageMatches(languageTag: $0.languageTag,
                            languageCode: $0.languageCode,
                            language: $0.language,
                            preferredLanguage: preferred)
        }?.id
    }

    static func subtitleStreamIndex(defaults: UserDefaults = .standard) -> Int? {
        defaults.bool(forKey: PlaybackPreferences.Keys.subtitlesOff)
            ? subtitleOffStreamIndex
            : nil
    }

    private static func sourcePart(for item: MediaItem, mediaIndex: Int) -> Part? {
        let media = item.media.flatMap { mediaItems -> Media? in
            if mediaItems.indices.contains(mediaIndex) { return mediaItems[mediaIndex] }
            return mediaItems.first
        }
        return media?.part.first
    }

    private static func languageMatches(languageTag: String?,
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
}
