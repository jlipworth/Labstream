# proxy: the loopback HLS proxy's listener, handlers and upstream

`PlaybackProxy.tla` models the PMSKit side of the loopback proxy: one `MediaSessionProxy`
actor, its `LoopbackOrigin` (an `NWListener` on a serial dispatch queue), the per-connection
handler Tasks the origin spawns, and the `UpstreamConnection` and `SessionBox` that fetch
upstream and rotate a wedged socket. The controller side, the `remoteHLSProxy` slot and its
`pendingStopTasks`, is in `../restart`; here the caller is abstract. The module does not
extend `../base`: it has no server, encoding session or controller state in it.

```sh
scripts/check-tla-specs.sh specs/playback/proxy
scripts/check-tla-specs.sh --deep specs/playback/proxy    # adds Deep-Reopen
```

The model reproduces suspect 5 (the 2026-06-14 proxy review's finding D) and finds three
smaller defects next to it. Each has a `Finding-*` config and a trace below. None has been
reproduced in the app.

## What is modelled

Each run of an actor between two awaits is one action, and so is each block on the origin's
serial queue. Line numbers are as of commit `2438be1e`; the three modelled files were last
changed in `4ed709a4`. `MediaSessionProxy.swift`, `LoopbackOrigin.swift` and
`UpstreamConnection.swift` are in `PMSKit/Sources/PMSKit/MediaSession/`.

| Model | Swift |
| --- | --- |
| `CallStandUp(c)` | `standUpLoopback` up to its await: the re-open teardown (`MediaSessionProxy.swift` 82 to 87), the `UpstreamConnection` (99 to 104), and the synchronous body of `origin.start`'s continuation: `state.install` and `queue.async` (`LoopbackOrigin.swift` 21 to 27) |
| `Resume(c)` | the rest of `standUpLoopback` once start resumes: success hands out `generationCounter + 1` and sets `current` (137 to 140); failure runs the catch, `origin.stop(); connection = nil; current = nil` (114 to 120). Then the caller's own check: `PlaybackController.swift` 3099 to 3103, 3128 to 3132, 3467 to 3471 |
| `Teardown(c)` | the caller tears down. Awaiting: `playbackTask?.cancel()` (`PlaybackController.swift` 1181), which runs start's `onCancel` (`LoopbackOrigin.swift` 62 to 68). Open: `pendingStopTasks.append(Task { await proxy.stop(generation:) })` (1188 to 1192, 5169 to 5173) |
| `CallerStop(c)` | an API caller that reuses the proxy stops it and may re-open later (`testStaleStopIsIgnored`, `testProxyRejectsChangedInitializationDuringRangeAndResetsOnReopen`) |
| `DeliverStop(g)` | `stop(generation:)` (155 to 160): the guard at 156, then `origin.stop()`, which only queues the cancel (`LoopbackOrigin.swift` 71 to 76) |
| `QueueStep`, `build` | start's queue block (`LoopbackOrigin.swift` 27 to 60): skip if completed (28), make the listener or fail (33, 57 to 58), assign `self.listener` (38) |
| `QueueStep`, `cancel` | `self.listener?.cancel(); self.listener = nil` from `stop()` (72 to 75) or `onCancel` (64 to 67): it cancels whichever listener `self.listener` holds when it runs |
| `ListenerReady`, `ListenerFails` | the `stateUpdateHandler` (42 to 55) and `ListenerStartState.complete` (139 to 151) |
| `Accept(o)` | `newConnectionHandler` and `handle(_:handler:)` (39 to 41, 78 to 80). Enabled only once the attempt's handle has been returned to a caller that kept it: no client can connect to a port it was never given |
| `HeadArrives`, `HeadAbort` | `readHead` (92 to 108) delivering the head and starting the untracked `Task` (82), or `done(nil)` and `conn.cancel()` (81). The P7 resource await in `serve` (180 to 187) is folded in |
| `FetchStart(i)` | `serve` calls `connection.send` (`MediaSessionProxy.swift` 206); `send` takes `makeAttempt()` (`UpstreamConnection.swift` 48) and the request goes out |
| `FetchOk`, `FetchFail2` | the fetch or the single retry returns; the handler writes the response and closes (`LoopbackOrigin.swift` 83 to 86) |
| `FetchFail(i)` | `send`'s catch on the connection actor (`UpstreamConnection.swift` 51 to 72): the stale-generation retry with `Task.checkCancellation` (52 to 61), `isWedge` (63), the budget (64) |
| `Rotate(i)` | `rotate(attempt.generation)` and the retry `makeAttempt().response` (66 to 69); `SessionBox.rotate(ifCurrent:)` (`MediaSessionProxy.swift` 328 to 341) |
| `boxGen`, `boxValid`, `deadGens` | `SessionBox.generation`; whether its current `URLSession` is invalidated; sessions whose tasks were cancelled (`invalidateAndCancel`, only before `adada9d3` and in the proposed fix) |

A standUpLoopback call is an attempt `o`. Its listener (`lstate[o]`), its start state
(`sres[o]`), its `UpstreamConnection` (`budget[o]`, `busy[o]`) and the handlers its listener
accepts are indexed by `o`; the generation the proxy handed it is `genOf[o]`. A handler is
`[o, pc, g, cx, late, lf]`: its attempt, where it is (`head`, `pre`, `fetch`, `rotate`,
`fetch2`, `done`), the session generation its fetch uses, whether its Task was cancelled (only
the proposed fix cancels one), and two ghosts: accepted after its session was torn down, and
started a fetch after that.

### The caller

`PlaybackController` builds a new `MediaSessionProxy` for every stand-up and calls
`standUpLoopback` once on it, then `stop(generation:)` once with the generation it was given.
`Current-Controller` is that caller. `Current-Reopen` is an API caller that reuses one proxy:
it may stop and re-open, or re-open directly, and its stop calls are Tasks that can arrive at
any time. Only there do stale stops, a stop that finds `current == nil`, and two
`UpstreamConnection`s over one `SessionBox` occur. `Controllers = {c1, c2}` is two overlapping
callers of one proxy; the app never does that.

A teardown during `standUpLoopback`'s await has no generation to name: `stop(generation:)` can
only name a handle already returned. The controller has two mitigations and the model has a
constant for each:

| Constant | `TRUE` (the controller) |
| --- | --- |
| `CallerCancels` | teardown cancels the task awaiting the stand-up, so start's `onCancel` completes it with `CancellationError` and queues a listener cancel |
| `CallerRechecks` | after `standUpLoopback` returns, `guard !Task.isCancelled, generation == playbackGeneration` stops the handle it was just given |

Either one alone keeps `TeardownNotLost`; `Mutant-TeardownDropped` turns both off. The check
and the install are one step here: the controller's yield at `await oldProxy.stop` between
them is suspect 1 and belongs to `../restart` (`Finding-ProxyAfterCleanup`).

### Constants under test

| Constant | `TRUE` is | Flipped by |
| --- | --- | --- |
| `StopChecksGeneration` | the guard at `MediaSessionProxy.swift` 156 | `Mutant-StaleStopTearsDown`, `Mutant-StaleStopCancelsListener` |
| `ReopenStopsPrior` | `origin.stop()` at 84 before a re-open binds | `Mutant-ReopenKeepsListener` |
| `RotateFenced` | `adada9d3`: the stale-generation retry, the compare-and-swap rotate, draining instead of cancelling the old session | `Faithful-RotateFenced-off` |
| `RotateCAS` | the compare in `SessionBox.rotate(ifCurrent:)` (330) | `Mutant-RotateUnconditional` |
| `FixCancelHandlers` | proposed: `stop` synchronously cancels the session's tracked handler Tasks and refuses new connections; handlers check cancellation before every upstream attempt | `Proposed-*` |
| `FixInvalidateOnStop` | proposed: `stop` invalidates the upstream `URLSession`; a re-open makes a fresh one | `Proposed-*` |

## What is abstracted, and why

- **The queue.** Only the blocks the proxy queues (`build`, `cancel`) are kept in order. The
  listener's own callbacks (ready, failed, a new connection) are actions that may run between
  any two of them, which is what a serial queue allows. A cancelled listener delivers no more
  connections; a connection accepted before its cancel keeps running, since `NWListener.cancel`
  does not cancel accepted `NWConnection`s. That is an assumption taken from Apple's
  documentation, not measured here.
- **Who connects.** A connection needs a client that knows the port: `Accept` requires the
  attempt's handle to have been returned to a caller that kept it (not one whose re-check
  stopped it). After teardown the client may still hold the URL and connect (AVPlayer's
  in-flight and queued segment requests), which is the window the findings use.
