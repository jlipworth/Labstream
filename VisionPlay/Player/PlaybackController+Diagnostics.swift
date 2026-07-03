import Foundation
import AVKit
import PMSKit

extension PlaybackController {

    func diagnosticFields(_ fields: [String: DiagnosticFieldValue]) -> [String: DiagnosticFieldValue] {
        var merged: [String: DiagnosticFieldValue] = [
            "session": .identifier(sessionID),
            "item_type": .label(item.type),
            "media_index": .int(mediaIndex),
            "quality_label": .label(StreamingQuality.label(kbps: maxVideoBitrateKbps)),
            "quality_kbps": .int(maxVideoBitrateKbps),
        ]
        merged.merge(fields) { _, new in new }
        return merged
    }

    func sourceDiagnosticFields() -> [String: DiagnosticFieldValue] {
        PlaybackSourceSummary.plex(item: item, mediaIndex: mediaIndex).diagnosticFields
    }

    func mediaBrowserSourceDiagnosticFields(_ source: MediaBrowserPlaybackSourceMetadata?) -> [String: DiagnosticFieldValue] {
        PlaybackSourceSummary.mediaBrowser(source)?.diagnosticFields ?? [:]
    }

    func decisionDiagnosticFields(_ decision: DecisionResponse) -> [String: DiagnosticFieldValue] {
        var fields: [String: DiagnosticFieldValue] = [
            "pms_decision_mode": .label(Self.decisionModeLabel(decision)),
            "saves_video_encode": .bool(decision.savesVideoEncode),
            "plays_whole_file_directly": .bool(decision.playsWholeFileDirectly),
            "part_decision": .label(decision.partDecision),
            "video_decision": .label(decision.videoDecision),
            "audio_decision": .label(decision.audioDecision),
        ]
        if let code = decision.generalDecisionCode {
            fields["general_decision_code"] = .int(code)
        }
        if let code = decision.mdeDecisionCode {
            fields["mde_decision_code"] = .int(code)
        }
        if let text = decision.generalDecisionText {
            fields["general_decision_text"] = .text(text)
        }
        if let text = decision.mdeDecisionText {
            fields["mde_decision_text"] = .text(text)
        }
        return fields
    }

    static func decisionModeLabel(_ decision: DecisionResponse) -> String {
        switch decision.decision {
        case .directPlay:
            return "direct_play"
        case .transcode:
            return "transcode"
        case .unsupported:
            return "unsupported"
        }
    }

    func runtimeSnapshotFields() -> [String: DiagnosticFieldValue] {
        [
            "target_bitrate_kbps": .int(diagnostics.targetBitrateKbps),
            "target_bitrate_label": .label(diagnostics.targetBitrateLabel),
            "source_bitrate_kbps": .int(diagnostics.sourceBitrateKbps),
            "observed_bitrate_kbps": .double(diagnostics.observedBitrateKbps),
            "observed_bitrate_state": .label(String(describing: diagnostics.observedBitrateState)),
            "indicated_bitrate_kbps": .double(diagnostics.indicatedBitrateKbps),
            "indicated_average_bitrate_kbps": .double(diagnostics.indicatedAverageBitrateKbps),
            "average_video_bitrate_kbps": .double(diagnostics.averageVideoBitrateKbps),
            "required_bitrate_kbps": .double(diagnostics.requiredBitrateKbps),
            "buffer_ahead_seconds": .double(diagnostics.bufferedAheadSeconds),
            "likely_to_keep_up": .bool(diagnostics.likelyToKeepUp),
            "stall_count": .int(diagnostics.stalls),
            "dropped_frames": .int(diagnostics.droppedFrames),
            "is_transcoding": .bool(diagnostics.isTranscoding),
            "decision_summary": .text(diagnostics.decisionText),
        ].merging(hdrSnapshotFields()) { current, _ in current }
    }

    /// HDR facts for exported snapshots (#195): source classification, runtime probe
    /// label, and the tone-map inference. Labels only — never URLs/tokens/titles.
    private func hdrSnapshotFields() -> [String: DiagnosticFieldValue] {
        var fields: [String: DiagnosticFieldValue] = [:]
        if let sourceHDR = diagnostics.sourceHDRLabel {
            fields["source_hdr_detail"] = .label(sourceHDR)
        }
        if let format = diagnostics.sourceHDRFormat {
            fields["source_hdr"] = .label(format.rawValue)
        }
        if let runtimeHDR = diagnostics.runtimeContainsHDR {
            fields["runtime_hdr"] = .label(runtimeHDR ? "hdr" : "sdr")
        }
        if let transfer = diagnostics.runtimeTransferFunction {
            fields["runtime_transfer"] = .label(transfer)
        }
        if let fourCC = diagnostics.runtimeVideoCodecFourCC {
            fields["runtime_video_codec"] = .label(fourCC)
        }
        if let eligible = diagnostics.runtimeEligibleForHDR {
            fields["hdr_eligible"] = .bool(eligible)
        }
        if let rendered = diagnostics.renderedLabel {
            fields["rendered"] = .label(rendered)
        }
        return fields
    }

    static func timeControlStatusLabel(_ status: AVPlayer.TimeControlStatus) -> String {
        switch status {
        case .paused:
            return "paused"
        case .waitingToPlayAtSpecifiedRate:
            return "waiting"
        case .playing:
            return "playing"
        @unknown default:
            return "unknown"
        }
    }

    static func itemStatusLabel(_ status: AVPlayerItem.Status) -> String {
        switch status {
        case .unknown:
            return "unknown"
        case .readyToPlay:
            return "readyToPlay"
        case .failed:
            return "failed"
        @unknown default:
            return "unknown"
        }
    }

    static func playerStatusLabel(_ status: AVPlayer.Status) -> String {
        switch status {
        case .unknown:
            return "unknown"
        case .readyToPlay:
            return "readyToPlay"
        case .failed:
            return "failed"
        @unknown default:
            return "unknown"
        }
    }

    static func errorDomainFamily(_ domain: String) -> String {
        DiagnosticRedactor.errorDomainFamily(domain)
    }
}
