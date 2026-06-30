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

    @Test("Transfer finalizing caption uses local verification wording")
    func transferFinalizingCaption() {
        let caption = DownloadRowStatusCaptionPolicy.caption(context(
            progress: 1.0,
            bytes: 1_000_000,
            resolutionLabel: "4K"))

        #expect(caption.hasPrefix("Verifying download… • "))
        #expect(caption.hasSuffix(" • 4K"))
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
                         isCheckpointPausing: Bool = false,
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
                                               isCheckpointPausing: isCheckpointPausing,
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