- **The build block is atomic.** It checks `state.isCompleted` twice (28, 34). If `onCancel`
  completes the start between the second check and the assignment at 38, the listener is
  assigned and started anyway, but `onCancel` always queues a cancel after it (64), so the
  atomic block reaches the same states.
- **A listener that fails after `.ready`** is not modelled: `ListenerStartState.complete`
  ignores it, and the session stays open with a dead listener until it is stopped.
- **Handlers.** One request per connection, as the origin does. The head read and the P7
  resource await are one step before the fetch. The HTTP response, the playlist rewrite and
  the P7 checks after the fetch start no new fetch and are folded into `FetchOk`.
- **Errors.** A failed fetch is a wedge or not, chosen freely; a cancellation (the fix, or a
  session cancelled under it) is never a wedge, as in `isWedge` (77 to 86).
- **Budget.** `SeekRestartBudget(cooldownSeconds: 5, burstLimit: 3, burstWindowSeconds: 60)`
  is a plain count per `UpstreamConnection` (`RotateBudget`, 1 or 2 here). `.deferred` and
  `.escalate` both surface the error.
- **The connection actor.** `send`'s catch reads the generation, takes the budget and calls
  `rotate` with no await between them, so no other step of the same `UpstreamConnection` can
  run in between (`busy[o]`). A different `UpstreamConnection` can: actors run on different
  threads. The catch is therefore split into `FetchFail` (check and budget) and `Rotate`
  (compare-and-swap and retry) so that cross-connection interleaving is explored.
