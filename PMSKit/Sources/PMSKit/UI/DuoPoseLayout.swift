import CoreGraphics
import Foundation

/// The partially folded pose a foldable iPhone reports, as the one input every pose-aware layout
/// reads (iPhone Duo design spec, "Poses and terms").
///
/// Layout never keys on a pose *name* from a hinge call of its own: the app derives this value
/// once, from the supported geometry APIs (`reservedRegions(kind: .division)`), and in DEBUG
/// builds a launch override can replace it so book and tabletop compositions get headless
/// screenshot evidence. Every other partially folded state is `flat`.
public enum DuoPoseInput: Equatable, Sendable {
    /// No active fold division: the display is closed (outer display) or fully open.
    case flat
    /// Unfolded sideways and partially folded: the division is a vertical strip.
    case book(hinge: CGRect)
    /// Unfolded upright and partially folded: the division is a horizontal strip.
    case tabletop(hinge: CGRect)

    /// Classifies an active division (fold) region. A strip taller than it is wide splits the
    /// width (book); a strip wider than it is tall splits the height (tabletop). An empty or
    /// degenerate region is `flat`.
    public static func classify(division: CGRect?) -> DuoPoseInput {
        guard let division,
              division.width.isFinite, division.height.isFinite,
              !division.isNull, !division.isInfinite,
              division.width > 0 || division.height > 0 else { return .flat }
        if division.height > division.width { return .book(hinge: division) }
        if division.width > division.height { return .tabletop(hinge: division) }
        return .flat
    }

    public var hinge: CGRect? {
        switch self {
        case .flat: nil
        case .book(let hinge), .tabletop(let hinge): hinge
        }
    }
}

/// Turns a `DuoPoseInput` plus the consumer's content region (both in the same coordinate space)
/// into the half rects that pose-aware layouts use: the trailing half for the book player control
/// group, the 2 + 2 grid split, the list + detail divider, and the tabletop top and bottom halves.
public struct DuoPoseLayout: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case flat, book, tabletop
    }

    public let kind: Kind
    public let contentRegion: CGRect
    /// The hinge strip clipped to the content region; `nil` when flat or when the hinge does not
    /// cross the content region.
    public let hinge: CGRect?
    /// Book: the part of the content region left of the hinge. Tabletop: the part above it.
    /// Flat: the whole content region.
    public let firstHalf: CGRect
    /// Book: the part of the content region right of the hinge. Tabletop: the part below it.
    /// Flat: the whole content region.
    public let secondHalf: CGRect

    public init(input: DuoPoseInput, contentRegion: CGRect) {
        let region = contentRegion.standardized
        self.contentRegion = region
        switch input {
        case .book(let rawHinge):
            let hinge = rawHinge.standardized.intersection(region)
            if !hinge.isNull, hinge.minX > region.minX, hinge.maxX < region.maxX {
                kind = .book
                self.hinge = hinge
                firstHalf = CGRect(x: region.minX, y: region.minY,
                                   width: hinge.minX - region.minX, height: region.height)
                secondHalf = CGRect(x: hinge.maxX, y: region.minY,
                                    width: region.maxX - hinge.maxX, height: region.height)
                return
            }
        case .tabletop(let rawHinge):
            let hinge = rawHinge.standardized.intersection(region)
            if !hinge.isNull, hinge.minY > region.minY, hinge.maxY < region.maxY {
                kind = .tabletop
                self.hinge = hinge
                firstHalf = CGRect(x: region.minX, y: region.minY,
                                   width: region.width, height: hinge.minY - region.minY)
                secondHalf = CGRect(x: region.minX, y: hinge.maxY,
                                    width: region.width, height: region.maxY - hinge.maxY)
                return
            }
        case .flat:
            break
        }
        // Flat, or a hinge that does not cross the content region.
        kind = .flat
        hinge = nil
        firstHalf = region
        secondHalf = region
    }

    /// Splits a grid's column count around a book hinge so no column straddles the fold
    /// (HIG: even column counts wherever the fold can split them). Flat and tabletop never split
    /// a column, so the whole count stays on one side.
    public func columnSplit(_ columns: Int) -> (first: Int, second: Int) {
        let count = max(columns, 0)
        guard kind == .book else { return (count, 0) }
        let first = (count + 1) / 2
        return (first, count - first)
    }
}

#if DEBUG
/// DEBUG-only pose override (`LABSTREAM_DEBUG_DUO_POSE=book|tabletop`, from the launch
/// environment or a `--labstream-debug-duo-pose <value>` launch argument). It lets the
/// `devicectl appResize` proxy capture book (951×669) and tabletop (669×951) layouts headlessly.
/// Not compiled into Release, which always reads the live division region.
public enum DuoPoseOverride: String, Equatable, Sendable {
    case flat, book, tabletop

    public static let environmentKey = "LABSTREAM_DEBUG_DUO_POSE"
    public static let argumentFlag = "--labstream-debug-duo-pose"
    /// Approximate hinge strip thickness used for the synthetic division.
    public static let hingeThickness: CGFloat = 20

    /// The requested override, or `nil` when none was requested. An unknown value is `flat`, so
    /// a typo never produces a half-applied pose.
    public static func parse(environment: [String: String], arguments: [String]) -> DuoPoseOverride? {
        var raw = environment[environmentKey]
        if let index = arguments.firstIndex(of: argumentFlag), arguments.indices.contains(index + 1) {
            raw = arguments[index + 1]
        }
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return DuoPoseOverride(rawValue: value) ?? .flat
    }

    /// The synthetic pose for the current bounds: a vertical strip at the horizontal centre for
    /// book, a horizontal strip at the vertical centre for tabletop. The override applies only
    /// while the bounds have the matching orientation (sideways for book, upright for tabletop);
    /// otherwise it is `flat`.
    public func input(in bounds: CGRect) -> DuoPoseInput {
        let rect = bounds.standardized
        guard rect.width > 0, rect.height > 0 else { return .flat }
        let half = Self.hingeThickness / 2
        switch self {
        case .flat:
            return .flat
        case .book:
            guard rect.width > rect.height else { return .flat }
            return .book(hinge: CGRect(x: rect.midX - half, y: rect.minY,
                                       width: Self.hingeThickness, height: rect.height))
        case .tabletop:
            guard rect.height > rect.width else { return .flat }
            return .tabletop(hinge: CGRect(x: rect.minX, y: rect.midY - half,
                                           width: rect.width, height: Self.hingeThickness))
        }
    }
}
#endif
