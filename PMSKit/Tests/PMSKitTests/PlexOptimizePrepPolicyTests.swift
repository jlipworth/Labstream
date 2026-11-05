import Foundation
import Testing
@testable import PMSKit

struct PlexOptimizePrepPolicyTests {
    @Test func unavailableIsNeverAbsence() {
        #expect(PlexOptimizePrepPolicy.queueLookup(inspected: false, matchingItemPresent: false) == .unavailable)
        #expect(PlexOptimizePrepPolicy.queueLookup(inspected: true, matchingItemPresent: false) == .inspectedAbsent)
        #expect(PlexOptimizePrepPolicy.queueLookup(inspected: true, matchingItemPresent: true) == .present)
        for dispatchedAt: Double? in [nil, 1] {
            #expect(PlexOptimizePrepPolicy.action(queue: .unavailable, metadataInspected: true,
                                                 dispatchedAt: dispatchedAt, now: 1_000) == .keepInspecting)
        }
    }

    @Test func createGraceSurvivesRepeatedInspectionAndRelaunch() throws {
        var metadata = OfflineMetadata(ratingKey: "item", title: "Fixture", type: "movie")
        metadata.plexOptimizeCreateDispatchedAtEpochSeconds = 100
        let relaunched = try JSONDecoder().decode(OfflineMetadata.self, from: JSONEncoder().encode(metadata))
        for now in [100.0, 150, 279.9] {
            #expect(PlexOptimizePrepPolicy.action(queue: .inspectedAbsent, metadataInspected: true,
                                                 dispatchedAt: relaunched.plexOptimizeCreateDispatchedAtEpochSeconds,
                                                 now: now) == .keepInspecting)
        }
        #expect(PlexOptimizePrepPolicy.action(queue: .inspectedAbsent, metadataInspected: true,
                                             dispatchedAt: 100, now: 280) == .failMissingCreate)
    }

    @Test func createAndFailureRequireSuccessfulMetadataInspection() {
        #expect(PlexOptimizePrepPolicy.action(queue: .inspectedAbsent, metadataInspected: true,
                                             dispatchedAt: nil, now: 500) == .create)
        for dispatchedAt: Double? in [nil, 1] {
            #expect(PlexOptimizePrepPolicy.action(queue: .inspectedAbsent, metadataInspected: false,
                                                 dispatchedAt: dispatchedAt, now: 500) == .keepInspecting)
            #expect(PlexOptimizePrepPolicy.action(queue: .present, metadataInspected: true,
                                                 dispatchedAt: dispatchedAt, now: 500) == .keepInspecting)
        }
    }

    @Test func adoptionKeepsSourceExclusionTierAndPlayability() {
        let source = Part(id: 1, key: "/source", file: "/fixture/source.mkv", container: "mkv")
        let chosen = Part(id: 2, key: "/chosen", file: "/fixture/Plex Versions/chosen.mp4", container: "mp4")
        let low = Part(id: 3, key: "/low", file: "/fixture/Plex Versions/low.mp4", container: "mp4")
        let incompatible = Part(id: 4, key: "/incompatible", file: "/fixture/Plex Versions/incompatible.mkv", container: "mkv")
        let media = [Media(id: 1, width: 1920, height: 1080, part: [source]),
                     Media(id: 2, width: 1280, height: 720, part: [low]),
                     Media(id: 3, width: 1920, height: 1080, part: [incompatible]),
                     Media(id: 4, width: 1920, height: 1080, part: [chosen])]
        #expect(PlexOptimizePrepPolicy.candidate(from: media, baselinePartIDs: [1],
                                                targetName: "1080p", sourceHeight: 1080)?.id == 2)
        #expect(PlexOptimizePrepPolicy.candidate(from: media, baselinePartIDs: [1, 2],
                                                targetName: "1080p", sourceHeight: 1080) == nil)
    }

    @Test func embyPollerEndCannotRemoveSuccessor() {
        var tracker = ServerPrepAttemptTracker()
        let key = DownloadAttemptKey(ratingKey: "emby:item", attemptID: DownloadAttemptID(uuid: UUID()))
        let old = tracker.beginEmbyConvertPoller(for: key)!
        let duplicate = tracker.beginEmbyConvertPoller(for: key)
        #expect(duplicate == nil)
        tracker.releaseAll(for: key)
        let current = tracker.beginEmbyConvertPoller(for: key)!
        let staleEnd = tracker.endEmbyConvertPoller(for: key, id: old)
        #expect(!staleEnd)
        #expect(tracker.isCurrentEmbyConvertAttempt(for: key, id: current))
        let currentEnd = tracker.endEmbyConvertPoller(for: key, id: current)
        #expect(currentEnd)
    }
}