- **Time.** No timers. URLSession's request and resource timeouts (20 s and 300 s,
  `PlexSessionConfiguration.mediaUpstream`) appear only as the fairness that makes every fetch
  end.
- **Left out:** the playlist rewriter, P7 HDR10 admission and normalisation, response headers,
  `status()`, the `URLError(.badURL)` path after a successful start (122 to 129; same cleanup
  as the catch), and keep-alive.

## Bounds

- `Current-Controller`: one caller, one stand-up, three connections, a rotate budget of two,
  listener failures on.
- `Current-Reopen`: one caller, two stand-ups, three connections, a rotate budget of one.
- `Deep-Reopen` (deep tier): three stand-ups.
- The `Finding-Concurrent*` configs: two callers, one stand-up each, one connection.
- Liveness configs over the re-open bounds use two connections; three makes the temporal check
  take longer than the default tier allows.

## Properties

| Property | Kind | Meaning |
| --- | --- | --- |
| `NoFetchAfterStop` | invariant | Once the proxy has torn a session down (stop, re-open, or a failed start), no handler of that session starts another upstream fetch. **Violated by the code (suspect 5).** |
| `NoAcceptAfterStop` | invariant | Once the proxy has torn a session down, its listener serves no new connection. **Violated by the code.** |
| `StaleStopIgnored` | invariant | A stop tears down only the session of the generation it names. |
| `CancelHitsOwnListener` | invariant | A queued listener cancel only cancels the listener of the attempt it was issued for. **Violated by two overlapping stand-ups** (not reachable from the app). |
| `SingleReachableListener` | invariant | Every live listener is the one `self.listener` refers to, so a later `origin.stop()` can reach it: no listener leaks. **Violated by two overlapping stand-ups** (not reachable from the app). |
| `TeardownNotLost` | invariant | Once a caller has torn down and the queue and its stop calls have run, none of its listeners is live. Covers a teardown during `standUpLoopback`'s await. |
| `RotateRetiresFailedGeneration` | invariant | A rotate retires exactly the session generation the failed fetch used. |
| `UpstreamSessionReleased` | invariant | Once everything has settled with no session current, the upstream `URLSession` is invalidated. **Violated by the code.** |
| `HandlersFinish` | liveness | Every accepted connection's handler finishes. |
| `StoppedListenerDies` | liveness | A torn-down session's listener stops listening. |
| `TeardownCompletes` | liveness | A caller's teardown completes and leaves none of its listeners live. |

