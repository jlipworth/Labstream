import Testing
@testable import PMSKit

struct MobileVideoDisplayModeTests {
    @Test func defaultsInvalidPersistenceToFit() {
        #expect(MobileVideoDisplayMode.persisted(nil) == .fit)
        #expect(MobileVideoDisplayMode.persisted("invalid") == .fit)
        #expect(MobileVideoDisplayMode.persisted("fill") == .fill)
    }

    @Test func toggleAndLabelsDescribeResult() {
        #expect(MobileVideoDisplayMode.fit.toggled == .fill)
        #expect(MobileVideoDisplayMode.fill.toggled == .fit)
        #expect(MobileVideoDisplayMode.fill.statusLabel == "Zoomed to Fill")
        #expect(MobileVideoDisplayMode.fit.statusLabel == "Original")
    }

    @Test func pinchUsesDirectionAndSnapThreshold() {
        #expect(MobileVideoDisplayMode.pinchSelection(magnification: 1.2) == .fill)
        #expect(MobileVideoDisplayMode.pinchSelection(magnification: 0.8) == .fit)
        #expect(MobileVideoDisplayMode.pinchSelection(magnification: 1.05) == nil)
        #expect(MobileVideoDisplayMode.pinchSelection(magnification: 0.95) == nil)
    }
}
