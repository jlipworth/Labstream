# DownloadsWake: background wakes, the completion registry and startup admission

Module notes for `DownloadsWake.tla` and `DownloadsWakeLaunchGate.tla`. Shared conventions are in
the comment block at the top of `DownloadsBase.tla`.

## What is modelled

`DownloadsWake.tla` models one background-session identifier and three pieces of code together:

| Code | In the model |
| --- | --- |
| `BackgroundDownloadCompletionRegistry` | stored handlers (`hs`), their receipts' frozen deadlines (`hdl`), `register` replay (`ManagerInit`), the registry's own deadline timer (`RegistryTimer`), `fireCompletions` (`MainFire`) |
| `BackgroundDownloadCompletionHandlerStore` | exact-token batches: `MainFire` calls only tokens that were claimed |
| `BackgroundDownloadWakeCoordinator` | the record `c`: the wake, awaiting and finished tokens, required and registered operations, expired operations, the flush and its proof, wind-down, authorization expiry |
| `DownloadWakeBudgetContract` | `WholeWake`, `OpBudget`, `Reserve`; the release predicate in `Progress` |
| `BackgroundDownloadSession` startup | `adm` (dormant, purging, active), `live`, `failedAfter`, `sws`, `releaseBackgroundCompletionAfterStartupFailure` |
| `DownloadManager` startup | `mgr`: not built, preparing, waiting for authorization, in flight, ready, blocked |

A handler is released in two steps, as in the code: the coordinator claims the token, then a
MainActor hop calls it. `releaseQ` holds tokens between the two.

`DownloadsWakeLaunchGate.tla` models `LaunchDownloadRecoveryGate` and its two callers in the root
view (the launch task and the browse-ready observer).

Neither module has download rows or calls `Reduce`: nothing in this subsystem changes a lifecycle.
There is therefore no `Projection-Wake.cfg`.

Actors: the OS (handler delivery, finish-events, task events), app startup, the clock and its
timers, transfer work (operations, a delayed retry, persistence flushes), the foreground edge, and
process death.

## The clock and the timers

The clock keeps running while a timer callback waits on its queue, as `DispatchTime` does. A
callback runs at most `TimerSlack` ticks after the later of its deadline and the moment it was
armed: `Tick` is disabled only once a timer that exists is that late. Between a deadline and its
callback everything else can happen: finish-events, a flush result, an operation ending, a new
handler. An earlier version stopped the clock whenever any timer was due, and its budget
invariant accepted an overdue handler whenever any timer was due, so it passed with the
operation watchdog removed.

The four timers are switched separately. `FixB13` is the operation deadline alone, which is what
B13 fixed (a leaked operation had no time bound). `MutantNoAbsoluteDeadline` and
`MutantNoRegistryTimer` remove the other two claiming timers. The reserve timer has no switch.

When a session registers, a handler passes from the registry's timer to the wake's
absolute-deadline timer, which is armed at that moment. `hat` records when the covering timer
was armed, so a handler registered inside the slack window is given the slack again.

## Bounds

