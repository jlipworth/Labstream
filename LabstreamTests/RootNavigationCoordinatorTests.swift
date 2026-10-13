import PMSKit
import SwiftUI
import Testing

@testable import Labstream

@MainActor
struct RootNavigationCoordinatorTests {
  @Test func browseSessionResetClearsOnlyOnlinePaths() {
    let navigation = populatedCoordinator()
    navigation.offlineReturnRatingKey = "emby:offline-42"

    navigation.resetForBrowseSessionChange()

    #expect(navigation.homePath.isEmpty)
    #expect(navigation.librariesPath.isEmpty)
    #expect(navigation.searchPath.isEmpty)
    #expect(navigation.musicPath.isEmpty)
    #expect(navigation.offlineReturnRatingKey == "emby:offline-42")
  }

  @Test func pushResetAndBackMutateOnlyTheRequestedDestination() {
    let navigation = RootNavigationCoordinator()
    let item = MediaItem(ratingKey: "movie", title: "Movie", type: "movie")

    navigation.push(item, on: .libraries)
    navigation.push(item, on: .libraries)
    navigation.push(item, on: .home)

    #expect(navigation.librariesPath.count == 2)
    #expect(navigation.homePath.count == 1)
    #expect(navigation.canNavigateBack(in: .libraries))
    navigation.navigateBack(in: .libraries)
    #expect(navigation.librariesPath.count == 1)
    #expect(navigation.homePath.count == 1)

    navigation.resetPath(for: .libraries)
    #expect(navigation.librariesPath.isEmpty)
    #expect(navigation.homePath.count == 1)
    #expect(!navigation.canNavigateBack(in: .settings))
  }

  @Test func exitingSearchReturnsToTheLastNonSearchDestination() {
    let navigation = RootNavigationCoordinator()
    navigation.selection = .libraries
    navigation.selectionDidChange(to: .libraries)
    navigation.selection = .search
    navigation.selectionDidChange(to: .search)
    navigation.searchPath.append(
      MediaItem(ratingKey: "result", title: "Result", type: "movie"))

    navigation.exitSearch()

    #expect(navigation.selection == .libraries)
    #expect(navigation.searchPath.isEmpty)
    #expect(navigation.lastNonSearchSelection == .libraries)
  }

  @Test func searchFocusGenerationSupportsSelectionAndAlreadyPresentedSearch() {
    let navigation = RootNavigationCoordinator()
    navigation.selection = .libraries

    navigation.requestSearchFocus()
    #expect(navigation.selection == .search)
    #expect(navigation.searchFocusRequest == 1)

    navigation.requestSearchFocus(selectsSearch: false)
    #expect(navigation.selection == .search)
    #expect(navigation.searchFocusRequest == 2)
  }

  @Test func searchCommandRevealsTheSearchRootButTabReselectionKeepsTheStack() {
    let navigation = RootNavigationCoordinator()
    let result = MediaItem(ratingKey: "result", title: "Result", type: "movie")
    navigation.selection = .libraries
    navigation.push(result, on: .search)

    navigation.requestSearchFocus(selectsSearch: false)
    #expect(navigation.searchPath.count == 1)

    navigation.focusSearchFromCommand()
    #expect(navigation.selection == .search)
    #expect(navigation.searchPath.isEmpty)
    #expect(navigation.searchFocusRequest == 2)

    navigation.push(result, on: .search)
    navigation.focusSearchFromCommand(selectsSearch: false)
    #expect(navigation.searchPath.isEmpty)
    #expect(navigation.searchFocusRequest == 3)
  }

  @Test func onlyADifferentNonEmptyQueryRevealsSearchResults() {
    let navigation = RootNavigationCoordinator()
    let result = MediaItem(ratingKey: "result", title: "Result", type: "movie")
    navigation.push(result, on: .search)

    navigation.searchQueryDidChange(from: "alien", to: " alien ")
    navigation.searchQueryDidChange(from: "alien", to: "  ")
    #expect(navigation.searchPath.count == 1)

    navigation.searchQueryDidChange(from: "alien", to: "aliens")
    #expect(navigation.searchPath.isEmpty)
  }

  private func populatedCoordinator() -> RootNavigationCoordinator {
    let navigation = RootNavigationCoordinator()
    let item = MediaItem(ratingKey: "item", title: "Item", type: "movie")
    navigation.push(item, on: .home)
    navigation.push(item, on: .libraries)
    navigation.push(item, on: .search)
    navigation.push(item, on: .music)
    return navigation
  }
}

#if os(iOS)
  @MainActor
  struct MobileSettingsPresentationPolicyTests {
    @Test func compactResizeMovesASelectedSettingsTabIntoItsSheet() {
      #expect(
        MobileSettingsPresentationPolicy.action(selection: .settings, isCompact: true)
          == .presentSheet(selecting: .home))
    }

    @Test func regularWidthAndNonSettingsSelectionsRemainUnchanged() {
      #expect(
        MobileSettingsPresentationPolicy.action(selection: .settings, isCompact: false)
          == .unchanged)
      #expect(
        MobileSettingsPresentationPolicy.action(selection: .offline, isCompact: true)
          == .unchanged)
    }
  }
#endif
