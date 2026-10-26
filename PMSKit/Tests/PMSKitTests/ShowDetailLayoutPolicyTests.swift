import Foundation
import Testing
@testable import PMSKit

struct ShowDetailLayoutPolicyTests {
    @Test func foldedAndUprightPushTheSeason() {
        // Folded portrait and landscape (compact), unfolded upright (regular, portrait).
        #expect(ShowDetailLayoutPolicy.layout(width: 376, height: 678, regularWidth: false) == .single)
        #expect(ShowDetailLayoutPolicy.layout(width: 588, height: 466, regularWidth: false) == .single)
        #expect(ShowDetailLayoutPolicy.layout(width: 669, height: 951, regularWidth: true) == .single)
    }

    @Test func sidewaysSplitsShowAndSeasonEvenly() {
        #expect(ShowDetailLayoutPolicy.layout(width: 850, height: 669, regularWidth: true)
                == .split(listWidth: 425, detailStart: 425))
    }

    @Test func bookPutsTheDividerOnTheHinge() {
        #expect(ShowDetailLayoutPolicy.layout(width: 867, height: 669, regularWidth: true,
                                              hinge: (465.5, 485.5))
                == .split(listWidth: 465.5, detailStart: 485.5))
        // A hinge far off-centre is ignored and the split stays even.
        #expect(ShowDetailLayoutPolicy.layout(width: 850, height: 669, regularWidth: true,
                                              hinge: (100, 120))
                == .split(listWidth: 425, detailStart: 425))
    }
}