`TeardownNotLost` is checked as a safety property over drained states: TLC explores the
schedule that runs the queue and every stop call, so a lost teardown shows up in a finite
trace. `TeardownCompletes` is the same claim under fairness.

Fairness is weak fairness on the queue, the listener becoming ready, `Resume`, stop delivery
and every handler step; none on the caller's choices or on a client connecting. The head read
is fair, which assumes the client eventually sends its head or closes: `readHead` has no
deadline (proxy review finding H).

## Configs and results

2026-11-25, tla2tools v1.7.4, `TLC_WORKERS=auto TLC_HEAP=4g` on 30 cores. Every config sets
`EnvFails = TRUE`.

| Config | Expect | Result | Distinct states | Time |
| --- | --- | --- | --- | --- |
| `Current-Controller` | pass | pass | 15,264 | 1 s |
| `Current-Reopen` | pass | pass | 1,618,198 | 6 s |
| `Deep-Reopen` (deep) | pass | pass | 45,606,950 | 138 s |
| `Liveness-Controller` | pass | pass | 15,264 | 2 s |
| `Liveness-Reopen` | pass | pass | 100,049 | 15 s |
| `Faithful-RotateFenced-off` | `RotateRetiresFailedGeneration` violated | violated | stops at first error | 2 s |
| `Mutant-ReopenKeepsListener` | `SingleReachableListener` violated | violated | stops at first error | 0 s |
| `Mutant-ReopenKeepsListener-Liveness` | `StoppedListenerDies` (temporal) violated | violated | stops at first error | 4 s |
| `Mutant-RotateUnconditional` | `RotateRetiresFailedGeneration` violated | violated | stops at first error | 1 s |
| `Mutant-StaleStopCancelsListener` | `CancelHitsOwnListener` violated | violated | stops at first error | 1 s |
| `Mutant-StaleStopTearsDown` | `StaleStopIgnored` violated | violated | stops at first error | 1 s |
| `Mutant-TeardownDropped` | `TeardownNotLost` violated | violated | stops at first error | 1 s |
| `Mutant-TeardownDropped-Liveness` | `TeardownCompletes` (temporal) violated | violated | stops at first error | 1 s |
| `Finding-HandlerOutlivesListener` | `NoFetchAfterStop` violated | violated | stops at first error | 1 s |
| `Finding-AcceptAfterStop` | `NoAcceptAfterStop` violated | violated | stops at first error | 0 s |
| `Finding-UpstreamSessionNeverInvalidated` | `UpstreamSessionReleased` violated | violated | stops at first error | 0 s |
| `Finding-ConcurrentStandUpLeaksListener` | `SingleReachableListener` violated | violated | stops at first error | 1 s |
| `Finding-ConcurrentStandUpCancelsOther` | `CancelHitsOwnListener` violated | violated | stops at first error | 1 s |
| `Proposed-Controller` | pass | pass | 3,474 | 1 s |
| `Proposed-Fixes` | pass | pass | 237,857 | 2 s |
| `Proposed-Liveness` | pass | pass | 27,800 | 3 s |

- `Current-Controller` checks `TypeOK`, `TeardownNotLost`, `SingleReachableListener` and
  `CancelHitsOwnListener`. It leaves out `StaleStopIgnored` and
  `RotateRetiresFailedGeneration`: with one stand-up there is no stale generation and one
  `UpstreamConnection`, so both would hold vacuously.
- `Current-Reopen` and `Deep-Reopen` check all six properties the code keeps.
- `Liveness-Controller`, `Liveness-Reopen` and `Proposed-Liveness` check `HandlersFinish`,
  `StoppedListenerDies` and `TeardownCompletes`.
