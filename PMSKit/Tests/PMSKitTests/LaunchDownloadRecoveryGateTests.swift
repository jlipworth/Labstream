import Testing
@testable import PMSKit

/// B77: the launch-only download recovery pass (inactive-backend hydration plus the orphaned
/// encoder sweep) must run again once a reconnect makes browse ready after an offline launch,
/// and must not run twice on a normal launch.
@Suite("Launch download recovery gate")
struct LaunchDownloadRecoveryGateTests {
    @Test("Normal launch: browse ready before the pass runs it exactly once")
    func normalLaunchRunsOnce() {
        var gate = LaunchDownloadRecoveryGate()
        // restoreSession flips browse ready before the launch pass starts.
        let r1 = gate.browseBecameReady()
        #expect(!r1)
        gate.beginLaunchPass(browseReady: true)
        let r2 = gate.finishLaunchPass(browseReady: true)
        #expect(!r2)
        // Later ready edges (sign-out then sign-in) do not repeat the launch pass.
        let r3 = gate.browseBecameReady()
        #expect(!r3)
    }

    @Test("Offline launch: the first reconnect reruns the pass once")
    func offlineLaunchReconnectRerunsOnce() {
        var gate = LaunchDownloadRecoveryGate()
        gate.beginLaunchPass(browseReady: false)
        let r4 = gate.finishLaunchPass(browseReady: false)
        #expect(!r4)
        let r5 = gate.browseBecameReady()
        #expect(r5)
        let r6 = gate.browseBecameReady()
        #expect(!r6)
    }

    @Test("Reconnect during an offline pass reruns when the pass finishes")
    func reconnectDuringOfflinePassRerunsAtFinish() {
        var gate = LaunchDownloadRecoveryGate()
        gate.beginLaunchPass(browseReady: false)
        // The pass is still awaiting hydration, so the edge must not start a concurrent rerun.
        let r7 = gate.browseBecameReady()
        #expect(!r7)
        let r8 = gate.finishLaunchPass(browseReady: true)
        #expect(r8)
        let r9 = gate.browseBecameReady()
        #expect(!r9)
    }

    @Test("A pass that started browse-ready never reruns")
    func readyPassNeverReruns() {
        var gate = LaunchDownloadRecoveryGate()
        gate.beginLaunchPass(browseReady: true)
        let r10 = gate.browseBecameReady()
        #expect(!r10)
        let r11 = gate.finishLaunchPass(browseReady: false)
        #expect(!r11)
        let r12 = gate.browseBecameReady()
        #expect(!r12)
    }
}
