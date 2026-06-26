import Foundation
import PMSKit

enum PlaybackPreferences {
    enum Keys {
        static let legacyQualityKbps = "maxVideoBitrateKbps"
        static let homeQualityKbps = "homeMaxVideoBitrateKbps"
        static let remoteQualityKbps = "remoteMaxVideoBitrateKbps"
        static let autoPlayUpNext = "playerAutoPlayUpNext"
        static let upNextCountdownSeconds = "playerUpNextCountdownSeconds"
        static let resumeRewindSeconds = "playerResumeRewindSeconds"
        static let skipIntroMode = "playerSkipIntroMode"
        static let skipCreditsMode = "playerSkipCreditsMode"
        static let adaptiveBitrateEnabled = "playerAdaptiveBitrateEnabled"
        static let defaultDownloadQuality = "defaultDownloadQuality"
        static let downloadStorageLimitBytes = "downloadStorageLimitBytes"
        static let prioritizeQuickDownloads = "prioritizeQuickDownloads"
        static let systemMediaSuggestionsEnabled = "systemMediaSuggestionsEnabled"

        // Audio/subtitle language + subtitle-handling keys (formerly the separate
        // `PlaybackPreferenceKeys` namespace). Raw strings preserved exactly so existing
        // @AppStorage declarations and persisted values are untouched.
        static let preferredAudioLanguage = "preferredAudioLanguage"
        static let preferredSubtitleLanguage = "preferredSubtitleLanguage"
        static let subtitlesOff = "subtitlesOff"
        static let subtitleAutoSelectMode = "subtitleAutoSelectMode"
        static let subtitleBurnMode = "subtitleBurnMode"
    }

    enum SkipMode: String, CaseIterable, Identifiable {
        case disabled
        case manual
        case automatic
        var id: String { rawValue }
        var label: String {
            switch self {
            case .disabled: return "Disabled"
            case .manual: return "Manual"
            case .automatic: return "Automatic"
            }
        }
    }

    static let defaultRemoteQualityKbps = 8_000
    static let defaultHomeQualityKbps = StreamingQuality.maximumOriginalKbps
    static let defaultUpNextCountdownSeconds = 10
    static let defaultAdaptiveBitrateEnabled = false
    static let defaultAutoPlayUpNext = true
    static let defaultSkipMode = SkipMode.manual
    static let defaultStorageLimitBytes = DownloadStorageLimit.unlimited
    static let defaultDownloadQuality = "1080p 8 Mbps"
    /// Off by default: the move PUT reorders the user's server-wide conversion queue and is
    /// admin-gated, so it is opt-in (least surprising — respect the server's queue order).
    static let defaultPrioritizeQuickDownloads = false
    /// On by default to preserve existing #24 behavior, but user-visible because it exposes
    /// browsed media titles to system search/Siri/Shortcuts surfaces outside VisionPlay.
    static let defaultSystemMediaSuggestionsEnabled = true

    static func systemMediaSuggestionsEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: Keys.systemMediaSuggestionsEnabled) != nil else {
            return defaultSystemMediaSuggestionsEnabled
        }
        return defaults.bool(forKey: Keys.systemMediaSuggestionsEnabled)
    }

    /// Whether a newly-enqueued optimize job should jump ahead of pending conversions (but never
    /// the one currently transcoding). When false, the server's queue order is respected and no
    /// reorder PUT is issued.
    static func prioritizeQuickDownloads(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: Keys.prioritizeQuickDownloads) != nil else {
            return defaultPrioritizeQuickDownloads
        }
        return defaults.bool(forKey: Keys.prioritizeQuickDownloads)
    }

    static func qualityKbps(forDefaultsKey key: String, defaults: UserDefaults = .standard) -> Int {
        if defaults.object(forKey: key) != nil { return defaults.integer(forKey: key) }
        if key == Keys.remoteQualityKbps, defaults.object(forKey: Keys.legacyQualityKbps) != nil {
            return defaults.integer(forKey: Keys.legacyQualityKbps)
        }
        return key == Keys.homeQualityKbps ? defaultHomeQualityKbps : defaultRemoteQualityKbps
    }

    static func setQualityKbps(_ kbps: Int, forDefaultsKey key: String, defaults: UserDefaults = .standard) {
        defaults.set(kbps, forKey: key)
        // The retired single-cap key maps to the conservative Internet/Remote cap. Do not
        // let Home/Local changes rewrite it, or older installs with no remote key yet can
        // accidentally inherit an unlimited/local value for remote playback.
        if key == Keys.remoteQualityKbps || key == Keys.legacyQualityKbps {
            defaults.set(kbps, forKey: Keys.legacyQualityKbps)
        }
    }

    static func migrateLegacyQualityIfNeeded(defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: Keys.remoteQualityKbps) == nil,
              defaults.object(forKey: Keys.legacyQualityKbps) != nil else { return }
        defaults.set(defaults.integer(forKey: Keys.legacyQualityKbps),
                     forKey: Keys.remoteQualityKbps)
    }

    static func adaptiveBitrateEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: Keys.adaptiveBitrateEnabled) != nil else {
            return defaultAdaptiveBitrateEnabled
        }
        return defaults.bool(forKey: Keys.adaptiveBitrateEnabled)
    }

    /// Download storage cap in bytes; `DownloadStorageLimit.unlimited` (0) when unset.
    static func downloadStorageLimitBytes(defaults: UserDefaults = .standard) -> Int {
        guard defaults.object(forKey: Keys.downloadStorageLimitBytes) != nil else {
            return defaultStorageLimitBytes
        }
        return defaults.integer(forKey: Keys.downloadStorageLimitBytes)
    }

    /// Countdown (seconds) shown on the Up Next card before it autoplays the next item.
    static func upNextCountdownSeconds(defaults: UserDefaults = .standard) -> Int {
        guard defaults.object(forKey: Keys.upNextCountdownSeconds) != nil else {
            return defaultUpNextCountdownSeconds
        }
        return defaults.integer(forKey: Keys.upNextCountdownSeconds)
    }

    static func autoPlayUpNext(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: Keys.autoPlayUpNext) != nil else {
            return defaultAutoPlayUpNext
        }
        return defaults.bool(forKey: Keys.autoPlayUpNext)
    }

    /// Skip behavior for an intro or credits marker. `intro == true` reads the intro key,
    /// otherwise the credits key; both default to `.manual`.
    static func skipMode(intro: Bool, defaults: UserDefaults = .standard) -> SkipMode {
        let key = intro ? Keys.skipIntroMode : Keys.skipCreditsMode
        let raw = defaults.string(forKey: key) ?? defaultSkipMode.rawValue
        return SkipMode(rawValue: raw) ?? defaultSkipMode
    }
}

enum DownloadStorageLimit {
    struct Option: Identifiable, Equatable {
        let bytes: Int
        let label: String
        var id: Int { bytes }
    }

    static let unlimited: Int = 0
    static let options: [Option] = [
        .init(bytes: unlimited, label: "Unlimited"),
        .init(bytes: 10 * 1_000_000_000, label: "10 GB"),
        .init(bytes: 25 * 1_000_000_000, label: "25 GB"),
        .init(bytes: 50 * 1_000_000_000, label: "50 GB"),
        .init(bytes: 100 * 1_000_000_000, label: "100 GB"),
        .init(bytes: 250 * 1_000_000_000, label: "250 GB"),
    ]

    static func label(bytes: Int) -> String {
        if let option = options.first(where: { $0.bytes == bytes }) { return option.label }
        if bytes <= 0 { return "Unlimited" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