- `Proposed-Fixes` checks every safety property, including the three the code breaks;
  `Proposed-Controller` the same at the controller's bounds (without the two the re-open adds).
- By hand, with `Proposed-Fixes`'s constants: `FixCancelHandlers` alone keeps
  `NoFetchAfterStop` and `NoAcceptAfterStop` (193,736 states, pass). `FixInvalidateOnStop`
  alone does not: a re-open makes a fresh session and the old session's handlers fetch on it
  (violated in 9 states). Invalidating the session is for `UpstreamSessionReleased`, not for
  suspect 5.

### Faithfulness and mutants

| Config | Flips | Violates | Trace |
| --- | --- | --- | --- |
| `Faithful-RotateFenced-off` | `RotateFenced` | `RotateRetiresFailedGeneration` | Before `adada9d3`. 20 states: the first session's listener accepts a connection, a re-open stands up the second, it opens, and its listener accepts one too. Both fetches fail on generation 0 with a wedge, each on its own `UpstreamConnection` with its own budget. The first rotates to generation 1 and cancels generation 0; the second, with no stale check, rotates generation 1 away as well. |
| `Mutant-RotateUnconditional` | `RotateCAS` | `RotateRetiresFailedGeneration` | The same 20 states with the stale check kept: both catches pass their check on generation 0 before either rotates (two actors, two threads), and the second `rotate` no longer compares. With the compare, `Current-Reopen` reaches exactly this interleaving and the second rotate is refused (`NeverCasRejected`). |
| `Mutant-StaleStopTearsDown` | `StopChecksGeneration` | `StaleStopIgnored` | 12 states: open (generation 1), `CallerStop` queues `stop(1)`, re-open, the second session opens (generation 2), then `stop(1)` arrives and tears it down. |
| `Mutant-StaleStopCancelsListener` | `StopChecksGeneration` | `CancelHitsOwnListener` | The same, one step on: the cancel queued for session 1 cancels session 2's listener. |
| `Mutant-TeardownDropped` | `CallerCancels`, `CallerRechecks` | `TeardownNotLost` | 6 states: stand up, tear down during the await, the listener binds and is ready, `standUpLoopback` returns a handle nobody stops. |
| `Mutant-TeardownDropped-Liveness` | the same | `TeardownCompletes` | The same listener stays live forever. |
| `Mutant-ReopenKeepsListener` | `ReopenStopsPrior` | `SingleReachableListener` | 7 states: open, re-open without `origin.stop()`, the build overwrites `self.listener` and the first listener can no longer be cancelled. |
| `Mutant-ReopenKeepsListener-Liveness` | the same | `StoppedListenerDies` | The first session is torn down and its listener never stops listening. |

`NoFetchAfterStop`, `NoAcceptAfterStop` and `UpstreamSessionReleased` have no `Mutant`: the
shipping code already violates them, so their `Finding` configs stand in as the proof that they
can fail, and the `Proposed` configs are the proof that they can hold.
`SingleReachableListener` and `CancelHitsOwnListener` are violated both by mutants in the
single-caller model and by the two-caller `Finding` configs. `StaleStopIgnored`,
`RotateRetiresFailedGeneration` and `TeardownNotLost` are broken by mutants.
`StoppedListenerDies` and `TeardownCompletes` are broken by the `-Liveness` mutants.
`HandlersFinish` has no failing run and holds by construction: every handler step is weakly
fair and a handler's `pc` never goes back, so with fairness each handler reaches `done`.

### Every branch is taken

The module ends with witnesses, each the negation of a state one branch reaches. Each was
checked as the only invariant with the named config's constants and is violated:

