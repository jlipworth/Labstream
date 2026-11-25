import Testing
@testable import PMSKit

/// The PMSKit facts that the TLA+ wake models rest on (`specs/downloads/wake/DownloadsWake.tla`,
/// `specs/downloads/wake/DownloadsWakeLaunchGate.tla`, notes in `specs/downloads/wake/README.md`).
///
/// The models treat the completion-handler store and the launch recovery gate as given. These
/// tests check the real types against the same statements, over every short call order, so a
/// change to either type that breaks a model assumption fails here.
///
/// The two open findings of the wake model (W1, W2) are in app code (the completion registry and
/// the wake coordinator), which PMSKit cannot reach. They have `wake/Finding-*.cfg` configs and
/// need `LabstreamTests` pins; none is possible in this file.
@Suite("Downloads formal-model wake assumptions")
struct DownloadsFormalModelWakeTests {
    private typealias Store = BackgroundDownloadCompletionHandlerStore
    private typealias Batch = BackgroundDownloadCompletionReleaseBatch
    private static let identifier = "session"

    private final class Calls {
        var counts: [Int: Int] = [:]
    }

    private enum StoreStep: CaseIterable {
        /// The OS supplies a handler.
        case append
        /// A finish-events transition claims the tokens pending right now.
        case claim
        /// A claimed batch is released (possibly again, possibly late).
        case drainOldest
        case drainNewest
    }

    /// `CalledOnlyAfterClaim` and "exactly once": over every order of supply, claim and release,
    /// a handler runs only when a batch that claimed its token is drained, and never twice. The
    /// model's `wake/Mutant-DrainByIdentifier.cfg` shows what breaks when a drain takes every
    /// handler for the identifier instead.
    @Test("Store: a drain calls exactly the handlers its batch claimed, once")
    func drainCallsExactlyTheClaimedHandlersOnce() {
        var orders = 0
        func run(_ steps: [StoreStep]) {
            var store = Store()
            let calls = Calls()
            var supplied = 0
            var index: [BackgroundDownloadCompletionHandlerToken: Int] = [:]
            var batches: [Batch] = []
            var claimed: Set<Int> = []
            var drained: Set<Int> = []
            for step in steps {
                switch step {
                case .append:
                    let id = supplied
                    supplied += 1
                    let token = store.append(identifier: Self.identifier) {
                        calls.counts[id, default: 0] += 1
                    }
                    index[token] = id
                case .claim:
                    let tokens = store.pendingTokens(for: Self.identifier)
                    batches.append(Batch(identifier: Self.identifier, tokens: tokens))
                    claimed.formUnion(tokens.compactMap { index[$0] })
                case .drainOldest, .drainNewest:
                    guard let batch = step == .drainOldest ? batches.first : batches.last else {
                        continue
                    }
                    store.drain(batch: batch).forEach { $0() }
                    drained.formUnion(batch.tokens.compactMap { index[$0] })
                }
                for id in 0..<supplied {
                    let count = calls.counts[id, default: 0]
                    #expect(count == (drained.contains(id) ? 1 : 0),
                            "handler \(id) ran \(count) times after \(steps)")
                    #expect(count == 0 || claimed.contains(id))
                }
                #expect(store.totalCount == supplied - drained.count)
            }
            orders += 1
        }
        func extend(_ prefix: [StoreStep], depth: Int) {
            run(prefix)
            guard depth > 0 else { return }
            for step in StoreStep.allCases { extend(prefix + [step], depth: depth - 1) }
        }
        extend([], depth: 6)
        #expect(orders > 5_000)
    }

    /// The registry computes a new receipt's deadline from the receipts it still holds, and the
    /// store keeps a claimed token until its batch is drained. This is the store half of finding
    /// W1: between a claim and its MainActor release the claimed handler is still pending.
    @Test("Store: a claimed token stays pending until its batch is drained")
    func claimedTokenStaysPendingUntilDrained() {
        var store = Store()
        let first = store.append(identifier: Self.identifier) {}
        let batch = Batch(identifier: Self.identifier, tokens: store.pendingTokens(for: Self.identifier))
        let second = store.append(identifier: Self.identifier) {}
        #expect(store.pendingTokens(for: Self.identifier) == [first, second])
        #expect(store.drain(batch: batch).count == 1)
        #expect(store.pendingTokens(for: Self.identifier) == [second])
        #expect(store.drain(batch: batch).isEmpty)
    }

    private enum GateStep: CaseIterable {
        case passReturns
        case browseReady
        case browseLost
        case rerunReturns
    }

    /// `wake/WakeLaunchGate-Current-Gate.cfg`: for every order of the launch pass returning, browse
    /// readiness changing and the rerun returning, the gate reruns at most once, never while a
    /// pass is running, never after a launch that began with browse ready, and (B77) always once
    /// the launch pass is over and browse is ready after an offline launch.
    @Test("Launch gate: every call order keeps the model's invariants", arguments: [false, true])
    func launchGateKeepsItsInvariants(readyAtLaunch: Bool) {
        var orders = 0
        func run(_ steps: [GateStep]) {
            var gate = LaunchDownloadRecoveryGate()
            var ready = readyAtLaunch
            var launchPassRunning = true
            var rerunsRunning = 0
            var rerunCount = 0
            var sawReady = readyAtLaunch
            gate.beginLaunchPass(browseReady: ready)
            for step in steps {
                var rerun = false
                switch step {
                case .passReturns:
                    guard launchPassRunning else { continue }
                    launchPassRunning = false
                    rerun = gate.finishLaunchPass(browseReady: ready)
                case .browseReady:
                    guard !ready else { continue }
                    ready = true
                    rerun = gate.browseBecameReady()
                case .browseLost:
                    ready = false
                case .rerunReturns:
                    rerunsRunning = max(0, rerunsRunning - 1)
                }
                if rerun {
                    #expect(ready, "a rerun was requested while browse was not ready: \(steps)")
                    rerunsRunning += 1
                    rerunCount += 1
                    sawReady = true
                }
                #expect((launchPassRunning ? 1 : 0) + rerunsRunning <= 1, "passes overlap: \(steps)")
                #expect(rerunCount <= 1, "the pass was rerun twice: \(steps)")
                #expect(!readyAtLaunch || rerunCount == 0, "a normal launch reran: \(steps)")
                #expect(launchPassRunning || !ready || sawReady,
                        "browse is ready and no pass has seen it: \(steps)")
            }
            orders += 1
        }
        func extend(_ prefix: [GateStep], depth: Int) {
            run(prefix)
            guard depth > 0 else { return }
            for step in GateStep.allCases { extend(prefix + [step], depth: depth - 1) }
        }
        extend([], depth: 7)
        #expect(orders > 20_000)
    }
}
