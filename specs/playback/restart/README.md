# restart: PlaybackController's restart and cleanup core

`PlaybackRestart.tla` models how `PlaybackController` starts, restarts and tears down a
stream: the playback generation, the `playbackTask` that is current and the cancelled ones
still unwinding, the seek hold, the final-target rebuild policy and its restart budget, the
retry task, the loopback proxy slot and `pendingStopTasks`. The backend's replacement order is
abstracted to "stop the prior session, then replace"; the Plex, Emby and Jellyfin orders are
their own modules.

```sh
scripts/check-tla-specs.sh specs/playback/restart
```

The model reproduces suspect 1 and suspect 4, and found three defects nobody had named. Each
has a `Finding-*` config and a trace below. None has been confirmed outside the model yet.

## What is modelled

Each MainActor run between two awaits is one action. Functions are in
`Labstream/Shared/Player/PlaybackController.swift` unless another file is named.

| Model | Swift |
| --- | --- |
| `Start` | `start()` with `beginStreaming` or `beginRemoteStream` |
| `UserQuality` | `reload(bitrateKbps:)` and the audio and subtitle track changes: `restartAtCurrentPosition` with an intent other than `explicitRetry` (`PlaybackRestartIntent.plan`) |
| `UserSeek` | `performUserSeek`: the native branch (`player.seek` and its completion handler) or `scheduleFinalTargetRebuild` |
| `SeekSettle` | the body of `finalTargetSettleTask`, `beginFinalTargetRebuild`, `FinalTargetRebuildPolicy.beginRebuild`, `SeekRestartBudget.requestRestart` |
| `SeekComplete` | `clearSeekHold(ifGeneration:)`, `PlaybackSeekHold.clear(ifGeneration:)` (`PlaybackPositionModels.swift`) |
| `SeekHoldCeiling` | `clearSeekHoldIfLanded`, `PlaybackSeekHold.exceeded` |
| `UserPause` | `requestPause`, `requestPlay` |
| `ReadyToPlay`, `ResumeSeekComplete` | the `.readyToPlay` branch of the item status observer, `resumeAfterCompletedSeek`, `isCurrentObservedItem` |
| `Retry`, `RetryProceeds`, `RetryBails` | `retry()`, `failureRetryTask`, `waitForPendingStopRequests` |
| `Close`, `CloseDetach` | `stop()` |
| `Fail`, `NegotiateFails` | `handlePlaybackFailure`, `surfaceReconnectTimeout`, `handleItemPreparationTimeout`, the `catch` of `reopenRemoteStream`, each ending in `surfaceFailure` |
| `StallWatchdog` | `handleStallTimeout`, `attemptAdaptiveBitrateFallback` |
| `StartupDeadline` | `attemptStartupDeadlineRetry`, `handleStartupVariantAbandonment` |
| `AbrSwitch` | `maybeAdaptBitrateAfterHealthyPlayback`, `applyAdaptiveBitrateDecision` |
| `RestartCore`, `PlanReset` | the synchronous part of `restartAtCurrentPosition`, `beginStreaming` and `reopenRemoteStream`; `PlaybackRestartPlan.preparationSteps` |
| `Terminal`, `SurfaceFailure` | what `stop()` and `surfaceFailure` share; `sendTranscodeStop`, `stopRemoteSessionIfNeeded` |
| `TaskStopWaitDone` | the wait in `stopPreviousTranscode`, or for the stop barrier in `reopenRemoteStream` |
| `NegotiateLands` | the server accepts the start (`start.m3u8`) or reopen (`remoteStreamReopener`) request |
| `TaskResume`, `TaskUnwindExit` | the `guard !Task.isCancelled, generation == playbackGeneration` checks of `startStreaming`; `RemoteStreamLifecyclePolicy.acceptsReopenResult` in `reopenRemoteStream` |
| `Attach` | `load(_:resumeOffsetMs:)`, and the tail of the task in `beginStreaming` |
| `Reject`, `TaskRejectDone` | `stopRejectedRemoteStream`, or the bare `return` of `startStreaming` |
| `ProxyStandUp`, `ProxyInstall`, `ProxyOwnStopped` | the proxy stand-up in `startStreaming` and `prepareRemoteStreamURL`, split at `await oldProxy.stop(generation:)` |
| `ProxyStopRuns` | a `pendingStopTasks` entry running `proxy.stop(generation:)` |
| `budget`, `pendingTarget`, `RebuildActive` | `SeekRestartBudget` (`SeekRestartBudget.swift`), `FinalTargetRebuildPolicy.pendingOffsetMs` and `activeGeneration` (`FinalTargetRebuildPolicy.swift`) |

