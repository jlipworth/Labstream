import Foundation
import Testing
@testable import PMSKit

/// The status and speed side of the downloads TLA+ model (`specs/downloads/status/DownloadsStatus.tla`,
/// `specs/downloads/status/README.md`).
///
/// The model treats a rate estimator as the stage it has reached (settling, window, quiet) and
/// leaves the arithmetic out. The seeded tests here cover that arithmetic: each draws event
/// sequences from a fixed-seed generator, so a failure reproduces exactly.
///
/// The two findings at the end state the wanted behaviour inside `withKnownIssue`, so the suite
/// stays green while they are open. When a fix lands, `withKnownIssue` fails the test: delete the
/// wrapper then, and flip the matching `status/Finding-*.cfg` to `EXPECT: pass`.
@Suite("Downloads formal-model status and speed")
struct DownloadsFormalModelStatusTests {

    // MARK: - Deterministic randomness

    /// SplitMix64: small, fast and identical on every platform.
    private struct Seeded: RandomNumberGenerator {
        var state: UInt64
        init(_ seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func real(_ range: ClosedRange<Double>) -> Double { Double.random(in: range, using: &self) }
        mutating func int(_ range: ClosedRange<Int>) -> Int { Int.random(in: range, using: &self) }
        mutating func chance(_ probability: Double) -> Bool { real(0...1) < probability }
    }

    private static func time(_ seconds: Double) -> Date { Date(timeIntervalSinceReferenceDate: seconds) }

    private static func key(_ index: Int, attempt: Int = 0) -> DownloadAttemptKey {
        DownloadAttemptKey(ratingKey: "row-\(index)", attemptID: .init(rawValue: "attempt-\(index)-\(attempt)")!)
    }

    // MARK: - A batch of transfers across sleep and wake

    /// One transfer as the daemon and the delegate see it. Bytes arrive at `rate(at:)`; a callback
    /// reports them. After a blackout (the app suspended) the first callbacks may report only part
    /// of what piled up, and the rest within `lagEnds` (model assumption A1: within 4 s of the
    /// first callback after the blackout).
    private struct SimulatedTransfer {
        /// Piecewise-constant true rate: `(start, bytesPerSecond)`, sorted by start.
        var segments: [(start: Double, rate: Double)]
        var lagStart = 0.0
        var lagEnds = 0.0
        var lagBytes = 0.0
        var lastReported = 0
        var nextCallback = 0.0

        func trueBytes(at now: Double) -> Double {
            var total = 0.0
            for (index, segment) in segments.enumerated() where segment.start < now {
                let end = index + 1 < segments.count ? min(segments[index + 1].start, now) : now
                total += segment.rate * (end - segment.start)
            }
            return total
        }

        /// What a callback at `now` reports: the true total less whatever is still lagging.
        func reported(at now: Double) -> Int {
            let lag: Double
            if now >= lagEnds || lagEnds <= lagStart {
                lag = 0
            } else {
                lag = lagBytes * (lagEnds - now) / (lagEnds - lagStart)
            }
            return max(lastReported, Int(trueBytes(at: now) - lag))
        }
    }

    /// What must hold of an estimator's evidence before `rate(at:)` may answer, tracked beside
    /// the estimator from the same calls.
    private struct Evidence {
        var first: Double
        var last: Double
        var lastBytes: Int
        var count: Int
    }

    private struct BatchRun {
        var nonNilAnswers = 0
        var longAwakePeriods = 0
    }

    /// Drive a batch through awake periods and sleeps and check every answer `rate(at:)` gives.
    ///
    /// - `steady`: every transfer flows at one constant rate for the whole run, so a non-nil
    ///   answer must equal the batch's true total. Otherwise rates change and stall, and a
    ///   non-nil answer must not exceed the sum of each transfer's peak rate.
    private static func runBatch(seed: UInt64, steady: Bool) -> BatchRun {
        var rng = Seeded(seed)
        var estimator = DownloadAggregateRateEstimator()
        let gap = estimator.callbackGap
        let settle = estimator.settlingDuration
        let count = rng.int(2...4)
        let keys = (0..<count).map { key($0) }
        let horizon = 400.0

        var transfers: [SimulatedTransfer] = []
        var peaks: [Double] = []
        for _ in 0..<count {
            let base = rng.real(50_000...5_000_000)
            if steady {
                transfers.append(SimulatedTransfer(segments: [(0, base)]))
                peaks.append(base)
            } else {
                var segments: [(start: Double, rate: Double)] = []
                var start = 0.0
                var peak = 0.0
                while start < horizon {
                    // A third of the stretches are stalls: no bytes, so no callbacks.
                    let rate = rng.chance(0.33) ? 0 : rng.real(0.1...1) * base
                    peak = max(peak, rate)
                    segments.append((start, rate))
                    start += rng.real(2...25)
                }
                transfers.append(SimulatedTransfer(segments: segments))
                peaks.append(peak)
            }
        }
        let trueTotal = peaks.reduce(0, +)
        let tolerance = Double(count) * 8 + trueTotal * 1e-6

        var evidence: [Int: Evidence] = [:]
        var run = BatchRun()
        estimator.setActiveTransfers(Set(keys))

        func check(_ now: Double, _ context: String) {
            guard let rate = estimator.rate(at: time(now)) else { return }
            run.nonNilAnswers += 1
            #expect(rate.isFinite && rate >= 0, "seed \(seed) \(context) t=\(now)")
            // #379: an answer needs settled, fresh evidence from every transfer of the batch.
            for index in 0..<count {
                guard let seen = evidence[index] else {
                    Issue.record("seed \(seed) \(context) t=\(now): transfer \(index) has no evidence")
                    continue
                }
                #expect(seen.count >= 2, "seed \(seed) \(context) t=\(now): transfer \(index) has one observation")
                #expect(now >= seen.first + settle, "seed \(seed) \(context) t=\(now): transfer \(index) is settling")
                #expect(now - seen.last < gap, "seed \(seed) \(context) t=\(now): transfer \(index) is stale")
            }
            if steady {
                // #379: never a partial sum. #224: never an inflated one.
                #expect(abs(rate - trueTotal) <= tolerance,
                        "seed \(seed) \(context) t=\(now): \(rate) is not the batch's \(trueTotal)")
            } else {
                // #224: bytes that piled up are never divided by a short interval.
                #expect(rate <= trueTotal + tolerance,
                        "seed \(seed) \(context) t=\(now): \(rate) exceeds the peak total \(trueTotal)")
            }
        }

