import Testing
@testable import Labstream

/// Presentation timing for the transport status: show delay, minimum-visible hold, staged
/// spinner → card escalation, and immediate reconnect/failure preemption. Driven by a manual
/// scheduler so every timer fires deterministically on the test's main actor.
@Suite("Transport status presentation timing")
@MainActor
struct PlaybackTransportStatusStateTests {
    /// Distinct durations so each manual `fire` targets exactly one kind of timer.
    private let timing = ManualTransportStatusScheduler.timing

    @Test("Standard timing uses the approved thresholds")
    func standardTiming() {
        let standard = PlaybackTransportStatusState.Timing.standard
        #expect(standard.showDelay == .milliseconds(600))
        #expect(standard.minimumVisible == .milliseconds(600))
        #expect(standard.escalation == .milliseconds(3_500))
    }

    @Test("A wait shorter than the show delay never publishes anything")
    func showDelaySuppressesShortWait() {
        let clock = ManualTransportStatusScheduler()
        let state = clock.makeState()

        state.set(.buffering)
        #expect(state.status == .none)
        #expect(clock.pendingDelays.contains(timing.showDelay))

        state.set(.none)
        #expect(state.status == .none)
        clock.fireAll()
        #expect(state.status == .none)
        #expect(clock.pendingDelays.isEmpty)
    }

    @Test("A sustained wait shows the spinner after the show delay")
    func sustainedWaitShowsSpinner() {
        let clock = ManualTransportStatusScheduler()
        let state = clock.makeState()

        state.set(.buffering)
        state.set(.buffering) // repeated controller callbacks do not restart the delay
        #expect(clock.pendingDelays.filter { $0 == timing.showDelay }.count == 1)
        clock.fire(timing.showDelay)
        #expect(state.status == .buffering)
        #expect(state.stage == .spinner)
    }

    @Test("Once shown, a wait stays visible for the minimum duration")
    func minimumVisibleHolds() {
        let clock = ManualTransportStatusScheduler()
        let state = clock.makeState()

        state.set(.buffering)
        clock.fire(timing.showDelay)
        state.set(.none)
        #expect(state.status == .buffering, "a clear inside the hold must not flicker the spinner off")

        // Chatter back to waiting inside the hold continues the same presentation.
        state.set(.buffering)
        state.set(.none)
        #expect(state.status == .buffering)

        clock.fire(timing.minimumVisible)
        #expect(state.status == .none)
    }

    @Test("A clear after the minimum duration hides immediately")
    func clearAfterMinimumVisible() {
        let clock = ManualTransportStatusScheduler()
        let state = clock.makeState()

        state.set(.buffering)
        clock.fire(timing.showDelay)
        clock.fire(timing.minimumVisible)
        #expect(state.status == .buffering)
        state.set(.none)
        #expect(state.status == .none)
        #expect(clock.pendingDelays.isEmpty, "hiding cancels the escalation timer")
    }

    @Test("Waiting resumed inside the hold keeps the wait continuous")
    func resumedWaitStaysVisible() {
        let clock = ManualTransportStatusScheduler()
        let state = clock.makeState()

        state.set(.buffering)
        clock.fire(timing.showDelay)
        state.set(.none)
        state.set(.buffering)
        clock.fire(timing.minimumVisible)
        #expect(state.status == .buffering)
        clock.fire(timing.escalation)
        #expect(state.stage == .card)
    }

    @Test("A continuous wait escalates from spinner to card")
    func escalatesToCard() {
        let clock = ManualTransportStatusScheduler()
        let state = clock.makeState()

        state.set(.buffering)
        clock.fire(timing.showDelay)
        clock.fire(timing.minimumVisible)
        #expect(state.stage == .spinner)
        clock.fire(timing.escalation)
        #expect(state.status == .buffering)
        #expect(state.stage == .card)

        // A new wait after recovery starts again at the spinner.
        state.set(.none)
        #expect(state.status == .none)
        state.set(.buffering)
        clock.fire(timing.showDelay)
        #expect(state.stage == .spinner)
    }

