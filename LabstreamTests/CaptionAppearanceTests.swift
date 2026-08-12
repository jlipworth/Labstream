import MediaAccessibility
import Testing
@testable import Labstream

@Suite("Caption appearance")
struct CaptionAppearanceTests {
    @Test("offline presentation clamps opacity size and radius")
    func clampsValues() {
        let value = OfflineCaptionPresentationPolicy.make(
            relativeCharacterSize: 9,
            fontName: "",
            foreground: CaptionColorComponents(red: 2, green: -1, blue: 0.5, opacity: 4),
            background: CaptionColorComponents(red: 0, green: 0, blue: 0, opacity: -2),
            window: nil,
            edgeRawValue: Int(MACaptionAppearanceTextEdgeStyle.uniform.rawValue),
            windowCornerRadius: 100)

        #expect(value.relativeCharacterSize == 3)
        #expect(value.fontName == nil)
        #expect(value.foreground.red == 1)
        #expect(value.foreground.green == 0)
        #expect(value.foreground.opacity == 1)
        #expect(value.background.opacity == 0)
        #expect(value.edge == .uniform)
        #expect(value.windowCornerRadius == 40)
    }

    @Test("undefined edge and invalid numbers use legible fallbacks")
    func fallbackValues() {
        let value = OfflineCaptionPresentationPolicy.make(
            relativeCharacterSize: .nan,
            fontName: nil,
            foreground: nil,
            background: nil,
            window: nil,
            edgeRawValue: 999,
            windowCornerRadius: .infinity)

        #expect(value.relativeCharacterSize == 1)
        #expect(value.foreground == .white)
        #expect(value.background.opacity == 0.62)
        #expect(value.edge == .none)
        #expect(value.windowCornerRadius == 0)
    }

    @Test("preview availability preserves lower deployment targets")
    @MainActor
    func availabilityIsRuntimeGated() {
        let controller = CaptionAppearanceController()
        // The assertion intentionally follows the runtime rather than assuming the deployment
        // floor; constructing the controller is the regression check for pre-preview OS support.
        if #available(macOS 26.4, iOS 26.4, tvOS 26.4, visionOS 26.4, *) {
            #expect(controller.supportsNativePreview)
        } else {
            #expect(!controller.supportsNativePreview)
        }
        controller.stopPreview()
        controller.attachPlayerLayer(nil)
    }
}
