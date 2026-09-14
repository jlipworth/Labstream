// Read-only native-macOS format-description experiment for issue #316.
// Compile: swiftc -parse-as-library scripts/dv-decoder-init-probe.swift -o build/dv-init-probe
// Run: build/dv-init-probe /path/to/private/init.mp4
// This never rewrites media, submits compressed samples, or establishes a playback pass.
import Foundation
import AVFoundation
import VideoToolbox

private let dvAtomNames = ["dvcC", "dvvC", "dvwC"]

private func withoutDVAtoms(_ original: NSDictionary) -> NSDictionary {
    let result = original.mutableCopy() as! NSMutableDictionary
    if let atoms = original[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] as? NSDictionary {
        let copy = atoms.mutableCopy() as! NSMutableDictionary
        for name in dvAtomNames { copy.removeObject(forKey: name) }
        result[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] = copy
    }
    return result
}

private func selfTest() {
    let atoms: NSDictionary = ["hvcC": Data([1, 2]), "dvcC": Data([3]),
                               "dvvC": Data([4]), "dvwC": Data([5]), "other": Data([6])]
    let original: NSDictionary = [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: atoms,
                                  kCMFormatDescriptionExtension_ColorPrimaries: "ITU_R_2020",
                                  "sentinel": Data([7])]
    let before = original.copy() as! NSDictionary
    let modified = withoutDVAtoms(original)
    let remaining = modified[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] as! NSDictionary
    precondition(original.isEqual(to: before as! [AnyHashable: Any]))
    precondition(remaining.count == 2 && remaining["hvcC"] as? Data == Data([1, 2]))
    precondition(remaining["other"] as? Data == Data([6]))
    precondition(modified[kCMFormatDescriptionExtension_ColorPrimaries] as? String == "ITU_R_2020")
    precondition(modified["sentinel"] as? Data == Data([7]))
    precondition(withoutDVAtoms(modified).isEqual(to: modified as! [AnyHashable: Any]))
    precondition(withoutDVAtoms(["sentinel": 1]).isEqual(to: ["sentinel": 1]))
    print("Self-test passed: only DV atom entries removed; input and other extensions preserved.")
}

private func decoderStatus(_ description: CMVideoFormatDescription) -> OSStatus {
    var session: VTDecompressionSession?
    var callback = VTDecompressionOutputCallbackRecord(decompressionOutputCallback: { _, _, _, _, _, _, _ in },
                                                       decompressionOutputRefCon: nil)
    let status = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault,
                                             formatDescription: description,
                                             decoderSpecification: nil,
                                             imageBufferAttributes: nil,
                                             outputCallback: &callback,
                                             decompressionSessionOut: &session)
    if let session { VTDecompressionSessionInvalidate(session) }
    return status
}

private enum ProbeError: Error { case invalidInput, unexpectedTrack, unsupportedFormat, formatCreation }

@main private struct Probe {
    static func main() async {
        do {
            guard CommandLine.arguments.count == 2 else { throw ProbeError.invalidInput }
            if CommandLine.arguments[1] == "--self-test" { selfTest(); return }
            let url = URL(fileURLWithPath: CommandLine.arguments[1])
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, let size = values.fileSize,
                  size > 0, size <= 1_048_576 else { throw ProbeError.invalidInput }
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard tracks.count == 1 else { throw ProbeError.unexpectedTrack }
            let formats = try await tracks[0].load(.formatDescriptions)
            guard formats.count == 1 else { throw ProbeError.unsupportedFormat }
            let original = formats[0]
            let subtype = CMFormatDescriptionGetMediaSubType(original)
            guard subtype == kCMVideoCodecType_HEVC,
                  let extensions = CMFormatDescriptionGetExtensions(original) else {
                throw ProbeError.unsupportedFormat
            }
            let originalExtensions = extensions as NSDictionary
            let dimensions = CMVideoFormatDescriptionGetDimensions(original)
            let atoms = originalExtensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] as? NSDictionary
            let present = dvAtomNames.filter { atoms?[$0] != nil }
            var cases: [[String: Any]] = [["case": "asset-original", "decoderStatus": decoderStatus(original)]]
            // Round-trip and restore controls distinguish reconstruction and ordering effects
            // from the single dictionary change. All other extensions (including color) survive.
            for (name, changed) in [("round-trip", false), ("omit-dv-atoms", true), ("restored", false)] {
                var format: CMVideoFormatDescription?
                let selected = changed ? withoutDVAtoms(originalExtensions) : originalExtensions
                let status = CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                                            codecType: subtype,
                                                            width: dimensions.width,
                                                            height: dimensions.height,
                                                            extensions: selected as CFDictionary,
                                                            formatDescriptionOut: &format)
                guard status == noErr, let format else { throw ProbeError.formatCreation }
                cases.append(["case": name, "formatStatus": status, "decoderStatus": decoderStatus(format)])
            }
            let report: [String: Any] = ["scope": "decoder-creation-only; no samples submitted",
                                         "width": dimensions.width, "height": dimensions.height,
                                         "dvAtoms": present, "cases": cases]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        } catch {
            // Do not print input URLs, source names, or framework error userInfo.
            fputs("Probe failed: expected a local, bounded HEVC initialization file with one video format.\n", stderr)
            exit(1)
        }
    }
}
