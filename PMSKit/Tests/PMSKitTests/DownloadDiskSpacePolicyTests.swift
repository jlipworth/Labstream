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
}
