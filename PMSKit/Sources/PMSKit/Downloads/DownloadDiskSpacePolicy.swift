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
