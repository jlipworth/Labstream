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

    @Test("admits only a transient restore failure with a playable download")
    func admitsOnlyTransientFailureWithPlayableDownload() {
        #expect(OfflineLaunchAvailability.admitsOfflineLaunch(
            restoreOutcome: .temporarilyUnavailable, hasPlayableDownload: true))

        let refused: [SessionRestoreOutcome?] = [
            nil, .restored, .missingCredential, .invalidCredential, .unconfirmedCredential
        ]
        for outcome in refused {
            #expect(!OfflineLaunchAvailability.admitsOfflineLaunch(
                restoreOutcome: outcome, hasPlayableDownload: true))
        }
        // No completed local media file: keep the sign-in/retry surface.
        #expect(!OfflineLaunchAvailability.admitsOfflineLaunch(
            restoreOutcome: .temporarilyUnavailable, hasPlayableDownload: false))
    }

    @Test("an HTTP 403 restore never opens Offline; 429/5xx/transport do")
    func forbiddenNeverAdmitsOffline() {
        #expect(SessionRestoreOutcome.preservedFailure(httpStatus: 403) == .unconfirmedCredential)
        #expect(!OfflineLaunchAvailability.admitsOfflineLaunch(
            restoreOutcome: .preservedFailure(httpStatus: 403), hasPlayableDownload: true))
        for status in [nil, 429, 500, 502, 503] as [Int?] {
            #expect(SessionRestoreOutcome.preservedFailure(httpStatus: status)
                == .temporarilyUnavailable)
            #expect(OfflineLaunchAvailability.admitsOfflineLaunch(
                restoreOutcome: .preservedFailure(httpStatus: status), hasPlayableDownload: true))
        }
    }
}

@Suite("Session restore outcome")
struct SessionRestoreOutcomeTests {
    @Test("only missing and invalid credentials are retired")
    func retainsSavedCredential() {
        #expect(SessionRestoreOutcome.restored.retainsSavedCredential)
        #expect(SessionRestoreOutcome.temporarilyUnavailable.retainsSavedCredential)
        #expect(SessionRestoreOutcome.unconfirmedCredential.retainsSavedCredential)
        #expect(!SessionRestoreOutcome.missingCredential.retainsSavedCredential)
        #expect(!SessionRestoreOutcome.invalidCredential.retainsSavedCredential)
    }

    @Test("runtime readiness is authoritative")
    func reconcilesWithRuntimeReadiness() {
        let all: [SessionRestoreOutcome] = [
            .restored, .missingCredential, .invalidCredential, .unconfirmedCredential,
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
        #expect(SessionRestoreOutcome.unconfirmedCredential.reconciled(hasUsableSession: false)
            == .unconfirmedCredential)
        #expect(SessionRestoreOutcome.temporarilyUnavailable.reconciled(hasUsableSession: false)
            == .temporarilyUnavailable)
    }
}