    @Test("Paused buffering presents the card directly")
    func pausedBufferingUsesCard() {
        let clock = ManualTransportStatusScheduler()
        let state = clock.makeState()

        state.set(.buffering)
        clock.fire(timing.showDelay)
        #expect(state.stage == .spinner)
        state.set(.pausedBuffering)
        #expect(state.status == .pausedBuffering)
        #expect(state.stage == .card)

        // Resuming while still waiting does not demote the engaged viewer's card.
        state.set(.buffering)
        #expect(state.status == .buffering)
        #expect(state.stage == .card)
    }

    @Test("A paused wait that begins hidden still honors the show delay, then shows the card")
    func pausedWaitShowDelay() {
        let clock = ManualTransportStatusScheduler()
        let state = clock.makeState()

        state.set(.pausedBuffering)
        #expect(state.status == .none)
        clock.fire(timing.showDelay)
        #expect(state.status == .pausedBuffering)
        #expect(state.stage == .card)

        let localState = clock.makeState()
        localState.set(.preparingLocal(isPaused: true, hasObservedPlayback: true))
        clock.fire(timing.showDelay)
        #expect(localState.stage == .card)
    }

    @Test("Reconnecting and failure preempt a pending show and the minimum hold")
    func reconnectAndFailurePreempt() {
        let clock = ManualTransportStatusScheduler()
        let state = clock.makeState()

        state.set(.buffering)
        state.set(.reconnecting)
        #expect(state.status == .reconnecting)
        #expect(state.stage == .card)
        #expect(clock.pendingDelays.isEmpty)

        let held = clock.makeState()
        held.set(.buffering)
        clock.fire(timing.showDelay)
        held.set(.failed(message: "Try again."))
        #expect(held.status == .failed(message: "Try again."))
        #expect(held.stage == .card)

        // Clearing a reconnect/failure is not subject to the waiting hold.
        held.set(.none)
        #expect(held.status == .none)
    }

    @Test("Retry from a failure replaces the card with the spinner without a blank gap")
    func retryFromFailure() {
        let clock = ManualTransportStatusScheduler()
        let state = clock.makeState()

        state.set(.failed(message: nil))
        state.set(.buffering)
        #expect(state.status == .buffering)
        #expect(state.stage == .spinner)
        clock.fire(timing.escalation)
        #expect(state.stage == .card)
    }

    @Test("Remote first start before any frame shows the spinner without the delay")
    func remoteFirstStartIsImmediate() {
        let clock = ManualTransportStatusScheduler()
        let state = clock.makeState()

        state.set(.buffering, hasObservedPlayback: false)
        #expect(state.status == .buffering)
        #expect(state.stage == .spinner)

        // Same escalation timer as a rebuffer.
        clock.fire(timing.escalation)
        #expect(state.stage == .card)
    }

    @Test("Remote first start still honors the minimum-visible hold")
    func remoteFirstStartMinimumVisible() {
        let clock = ManualTransportStatusScheduler()
        let state = clock.makeState()

        state.set(.buffering, hasObservedPlayback: false)
        state.set(.none)
        #expect(state.status == .buffering)
        clock.fire(timing.minimumVisible)
        #expect(state.status == .none)
    }

    @Test("Local preparation uses the unified show delay, including before the first frame")
    func localPreparationUsesUnifiedDelay() {
        let clock = ManualTransportStatusScheduler()
        let state = clock.makeState()

        // A transient Offline initial open never publishes an overlay.
        state.set(.preparingLocal(isPaused: false, hasObservedPlayback: false), hasObservedPlayback: false)
        #expect(state.status == .none)
        #expect(clock.pendingDelays.contains(timing.showDelay))
        state.set(.none)
        clock.fireAll()
        #expect(state.status == .none)

        // A sustained one shows the spinner, then escalates like any other wait.
        state.set(.preparingLocal(isPaused: false, hasObservedPlayback: false), hasObservedPlayback: false)
        clock.fire(timing.showDelay)
        #expect(state.status == .preparingLocal(isPaused: false, hasObservedPlayback: false))
        #expect(state.stage == .spinner)
        clock.fire(timing.escalation)
        #expect(state.stage == .card)

        // A post-start local wait is delayed exactly like a remote rebuffer.
        let rebuffer = clock.makeState()
        rebuffer.set(.preparingLocal(isPaused: false, hasObservedPlayback: true))
        #expect(rebuffer.status == .none)
        clock.fire(timing.showDelay)
        #expect(rebuffer.status == .preparingLocal(isPaused: false, hasObservedPlayback: true))
    }

