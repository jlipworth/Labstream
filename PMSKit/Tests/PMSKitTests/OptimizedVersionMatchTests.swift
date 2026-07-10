import Testing
import Foundation
@testable import PMSKit

// GH #135 Stage 1a: characterization of the Plex optimized-version matcher extracted from
// DownloadManager. Pins the load-bearing ±16 px bounding-box and ×1.10+768 kbps slop constants
// that previously had zero tests, so the matcher can be refactored safely.

@Suite("Optimized version match")
struct OptimizedVersionMatchTests {

    private func part(id: Int, file: String?) -> Part {
        Part(id: id, key: "/library/parts/\(id)/file", file: file)
    }
    private func media(id: Int = 1, width: Int? = nil, height: Int? = nil, bitrate: Int? = nil,
                       parts: [Part] = []) -> Media {
        Media(id: id, bitrate: bitrate, width: width, height: height, part: parts)
    }

    // MARK: matches — resolution bounding box (target 1920x1080)

    private let target1080 = (width: 1920, height: 1080)

    @Test func acceptsExactAndScopeWithinBox() {
        #expect(OptimizedVersionMatch.matches(media: media(width: 1920, height: 1080),
                targetDimensions: target1080, targetVideoKbps: nil, isOriginalQuality: false, sourceHeight: nil))
        // CinemaScope 2.40:1 render: width hits target, height under box.
        #expect(OptimizedVersionMatch.matches(media: media(width: 1920, height: 802),
                targetDimensions: target1080, targetVideoKbps: nil, isOriginalQuality: false, sourceHeight: nil))
    }

    @Test func rejectsTooSmallAndOverBox() {
        // 720p: neither edge near the 1080p target.
        #expect(!OptimizedVersionMatch.matches(media: media(width: 1280, height: 720),
                targetDimensions: target1080, targetVideoKbps: nil, isOriginalQuality: false, sourceHeight: nil))
        // Exceeds the box on height (+120).
        #expect(!OptimizedVersionMatch.matches(media: media(width: 1920, height: 1200),
                targetDimensions: target1080, targetVideoKbps: nil, isOriginalQuality: false, sourceHeight: nil))
    }

    @Test func sixteenPixelSlopEdges() {
        #expect(OptimizedVersionMatch.matches(media: media(width: 1904, height: 1080),
                targetDimensions: target1080, targetVideoKbps: nil, isOriginalQuality: false, sourceHeight: nil))
        #expect(OptimizedVersionMatch.matches(media: media(width: 1920, height: 1096),
                targetDimensions: target1080, targetVideoKbps: nil, isOriginalQuality: false, sourceHeight: nil))
        // width 17 off AND height 17 over the box → neither near, over box → reject.
        #expect(!OptimizedVersionMatch.matches(media: media(width: 1903, height: 1097),
                targetDimensions: target1080, targetVideoKbps: nil, isOriginalQuality: false, sourceHeight: nil))
    }

    @Test func legacyWidthNilFallsBackToHeightOnly() {
        #expect(OptimizedVersionMatch.matches(media: media(width: nil, height: 1080),
                targetDimensions: target1080, targetVideoKbps: nil, isOriginalQuality: false, sourceHeight: nil))
        #expect(!OptimizedVersionMatch.matches(media: media(width: nil, height: 720),
                targetDimensions: target1080, targetVideoKbps: nil, isOriginalQuality: false, sourceHeight: nil))
    }

    @Test func noTargetDimensionsMeansNoResolutionConstraint() {
        #expect(OptimizedVersionMatch.matches(media: media(width: 640, height: 360),
                targetDimensions: nil, targetVideoKbps: nil, isOriginalQuality: false, sourceHeight: nil))
    }

    // MARK: matches — original-quality height gate

    @Test func originalQualityRequiresSourceHeight() {
        // A 1080-tall render for a 2160 source is a down-rez, not "original".
        #expect(!OptimizedVersionMatch.matches(media: media(height: 1080),
                targetDimensions: nil, targetVideoKbps: nil, isOriginalQuality: true, sourceHeight: 2160))
        #expect(OptimizedVersionMatch.matches(media: media(height: 2156),
                targetDimensions: nil, targetVideoKbps: nil, isOriginalQuality: true, sourceHeight: 2160))
        #expect(!OptimizedVersionMatch.matches(media: media(height: 2160),
                targetDimensions: nil, targetVideoKbps: nil, isOriginalQuality: true, sourceHeight: nil))
        #expect(!OptimizedVersionMatch.matches(media: media(height: nil),
                targetDimensions: nil, targetVideoKbps: nil, isOriginalQuality: true, sourceHeight: 2160))
    }

    // MARK: matches — bitrate allowance (×1.10 + 768)

    @Test func bitrateAllowanceEdges() {
        // 8000 → allowed 9568.
        #expect(OptimizedVersionMatch.matches(media: media(bitrate: 8000),
                targetDimensions: nil, targetVideoKbps: 8000, isOriginalQuality: false, sourceHeight: nil))
        #expect(OptimizedVersionMatch.matches(media: media(bitrate: 9568),
                targetDimensions: nil, targetVideoKbps: 8000, isOriginalQuality: false, sourceHeight: nil))
        #expect(!OptimizedVersionMatch.matches(media: media(bitrate: 9569),
                targetDimensions: nil, targetVideoKbps: 8000, isOriginalQuality: false, sourceHeight: nil))
        // Unknown media bitrate → bitrate check skipped (accept).
        #expect(OptimizedVersionMatch.matches(media: media(bitrate: nil),
                targetDimensions: nil, targetVideoKbps: 8000, isOriginalQuality: false, sourceHeight: nil))
    }

    // MARK: isServerOptimizedPart

    @Test func serverOptimizedPartByPath() {
        #expect(OptimizedVersionMatch.isServerOptimizedPart(part(id: 1, file: "/Movies/Plex Versions/x.mp4")))
        #expect(OptimizedVersionMatch.isServerOptimizedPart(part(id: 2, file: "/MOVIES/PLEX VERSIONS/x.mp4")))
        #expect(!OptimizedVersionMatch.isServerOptimizedPart(part(id: 3, file: "/Movies/original.mkv")))
        #expect(!OptimizedVersionMatch.isServerOptimizedPart(part(id: 4, file: nil)))
    }

    // MARK: candidate selection

    @Test func candidatePicksNewOptimizedPlayablePart() {
        let baseline = part(id: 10, file: "/Movies/orig.mkv")            // original source
        let optimized = part(id: 11, file: "/Movies/Plex Versions/Optimized for Mobile/x.mp4")
        let m = media(id: 1, width: 1920, height: 1080, bitrate: 8000, parts: [baseline, optimized])
        let pick = OptimizedVersionMatch.candidate(from: [m], baselinePartIDs: [10],
                targetDimensions: target1080, targetVideoKbps: 8000, isOriginalQuality: false, sourceHeight: nil)
        #expect(pick?.id == 11)
    }

    @Test func candidateRejectsBaselineNonOptimizedAndNonPlayable() {
        // Only a baseline id present → nil.
        let baselineOnly = media(id: 1, width: 1920, height: 1080,
                                 parts: [part(id: 10, file: "/Movies/Plex Versions/x.mp4")])
        #expect(OptimizedVersionMatch.candidate(from: [baselineOnly], baselinePartIDs: [10],
                targetDimensions: target1080, targetVideoKbps: nil, isOriginalQuality: false, sourceHeight: nil) == nil)
        // A new optimized part that is NOT locally playable (mkv) → excluded.
        let mkv = media(id: 2, width: 1920, height: 1080,
                        parts: [part(id: 20, file: "/Movies/Plex Versions/x.mkv")])
        #expect(OptimizedVersionMatch.candidate(from: [mkv], baselinePartIDs: [],
                targetDimensions: target1080, targetVideoKbps: nil, isOriginalQuality: false, sourceHeight: nil) == nil)
        // A new mp4 that is NOT under Plex Versions → excluded.
        let notOptimized = media(id: 3, width: 1920, height: 1080,
                                 parts: [part(id: 30, file: "/Movies/manual.mp4")])
        #expect(OptimizedVersionMatch.candidate(from: [notOptimized], baselinePartIDs: [],
                targetDimensions: target1080, targetVideoKbps: nil, isOriginalQuality: false, sourceHeight: nil) == nil)
    }

    @Test func candidateSkipsWrongTierMedia() {
        // A 720p optimized render must NOT satisfy a 1080p request even though it's a Plex Version.
        let m = media(id: 1, width: 1280, height: 720,
                      parts: [part(id: 11, file: "/Movies/Plex Versions/x.mp4")])
        #expect(OptimizedVersionMatch.candidate(from: [m], baselinePartIDs: [],
                targetDimensions: target1080, targetVideoKbps: nil, isOriginalQuality: false, sourceHeight: nil) == nil)
    }

    // MARK: shared dimensions parser (dedup target)

    @Test func dimensionsParserLowercasesAndParses() {
        #expect(DownloadResolutionLabel.dimensions(forVideoResolution: "1920x1080")?.width == 1920)
        #expect(DownloadResolutionLabel.dimensions(forVideoResolution: "1920x1080")?.height == 1080)
        // Defensive: capital-X also parses now (the old inline copy did not lowercase).
        #expect(DownloadResolutionLabel.dimensions(forVideoResolution: "1920X1080")?.height == 1080)
        #expect(DownloadResolutionLabel.dimensions(forVideoResolution: "garbage") == nil)
    }
}
