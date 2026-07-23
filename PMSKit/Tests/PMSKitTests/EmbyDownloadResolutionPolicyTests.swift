import Foundation
import Testing
@testable import PMSKit

@Suite("Emby negotiated download resolution persistence (#253)")
struct EmbyDownloadResolutionPolicyTests {
    @Test("Explicit existing-version and convert/reuse handoffs persist wide 1080p dimensions")
    func existingVersionOriginsConvergeOnWidthAwareLabel() {
        // Explicit selection, completed-convert handoff, reuse, and season admission all enter
        // DownloadManager.downloadEmby as `.existingVersion` and therefore share this boundary.
        for queueTimeLabel in ["4K", "720p", nil] as [String?] {
            #expect(resolved(
                choice: .existingVersion,
                currentLabel: queueTimeLabel,
                width: 1920,
                height: 800
            ) == "1080p")
        }
    }

    @Test("Canonical standard and wide-aspect tiers remain unchanged")
    func canonicalTiers() {
        #expect(resolved(choice: .existingVersion, width: 1920, height: 1080) == "1080p")
        #expect(resolved(choice: .existingVersion, width: 1280, height: 720) == "720p")
        #expect(resolved(choice: .existingVersion, width: 1280, height: 534) == "720p")
    }

    @Test("Missing width retains the documented height-only fallback")
    func missingWidthFallback() {
        #expect(resolved(
            choice: .existingVersion,
            currentLabel: "4K",
            width: nil,
            height: 800
        ) == "720p")
        #expect(resolved(
            choice: .existingVersion,
            currentLabel: "Original label",
            width: nil,
            height: nil
        ) == "Original label")
    }

    @Test("Original and non-existing lanes retain their source or requested label")
    func nonExistingLanesAreNotCorrected() {
        let choices: [DownloadIntentChoice] = [
            .original,
            .optimize(targetName: "1080p 8 Mbps"),
            .optimizeCompatible,
        ]
        for choice in choices {
            #expect(resolved(
                choice: choice,
                currentLabel: "4K",
                width: 1920,
                height: 800
            ) == "4K")
        }
    }

    @Test("Existing-version submenu and persisted row cannot diverge for identical dimensions")
    func submenuAndPersistedLabelParity() {
        let version = EmbyPlayback.EmbyExistingVersion(
            mediaSourceId: "converted-wide",
            name: "Converted",
            container: "mp4",
            videoCodec: nil,
            audioCodec: "aac",
            size: nil,
            width: 1920,
            height: 800,
            bitrate: nil,
            supportsDirectPlay: true
        )
        let menuLabel = DownloadExistingVersionOptionPolicy.embyVersionLabel(version)
        let persistedLabel = resolved(
            choice: .existingVersion,
            currentLabel: "4K",
            width: version.width,
            height: version.height
        )

        #expect(menuLabel == "1080p")
        #expect(persistedLabel == menuLabel)
    }

    @Test("Persisted label survives relaunch and feeds active and completed captions")
    func durableLabelFeedsCaptions() throws {
        let label = resolved(
            choice: .existingVersion,
            currentLabel: "720p",
            width: 1920,
            height: 800
        )
        let metadata = OfflineMetadata(
            ratingKey: "emby:wide",
            title: "Fixture",
            type: "movie",
            resolutionLabel: label,
            backendKind: .emby,
            downloadLane: .original,
            resumeMode: .staticByteRange,
            serverPreparedVersion: true
        )
        let relaunchedMetadata = try JSONDecoder().decode(
            OfflineMetadata.self,
            from: JSONEncoder().encode(metadata)
        )

        #expect(relaunchedMetadata.resolutionLabel == "1080p")
        #expect(caption(status: .downloading, metadata: relaunchedMetadata).contains("1080p"))
        #expect(caption(status: .complete, metadata: relaunchedMetadata).contains("1080p"))
    }

    private func resolved(
        choice: DownloadIntentChoice,
        currentLabel: String? = nil,
        width: Int?,
        height: Int?
    ) -> String? {
        EmbyDownloadResolutionPolicy.persistedLabel(
            choice: choice,
            currentLabel: currentLabel,
            negotiatedWidth: width,
            negotiatedHeight: height
        )
    }

    private func caption(status: DownloadStatus, metadata: OfflineMetadata) -> String {
        let isActive = status == .downloading
        let record = DownloadRecord(
            ratingKey: "emby:wide",
            title: "Fixture",
            localURL: URL(fileURLWithPath: "/tmp/fixture.mp4"),
            bytes: 1_000,
            progress: status == .complete ? 1 : 0.5,
            status: status,
            metadata: metadata
        )
        let context = DownloadRowStatusCaptionPolicy.Context(
            record: record,
            displayFraction: .init(value: status == .complete ? 1 : 0.5, isEstimated: false),
            isActive: isActive,
            isBackendConfigured: true,
            isTranscodeLimited: false,
            serverPrepState: nil,
            serverPrepProgress: nil,
            serverPrepETA: nil,
            downloadETA: nil,
            downloadSpeedBytesPerSecond: nil,
            isRetrying: false,
            failureCaption: nil
        )
        return DownloadRowStatusCaptionPolicy.caption(context)
    }
}
