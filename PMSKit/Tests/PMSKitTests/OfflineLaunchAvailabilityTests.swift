import Foundation
import Testing
@testable import PMSKit

@Suite("Offline launch availability")
struct OfflineLaunchAvailabilityTests {
    private let file = URL(fileURLWithPath: "/tmp/offline-launch-test.mp4")

    @Test("requires a completed row whose local file still exists")
    func requiresCompletedPresentFile() {
        let complete = DownloadRecord(ratingKey: "plex:item", title: "Item",
                                      localURL: file, status: .complete)
        let unverified = DownloadRecord(ratingKey: "jellyfin:item", title: "Item",
                                        localURL: file, status: .unverified)
        let queued = DownloadRecord(ratingKey: "emby:item", title: "Item",
                                    localURL: file, status: .queued)

        #expect(OfflineLaunchAvailability.hasPlayableDownload(records: [complete]) { _ in true })
        #expect(OfflineLaunchAvailability.hasPlayableDownload(records: [unverified]) { _ in true })
        #expect(!OfflineLaunchAvailability.hasPlayableDownload(records: [queued]) { _ in true })
        #expect(!OfflineLaunchAvailability.hasPlayableDownload(records: [complete]) { _ in false })
        #expect(!OfflineLaunchAvailability.hasPlayableDownload(records: []) { _ in true })
    }

    @Test("admits only a transient restore failure with a playable download on a download product")
    func admitsOnlyTransientFailureWithPlayableDownload() {
        #expect(OfflineLaunchAvailability.admitsOfflineLaunch(
            restoreOutcome: .temporarilyUnavailable, downloadsSupported: true,
            hasPlayableDownload: true))

        let refused: [SessionRestoreOutcome?] = [
            nil, .restored, .missingCredential, .invalidCredential, .unconfirmedIdentity
        ]
        for outcome in refused {
            #expect(!OfflineLaunchAvailability.admitsOfflineLaunch(
                restoreOutcome: outcome, downloadsSupported: true, hasPlayableDownload: true))
        }
        // No completed local media file: keep the sign-in/retry surface.
        #expect(!OfflineLaunchAvailability.admitsOfflineLaunch(
            restoreOutcome: .temporarilyUnavailable, downloadsSupported: true,
            hasPlayableDownload: false))
        // tvOS ships no downloads capability.
        #expect(!OfflineLaunchAvailability.admitsOfflineLaunch(
            restoreOutcome: .temporarilyUnavailable, downloadsSupported: false,
            hasPlayableDownload: true))
    }
}

@Suite("Session restore outcome")
struct SessionRestoreOutcomeTests {
    @Test("only missing and invalid credentials are retired")
    func retainsSavedCredential() {
        #expect(SessionRestoreOutcome.restored.retainsSavedCredential)
        #expect(SessionRestoreOutcome.temporarilyUnavailable.retainsSavedCredential)
        #expect(SessionRestoreOutcome.unconfirmedIdentity.retainsSavedCredential)
        #expect(!SessionRestoreOutcome.missingCredential.retainsSavedCredential)
        #expect(!SessionRestoreOutcome.invalidCredential.retainsSavedCredential)
    }

    @Test("runtime readiness is authoritative")
    func reconcilesWithRuntimeReadiness() {
        let all: [SessionRestoreOutcome] = [
            .restored, .missingCredential, .invalidCredential, .unconfirmedIdentity,
            .temporarilyUnavailable
        ]
        for outcome in all {
            #expect(outcome.reconciled(hasUsableSession: true) == .restored)
        }
        #expect(SessionRestoreOutcome.restored.reconciled(hasUsableSession: false)
            == .temporarilyUnavailable)
        #expect(SessionRestoreOutcome.invalidCredential.reconciled(hasUsableSession: false)
            == .invalidCredential)
        #expect(SessionRestoreOutcome.missingCredential.reconciled(hasUsableSession: false)
            == .missingCredential)
        #expect(SessionRestoreOutcome.unconfirmedIdentity.reconciled(hasUsableSession: false)
            == .unconfirmedIdentity)
        #expect(SessionRestoreOutcome.temporarilyUnavailable.reconciled(hasUsableSession: false)
            == .temporarilyUnavailable)
    }
}
