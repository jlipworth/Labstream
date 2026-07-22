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
        static let allowCellularDownloads = "allowCellularDownloads"
        static let prioritizeQuickDownloads = "prioritizeQuickDownloads"
        static let systemMediaSuggestionsEnabled = "systemMediaSuggestionsEnabled"
        // GH #196: experimental Dolby Vision signalling (dvh1 profile advertising + HLS
        // playlist injection). Default false; nothing DV-signalled ships default-on until
        // device-verified. Also defers the DV P5 tone-map guard when enabled.
        static let experimentalDVSignalling = "experimentalDVSignalling"

        // Audio/subtitle language + subtitle-handling keys (formerly the separate
        // `PlaybackPreferenceKeys` namespace). Raw strings preserved exactly so existing
        // @AppStorage declarations and persisted values are untouched.
        static let preferredAudioLanguage = "preferredAudioLanguage"
        static let preferredSubtitleLanguage = "preferredSubtitleLanguage"
        static let subtitlesOff = "subtitlesOff"
        static let subtitleAutoSelectMode = "subtitleAutoSelectMode"
        static let subtitleBurnMode = "subtitleBurnMode"
        static let mobileVideoDisplayMode = "mobileVideoDisplayMode"
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
    /// Off by default on mobile so a tap-to-download cannot unexpectedly consume a cellular plan.
    static let defaultAllowCellularDownloads = false
    /// Off by default: the move PUT reorders the user's server-wide conversion queue and is
    /// admin-gated, so it is opt-in (least surprising — respect the server's queue order).
    static let defaultPrioritizeQuickDownloads = false
    /// On by default to preserve existing #24 behavior, but user-visible because it exposes
    /// browsed media titles to system search/Siri/Shortcuts surfaces outside Labstream.
    static let defaultSystemMediaSuggestionsEnabled = true

    static func systemMediaSuggestionsEnabled(defaults: UserDefaults = .standard) -> Bool {
        TypedPreferenceStore(defaults: defaults).value(for: .bool(
            Keys.systemMediaSuggestionsEnabled, default: defaultSystemMediaSuggestionsEnabled))
    }

    /// Whether a newly-enqueued optimize job should jump ahead of pending conversions (but never
    /// the one currently transcoding). When false, the server's queue order is respected and no
    /// reorder PUT is issued.
    static func prioritizeQuickDownloads(defaults: UserDefaults = .standard) -> Bool {
        TypedPreferenceStore(defaults: defaults).value(for: .bool(
            Keys.prioritizeQuickDownloads, default: defaultPrioritizeQuickDownloads))
    }

    /// Whether new background/download URLSession tasks may use cellular data.
    ///
    /// Existing active/resume-data tasks keep the policy archived when they were created;
    /// `BackgroundDownloadSession` stamps this setting onto each fresh URLRequest task.
    static func allowsCellularDownloads(defaults: UserDefaults = .standard) -> Bool {
        TypedPreferenceStore(defaults: defaults).value(for: .bool(
            Keys.allowCellularDownloads, default: defaultAllowCellularDownloads))
    }

    static func qualityKbps(forDefaultsKey key: String, defaults: UserDefaults = .standard) -> Int {
        let store = TypedPreferenceStore(defaults: defaults)
        let fallback = key == Keys.homeQualityKbps ? defaultHomeQualityKbps : defaultRemoteQualityKbps
        let typedKey = PreferenceKey<Int>.integer(key, default: fallback)
        if store.contains(typedKey) { return store.value(for: typedKey) }
        if key == Keys.remoteQualityKbps, defaults.object(forKey: Keys.legacyQualityKbps) != nil {
            return defaults.integer(forKey: Keys.legacyQualityKbps)
        }
        return fallback
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
        TypedPreferenceStore(defaults: defaults).value(for: .bool(
            Keys.adaptiveBitrateEnabled, default: defaultAdaptiveBitrateEnabled))
    }

    /// Download storage cap in bytes; `DownloadStorageLimit.unlimited` (0) when unset.
    static func downloadStorageLimitBytes(defaults: UserDefaults = .standard) -> Int {
        TypedPreferenceStore(defaults: defaults).value(for: .integer(
            Keys.downloadStorageLimitBytes, default: defaultStorageLimitBytes))
    }

    /// Countdown (seconds) shown on the Up Next card before it autoplays the next item.
    static func upNextCountdownSeconds(defaults: UserDefaults = .standard) -> Int {
        TypedPreferenceStore(defaults: defaults).value(for: .integer(
            Keys.upNextCountdownSeconds, default: defaultUpNextCountdownSeconds))
    }

    static func autoPlayUpNext(defaults: UserDefaults = .standard) -> Bool {
        TypedPreferenceStore(defaults: defaults).value(for: .bool(
            Keys.autoPlayUpNext, default: defaultAutoPlayUpNext))
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
    static let unlimited: Int = DownloadStorageLimitPolicy.unlimited
    static let options = DownloadStorageLimitPolicy.options

    static func label(bytes: Int) -> String {
        DownloadStorageLimitPolicy.label(bytes: bytes)
    }
}
