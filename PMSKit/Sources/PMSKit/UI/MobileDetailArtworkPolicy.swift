import Foundation

public enum MobileDetailArtworkPolicy {
    public enum Selection: Equatable, Sendable {
        case landscape(path: String)
        case croppedPoster(path: String)
        case none
    }

    public static func selection(art: String?, thumb: String?) -> Selection {
        if let art = normalized(art) { return .landscape(path: art) }
        if let thumb = normalized(thumb) { return .croppedPoster(path: thumb) }
        return .none
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
