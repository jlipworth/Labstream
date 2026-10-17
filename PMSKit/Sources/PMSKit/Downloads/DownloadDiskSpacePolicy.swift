import Foundation

/// Classifies "the disk is full" errors so transfer failure paths can surface the storage-full
/// user message (and stop retrying) instead of "Transfer failed (system code 640)" or a fake
/// resumable pause that immediately fails again.
public enum DownloadDiskSpacePolicy {
    /// NSCocoaErrorDomain `NSFileWriteOutOfSpaceError` and the POSIX/Mach ENOSPC variants.
    public static func isOutOfSpace(errorDomain: String, errorCode: Int) -> Bool {
        switch errorDomain {
        case NSCocoaErrorDomain:
            return errorCode == CocoaError.fileWriteOutOfSpace.rawValue
        case NSPOSIXErrorDomain:
            return errorCode == Int(ENOSPC)
        default:
            return false
        }
    }

    /// Fixed free-space margin kept for the OS and the temp-then-move copy.
    public static let startHeadroomBytes: Int64 = 500_000_000

    /// Free space a transfer start must find before it creates work (B01). A static byte-range
    /// resume continues from its durable checkpoint, so it needs only the remaining bytes plus the
    /// headroom — the same formula as the continuation preflight and the auto-resume park check.
    /// `durableCheckpointBytes` is `nil` for lanes without a checkpoint. A checkpoint larger than
    /// the expected size is discarded by the range start, so it reserves nothing.
    public static func requiredFreeBytesToStart(expectedBytes: Int?,
                                                durableCheckpointBytes: Int?,
                                                headroomBytes: Int64 = startHeadroomBytes) -> Int64 {
        guard let expectedBytes, expectedBytes > 0 else { return headroomBytes }
        let expected = Int64(expectedBytes)
        var checkpoint = Int64(max(0, durableCheckpointBytes ?? 0))
        if checkpoint > expected { checkpoint = 0 }
        return max(headroomBytes, expected - checkpoint + headroomBytes)
    }

    /// Walks the `NSUnderlyingErrorKey` chain (bounded): URLSession and FileHandle wrap the
    /// POSIX ENOSPC several layers deep.
    public static func isOutOfSpace(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        var depth = 0
        while let nsError = current, depth < 8 {
            if isOutOfSpace(errorDomain: nsError.domain, errorCode: nsError.code) {
                return true
            }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return false
    }
}
