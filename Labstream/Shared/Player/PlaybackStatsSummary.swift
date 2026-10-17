import Foundation
import PMSKit

/// Presentation model for the player Stats panel (#331).
///
/// The panel is a "signal chain": what the server file is, what the server does to it
/// (direct / copy / encode), and what reaches this device, followed by buffer, bitrate,
/// connection, and track tiles. The expanded view keeps every diagnostic row the old
/// "Stats for Nerds" grid showed, grouped into Video / Audio / Network sections.
///
/// Built from `PlaybackDiagnostics` without changing any metric semantics. Path color in the
/// view means only one thing — how the server handles the stream — and `isProblem` is reserved
/// for real playback trouble (stalls), never for an invented threshold.
struct PlaybackStatsSummary: Equatable {
    enum Path: String, Equatable {
        case direct, copy, encode

        init(lane: PlaybackExplanationLane) {
            switch lane {
            case .directPlay: self = .direct
            case .directStream, .audioOnlyTranscode: self = .copy
            case .videoTranscode, .unknownTranscode: self = .encode
            }
        }

        var title: String {
            switch self {
            case .direct: "Direct play"
            case .copy: "Copying video"
            case .encode: "Transcoding"
            }
        }

        /// The short word on the chain link between the two nodes.
        var linkLabel: String {
            switch self {
            case .direct: "Direct"
            case .copy: "Copy"
            case .encode: "Encode"
            }
        }
    }

    /// One value in a chain node. `converted` marks a value the server changed (and is drawn in
    /// the path color); it is false for everything the device receives untouched.
    struct Spec: Equatable {
        var value: String
        var converted = false
    }

    struct Node: Equatable {
        var video: Spec
        var hdr: Spec
        var audio: Spec
    }

    struct Tile: Equatable {
        var label: String
        var value: String
        var context: String
        var isProblem = false
        /// Optional SF Symbol drawn before the context line (e.g. the throughput arrow).
        var contextSymbol: String?
        var accessibilityContext: String?
    }

    struct Row: Equatable {
        var label: String
        var value: String
    }

    struct Group: Equatable {
        var title: String
        var rows: [Row]
    }

    enum Section: String, CaseIterable, Identifiable {
        case video, audio, network
        var id: String { rawValue }
        var title: String {
            switch self {
            case .video: "Video"
            case .audio: "Audio"
            case .network: "Network"
            }
        }
    }

    var path: Path
    var reason: String
    var source: Node
    var device: Node
    var buffer: Tile
    var bitrate: Tile
    var connection: Tile
    var audioTrack: Tile
    var subtitles: Tile
    var video: [Group]
    var audio: [Group]
    var network: [Group]

    func groups(for section: Section) -> [Group] {
        switch section {
        case .video: video
        case .audio: audio
        case .network: network
        }
    }

    /// One VoiceOver sentence for the header and chain.
    var accessibilitySummary: String {
        var parts = ["\(path.title). \(reason)."]
        parts.append("Server file: \(source.video.value), \(source.hdr.value), \(source.audio.value).")
        let changed = [("video", device.video), ("HDR", device.hdr), ("audio", device.audio)]
            .filter { $0.1.converted }
        if changed.isEmpty {
            parts.append("This device receives the same streams.")
        } else {
            parts.append("This device receives " + changed.map { "\($0.0) \($0.1.value)" }
                .joined(separator: ", ") + ".")
        }
        return parts.joined(separator: " ")
    }
}

// MARK: - Building

extension PlaybackStatsSummary {
    /// Active track names come from the same loaders the Audio/Subtitles menus use. They are
    /// shown on screen but never copied, because backend track titles are free-form text.
    struct Tracks: Equatable {
        var audioName: String?
        var subtitleName: String?
        var subtitlesOff = true
    }

