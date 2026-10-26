import Foundation

/// Chooses the iOS player chrome branch from the measured player viewport and size classes.
///
/// `usesCompactChrome` used to be true for every iPhone regardless of space. The unfolded iPhone
/// Duo inner display (669×951 pt, regular width) has room for the regular chrome, and the folded
/// outer display does not, so the decision now comes only from geometry: a compact size class in
/// either axis or a short side below 500 pt.
public struct MobilePlayerChromeLayoutPolicy: Equatable, Sendable {
    public enum SizeClass: Equatable, Sendable {
        case compact
        case regular
    }

    /// The three chrome compositions. A change between them during a scrub cancels the scrub.
    public enum Branch: String, Equatable, Sendable {
        case phoneLandscape
        case compact
        case regular
    }

    public static let compactShortSideLimit: Double = 500

    public let horizontalSizeClass: SizeClass?
    public let verticalSizeClass: SizeClass?
    /// Only `isPhoneLandscape` reads the idiom: it selects the dense single-platter layout that is
    /// authored for phone landscape, and its geometry term already caps the short side at 500 pt.
    public let isPhoneIdiom: Bool
    public let viewportWidth: Double
    public let viewportHeight: Double

    public init(horizontalSizeClass: SizeClass?,
                verticalSizeClass: SizeClass?,
                isPhoneIdiom: Bool,
                viewportWidth: Double,
                viewportHeight: Double) {
        self.horizontalSizeClass = horizontalSizeClass
        self.verticalSizeClass = verticalSizeClass
        self.isPhoneIdiom = isPhoneIdiom
        self.viewportWidth = viewportWidth
        self.viewportHeight = viewportHeight
    }

    private var hasMeasuredViewport: Bool {
        viewportWidth.isFinite && viewportHeight.isFinite && viewportWidth > 0 && viewportHeight > 0
    }

    private var isGeometryLandscape: Bool {
        hasMeasuredViewport && viewportWidth > viewportHeight
    }

    private var shortestMeasuredSide: Double? {
        hasMeasuredViewport ? min(viewportWidth, viewportHeight) : nil
    }

    /// True when the measured viewport is roomier than a phone-class display in both axes (the
    /// unfolded iPhone Duo, an iPad). A phone-idiom device can report vertical-compact there, so a
    /// measured viewport overrides that class (open review finding: `isPhoneLandscape` at 951×669).
    private var isMeasuredLarge: Bool {
        (shortestMeasuredSide.map { $0 > Self.compactShortSideLimit } ?? false)
    }

    public var isPhoneLandscape: Bool {
        guard isPhoneIdiom, !isMeasuredLarge else { return false }
        return verticalSizeClass == .compact
            || (isGeometryLandscape && (shortestMeasuredSide ?? 0) <= Self.compactShortSideLimit)
    }

    public var usesCompactChrome: Bool {
        horizontalSizeClass == .compact
            || (verticalSizeClass == .compact && !isMeasuredLarge)
            || (shortestMeasuredSide.map { $0 < Self.compactShortSideLimit } ?? false)
    }

    public var branch: Branch {
        if isPhoneLandscape { return .phoneLandscape }
        return usesCompactChrome ? .compact : .regular
    }
}

/// Latches the largest top safe-area inset seen for one player viewport size.
///
/// Key the latch on the full-bounds size (safe-area layout size plus the insets), never on the
/// safe-area layout size alone: hiding the status bar grows the safe-area height by exactly the
/// inset it removes, so a safe-area-keyed latch would restart on every chrome toggle and follow
/// the live inset. `observe(safeAreaWidth:safeAreaHeight:top:bottom:leading:trailing:)` does this.
///
/// The player hides the status bar together with its chrome. On some displays that flips the top
/// inset between zero and the status-bar height on every reveal, which would make the top chrome
/// jump. Holding the largest value for a given viewport keeps it still; a new viewport size (a
/// rotation, an iPad window resize, or an iPhone Duo fold) starts a fresh measurement.
public struct PlayerTopSafeInsetLatch: Equatable, Sendable {
    public private(set) var viewportWidth: Double = 0
    public private(set) var viewportHeight: Double = 0
    public private(set) var latchedTopInset: Double = 0

    public init() {}

    /// Feed one measurement; returns the latched inset.
    @discardableResult
    public mutating func observe(viewportWidth: Double, viewportHeight: Double, topInset: Double) -> Double {
        let inset = topInset.isFinite ? max(0, topInset) : 0
        if abs(viewportWidth - self.viewportWidth) > 0.5 || abs(viewportHeight - self.viewportHeight) > 0.5 {
            self.viewportWidth = viewportWidth
            self.viewportHeight = viewportHeight
            latchedTopInset = inset
        } else {
            latchedTopInset = max(latchedTopInset, inset)
        }
        return latchedTopInset
    }

    /// Feed one measurement taken in the safe-area layout frame. The latch is keyed on the
    /// full-bounds size (layout size plus all insets), which does not change when the status bar
    /// is shown or hidden.
    @discardableResult
    public mutating func observe(safeAreaWidth: Double, safeAreaHeight: Double,
                                 top: Double, bottom: Double, leading: Double, trailing: Double) -> Double {
        func finite(_ value: Double) -> Double { value.isFinite ? max(0, value) : 0 }
        return observe(viewportWidth: finite(safeAreaWidth) + finite(leading) + finite(trailing),
                       viewportHeight: finite(safeAreaHeight) + finite(top) + finite(bottom),
                       topInset: top)
    }

    /// Top padding for the top chrome: the authored inset, or the latched safe inset plus a small
    /// margin when that is larger (portrait phone-class viewports with a status bar or sensor
    /// housing at the top).
    public static func topChromePadding(authored: Double, latchedTopInset: Double, margin: Double = 4) -> Double {
        latchedTopInset > 0 ? max(authored, latchedTopInset + margin) : authored
    }
}