        var now = 0.0
        var firstPeriod = true
        while now < horizon {
            let awakeFor = rng.real(1...45)
            let awakeUntil = now + awakeFor
            for index in 0..<count {
                // Callbacks after a wake are staggered: some transfers report at once, some late.
                let delay = firstPeriod ? rng.real(0...0.5) : (rng.chance(0.3) ? rng.real(0...12) : rng.real(0...0.6))
                transfers[index].nextCallback = now + delay
                if !firstPeriod {
                    let first = transfers[index].nextCallback
                    let behind = max(0, transfers[index].trueBytes(at: first) - Double(transfers[index].lastReported))
                    transfers[index].lagStart = first
                    transfers[index].lagEnds = first + rng.real(0...3)
                    transfers[index].lagBytes = rng.chance(0.5) ? behind * rng.real(0...0.8) : 0
                }
            }
            firstPeriod = false
            check(now, "wake")

            while true {
                guard let index = (0..<count).min(by: { transfers[$0].nextCallback < transfers[$1].nextCallback })
                else { break }
                let at = transfers[index].nextCallback
                if at >= awakeUntil { break }
                let bytes = transfers[index].reported(at: at)
                // didWriteData fires only when bytes were written.
                if bytes > transfers[index].lastReported {
                    if let seen = evidence[index], at - seen.last >= gap || bytes < seen.lastBytes {
                        evidence.removeAll()
                    }
                    if var seen = evidence[index] {
                        seen.last = at
                        seen.lastBytes = bytes
                        seen.count += 1
                        evidence[index] = seen
                    } else {
                        evidence[index] = Evidence(first: at, last: at, lastBytes: bytes, count: 1)
                    }
                    estimator.sample(keys[index], bytes: bytes, at: time(at))
                    transfers[index].lastReported = bytes
                }
                transfers[index].nextCallback = at + rng.real(0.05...0.9)
                check(at, "callback")
                if rng.chance(0.2) { check(at + rng.real(0...3), "refresh") }
            }

            // "Updating speed..." gives way to a number while every transfer flows: the latest
            // first callback (12 s), settling (4 s), one more callback and the minimum window.
            if steady, awakeFor >= 20 {
                run.longAwakePeriods += 1
                #expect(estimator.rate(at: time(awakeUntil)) != nil,
                        "seed \(seed): no speed after \(awakeFor) s awake with every transfer flowing")
            }

