import Foundation

/// Shared load state for browse-oriented views (Home, Search, Library grids,
/// Music, and child/detail lists). Kept outside any one view so call sites do
/// not imply Home owns the app-wide loading model.
enum BrowseLoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}
