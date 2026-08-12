import AVFoundation
import CoreText
import Foundation
import MediaAccessibility
import SwiftUI

struct CaptionColorComponents: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double
    let opacity: Double

    static let white = Self(red: 1, green: 1, blue: 1, opacity: 1)
    static let clearBlack = Self(red: 0, green: 0, blue: 0, opacity: 0)

    var color: Color { Color(red: red, green: green, blue: blue, opacity: opacity) }
}

enum CaptionTextEdgePresentation: Equatable, Sendable {
    case none
    case raised
    case depressed
    case uniform
    case dropShadow
}

struct OfflineCaptionPresentation: Equatable, Sendable {
    let relativeCharacterSize: Double
    let fontName: String?
    let foreground: CaptionColorComponents
    let background: CaptionColorComponents
    let window: CaptionColorComponents
    let edge: CaptionTextEdgePresentation
    let windowCornerRadius: Double
}

/// Value-only normalization for the app-owned offline caption renderer. Media Accessibility can
/// return out-of-range values or an undefined edge; fail to legible system-like fallbacks.
enum OfflineCaptionPresentationPolicy {
    static func make(relativeCharacterSize: Double,
                     fontName: String?,
                     foreground: CaptionColorComponents?,
                     background: CaptionColorComponents?,
                     window: CaptionColorComponents?,
                     edgeRawValue: Int,
                     windowCornerRadius: Double) -> OfflineCaptionPresentation {
        let edge: CaptionTextEdgePresentation = switch edgeRawValue {
        case Int(MACaptionAppearanceTextEdgeStyle.raised.rawValue): .raised
        case Int(MACaptionAppearanceTextEdgeStyle.depressed.rawValue): .depressed
        case Int(MACaptionAppearanceTextEdgeStyle.uniform.rawValue): .uniform
        case Int(MACaptionAppearanceTextEdgeStyle.dropShadow.rawValue): .dropShadow
        default: .none
        }
        return OfflineCaptionPresentation(
            relativeCharacterSize: min(3, max(0.5,
                relativeCharacterSize.isFinite ? relativeCharacterSize : 1)),
            fontName: fontName?.isEmpty == false ? fontName : nil,
            foreground: clamped(foreground ?? .white),
            background: clamped(background ?? CaptionColorComponents(
                red: 0, green: 0, blue: 0, opacity: 0.62)),
            window: clamped(window ?? .clearBlack),
            edge: edge,
            windowCornerRadius: min(40, max(0,
                windowCornerRadius.isFinite ? windowCornerRadius : 0)))
    }

    private static func clamped(_ value: CaptionColorComponents) -> CaptionColorComponents {
        CaptionColorComponents(red: min(1, max(0, value.red)),
                               green: min(1, max(0, value.green)),
                               blue: min(1, max(0, value.blue)),
                               opacity: min(1, max(0, value.opacity)))
    }
}

struct CaptionAppearanceProfile: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
}

/// Playback-lifetime bridge to Apple's system caption profiles and AVPlayerLayer preview.
/// The bridge stops preview before every layer replacement and when playback tears down.
@Observable
@MainActor
final class CaptionAppearanceController {
    private(set) var profiles: [CaptionAppearanceProfile] = []
    private(set) var activeProfileID: String?
    private(set) var offlinePresentation: OfflineCaptionPresentation
    private(set) var previewedProfileID: String?

    @ObservationIgnored private weak var playerLayer: AVPlayerLayer?
    @ObservationIgnored nonisolated(unsafe) private var settingsObserver: NSObjectProtocol?

