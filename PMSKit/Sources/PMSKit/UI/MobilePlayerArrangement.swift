import CoreGraphics
import Foundation

/// Where the iPhone/iPad player puts its picture and its one control arrangement (iPhone Duo design
/// spec, "Player").
///
/// The controls are always the same group in the same vertical order: the top row (Close, PiP and
/// gravity leading; AirPlay trailing), the transport (−10 / play-pause / +10), the title and
/// caption, the scrubber, then the row of circles. Only *where* that group sits changes:
///
/// - **overlay:** the whole safe frame (folded landscape, unfolded sideways, iPad landscape, or a
///   picture that fills the screen).
/// - **videoRect:** a portrait viewport with an aspect-fit picture (unfolded upright): the chrome
///   overlays the video rectangle, not the black bands, kept at least `minimumOverlayHeight` tall.
/// - **book:** the overlay, but the transport, title, scrubber and circles move together into the
///   half after the vertical hinge; the top row does not move (Resolved decision 7).
/// - **tabletop:** the picture fills the half above the horizontal hinge and the controls form a
///   deck in the half below, which does not auto-hide.
///
/// All rects share one coordinate space (the caller's global space). The pose only ever changes
/// layout: the picture stays one `AVPlayerLayer` whose frame moves.
public struct MobilePlayerArrangement: Equatable, Sendable {
    public enum Mode: String, Equatable, Sendable {
        case overlay, videoRect, book, tabletop
    }

    /// The minimum height the chrome claims in `videoRect` mode, so a wide (2.39:1) picture on a
    /// portrait viewport still seats the whole group; it grows around the picture's centre.
    public static let minimumOverlayHeight: CGFloat = 300
    /// The narrowest trailing half that seats the control group in book; narrower stays overlay.
    public static let minimumBookGroupWidth: CGFloat = 320
    /// The shortest deck that seats the four tabletop rows; shorter stays overlay.
    public static let minimumDeckHeight: CGFloat = 280
    /// Assumed picture aspect before the first frame reports one.
    public static let defaultVideoAspect: Double = 16.0 / 9.0
    /// An occlusion (camera island) only trims the bottom group when the group keeps this width.
    public static let minimumTrimmedGroupWidth: CGFloat = 240

    public let mode: Mode
    /// The `AVPlayerLayer` frame: the full bounds, or the half above the hinge in tabletop.
    public let videoFrame: CGRect
    /// The envelope of the whole control group; the top row spans it.
    public let chromeFrame: CGRect
    /// The rect whose centre column holds the transport row.
    public let transportFrame: CGRect
    /// The rect that holds the title, scrubber and circles (and anchors the menus).
    public let bottomGroupFrame: CGRect
    /// The rect the transport status centres in: the video rectangle, the book group, or the
    /// tabletop picture half.
    public let statusFrame: CGRect

    /// The tabletop deck is a stable surface: it never auto-hides.
    public var pinsControls: Bool { mode == .tabletop }

    public init(mode: Mode, videoFrame: CGRect, chromeFrame: CGRect, transportFrame: CGRect,
                bottomGroupFrame: CGRect, statusFrame: CGRect) {
        self.mode = mode
        self.videoFrame = videoFrame
        self.chromeFrame = chromeFrame
        self.transportFrame = transportFrame
        self.bottomGroupFrame = bottomGroupFrame
        self.statusFrame = statusFrame
    }

    /// - Parameters:
    ///   - bounds: the player's full bounds (where the picture may draw).
    ///   - safeFrame: where controls may sit: the bounds minus the safe-area insets (the top edge at
    ///     the latched top inset).
    ///   - pose: the foldable pose, in the same coordinate space.
    ///   - videoAspect: width ÷ height of the picture, or `nil` before it is known.
    ///   - fillsScreen: the Fill gravity is on, so the picture covers the bounds.
    ///   - occlusions: active occlusion regions (the outer camera island), same coordinate space.
    public static func resolve(bounds: CGRect,
                               safeFrame: CGRect,
                               pose: DuoPoseInput,
                               videoAspect: Double?,
                               fillsScreen: Bool,
                               occlusions: [CGRect] = []) -> MobilePlayerArrangement {
        let bounds = bounds.standardized
        let safe = Self.usableSafeFrame(safeFrame.standardized, in: bounds)
        guard bounds.width > 0, bounds.height > 0, safe.width > 0, safe.height > 0 else {
            return MobilePlayerArrangement(mode: .overlay, videoFrame: bounds, chromeFrame: safe,
                                           transportFrame: safe, bottomGroupFrame: safe, statusFrame: safe)
        }

        switch pose {
        case .tabletop:
            let layout = DuoPoseLayout(input: pose, contentRegion: bounds)
            if layout.kind == .tabletop, let hinge = layout.hinge {
                let deck = CGRect(x: safe.minX, y: max(safe.minY, hinge.maxY),
                                  width: safe.width, height: safe.maxY - max(safe.minY, hinge.maxY))
                if deck.height >= minimumDeckHeight {
                    let video = CGRect(x: bounds.minX, y: bounds.minY,
                                       width: bounds.width, height: hinge.minY - bounds.minY)
                    let status = CGRect(x: safe.minX, y: max(video.minY, safe.minY),
                                        width: safe.width, height: video.maxY - max(video.minY, safe.minY))
                    return MobilePlayerArrangement(mode: .tabletop, videoFrame: video, chromeFrame: deck,
                                                   transportFrame: deck, bottomGroupFrame: deck,
                                                   statusFrame: status)
                }
            }
        case .book:
            let layout = DuoPoseLayout(input: pose, contentRegion: safe)
            if layout.kind == .book, layout.secondHalf.width >= minimumBookGroupWidth {
                let group = layout.secondHalf
                return MobilePlayerArrangement(mode: .book, videoFrame: bounds, chromeFrame: safe,
                                               transportFrame: group,
                                               bottomGroupFrame: trimmed(group, chrome: safe, by: occlusions),
                                               statusFrame: group)
            }
        case .flat:
            break
        }

        if !fillsScreen, bounds.height > bounds.width {
            let aspect = (videoAspect.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }) ?? defaultVideoAspect
            let fitHeight = bounds.width / CGFloat(aspect)
            if fitHeight < bounds.height {
                let video = CGRect(x: bounds.minX, y: bounds.midY - fitHeight / 2,
                                   width: bounds.width, height: fitHeight)
                var band = video.intersection(safe)
                if band.isNull { band = safe }
                let height = min(max(band.height, minimumOverlayHeight), safe.height)
                var minY = band.midY - height / 2
                minY = min(max(minY, safe.minY), safe.maxY - height)
                let chrome = CGRect(x: safe.minX, y: minY, width: safe.width, height: height)
                return MobilePlayerArrangement(mode: .videoRect, videoFrame: bounds, chromeFrame: chrome,
                                               transportFrame: chrome,
                                               bottomGroupFrame: trimmed(chrome, chrome: chrome, by: occlusions),
                                               statusFrame: chrome)
            }
        }

