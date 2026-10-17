import Foundation
import PMSKit
import Testing
@testable import Labstream

/// P2.6 runner pins with fake dependencies: coalescing, single flight, bounded concurrency,
/// eligibility, legacy classification, receipts, session gating, backoff and self-scheduled wake.
@MainActor
@Suite("Cleanup intent runner", .serialized)
struct DownloadCleanupIntentRunnerTests {
    @Test("Eligible intents run; retiring and blocked ones wait without backoff")
    func eligibilityAndReceipts() async throws {
        let deleted = try intent(.rowDeletion)
        let retiring = try intent(.rowDeletion)
        let blocked = try intent(.rowDeletion)
        let fake = FakeCleanupWorld(intents: [deleted, retiring, blocked])
        fake.rowStates[retiring.id] = .retiring
        fake.blocked = [blocked.id]
        let runner = fake.makeRunner()
        runner.enable()
        await runner.waitUntilIdle()

        #expect(fake.executed == [deleted.id])
        #expect(runner.nextWakeForTesting == nil)
    }

    @Test("Legacy entries are classified durably before they can run")
    func legacyClassification() async throws {
        let legacy = try intent(nil)
        let unclassifiable = try intent(nil)
        let fake = FakeCleanupWorld(intents: [legacy, unclassifiable])
        fake.rowStates[unclassifiable.id] = .present(isTerminal: false, protectsResource: false)
        let runner = fake.makeRunner()
        runner.enable()
        await runner.waitUntilIdle()

        #expect(fake.replaced.map(\.id) == [legacy.id])
        #expect(fake.replaced.first?.provenance == .rowDeletion)
        #expect(fake.executed == [legacy.id])
    }

    @Test("A protected failed row keeps its terminal-release intent")
    func protectedTerminalReleaseWaits() async throws {
        let release = try intent(.terminalRelease)
        let fake = FakeCleanupWorld(intents: [release])
        fake.rowStates[release.id] = .present(isTerminal: true, protectsResource: true)
        let runner = fake.makeRunner()
        runner.enable()
        await runner.waitUntilIdle()
        #expect(fake.executed.isEmpty)
    }

    @Test("Kicks during a pass coalesce into exactly one more pass")
    func kicksCoalesce() async throws {
        let fake = FakeCleanupWorld(intents: [])
        fake.loadDelay = 0.05
        let runner = fake.makeRunner()
        runner.enable()
        // Kicks before the first load are folded into it; kicks while it loads add one pass.
        for _ in 0..<100 where fake.loads == 0 { try await Task.sleep(for: .milliseconds(2)) }
        for _ in 0..<5 { runner.kick(reason: "test") }
        await runner.waitUntilIdle()
        #expect(fake.loads == 2)
    }

    @Test("At most two intents run at once and each runs once per pass")
    func boundedConcurrencyAndSingleFlight() async throws {
        let intents = try (0..<5).map { _ in try intent(.rowDeletion) }
        let fake = FakeCleanupWorld(intents: intents)
        fake.executionDelay = 0.03
        let runner = fake.makeRunner()
        runner.enable()
        runner.kick(reason: "overlap")
        await runner.waitUntilIdle()

        #expect(fake.maxConcurrent <= DownloadCleanupIntentRunner.maxConcurrentRuns)
        #expect(Set(fake.executed).count == intents.count)
        #expect(fake.executed.count == Set(fake.executed).count)
    }

    @Test("A missing session backs off and the runner wakes itself without any other trigger")
    func sessionMismatchBacksOffAndSelfSchedules() async throws {
        let pending = try intent(.rowDeletion)
        let fake = FakeCleanupWorld(intents: [pending])
        fake.hasSession = false
        let runner = fake.makeRunner(backoff: 0.05)
        runner.enable()
        await runner.waitUntilIdle()
        #expect(fake.executed.isEmpty)
        #expect(runner.nextWakeForTesting != nil)

        fake.hasSession = true
        for _ in 0..<100 where fake.executed.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(fake.executed == [pending.id])
    }

    @Test("Failures back off per intent; a reset makes them runnable at once")
    func failureBackoffAndReset() async throws {
        let failing = try intent(.rowDeletion)
        let fake = FakeCleanupWorld(intents: [failing])
        fake.outcome = .failed
        let runner = fake.makeRunner(backoff: 3_600)
        runner.enable()
        await runner.waitUntilIdle()
        runner.kick(reason: "too_soon")
        await runner.waitUntilIdle()
        #expect(fake.executed == [failing.id])

        runner.resetBackoff(reason: "session_changed")
        await runner.waitUntilIdle()
        #expect(fake.executed == [failing.id, failing.id])
    }