| Witness | Config | States | Branch |
| --- | --- | --- | --- |
| `NeverTeardownDuringAwait` | `Current-Controller` | 3 | teardown while `standUpLoopback` awaits |
| `NeverListenerFails` | `Current-Controller` | 3 | the listener fails to bind |
| `NeverDeadHandle` | `Current-Controller` | 7 | a returned handle whose listener `onCancel` cancelled (see below) |
| `NeverRotate` | `Current-Controller` | 10 | a wedge rotates the upstream session |
| `NeverLateFetch`, `NeverOrphanFetchInFlight` | `Current-Controller` | 10 | a fetch after teardown; one in flight |
| `NeverEarlyHandlerLateFetch` | `Current-Controller` | 10 | a handler accepted while its session was live fetches after the teardown |
| `NeverStopKilledEarly` | `Current-Controller` | 10 | the same with the teardown a `stop(generation:)` of an open session: suspect 5 in the review's form (below) |
| `NeverReopenTeardown` | `Current-Reopen` | 6 | a re-open tears down a live session |
| `NeverStopSawNil` | `Current-Reopen` | 8 | a stop arrives during a re-open's await and finds `current == nil` |
| `NeverStaleStop` | `Current-Reopen` | 12 | a stale stop is ignored with a newer session current |
| `NeverStaleRetry` | `Current-Reopen` | 14 | `send` takes the stale-generation retry |
| `NeverCasRejected` | `Current-Reopen` | 20 | `SessionBox.rotate` refuses a generation another connection already rotated |

No config lists them; to repeat one, copy the named config, replace its `INVARIANTS` and
`PROPERTIES` with the witness, use `SPECIFICATION Spec` and run TLC.

## Findings

Line numbers are as of `2438be1e` (the three modelled files unchanged since `4ed709a4`).
Traces are the shortest TLC finds with one worker.

### Suspect 5, reproduced: handlers outlive the listener (`Finding-HandlerOutlivesListener`)

The 2026-06-14 adversarial review of the proxy (finding D, removed from the tree in `0e2af792`;
read it with `git show 8a116844:docs/superpowers/reviews/2026-06-14-issue33-proxy-adversarial-review.md`)
said the handler Task `LoopbackOrigin.handle` spawns is never retained, and `stop()` cancels only
the listener. The code has not changed in that respect: the Task is at `LoopbackOrigin.swift`
82 to 88 (65 to 71 in the review), still untracked, and `stop()` (71 to 76) still only cancels
the listener. `NoFetchAfterStop` is violated.

In the review's form (`NeverStopKilledEarly` with `Current-Controller`'s constants, 10 states):

| Step | Model | Swift |
| --- | --- | --- |
| 1 to 4 | `CallStandUp`, `QueueStep` (build), `ListenerReady`, `Resume`: the proxy is open at generation 1 | `standUpLoopback` (`MediaSessionProxy.swift` 80 to 140), the queue block and `.ready` (`LoopbackOrigin.swift` 27 to 56, 44 to 47); the controller installs it (`PlaybackController.swift` 3132 to 3137) |
| 5 | `Teardown`: Close queues the stop | `pendingStopTasks.append(Task { await proxy.stop(generation:) })` (`PlaybackController.swift` 1188 to 1192) |
| 6 | `Accept`: AVPlayer's request connects | `newConnectionHandler`, `handle`, `readHead` (`LoopbackOrigin.swift` 39 to 41, 78 to 80) |
| 7 | `DeliverStop(1)`: the guard passes, the listener cancel is queued, `current = nil`, and `stop` returns | `MediaSessionProxy.swift` 155 to 160; `origin.stop()` is `queue.async` (`LoopbackOrigin.swift` 72) |
| 8 | `HeadArrives`: the head completes and the handler Task starts; nothing records it | `LoopbackOrigin.swift` 80 to 82 |
| 9 | `FetchStart`: the handler fetches upstream for a session the proxy has torn down | `serve` (`MediaSessionProxy.swift` 206) through `UpstreamConnection.send` (`UpstreamConnection.swift` 48 to 50) |