Two handlers, two operations, clock 0 to 4 with whole wake 2, operation budget 1, reserve 1 and
timer slack 1 (the app's 25 s, 20 s and 5 s, in order), one crash, one task event, two operation
starts, one startup failure and one retry. `Handlers` and `Ops` are symmetry sets in the safety configs.

| Config | Result | Distinct states | Time at 2 workers, 2 GB (the higher figure is with other agents running) |
| --- | --- | --- | --- |
| `Current-Wake` | pass | 9,290,572 | 135 s |
| `Proposed-W1-FreshDeadline` | pass | 8,015,945 | 134 s |
| `Liveness-HandlerCalled` | pass | 977,937 | 112 s |
| `WakeLaunchGate-Current-Gate` | pass | 112 | 1 s |
| every `Faithful`, `Mutant` and `Finding` config | expected violation | under 34,000 | 1 s |

No deep config.

## Properties

| Property | Says | Bug |
| --- | --- | --- |
| `NoOrphanHandler` | a stored handler is held by the coordinator, queued for the MainActor, or covered by the registry timer | B06, B11 |
| `HandlerClaimedWithinBudget` | no handler is unclaimed more than the slack after its deadline (or after its covering timer was armed, when that was later) | mutants |
| `OperationHoldBounded` | an operation the wake waits for holds it for at most the operation budget plus the slack | B13 |
| `AwaitingHandlerIsOwedFinishEvents` | a handler waiting for finish-events is one the OS still owes them for | B11 |
| `BlockedStartupHoldsNoHandler` | a startup blocked before the transport exists holds no wake | B06 |
| `GateHoldsForSuccessor` | no drained release while a delayed retry's successor is unregistered | B04 |
| `LiveHoldsSurviveStartupBlock` | a release that is not a timeout never drops an operation the wake waited for | B05 |
| `CalledOnlyAfterClaim` | a handler is called only after its own token was claimed | mutant |
| `HandlerEventuallyCalled` (liveness) | every stored handler is called or dies with the process | B06, B11, B13 |
| `NoStaleDeadline`, `NoHandlerBornExpired` | a new handler does not inherit a claimed batch's deadline | finding W1 |
| `NoDrainWithUnsettledWork` | a drained release leaves no operation in flight, except one a timed-out wake gave up on | finding W2 |
| `LaunchPassSawServers` | after the launch pass, if browse is ready then some pass started with it ready | B77 |
| `NoOverlappingPasses`, `RerunAtMostOnce`, `NormalLaunchRunsOnce` | the rerun is single, late enough and only after an offline launch | |

"Called exactly once" is split. "At least once" is `HandlerEventuallyCalled`. "At most once" is not
a model property: the store removes a handler when it drains it, so the model cannot call one
twice. `DownloadsFormalModelWakeTests` checks that fact on the real store over every short order of
supply, claim and release.

The liveness run forces only the clock, the timers and the MainActor queue. Finish-events,
operations, flushes and startup may never happen.

## Faithfulness

| Config | Fix off | Violates |
| --- | --- | --- |
| `Faithful-B04-off` | a delayed retry holds no wake operation | `GateHoldsForSuccessor` |
| `Faithful-B05-off` | a block after the transport exists aborts holds | `LiveHoldsSurviveStartupBlock` |
| `Faithful-B06-off` | the session forgets the startup block | `BlockedStartupHoldsNoHandler` |
| `Faithful-B11-off` | the handler reaches the registry through a Task hop | `AwaitingHandlerIsOwedFinishEvents` |
| `Faithful-B13-off` | no operation deadline; the other timers stay | `OperationHoldBounded` |
| `Mutant-NoAbsoluteDeadline` | no absolute-deadline timer | `HandlerClaimedWithinBudget` |
| `Mutant-NoRegistryTimer` | no registry deadline timer | `HandlerClaimedWithinBudget` |
| `Mutant-DrainByIdentifier` | a release drains every handler for the identifier | `CalledOnlyAfterClaim` |
| `WakeLaunchGate-Faithful-B77-off` | a reconnect never reruns the pass | `LaunchPassSawServers` |

`Faithful-B13-off` passes when no operation ever starts (`MaxOps = 0`), which is the isolation
check: the mutation is the operation deadline and nothing else. With the absolute deadline still
armed, a leaked operation costs the wake `WholeWake` instead of `OpBudget`, and
`HandlerClaimedWithinBudget` still holds.

## Findings

Both are in app-target code, so neither can be pinned from PMSKit. They have Finding configs and
the test sketches below, which were not compiled.

### W1: a handler that arrives during a release hop inherits the claimed batch's deadline

Issue: #480.

1. Handler A is stored. Its receipt's deadline is 25 s away.
2. No finish-events arrive. At the deadline the coordinator claims A as timed out and queues the
   MainActor hop that will call it.
3. Before that hop runs, the OS supplies handler B.
4. The registry gives B the earliest deadline among the receipts it still holds. A's receipt is
   only removed when A is called, so B gets A's deadline, which has passed.
5. The coordinator opens a new wake for B with that deadline. Its timers are already due: B is
   claimed as timed out at once, and background authorization is marked expired again, so
   startup recovery and transfer work stay parked for this wake.

When the first claim is a normal drain the deadline is not yet past and B only gets A's remaining
budget instead of its own 25 s.

Evidence: `BackgroundDownloadCompletionRegistry.swift:70-72` (deadline from held receipts),
`:130` (receipt removed only in `fireCompletions`), `BackgroundDownloadSession.swift:2190-2193`
(release is a MainActor Task), `BackgroundDownloadWakeCoordinator.swift:156-161` and `:340-345`
(a new wake takes the receipt's deadline and times out when it is due). The coordinator's own test
"Expired A remains physically owned but cannot hold or expire successor wake B" states the intent
this breaks. The window is the MainActor queue latency between claim and call.

Proposed fix in the model (`FixStaleDeadline`): inherit only from receipts whose token has not
been claimed. `Proposed-W1-FreshDeadline.cfg` passes.

```swift
// LabstreamTests sketch. The session's release closure is withheld to stand for the pending hop.
let clock = P6WakeClock()
let registry = BackgroundDownloadCompletionRegistry(clockHooks: clock.hooks)
let session = BackgroundDownloadSession(store: store, protocolClasses: [],
    wakeClockHooks: clock.hooks, releaseBackgroundCompletion: { _ in })
registry.register(session)
registry.store(identifier: BackgroundDownloadSession.identifier) {}
clock.advance(to: 25)                       // A is claimed as timed out, not yet called
registry.store(identifier: BackgroundDownloadSession.identifier) {}
withKnownIssue("TLA+ finding W1") {
    #expect(!session.startupAuthorizationExpired)   // B opened a wake with its own budget
}
```

### W2: an operation begun while an expired operation lingers does not hold the next wake

Issue: #481.

1. A wake is open and operation X (say an append) is in flight. X outlives its budget, the wake
   is claimed as timed out, and X is marked expired. X is still running.
2. With no wake open, operation Y begins (an append from a task callback, or a delayed retry).
   Because an expired operation exists, Y is marked expired too.
3. A new handler arrives. The new wake requires every registered operation except the expired
   ones, so it requires nothing.
4. Finish-events arrive, the flush commits, and the handler is released as drained while Y is
   still in flight. If Y is a delayed retry, its successor task is not registered yet: the B04
   guarantee does not hold for it.

Evidence: `BackgroundDownloadWakeCoordinator.swift:119` (`if wake == nil &&
!expiredOperations.isEmpty { expiredOperations.insert(operation.id) }`), `:161` (required is
operations minus expired), and the comment at `:186` ("Work admitted before a handler remains
required"). Whether marking Y is intended is not stated anywhere; no test covers an operation
begun between a timed-out wake and its successor.

```swift
// LabstreamTests sketch.
let clock = P6WakeClock()
let coordinator = BackgroundDownloadWakeCoordinator(clockHooks: clock.hooks)
coordinator.storeHandler(identifier: "wake", token: .init())
let old = coordinator.beginOperation(kind: .append)
clock.advance(to: 20)                                        // wake A timed out; old lingers
let fresh = coordinator.beginOperation(kind: .delayedRetry)  // begun between wakes
coordinator.storeHandler(identifier: "wake", token: .init())
withKnownIssue("TLA+ finding W2") {
    #expect(coordinator.finishEvents(identifier: "wake") == .none)  // fresh still holds wake B
}
_ = (old, fresh)
```

### Modelling artefact fixed in the model

The first statement of `GateHoldsForSuccessor` flagged a retry whose operation a timed-out wake had
already given up on. That exclusion is the B13 design (pinned by the coordinator test named above),
so the property now exempts operations the coordinator has marked expired. The part of the
counterexample that was not by design is W2.

## Observations that are not findings

- Nothing in the app calls `BackgroundDownloadCompletionRegistry.noteStartupWakeState`; only
  `P6BackgroundWakeTests` does. In the app a startup block reaches the session through
  `DownloadManager.blockDownloadStartup`, and a handler stored before any session registers waits
  for the registry timer. The model follows the app, so the registry's startup memory is unmodelled.
- After a timed-out wake, `isWindingDown` stays true for as long as any expired operation is
  registered, including in the foreground. A leaked operation would keep health refill parked until
  relaunch. That belongs to the range-train model.
- The rerun after a ready edge starts in a MainActor Task. Browse can stop being ready before it
  begins, and the gate will not rerun again in that process. The gate model starts the rerun in the
  same step as the edge.

## Not covered

- Timer arming. Timers are derived from state (a timer is due while its wake exists and its
  deadline has passed), so a missing or stale arm cannot be found here.
- Rebuild grace (`beginGrace`, `endGrace`), deferred revalidation keys, the count-only anonymous
  operation API used by older fixtures.
- The unsupported-schema reset path and per-task callback admission (B07).
- More than one session identifier.
- How long the MainActor hop takes. Calling a claimed handler is bounded by fairness, not by time.
- The MainActor hop between `failStartupAdmission` and `blockDownloadStartup`: one step here.