    @MainActor
    static func make(_ d: PlaybackDiagnostics, tracks: Tracks = Tracks()) -> PlaybackStatsSummary {
        let explanation = d.playbackExplanation
        let path = Path(lane: explanation.lane)
        let reasons = explanation.evidence.map(\.reason)

        // Source node
        let sourceVideo = Format.videoSummary(width: d.sourceWidth, height: d.sourceHeight,
                                              codec: d.videoCodec)
        let sourceHDR = Format.shortHDR(d.sourceHDR)
        let sourceAudio = Format.shortAudio(codec: d.audioCodec, profile: d.sourceAudioProfile)
        let source = Node(video: Spec(value: sourceVideo), hdr: Spec(value: sourceHDR),
                          audio: Spec(value: sourceAudio))

        // Device node
        let deviceVideo: Spec
        switch path {
        case .direct, .copy:
            deviceVideo = Spec(value: sourceVideo)
        case .encode:
            let observed = Format.videoSummary(width: d.deliveredWidth, height: d.deliveredHeight,
                                               codec: Format.codecName(fourCC: d.runtimeVideoCodecFourCC))
            deviceVideo = Spec(value: observed, converted: true)
        }

        let deviceHDR: Spec
        if path == .direct {
            deviceHDR = Spec(value: sourceHDR)
        } else if let observed = Format.observedHDR(containsHDR: d.runtimeContainsHDR,
                                                    transfer: d.runtimeTransferFunction,
                                                    fourCC: d.runtimeVideoCodecFourCC) {
            deviceHDR = Spec(value: observed,
                             converted: path == .encode
                                || Format.hdrFamily(observed) != Format.hdrFamily(sourceHDR))
        } else {
            // Before the runtime probe has seen video, a copy carries the source bitstream; an
            // encode's output range is not yet known.
            deviceHDR = path == .copy ? Spec(value: sourceHDR) : Spec(value: "—", converted: true)
        }

        let audioConverted: Bool
        switch path {
        case .direct:
            audioConverted = false
        case .copy, .encode:
            if let decision = d.plexAudioDecision {
                audioConverted = decision == "transcode"
            } else {
                audioConverted = explanation.lane == .audioOnlyTranscode
                    || reasons.contains(where: Self.audioReasons.contains)
            }
        }
        let observedAudio = Format.observedAudio(fourCC: d.runtimeAudioCodecFourCC,
                                                 channels: d.runtimeAudioChannels)
        let deviceAudio = audioConverted
            ? Spec(value: observedAudio?.short ?? "Converted", converted: true)
            : Spec(value: sourceAudio)
        let device = Node(video: deviceVideo, hdr: deviceHDR, audio: deviceAudio)

        // Tiles
        let buffer = Tile(label: "Buffer",
                          value: Format.seconds(d.bufferedAheadSeconds),
                          context: d.stalls == 0 ? "No stalls"
                              : "\(d.stalls) \(d.stalls == 1 ? "stall" : "stalls")",
                          isProblem: d.stalls > 0,
                          contextSymbol: d.stalls > 0 ? "exclamationmark.triangle.fill" : nil)

        let sourceKbps = Double(d.sourceBitrateKbps)
        let deliveredKbps: Double = switch path {
        case .direct: sourceKbps > 0 ? sourceKbps : d.indicatedBitrateKbps
        case .copy, .encode:
            d.indicatedBitrateKbps > 0 ? d.indicatedBitrateKbps
                : (d.targetBitrateKbps > 0 ? Double(d.targetBitrateKbps) : sourceKbps)
        }
        let bitrateContext: String
        if path == .direct {
            bitrateContext = "Original"
        } else if sourceKbps > 0 {
            bitrateContext = "from \(Format.bitrateNumber(sourceKbps))"
        } else {
            bitrateContext = "Source unknown"
        }
        let bitrate = Tile(label: "Bitrate", value: Format.bitrate(deliveredKbps),
                           context: bitrateContext,
                           accessibilityContext: path == .direct ? "Original"
                               : sourceKbps > 0 ? "Source \(Format.bitrate(sourceKbps))" : "Source unknown")

        let route = PlaybackConnectionRoute.classify(host: d.connectionHost)
        let connection: Tile
        if route == .downloaded {
            connection = Tile(label: "Connection", value: route.title, context: "On this device")
        } else {
            switch d.observedBitrateState {
            case .active where d.observedBitrateKbps > 0:
                connection = Tile(label: "Connection", value: route.title,
                                  context: Format.bitrate(d.observedBitrateKbps),
                                  contextSymbol: "arrow.down",
                                  accessibilityContext: "Throughput \(Format.bitrate(d.observedBitrateKbps))")
            case .localProxy:
                connection = Tile(label: "Connection", value: route.title, context: "Not measured",
                                  accessibilityContext: "Throughput not measured")
            case .idle:
                connection = Tile(label: "Connection", value: route.title, context: "Idle",
                                  accessibilityContext: "Not downloading")
            default:
                connection = Tile(label: "Connection", value: route.title, context: "—",
                                  accessibilityContext: "Throughput unavailable")
            }
        }

        let deliveredAudioFull: String = audioConverted
            ? (observedAudio?.full ?? "Converted")
            : Format.shortAudio(codec: d.audioCodec, profile: d.sourceAudioProfile,
                                channels: d.sourceAudioChannels)
        let audioTrack = Tile(label: "Audio", value: tracks.audioName ?? sourceAudio,
                              context: deliveredAudioFull)

        let burned = reasons.contains(.subtitleBurnIn)
        let subtitles: Tile = tracks.subtitlesOff
            ? Tile(label: "Subtitles", value: "Off", context: "None")
            : Tile(label: "Subtitles", value: tracks.subtitleName ?? "On",
                   context: burned ? "Burned in" : "Separate track")

        // Expanded groups — every row the previous grid showed, regrouped.
        var decisionRows = [Row(label: "Mode", value: d.modeText),
                            Row(label: "Summary", value: explanation.headline)]
        if d.decisionText != "—" || d.dvGuardReason != nil {
            decisionRows.append(Row(label: "Decision", value: d.decisionDisplayText))
        }
        for (index, fact) in explanation.conciseReasons.enumerated() {
            decisionRows.append(Row(label: index == 0 ? "Reasons" : "", value: fact.conciseText))
        }
        var sourceVideoRows = [Row(label: "Format", value: d.videoFormatText),
                               Row(label: "Resolution", value: d.sourceResolution),
                               Row(label: "Container", value: d.container.uppercased())]
        sourceVideoRows.append(Row(label: "HDR", value: d.sourceHDRLabel ?? "None reported"))
        var deviceVideoRows: [Row] = []
        if let width = d.deliveredWidth, let height = d.deliveredHeight {
            deviceVideoRows.append(Row(label: "Resolution", value: "\(width)×\(height)"))
        }
        if let codec = Format.codecName(fourCC: d.runtimeVideoCodecFourCC) {
            deviceVideoRows.append(Row(label: "Codec", value: codec))
        }
        if let rendered = d.renderedLabel {
            deviceVideoRows.append(Row(label: "Stream signal", value: rendered))
        }
        deviceVideoRows.append(Row(label: "Display", value: d.displayCapabilityLabel))
        let video = [Group(title: "Source", rows: sourceVideoRows),
                     Group(title: "On this device", rows: deviceVideoRows),
                     Group(title: "Decision", rows: decisionRows)]

        var audioRows = [Row(label: "Source", value: d.audioFormatText),
                         Row(label: "On this device", value: deliveredAudioFull)]
        if let name = tracks.audioName { audioRows.append(Row(label: "Track", value: name)) }
        let subtitleRows = tracks.subtitlesOff
            ? [Row(label: "Track", value: "Off")]
            : [Row(label: "Track", value: tracks.subtitleName ?? "On"),
               Row(label: "Delivery", value: burned ? "Burned into video" : "Separate track")]
        let audio = [Group(title: "Audio", rows: audioRows),
                     Group(title: "Subtitles", rows: subtitleRows)]

        var bitrateRows = [Row(label: "Target", value: d.targetBitrateLabel),
                           Row(label: "Source", value: Format.bitrate(sourceKbps)),
                           Row(label: "Observed", value: d.observedBitrateLabel),
                           Row(label: "Indicated", value: Format.bitrate(d.indicatedBitrateKbps))]
        if d.indicatedAverageBitrateKbps > 0 {
            bitrateRows.append(Row(label: "Indicated avg", value: Format.bitrate(d.indicatedAverageBitrateKbps)))
        }
        if d.averageVideoBitrateKbps > 0 {
            bitrateRows.append(Row(label: "Avg video", value: Format.bitrate(d.averageVideoBitrateKbps)))
        }
        let healthRows = [Row(label: "Buffer ahead", value: String(format: "%.1f s", d.bufferedAheadSeconds)),
                          Row(label: "Keep up", value: d.likelyToKeepUp ? "Yes" : "No"),
                          Row(label: "Stalls", value: "\(d.stalls)"),
                          Row(label: "Dropped frames", value: "\(d.droppedFrames)")]
        // The server host stays out of the player UI entirely (#203); only the route is named.
        let sessionRows = [Row(label: "Route", value: route.title)]
        let network = [Group(title: "Bitrate", rows: bitrateRows),
                       Group(title: "Health", rows: healthRows),
                       Group(title: "Session", rows: sessionRows)]

        return PlaybackStatsSummary(path: path,
                                    reason: Self.reason(for: explanation),
                                    source: source, device: device,
                                    buffer: buffer, bitrate: bitrate, connection: connection,
                                    audioTrack: audioTrack, subtitles: subtitles,
                                    video: video, audio: audio, network: network)
    }