`connection = nil` at 158 changes nothing for the handler: the `origin.start` closure captured
`conn` at 110. Whether step 6 comes before or after the queued cancel runs makes no difference
once the connection is accepted, since cancelling an `NWListener` does not cancel accepted
connections (an assumption from Apple's documentation, not measured).

The config's own shortest trace is also 10 states and differs only in order: `stop(1)` runs
(step 7) before the connection is accepted (step 6), in the window before the queued listener
cancel runs (`Finding-AcceptAfterStop`), and that handler then fetches.

What bounds it. Each handler makes at most two upstream attempts: the first and a single retry
(`UpstreamConnection.swift` 60 or 69). Each attempt is bounded by the session's timeouts, 20 s
idle and 300 s per resource (`PlexSessionConfiguration.mediaUpstream`), so an orphan holds a
request open for at most about ten minutes after the P7 resource await. Before the fetch,
`readHead` has no deadline (review finding H): a connection accepted before the stop starts its
fetch whenever its head completes. Nothing cancels the fetch: the upstream `URLSession` is not
invalidated on stop (finding below), and the handler's closure (`conn`, then `makeAttempt`, then
the `SessionBox`) keeps it alive until the handler returns. On a reused proxy an orphan's wedge
can also rotate the `SessionBox` the next session uses (`NeverCasRejected` shows two
connections' catches interleaving); the app builds one proxy per stand-up, so there only the
dead session's own box is touched.

What it costs. The review's High rating rested on Stage 3 (a ~7 s `pollUntilReal` loop that
could re-prime a session from inside a handler). That loop never shipped; no handler re-primes
anything today. The defect that is left is smaller: up to two upstream requests per in-flight
connection, after teardown, against the transcode session the controller is stopping. The
2026-09-17 Jellyfin audit says Jellyfin can recreate a job from an HLS request it accepted
before acknowledging the stop; an orphaned segment request is such a request. That consequence
is plausible but not shown.

Proposed fix (`FixCancelHandlers`, checked by `Proposed-Fixes`, `Proposed-Controller` and
`Proposed-Liveness`): keep the handler Tasks in a lock-protected set with a stopped flag; `stop()`
sets the flag and cancels them synchronously, before it returns, not on the queue; `handle`
refuses a connection once the flag is set; `send` checks cancellation before each attempt (the
rotate retry at 69 has no check today). URLSession's async API cancels an in-flight request
with its Task.

Tracking Tasks is not enough on its own for the trace above. There the connection is accepted
before the stop and its head completes after it, so at stop time no Task exists to cancel, and
the Task created afterwards would not be cancelled. The fix must also do one of two things:
(a) when the head completes, re-check the stopped flag under the same lock and insert the new
Task into the set atomically with that check, or (b) track the accepted `NWConnection`s and
cancel them in `stop()`. In the model, the fix sets `cx` on handlers still reading their head
and `HeadArrives` then ends them. That `cx` stands for (a) or (b); without one of them the
model's fix would be stronger than the code change.

### The listener serves after stop returns (`Finding-AcceptAfterStop`)

`NoAcceptAfterStop` is violated in 8 states: open (steps 1 to 4 above), Close queues the stop,
`stop(1)` runs and returns with the listener cancel only queued (`LoopbackOrigin.swift` 72),
and the listener accepts a connection from the client that still holds the URL before that block
runs. The handler is served like any other. The start's catch (64) queues its cancel the same
way, but there no handle was returned, so no client can connect. The same fix covers it (the
stopped flag checked in `handle`).

### The upstream URLSession is never invalidated (`Finding-UpstreamSessionNeverInvalidated`)

`UpstreamSessionReleased` is violated in 6 states: `CallStandUp`, the build fails to make a
listener, `Resume` runs the catch, `Teardown` from idle, the queued cancel runs. Any order that
ends with the proxy stopped does the same. `SessionBox` makes its `URLSession` in the proxy's
initialiser (`MediaSessionProxy.swift` 46 to 48 and 295); the only invalidation is of a
rotated-out session (339). `stop`, the catch and the re-open never invalidate the current one,
and neither class has a `deinit`. Apple's documentation says a session that is never
invalidated stays alive until the app exits. So each proxied playback leaves one session
behind; the controller passes no delegate, so no delegate is retained with it. Low severity,
not measured.

