import Foundation
import Testing
@testable import PMSKit

@Suite("Download row status caption policy")
struct DownloadRowStatusCaptionPolicyTests {
    @Test("Static byte-range zero-byte active rows stay in download language")
    func activeStaticZeroByteCaption() {
        let caption = DownloadRowStatusCaptionPolicy.caption(context(
            resumeMode: .staticByteRange,
            resolutionLabel: "1080p",
            isActive: true,
            downloadETA: 90,
            downloadSpeedBytesPerSecond: 1_000_000))

        #expect(caption.hasPrefix("Downloading original • 0% • ~2 min left • "))
        #expect(caption.contains("/s"))
        #expect(caption.hasSuffix(" • 1080p"))
    }

    @Test("Server prep finalizing stays distinct from local verification")
    func serverPrepFinalizingCaption() {
        let caption = DownloadRowStatusCaptionPolicy.caption(context(
            status: .preparing,
            resumeMode: .serverPrepThenStatic,
            resolutionLabel: "720p",
            serverPrepState: "finalizing",
            serverPrepProgress: 1.0))

        #expect(caption == "Finalizing server transcode… • 720p")
    }

    @Test("Forward-only active bytes include approximate percent and server-paced rate")
    func activeForwardOnlyCaption() {
        let caption = DownloadRowStatusCaptionPolicy.caption(context(
            bytes: 2_000_000,
            lane: .optimize,
            backend: .emby,
            displayFraction: .init(value: 0.25, isEstimated: true),
            isActive: true,
            isTranscodeLimited: true,
            downloadSpeedBytesPerSecond: 500_000))

        #expect(caption.hasPrefix("Transcoding + downloading • ~25%"))
        #expect(caption.contains("server-paced"))
    }

