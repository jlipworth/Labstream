import Testing
@testable import PMSKit

/// B60 / IC-4: a keepalive must stop for a row whose exact attempt has no live transfer.
@Suite("Download keepalive transfer gate")
struct DownloadKeepaliveTransferGateTests {
    @Test("A tracked transfer always sends and resets the untracked streak")
    func trackedTransferSends() {
        var gate = DownloadKeepaliveTransferGate()
        #expect(gate.evaluate(isTrackingTransfer: true) == .send)
        #expect(gate.evaluate(isTrackingTransfer: false) == .skip)
        #expect(gate.evaluate(isTrackingTransfer: true) == .send)
        #expect(gate.consecutiveUntrackedTicks == 0)
    }

    @Test("One untracked tick is tolerated without sending; a second consecutive one stops")
    func untrackedRowStops() {
        var gate = DownloadKeepaliveTransferGate()
        // The first tick can race session.start or a stall-restart handoff: skip, do not send.
        #expect(gate.evaluate(isTrackingTransfer: false) == .skip)
        #expect(gate.evaluate(isTrackingTransfer: false) == .stop)
    }

    @Test("A row that never gains a transfer sends nothing before stopping")
    func neverTrackedSendsNothing() {
        var gate = DownloadKeepaliveTransferGate()
        var sent = 0
        for _ in 0..<10 {
            let action = gate.evaluate(isTrackingTransfer: false)
            if action == .send { sent += 1 }
            if action == .stop { break }
        }
        #expect(sent == 0)
    }

    @Test("The ensure gate starts a keepalive only for a tracked transfer")
    func ensureGate() {
        #expect(DownloadKeepaliveTransferGate.shouldStart(isTrackingTransfer: true))
        #expect(!DownloadKeepaliveTransferGate.shouldStart(isTrackingTransfer: false))
    }
}