    @Test("A Plex retention delay is honoured even when the backoff is shorter")
    func plexRetentionDelay() async throws {
        let plex = try intent(.rowDeletion)
        let fake = FakeCleanupWorld(intents: [plex])
        fake.outcome = .retained(minimumDelaySeconds: 3_600)
        let runner = fake.makeRunner(backoff: 0.01)
        runner.enable()
        await runner.waitUntilIdle()
        let wake = try #require(runner.nextWakeForTesting)
        #expect(wake.timeIntervalSinceNow > 3_000)
    }

    @Test("An unreadable journal is retried by the runner's own timer")
    func loadFailureRetries() async throws {
        let fake = FakeCleanupWorld(intents: [])
        fake.loadFails = true
        let runner = fake.makeRunner()
        runner.enable()
        await runner.waitUntilIdle()
        #expect(runner.nextWakeForTesting != nil)
        #expect(fake.executed.isEmpty)
    }

    private func intent(
        _ provenance: DurableDownloadCleanupIntent.Provenance?
    ) throws -> DurableDownloadCleanupIntent {
        let attemptID = DownloadAttemptID(uuid: UUID())
        let server = try #require(DurableDownloadCleanupIntent.ServerIdentity(
            baseURL: URL(string: "https://media.example")!, serverID: "server-1", userID: "user-1"))
        return try #require(DurableDownloadCleanupIntent(
            attemptKey: DownloadAttemptKey(ratingKey: "jellyfin:\(attemptID.rawValue)",
                                           attemptID: attemptID),
            backend: .jellyfin, server: server,
            operation: .activeEncoding(playSessionID: "session-\(attemptID.rawValue)"),
            provenance: provenance))
    }
}

@MainActor
private final class FakeCleanupWorld {
    var intents: [DurableDownloadCleanupIntent]
    var rowStates: [UUID: CleanupIntentEligibilityPolicy.RowState] = [:]
    var blocked: Set<UUID> = []
    var hasSession = true
    var outcome: DownloadCleanupIntentRunner.ExecutionOutcome = .retired
    var executionDelay: Double = 0
    var loadDelay: Double {
        get { journal.withLock { $0.loadDelay } }
        set { journal.withLock { $0.loadDelay = newValue } }
    }
    var loadFails: Bool {
        get { journal.withLock { $0.loadFails } }
        set { journal.withLock { $0.loadFails = newValue } }
    }
    var loads: Int { journal.withLock { $0.loads } }
    var replaced: [DurableDownloadCleanupIntent] { journal.withLock { $0.replaced } }
    private(set) var executed: [UUID] = []
    private(set) var maxConcurrent = 0
    private var running = 0
    private let journal: LockedJournal

    init(intents: [DurableDownloadCleanupIntent]) {
        self.intents = intents
        self.journal = LockedJournal(intents: intents)
    }

    func makeRunner(backoff: Double? = nil) -> DownloadCleanupIntentRunner {
        var dependencies = DownloadCleanupIntentRunner.Dependencies(
            load: { [journal] in
                let (delay, fails) = journal.withLock { state -> (Double, Bool) in
                    state.loads += 1
                    return (state.loadDelay, state.loadFails)
                }
                if delay > 0 { Thread.sleep(forTimeInterval: delay) }
                if fails { return .failed(.init(stage: .read, errorType: "Injected")) }
                return .loaded(journal.withLock { $0.intents })
            },
            replace: { [journal] updated in
                journal.withLock { state in
                    state.replaced.append(updated)
                    if let index = state.intents.firstIndex(where: { $0.id == updated.id }) {
                        state.intents[index] = updated
                    }
                }
                return true
            },
            rowState: { [unowned self] intent in self.rowStates[intent.id] ?? .committedAbsent },
            isBlocked: { [unowned self] intent in self.blocked.contains(intent.id) },
            hasMatchingSession: { [unowned self] _ in self.hasSession },
            execute: { [unowned self] intent in await self.execute(intent) })
        if let backoff { dependencies.backoffSeconds = { _ in backoff } }
        let runner = DownloadCleanupIntentRunner(dependencies: dependencies)
        return runner
    }

    private func execute(
        _ intent: DurableDownloadCleanupIntent
    ) async -> DownloadCleanupIntentRunner.ExecutionOutcome {
        running += 1
        maxConcurrent = max(maxConcurrent, running)
        executed.append(intent.id)
        if executionDelay > 0 { try? await Task.sleep(for: .seconds(executionDelay)) }
        running -= 1
        if outcome == .retired {
            journal.withLock { $0.intents.removeAll { $0.id == intent.id } }
        }
        return outcome
    }
}

private final class LockedJournal: @unchecked Sendable {
    struct State {
        var intents: [DurableDownloadCleanupIntent]
        var replaced: [DurableDownloadCleanupIntent] = []
        var loads = 0
        var loadDelay: Double = 0
        var loadFails = false
    }

    private let lock = NSLock()
    private var state: State

    init(intents: [DurableDownloadCleanupIntent]) { state = State(intents: intents) }

    func withLock<T>(_ body: (inout State) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(&state)
    }
}
