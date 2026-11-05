import Foundation
import Testing
@testable import PMSKit

@Suite("Download backend retry intent policy")
struct DownloadBackendRetryIntentPolicyTests {
    private let localURL = URL(fileURLWithPath: "/tmp/labstream-retry-intent.mp4")

    @Test("Jellyfin retry preserves persisted target, compatible lane, original metadata, and fallback default")
    func jellyfinIntent() {
        let optimized = record(metadata: metadata(backend: .jellyfin,
                                                  optimizeTargetName: "Original video quality",
                                                  mediaIndex: 2,
                                                  partIndex: 1,
                                                  mediaSourceID: "source-1",
                                                  audioStreamIndex: 7))
        let optimizedIntent = DownloadBackendRetryIntentPolicy.jellyfinIntent(
            for: optimized,
            fallbackItemID: "fallback",
            fallbackOriginalIsLocallyPlayable: false)
        #expect(optimizedIntent.choice == .optimize(targetName: DownloadPresetPolicy.jellyfinDefaultDownloadPreset))
        #expect(optimizedIntent.mediaIndex == 2)
        #expect(optimizedIntent.partIndex == 1)
        #expect(optimizedIntent.mediaSourceIDOverride == "source-1")
        #expect(optimizedIntent.audioStreamIndex == 7)

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
                                                 audioStreamIndex: 9,
                                                 lane: .original,
                                                 resumeMode: .staticByteRange,
                                                 serverPreparedVersion: true))
        let existingIntent = DownloadBackendRetryIntentPolicy.embyIntent(for: existing,
                                                                         fallbackItemID: "fallback")
        #expect(existingIntent.choice == .existingVersion)
        #expect(existingIntent.mediaSourceIDOverride == "converted-source")
        #expect(existingIntent.audioStreamIndex == 9)

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

    @Test("B34: a failed Plex optimize row retries its persisted requested target, not the default")
    func plexFailedOptimizeRetryKeepsRequestedTarget() {
        // e.g. the 24 h deadline, completed_part_missing or optimize_status_failed.
        let failedOptimize = record(metadata: metadata(backend: .plex,
                                                       optimizeTargetName: "Original video quality",
                                                       lane: .optimize,
                                                       resumeMode: .serverPrepThenStatic))
        #expect(DownloadBackendRetryIntentPolicy.plexPersistedOptimizeTarget(for: failedOptimize)
            == "Original video quality")
        let padded = record(metadata: metadata(backend: .plex,
                                               optimizeTargetName: "  720p 4 Mbps ",
                                               lane: .optimize,
                                               resumeMode: .serverPrepThenStatic))
        #expect(DownloadBackendRetryIntentPolicy.plexPersistedOptimizeTarget(for: padded) == "720p 4 Mbps")

        // No persisted target (a true original, or a blank legacy value) keeps the re-probe path.
        let original = record(metadata: metadata(backend: .plex, lane: .original,
                                                 resumeMode: .staticByteRange))
        #expect(DownloadBackendRetryIntentPolicy.plexPersistedOptimizeTarget(for: original) == nil)
        let blank = record(metadata: metadata(backend: .plex, optimizeTargetName: "  ",
                                              lane: .optimize, resumeMode: .serverPrepThenStatic))
        #expect(DownloadBackendRetryIntentPolicy.plexPersistedOptimizeTarget(for: blank) == nil)
        #expect(DownloadBackendRetryIntentPolicy.plexPersistedOptimizeTarget(for: record(metadata: nil)) == nil)
        // Other backends own their own retry intents.
        let jellyfin = record(metadata: metadata(backend: .jellyfin, optimizeTargetName: "720p 4 Mbps"))
        #expect(DownloadBackendRetryIntentPolicy.plexPersistedOptimizeTarget(for: jellyfin) == nil)
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
                          audioStreamIndex: Int? = nil,
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
                               audioStreamIndex: audioStreamIndex,
                               downloadLane: lane,
                               resumeMode: resumeMode,
                               serverPreparedVersion: serverPreparedVersion ? true : nil)
    }
}