Proposed fix (`FixInvalidateOnStop`): `invalidateAndCancel()` on stop, the catch and re-open,
with a re-open making a fresh session and `rotate` refusing to resurrect an invalidated box.
On its own it does not fix suspect 5 (see the results).

### API only: two overlapping stand-ups on one proxy (`Finding-ConcurrentStandUp*`)

`MediaSessionProxy` is an actor, so a second `standUpLoopback` can run while the first awaits
`origin.start`. Both configs use two callers with one stand-up each.

- `Finding-ConcurrentStandUpLeaksListener`, `SingleReachableListener` violated in 5 states:
  both calls start (the second sees `current == nil` at 83 and stops nothing), both builds run,
  and the second assigns `self.listener` (`LoopbackOrigin.swift` 38) over the first, which is
  still listening and which no `origin.stop()` can reach any more.
- `Finding-ConcurrentStandUpCancelsOther`, `CancelHitsOwnListener` violated in 7 states: both
  calls start, the first is cancelled (`onCancel` queues a cancel), its build is skipped, the
  second's build assigns `self.listener`, and the first's cancel cancels the second's listener.
  The first's failure catch (115 to 117) does the same and also clears `current` for the
  second.

`PlaybackController` never does this: it builds a new proxy for every stand-up (3096, 3124,
3464) and calls `standUpLoopback` once on it. They are recorded because the type is public and
its re-open path (82 to 87) invites reuse; a guard that rejects a stand-up while one is in
flight, or a per-attempt token in `LoopbackOrigin`, would close them.

## Observations that are not findings

- **A stop during `standUpLoopback`'s await is not lost.** At the PMSKit level a stop can only
  name a generation already handed out. A stop for an older generation that arrives during a
  re-open's await finds `current == nil` and returns (`NeverStopSawNil`); nothing is lost,
  because the re-open had already stopped that listener (82 to 87). A teardown of the stand-up
  itself has no generation to name, so the caller has to carry it, and the controller does,
  twice over: it cancels the task (start's `onCancel` cancels the listener) and re-checks after
  the call returns. Either alone keeps `TeardownNotLost` and `TeardownCompletes`; the model
  assumes the controller's check runs before it installs the proxy, which is true except for
  the yield at `await oldProxy.stop` (suspect 1, `../restart`).
- **A cancelled stand-up can return a dead handle** (`NeverDeadHandle`, 7 states). If the task is
  cancelled after `.ready` completed the start but before `standUpLoopback` resumes,
  `onCancel` still runs (`withTaskCancellationHandler` calls it whenever cancellation arrives
  while the operation has not returned), cancels the listener, and `standUpLoopback` returns a
  handle with `current` set and nothing listening. The controller's re-check sees
  `Task.isCancelled` and stops it, so the app is unaffected; a caller that ignored
  cancellation would hand AVPlayer a dead port.
- **A connection that never sends its head** (low). Weak fairness on the head read assumes the
  client sends its head or closes. A local socket that does neither keeps its handler, the
  handler's closure, the `UpstreamConnection` and the `SessionBox` alive indefinitely, since
  `readHead` has no deadline (review finding H). The listener binds to loopback only
  (`LoopbackOrigin.swift` 31) and AVPlayer closes its sockets when it is released, so this needs
  a misbehaving local client.
- **Rotation.** `adada9d3`'s fencing is load-bearing only across connections: within one
  `UpstreamConnection` the actor already orders the check and the rotate. Two connections over
  one `SessionBox` exist only on a reused proxy, which is also where `Current-Reopen` reaches a
  refused compare-and-swap.

## For the lead

- Suspect 5 is reproduced with a smaller blast radius than the review gave it (Stage 3 never
  shipped). The fix is small and local to `LoopbackOrigin` and `UpstreamConnection`, and a
  hermetic PMSKit test can pin it: open, start a slow handler (a stub upstream that blocks),
  stop, release the stub, assert no second upstream request. Today that test would see the
  first request complete and, on a wedge, a retry.
- `Finding-UpstreamSessionNeverInvalidated` is a leak, not an ordering bug; file it low.
- The concurrent stand-up findings are API hygiene with no app path.
