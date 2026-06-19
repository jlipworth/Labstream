import Foundation

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
    static let defaultDownloadQuality = "1080p 8 Mbps"

    static func qualityKbps(forDefaultsKey key: String) -> Int {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: key) != nil { return defaults.integer(forKey: key) }
        if key == Keys.remoteQualityKbps, defaults.object(forKey: Keys.legacyQualityKbps) != nil {
            return defaults.integer(forKey: Keys.legacyQualityKbps)
        }
        return key == Keys.homeQualityKbps ? defaultHomeQualityKbps : defaultRemoteQualityKbps
    }

    static func setQualityKbps(_ kbps: Int, forDefaultsKey key: String) {
        let defaults = UserDefaults.standard
        defaults.set(kbps, forKey: key)
        // The retired single-cap key maps to the conservative Internet/Remote cap. Do not
        // let Home/Local changes rewrite it, or older installs with no remote key yet can
        // accidentally inherit an unlimited/local value for remote playback.
        if key == Keys.remoteQualityKbps || key == Keys.legacyQualityKbps {
            defaults.set(kbps, forKey: Keys.legacyQualityKbps)
        }
    }

    static func migrateLegacyQualityIfNeeded() {
        let defaults = UserDefaults.standard
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
