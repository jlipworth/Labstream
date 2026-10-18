import Testing
@testable import PMSKit

@Suite("Download admission policy (P4)")
struct DownloadAdmissionPolicyTests {
    private typealias P = DownloadAdmissionPolicy
    private let limits = DownloadAdmissionLimits(maximumTotal: 3)

    private func request(_ id: String, _ lane: DownloadAdmissionLane,
                         _ origin: DownloadAdmissionOrigin = .automatic,
                         at time: Double = 0, eligibleAt: Double? = nil) -> DownloadAdmissionRequest {
        DownloadAdmissionRequest(id: id, lane: lane, origin: origin, requestedAt: time,
                                 eligibleAt: eligibleAt)
    }

    @Test(arguments: DownloadAdmissionLimits.supportedTotals)
    func configuredTotalsDeriveAndEnforceEveryLane(total: Int) {
        let limits = DownloadAdmissionLimits(maximumTotal: total)
        #expect(limits.maximumTotal == total)
        #expect(limits.maximumByLane[.staticFile] == max(1, total - 1))
        #expect(limits.maximumByLane[.serverPreparation] == DownloadAdmissionLimits.maximumServerPreparations)
        #expect(limits.maximumByLane[.liveForward] == 1)
        let requests = (1...6).map { request("s\($0)", .staticFile) }
            + (1...6).map { request("p\($0)", .serverPreparation) }
            + (1...2).map { request("l\($0)", .liveForward) }
        let granted = P.grants(limits: limits, occupants: [], requests: requests,
                               now: 1, queuePaused: false)
        // #414: server jobs never use a transfer slot.
        #expect(granted.filter { $0.lane != .serverPreparation }.count == total)
        #expect(granted.filter { $0.lane == .serverPreparation }.count
            == DownloadAdmissionLimits.maximumServerPreparations)
        for lane in DownloadAdmissionLane.allCases {
            let laneRequests = requests.filter { $0.lane == lane }
            let laneGrants = P.grants(limits: limits, occupants: [], requests: laneRequests,
                                     now: 1, queuePaused: false)
            #expect(laneGrants.count == limits.maximumByLane[lane])
            let fullLane = laneGrants.map { DownloadAdmissionOccupant(id: $0.id, lane: $0.lane) }
            #expect(!P.mayEnter(lane, id: "new", occupants: fullLane, limits: limits))
        }
        let full = granted.map { DownloadAdmissionOccupant(id: $0.id, lane: $0.lane) }
        for lane in DownloadAdmissionLane.allCases {
            #expect(!P.mayEnter(lane, id: "new", occupants: full, limits: limits))
        }
    }

    @Test func limitsClampInvalidTotals() {
        #expect(DownloadAdmissionLimits(maximumTotal: 0).maximumTotal == 1)
        #expect(DownloadAdmissionLimits(maximumTotal: 6).maximumTotal == 5)
    }

    @Test func grantsAreBoundedPerLaneAndInTotal() {
        let requests = [
            request("prep-1", .serverPreparation, at: 1),
            request("prep-2", .serverPreparation, at: 2),
            request("static-1", .staticFile, at: 3),
            request("live-1", .liveForward, at: 4),
            request("static-2", .staticFile, at: 5),
            request("static-3", .staticFile, at: 6),
        ]
        let granted = P.grants(limits: limits, occupants: [], requests: requests, now: 10, queuePaused: false)
        #expect(granted.map(\.id) == ["prep-1", "prep-2", "static-1", "live-1", "static-2"])
    }

    /// #414: three transcoded downloads queued together all reach the server at once, even while
    /// every transfer slot is busy, so they render while the app is suspended.
    @Test func serverJobsAreSubmittedTogetherWhileTransfersAreFull() {
        let occupants = [DownloadAdmissionOccupant(id: "s1", lane: .staticFile),
                         .init(id: "s2", lane: .staticFile),
                         .init(id: "l1", lane: .liveForward)]
        let requests = (1...3).map { request("p\($0)", .serverPreparation, at: Double($0)) }
            + [request("s3", .staticFile, at: 9)]
        let granted = P.grants(limits: limits, occupants: occupants, requests: requests,
                               now: 10, queuePaused: false)
        #expect(granted.map(\.id) == ["p1", "p2", "p3"])
        // The fixed prep bound still holds.
        let fullPrep = (1...DownloadAdmissionLimits.maximumServerPreparations)
            .map { DownloadAdmissionOccupant(id: "p\($0)", lane: .serverPreparation) }
        #expect(P.grants(limits: limits, occupants: fullPrep,
                         requests: [request("p9", .serverPreparation), request("s1", .staticFile)],
                         now: 1, queuePaused: false).map(\.id) == ["s1"])
    }

    /// #414: a finished render takes a static and a transfer slot only when one is free; prep
    /// occupants (its own included) never block it.
    @Test func renderHandOffNeedsAStaticSlot() {
        let prep = (1...4).map { DownloadAdmissionOccupant(id: "p\($0)", lane: .serverPreparation) }
        #expect(P.mayHandOffToStatic(id: "p1", occupants: prep, limits: limits))
        let staticFull = prep + [.init(id: "s1", lane: .staticFile), .init(id: "s2", lane: .staticFile)]
        #expect(!P.mayHandOffToStatic(id: "p1", occupants: staticFull, limits: limits))
        let totalFull = prep + [.init(id: "s1", lane: .staticFile), .init(id: "l1", lane: .liveForward),
                                .init(id: "l2", lane: .liveForward)]
        #expect(!P.mayHandOffToStatic(id: "p1", occupants: totalFull, limits: limits))
        let oneFree = prep + [.init(id: "s1", lane: .staticFile), .init(id: "l1", lane: .liveForward)]
        #expect(P.mayHandOffToStatic(id: "p1", occupants: oneFree, limits: limits))
    }

    /// B63: five parked rows resumed together start no more than the caps allow.
    @Test func resumeAllOfFiveRowsGrantsOnlyTheCaps() {
        let requests = (1...5).map { request("s\($0)", .staticFile, at: Double($0)) }
        let granted = P.grants(limits: limits, occupants: [], requests: requests, now: 10, queuePaused: false)
        #expect(granted.map(\.id) == ["s1", "s2"])
    }

    /// B72: a reservation (a start in flight whose row is not active yet) counts like active work.
    @Test func reservationsCountAgainstTheCaps() {
        let occupants = [DownloadAdmissionOccupant(id: "s1", lane: .staticFile),
                         .init(id: "s2", lane: .staticFile)]
        let granted = P.grants(limits: limits, occupants: occupants,
                               requests: [request("s3", .staticFile)], now: 1, queuePaused: false)
        #expect(granted.isEmpty)
    }

    @Test func aFullLaneDoesNotBlockOtherLanes() {
        let occupants = [DownloadAdmissionOccupant(id: "l1", lane: .liveForward)]
        let granted = P.grants(limits: limits,
            occupants: occupants,
            requests: [request("l2", .liveForward, at: 1), request("s1", .staticFile, at: 2)],
            now: 5, queuePaused: false)
        #expect(granted.map(\.id) == ["s1"])
    }

    @Test func userRequestsGoFirstButNeverLiftACap() {
        let requests = [
            request("auto-old", .staticFile, .automatic, at: 1),
            request("user-new", .staticFile, .user, at: 9),
            request("auto-mid", .staticFile, .automatic, at: 5),
        ]
        let granted = P.grants(limits: limits, occupants: [], requests: requests, now: 10, queuePaused: false)
        #expect(granted.map(\.id) == ["user-new", "auto-old"])
    }

    /// Relaunch: work the OS still owned is grandfathered over the cap; nothing new is granted
    /// in that lane until it is back under, and the total cap holds.
    @Test func grandfatheredOccupancyOverTheCapGrantsNothingNewInThatLane() {
        let occupants = [DownloadAdmissionOccupant(id: "s1", lane: .staticFile),
                         .init(id: "s2", lane: .staticFile),
                         .init(id: "s3", lane: .staticFile)]
        let granted = P.grants(limits: limits,
            occupants: occupants,
            requests: [request("s4", .staticFile), request("l1", .liveForward)],
            now: 1, queuePaused: false)
        #expect(granted.isEmpty)
    }

    @Test func queuePauseGrantsOnlyExemptRows() {
        let requests = [request("a", .staticFile, at: 1), request("b", .staticFile, .user, at: 2)]
        #expect(P.grants(limits: limits, occupants: [], requests: requests, now: 5, queuePaused: true).isEmpty)
        #expect(P.grants(limits: limits, occupants: [], requests: requests, now: 5, queuePaused: true,
                         pauseExemptIDs: ["b"]).map(\.id) == ["b"])
    }

    @Test func backoffDefersARequestUntilItIsEligible() {
        let waiting = request("s1", .staticFile, at: 0, eligibleAt: 15)
        #expect(P.grants(limits: limits, occupants: [], requests: [waiting], now: 14, queuePaused: false).isEmpty)
        #expect(P.grants(limits: limits, occupants: [], requests: [waiting], now: 15, queuePaused: false)
            .map(\.id) == ["s1"])
        #expect(P.nextEligibleTime(requests: [waiting], now: 14) == 15)
        #expect(P.nextEligibleTime(requests: [waiting], now: 15) == nil)
        #expect(P.deferralDelay(afterAttempt: 0) == 1)
        #expect(P.deferralDelay(afterAttempt: 3) == 30)
        #expect(P.deferralDelay(afterAttempt: 99) == 60)
    }

    @Test func aRowAlreadyOccupyingIsNeverGrantedAgain() {
        let occupants = [DownloadAdmissionOccupant(id: "s1", lane: .staticFile)]
        #expect(P.grants(limits: limits, occupants: occupants, requests: [request("s1", .staticFile)],
                         now: 1, queuePaused: false).isEmpty)
    }

    /// P4.5: a row rerouted into server prep may enter only a lane with room; its own occupancy
    /// does not count against it.
    @Test func mayEnterExcludesTheRowItself() {
        let occupants = [DownloadAdmissionOccupant(id: "row", lane: .staticFile),
                         .init(id: "other", lane: .liveForward)]
        #expect(!P.mayEnter(.liveForward, id: "row", occupants: occupants, limits: limits))
        #expect(P.mayEnter(.serverPreparation, id: "row", occupants: occupants, limits: limits))
        let busy = [DownloadAdmissionOccupant(id: "row", lane: .staticFile),
                    .init(id: "other", lane: .serverPreparation)]
        #expect(P.mayEnter(.liveForward, id: "row", occupants: busy, limits: limits))
        // The row already counts toward the total, so moving it does not change the total; only
        // three other transfer occupants close every transfer lane (#414: prep never counts).
        let busier = busy + [DownloadAdmissionOccupant(id: "third", lane: .staticFile),
                             .init(id: "fourth", lane: .staticFile)]
        #expect(P.mayEnter(.liveForward, id: "row", occupants: busier, limits: limits))
        let full = busier + [DownloadAdmissionOccupant(id: "fifth", lane: .staticFile)]
        #expect(!P.mayEnter(.liveForward, id: "row", occupants: full, limits: limits))
        #expect(P.mayEnter(.serverPreparation, id: "row", occupants: full, limits: limits))
    }

    /// pu-33: waiting rows say why they wait; started or plainly parked rows do not.
    @Test func waitingRowsReadAsWaiting() {
        let C = DownloadRowStatusCaptionPolicy.self
        #expect(C.admissionWaitingCaption(lifecycle: .planned, intent: .seasonPlanned,
                                          isQueuePaused: false, isExempt: false)
            == "Waiting for a download slot…")
        #expect(C.admissionWaitingCaption(lifecycle: .paused, intent: .retryRequested,
                                          isQueuePaused: true, isExempt: false)
            == "Waiting — downloads paused")
        #expect(C.admissionWaitingCaption(lifecycle: .paused, intent: .retryRequested,
                                          isQueuePaused: true, isExempt: true)
            == "Waiting for a download slot…")
        #expect(C.admissionWaitingCaption(lifecycle: .paused, intent: .seasonPlanned,
                                          isQueuePaused: false, isExempt: false) == nil)
        #expect(C.admissionWaitingCaption(lifecycle: .failed, intent: nil,
                                          isQueuePaused: false, isExempt: false) == nil)
        #expect(C.admissionWaitingCaption(lifecycle: .transferring, intent: nil,
                                          isQueuePaused: false, isExempt: false) == nil)
    }

    @Test func backendLanesPreserveExistingTransferBehavior() {
        #expect(P.lane(backend: .plex, downloadLane: .optimize) == .serverPreparation)
        #expect(P.lane(backend: .emby, downloadLane: .optimize) == .serverPreparation)
        #expect(P.lane(backend: .jellyfin, downloadLane: .optimize) == .liveForward)
        for backend in [DownloadBackendKind.plex, .jellyfin, .emby] {
            #expect(P.lane(backend: backend, downloadLane: .original) == .staticFile)
            #expect(P.lane(backend: backend, downloadLane: .compatibleRemux) == .liveForward)
        }
    }
}
