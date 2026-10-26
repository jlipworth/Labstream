import Foundation
import Testing
@testable import PMSKit

struct SettingsCategoryPolicyTests {
    @Test func everyFormSectionBelongsToExactlyOneCategoryAndEveryCategoryHasASection() {
        for category in SettingsCategory.allCases {
            #expect(!SettingsCategoryPolicy.sections(of: category).isEmpty, "\(category)")
        }
        let covered = SettingsCategory.allCases.flatMap(SettingsCategoryPolicy.sections(of:))
        #expect(Set(covered) == Set(SettingsFormSection.allCases))
        #expect(covered.count == SettingsFormSection.allCases.count)
    }

    @Test func accountAndServerGroupsBackendServerAndAccount() {
        #expect(SettingsCategoryPolicy.sections(of: .accountServer) == [.backend, .server, .account])
        #expect(SettingsCategoryPolicy.anchorSection(for: .accountServer) == .backend)
        #expect(SettingsCategoryPolicy.anchorSection(for: .audioSubtitles) == .audioSubtitles)
    }

    @Test func sidebarDropsDownloadsWhereThePlatformHasNone() {
        #expect(SettingsCategoryPolicy.sidebar(includesDownloads: true).contains(.downloads))
        #expect(!SettingsCategoryPolicy.sidebar(includesDownloads: false).contains(.downloads))
        #expect(SettingsCategoryPolicy.sidebar(includesDownloads: true).first == .accountServer)
    }

    @Test func formPositionPicksTheSectionWhoseHeaderIsLastAboveTheLine() {
        // Scrolled into Playback: its header is above the line, Audio & Subtitles' is below.
        let tops: [SettingsFormSection: Double] = [.backend: -900, .server: -700, .libraries: -300,
                                                   .playback: -120, .audioSubtitles: 420]
        #expect(SettingsCategoryPolicy.category(headerTops: tops, topLine: 200) == .playback)
        // Scrolled to the bottom: Account (grouped under Account & Server).
        let bottom: [SettingsFormSection: Double] = [.about: -200, .account: 80]
        #expect(SettingsCategoryPolicy.category(headerTops: bottom, topLine: 200) == .accountServer)
        // At rest (nothing above the line yet) and unmeasured.
        #expect(SettingsCategoryPolicy.category(headerTops: [.backend: 240], topLine: 200) == .accountServer)
        #expect(SettingsCategoryPolicy.category(headerTops: [:], topLine: 200) == .accountServer)
        #expect(SettingsCategoryPolicy.category(headerTops: [.server: .nan], topLine: 200) == .accountServer)
    }

    @Test(arguments: [
        // Unfolded upright (669), sideways content region (~865), iPad full screen (1194).
        (669.0, nil as Double?, 280.0), (865.0, nil, 294.0), (1194.0, nil, 360.0),
        // Book: the first page exactly.
        (865.0, 465.0, 465.0),
        // Unmeasured.
        (0.0, nil, 320.0), (Double.nan, nil, 320.0),
    ])
    func sidebarWidth(container: Double, book: Double?, expected: Double) {
        #expect(SettingsCategoryPolicy.sidebarWidth(containerWidth: container, bookFirstHalfWidth: book) == expected)
    }
}