A task is `[gen, pc, sid, inc, px, old, rb]`: the generation it captured, where it is, the job
its request created, the proxy it stood up, the proxy whose stop it awaits, and whether it is a
final-target rebuild. Its places:

| `pc` | The task is at |
| --- | --- |
| `awaitStop` | the wait for the prior session's stop |
| `negotiate` | its start or reopen request, on the wire |
| `negotiated` | the answer to an accepted request, on its way back |
| `standUp` | `await proxy.standUpLoopback` |
| `oldProxyStop` | `await oldProxy.stop(generation:)` |
| `stopOwnProxy` | `await proxy.stop` for its own proxy, after a failed check |
| `awaitReject` | `stopRejectedRemoteStream` |

Cancelling a task moves it to `unwinding`; it keeps taking steps until it returns.

### Two cleanup shapes

`PlaybackController` cleans a session up in two ways, and the core has both behind two
constants. Neither is a fix under test.

| Constant | `TRUE` | `FALSE` |
| --- | --- | --- |
| `RejectedResultStopped` | `reopenRemoteStream`: a result that fails the generation check is stopped by `stopRejectedRemoteStream` | `startStreaming`: every check is a bare `return` |
| `StopLatchPerSession` | `MediaBrowserPlaybackSession.didStop`, cleared when a reopen installs the next session's callbacks | `sentTranscodeStop`, one latch per controller, cleared only by `retry()` |

The `Current` and `Liveness` configs use `TRUE` for both. The `FALSE` shapes appear in
`Finding-StopNoJoin-LateStart`, `Finding-RestartAfterFailureSkipsFinalStop` and
`Proposed-ControllerLatch`. With a fresh session id per start, the `startStreaming` shape
overstates what a restart leaves behind (Plex reuses its id, so a later stop reaches the
same id); task 3 models that. `Finding-StopNoJoin-LateStart` therefore has no restarts.

## What is abstracted, and why