    @Test("Failed and paused terminal captions preserve row affordances")
    func terminalCaptions() {
        #expect(DownloadRowStatusCaptionPolicy.caption(context(
            status: .failed,
            isRetrying: true,
            failureCaption: "Download failed: boom")) == "Retrying…")

        let paused = DownloadRowStatusCaptionPolicy.caption(context(
            status: .paused,
            bytes: 1_000_000,
            displayFraction: .init(value: 0.5, isEstimated: false)))
        #expect(paused.hasPrefix("Paused — tap to resume • 50% • "))
    }

    @Test("Phase classification makes row state machine explicit")
    func phases() {
        #expect(DownloadRowStatusCaptionPolicy.phase(context(
            status: .failed,
            isRetrying: true)) == .failed(isRetrying: true))
        #expect(DownloadRowStatusCaptionPolicy.phase(context(
            resumeMode: .staticByteRange,
            isActive: true)) == .activeStaticZeroByteTransfer)
        #expect(DownloadRowStatusCaptionPolicy.phase(context(
            resumeMode: .serverPrepThenStatic,
            serverPrepState: "finalizing",
            serverPrepProgress: 1.0)) == .serverPrepFinalizing)
        #expect(DownloadRowStatusCaptionPolicy.phase(context(
            isBackendConfigured: false)) == .waitingForBackend)
        #expect(DownloadRowStatusCaptionPolicy.phase(context(
            bytes: 1_000_000,
            isActive: true)) == .activeTransfer)
    }

    @Test("Inactive server prep waits for its unavailable backend while active prep stays visible")
    func unavailableBackendPrepCaption() {
        let inactive = context(status: .preparing,
                               backend: .emby,
                               resumeMode: .serverPrepThenStatic,
                               isActive: false,
                               isBackendConfigured: false,
                               serverPrepState: "finalizing",
                               serverPrepProgress: 1.0)
        #expect(DownloadRowStatusCaptionPolicy.phase(inactive) == .waitingForBackend)
        #expect(DownloadRowStatusCaptionPolicy.caption(inactive) == "Waiting for Emby…")

        let active = context(status: .preparing,
                             backend: .plex,
                             resumeMode: .serverPrepThenStatic,
                             isActive: true,
                             isBackendConfigured: false,
                             serverPrepProgress: 0.42)
        #expect(DownloadRowStatusCaptionPolicy.phase(active) == .serverPrepProgressing)
        #expect(DownloadRowStatusCaptionPolicy.caption(active) == "Preparing on server… 42%")
    }


    @Test("Compact sheet captions preserve modal phase wording")
    func compactActiveCaptions() {
        #expect(DownloadRowStatusCaptionPolicy.compactActiveCaption(lane: .original,
                                                                   backend: .plex,
                                                                   isServerPreparedVersion: false) == "Downloading…")
        // B4: server-prepared static byte-range version reads as "optimized", never "transcode".
        #expect(DownloadRowStatusCaptionPolicy.compactActiveCaption(lane: .original,
                                                                   backend: .plex,
                                                                   isServerPreparedVersion: true) == "Downloading optimized…")
        #expect(DownloadRowStatusCaptionPolicy.compactActiveCaption(lane: .compatibleRemux,
                                                                   backend: .emby,
                                                                   isServerPreparedVersion: false) == "Remuxing + downloading…")
        #expect(DownloadRowStatusCaptionPolicy.compactActiveCaption(lane: .optimize,
                                                                   backend: .jellyfin,
                                                                   isServerPreparedVersion: false) == "Transcoding + downloading…")
    }

    @Test("Record context derives persisted row facts from the shared job snapshot")
    func recordContextDerivesPersistedFacts() {
        let record = DownloadRecord(
            ratingKey: "emby:item-1",
            title: "Fixture",
            localURL: URL(fileURLWithPath: "/tmp/fixture.mp4"),
            bytes: 1_000,
            progress: 0.25,
            status: .downloading,
            metadata: OfflineMetadata(ratingKey: "emby:item-1",
                                      title: "Fixture",
                                      type: "movie",
                                      resolutionLabel: "720p",
                                      optimizeQueueTitle: "queue-title",
                                      backendKind: .emby,
                                      downloadLane: .compatibleRemux,
                                      resumeMode: .liveForwardOnly,
                                      serverPreparedVersion: true))

        let context = DownloadRowStatusCaptionPolicy.Context(
            record: record,
            displayFraction: .init(value: 0.25, isEstimated: true),
            isActive: true,
            isBackendConfigured: true,
            isTranscodeLimited: true,
            serverPrepState: nil,
            serverPrepProgress: nil,
            serverPrepETA: nil,
            downloadETA: 120,
            downloadSpeedBytesPerSecond: 500_000,
            isRetrying: false,
            failureCaption: nil)

        #expect(context.status == .downloading)
        #expect(context.progress == 0.25)
        #expect(context.bytes == 1_000)
        #expect(context.captionBytes == 1_000)
        #expect(context.sideAssetBytes == 0)
        #expect(context.backend == .emby)
        #expect(context.lane == .compatibleRemux)
        #expect(context.resumeMode == .liveForwardOnly)
        #expect(context.isServerPreparedVersion)
        #expect(context.resolutionLabel == "720p")
        #expect(context.hasServerPrepQueueTitle)
        #expect(DownloadRowStatusCaptionPolicy.caption(context).contains("server-paced"))
    }

    @Test("paused captions can use resumable display bytes")
    func pausedCaptionUsesResumableDisplayBytes() {
        let record = DownloadRecord(
            ratingKey: "plex-1",
            title: "Movie",
            localURL: URL(fileURLWithPath: "/tmp/movie.mp4"),
            bytes: 270_000_000,
            progress: 0.017,
            status: .paused,
            metadata: OfflineMetadata(ratingKey: "plex-1",
                                      title: "Movie",
                                      type: "movie",
                                      sourcePartSize: 15_669_460_890,
                                      downloadLane: .original,
                                      resumeMode: .staticByteRange,
                                      resumeDataRelativePath: "plex-1.resume",
                                      resumeDisplayBytes: 5_500_000_000))

        let fraction = DownloadProgressDisplay.fraction(
            for: record,
            displayBytes: record.metadata?.resumeDisplayBytes,
            staticExpectedBytes: record.metadata?.sourcePartSize,
            estimatedTotalBytes: nil)

        let caption = DownloadRowStatusCaptionPolicy.caption(.init(
            record: record,
            backend: .plex,
            displayFraction: fraction,
            displayBytes: record.metadata?.resumeDisplayBytes,
            isActive: false,
            isBackendConfigured: true,
            isTranscodeLimited: false,
            serverPrepState: nil,
            serverPrepProgress: nil,
            serverPrepETA: nil,
            downloadETA: nil,
            downloadSpeedBytesPerSecond: nil,
            isRetrying: false,
            failureCaption: nil))

        #expect(caption.contains("Paused"))
        #expect(caption.contains("35%"))
        #expect(caption.contains("5.5 GB"))
        #expect(!caption.contains("270 MB"))
    }

    @Test("row captions separate side-asset bytes from media progress bytes")
    func rowCaptionSeparatesSideAssetBytesFromMediaBytes() {
        let record = DownloadRecord(
            ratingKey: "plex-1",
            title: "Movie",
            localURL: URL(fileURLWithPath: "/tmp/movie.mp4"),
            bytes: 0,
            progress: 0,
            status: .downloading,
            metadata: OfflineMetadata(ratingKey: "plex-1",
                                      title: "Movie",
                                      type: "movie",
                                      downloadLane: .original,
                                      resumeMode: .staticByteRange),
            sideAssetBytes: 21_000_000)

        let context = DownloadRowStatusCaptionPolicy.Context(
            record: record,
            backend: .plex,
            displayFraction: nil,
            isActive: true,
            isBackendConfigured: true,
            isTranscodeLimited: false,
            serverPrepState: nil,
            serverPrepProgress: nil,
            serverPrepETA: nil,
            downloadETA: nil,
            downloadSpeedBytesPerSecond: nil,
            isRetrying: false,
            failureCaption: nil)

        #expect(context.bytes == 0)
        #expect(context.captionBytes == 0)
        #expect(context.sideAssetBytes == 21_000_000)
        #expect(DownloadRowStatusCaptionPolicy.phase(context) == .activeStaticZeroByteTransfer)
        #expect(DownloadRowStatusCaptionPolicy.caption(context).contains("21 MB extras"))
    }

    @Test("active captions use live display bytes when provided")
    func activeCaptionUsesLiveDisplayBytes() {
        let record = DownloadRecord(
            ratingKey: "plex-1",
            title: "Movie",
            localURL: URL(fileURLWithPath: "/tmp/movie.mp4"),
            bytes: 256 * 1_024 * 1_024,
            progress: 0.017,
            status: .downloading,
            metadata: OfflineMetadata(ratingKey: "plex-1",
                                      title: "Movie",
                                      type: "movie",
                                      downloadLane: .original,
                                      resumeMode: .staticByteRange,
                                      serverPreparedVersion: true))

        let caption = DownloadRowStatusCaptionPolicy.caption(.init(
            record: record,
            backend: .plex,
            displayFraction: .init(value: 0.37, isEstimated: false),
            displayBytes: 5_500_000_000,
            isActive: true,
            isBackendConfigured: true,
            isTranscodeLimited: false,
            serverPrepState: nil,
            serverPrepProgress: nil,
            serverPrepETA: nil,
            downloadETA: nil,
            downloadSpeedBytesPerSecond: nil,
            isRetrying: false,
            failureCaption: nil))

        #expect(caption.contains("37%"))
        #expect(caption.contains("5.5 GB"))
        #expect(!caption.contains("256 MB"))
        // B4: this row is a server-prepared version on the STATIC `.original` byte-range lane, so its
        // caption must read as "optimized" and never mislabel it a live "transcode".
        #expect(caption.contains("Downloading optimized"))
        #expect(!caption.lowercased().contains("transcode"))
    }

    @Test("Transfer finalizing caption uses local verification wording")
    func transferFinalizingCaption() {
        let caption = DownloadRowStatusCaptionPolicy.caption(context(
            progress: 1.0,
            bytes: 1_000_000,
            resolutionLabel: "4K"))

        #expect(caption.hasPrefix("Verifying download… • "))
        #expect(caption.hasSuffix(" • 4K"))
    }

    @Test("ETA wording exposes estimated-total provenance")
    func estimatedTotalETAWording() {
        let estimated = DownloadRowStatusCaptionPolicy.caption(context(
            bytes: 2_000_000,
            displayFraction: .init(value: 0.25, isEstimated: true),
            isActive: true,
            downloadETA: 90))
        #expect(estimated.contains("roughly 2 min left"))

        let exact = DownloadRowStatusCaptionPolicy.caption(context(
            bytes: 2_000_000,
            displayFraction: .init(value: 0.25, isEstimated: false),
            isActive: true,
            downloadETA: 90))
        #expect(exact.contains("~2 min left"))
    }

    private func context(status: DownloadStatus = .downloading,
                         progress: Double = 0,
                         bytes: Int = 0,
                         lane: DownloadLane = .original,
                         backend: DownloadBackendKind = .plex,
                         resumeMode: DownloadResumeMode? = nil,
                         isServerPreparedVersion: Bool = false,
                         resolutionLabel: String? = nil,
                         displayFraction: DownloadProgressDisplay.Fraction? = nil,
                         isActive: Bool = false,
                         isBackendConfigured: Bool = true,
                         isTranscodeLimited: Bool = false,
                         serverPrepState: String? = nil,
                         serverPrepProgress: Double? = nil,
                         serverPrepETA: TimeInterval? = nil,
                         downloadETA: TimeInterval? = nil,
                         downloadSpeedBytesPerSecond: Double? = nil,
                         hasServerPrepQueueTitle: Bool = false,
                         isRetrying: Bool = false,
                         failureCaption: String? = nil) -> DownloadRowStatusCaptionPolicy.Context {
        DownloadRowStatusCaptionPolicy.Context(status: status,
                                               progress: progress,
                                               bytes: bytes,
                                               lane: lane,
                                               backend: backend,
                                               resumeMode: resumeMode,
                                               isServerPreparedVersion: isServerPreparedVersion,
                                               resolutionLabel: resolutionLabel,
                                               displayFraction: displayFraction,
                                               isActive: isActive,
                                               isBackendConfigured: isBackendConfigured,
                                               isTranscodeLimited: isTranscodeLimited,
                                               serverPrepState: serverPrepState,
                                               serverPrepProgress: serverPrepProgress,
                                               serverPrepETA: serverPrepETA,
                                               downloadETA: downloadETA,
                                               downloadSpeedBytesPerSecond: downloadSpeedBytesPerSecond,
                                               hasServerPrepQueueTitle: hasServerPrepQueueTitle,
                                               isRetrying: isRetrying,
                                               failureCaption: failureCaption)
    }
}
