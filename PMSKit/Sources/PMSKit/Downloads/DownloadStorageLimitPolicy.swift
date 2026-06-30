import Foundation

public struct DownloadStorageLimitOption: Sendable, Equatable, Identifiable {
    public let bytes: Int
    public let label: String

    public var id: Int { bytes }

    public init(bytes: Int, label: String) {
        self.bytes = bytes
        self.label = label
    }
}

/// Pure storage-cap presentation and preflight policy for offline downloads.
///
/// The app still owns the persisted preference and current on-disk usage, but this policy keeps the
/// user-facing cap labels and enqueue rejection message in PMSKit so the download coordinator and
/// settings UI do not drift.
public enum DownloadStorageLimitPolicy {
    public static let unlimited: Int = 0

    public static let options: [DownloadStorageLimitOption] = [
        .init(bytes: unlimited, label: "Unlimited"),
        .init(bytes: 10 * 1_000_000_000, label: "10 GB"),
        .init(bytes: 25 * 1_000_000_000, label: "25 GB"),
        .init(bytes: 50 * 1_000_000_000, label: "50 GB"),
        .init(bytes: 100 * 1_000_000_000, label: "100 GB"),
        .init(bytes: 250 * 1_000_000_000, label: "250 GB"),
    ]

    public static func byteString(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    public static func label(bytes: Int) -> String {
        if let option = options.first(where: { $0.bytes == bytes }) { return option.label }
        if bytes <= 0 { return "Unlimited" }
        return byteString(bytes)
    }

    public static func rejectionMessage(adding expectedBytes: Int?,
                                        currentBytes: Int,
                                        limitBytes: Int) -> String? {
        guard let expectedBytes, expectedBytes > 0 else { return nil }
        guard limitBytes > 0 else { return nil }
        let projected = currentBytes + expectedBytes
        guard projected > limitBytes else { return nil }
        return "This download needs about \(byteString(expectedBytes)), but \(byteString(currentBytes)) is already used and the limit is \(label(bytes: limitBytes)). Increase the limit or remove downloads first."
    }
}
