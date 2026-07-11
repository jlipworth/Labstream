public enum MobileVideoDisplayMode: String, CaseIterable, Sendable, Equatable {
    case fit
    case fill

    public var toggled: Self { self == .fit ? .fill : .fit }
    public var statusLabel: String { self == .fit ? "Original" : "Zoomed to Fill" }
    public var accessibilityLabel: String { self == .fit ? "Zoom video to fill" : "Show original video" }
    public var systemImage: String { self == .fit ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left" }

    public static func persisted(_ rawValue: String?) -> Self {
        rawValue.flatMap(Self.init(rawValue:)) ?? .fit
    }

    public static func pinchSelection(magnification: Double, threshold: Double = 0.12) -> Self? {
        guard magnification.isFinite, threshold >= 0 else { return nil }
        if magnification >= 1 + threshold { return .fill }
        if magnification <= 1 - threshold { return .fit }
        return nil
    }
}
