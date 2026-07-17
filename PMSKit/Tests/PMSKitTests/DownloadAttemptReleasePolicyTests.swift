import Foundation
import Testing
@testable import PMSKit

struct DownloadAttemptReleasePolicyTests {
    @Test func currentAttemptReleasesItsExactResourcesAndCurrentState() {
        let attemptA = key("item", "attempt-A")

        let plan = DownloadAttemptReleasePolicy.plan(
            releasing: attemptA,
            currentOwner: attemptA
        )

        #expect(plan.exactResourceOwner == attemptA)
        #expect(plan.releaseCurrentState)
    }

    @Test func staleAttemptCannotReleaseReplacementStateForSameRatingKey() {
        let attemptA = key("item", "attempt-A")
        let attemptB = key("item", "attempt-B")

        let plan = DownloadAttemptReleasePolicy.plan(
            releasing: attemptA,
            currentOwner: attemptB
        )

        #expect(plan.exactResourceOwner == attemptA)
        #expect(!plan.releaseCurrentState)
    }

    @Test func staleAttemptCannotRedirectExactTeardownToReplacement() {
        let attemptA = key("item", "attempt-A")
        let attemptB = key("item", "attempt-B")

        let planA = DownloadAttemptReleasePolicy.plan(
            releasing: attemptA,
            currentOwner: attemptB
        )
        let planB = DownloadAttemptReleasePolicy.plan(
            releasing: attemptB,
            currentOwner: attemptB
        )

        #expect(planA.exactResourceOwner == attemptA)
        #expect(planB.exactResourceOwner == attemptB)
        #expect(!planA.releaseCurrentState)
        #expect(planB.releaseCurrentState)
    }

    @Test func ownerlessStateIsNotImplicitlyClearedByExactRelease() {
        let attemptA = key("item", "attempt-A")

        let plan = DownloadAttemptReleasePolicy.plan(
            releasing: attemptA,
            currentOwner: nil
        )

        #expect(plan.exactResourceOwner == attemptA)
        #expect(!plan.releaseCurrentState)
    }

    private func key(_ ratingKey: String, _ attemptID: String) -> DownloadAttemptKey {
        DownloadAttemptKey(
            ratingKey: ratingKey,
            attemptID: DownloadAttemptID(rawValue: attemptID)!
        )
    }
}
