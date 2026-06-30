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

    @Test("Range chunk stashes are deleted only when their task is no longer live")
    func rangeChunkStashOwnership() {
        #expect(BackgroundTempFileCleanupPolicy.rangeChunkStashTaskIdentifier(
            fileName: "vp-range-chunk-42"
        ) == 42)
        #expect(BackgroundTempFileCleanupPolicy.rangeChunkStashTaskIdentifier(
            fileName: "vp-range-chunk-not-a-number"
        ) == nil)
        #expect(!BackgroundTempFileCleanupPolicy.shouldDeleteRangeChunkStash(
            fileName: "vp-range-chunk-42",
            liveTaskIdentifiers: [42]
        ))
        #expect(BackgroundTempFileCleanupPolicy.shouldDeleteRangeChunkStash(
            fileName: "vp-range-chunk-42",
            liveTaskIdentifiers: [7]
        ))
        #expect(!BackgroundTempFileCleanupPolicy.shouldDeleteRangeChunkStash(
            fileName: "unrelated",
            liveTaskIdentifiers: []
        ))
    }

    @Test("Network cleanup deletes only when candidates exist and no URLSession tasks are live")
    func networkCleanupDisposition() {
        #expect(BackgroundTempFileCleanupPolicy.cleanupDisposition(
            liveTaskCount: 0,
            candidateCount: 0
        ) == .none)
        #expect(BackgroundTempFileCleanupPolicy.cleanupDisposition(
            liveTaskCount: 2,
            candidateCount: 3
        ) == .skipLiveTasks(liveTaskCount: 2))
        #expect(BackgroundTempFileCleanupPolicy.cleanupDisposition(
            liveTaskCount: 0,
            candidateCount: 3
        ) == .deleteCandidates)
    }
}
