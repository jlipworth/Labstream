import Testing
@testable import PMSKit

struct MobilePlayerOrientationLockPolicyTests {
    private typealias Policy = MobilePlayerOrientationLockPolicy

    @Test(arguments: [
        (402.0, 874.0, MobilePlayerDisplayClass.phone),   // iPhone 18 Pro portrait
        (874.0, 402.0, .phone),                            // iPhone 18 Pro landscape
        (466.0, 678.0, .phone),                            // Duo outer, folded portrait
        (678.0, 466.0, .phone),                            // Duo outer, folded landscape
        (669.0, 951.0, .large),                            // Duo inner, unfolded portrait
        (951.0, 669.0, .large),                            // Duo inner, unfolded landscape
        (1032.0, 1376.0, .large),                          // iPad
    ])
    func displayClassComesFromTheShortSide(width: Double, height: Double, expected: MobilePlayerDisplayClass) {
        #expect(Policy.displayClass(sceneWidth: width, sceneHeight: height) == expected)
    }

    @Test func unmeasuredSceneHasNoClassAndNoDecision() {
        #expect(Policy.displayClass(sceneWidth: 0, sceneHeight: 0) == nil)
        #expect(Policy.decision(displayClass: nil, fillsScreen: true, isLocked: false, declinedClass: nil) == .none)
        #expect(Policy.decision(displayClass: nil, fillsScreen: true, isLocked: true, declinedClass: nil) == .none)
    }

    @Test func fillsScreenIgnoresOrientation() {
        #expect(Policy.fillsScreen(sceneWidth: 678, sceneHeight: 466, screenWidth: 466, screenHeight: 678))
        #expect(Policy.fillsScreen(sceneWidth: 669, sceneHeight: 951, screenWidth: 669, screenHeight: 951))
        // A resizable iPad window that happens to be phone-sized.
        #expect(!Policy.fillsScreen(sceneWidth: 420, sceneHeight: 700, screenWidth: 1032, screenHeight: 1376))
    }

    @Test func fullScreenPhoneClassLocksLandscape() {
        // iPhone 18 Pro and the folded Duo, opened from portrait.
        #expect(Policy.decision(displayClass: .phone, fillsScreen: true, isLocked: false, declinedClass: nil)
                == .lockLandscape)
        #expect(Policy.decision(displayClass: .phone, fillsScreen: true, isLocked: true, declinedClass: nil)
                == .none)
    }

    @Test func largeDisplayNeverLocksAndUnfoldReleases() {
        // iPad and the unfolded Duo opened directly.
        #expect(Policy.decision(displayClass: .large, fillsScreen: true, isLocked: false, declinedClass: nil)
                == .none)
        // Unfolding during locked playback releases without forcing a rotation.
        #expect(Policy.decision(displayClass: .large, fillsScreen: true, isLocked: true, declinedClass: nil)
                == .release)
    }

    @Test func foldingBackReappliesTheLock() {
        #expect(Policy.decision(displayClass: .phone, fillsScreen: true, isLocked: false, declinedClass: nil)
                == .lockLandscape)
    }

    @Test func phoneSizedWindowThatDoesNotFillTheScreenIsLeftAlone() {
        #expect(Policy.decision(displayClass: .phone, fillsScreen: false, isLocked: false, declinedClass: nil)
                == .none)
        #expect(Policy.decision(displayClass: .phone, fillsScreen: false, isLocked: true, declinedClass: nil)
                == .release)
    }

    @Test func declinedRequestIsNotRepeatedForTheSameClass() {
        #expect(Policy.decision(displayClass: .phone, fillsScreen: true, isLocked: false, declinedClass: .phone)
                == .none)
        // A declined request for the large class does not suppress a later phone-class lock.
        #expect(Policy.decision(displayClass: .phone, fillsScreen: true, isLocked: false, declinedClass: .large)
                == .lockLandscape)
    }
}