    @Test("The latest waiting variant is published when the delay elapses")
    func pendingShowUsesLatestStatus() {
        let clock = ManualTransportStatusScheduler()
        let state = clock.makeState()

        state.set(.buffering)
        state.set(.pausedBuffering)
        clock.fire(timing.showDelay)
        #expect(state.status == .pausedBuffering)
        #expect(state.stage == .card)
    }

    @Test("Status presentation helpers classify buffering-class states")
    func classification() {
        #expect(PlaybackTransportStatus.buffering.isWaitingForMedia)
        #expect(PlaybackTransportStatus.pausedBuffering.isWaitingForMedia)
        #expect(PlaybackTransportStatus.preparingLocal(isPaused: false, hasObservedPlayback: true).isWaitingForMedia)
        #expect(!PlaybackTransportStatus.reconnecting.isWaitingForMedia)
        #expect(!PlaybackTransportStatus.failed(message: nil).isWaitingForMedia)
        #expect(!PlaybackTransportStatus.buffering.presentsCardImmediately)
        #expect(PlaybackTransportStatus.pausedBuffering.presentsCardImmediately)
        #expect(PlaybackTransportStatus.preparingLocal(isPaused: true, hasObservedPlayback: false).presentsCardImmediately)
    }

    #if os(iOS)
    @Test("iOS status layout resolves by size class and scales compact widths")
    func mobileLayout() {
        #expect(PlayerTransportStatusLayout.resolve(usesCompactChrome: false,
                                                     isCompactHeight: false,
                                                     availableWidth: 1_024) == .regular)
        #expect(PlayerTransportStatusLayout.regular.cardWidth == 420)
        let portrait = PlayerTransportStatusLayout.resolve(usesCompactChrome: true,
                                                           isCompactHeight: false,
                                                           availableWidth: 320)
        #expect(portrait == .compact(availableWidth: 320))
        #expect(portrait.cardWidth == 272)
        let landscape = PlayerTransportStatusLayout.resolve(usesCompactChrome: true,
                                                            isCompactHeight: true,
                                                            availableWidth: 700)
        #expect(landscape == .compactHeight(availableWidth: 700))
        #expect(abs(landscape.cardWidth - 385) < 0.5)
    }
    #endif
}

/// Deterministic stand-in for `PlaybackTransportStatusState.taskScheduler`: records each timer
/// and fires it only when the test says so.
@MainActor
private final class ManualTransportStatusScheduler {
    private struct Entry {
        let id: Int
        let delay: Duration
        let action: @MainActor () -> Void
    }

    private var entries: [Entry] = []
    private var nextID = 0

    static let timing = PlaybackTransportStatusState.Timing(showDelay: .milliseconds(600),
                                                            minimumVisible: .milliseconds(700),
                                                            escalation: .milliseconds(3_500))

    var pendingDelays: [Duration] { entries.map(\.delay) }

    func makeState() -> PlaybackTransportStatusState {
        PlaybackTransportStatusState(timing: Self.timing) { [unowned self] delay, action in
            self.schedule(delay, action)
        }
    }

    private func schedule(_ delay: Duration, _ action: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
        nextID += 1
        let id = nextID
        entries.append(Entry(id: id, delay: delay, action: action))
        return { [weak self] in self?.entries.removeAll { $0.id == id } }
    }

    /// Fire every pending timer with `delay`, in scheduling order.
    func fire(_ delay: Duration, sourceLocation: SourceLocation = #_sourceLocation) {
        let due = entries.filter { $0.delay == delay }
        #expect(!due.isEmpty, "no pending \(delay) timer", sourceLocation: sourceLocation)
        for entry in due where entries.contains(where: { $0.id == entry.id }) {
            entries.removeAll { $0.id == entry.id }
            entry.action()
        }
    }

    func fireAll() {
        while let entry = entries.first {
            entries.removeFirst()
            entry.action()
        }
    }
}
