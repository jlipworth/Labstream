import Foundation
import AVFoundation
import CoreMedia

/// Runtime HDR facts observed from AVFoundation for the current item (GH #195).
///
/// This is the "what is AVPlayer actually seeing" half of the Stats HDR story — the
/// backend-metadata half (`VideoHDRMetadata`) says what the source file claims. The two
/// can legitimately disagree (e.g. HDR source, server tone-mapped transcode to SDR).
struct PlaybackHDRProbeResult: Equatable {
    /// True when the asset exposes a track with `.containsHDRVideo`.
    var containsHDRVideo: Bool
    /// "PQ" / "HLG" when the video track's format description carries a transfer function.
    var transferFunction: String?
    /// Device/runtime capability: `AVPlayer.eligibleForHDRPlayback`.
    var eligibleForHDRPlayback: Bool
    /// True when the probe saw at least one video track with format descriptions. HLS
    /// items often have none until segments load, so an inconclusive probe should be
    /// retried rather than displayed as "SDR".
    var sawVideoFormatDescriptions: Bool
    /// FourCC of the first video format description (e.g. "hvc1", "avc1"), when segments
    /// have loaded. Codec-family agreement with the source supports a copy/remux inference on
    /// Jellyfin/Emby "transcode" sessions, but is not encoder proof (#196/#203).
    var videoCodecFourCC: String?
}

enum PlaybackHDRProbe {

    /// Inspect the current item's asset for HDR characteristics. Best-effort and silent:
    /// never throws, never logs (asset URLs may embed tokens). Main-actor because the
    /// player item and its asset are main-actor bound in this app; the `load(...)` awaits
    /// suspend rather than block, so this stays cheap.
    @MainActor
    static func probe(playerItem: AVPlayerItem, eligibleForHDRPlayback: Bool) async -> PlaybackHDRProbeResult {
        let asset = playerItem.asset

        let hdrTracks = (try? await asset.loadTracks(withMediaCharacteristic: .containsHDRVideo)) ?? []
        let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []

        var transfer: String?
        var sawFormats = false
        var codecFourCC: String?
        for track in videoTracks {
            guard let formats = try? await track.load(.formatDescriptions), !formats.isEmpty else { continue }
            sawFormats = true
            if codecFourCC == nil, let first = formats.first {
                codecFourCC = fourCCString(CMFormatDescriptionGetMediaSubType(first))
            }
            for format in formats {
                if let name = transferFunctionName(format) {
                    transfer = name
                    break
                }
            }
            if transfer != nil { break }
        }

        return PlaybackHDRProbeResult(containsHDRVideo: !hdrTracks.isEmpty,
                                      transferFunction: transfer,
                                      eligibleForHDRPlayback: eligibleForHDRPlayback,
                                      sawVideoFormatDescriptions: sawFormats,
                                      videoCodecFourCC: codecFourCC)
    }

    private static func fourCCString(_ code: FourCharCode) -> String? {
        let bytes: [UInt8] = [UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
                              UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
        guard bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else { return nil }
        return String(bytes: bytes, encoding: .ascii)
    }

    private static func transferFunctionName(_ format: CMFormatDescription) -> String? {
        guard let raw = CMFormatDescriptionGetExtension(
            format,
            extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String else { return nil }
        switch raw as CFString {
        case kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ:
            return "PQ"
        case kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG:
            return "HLG"
        case kCMFormatDescriptionTransferFunction_ITU_R_2020:
            return "BT.2020"
        case kCMFormatDescriptionTransferFunction_ITU_R_709_2:
            return nil // SDR transfer — the leading HDR/SDR word already covers it.
        default:
            // Surface unrecognised constants by their suffix rather than hiding them.
            let name = raw.replacingOccurrences(of: "TransferFunction_", with: "")
            return name.isEmpty ? nil : name
        }
    }
}
