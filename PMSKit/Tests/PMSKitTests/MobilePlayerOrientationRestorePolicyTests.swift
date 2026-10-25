import Testing
@testable import PMSKit

struct MobilePlayerOrientationRestorePolicyTests {
    @Test func portraitAndUnknownRestoreToPortrait() {
        #expect(MobilePlayerOrientationRestorePolicy.target(after: .portrait) == .portrait)
        #expect(MobilePlayerOrientationRestorePolicy.target(after: .unknown) == .portrait)
    }

    @Test func genuineLandscapeLaunchPreservesItsSide() {
        #expect(MobilePlayerOrientationRestorePolicy.target(after: .landscapeLeft) == .landscapeLeft)
        #expect(MobilePlayerOrientationRestorePolicy.target(after: .landscapeRight) == .landscapeRight)
    }
}

struct MobilePlayerOrientationRestoreActionTests {
    private typealias Policy = MobilePlayerOrientationRestorePolicy

    @Test func unlockedSessionRestoresNothing() {
        #expect(Policy.action(previous: .portrait, didLock: false, entryClass: .large, currentClass: .large) == .none)
        #expect(Policy.action(previous: .portrait, didLock: false, entryClass: .phone, currentClass: .large) == .none)
    }

    @Test func sameDisplayClassRestoresTheEntryOrientation() {
        #expect(Policy.action(previous: .portrait, didLock: true, entryClass: .phone, currentClass: .phone)
                == .request(.portrait))
        #expect(Policy.action(previous: .landscapeRight, didLock: true, entryClass: .phone, currentClass: .phone)
                == .request(.landscapeRight))
        #expect(Policy.action(previous: .unknown, didLock: true, entryClass: nil, currentClass: .phone)
                == .request(.portrait))
    }

    @Test func displayClassChangeOnlyWidensTheMask() {
        // Opened folded, closed after unfolding.
        #expect(Policy.action(previous: .portrait, didLock: true, entryClass: .phone, currentClass: .large)
                == .widenMaskOnly)
        // Opened unfolded, folded during playback (lock applied), closed folded.
        #expect(Policy.action(previous: .portrait, didLock: true, entryClass: .large, currentClass: .phone)
                == .widenMaskOnly)
    }
}