        return MobilePlayerArrangement(mode: .overlay, videoFrame: bounds, chromeFrame: safe,
                                       transportFrame: safe,
                                       bottomGroupFrame: trimmed(safe, chrome: safe, by: occlusions),
                                       statusFrame: safe)
    }

    /// The safe frame clipped to the bounds; an unmeasured safe frame falls back to the bounds.
    private static func usableSafeFrame(_ safe: CGRect, in bounds: CGRect) -> CGRect {
        guard safe.width > 0, safe.height > 0 else { return bounds }
        let clipped = safe.intersection(bounds)
        return clipped.isNull ? bounds : clipped
    }

    /// Ends the bottom group before an occlusion (the outer camera island in tent / folded
    /// landscape) that reaches into the lower half of the chrome, on whichever side it sits. The
    /// transport stays centred in the full frame. Occlusions in the upper half are left to the safe
    /// area (the status strip).
    static func trimmed(_ group: CGRect, chrome: CGRect, by occlusions: [CGRect]) -> CGRect {
        var result = group
        for raw in occlusions {
            let occlusion = raw.standardized
            guard occlusion.width > 0, occlusion.height > 0,
                  occlusion.maxY > chrome.midY,
                  occlusion.intersects(result) else { continue }
            var candidate = result
            if occlusion.midX >= result.midX {
                candidate.size.width = max(0, occlusion.minX - result.minX)
            } else {
                let newMinX = occlusion.maxX
                candidate.size.width = max(0, result.maxX - newMinX)
                candidate.origin.x = newMinX
            }
            if candidate.width >= minimumTrimmedGroupWidth { result = candidate }
        }
        return result
    }
}

/// Resolves the pose the player lays out for (iPhone Duo design spec, "Player", tabletop and
/// book).
///
/// The shell's single pose value (the active `reservedRegions(kind: .division)` region, or the
/// DEBUG launch override) wins. When it reports nothing but the player's read-only
/// `UIHingeInteraction` reports a partially open hinge on an unfolded (large) display, the hinge
/// sits across the middle of the inner display, so the player synthesises the same centre strip
/// the DEBUG override uses: horizontal (tabletop) on an upright display, vertical (book) on a
/// sideways one. A closed or fully open hinge, or a phone-class display (folded, tent), is flat.
public enum MobilePlayerPoseResolver {
    public enum HingeStatus: String, Equatable, Sendable {
        case unavailable, unknown, closed, partiallyOpen, fullyOpen
    }

    /// Displays at or below this short side are phone-class (the folded outer display).
    public static let largeDisplayShortSide: CGFloat = 500
    /// Thickness of the synthesised hinge strip.
    public static let hingeThickness: CGFloat = 20

    public static func resolve(shellPose: DuoPoseInput,
                               hingeStatus: HingeStatus,
                               bounds: CGRect) -> DuoPoseInput {
        if shellPose != .flat { return shellPose }
        let rect = bounds.standardized
        guard hingeStatus == .partiallyOpen,
              rect.width > 0, rect.height > 0,
              min(rect.width, rect.height) > largeDisplayShortSide else { return .flat }
        let half = hingeThickness / 2
        if rect.width > rect.height {
            return .book(hinge: CGRect(x: rect.midX - half, y: rect.minY,
                                       width: hingeThickness, height: rect.height))
        }
        if rect.height > rect.width {
            return .tabletop(hinge: CGRect(x: rect.minX, y: rect.midY - half,
                                           width: rect.width, height: hingeThickness))
        }
        return .flat
    }
}
