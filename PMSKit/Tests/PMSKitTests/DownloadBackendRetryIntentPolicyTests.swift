import Foundation
import Testing
@testable import PMSKit

@Suite("Download backend retry intent policy")
struct DownloadBackendRetryIntentPolicyTests {
    private let localURL = URL(fileURLWithPath: "/tmp/visionplay-retry-intent.mp4")

    @Test("Jellyfin retry preserves persisted target, compatible lane, original metadata, and fallback default")
    func jellyfinIntent() {
        let optimized = record(metadata: metadata(backend: .jellyfin,
                                                  optimizeTargetName: "Original video quality",
                                                  mediaIndex: 2,
                                                  partIndex: 1,
                                                  mediaSourceID: "source-1"))
        let optimizedIntent = DownloadBackendRetryIntentPolicy.jellyfinIntent(
            for: optimized,
            fallbackItemID: "fallback",
            fallbackOriginalIsLocallyPlayable: false)
        #expect(optimizedIntent.choice == .optimize(targetName: DownloadPresetPolicy.jellyfinDefaultDownloadPreset))
        #expect(optimizedIntent.mediaIndex == 2)
        #expect(optimizedIntent.partIndex == 1)
        #expect(optimizedIntent.mediaSourceIDOverride == "source-1")

        let compatible = record(metadata: metadata(backend: .jellyfin,
                                                   lane: .compatibleRemux,
                                                   resumeMode: .liveForwardOnly))
        #expect(DownloadBackendRetryIntentPolicy.jellyfinIntent(for: compatible,
                                                               fallbackItemID: "fallback",
                                                               fallbackOriginalIsLocallyPlayable: false).choice == .optimizeCompatible)

        let original = record(metadata: metadata(backend: .jellyfin,
                                                lane: .original,
                                                resumeMode: .staticByteRange))
        #expect(DownloadBackendRetryIntentPolicy.jellyfinIntent(for: original,
                                                               fallbackItemID: "fallback",
                                                               fallbackOriginalIsLocallyPlayable: false).choice == .original)

        let legacy = record(metadata: nil)
        #expect(DownloadBackendRetryIntentPolicy.jellyfinIntent(for: legacy,
                                                               fallbackItemID: "legacy-item",
                                                               fallbackOriginalIsLocallyPlayable: false).choice
            == .optimize(targetName: DownloadPresetPolicy.jellyfinDefaultDownloadPreset))
        #expect(DownloadBackendRetryIntentPolicy.jellyfinIntent(for: legacy,
                                                               fallbackItemID: "legacy-item",
                                                               fallbackOriginalIsLocallyPlayable: true).choice == .original)
    }

    @Test("Emby retry preserves server-prepared sources, optimize targets, compatible remux, and original")
    func embyIntent() {
        let existing = record(metadata: metadata(backend: .emby,
                                                 mediaSourceID: "converted-source",
                                                 lane: .original,
                                                 resumeMode: .staticByteRange,
                                                 serverPreparedVersion: true))
        let existingIntent = DownloadBackendRetryIntentPolicy.embyIntent(for: existing,
                                                                         fallbackItemID: "fallback")
        #expect(existingIntent.choice == .existingVersion)
        #expect(existingIntent.mediaSourceIDOverride == "converted-source")

        let optimized = record(metadata: metadata(backend: .emby,
                                                  optimizeTargetName: "720p 3 Mbps"))
        #expect(DownloadBackendRetryIntentPolicy.embyIntent(for: optimized,
                                                           fallbackItemID: "fallback").choice
            == .optimize(targetName: "720p 3 Mbps"))

        let compatible = record(metadata: metadata(backend: .emby,
                                                   lane: .compatibleRemux,
                                                   resumeMode: .liveForwardOnly))
        #expect(DownloadBackendRetryIntentPolicy.embyIntent(for: compatible,
                                                           fallbackItemID: "fallback").choice == .optimizeCompatible)

        let original = record(metadata: metadata(backend: .emby,
                                                lane: .original,
                                                resumeMode: .staticByteRange))
        #expect(DownloadBackendRetryIntentPolicy.embyIntent(for: original,
                                                           fallbackItemID: "fallback").choice == .original)
    }

    private func record(metadata: OfflineMetadata?) -> DownloadRecord {
        DownloadRecord(ratingKey: metadata?.ratingKey ?? "jellyfin:legacy",
                       title: metadata?.title ?? "Legacy",
                       localURL: localURL,
                       status: .failed,
                       metadata: metadata)
    }

    private func metadata(backend: DownloadBackendKind,
                          optimizeTargetName: String? = nil,
                          mediaIndex: Int = 0,
                          partIndex: Int = 0,
                          mediaSourceID: String? = nil,
                          lane: DownloadLane? = nil,
                          resumeMode: DownloadResumeMode? = nil,
                          serverPreparedVersion: Bool = false) -> OfflineMetadata {
        let ratingKey = DownloadRecordIdentity.recordKey(for: "item-1", backend: backend)
        return OfflineMetadata(ratingKey: ratingKey,
                               title: "Title",
                               type: "movie",
                               mediaIndex: mediaIndex,
                               partIndex: partIndex,
                               optimizeTargetName: optimizeTargetName,
                               backendKind: backend,
                               mediaSourceID: mediaSourceID,
                               downloadLane: lane,
                               resumeMode: resumeMode,
                               serverPreparedVersion: serverPreparedVersion ? true : nil)
    }
}
