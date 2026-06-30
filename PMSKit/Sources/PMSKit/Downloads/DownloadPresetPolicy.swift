import Foundation

/// Pure download-preset catalog and mapping policy shared by Plex optimize, MediaBrowser
/// transcode/remux, storage preflight, and offline row labels.
///
/// The app layer still owns server target discovery and request side effects; this type owns the
/// durable meaning of labels such as "Original video quality", bitrate ladder presets, Plex fallback
/// media settings, and Jellyfin/Emby transcode caps.
public enum DownloadPresetPolicy {
    public struct CustomDownloadProfile: Sendable, Equatable {
        public let name: String
        public let deviceProfile: String
        public let settings: OptimizeRequest.MediaSettings

        public init(name: String, deviceProfile: String, settings: OptimizeRequest.MediaSettings) {
            self.name = name
            self.deviceProfile = deviceProfile
            self.settings = settings
        }
    }

    public struct JellyfinTranscodeProfile: Sendable, Equatable {
        public let videoBitrateBps: Int
        public let maxWidth: Int?
        public let maxHeight: Int?

        public init(videoBitrateBps: Int, maxWidth: Int?, maxHeight: Int?) {
            self.videoBitrateBps = videoBitrateBps
            self.maxWidth = maxWidth
            self.maxHeight = maxHeight
        }
    }

    public static let compatibleOriginalQualityName = "Original video quality"
    public static let plexOriginalQualityTargetName = "Original Quality"
    public static let jellyfinDefaultDownloadPreset = "1080p 8 Mbps"

    public static let customDownloadProfiles: [CustomDownloadProfile] = [
        .init(name: "4K 40 Mbps", deviceProfile: "Universal TV",
              settings: .init(videoQuality: 100, maxVideoBitrateKbps: 40_000, videoResolution: "3840x2160")),
        .init(name: "1080p 20 Mbps", deviceProfile: "Universal TV",
              settings: .init(videoQuality: 100, maxVideoBitrateKbps: 20_000, videoResolution: "1920x1080")),
        .init(name: "1080p 12 Mbps", deviceProfile: "Universal TV",
              settings: .init(videoQuality: 90, maxVideoBitrateKbps: 12_000, videoResolution: "1920x1080")),
        .init(name: "1080p 10 Mbps", deviceProfile: "Universal TV",
              settings: .init(videoQuality: 75, maxVideoBitrateKbps: 10_000, videoResolution: "1920x1080")),
        .init(name: "1080p 8 Mbps", deviceProfile: "Universal TV",
              settings: .init(videoQuality: 60, maxVideoBitrateKbps: 8_000, videoResolution: "1920x1080")),
        .init(name: "720p 4 Mbps", deviceProfile: "Universal TV",
              settings: .init(videoQuality: 100, maxVideoBitrateKbps: 4_000, videoResolution: "1280x720")),
        .init(name: "720p 3 Mbps", deviceProfile: "Universal TV",
              settings: .init(videoQuality: 75, maxVideoBitrateKbps: 3_000, videoResolution: "1280x720")),
        .init(name: "720p 2 Mbps", deviceProfile: "Universal TV",
              settings: .init(videoQuality: 60, maxVideoBitrateKbps: 2_000, videoResolution: "1280x720")),
        .init(name: "480p 1.5 Mbps", deviceProfile: "Universal Mobile",
              settings: .init(videoQuality: 60, maxVideoBitrateKbps: 1_500, videoResolution: "720x480")),
    ]

    public static var customDownloadProfileNames: [String] {
        [compatibleOriginalQualityName] + customDownloadProfiles.map(\.name)
    }

    /// Bitrate-only presets shared by Jellyfin/Emby transcode pickers. These backends do not have
    /// Plex's server-side "Original video quality" optimize queue; source-quality preservation is
    /// represented by the separate compatible-remux lane instead.
    public static var bitratePresetNames: [String] {
        customDownloadProfiles.map(\.name)
    }

