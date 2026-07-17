import Foundation
import Testing
@testable import PMSKit

@Suite("Prepared static lane normalization policy")
struct PreparedStaticLaneNormalizationPolicyTests {
    @Test("Legacy Plex rendered-Part handoff normalizes to optimized static provenance")
    func normalizesLegacyPlexHandoff() {
        var metadata: OfflineMetadata? = OfflineMetadata(
            ratingKey: "123",
            title: "Movie",
            type: "movie",
            optimizeTargetName: "8 Mbps 1080p",
            backendKind: .plex,
            // `nil` is also a real legacy shape: resolvedDownloadLane infers optimize from target.
            downloadLane: nil,
            resumeMode: .staticByteRange,
            serverPreparedVersion: true)

        #expect(PreparedStaticLaneNormalizationPolicy.shouldNormalize(
            metadata: metadata, ratingKey: "123"))
        #expect(PreparedStaticLaneNormalizationPolicy.normalize(
            metadata: &metadata, ratingKey: "123"))
        #expect(metadata?.downloadLane == .original)
        #expect(metadata?.resolvedResumeMode(ratingKey: "123") == .staticByteRange)
        #expect(metadata?.isServerPreparedVersion == true)
        #expect(DownloadRowDisplayPolicy.routeBadge(
            lane: metadata?.resolvedDownloadLane() ?? .optimize,
            isServerPreparedVersion: metadata?.isServerPreparedVersion == true) == .optimized)
    }

    @Test("Live and still-preparing rows never normalize")
    func rejectsOtherBackendsAndPhases() {
        for (backend, resumeMode) in [
            (DownloadBackendKind.jellyfin, DownloadResumeMode.liveForwardOnly),
            (.plex, .serverPrepThenStatic),
            (.emby, .staticByteRange),
        ] {
            var metadata: OfflineMetadata? = OfflineMetadata(
                ratingKey: "item",
                title: "Movie",
                type: "movie",
                optimizeTargetName: "8 Mbps 1080p",
                backendKind: backend,
                downloadLane: .optimize,
                resumeMode: resumeMode,
                serverPreparedVersion: true)
            #expect(!PreparedStaticLaneNormalizationPolicy.normalize(
                metadata: &metadata, ratingKey: "item"))
            #expect(metadata?.downloadLane == .optimize)
        }
    }
}