- **Replacement order.** The prior session's stop is sent in the synchronous part of the
  restart and the task waits for it (Emby's shape). Plex sends it from inside the task, and
  Jellyfin replaces first; those are tasks 3 and 5. When the stop is unconfirmed the task goes
  on, as Plex does; Emby's `priorSessionStopUnconfirmed` is task 4.
- **Detach on restart.** The item is detached in the synchronous part, as `reopenRemoteStream`
  does. A Plex in-place restart stops first and detaches after, so `DetachBeforeStop` holds for
  restarts here by this choice. The property is claimed for `stop()` and `surfaceFailure` only.
- **Session ids.** Every start gets an id the server has not used, picked by a fixed choice
  instead of every permutation. `OneEncoder` and `NoWrongKill` are not checked: with the order
  abstracted they say nothing, and they belong to the backend modules.
- **Time.** The budget is one burst window with no cooldown: a `.deferred` answer only re-arms
  the same timer. The seek hold's 12-second deadline is an action that can always fire. The
  watchdogs fire whenever their guards hold.
- **The seek hold.** One generation per MainActor run, where the Swift bumps it once per
  `setSeeking(true)`. Every restart re-arms the hold, as `reopenRemoteStream` does; a Plex
  restart that is not a seek does not.
- **The seek budget.** Every rebuild seek goes through `FinalTargetRebuildPolicy`, as on Plex.
  MediaBrowser seeks call `reopenRemoteStream` from the settle timer and are not budgeted.
- **A native seek** clears the recorded target. The Swift leaves it, but nothing reads it
  before the next seek or reset overwrites it.
- **`start()`** bumps the generation once; on Plex `beginStreaming` bumps it again in the
  same MainActor run.
- **The startup-deadline retry** stops the prior session like any restart. On Plex it
  deliberately does not (`stoppingPreviousTranscode: false`); task 3.
- **Left out:** the video-transcode consent boundary, Emby's copy fallback and copy reopen
  retry, the direct-play fallback, the deferred Jellyfin stop, the Emby stop barrier and
  transaction tail, timeline reporting, `upNextTask`, and `ServerRecreate`. The reconnect,
  preparation and Dolby Vision watchdogs are folded into `Fail`.

## Bounds

- One controller. `SessionIds` bounds the tasks ever started (one id each); `MaxGeneration`
  bounds `playbackGeneration` and the hold generation. A restart needs room for its own bump and
  its `load()`, so a running task can always attach.
- `MaxUserActions` bounds seeks, quality changes, pauses and Retry taps together. Close is
  always available once.
- `RestartBudget` is `SeekRestartBudget.burstLimit` (5 in the app, 1 here). `AbrRungs` is the
  number of rungs below the user's cap.
- `UserSeeks`, `UserPauses`, `ResumeSeeks`, `UsesProxy`, `EnvFails` and `AutoRecovery` switch
  parts of the model off so a config can go deeper elsewhere.

## Properties

| Property | Kind | Meaning |
| --- | --- | --- |
| `GenerationFencing` | invariant | Only the current task attaches, and an attached item has no restart behind it. |
| `SeekHoldFencing` | invariant | A seek completion releases only the hold it was issued for. |
| `BoundedRestarts` | action property | Seek rebuilds since the budget was last reset never exceed `RestartBudget`, and restarts in a row with no user action never exceed `AutoRestartBound`. |
| `PauseIntent` | invariant | The player never plays against the user's pause, a resume-seek completion resumes only its own current item, and only the user changes the pause intent (Retry keeps it). |
| `DetachBeforeStop` | invariant | No stop is on the wire for the session an attached item plays from. |
| `ProxyOwnership` | invariant | Every listener is the one in the slot or is being stopped, and the slot is empty after Close and while a failure shows. **Violated by the code (suspect 1).** |
| `ProxyOwnershipOutsideYieldRace` | invariant | The same, unless a task was cancelled while suspended at `await oldProxy.stop`. This is what the code keeps. |
| `NoOrphans` | invariant | Every session a request created is the one playing, has had a stop sent, or is held by a task that will attach or stop it; and Retry restarts only after `pendingStopTasks` is joined. |
| `JoinCoversCleanup` | invariant | Once `waitForPendingStopRequests` would return after Close, or after a failure with no restart under way, no task can still reach the server and every session has had a stop sent. **Violated by the code (suspect 4).** |
| `SeekIntentSurvivesAttach` | invariant | A recorded seek target always has a current settle timer or a running rebuild to act on it. **Violated by the code.** |
| `CloseCleansUp` | liveness | After Close every task returns, the joined cleanup ends and every session has had a stop sent. |
| `AbandonedSessionStopped` | liveness | A session that is not the one playing gets a stop. |
| `SeekHoldReleased` | liveness | A held scrubber is released. |
| `RetryJoinEnds` | liveness | The wait of a retry task that is still current ends. |
| `RetryRuns` | liveness | Every retry task ends, so Retry can be tapped again. **Violated by the code.** |

`BoundedRestarts` counts with two ghost counters instead of a liveness formula. With bounded
generations every behaviour restarts finitely often, so "eventually no more restarts" could
not fail; a count can. `AutoRestartBound` is exact: `Current-AutoRecovery` passes with 4 and is
violated with 3 (stall downshift, upshift, startup-deadline retry, downshift, startup-deadline
retry).

"A stop was sent" is the judgement the design uses: a stop that fails still counts.

## Configs and results

2026-11-25, tla2tools v1.7.4, `TLC_WORKERS=auto TLC_HEAP=4g` on 30 cores. Unless noted: one
controller, three sessions, `MaxGeneration = 6`, two user actions, `RestartBudget = 1`, both
cleanup shapes `TRUE`, proxies and failures on, automatic recovery off.

| Config | Expect | Result | Distinct states | Time |
| --- | --- | --- | --- | --- |
| `Current-AutoRecovery` | pass | pass | 4,463,294 | 33 s |
| `Current-CancelPastCheck` | pass | pass | 26,436,637 | 119 s |
| `Current-Core` | pass | pass | 12,407,383 | 46 s |
| `Current-RetryRetry` | pass | pass | 811,768 | 4 s |
| `Liveness-Core` | pass | pass | 390,437 | 49 s |
| `Liveness-Proxy` | pass | pass | 74,024 | 8 s |
| `Faithful-DetachBeforeStop-off` | `DetachBeforeStop` violated | violated | stops at first error | 1 s |
| `Mutant-AttachUnfenced` | `GenerationFencing` violated | violated | stops at first error | 1 s |
| `Mutant-BudgetNotEnforced` | `BoundedRestarts` violated | violated | stops at first error | 2 s |
| `Mutant-CleanupKeepsProxy` | `ProxyOwnershipOutsideYieldRace` violated | violated | stops at first error | 1 s |
| `Mutant-CloseSkipsFinalStop` | `NoOrphans` violated | violated | stops at first error | 1 s |
| `Mutant-ResumeUnguarded` | `PauseIntent` violated | violated | stops at first error | 1 s |
| `Mutant-RetryDropsPause` | `PauseIntent` violated | violated | stops at first error | 1 s |
| `Mutant-RetrySkipsJoin` | `NoOrphans` violated | violated | stops at first error | 1 s |
| `Mutant-SeekClearUnfenced` | `SeekHoldFencing` violated | violated | stops at first error | 1 s |
| `Mutant-StartupRetryRearms` | `BoundedRestarts` violated | violated | stops at first error | 1 s |
| `Finding-ProxyAfterCleanup` | `ProxyOwnership` violated | violated | stops at first error | 2 s |
| `Finding-RestartAfterFailureSkipsFinalStop` | `NoOrphans` violated | violated | stops at first error | 2 s |
| `Finding-RetryWedgedByAttach` | `RetryRuns` (temporal) violated | violated | stops at first error | 3 s |
| `Finding-SeekDroppedByAttach` | `SeekIntentSurvivesAttach` violated | violated | stops at first error | 1 s |
| `Finding-StopNoJoin` | `JoinCoversCleanup` violated | violated | stops at first error | 1 s |
| `Finding-StopNoJoin-LateStart` | `NoOrphans` violated | violated | stops at first error | 1 s |
| `Proposed-ControllerLatch` | pass | pass | 10,757,842 | 41 s |
| `Proposed-Fixes` | pass | pass | 10,816,726 | 40 s |
| `Proposed-Liveness` | pass | pass | 374,859 | 48 s |

- `Current-Core` checks `TypeOK`, `GenerationFencing`, `SeekHoldFencing`, `PauseIntent`,
  `DetachBeforeStop`, `ProxyOwnershipOutsideYieldRace`, `NoOrphans` and `BoundedRestarts`, and
  so do the other `Current` configs.
- `Current-AutoRecovery`: the watchdogs and adaptive bitrate with one rung, six sessions,
  `MaxGeneration = 12`, no user, proxies, failures or resume seeks.
- `Current-CancelPastCheck` (review focus 1): four sessions and three quality changes with
  proxies, no seeks, pauses, failures or resume seeks. Up to three tasks unwind at once, each
  cancelled at any await, and one cancelled at `oldProxyStop` goes on to write the slot.
- `Current-RetryRetry` (review focus 5): three Retry or quality actions with failures,
  `MaxGeneration = 8`, no proxies, seeks, pauses or resume seeks.
- `Liveness-Core`: two Retry or quality actions, no proxies or seeks. `Liveness-Proxy`: one
  user action over two sessions with everything on.
- `Proposed-Fixes` and `Proposed-ControllerLatch` check the full `ProxyOwnership`,
  `JoinCoversCleanup` and `SeekIntentSurvivesAttach` beside the rest; `Proposed-Liveness`
  checks the full `RetryRuns`.

How the `Current` configs are scoped around the findings: each finding breaks one property and
leaves the rest of the model as it was, so the `Current` configs keep the behaviour and check
what the code does keep. For suspect 1 that is `ProxyOwnershipOutsideYieldRace`, which pins the
defect to the one yield. For the others the broken property is left to its `Finding` and
`Proposed` configs.

### Faithfulness and mutants

| Config | Flips | Violates | Trace |
| --- | --- | --- | --- |
| `Faithful-DetachBeforeStop-off` | `StopDetachesFirst` | `DetachBeforeStop` | Close sends the stop while the item is still attached (the order before #327). |
| `Mutant-AttachUnfenced` | `AttachChecksGeneration` | `GenerationFencing` | Close cancels the task; its request lands and it attaches all the same. |
| `Mutant-SeekClearUnfenced` | `SeekClearChecksGeneration` | `SeekHoldFencing` | A native seek's completion releases the hold a later restart re-armed. |
| `Mutant-ResumeUnguarded` | `ResumeSeekGuarded` | `PauseIntent` | The user pauses before the item attaches; its resume seek completes and plays. |
| `Mutant-RetryDropsPause` | `RetryPreservesPause` | `PauseIntent` | Pause, fail, Retry: the controller's pause flag no longer matches what the user asked. |
| `Mutant-StartupRetryRearms` | `StartupRetryOneShot` | `BoundedRestarts` | Two startup-deadline retries in a row with no rung to re-arm the first. |
| `Mutant-BudgetNotEnforced` | `EscalateOnExhaustedBudget` | `BoundedRestarts` | A second seek rebuild on a budget of one. |
| `Mutant-CleanupKeepsProxy` | `CleanupClearsProxySlot` | `ProxyOwnershipOutsideYieldRace` | Close leaves the proxy in the slot. |
| `Mutant-CloseSkipsFinalStop` | `CloseSendsFinalStop` | `NoOrphans` | Close with a session playing and no stop. |
| `Mutant-RetrySkipsJoin` | `RetryJoinsPendingStops` | `NoOrphans` | Retry restarts while the failed attempt's task is still unwinding. |

`ProxyOwnership`, `JoinCoversCleanup`, `SeekIntentSurvivesAttach` and `RetryRuns` are violated
by the code as it stands; their `Finding` configs are the proof they can fail and the
`Proposed` configs the proof they can hold. `CloseCleansUp` was checked once with
`RejectedResultStopped = FALSE` and `Liveness-Proxy`'s constants, and is violated.
`AbandonedSessionStopped`, `SeekHoldReleased` and `RetryJoinEnds` have no failing run.

### Every branch is taken

The module ends with witnesses, each the negation of a state one branch reaches. Checked as
the only invariant with `Current-Core`'s constants, each is violated: `NeverTwoUnwinding`,
`NeverYieldRace`, `NeverRejectWait`, `NeverOwnProxyStopped`, `NeverLateStopPassed`,
`NeverRetryWaits`, `NeverRestartFromFailure`, `NeverStaleSettle`, `NeverAlreadyRebuilding`,
`NeverTailRearms`, `NeverBudgetExhausted`, `NeverResumeFenced`, `NeverSeekFenced`. No config
lists them; to repeat one, copy `Current-Core.cfg`, replace its `INVARIANTS` and `PROPERTIES`
with the witness and run TLC.

## Findings

Line numbers are `PlaybackController.swift` at the commit this model was written against.
Traces are the shortest TLC finds with one worker.

### Suspect 1, reproduced: a proxy installed after cleanup (`Finding-ProxyAfterCleanup`)

`ProxyOwnership` is violated in 13 states.

| Step | Model | Swift |
| --- | --- | --- |
| 1 to 4 | `Start`, `NegotiateLands`, `TaskResume`, `ProxyStandUp`: the first item plays through proxy 1, which is in the slot | `startStreaming` 3128 to 3137, or `prepareRemoteStreamURL` 3466 to 3476, with an empty slot |
| 5 to 10 | `UserQuality`, the prior stop is answered, `TaskStopWaitDone`, `NegotiateLands`, `TaskResume`, `ProxyStandUp`: the replacement stands up proxy 3, finds proxy 1 in the slot and suspends | `await oldProxy.stop(generation: oldGeneration)` at 3134 (also 3105 and 3473) |
| 11 | `Close`: the generation is bumped, the task cancelled, proxy 1 taken out of the slot and its stop queued | `stop()` 1158, 1181, 1188 to 1191 |
| 12 | `ProxyInstall`: the task resumes and writes proxy 3 into the slot. Its next check fails and it leaves | `remoteHLSProxy = proxy` at 3136 with no check since 3129; the check at 3157 returns. On the MediaBrowser path 3475, then `acceptsReopenResult` in the caller |

The controller is closed and `remoteHLSProxy` holds a listening proxy that nothing will stop.
`surfaceFailure` in place of `stop()` gives the same trace (5153, 5169 to 5172); the listener
then lives until a later restart happens to stand up another proxy. `MediaSessionProxy` and
`LoopbackOrigin` have no `deinit`, so nothing in the app stops the listener when the controller
goes away.

The window is the hop to the proxy actor and back, which is short: `MediaSessionProxy.stop`
does no I/O. It opens only on a restart that stands up a proxy while one is installed (a
second Dolby Vision injection session on Plex, a second deep-seek reopen on MediaBrowser), and
it needs `stop()` or `surfaceFailure` to be the next MainActor job.

A second way to the same leak needs no cleanup: two tasks both suspended at the yield for the
same old proxy, the cancelled one resuming first. Each writes the slot and the first write is
lost. It needs a whole restart to fit inside one actor hop, so it is far less likely.
`ProxyOwnershipOutsideYieldRace` covers both: with no task cancelled at the yield, the full
property holds.

Proposed fix (`FixProxyRecheck`, checked by `Proposed-Fixes`): re-check the generation after
`await oldProxy.stop` and stop the new proxy instead of installing it.

### Suspect 4, reproduced: `stop()` does not join the cancelled task (`Finding-StopNoJoin`)

`JoinCoversCleanup` is violated in 3 states.

| Step | Model | Swift |
| --- | --- | --- |
| 1 | `Start`: the task's request is on the wire | `beginStreaming` 2715, `beginRemoteStream` 3239, `reopenRemoteStream` 5808 |
| 2 | `Close`: the task is cancelled and dropped; nothing is appended to `pendingStopTasks` for it | `playbackTask?.cancel(); playbackTask = nil` at 1181 to 1182. `surfaceFailure` appends `Task { await task.value }` at 5155 to 5158 |

`waitForPendingStopRequests` (1236) would now return, and the request can still create a
session. On the `reopenRemoteStream` path the cancelled task then stops that session itself
(`stopRejectedRemoteStream`, 5844 and 5859), after the join has returned.

The same property fails after a surfaced failure, in 4 states: `Start`, `UserQuality` (the
first task is cancelled with its request on the wire), `NegotiateFails`. `surfaceFailure` joins
only the task that was current. A task an earlier restart cancelled (2707, 5766) is joined by
nobody, so `retry()` (2580) can restart while that task's request or rejected-result cleanup is
still outstanding. Emby's transaction tail orders reopen tasks; Jellyfin has nothing in its
place, and task 5 should check this with a reused session id.

Proposed fix (`FixJoinCancelledTasks`): append `await task.value` to `pendingStopTasks`
wherever `playbackTask` is cancelled.

### Suspect 4, the `startStreaming` shape: a start that lands after the final stop (`Finding-StopNoJoin-LateStart`)

`NoOrphans` is violated in 5 states with `RejectedResultStopped = FALSE`.

| Step | Model | Swift |
| --- | --- | --- |
| 1 | `Start`: a request that starts a session is on the wire | `startStreaming`: the `start.m3u8` fetch at 2999 or the prewarm at 3040, both on the Original lane only |
| 2 | `Close` | `stop()`: `sendTranscodeStop` at 1202 |
| 3 | `NegotiateLands`: the server acts on the start after the stop | |
| 4 | `TaskResume`: the cancelled task returns at its check | 3001 or 3043 |

The session has no stop and no task holds it. Joining the task would not help: the final stop
has already gone. Cancelling the Swift task cancels the URL request, so the window is one
request the server has already read. Whether Plex then keeps a transcoder running is for task 3
to judge; this module shows only that nothing in the controller would stop it.

### New: a seek made during a restart is dropped (`Finding-SeekDroppedByAttach`)

`SeekIntentSurvivesAttach` is violated in 5 states.

| Step | Model | Swift |
| --- | --- | --- |
| 1 | `Start` (any start or restart): generation G, no item yet | `beginStreaming` 2712, `reopenRemoteStream` 5767 |
| 2 | `UserSeek`, out of the buffer: the target is recorded and the settle timer captures G | `performUserSeek` 2646, `scheduleFinalTargetRebuild` 5673 to 5676 |
| 3, 4 | `NegotiateLands`, `TaskResume` and `Attach`: `load()` bumps the generation to G+1 | `load` 3795 |

The settle timer wakes 500 ms after the seek, fails `isCurrentPlaybackLifecycle(G)` and returns
(5682). The comment above it says a cancelled timer leaves the hold "to the new owner", but this
timer was not cancelled and there is no new owner: `load()` neither cancels nor re-arms it. The
new item plays from the old position with the scrubber held on the target until the item
reaches it or the 12-second ceiling passes. The exception is a seek made during a final-target
rebuild on Plex, which the task's tail picks up (2720 to 2728).

It needs a seek committed in the 500 ms before a start or restart reaches `load()`.

Proposed fix (`FixSettleSurvivesAttach`): `load()` re-arms a pending settle under the new
generation, or the timer captures the seek instead of the playback generation.

### New: Retry is dead after a restart from a failure overtakes it (`Finding-RetryWedgedByAttach`)

`RetryRuns` is violated: the behaviour ends with `retryGen` set for ever.

| Step | Model | Swift |
| --- | --- | --- |
| 1, 2 | `Start`, `NegotiateFails`: a failure shows | `surfaceFailure` 5133 |
| 3 | `UserQuality`: a restart from the failure. The error stays up: only `explicitRetry` clears it | `reload` 2470, `restartAtCurrentPosition` 5710; `PlaybackRestartIntent.plan` |
| 4 | `Retry`, while the error still shows: the retry task captures generation G and waits for the join | `retry()` 2567, 2575 to 2580 |
| 5, 6 | `NegotiateLands`, `TaskResume` and `Attach`: `load()` bumps the generation and clears the error | 3795, 3816 |
| 7 | `Fail`: a failure shows again, and `failureRetryTask` is still set | `surfaceFailure` |

When its join ends the retry task fails `playbackGeneration == generation` and returns (2581)
without reaching `self.failureRetryTask = nil` (2582). `retry()` requires
`failureRetryTask == nil` (2567), so after the next failure the Retry button does nothing. A
quality or track change (5713 to 5714) or Close clears it.

It needs the join to outlast the restart: a stop request still hanging when the restarted
stream loads, which is the dead-connection case Retry exists for. The failure message itself
suggests lowering the quality.

Proposed fix (`FixRetryBailClearsTask`): clear `failureRetryTask` on the bail path.

### New: no final stop after a restart from a failure (`Finding-RestartAfterFailureSkipsFinalStop`)

`NoOrphans` is violated in 7 states with `StopLatchPerSession = FALSE`, the Plex latch.

| Step | Model | Swift |
| --- | --- | --- |
| 1, 2 | `Start`, `Fail` | `surfaceFailure` calls `sendTranscodeStop` (5177), which sets `sentTranscodeStop` (1290) |
| 3 | `UserQuality`: a restart from the failure | `reload` 2470 has no failure guard; `restartAtCurrentPosition` 5710 does not touch the latch. Only `retry()` clears it (2583) |
| 4, 5 | `NegotiateLands`, `Attach`: a new session plays | `startStreaming`, `load` |
| 6 | `Close`: no stop | `sendTranscodeStop` returns at `!sentTranscodeStop` (1289) |

The transcode runs until the server reaps it. A second failure in place of Close has the same
result: `surfaceFailure` sends no stop either. MediaBrowser is not affected: `didStop` is
cleared when a reopen is accepted (5888).

Proposed fix (`FixRestartResetsStopLatch`, checked by `Proposed-ControllerLatch`): clear the
latch on every restart, or when a start is accepted.

## Observations that are not findings

- The restart budget is reset by restarts the user did not ask for: the adaptive-bitrate plan
  includes `resetFinalTarget`, and `attemptStartupDeadlineRetry` calls
  `finalTargetRebuildPolicy.reset()`. `SeekRestartBudget`'s comment says reset is for explicit
  user intent. Unattended restarts stay bounded because the rungs and the one-shot are.
- MediaBrowser seek reopens bypass `FinalTargetRebuildPolicy`, so nothing budgets them.
- While a failure shows and a quality change is restarting, `surfaceFailure` is a no-op
  (its `guard !playbackError.isFailed`): a second failure of that restart ends the task and
  leaves the first failure's overlay up. The user still has Retry.

## For the backend modules

- This module does not check `OneEncoder`, `NoWrongKill` or `StopNeverKillsSuccessor`. With a
  cancelled task's request still on the wire, the core has two sessions at once (the rejected
  one and its successor) on every backend that does not chain its tasks.
- `Terminal(c, inTask, join, send)` is the shape of `stop()` and `surfaceFailure`;
  `RestartCore(c, rb)` the shape of a restart. A backend module copies the parts it needs: no
  module imports this one.
- The task record adds `inc`, `px`, `old` and `rb` to the base's `Task(g, pc, s)`. The base
  operators (`UnwindingAfterCancel`, `TaskRuns`, `TicketDone`) read only `gen`.
- Open questions handed on: the `startStreaming` late start (task 3), the unjoined rejected
  cleanup with a reused id (task 5), and whether Emby's transaction tail closes the same gap
  (task 4).