    public static func customDownloadProfile(named name: String) -> CustomDownloadProfile? {
        customDownloadProfiles.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
    }

    public static func isPlexOriginalQualityTarget(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.localizedCaseInsensitiveCompare(compatibleOriginalQualityName) == .orderedSame
            || trimmed.localizedCaseInsensitiveCompare(plexOriginalQualityTargetName) == .orderedSame
    }

    public static func isExplicitDownloadPresetName(_ name: String) -> Bool {
        isPlexOriginalQualityTarget(name) || customDownloadProfile(named: name) != nil
    }

    public static func isVisibleDownloadPresetName(_ name: String) -> Bool {
        ![
            plexOriginalQualityTargetName,
            "Optimized for TV",
            "Optimized for Mobile",
        ].contains { hidden in
            name.localizedCaseInsensitiveCompare(hidden) == .orderedSame
        }
    }

    /// The visible source-quality Plex optimize preset, if the current preset list contains one.
    public static func plexOriginalQualityPreset(in presets: [String]) -> String? {
        presets.first { isPlexOriginalQualityTarget($0) }
    }

    /// Remove the source-quality Plex optimize helper from the normal bitrate section. The sheet
    /// renders it as its own "Original quality" row so it is not visually mixed with bitrate caps.
    public static func presetsExcludingPlexOriginalQuality(_ presets: [String]) -> [String] {
        guard plexOriginalQualityPreset(in: presets) != nil else { return presets }
        return presets.filter { !isPlexOriginalQualityTarget($0) }
    }

    /// Preferred initial picker choice for the download sheet. Existing server versions are never
    /// defaulted: they are explicit alternates below the normal quality choices.
    public static func preferredPickerChoice(originalAvailable: Bool,
                                             compatibleRemuxAvailable: Bool,
                                             presets: [String],
                                             backend: DownloadBackendKind,
                                             defaultDownloadQuality: String) -> DownloadIntentChoice? {
        if originalAvailable { return .original }
        if backend == .plex, let plexOriginal = plexOriginalQualityPreset(in: presets) {
            return .optimize(targetName: plexOriginal)
        }
        if compatibleRemuxAvailable { return .optimizeCompatible }
        if presets.contains(defaultDownloadQuality) { return .optimize(targetName: defaultDownloadQuality) }
        if let match = presets.first(where: { $0.localizedCaseInsensitiveContains(defaultDownloadQuality) }) {
            return .optimize(targetName: match)
        }
        return presets.first.map { .optimize(targetName: $0) }
    }

    /// Merge live Plex target names with the app's explicit quality ladder, preserving first-seen
    /// spelling/order, removing case-insensitive duplicates, hiding generic Plex labels, and dropping
    /// empty names before the picker sees them.
    public static func visiblePresetNames(serverTargets: [String]) -> [String] {
        dedup(serverTargets + customDownloadProfileNames)
            .filter(isVisibleDownloadPresetName)
            .filter { !$0.isEmpty }
    }

    /// Resolution label to store/display on the offline row for a user's choice.
    ///
    /// Server-prepared bitrate ladder targets display the target resolution. Direct-original and
    /// Original-quality targets display the source resolution because they do not intentionally
    /// downscale video.
    public static func displayResolutionLabel(choice: DownloadIntentChoice, chosenMedia: Media?) -> String? {
        let sourceLabel = resolutionLabel(for: chosenMedia)
        guard case .optimize(let targetName) = choice else { return sourceLabel }
        let videoResolution = customDownloadProfile(named: targetName)?.settings.videoResolution
            ?? mediaSettings(forTargetName: targetName).videoResolution
        guard let videoResolution else { return sourceLabel }
        return DownloadResolutionLabel.label(forVideoResolution: videoResolution) ?? sourceLabel
    }

    public static func resolutionLabel(for media: Media?) -> String? {
        guard let media else { return nil }
        return DownloadResolutionLabel.label(width: media.width, height: media.height)
    }

