import Foundation
import Testing
@testable import PMSKit

@Suite("Download disk space policy")
struct DownloadDiskSpacePolicyTests {
    @Test("Classifies Cocoa 640 and POSIX ENOSPC as out of space")
    func classifiesOutOfSpaceCodes() {
        #expect(DownloadDiskSpacePolicy.isOutOfSpace(
            errorDomain: NSCocoaErrorDomain,
            errorCode: CocoaError.fileWriteOutOfSpace.rawValue))
        #expect(DownloadDiskSpacePolicy.isOutOfSpace(
            errorDomain: NSPOSIXErrorDomain, errorCode: Int(ENOSPC)))
    }

    @Test("Other file and URL errors are not out of space")
    func rejectsOtherErrors() {
        #expect(!DownloadDiskSpacePolicy.isOutOfSpace(
            errorDomain: NSCocoaErrorDomain, errorCode: CocoaError.fileNoSuchFile.rawValue))
        #expect(!DownloadDiskSpacePolicy.isOutOfSpace(
            errorDomain: NSPOSIXErrorDomain, errorCode: Int(ECONNRESET)))
        #expect(!DownloadDiskSpacePolicy.isOutOfSpace(
            errorDomain: NSURLErrorDomain, errorCode: NSURLErrorNetworkConnectionLost))
    }

    @Test("Walks the underlying-error chain to a wrapped ENOSPC")
    func walksUnderlyingChain() {
        let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        let cocoa = NSError(domain: NSCocoaErrorDomain,
                            code: CocoaError.fileWriteOutOfSpace.rawValue,
                            userInfo: [NSUnderlyingErrorKey: posix])
        let url = NSError(domain: NSURLErrorDomain,
                          code: NSURLErrorCannotWriteToFile,
                          userInfo: [NSUnderlyingErrorKey: cocoa])

        #expect(DownloadDiskSpacePolicy.isOutOfSpace(url))
        #expect(DownloadDiskSpacePolicy.isOutOfSpace(cocoa))
        #expect(DownloadDiskSpacePolicy.isOutOfSpace(posix))
    }

    @Test("A chain with no out-of-space member is not classified")
    func cleanChainNotClassified() {
        let inner = NSError(domain: NSPOSIXErrorDomain, code: Int(EPIPE))
        let outer = NSError(domain: NSURLErrorDomain,
                            code: NSURLErrorNetworkConnectionLost,
                            userInfo: [NSUnderlyingErrorKey: inner])

        #expect(!DownloadDiskSpacePolicy.isOutOfSpace(outer))
    }

    // B01: a resume from a durable static checkpoint needs only the remaining bytes plus the
    // headroom, matching the continuation preflight and the auto-resume park check.
    @Test("Start preflight for a checkpointed resume requires only remaining bytes plus headroom")
    func startPreflightUsesRemainingBytesForCheckpointedResume() {
        let gb: Int64 = 1_000_000_000
        let headroom: Int64 = 500_000_000
        // 60 GB item, 55 GB durable: 5 GB remaining + headroom.
        #expect(DownloadDiskSpacePolicy.requiredFreeBytesToStart(
            expectedBytes: Int(60 * gb), durableCheckpointBytes: Int(55 * gb)) == 5 * gb + headroom)
        // No checkpoint (opaque lane or fresh start): the full expected size plus headroom.
        #expect(DownloadDiskSpacePolicy.requiredFreeBytesToStart(
            expectedBytes: Int(60 * gb), durableCheckpointBytes: nil) == 60 * gb + headroom)
        #expect(DownloadDiskSpacePolicy.requiredFreeBytesToStart(
            expectedBytes: Int(60 * gb), durableCheckpointBytes: 0) == 60 * gb + headroom)
        // Unknown size keeps the bare headroom floor.
        #expect(DownloadDiskSpacePolicy.requiredFreeBytesToStart(
            expectedBytes: nil, durableCheckpointBytes: Int(5 * gb)) == headroom)
        // An oversized checkpoint is truncated to zero by the range start, so it buys nothing.
        #expect(DownloadDiskSpacePolicy.requiredFreeBytesToStart(
            expectedBytes: Int(10 * gb), durableCheckpointBytes: Int(11 * gb)) == 10 * gb + headroom)
        // A complete checkpoint needs only the headroom (the start finalizes it).
        #expect(DownloadDiskSpacePolicy.requiredFreeBytesToStart(
            expectedBytes: Int(10 * gb), durableCheckpointBytes: Int(10 * gb)) == headroom)
    }
}
