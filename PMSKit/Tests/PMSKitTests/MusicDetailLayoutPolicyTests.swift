import Foundation
import Testing
@testable import PMSKit

struct MusicDetailLayoutPolicyTests {
    @Test func foldedAndUprightPosesStack() {
        // Folded portrait / landscape (compact width) and unfolded upright (portrait).
        #expect(MusicDetailLayoutPolicy.layout(width: 382, height: 644, regularWidth: false) == .stacked)
        #expect(MusicDetailLayoutPolicy.layout(width: 594, height: 466, regularWidth: false) == .stacked)
        #expect(MusicDetailLayoutPolicy.layout(width: 669, height: 900, regularWidth: true) == .stacked)
    }

    @Test func unfoldedSidewaysSplitsEvenly() {
        #expect(MusicDetailLayoutPolicy.layout(width: 867, height: 669, regularWidth: true)
                == .columns(leadingWidth: 433.5, trailingStart: 433.5))
    }

    @Test func bookPutsTheColumnGapOnTheHinge() {
        let layout = MusicDetailLayoutPolicy.layout(width: 867, height: 669, regularWidth: true,
                                                    hinge: (465.5, 485.5))
        #expect(layout == .columns(leadingWidth: 465.5, trailingStart: 485.5))
    }

    @Test func anOffCentreHingeFallsBackToAnEvenSplit() {
        let layout = MusicDetailLayoutPolicy.layout(width: 900, height: 600, regularWidth: true,
                                                    hinge: (100, 120))
        #expect(layout == .columns(leadingWidth: 450, trailingStart: 450))
    }

    @Test func degenerateSizesStack() {
        #expect(MusicDetailLayoutPolicy.layout(width: .nan, height: 600, regularWidth: true) == .stacked)
        #expect(MusicDetailLayoutPolicy.layout(width: 0, height: 0, regularWidth: true) == .stacked)
    }
}
