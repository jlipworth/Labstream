import XCTest

extension XCUIApplication {
    /// The app scene's frame: the largest window. On iPadOS 27 `windows.firstMatch` can be a
    /// zero-size auxiliary window, which made every measured-geometry check read 0×0.
    @MainActor
    var sceneFrame: CGRect {
        windows.allElementsBoundByIndex
            .map(\.frame)
            .max { $0.width * $0.height < $1.width * $1.height } ?? .zero
    }
}
