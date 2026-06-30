import Foundation
import Testing
@testable import PMSKit

@Suite("Plex original fallback policy")
struct PlexOriginalFallbackPolicyTests {
    private let url = URL(fileURLWithPath: "/tmp/visionplay-plex-fallback.mp4")

    @Test("Fallback requires a true Plex original row with no transcode or prep ownership and a Plex session")
    func eligibility() {
        let plexOriginal = record(backend: .plex)
        #expect(PlexOriginalFallbackPolicy.shouldFallback(record: plexOriginal,
                                                         ratingKey: plexOriginal.ratingKey,
                                                         isTranscodeSourced: false,
                                                         hasServerPrepQueueTitle: false,
                                                         hasPlexSession: true))
        #expect(!PlexOriginalFallbackPolicy.shouldFallback(record: plexOriginal,
                                                          ratingKey: plexOriginal.ratingKey,
                                                          isTranscodeSourced: true,
                                                          hasServerPrepQueueTitle: false,
                                                          hasPlexSession: true))
        #expect(!PlexOriginalFallbackPolicy.shouldFallback(record: plexOriginal,
                                                          ratingKey: plexOriginal.ratingKey,
                                                          isTranscodeSourced: false,
                                                          hasServerPrepQueueTitle: true,
                                                          hasPlexSession: true))
        #expect(!PlexOriginalFallbackPolicy.shouldFallback(record: plexOriginal,
                                                          ratingKey: plexOriginal.ratingKey,
                                                          isTranscodeSourced: false,
                                                          hasServerPrepQueueTitle: false,
                                                          hasPlexSession: false))
        #expect(!PlexOriginalFallbackPolicy.shouldFallback(record: record(backend: .jellyfin),
                                                          ratingKey: "jellyfin:item-1",
                                                          isTranscodeSourced: false,
                                                          hasServerPrepQueueTitle: false,
                                                          hasPlexSession: true))
        #expect(!PlexOriginalFallbackPolicy.shouldFallback(record: record(backend: .plex,
                                                                         optimizeTargetName: "720p 4 Mbps"),
                                                          ratingKey: "item-1",
                                                          isTranscodeSourced: false,
                                                          hasServerPrepQueueTitle: false,
                                                          hasPlexSession: true))
        #expect(!PlexOriginalFallbackPolicy.shouldFallback(record: nil,
                                                          ratingKey: "item-1",
                                                          isTranscodeSourced: false,
                                                          hasServerPrepQueueTitle: false,
                                                          hasPlexSession: true))
    }

    @Test("Fallback target uses only explicit download presets before defaulting")
    func fallbackTarget() {
        #expect(PlexOriginalFallbackPolicy.fallbackTarget(storedPreference: " 720p 4 Mbps ",
                                                         defaultPreference: "1080p 8 Mbps") == "720p 4 Mbps")
        #expect(PlexOriginalFallbackPolicy.fallbackTarget(storedPreference: "Original video quality",
                                                         defaultPreference: "1080p 8 Mbps") == "Original video quality")
        #expect(PlexOriginalFallbackPolicy.fallbackTarget(storedPreference: "Optimized for TV",
                                                         defaultPreference: "1080p 8 Mbps") == "1080p 8 Mbps")
        #expect(PlexOriginalFallbackPolicy.fallbackTarget(storedPreference: nil,
                                                         defaultPreference: "1080p 8 Mbps") == "1080p 8 Mbps")
    }

    private func record(backend: DownloadBackendKind,
                        optimizeTargetName: String? = nil) -> DownloadRecord {
        let ratingKey = DownloadRecordIdentity.recordKey(for: "item-1", backend: backend)
        let metadata = OfflineMetadata(ratingKey: ratingKey,
                                       title: "Title",
                                       type: "movie",
                                       optimizeTargetName: optimizeTargetName,
                                       backendKind: backend,
                                       downloadLane: .original,
                                       resumeMode: .staticByteRange)
        return DownloadRecord(ratingKey: ratingKey,
                              title: "Title",
                              localURL: url,
                              status: .failed,
                              metadata: metadata)
    }
}