            // Sleep. The foreground and background-wake hooks reset the estimator; when neither
            // runs, a sleep of at least callbackGap must be caught by the gap rule alone.
            let hinted = rng.chance(0.7)
            let sleepFor = hinted ? rng.real(0.2...300) : rng.real(gap + 0.5...300)
            now = awakeUntil + sleepFor
            if hinted {
                estimator.resetAfterWake()
                evidence.removeAll()
            }
        }
        return run
    }

    @Test("Aggregate speed: a steady batch reads its true total or nothing, across sleeps (#379, #224)")
    func aggregateSteadyBatchIsExactOrHidden() {
        var answers = 0
        var longPeriods = 0
        for seed in UInt64(1)...60 {
            let run = Self.runBatch(seed: seed, steady: true)
            answers += run.nonNilAnswers
            longPeriods += run.longAwakePeriods
        }
        #expect(answers > 1_000, "the runs must publish speeds, or the test checks nothing")
        #expect(longPeriods > 50)
    }

    @Test("Aggregate speed: with stalls and changing rates it never exceeds the peak total (#224)")
    func aggregateNeverExceedsPeakThroughput() {
        var answers = 0
        for seed in UInt64(1_001)...1_060 {
            answers += Self.runBatch(seed: seed, steady: false).nonNilAnswers
        }
        #expect(answers > 200, "the runs must publish speeds, or the test checks nothing")
    }

    @Test("Aggregate speed: arbitrary samples, resets and membership changes never yield an unbacked answer")
    func aggregateAnswersNeedEvidenceUnderAbuse() {
        var answers = 0
        for seed in UInt64(2_001)...2_080 {
            var rng = Seeded(seed)
            var estimator = DownloadAggregateRateEstimator(
                windowDuration: rng.real(1...6), minimumWindow: rng.real(0.1...1),
                callbackGap: rng.real(2...8), settlingDuration: rng.chance(0.3) ? 0 : rng.real(0...5))
            var active: Set<Int> = []
            var attempts = [0, 0, 0, 0]
            var evidence: [Int: Evidence] = [:]
            var bytes = [0, 0, 0, 0]
            var now = 0.0

            for _ in 0..<600 {
                switch rng.int(0...19) {
                case 0:
                    estimator.resetAfterWake()
                    evidence.removeAll()
                case 1, 2:
                    // Membership: add, remove, or replace an attempt (a retry is a new key).
                    var next = active
                    let index = rng.int(0...3)
                    if next.contains(index) {
                        if rng.chance(0.5) { next.remove(index) } else {
                            attempts[index] += 1
                            evidence[index] = nil
                            evidence.removeAll()
                        }
                    } else {
                        next.insert(index)
                        evidence.removeAll()
                    }
                    estimator.setActiveTransfers(Set(next.map { Self.key($0, attempt: attempts[$0]) }))
                    active = next
                    evidence = evidence.filter { active.contains($0.key) }
                default:
                    // Mostly forward in time and bytes; sometimes a long gap, a clock step back
                    // or a byte count that went down.
                    let step = rng.chance(0.08) ? rng.real(5...40) : rng.real(0...1.2)
                    now += rng.chance(0.03) ? -rng.real(0...2) : step
                    let index = rng.int(0...3)
                    bytes[index] += rng.chance(0.05) ? -rng.int(0...50_000) : rng.int(0...2_000_000)
                    bytes[index] = max(0, bytes[index])
                    if active.contains(index) {
                        if let seen = evidence[index],
                           now - seen.last >= estimator.callbackGap || now < seen.last || bytes[index] < seen.lastBytes {
                            evidence.removeAll()
                        }
                        if var seen = evidence[index] {
                            seen.last = now
                            seen.lastBytes = bytes[index]
                            seen.count += 1
                            evidence[index] = seen
                        } else {
                            evidence[index] = Evidence(first: now, last: now, lastBytes: bytes[index], count: 1)
                        }
                    }
                    estimator.sample(Self.key(index, attempt: attempts[index]), bytes: bytes[index], at: Self.time(now))
                }

                let query = now + (rng.chance(0.5) ? 0 : rng.real(-1...9))
                guard let rate = estimator.rate(at: Self.time(query)) else { continue }
                answers += 1
                #expect(rate.isFinite && rate >= 0, "seed \(seed)")
                #expect(!active.isEmpty, "seed \(seed): a speed with no active transfer")
                for index in active {
                    guard let seen = evidence[index] else {
                        Issue.record("seed \(seed) t=\(query): transfer \(index) has no evidence")
                        continue
                    }
                    #expect(seen.count >= 2, "seed \(seed) t=\(query): one observation")
                    #expect(query >= seen.first + estimator.settlingDuration, "seed \(seed) t=\(query): settling")
                    #expect(query >= seen.last && query - seen.last < estimator.callbackGap,
                            "seed \(seed) t=\(query): stale or future evidence")
                }
            }
        }
        #expect(answers > 300, "the runs must publish speeds, or the test checks nothing")
    }

    // MARK: - One row's estimator

    @Test("Row speed: finite, never above the true peak, hidden after a rebaseline and after a stall")
    func rowEstimatorStaysWithinTruth() {
        var answers = 0
        for seed in UInt64(3_001)...3_080 {
            var rng = Seeded(seed)
            let suppressFor = rng.chance(0.5) ? 4.0 : 0.0
            var estimator = DownloadRateEstimator(rebaselineSuppressWindow: suppressFor)
            let peak = rng.real(10_000...8_000_000)
            var now = 0.0
            var bytes = 0.0
            var lastForward = 0.0
            var rebaselinedAt: Double?
            var lastSampled = 0
            var first = true

            for _ in 0..<500 {
                let step = rng.real(0.05...2)
                now += step
                let backwards = !first && rng.chance(0.03) && bytes > 1
                if backwards {
                    // A checkpoint reset: the byte count drops and the transfer carries on.
                    bytes = (bytes * rng.real(0...0.9)).rounded(.down)
                } else if !rng.chance(0.3) {
                    bytes += rng.real(0...1) * peak * step
                }
                let sampled = Int(bytes)
                let rate = estimator.sample(bytes: sampled, at: Self.time(now))

                if !first, sampled < lastSampled {
                    rebaselinedAt = now
                    lastForward = now
                    #expect(rate == nil, "seed \(seed) t=\(now): a rate from a backwards sample")
                } else if first || sampled > lastSampled {
                    lastForward = now
                }
                if let rebaselinedAt, now < rebaselinedAt + suppressFor {
                    #expect(rate == nil, "seed \(seed) t=\(now): a rate inside the rebaseline grace")
                }
                if now - lastForward >= estimator.stallTimeout {
                    #expect(rate == nil, "seed \(seed) t=\(now): a rate \(estimator.stallTimeout) s into a stall")
                }
                if let rate {
                    answers += 1
                    #expect(rate.isFinite && rate >= 0, "seed \(seed) t=\(now)")
                    // One byte of truncation at each end of a window that spans at least 0.5 s.
                    #expect(rate <= peak + 4, "seed \(seed) t=\(now): \(rate) exceeds the peak \(peak)")
                }
                let total = sampled + rng.int(-1_000...50_000_000)
                if let eta = estimator.eta(expectedTotal: total) {
                    #expect(eta.isFinite && eta > 0, "seed \(seed) t=\(now)")
                    #expect(total > sampled, "seed \(seed) t=\(now): an ETA with nothing left")
                }
                #expect(estimator.eta(expectedTotal: nil) == nil)
                lastSampled = sampled
                first = false
            }
        }
        #expect(answers > 2_000, "the runs must publish speeds, or the test checks nothing")
    }

    /// The contract behind #224 and finding S4 (`status/Finding-S4-LateCallbackInflatesRow.cfg`).
    /// Bytes that arrived while the app was suspended are a valid forward count, so the estimator
    /// cannot tell them from a burst: the owner has to call `rebaseline` on the first sample
    /// after the boundary. `DownloadManager` does that for static-range rows on their first
    /// callback after foreground; a forward-only row has only a 4 s grace, which S4 is about.
    @Test("Row speed: catch-up bytes inflate the rate unless the owner re-baselines on them (#224)")
    func catchUpBytesNeedAnOwnerRebaseline() {
        for seed in UInt64(3_501)...3_540 {
            var rng = Seeded(seed)
            let peak = rng.real(200_000...4_000_000)
            let asleep = rng.real(30...600)
            // A sample at the pre-sleep watermark after foreground, as a refresh in the grace
            // window takes it; then the first callback, late, with everything the sleep wrote.
            let foreground = 1_000.0
            let baselineAt = foreground + rng.real(0...4)
            let callbackAt = baselineAt + rng.real(0.6...6)
            let before = 5_000_000
            let after = before + Int(peak * (asleep + callbackAt - foreground))

            var unprotected = DownloadRateEstimator(rebaselineSuppressWindow: 4.0)
            _ = unprotected.sample(bytes: before, at: Self.time(baselineAt))
            let inflated = unprotected.sample(bytes: after, at: Self.time(callbackAt))
            #expect((inflated ?? 0) > peak * 2, "seed \(seed): the estimator alone cannot see a lifecycle boundary")

            var protected = DownloadRateEstimator(rebaselineSuppressWindow: 4.0)
            _ = protected.sample(bytes: before, at: Self.time(baselineAt))
            protected.rebaseline(bytes: after, at: Self.time(callbackAt))
            var now = callbackAt
            var bytes = Double(after)
            for _ in 0..<40 {
                let step = rng.real(0.2...1.2)
                now += step
                bytes += peak * step * rng.real(0.2...1)
                let rate = protected.sample(bytes: Int(bytes), at: Self.time(now))
                if now < callbackAt + 4 {
                    #expect(rate == nil, "seed \(seed): a rate inside the grace after the rebaseline")
                } else {
                    #expect((rate ?? 0) <= peak + 4, "seed \(seed): \(rate ?? 0) exceeds the peak \(peak)")
                }
            }
            #expect(protected.sample(bytes: Int(bytes) + 1, at: Self.time(now + 1)) != nil)
        }
    }

    // MARK: - Bytes, fractions and percentages

    @Test("Live range bytes: the merged watermark and the rate sample never go backwards without cause")
    func liveRangeBytesAreMonotone() {
        for seed in UInt64(5_001)...5_060 {
            var rng = Seeded(seed)
            var previous: DownloadLiveRangeProgressSample?
            var now = 0.0
            for _ in 0..<300 {
                now += rng.real(0...2)
                let live = rng.int(0...10_000_000)
                let expected: Int? = rng.chance(0.4) ? nil : rng.int(1...10_000_000)
                let merged = DownloadLiveRangeProgressPolicy.mergedSample(
                    liveBytes: live, expectedBytes: expected, previous: previous, updatedAt: Self.time(now))
                #expect(merged.bytes >= live)
                #expect(merged.bytes >= (previous?.bytes ?? 0), "seed \(seed): the watermark went backwards")
                #expect(merged.expectedBytes == (expected ?? previous?.expectedBytes))
                previous = merged

                // #416: a dip is held only when finished bodies awaiting append explain all of it.
                let reported = rng.int(0...1_000_000)
                let last: Int? = rng.chance(0.2) ? nil : rng.int(0...1_000_000)
                let awaiting = rng.chance(0.5) ? 0 : rng.int(0...400_000)
                let sample = DownloadLiveRangeProgressPolicy.rateSampleBytes(
                    reportedBytes: reported, previous: last, bytesAwaitingAppend: awaiting)
                #expect(sample >= reported)
                if let last, reported < last, awaiting > 0, reported + awaiting >= last {
                    #expect(sample == last, "seed \(seed): an explained dip reached the estimator")
                } else {
                    #expect(sample == reported, "seed \(seed): an unexplained loss was hidden")
                }

                // The optimistic total never reads complete before the durable file is.
                let durable = rng.int(0...10_000_000)
                let shown = DownloadLiveRangeProgressPolicy.activeDisplayBytes(
                    optimisticBytes: live, expectedBytes: expected, durableBytes: durable)
                #expect(shown >= 0 && shown <= max(live, 0))
                if let expected {
                    #expect(shown <= expected)
                    if durable < expected { #expect(shown < expected) }
                }

                let segment: Int? = rng.chance(0.3) ? nil : rng.int(0...5_000_000)
                let accounted = DownloadLiveRangeProgressPolicy.accountedTaskBodyBytes(
                    reportedBytes: rng.int(-100...20_000_000), segmentLength: segment)
                #expect(accounted >= 0)
                if let segment { #expect(accounted <= segment) }
            }
        }
    }

    @Test("Progress fraction: inside 0...1, never complete from an estimate, never lower for more bytes")
    func progressFractionIsBoundedAndMonotone() {
        for seed in UInt64(6_001)...6_040 {
            var rng = Seeded(seed)
            for _ in 0..<400 {
                let progress = rng.chance(0.5) ? 0 : rng.real(0...1.3)
                let bytes = rng.int(0...5_000_000)
                let more = bytes + rng.int(0...5_000_000)
                let estimate: Int? = rng.chance(0.3) ? nil : rng.int(0...4_000_000)
                let fraction = DownloadProgressDisplay.fraction(
                    progress: progress, bytes: bytes, estimatedTotalBytes: estimate)
                let later = DownloadProgressDisplay.fraction(
                    progress: progress, bytes: more, estimatedTotalBytes: estimate)
                if let fraction {
                    #expect(fraction.value >= 0 && fraction.value <= 1)
                    if fraction.isEstimated {
                        #expect(fraction.value <= DownloadProgressDisplay.estimatedCeiling)
                        #expect(progress <= 0)
                    } else {
                        #expect(progress > 0)
                    }
                    #expect((later?.value ?? -1) >= fraction.value, "seed \(seed): more bytes, less progress")
                } else {
                    #expect(progress <= 0)
                    #expect(bytes <= 0 || (estimate ?? 0) <= 0)
                }
                #expect(DownloadProgressDisplay.isTransferFinalizing(status: .downloading, progress: progress)
                    == (progress >= 1))
                #expect(!DownloadProgressDisplay.isTransferFinalizing(status: .paused, progress: progress))
            }
        }
    }

    @Test("Sidebar and toolbar percentage: fail closed on any unknown total, bounded, monotone (#251)")
    func aggregatePercentageFailsClosed() {
        typealias Sample = OfflineActiveTransferPercentage.Sample
        let statuses: [DownloadStatus] = [.queued, .preparing, .downloading, .complete, .unverified, .failed, .paused]
        for seed in UInt64(7_001)...7_060 {
            var rng = Seeded(seed)
            for _ in 0..<200 {
                let samples = (0..<rng.int(0...6)).map { _ in
                    Sample(status: statuses[rng.int(0...statuses.count - 1)],
                           transferredBytes: rng.chance(0.03) ? -1 : rng.int(0...9_000_000),
                           trustworthyExpectedBytes: rng.chance(0.25) ? nil : rng.int(0...9_000_000))
                }
                let active = samples.filter { $0.status == .downloading }
                let percent = OfflineActiveTransferPercentage.integerPercent(samples)
                let allKnown = !active.isEmpty && active.allSatisfy {
                    $0.transferredBytes >= 0 && ($0.trustworthyExpectedBytes ?? 0) > 0
                }
                // The same rule as the speed: one transfer without a trustworthy total hides
                // the whole figure instead of leaving it out of the sum.
                #expect((percent != nil) == allKnown, "seed \(seed)")
                if let percent {
                    #expect((0...100).contains(percent))
                    let further = samples.map { sample in
                        Sample(status: sample.status,
                               transferredBytes: sample.transferredBytes + rng.int(0...1_000_000),
                               trustworthyExpectedBytes: sample.trustworthyExpectedBytes)
                    }
                    let later = OfflineActiveTransferPercentage.integerPercent(further)
                    #expect((later ?? -1) >= percent, "seed \(seed): more bytes, lower percentage")
                }

                let sidebar = OfflineSidebarStatusPolicy.presentation(samples)
                #expect((sidebar != nil) == !active.isEmpty, "seed \(seed): the sidebar shows work exactly when a row downloads")
                #expect(sidebar?.activeCount ?? 0 == active.count)
                #expect(sidebar?.aggregatePercent == percent)
            }
        }
    }

    // MARK: - Phase and caption

    private static func context(status: DownloadStatus, bytes: Int, isActive: Bool,
                                resumeMode: DownloadResumeMode?, lifecycle: DownloadLifecycle?,
                                isBackendConfigured: Bool, speed: Double?) -> DownloadRowStatusCaptionPolicy.Context {
        DownloadRowStatusCaptionPolicy.Context(
            status: status, progress: 0, bytes: bytes, lane: .original, backend: .jellyfin,
            resumeMode: resumeMode, isServerPreparedVersion: false, resolutionLabel: nil,
            displayFraction: nil, isActive: isActive, isBackendConfigured: isBackendConfigured,
            isTranscodeLimited: false, serverPrepState: nil, serverPrepProgress: nil,
            serverPrepETA: nil, downloadETA: speed == nil ? nil : 120,
            downloadSpeedBytesPerSecond: speed, hasServerPrepQueueTitle: false, isRetrying: false,
            failureCaption: nil, lifecycle: lifecycle)
    }

    @Test("Phase: every combination of row facts agrees with the model's phase rules")
    func phaseMatchesModelForEveryCombination() {
        let statuses: [DownloadStatus] = [.queued, .preparing, .downloading, .complete, .unverified, .failed, .paused]
        let modes: [DownloadResumeMode?] = [nil, .staticByteRange, .serverPrepThenStatic, .liveForwardOnly]
        for status in statuses {
            for bytes in [0, 1, 4_096] {
                for isActive in [false, true] {
                    for mode in modes {
                        for configured in [false, true] {
                            for lifecycle in [DownloadLifecycle?.none] + DownloadLifecycle.allCases.map(Optional.some) {
                                let context = Self.context(
                                    status: status, bytes: bytes, isActive: isActive, resumeMode: mode,
                                    lifecycle: lifecycle, isBackendConfigured: configured, speed: 2_000_000)
                                let phase = DownloadRowStatusCaptionPolicy.phase(context)
                                let caption = DownloadRowStatusCaptionPolicy.caption(context)
                                let label = "\(status) bytes=\(bytes) active=\(isActive) mode=\(String(describing: mode)) lifecycle=\(String(describing: lifecycle))"

                                // A parked or finished row is never active work, and never shows a speed.
                                if !status.isActiveWork {
                                    #expect(!phase.isActiveWork, "\(label)")
                                    #expect(!caption.contains("/s"), "\(label): \(caption)")
                                }
                                // A row with a running task (`isActive`) is never read as idle.
                                if status.isActiveWork, isActive {
                                    #expect(phase.isActiveWork, "\(label): \(phase)")
                                }
                                // Bytes on disk and nothing running: not an active transfer.
                                if status.isActiveWork, !isActive, bytes > 0, lifecycle != .finalizing {
                                    #expect(phase == .inactiveTransfer, "\(label): \(phase)")
                                    #expect(!caption.contains("/s"), "\(label): \(caption)")
                                }
                                if status.isActiveWork, lifecycle == .finalizing {
                                    #expect(phase == .transferFinalizing, "\(label)")
                                    #expect(!caption.contains("/s"), "\(label): \(caption)")
                                }
                                if status.isActiveWork, !isActive, !configured, bytes == 0, lifecycle != .finalizing {
                                    #expect(phase == .waitingForBackend, "\(label)")
                                }
                                #expect(!caption.isEmpty, "\(label)")
                            }
                        }
                    }
                }
            }
        }
    }

    @Test("Persisted phase, the health snapshot and the watchdog agree on what counts as work")
    func persistedPhaseHealthAndWatchdogAgree() {
        let statuses: [DownloadStatus] = [.queued, .preparing, .downloading, .complete, .unverified, .failed, .paused]
        var records: [DownloadRecord] = []
        for (index, status) in statuses.enumerated() {
            for bytes in [0, 2_048] {
                for mode in [DownloadResumeMode.staticByteRange, .liveForwardOnly] {
                    let ratingKey = "jellyfin:item-\(index)-\(bytes)-\(mode.rawValue)"
                    let record = DownloadRecord(
                        ratingKey: ratingKey, title: "Fixture",
                        localURL: URL(fileURLWithPath: "/tmp/fixture-\(index).mp4"),
                        bytes: bytes, status: status,
                        metadata: OfflineMetadata(ratingKey: ratingKey, title: "Fixture", type: "movie",
                                                  backendKind: .jellyfin,
                                                  downloadLane: mode == .staticByteRange ? .original : .optimize,
                                                  resumeMode: mode))
                    records.append(record)
                    let snapshot = DownloadJobSnapshot(record: record)
                    #expect(snapshot.persistedPhase.isActiveWork == status.isActiveWork, "\(ratingKey) \(status)")
                    // Only a downloading forward-only stream and a preparing row need the watchdog.
                    #expect(DownloadWatchdogPolicy.requiresWatchdog(record)
                        == ((status == .downloading && mode == .liveForwardOnly) || status == .preparing),
                            "\(ratingKey) \(status)")

                    let health = DownloadHealthSnapshotPolicy.makeSnapshot(
                        records: [record], activeJobCount: 0, retryingCount: 0, retryHandoffCount: 0,
                        pendingStaticResumeCount: 0, finalizingStaticRecoveryCount: 0,
                        serverPrepPollerCount: 0, jellyfinKeepaliveCount: 0, forwardStallWatchCount: 0,
                        session: DownloadHealthSessionSnapshot())
                    #expect(health.hasWork == status.isActiveWork, "\(ratingKey) \(status)")
                    #expect(DownloadHealthSnapshotPolicy.shouldRecord(snapshot: health, lastRecordedAt: nil, now: Date())
                        == status.isActiveWork)
                }
            }
        }

        // A running task is work whatever the rows say; an idle library is never sampled.
        let idle = DownloadHealthSnapshotPolicy.makeSnapshot(
            records: records.filter { !$0.status.isActiveWork }, activeJobCount: 0, retryingCount: 0,
            retryHandoffCount: 0, pendingStaticResumeCount: 0, finalizingStaticRecoveryCount: 0,
            serverPrepPollerCount: 0, jellyfinKeepaliveCount: 0, forwardStallWatchCount: 0,
            session: DownloadHealthSessionSnapshot())
        #expect(!idle.hasWork)
        var withTask = idle
        withTask.session.rangeInflightCount = 1
        #expect(withTask.hasWork)
        var scannedDisk = false
        let collected = DownloadHealthSnapshotPolicy.collectIfNeeded(
            enabled: true, lastRecordedAt: nil, now: Date(), makeSnapshot: { idle },
            pendingTempBytes: { scannedDisk = true; return 0 })
        #expect(collected == nil && !scannedDisk)
    }

    @Test("A row waiting for admission says so, whatever its phase would say (pu-33)")
    func waitingRowsReadAsWaiting() {
        let intents: [DownloadAdmissionIntent?] = [nil, .seasonPlanned, .retryRequested]
        for lifecycle in [DownloadLifecycle?.none] + DownloadLifecycle.allCases.map(Optional.some) {
            for intent in intents {
                for queuePaused in [false, true] {
                    for exempt in [false, true] {
                        let caption = DownloadRowStatusCaptionPolicy.admissionWaitingCaption(
                            lifecycle: lifecycle, intent: intent, isQueuePaused: queuePaused, isExempt: exempt)
                        let waiting = lifecycle == .planned
                            || ((lifecycle == .paused || lifecycle == .failed) && intent == .retryRequested)
                        #expect((caption != nil) == waiting, "\(String(describing: lifecycle)) \(String(describing: intent))")
                        if let caption {
                            #expect(caption == (queuePaused && !exempt
                                ? DownloadRowStatusCaptionPolicy.queuePausedWaitingCaption
                                : DownloadRowStatusCaptionPolicy.slotWaitingCaption))
                        }
                    }
                }
            }
        }
    }

    // MARK: - The smaller progress policies

    @Test("Static-range task health and background progress policies hold their gates for random input")
    func smallProgressPoliciesHoldTheirGates() {
        for seed in UInt64(8_001)...8_040 {
            var rng = Seeded(seed)
            let policy = StaticRangeTaskHealthPolicy()
            for _ in 0..<400 {
                let active = rng.real(0...200)
                let sample = rng.real(0...120)
                let baseline = rng.int(-10...400_000_000)
                let current = baseline + rng.int(-1_000...40_000_000)
                let length = rng.int(0...2_000_000_000)
                let context = rng.chance(0.5) ? "background_wake" : "foreground"
                let used = rng.chance(0.2)
                let decision = policy.decide(
                    activeSeconds: active, sampleSeconds: sample, baselineBytes: baseline,
                    currentBytes: current, rangeLength: length, creationContext: context, recoveryUsed: used)
                if decision == .reissue {
                    // A task is discarded only for a measured, slow, far-from-done, background-created
                    // transfer that has not been recovered before and is small enough to refetch.
                    #expect(active >= policy.settleSeconds + policy.windowSeconds && sample >= policy.windowSeconds)
                    #expect(baseline >= 0 && current >= baseline && !used)
                    #expect(Double(current - baseline) / sample < policy.maximumRate)
                    #expect(current < length && policy.canDiscard(current) && context == "background_wake")
                }
                if current < baseline, active >= policy.settleSeconds + policy.windowSeconds,
                   sample >= policy.windowSeconds {
                    #expect(decision == .counterReset, "seed \(seed): a counter that went backwards was measured")
                }

                let downloaded = rng.int(0...1_000_000_000)
                let progress = rng.real(0...1.5)
                if let expected = BackgroundDownloadProgressPolicy.derivedExpectedBytes(
                    downloadedBytes: downloaded, progress: progress) {
                    #expect(expected >= downloaded && downloaded > 0 && progress > 0.0001)
                }
                let last: Date? = rng.chance(0.3) ? nil : Self.time(rng.real(0...100))
                let now = Self.time(rng.real(0...100))
                let notify = BackgroundDownloadProgressPolicy.shouldNotifyProgressChange(
                    lastNotification: last, now: now, progress: progress, interval: 0.5)
                if progress >= 1 || last == nil { #expect(notify, "seed \(seed): completion was throttled") }
                #expect(BackgroundDownloadProgressPolicy.shouldRecordRangeProgress(
                    last: nil, now: now, totalBytes: downloaded, byteInterval: 1_000, isFirstCallback: false))
                #expect(BackgroundDownloadProgressPolicy.shouldRecordRangeProgress(
                    last: .init(time: now, bytes: downloaded), now: now, totalBytes: downloaded,
                    byteInterval: 1_000, isFirstCallback: true))
            }
        }
    }

    // MARK: - Findings

    /// S1 (`status/Finding-S1-SilentMemberHidesSpeed.cfg`). Two transfers share the batch. One
    /// stalls silently: no bytes, so no callbacks, and nothing takes a static-range row out of
    /// `transferring` (only forward-only streams have a stall verdict). The other keeps moving.
    /// The estimator hides the whole total while any member is silent, so the top of Downloads
    /// reads "Updating speed…" for as long as the stall lasts.
    ///
    /// `DownloadAggregateRateEstimatorTests.silentMember` pins the first seconds of this on
    /// purpose: a silent member may be about to deliver catch-up bytes. The finding is that the
    /// hidden state has no end. Wanted: in a process that stayed awake, a number returns for the
    /// rows that move (the silent one counting as zero, or leaving the batch).
    @Test("S1: a silently stalled transfer does not hide the batch speed for ever")
    func silentTransferDoesNotHideBatchSpeedForever() {
        let moving = Self.key(0)
        let silent = Self.key(1)
        var estimator = DownloadAggregateRateEstimator()
        estimator.setActiveTransfers([moving, silent])
        var answers: [Double] = []
        for second in 0...180 {
            estimator.sample(moving, bytes: second * 1_000_000, at: Self.time(Double(second)))
            // The second transfer moves for ten seconds, then goes silent without an error.
            if second <= 10 { estimator.sample(silent, bytes: second * 500_000, at: Self.time(Double(second))) }
            if second >= 60, let rate = estimator.rate(at: Self.time(Double(second))) { answers.append(rate) }
        }
        // What the screen says meanwhile.
        let record = DownloadRecord(ratingKey: "row-0", title: "Fixture",
                                    localURL: URL(fileURLWithPath: "/tmp/fixture.mp4"),
                                    bytes: 1, status: .downloading, lifecycle: .transferring)
        let stats = OfflineDownloadAggregateStats.make(
            records: [record], activeSpeedBytesPerSecond: estimator.rate(at: Self.time(180)))

        withKnownIssue("TLA+ finding S1 (#487): a silent transfer hides the batch speed for as long as it is silent") {
            #expect(!answers.isEmpty, "no speed in two minutes although one transfer moved 1 MB/s throughout")
            #expect(!stats.isUpdatingSpeed, "the screen still says \"Updating speed…\" 170 s into the stall")
        }
    }

    /// What `refreshRecords` and the watchdog loop leave on screen for one static-range row whose
    /// callbacks are `callbacks` and then stop. The refresh sources are the two the app has: the
    /// one-shot a callback schedules, and the watchdog loop, which `updateDownloadWatchdog` runs
    /// only for forward-only or preparing rows or while the aggregate has an answer.
    private struct StallOutcome {
        var rowSpeed: Double?
        var topAnswer: Double?
        var topAnswerAtLastCallback: Double?
        var lastRefresh = 0.0
    }

    private static func staticRowAfterStall(callbacks: [(time: Double, bytes: Int)],
                                            rng: inout Seeded) -> StallOutcome {
        let ratingKey = "jellyfin:item-1"
        let record = DownloadRecord(
            ratingKey: ratingKey, attemptID: .init(rawValue: "attempt-1"), title: "Fixture",
            localURL: URL(fileURLWithPath: "/tmp/fixture.mp4"), bytes: 0, status: .downloading,
            metadata: OfflineMetadata(ratingKey: ratingKey, title: "Fixture", type: "movie",
                                      backendKind: .jellyfin, downloadLane: .original,
                                      resumeMode: .staticByteRange),
            lifecycle: .transferring)
        let transfer = DownloadAttemptKey(ratingKey: ratingKey, attemptID: .init(rawValue: "attempt-1")!)

        var aggregate = DownloadAggregateRateEstimator()
        var row = DownloadRateEstimator(rebaselineSuppressWindow: 4.0)
        var outcome = StallOutcome()
        var liveBytes = 0
        var pending = callbacks[...]
        let horizon = (callbacks.last?.time ?? 0) + 120
        // The snapshot publication that makes the row a member of the batch.
        var scheduled: Double? = 0
        var tick: Double?

        while let now = [pending.first?.time, scheduled, tick].compactMap({ $0 }).min(), now <= horizon {
            if let callback = pending.first, callback.time == now {
                pending.removeFirst()
                liveBytes = callback.bytes
                aggregate.sample(transfer, bytes: liveBytes, at: time(now))
                if pending.isEmpty { outcome.topAnswerAtLastCallback = aggregate.rate(at: time(now)) }
                // scheduleRefreshRecords(reason: "range_live_progress", delay: .seconds(1))
                if scheduled == nil { scheduled = now + 1 }
                continue
            }
            let fromLoop = tick == now
            if scheduled == now { scheduled = nil }
            // refreshRecords: sample the row, publish, then decide whether the loop goes on.
            outcome.lastRefresh = now
            aggregate.setActiveTransfers([transfer])
            let sampled = row.sample(bytes: liveBytes, at: time(now))
            outcome.rowSpeed = (sampled ?? 0) > 0 ? sampled : nil
            outcome.topAnswer = aggregate.rate(at: time(now))
            // updateDownloadWatchdog. One second of sleep plus what a refresh costs on a busy
            // main thread; 15 s when only the row predicates keep the loop alive.
            if DownloadWatchdogPolicy.requiresWatchdog(records: [record]) || outcome.topAnswer != nil {
                if tick == nil || fromLoop {
                    tick = now + (outcome.topAnswer != nil
                        ? 1 + rng.real(0...0.4) : DownloadWatchdogPolicy.refreshIntervalSeconds)
                }
            } else {
                tick = nil
            }
        }
        return outcome
    }

    /// S2 (`status/Finding-S2-StaleRowSpeed.cfg`). A row's speed is recomputed only inside
    /// `refreshRecords`. After a static-range row's last callback the only refreshes left are
    /// the watchdog loop's, and that loop stops at the first refresh that finds the aggregate
    /// without an answer. The aggregate loses its answer 3.5 s after the last callback (its 4 s
    /// window less the 0.5 s minimum); the row's own window needs about 4 s of quiet refreshes
    /// to empty. So the last refresh leaves a decayed, non-zero speed, and its ETA, on the row,
    /// and nothing samples it again until some other event refreshes the screen. When the
    /// aggregate is hidden already (settling after a start, a wake or a new batch member, or
    /// hidden by S1) there is no loop at all and the row keeps its full last speed.
    ///
    /// The loop rule is app code, so the harness mirrors it and the first expectation checks the
    /// mirror against the source. Wanted: a stalled row's speed is removed.
    @Test("S2: a stalled static-range row stops showing a speed")
    func stalledStaticRowStopsShowingSpeed() throws {
        let watchdog = try #require(Self.appFunctionSource(
            named: "updateDownloadWatchdog",
            in: "Labstream/Capabilities/Downloads/Core/DownloadManager.swift"))
        #expect(watchdog.contains("DownloadWatchdogPolicy.requiresWatchdog(records: records)")
            && watchdog.contains("aggregateRateEstimator.rate(at: Date()) != nil"),
                "updateDownloadWatchdog changed: re-derive the loop rule in staticRowAfterStall from it")

        // 1. Steady state: the top shows a number when the network drops.
        var steady: [(seed: UInt64, outcome: StallOutcome)] = []
        for seed in UInt64(4_001)...4_100 {
            var rng = Seeded(seed)
            let rate = rng.real(100_000...6_000_000)
            let stallAt = rng.real(8...30)
            var callbacks: [(time: Double, bytes: Int)] = []
            var at = rng.real(0.05...0.3)
            while at < stallAt {
                callbacks.append((at, Int(rate * at)))
                at += rng.real(0.05...0.4)
            }
            steady.append((seed, Self.staticRowAfterStall(callbacks: callbacks, rng: &rng)))
        }
        // The harness is in the state the finding is about: a number on top at the stall, and
        // "Updating speed…" once the loop has stopped.
        #expect(steady.allSatisfy { $0.outcome.topAnswerAtLastCallback != nil && $0.outcome.topAnswer == nil })

        // 2. The stall comes while the aggregate is still settling: no loop ever runs.
        var rng = Seeded(4_999)
        let early = Self.staticRowAfterStall(
            callbacks: stride(from: 0.25, through: 3.0, by: 0.25).map { ($0, Int($0 * 2_000_000)) }, rng: &rng)
        #expect(early.topAnswerAtLastCallback == nil && early.topAnswer == nil)

        let stale = steady.filter { $0.outcome.rowSpeed != nil }
        withKnownIssue("TLA+ finding S2 (#488): the refresh loop stops before a stalled row's speed has decayed") {
            #expect(stale.isEmpty, """
                \(stale.count) of \(steady.count) steady-state stalls leave a speed on the row; seed \
                \(stale.first?.seed ?? 0) shows \(Int(stale.first?.outcome.rowSpeed ?? 0)) B/s after its last \
                refresh at t=\(stale.first?.outcome.lastRefresh ?? 0) s
                """)
            #expect(early.rowSpeed == nil,
                    "the row still shows \(Int(early.rowSpeed ?? 0)) B/s; its last refresh was at t=\(early.lastRefresh) s")
        }
    }

    /// The text of one function in an app source file, from its declaration to the next
    /// declaration at the same indentation. Nil when the file or the function is missing.
    private static func appFunctionSource(named name: String, in relativePath: String) -> String? {
        // PMSKit/Tests/PMSKitTests/<this file> -> repository root.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        guard let source = try? String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8),
              let start = source.range(of: "    private func \(name)(") else { return nil }
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n    private func ")?.lowerBound ?? rest.endIndex
        return String(source[start.lowerBound..<end])
    }
}
