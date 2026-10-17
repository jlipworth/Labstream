#if !os(tvOS)
import Foundation
import PMSKit
import Testing
@testable import Labstream

@Suite("Season download planner sheet")
struct SeasonDownloadPlannerSheetTests {
    /// B68: the planning state reports N-of-M instead of an indeterminate label.
    @Test func planningProgressTextCountsEpisodes() {
        #expect(SeasonDownloadPlannerSheet.planningProgressText(done: 0, total: 22)
                == "Planning episode 1 of 22…")
        #expect(SeasonDownloadPlannerSheet.planningProgressText(done: 21, total: 22)
                == "Planning episode 22 of 22…")
        #expect(SeasonDownloadPlannerSheet.planningProgressText(done: 22, total: 22)
                == "Planning episode 22 of 22…")
        #expect(SeasonDownloadPlannerSheet.planningProgressText(done: 0, total: 0)
                == "Planning each episode…")
    }
}
#endif
