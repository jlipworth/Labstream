import Foundation
import simd

/// Issue #12 RealityKit theater boundary.
///
/// `CustomCinemaMode` is the shipping app-owned Cinema path that hosts the custom player in an
/// `ImmersiveSpace`. This namespace owns the separate RealityKit theater prototype and starts with
/// no visible entry point.
enum RealityTheaterFeature {
    static let immersiveSpaceID = "realitykit-theater-prototype"

    /// Developer-only escape hatch for a future local test entry point. There is deliberately no
    /// Settings toggle or player-chrome button in this slice; the prototype entry point stays gated
    /// until real-device behavior is proven.
    static let developerDefaultsKey = "developerRealityKitTheaterEnabled"

    /// Hard shipping gate: #12 is not user-visible in release builds until screen placement/scale
    /// and full-Environment behavior are manually proven on Apple Vision Pro hardware.
    static let isShippingEntryPointVisible = false

    /// The RealityKit theater lab is not automatically surfaced in debug builds. Device testing
    /// showed that this prototype currently presents as a second black attachment in front of the
    /// existing player window, so keep it behind the explicit developer defaults key until the
    /// presentation model can replace/dismiss the windowed player cleanly.
    static var isDeviceTestingEntryPointVisible: Bool {
        false
    }

    static func isDeveloperEntryPointEnabled(defaults: UserDefaults = .standard) -> Bool {
        #if DEBUG
        defaults.bool(forKey: developerDefaultsKey)
        #else
        false
        #endif
    }
}

/// Tunable screen placement for the future RealityKit theater.
///
/// The values are intentionally expressed in meters so device testing can reason about actual
/// perceived size/distance instead of opaque SwiftUI frame points.
struct RealityTheaterScreenConfiguration: Equatable, Hashable, Sendable {
    static let defaultWidthMeters: Float = 4.8
    static let defaultDistanceMeters: Float = 5.6
    static let defaultVerticalOffsetMeters: Float = 0.08

    static let widthRangeMeters: ClosedRange<Float> = 2.4...7.2
    static let distanceRangeMeters: ClosedRange<Float> = 2.8...8.0
    static let verticalOffsetRangeMeters: ClosedRange<Float> = (-0.5)...1.1

    var widthMeters: Float
    var distanceMeters: Float
    var verticalOffsetMeters: Float
    var aspectRatio: Float

    init(widthMeters: Float = Self.defaultWidthMeters,
         distanceMeters: Float = Self.defaultDistanceMeters,
         verticalOffsetMeters: Float = Self.defaultVerticalOffsetMeters,
         aspectRatio: Float = 16.0 / 9.0) {
        self.widthMeters = widthMeters.clamped(to: Self.widthRangeMeters)
        self.distanceMeters = distanceMeters.clamped(to: Self.distanceRangeMeters)
        self.verticalOffsetMeters = verticalOffsetMeters.clamped(to: Self.verticalOffsetRangeMeters)
        self.aspectRatio = max(aspectRatio, 1.0)
    }

    var heightMeters: Float { widthMeters / aspectRatio }
}

enum RealityTheaterSeatPreset: String, CaseIterable, Equatable, Hashable, Identifiable, Sendable {
    case front
    case center
    case back

    var id: String { rawValue }

    /// Marker offset for the visible prototype seat. This does not move the user; real device
    /// iteration must decide whether controls should move the screen, the content root, or only a
    /// visual seat/control cluster.
    var prototypeSeatOffset: SIMD3<Float> {
        switch self {
        case .front:
            SIMD3<Float>(0, -0.95, -0.35)
        case .center:
            SIMD3<Float>(0, -0.95, 0.0)
        case .back:
            SIMD3<Float>(0, -0.95, 0.45)
        }
    }

    var displayName: String {
        switch self {
        case .front: "Front"
        case .center: "Center"
        case .back: "Back"
        }
    }
}

enum RealityTheaterControlsPlacement: String, CaseIterable, Equatable, Hashable, Identifiable, Sendable {
    case belowScreen
    case seatRail

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .belowScreen: "Below screen"
        case .seatRail: "Seat rail"
        }
    }
}

enum RealityTheaterBaselinePreset: String, CaseIterable, Equatable, Hashable, Identifiable, Sendable {
    case appleDefaultish
    case appleLargeBackRow
    case frontRowDebug

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .appleDefaultish: "Apple-ish default"
        case .appleLargeBackRow: "Apple-ish large/back"
        case .frontRowDebug: "Front-row debug"
        }
    }

    var configuration: RealityTheaterConfiguration {
        switch self {
        case .appleDefaultish:
            RealityTheaterConfiguration(screen: RealityTheaterScreenConfiguration(widthMeters: 4.8,
                                                                                 distanceMeters: 5.6,
                                                                                 verticalOffsetMeters: 0.08),
                                       seat: .center,
                                       controlsPlacement: .belowScreen)
        case .appleLargeBackRow:
            RealityTheaterConfiguration(screen: RealityTheaterScreenConfiguration(widthMeters: 6.2,
                                                                                 distanceMeters: 7.0,
                                                                                 verticalOffsetMeters: 0.15),
                                       seat: .back,
                                       controlsPlacement: .seatRail)
        case .frontRowDebug:
            RealityTheaterConfiguration(screen: RealityTheaterScreenConfiguration(widthMeters: 3.4,
                                                                                 distanceMeters: 3.8,
                                                                                 verticalOffsetMeters: -0.05),
                                       seat: .front,
                                       controlsPlacement: .seatRail)
        }
    }
}

struct RealityTheaterConfiguration: Equatable, Hashable, Sendable {
    static let `default` = RealityTheaterBaselinePreset.appleDefaultish.configuration

    var screen: RealityTheaterScreenConfiguration
    var seat: RealityTheaterSeatPreset
    var controlsPlacement: RealityTheaterControlsPlacement

    init(screen: RealityTheaterScreenConfiguration = RealityTheaterScreenConfiguration(),
         seat: RealityTheaterSeatPreset = .center,
         controlsPlacement: RealityTheaterControlsPlacement = .belowScreen) {
        self.screen = screen
        self.seat = seat
        self.controlsPlacement = controlsPlacement
    }

    var screenPosition: SIMD3<Float> {
        SIMD3<Float>(0, screen.verticalOffsetMeters, -screen.distanceMeters)
    }

    var controlsPosition: SIMD3<Float> {
        switch controlsPlacement {
        case .belowScreen:
            SIMD3<Float>(0, screen.verticalOffsetMeters - (screen.heightMeters / 2.0) - 0.28, -screen.distanceMeters + 0.08)
        case .seatRail:
            seat.prototypeSeatOffset + SIMD3<Float>(0, 0.18, -0.55)
        }
    }

    var debugSummary: String {
        String(format: "width %.1fm · distance %.1fm · vertical %.2fm · %@ · %@",
               screen.widthMeters,
               screen.distanceMeters,
               screen.verticalOffsetMeters,
               seat.displayName,
               controlsPlacement.displayName)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