    /// Media source semantics for storage preflight. Existing server versions and compatible remuxes
    /// are static/source-sized; bitrate ladder choices use duration × target bitrate.
    public static func storageEstimateMediaSource(for choice: DownloadIntentChoice) -> DownloadStorageEstimatePolicy.MediaSource {
        switch choice {
        case .original, .existingVersion, .optimizeCompatible:
            return .sourceFile
        case .optimize(let targetName):
            if isPlexOriginalQualityTarget(targetName) {
                return .sourceFile
            }
            if let profile = customDownloadProfile(named: targetName) {
                guard let kbps = profile.settings.maxVideoBitrateKbps else { return .sourceFile }
                return .transcode(videoBitrateBps: kbps * 1_000)
            }
            let bitrate = mediaSettings(forTargetName: targetName).maxVideoBitrateKbps
                .map { $0 * 1_000 } ?? 8_000_000
            return .transcode(videoBitrateBps: bitrate)
        }
    }

    public static func estimatedTranscodeBytes(for record: DownloadRecord) -> Int? {
        if record.metadata?.resolvedDownloadLane() == .compatibleRemux,
           let size = record.metadata?.sourcePartSize,
           size > 0 {
            // Compatible remux copies the source video and usually transcodes only audio/container,
            // so the original source part size is the closest expected-total estimate.
            return size
        }
        guard let targetName = record.metadata?.optimizeTargetName, !targetName.isEmpty else {
            return nil
        }
        let profile = jellyfinTranscodeProfile(named: targetName)
        return TranscodeSizeEstimator.bytes(durationMs: record.metadata?.duration,
                                            videoBitrateBps: profile.videoBitrateBps)
    }

    public static func jellyfinDownloadPreset(named name: String) -> String {
        // Jellyfin does not have Plex's server-side "Original video quality" optimize queue. If a row
        // was written with that global/default label, retry via the explicit bitrate ladder so
        // Jellyfin still produces an MP4-compatible transcoded download.
        customDownloadProfile(named: name)?.settings.maxVideoBitrateKbps == nil
            ? jellyfinDefaultDownloadPreset
            : name
    }

    public static func jellyfinTranscodeProfile(named name: String) -> JellyfinTranscodeProfile {
        let settings = customDownloadProfile(named: jellyfinDownloadPreset(named: name))?.settings
        let bitrateKbps = settings?.maxVideoBitrateKbps ?? 8_000
        let resolution = settings?.videoResolution
        let dimensions = resolution?
            .lowercased()
            .split(separator: "x")
            .compactMap { Int($0) }
        let width = dimensions?.indices.contains(0) == true ? dimensions?[0] : nil
        let height = dimensions?.indices.contains(1) == true ? dimensions?[1] : nil
        return JellyfinTranscodeProfile(videoBitrateBps: bitrateKbps * 1_000,
                                        maxWidth: width,
                                        maxHeight: height)
    }

    /// Conventional Plex target tag ids. The live server's ids still win when target discovery
    /// resolves them; this is the fallback only.
    public static func conventionalPlexTagID(forName name: String) -> Int {
        switch name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "optimized for mobile": return 1
        case "original quality", "original video quality": return 3
        default: return 2
        }
    }

    /// Best-known render settings per Plex preset name. The server preset governs when live target
    /// discovery provides more specific data.
    public static func mediaSettings(forTargetName name: String) -> OptimizeRequest.MediaSettings {
        switch name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "optimized for mobile":
            return .init(videoQuality: 100, maxVideoBitrateKbps: 2_000, videoResolution: "1280x720")
        case "original quality", "original video quality":
            return .init(videoQuality: 100, maxVideoBitrateKbps: nil, videoResolution: nil)
        default:
            return .init(videoQuality: 100, maxVideoBitrateKbps: 8_000, videoResolution: "1920x1080")
        }
    }

    private static func dedup(_ names: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for name in names {
            let key = name.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(name)
        }
        return result
    }
}