    private static let audioReasons: [PlaybackExplanationReason] = [
        .audioTranscode, .audioCodec, .audioChannels, .audioProfile, .audioRateOrDepth,
        .audioBitrate, .externalOrSecondaryAudio,
    ]

    /// Lane facts restate the path title; prefer the first fact that explains *why*.
    private static let laneReasons: [PlaybackExplanationReason] = [
        .originalFile, .videoCopy, .audioTranscode, .videoTranscode, .unknownServerReason,
    ]

    static func reason(for explanation: PlaybackExplanation) -> String {
        if let fact = explanation.evidence.first(where: { !laneReasons.contains($0.reason) }) {
            var text = fact.conciseText
            if text.hasSuffix(".") { text.removeLast() }
            return text
        }
        return explanation.headline
    }

    /// Privacy-safe plain text for the Copy action: no track titles and no media title (the
    /// server host is never part of the summary at all).
    var copyText: String {
        var lines = ["Labstream playback stats",
                     "\(path.title) — \(reason)",
                     "Server file: \(source.video.value) · \(source.hdr.value) · \(source.audio.value)",
                     "This device: \(device.video.value) · \(device.hdr.value) · \(device.audio.value)",
                     "Buffer: \(buffer.value) (\(buffer.context))",
                     "Bitrate: \(bitrate.value) (\(bitrate.accessibilityContext ?? bitrate.context))",
                     "Connection: \(connection.value) (\(connection.accessibilityContext ?? connection.context))"]
        for section in Section.allCases {
            for group in groups(for: section) {
                let rows = group.rows.filter { !Self.uncopiedRowLabels.contains($0.label) }
                guard !rows.isEmpty else { continue }
                lines.append("")
                lines.append("[\(section.title) · \(group.title)]")
                for row in rows {
                    lines.append(row.label.isEmpty ? "  \(row.value)" : "\(row.label): \(row.value)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Free-form track titles stay on screen only.
    private static let uncopiedRowLabels: Set<String> = ["Track"]
}

// MARK: - Connection route

/// Where the stream comes from, classified from the host alone. Only provable cases are named:
/// a private/link-local/loopback literal (including Plex's dashed-IP `plex.direct` names) or an
/// mDNS/home name is Local; a public IP literal is Remote; any other DNS name is Unknown,
/// because a custom domain can point at either side of the router.
enum PlaybackConnectionRoute: Equatable {
    case downloaded, local, remote, unknown

    var title: String {
        switch self {
        case .downloaded: "Downloaded"
        case .local: "Local"
        case .remote: "Remote"
        case .unknown: "Unknown"
        }
    }

    static func classify(host rawHost: String) -> PlaybackConnectionRoute {
        if rawHost == "Local file" { return .downloaded }
        var host = rawHost.lowercased()
        if host.hasPrefix("["), let end = host.firstIndex(of: "]") {
            host = String(host[host.index(after: host.startIndex)..<end])
        } else if host.filter({ $0 == ":" }).count == 1, let colon = host.lastIndex(of: ":") {
            host = String(host[..<colon]) // strip :port from a name or IPv4 literal
        }
        guard !host.isEmpty, host != "—" else { return .unknown }
        if let ipv4 = ipv4Octets(host) { return isPrivate(ipv4) ? .local : .remote }
        if host.contains(":") { return isPrivateIPv6(host) ? .local : .remote }
        if host.hasSuffix(".plex.direct"),
           let label = host.split(separator: ".").first,
           let ipv4 = ipv4Octets(label.replacingOccurrences(of: "-", with: ".")) {
            return isPrivate(ipv4) ? .local : .remote
        }
        if host == "localhost" || !host.contains(".")
            || [".local", ".lan", ".home.arpa", ".internal"].contains(where: host.hasSuffix) {
            return .local
        }
        return .unknown
    }

    private static func ipv4Octets(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return nil }
        return octets
    }

    private static func isPrivate(_ o: [Int]) -> Bool {
        o[0] == 10 || o[0] == 127
            || (o[0] == 172 && (16...31).contains(o[1]))
            || (o[0] == 192 && o[1] == 168)
            || (o[0] == 169 && o[1] == 254)
            || (o[0] == 100 && (64...127).contains(o[1])) // CGNAT, e.g. VPN overlays
    }

    private static func isPrivateIPv6(_ host: String) -> Bool {
        host == "::1" || host.hasPrefix("fe80:") || host.hasPrefix("fc") || host.hasPrefix("fd")
    }
}

// MARK: - Formatting

extension PlaybackStatsSummary {
    enum Format {
        static func resolutionName(width: Int?, height: Int?) -> String? {
            guard let width, let height, width > 0, height > 0 else { return nil }
            switch (width, height) {
            case let (w, h) where w >= 3200 || h >= 1800: return "4K"
            case let (w, h) where w >= 1700 || h >= 1000: return "1080p"
            case let (w, h) where w >= 1200 || h >= 700: return "720p"
            default: return "\(height)p"
            }
        }

        static func codecName(_ codec: String?) -> String? {
            guard let codec = codec?.lowercased(), !codec.isEmpty, codec != "—" else { return nil }
            return switch codec {
            case "hevc", "h265": "HEVC"
            case "h264", "avc": "H.264"
            case "av1": "AV1"
            case "vp9": "VP9"
            case "mpeg2video": "MPEG-2"
            case "mpeg4": "MPEG-4"
            case "vc1": "VC-1"
            default: codec.uppercased()
            }
        }

        static func codecName(fourCC: String?) -> String? {
            switch fourCC?.lowercased() {
            case "hvc1", "hev1": "HEVC"
            case "dvh1", "dvhe": "HEVC"
            case "avc1", "avc3": "H.264"
            case "av01": "AV1"
            case "vp09": "VP9"
            case nil, "": nil
            case let other?: other.uppercased()
            }
        }

        static func videoSummary(width: Int?, height: Int?, codec: String?) -> String {
            let parts = [resolutionName(width: width, height: height), codecName(codec)]
                .compactMap(\.self)
            return parts.isEmpty ? "—" : parts.joined(separator: " ")
        }

        /// The app's existing badge label ("DV P8", "HDR10+", "HLG"), shared with version
        /// badges. Backends usually expose no color facts for SDR files, so nil reads as SDR.
        static func shortHDR(_ hdr: VideoHDRMetadata?) -> String {
            hdr?.shortLabel ?? "SDR"
        }

        /// Only what the runtime probe actually saw; never a dynamic-metadata claim beyond
        /// the DV codec signalling itself.
        static func observedHDR(containsHDR: Bool?, transfer: String?, fourCC: String?) -> String? {
            guard let containsHDR else { return nil }
            guard containsHDR else { return "SDR" }
            if ["dvh1", "dvhe"].contains(fourCC?.lowercased() ?? "") { return "Dolby Vision" }
            if let transfer, transfer == "PQ" || transfer == "HLG" { return "HDR \(transfer)" }
            return "HDR"
        }

        /// Coarse family used to decide whether an observed copy changed the dynamic range.
        static func hdrFamily(_ label: String) -> String {
            if label == "SDR" { return "sdr" }
            if label.hasPrefix("DV") || label == "Dolby Vision" { return "dv" }
            if label.contains("HLG") { return "hlg" }
            return "hdr"
        }

        static func shortAudio(codec: String?, profile: String?, channels: Int? = nil) -> String {
            guard let codec = codec?.lowercased(), !codec.isEmpty, codec != "—" else { return "—" }
            let profile = profile?.lowercased() ?? ""
            var name: String = switch codec {
            case "ac3": "AC-3"
            case "eac3", "ec3", "ec-3": "E-AC-3"
            case "truehd": "TrueHD"
            case "dca", "dts":
                if profile.contains("dts:x") || profile.contains("dts-x") || profile == "x" { "DTS:X" }
                else if profile.contains("ma") && !profile.contains("mp3") { "DTS-HD MA" }
                else if profile.contains("hra") || profile.contains("high resolution") { "DTS-HD HRA" }
                else { "DTS" }
            case "aac": "AAC"
            case "flac": "FLAC"
            case "alac": "ALAC"
            case "opus": "Opus"
            case "vorbis": "Vorbis"
            case "mp3": "MP3"
            default: codec.hasPrefix("pcm") ? "PCM" : codec.uppercased()
            }
            if profile.contains("atmos") { name += " Atmos" }
            if let layout = AVFormatLabels.channelLayoutName(channels) { name += " \(layout)" }
            return name
        }

        static func observedAudio(fourCC: String?, channels: Int?) -> (short: String, full: String)? {
            let name: String? = switch fourCC?.lowercased() {
            case "aac ", "mp4a", "aach", "aacp": "AAC"
            case "ac-3": "AC-3"
            case "ec-3": "E-AC-3"
            case "alac": "ALAC"
            case "flac": "FLAC"
            case "opus": "Opus"
            case "lpcm": "PCM"
            case ".mp3": "MP3"
            case nil, "": nil
            case let other?: other.trimmingCharacters(in: .whitespaces).uppercased()
            }
            guard let name else { return nil }
            let layout = AVFormatLabels.channelLayoutName(channels).map { " \($0)" } ?? ""
            return (name + layout, name + layout)
        }

        static func seconds(_ value: Double) -> String {
            guard value.isFinite, value > 0 else { return "0 s" }
            return value >= 10 ? String(format: "%.0f s", value) : String(format: "%.1f s", value)
        }

        /// "58.2" for Mbps-range values, "850 kbps" below 1 Mbps.
        static func bitrateNumber(_ kbps: Double) -> String {
            guard kbps >= 1000 else { return bitrate(kbps) }
            return trimmed(kbps / 1000)
        }

        static func bitrate(_ kbps: Double) -> String {
            guard kbps.isFinite, kbps > 0 else { return "—" }
            if kbps >= 1000 { return "\(trimmed(kbps / 1000)) Mbps" }
            return String(format: "%.0f kbps", kbps)
        }

        private static func trimmed(_ mbps: Double) -> String {
            let text = String(format: "%.1f", mbps)
            return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
        }
    }
}
