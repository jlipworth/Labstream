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

    /// B70: the sheet captures its backend once at presentation, like DownloadOptionsSheet, so a
    /// backend switch while it is mounted cannot mint rows under the new backend's identity.
    @Test func sheetCapturesBackendAtPresentation() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let sheet = try String(contentsOf: root.appendingPathComponent(
            "Labstream/Capabilities/Downloads/UI/SeasonDownloadPlannerSheet.swift"), encoding: .utf8)
        #expect(!sheet.contains("appModel.activeBackend"))
        #expect(sheet.contains("init(season: MediaItem, backend: DownloadBackendKind)"))
        let browser = try String(contentsOf: root.appendingPathComponent(
            "Labstream/Shared/UI/ContainerBrowserView.swift"), encoding: .utf8)
        #expect(browser.contains("SeasonDownloadPlannerSheet(season: container, backend:"))
    }
}
#endif
