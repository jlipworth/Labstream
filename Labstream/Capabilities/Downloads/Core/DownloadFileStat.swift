import CoreFoundation
import Foundation

/// Metadata-only file observations used by download diagnostics and recovery paths.
///
/// Keep this separate from body readers: a failed HTTP download can leave a multi-gigabyte
/// temporary file, and diagnostics only need its logical byte count for a privacy-safe bucket.
enum DownloadFileStat {
    typealias AttributeReader = (String) throws -> [FileAttributeKey: Any]

    static func logicalSize(
        at url: URL,
        attributesOfItem: AttributeReader = FileManager.default.attributesOfItem(atPath:)
    ) -> Int? {
        guard let raw = try? attributesOfItem(url.path)[.size] else { return nil }

        // Swift bridges integer NSNumbers to the exact integer casts below, but also bridges
        // CFBoolean to Int. A boolean is never a meaningful filesystem byte count.
        if let number = raw as? NSNumber,
           CFGetTypeID(number) == CFBooleanGetTypeID() {
            return nil
        }

        if let value = raw as? Int {
            return value >= 0 ? value : nil
        }
        if let value = raw as? Int64 {
            guard value >= 0 else { return nil }
            return Int(exactly: value)
        }
        if let value = raw as? UInt64 {
            return Int(exactly: value)
        }
        return nil
    }
}