    init() {
        offlinePresentation = Self.readOfflinePresentation()
        refreshProfilesAndPresentation()
        settingsObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name(kMACaptionAppearanceSettingsChangedNotification as String),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshProfilesAndPresentation() }
        }
    }

    deinit {
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
    }

    var supportsNativePreview: Bool {
        if #available(macOS 26.4, iOS 26.4, tvOS 26.4, visionOS 26.4, *) { true }
        else { false }
    }

    func attachPlayerLayer(_ layer: AVPlayerLayer?) {
        guard playerLayer !== layer else { return }
        stopPreview()
        playerLayer = layer
    }

    func preview(profileID: String) {
        guard supportsNativePreview, let playerLayer else { return }
        if #available(macOS 26.4, iOS 26.4, tvOS 26.4, visionOS 26.4, *) {
            playerLayer.setCaptionPreviewProfileID(profileID,
                                                   position: .zero,
                                                   text: "Caption style preview")
            previewedProfileID = profileID
        }
    }

    func stopPreview() {
        if #available(macOS 26.4, iOS 26.4, tvOS 26.4, visionOS 26.4, *),
           let playerLayer {
            playerLayer.stopShowingCaptionPreview()
        }
        previewedProfileID = nil
    }

    func apply(profileID: String) {
        guard profiles.contains(where: { $0.id == profileID }) else { return }
        if #available(macOS 16.0, iOS 19.0, tvOS 19.0, visionOS 3.0, *) {
            MACaptionAppearanceSetActiveProfileID(profileID as CFString)
            activeProfileID = profileID
            stopPreview()
            refreshProfilesAndPresentation()
        }
    }

    func refreshProfilesAndPresentation() {
        if #available(macOS 16.0, iOS 19.0, tvOS 19.0, visionOS 3.0, *) {
            let ids = MACaptionAppearanceCopyProfileIDs() as? [String] ?? []
            profiles = ids.map { id in
                let name = MACaptionAppearanceCopyProfileName(id as CFString) as String
                return CaptionAppearanceProfile(id: id, name: name)
            }
            activeProfileID = MACaptionAppearanceCopyActiveProfileID() as String
        } else {
            profiles = []
            activeProfileID = nil
        }
        offlinePresentation = Self.readOfflinePresentation()
    }

    private static func readOfflinePresentation() -> OfflineCaptionPresentation {
        var behavior: MACaptionAppearanceBehavior = .useValue
        let domain: MACaptionAppearanceDomain = .user
        let foreground = colorComponents(MACaptionAppearanceCopyForegroundColor(domain, &behavior).takeRetainedValue(),
                                         opacity: Double(MACaptionAppearanceGetForegroundOpacity(domain, &behavior)))
        let background = colorComponents(MACaptionAppearanceCopyBackgroundColor(domain, &behavior).takeRetainedValue(),
                                         opacity: Double(MACaptionAppearanceGetBackgroundOpacity(domain, &behavior)))
        let window = colorComponents(MACaptionAppearanceCopyWindowColor(domain, &behavior).takeRetainedValue(),
                                     opacity: Double(MACaptionAppearanceGetWindowOpacity(domain, &behavior)))
        let descriptor = MACaptionAppearanceCopyFontDescriptorForStyle(
            domain, &behavior, .default).takeRetainedValue()
        let fontName = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String
        return OfflineCaptionPresentationPolicy.make(
            relativeCharacterSize: Double(MACaptionAppearanceGetRelativeCharacterSize(domain, &behavior)),
            fontName: fontName,
            foreground: foreground,
            background: background,
            window: window,
            edgeRawValue: Int(MACaptionAppearanceGetTextEdgeStyle(domain, &behavior).rawValue),
            windowCornerRadius: Double(MACaptionAppearanceGetWindowRoundedCornerRadius(domain, &behavior)))
    }

    private static func colorComponents(_ color: CGColor, opacity: Double) -> CaptionColorComponents? {
        guard let converted = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              intent: .defaultIntent,
                                              options: nil),
              let values = converted.components else { return nil }
        if values.count >= 3 {
            return CaptionColorComponents(red: Double(values[0]),
                                          green: Double(values[1]),
                                          blue: Double(values[2]),
                                          opacity: opacity)
        }
        guard let gray = values.first else { return nil }
        return CaptionColorComponents(red: Double(gray), green: Double(gray), blue: Double(gray),
                                      opacity: opacity)
    }
}
