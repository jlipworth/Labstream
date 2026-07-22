import Foundation
import Testing
@testable import PMSKit

@Suite("Background temp file cleanup policy")
struct BackgroundTempFileCleanupPolicyTests {
    @Test("Network temp directories include tmp and nsurlsessiond app cache")
    func networkTempDirectories() {
        let tmp = URL(fileURLWithPath: "/container/tmp", isDirectory: true)
        let appSupport = URL(fileURLWithPath: "/container/Library/Application Support", isDirectory: true)

        let directories = BackgroundTempFileCleanupPolicy.networkTempDirectories(
            tempDirectory: tmp,
            appSupportDirectory: appSupport,
            bundleID: "com.example.App"
        )

        #expect(directories == [
            tmp,
            URL(fileURLWithPath: "/container/Library/Caches/com.apple.nsurlsessiond/Downloads/com.example.App", isDirectory: true),
        ])
    }

    @Test("Network temp directories tolerate missing app support")
    func networkTempDirectoriesWithoutAppSupport() {
        let tmp = URL(fileURLWithPath: "/container/tmp", isDirectory: true)

        #expect(BackgroundTempFileCleanupPolicy.networkTempDirectories(
            tempDirectory: tmp,
            appSupportDirectory: nil,
            bundleID: "com.example.App"
        ) == [tmp])
    }

    @Test("CFNetwork candidates require the expected name shape and regular-file bit")
    func cfNetworkCandidateShape() {
        #expect(BackgroundTempFileCleanupPolicy.isCFNetworkDownloadTempFile(
            fileName: "CFNetworkDownload_abc.tmp",
            isRegularFile: true
        ))
        #expect(!BackgroundTempFileCleanupPolicy.isCFNetworkDownloadTempFile(
            fileName: "CFNetworkDownload_abc.tmp",
            isRegularFile: false
        ))
        #expect(!BackgroundTempFileCleanupPolicy.isCFNetworkDownloadTempFile(
            fileName: "Other_CFNetworkDownload_abc.tmp",
            isRegularFile: true
        ))
        #expect(!BackgroundTempFileCleanupPolicy.isCFNetworkDownloadTempFile(
            fileName: "CFNetworkDownload_abc.partial",
            isRegularFile: true
        ))
    }

    @Test("Range body stashes are deleted only when their task is no longer live")
    func rangeBodyStashOwnership() {
        #expect(BackgroundTempFileCleanupPolicy.rangeBodyStashTaskIdentifier(
            fileName: "vp-range-body-42"
        ) == 42)
        #expect(BackgroundTempFileCleanupPolicy.rangeBodyStashTaskIdentifier(
            fileName: "vp-range-chunk-42"
        ) == 42)
        #expect(BackgroundTempFileCleanupPolicy.rangeBodyStashTaskIdentifier(
            fileName: "vp-range-body-42-o536870912"
        ) == 42)
        #expect(BackgroundTempFileCleanupPolicy.rangeBodyStashTaskIdentifier(
            fileName: "vp-range-chunk-42-o536870912"
        ) == 42)
        #expect(BackgroundTempFileCleanupPolicy.rangeBodyStashOffset(
            fileName: "vp-range-body-42-o536870912"
        ) == 536870912)
        #expect(BackgroundTempFileCleanupPolicy.rangeBodyStashOffset(
            fileName: "vp-range-body-42"
        ) == nil)
        #expect(BackgroundTempFileCleanupPolicy.rangeBodyStashTaskIdentifier(
            fileName: "vp-range-body-not-a-number"
        ) == nil)
        #expect(!BackgroundTempFileCleanupPolicy.shouldDeleteRangeBodyStash(
            fileName: "vp-range-body-42",
            liveTaskIdentifiers: [42]
        ))
        #expect(BackgroundTempFileCleanupPolicy.shouldDeleteRangeBodyStash(
            fileName: "vp-range-body-42",
            liveTaskIdentifiers: [7]
        ))
        #expect(!BackgroundTempFileCleanupPolicy.shouldDeleteRangeBodyStash(
            fileName: "vp-range-body-42-o536870912",
            liveTaskIdentifiers: [42]
        ))
        #expect(BackgroundTempFileCleanupPolicy.shouldDeleteRangeBodyStash(
            fileName: "vp-range-body-42-o536870912",
            liveTaskIdentifiers: [7]
        ))
        #expect(!BackgroundTempFileCleanupPolicy.shouldDeleteRangeBodyStash(
            fileName: "unrelated",
            liveTaskIdentifiers: []
        ))
    }
}
