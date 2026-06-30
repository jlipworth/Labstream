import Foundation
import Testing
@testable import PMSKit

/// Pins the unified download-fraction derivation (#97) so Plex/Jellyfin/Emby present
/// progress the same way: an EXACT `Content-Length` fraction when the server reported a
/// size, an ESTIMATED (clamped, `~%`-marked) fraction for transcoder-streamed rows with no
/// `Content-Length`, and a `nil` spinner fallback when neither is available.
@Suite("Download progress display")
struct DownloadProgressDisplayTests {

    // MARK: - Exact path (real Content-Length: Plex, JF/Emby originals)

    @Test("progress > 0 yields the exact fraction, not estimated")
    func exactFractionFromProgress() throws {
        let f = try #require(DownloadProgressDisplay.fraction(progress: 0.42, bytes: 1_000,
                                                              estimatedTotalBytes: 9_999))
        #expect(f.value == 0.42)
        #expect(f.isEstimated == false)
    }

    @Test("exact path ignores any estimate and clamps a server over-report to 1.0")
    func exactFractionClampsOverReport() throws {
        // An estimate is present but must NOT be consulted once progress is real.
        let f = try #require(DownloadProgressDisplay.fraction(progress: 1.3, bytes: 5,
                                                              estimatedTotalBytes: 10))
        #expect(f.value == 1.0)
        #expect(f.isEstimated == false)
    }

    // MARK: - Estimated path (no Content-Length: JF/Emby transcoded)

    @Test("progress == 0 with bytes + estimate yields an estimated fraction")
    func estimatedFractionFromBytes() throws {
        let f = try #require(DownloadProgressDisplay.fraction(progress: 0, bytes: 300,
                                                              estimatedTotalBytes: 1_000))
        #expect(f.value == 0.3)
        #expect(f.isEstimated == true)
    }

    @Test("estimated fraction clamps at the ceiling so it never reads 100% early")
    func estimatedFractionClampsAtCeiling() throws {
        // bytes already met/exceeded the estimate — must stay below full until terminal status.
        let f = try #require(DownloadProgressDisplay.fraction(progress: 0, bytes: 1_200,
                                                              estimatedTotalBytes: 1_000))
        #expect(f.value == DownloadProgressDisplay.estimatedCeiling)
        #expect(f.value < 1.0)
        #expect(f.isEstimated == true)
    }

    // MARK: - Spinner fallback (nil)

    @Test("no bytes yet returns nil (keep the spinner)")
    func nilWhenNoBytes() {
        #expect(DownloadProgressDisplay.fraction(progress: 0, bytes: 0,
                                                 estimatedTotalBytes: 1_000) == nil)
    }

    @Test("no estimate (original/static row) returns nil when progress is 0")
    func nilWhenNoEstimate() {
        #expect(DownloadProgressDisplay.fraction(progress: 0, bytes: 500,
                                                 estimatedTotalBytes: nil) == nil)
        #expect(DownloadProgressDisplay.fraction(progress: 0, bytes: 500,
                                                 estimatedTotalBytes: 0) == nil)
    }

    // MARK: - Selection rule keyed on (progress == 0 && bytes > 0)

    @Test("the exact-vs-estimated choice is keyed on progress, not backend")
    func selectionRuleKeyedOnProgress() throws {
        // Same bytes/estimate; only `progress` differs — and it decides the path.
        let exact = try #require(DownloadProgressDisplay.fraction(progress: 0.5, bytes: 250,
                                                                 estimatedTotalBytes: 1_000))
        let estimated = try #require(DownloadProgressDisplay.fraction(progress: 0, bytes: 250,
                                                                     estimatedTotalBytes: 1_000))
        #expect(exact.isEstimated == false)
        #expect(estimated.isEstimated == true)
    }

    @Test("static byte range rows prefer exact byte totals before estimated fallback")
    func staticByteRangeRowsPreferExpectedBytes() throws {
        let record = record(bytes: 250,
                            progress: 0,
                            metadata: metadata(resumeMode: .staticByteRange))

        let exact = try #require(DownloadProgressDisplay.fraction(for: record,
                                                                  staticExpectedBytes: 1_000,
                                                                  estimatedTotalBytes: 2_000))
        #expect(exact.value == 0.25)
        #expect(exact.isEstimated == false)

        let live = try #require(DownloadProgressDisplay.fraction(for: record,
                                                                 displayBytes: 500,
                                                                 staticExpectedBytes: 1_000,
                                                                 estimatedTotalBytes: 2_000))
        #expect(live.value == 0.5)
        #expect(live.isEstimated == false)

        let estimated = try #require(DownloadProgressDisplay.fraction(for: record,
                                                                      staticExpectedBytes: nil,
                                                                      estimatedTotalBytes: 2_000))
        #expect(estimated.value == 0.125)
        #expect(estimated.isEstimated == true)
    }

    @Test("non-static row fractions keep the generic exact and estimated rules")
    func nonStaticRowsUseGenericFractionRules() throws {
        let exactRecord = record(bytes: 250,
                                 progress: 0.4,
                                 metadata: metadata(resumeMode: .liveForwardOnly))
        let exact = try #require(DownloadProgressDisplay.fraction(for: exactRecord,
                                                                  staticExpectedBytes: 1_000,
                                                                  estimatedTotalBytes: 2_000))
        #expect(exact.value == 0.4)
        #expect(exact.isEstimated == false)

        let estimatedRecord = record(bytes: 250,
                                     progress: 0,
                                     metadata: metadata(resumeMode: .liveForwardOnly))
        let estimated = try #require(DownloadProgressDisplay.fraction(for: estimatedRecord,
                                                                      staticExpectedBytes: 1_000,
                                                                      estimatedTotalBytes: 2_000))
        #expect(estimated.value == 0.125)
        #expect(estimated.isEstimated == true)
    }

    // MARK: - Post-transfer finalization display state

    @Test("downloading at exact 100% is a transfer-finalization display state")
    func downloadingAtOneHundredPercentIsFinalizing() {
        #expect(DownloadProgressDisplay.isTransferFinalizing(status: .downloading, progress: 1.0))
        #expect(DownloadProgressDisplay.isTransferFinalizing(status: .downloading, progress: 1.2))
    }

    @Test("non-terminal partials and terminal rows are not transfer-finalizing")
    func nonFinalizingRows() {
        #expect(!DownloadProgressDisplay.isTransferFinalizing(status: .downloading, progress: 0.999))
        #expect(!DownloadProgressDisplay.isTransferFinalizing(status: .queued, progress: 1.0))
        #expect(!DownloadProgressDisplay.isTransferFinalizing(status: .preparing, progress: 1.0))
        #expect(!DownloadProgressDisplay.isTransferFinalizing(status: .complete, progress: 1.0))
        #expect(!DownloadProgressDisplay.isTransferFinalizing(status: .unverified, progress: 1.0))
        #expect(!DownloadProgressDisplay.isTransferFinalizing(status: .failed, progress: 1.0))
        #expect(!DownloadProgressDisplay.isTransferFinalizing(status: .paused, progress: 1.0))
    }

    // MARK: - Server-prep finalization display state

    @Test("server prep at 100% is a server-side finalization state")
    func serverPrepAtOneHundredPercentIsFinalizing() {
        #expect(DownloadProgressDisplay.isServerPrepFinalizing(state: "transcoding", progress: 1.0))
        #expect(DownloadProgressDisplay.isServerPrepFinalizing(state: "finalizing", progress: 0.42))
        #expect(DownloadProgressDisplay.isServerPrepFinalizing(state: "FINALIZING", progress: nil))
    }

    @Test("queued or partial server prep is not finalizing")
    func serverPrepPartialsAreNotFinalizing() {
        #expect(!DownloadProgressDisplay.isServerPrepFinalizing(state: "queued", progress: nil))
        #expect(!DownloadProgressDisplay.isServerPrepFinalizing(state: "transcoding", progress: 0.999))
        #expect(!DownloadProgressDisplay.isServerPrepFinalizing(state: nil, progress: nil))
    }

    private func record(bytes: Int,
                        progress: Double,
                        metadata: OfflineMetadata?) -> DownloadRecord {
        DownloadRecord(ratingKey: "rk",
                       title: "Title",
                       localURL: URL(fileURLWithPath: "/tmp/title.mp4"),
                       bytes: bytes,
                       progress: progress,
                       status: .downloading,
                       metadata: metadata)
    }

    private func metadata(resumeMode: DownloadResumeMode) -> OfflineMetadata {
        OfflineMetadata(ratingKey: "rk",
                        title: "Title",
                        type: "movie",
                        resumeMode: resumeMode)
    }
}
