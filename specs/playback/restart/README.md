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

The model reproduces suspect 1 and suspect 4, and found five defects nobody had named (two of
them from the second independent review: a cancelled reopen that loses its answer, and an
unattended restart that resets the seek budget). Each has a `Finding-*` config and a trace
below. A review read each against the Swift and found it plausible; none has been reproduced
in the app. One is fixed: Retry wedged by a restart from a failure (#526) is now
`Faithful-RetryWedgedByAttach-off`, and its fix constant `FixRetryBailClearsTask` is `TRUE` in
every other config.

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
| `TaskResume`, `TaskUnwindExit` | the `guard !Task.isCancelled, generation == playbackGeneration` checks of `startStreaming`; `RemoteStreamLifecyclePolicy.acceptsReopenResult` (`PMSKit/Sources/PMSKit/RemoteStreamLifecyclePolicy.swift`) in `reopenRemoteStream` |
| `NegotiatedLost` | a cancelled `reopenRemoteStream` task whose request the server already acted on: `try await remoteStreamReopener` (5839) throws `CancellationError`, and the `catch` returns at `acceptsReopenResult` (5903 to 5907) without a stop |
| `Attach` | `load(_:resumeOffsetMs:)`, and the tail of the task in `beginStreaming` |
| `Reject`, `TaskRejectDone` | `stopRejectedRemoteStream`, which waits through `stopAndWaitIgnoringCancellation` (`Labstream/Shared/Player/PlaybackSessionSource.swift`), or the bare `return` of `startStreaming` |
| `ProxyStandUp`, `ProxyInstall`, `ProxyOwnStopped` | the proxy stand-up in `startStreaming` and `prepareRemoteStreamURL`, split at `await oldProxy.stop(generation:)` |
| `ProxyStopRuns` | a `pendingStopTasks` entry running `proxy.stop(generation:)` |
| `budget`, `pendingTarget`, `RebuildActive` | `SeekRestartBudget` (`SeekRestartBudget.swift`), `FinalTargetRebuildPolicy.pendingOffsetMs` and `activeGeneration` (`FinalTargetRebuildPolicy.swift`) |
| `rung`, `abrLeft` | `AdaptiveBitratePolicy` (`PMSKit/Sources/PMSKit/Transcode/AdaptiveBitratePolicy.swift`): the rungs below the cap, and the changes `maxChangesPerWindow` still allows (`canChange`, 163 to 170). `reload` (2478) and `explicitRetry` (5727) reset it |
| `cur.stopped`, `StopLatchPerSession` | `MediaBrowserPlaybackSession.didStop` (`PlaybackSessionSource.swift` 144); `RemoteStreamLifecyclePolicy.finalSessionStopDecision` |

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

The `Current` and `Liveness` configs use `TRUE` for both, except
`Current-StartStreamingShape`, which uses `FALSE` for both. The `FALSE` shapes also appear in
`Finding-StopNoJoin-LateStart`, `Finding-RestartAfterFailureSkipsFinalStop` and
`Proposed-ControllerLatch`. With a fresh session id per start, the `startStreaming` shape
overstates what a restart leaves behind (Plex reuses its id, so a later stop reaches the
same id); task 3 models that. `Finding-StopNoJoin-LateStart` therefore has no restarts.

### A cancelled request loses its answer

`CancelDropsAnswer` (shipping `TRUE`) adds `NegotiatedLost`: a cancelled restart task at
`negotiated` may return with no stop, because cancelling `playbackTask` cancelled its URLSession
request after the server had acted on it. Before the second review the model always delivered
the answer, so `NoOrphans` in `Current-Core` and `JoinCoversCleanup` in `Proposed-Fixes` held
only because of that assumption. The action is gated on `RejectedResultStopped` (the
`startStreaming` shape already drops a rejected result) and on a restart's task: `start()`'s
task on MediaBrowser is `beginRemoteStream`, whose session the launcher negotiated.

The configs are scoped around it the way the module already scopes suspect 1:

- `Current` configs, `Faithful`, `Mutant` and safety `Finding` configs run with `TRUE`. Where
  they checked `NoOrphans` they now check `NoOrphansOutsideLostAnswer`, which excuses only a
  session marked `lostAnswer` and holds every other session in the same behaviour to the full
  property. `Finding-CancelledReopenLosesAnswer` checks the full `NoOrphans`.
- `Proposed` configs run with `FALSE`: that is the proposed fix (the request does not inherit
  cancellation and the rejected result is stopped). `Finding-CancelledReopenLosesAnswer-JoinFix`
  shows the #525 fix alone does not close it.
- `Liveness-Core` and `Liveness-Proxy` run with `TRUE`, the shipping behaviour. The lost
  session is never stopped, so `AbandonedSessionStopped` and `CloseCleansUpOutsideYieldRace`
  fail for that reason alone (checked: `Liveness-Core` with `TRUE` violates both). These two
  configs check instead `CloseCleansUpOutsideRaceAndLost` and
  `AbandonedSessionStoppedOutsideLost`, which excuse only `LostAnswer(c)` sessions and hold
  every other session to the full property. The other temporal configs
  (`Finding-ProxyAfterCleanup-Liveness`, `Faithful-RetryWedgedByAttach-off`, `Proposed-Liveness*`)
  run with `FALSE`. The two liveness findings carry over to `TRUE`: `NegotiatedLost` only adds behaviours, and it is
  enabled only where `TaskResume` also is, so a violating fair behaviour stays fair.

## What is abstracted, and why

- **Replacement order.** The prior session's stop is sent in the synchronous part of the
  restart and the task waits for it (Emby's shape). Plex sends it from inside the task, and
  Jellyfin replaces first; those are tasks 3 and 5. When the stop is unconfirmed the task goes
  on, as Plex does; Emby's `priorSessionStopUnconfirmed` is task 4.
- **Detach on restart.** The item is detached in the synchronous part, as `reopenRemoteStream`
  does. A Plex in-place restart stops first and detaches after, so `DetachBeforeStop` holds for
  restarts here by this choice. The property is claimed for `stop()` and `surfaceFailure` only.
  The second half of `GenerationFencing` (an attached item has no task behind it) depends on
  the same choice: a Plex in-place restart keeps the old item attached while its task waits
  for the prior stop. Task 3 must not inherit either statement.
- **Session ids.** Every start gets an id the server has not used, picked by a fixed choice
  instead of every permutation. `NegotiateLands` reads `Latest(s)` through `FreshIds` to do
  that. This is the server choosing the id it mints, not a client guard reading the server. `OneEncoder` and `NoWrongKill` are not checked: with the order
  abstracted they say nothing, and they belong to the backend modules.
- **Adaptive bitrate.** A downshift or upshift needs a change left in
  `AdaptiveBitratePolicy`'s window (`maxChangesPerWindow`, 4 in 600 s in the app; `AbrMaxChanges`
  here, with the window never expiring). An upshift is not user intent: it does not restart the
  count of unattended restarts. Only `reload` and `explicitRetry` reset the policy; the model
  also resets it on track changes (one `UserQuality` action covers both), which only adds
  resets, so the bound stays sound. Real upshifts also wait 180 s after a downshift and want
  120 s of healthy playback (23 and 36 to 37); the model leaves time out.
- **Time.** The budget is one burst window with no cooldown: a `.deferred` answer only re-arms
  the same timer. `BoundedRestarts` is therefore a bound per window. The seek hold's 12-second deadline is an action that can always fire. The
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
- **Final-stop tickets.** `FinalStopTickets` joins every stop in flight for `cur`, which is
  Emby's (`beginFinalStop` joins the barrier) and Plex's (the stop is re-sent under the same
  id). Jellyfin's deferred prior stop is untracked (5929 to 5940), so the results for the
  MediaBrowser shape here are Emby results, not Jellyfin results; `../jellyfin` covers that.
- **The prior session's stop of a restart is not ticketed.** After `TaskStopWaitDone` on a
  `late` stop and an attach, that stop can still be on the wire when the join returns, and
  `JoinCoversCleanup` asks only that a stop was sent. The Swift cancels that stop on Plex
  (`stopPreviousTranscode`'s `group.cancelAll()`) and blocks on it on Emby, so the model's
  late-then-proceed branch matches neither backend exactly; the backend modules own the order.
- **`ProxyInstall` treats the awaited `oldProxy.stop` as stopping the listener at once**
  (`oldGone`). `../proxy` shows `stop` only queues the listener cancel on the origin's queue
  (#533), so a listener can outlive the await briefly. The composition assumes that queue
  drains; the restart properties do not depend on how soon.
- **Close before Start is not modelled.** `Start` needs `life = "new"` and `Close` needs
  `"open"`. Swift `start()` guards only `!started`, so a `stop()` that came first would not
  stop a later `start()`. Whether the UI can do this is not checked here; adding it is not a
  one-line change because the model would need a closed-but-startable state.
- **Left out:** the video-transcode consent boundary, Emby's copy fallback and copy reopen
  retry, the direct-play fallback, the deferred Jellyfin stop, the Emby stop barrier and
  transaction tail, timeline reporting, `upNextTask`, and `ServerRecreate`. The reconnect,
  preparation and Dolby Vision watchdogs are folded into `Fail`.

## Bounds

- One controller. `SessionIds` bounds the tasks ever started (one id each); `MaxGeneration`
  bounds `playbackGeneration` and the hold generation. A restart reserves `RestartRoom = 3`
  generations: its own bump, its `load()`, and one for a Close or failure after it; a failure
  keeps one for the Close after it. So a running task can always attach and an open
  controller can always close (`CloseStaysEnabled`, checked in every `Current` and `Proposed`
  safety config). Round 1 reserved two, which left no generation for Close after the last
  attach the bound allowed and pruned every Close behind it (`Mutant-RestartRoomTwo`). Every
  config's `MaxGeneration` went up by one to keep the same number of restarts.
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
| `BoundedRestarts` | action property | Seek rebuilds since the last explicit user intent (Retry, a quality or track change, Close: `SeekRestartBudget.swift` 17) never exceed `RestartBudget`, and restarts in a row with no user action never exceed `AutoRestartBound`. **Violated by the code once automatic recovery and seeks are both on** (`Finding-UnattendedRestartResetsSeekBudget`). |
| `PauseIntent` | invariant | The player never plays against the user's pause, a resume-seek completion resumes only its own current item, and only the user changes the pause intent (Retry keeps it). |
| `DetachBeforeStop` | invariant | No stop is on the wire for the session an attached item plays from. |
| `ProxyOwnership` | invariant | Every listener is the one in the slot or is being stopped, and the slot is empty after Close and while a failure shows. **Violated by the code (suspect 1).** |
| `ProxyOwnershipOutsideYieldRace` | invariant | The same for every listener except those the yield race touched (`Raced(c)`): a proxy whose task was cancelled while suspended at `await oldProxy.stop`, and a proxy that task's late write pushed out of the slot. Every other listener in the same behaviour is still held to the full property. This is what the code keeps. |
| `NoOrphans` | invariant | Every session a request created is the one playing, has had a stop sent, or is held by a task that will attach or stop it; and Retry restarts only after `pendingStopTasks` is joined. **Violated by the code** (`Finding-CancelledReopenLosesAnswer`). |
| `NoOrphansOutsideLostAnswer` | invariant | The same for every session but one a cancelled task lost the answer for (`LostAnswer(c)`). This is what the code keeps. |
| `CloseStaysEnabled` | invariant | An open controller always has a generation for Close. A check of the bound, not of the code. |
| `JoinCoversCleanup` | invariant | Once `waitForPendingStopRequests` would return after Close, or after a failure with no restart under way, no task can still reach the server and every session has had a stop sent. **Violated by the code (suspect 4).** |
| `SeekIntentSurvivesAttach` | invariant | A recorded seek target always has a current settle timer or a running rebuild to act on it. **Violated by the code.** |
| `CloseCleansUp` | liveness | After Close every task returns, the joined cleanup ends, every session has had a stop sent and no listener is left. **Violated by the code with proxies (suspect 1).** |
| `CloseCleansUpOutsideYieldRace` | liveness | The same, but a listener in `Raced(c)` may be left. This is what the code keeps. |
| `AbandonedSessionStopped` | liveness | A session that is not the one playing gets a stop. |
| `CloseCleansUpOutsideRaceAndLost`, `AbandonedSessionStoppedOutsideLost` | liveness | `CloseCleansUpOutsideYieldRace` and `AbandonedSessionStopped` excusing also a session in `LostAnswer(c)`. This is what the code keeps. |
| `SeekHoldReleased` | liveness | A held scrubber is released. Holds by construction (the ceiling is always enabled while held, under weak fairness); a check of the model. |
| `RetryJoinEnds` | liveness | The wait of a retry task that is still current ends. Implied by `RetryRuns`. |
| `RetryRuns` | liveness | Every retry task ends, so Retry can be tapped again. Held by the code since #526; violated with `FixRetryBailClearsTask = FALSE` (`Faithful-RetryWedgedByAttach-off`). |

`BoundedRestarts` counts with two ghost counters instead of a liveness formula. With bounded
generations every behaviour restarts finitely often, so "eventually no more restarts" could
not fail; a count can. Each ghost is tied to a documented contract, not to the code's own reset
points: `seekRun` resets only on explicit user intent, as `SeekRestartBudget`'s comment says,
and `autoRun` resets only on a user action. An upshift no longer resets `autoRun` (round 1 did,
which made the bound hold only between upshifts); stall/upshift cycles are bounded by
`AdaptiveBitratePolicy`'s change window instead. `AutoRestartBound` is exact: with one rung and
`AbrMaxChanges = 2`, `Current-AutoRecovery` passes with 5 and is violated with 4 (startup-deadline
retry, stall downshift, startup-deadline retry, upshift, startup-deadline retry: every
adaptive-bitrate restart re-arms the one-shot, so the bound is `1 + 2 * AbrMaxChanges`).

"A stop was sent" is the judgement the design uses: a stop that fails still counts.

## Configs and results

2026-11-25 (round-2 fixes; rerun after the #526 fix, `FixRetryBailClearsTask = TRUE`, where the
numbers changed: `Current-RetryRetry`, `Liveness-Core` with `RetryRuns`), tla2tools v1.7.4, `TLC_WORKERS=auto TLC_HEAP=4g` on 30 cores. Unless
noted: one controller, three sessions, `MaxGeneration = 7`, `RestartRoom = 3`, two user actions,
`RestartBudget = 1`, `AbrMaxChanges = 2`, both cleanup shapes `TRUE`, `CancelDropsAnswer` as
described above, proxies and failures on, automatic recovery off.

| Config | Expect | Result | Distinct states | Time |
| --- | --- | --- | --- | --- |
| `Current-AutoRecovery` | pass | pass | 1,144,656 | 9 s |
| `Current-CancelPastCheck` | pass | pass | 33,055,192 | 151 s |
| `Current-Core` | pass | pass | 17,183,405 | 63 s |
| `Current-RetryRetry` | pass | pass | 886,650 | 9 s |
| `Current-StartStreamingShape` | pass | pass | 1,431,670 | 6 s |
| `Liveness-Core` | pass | pass | 489,095 | 144 s |
| `Liveness-Proxy` | pass | pass | 86,727 | 10 s |
| `Faithful-DetachBeforeStop-off` | `DetachBeforeStop` violated | violated | stops at first error | 1 s |
| `Faithful-RetryWedgedByAttach-off` | `RetryRuns` (temporal) violated | violated | stops at first error | 3 s |
| `Mutant-AttachUnfenced` | `GenerationFencing` violated | violated | stops at first error | 0 s |
| `Mutant-BudgetNotEnforced` | `BoundedRestarts` violated | violated | stops at first error | 1 s |
| `Mutant-CleanupKeepsProxy` | `ProxyOwnershipOutsideYieldRace` violated | violated | stops at first error | 1 s |
| `Mutant-CloseSkipsFinalStop` | `NoOrphansOutsideLostAnswer` violated | violated | stops at first error | 0 s |
| `Mutant-RestartRoomTwo` | `CloseStaysEnabled` violated | violated | stops at first error | 2 s |
| `Mutant-ResumeUnguarded` | `PauseIntent` violated | violated | stops at first error | 1 s |
| `Mutant-RetryDropsPause` | `PauseIntent` violated | violated | stops at first error | 1 s |
| `Mutant-RetrySkipsJoin` | `NoOrphansOutsideLostAnswer` violated | violated | stops at first error | 0 s |
| `Mutant-SeekClearUnfenced` | `SeekHoldFencing` violated | violated | stops at first error | 1 s |
| `Mutant-StartupRetryRearms` | `BoundedRestarts` violated | violated | stops at first error | 1 s |
| `Finding-CancelledReopenLosesAnswer` | `NoOrphans` violated | violated | stops at first error | 1 s |
| `Finding-CancelledReopenLosesAnswer-JoinFix` | `JoinCoversCleanup` violated | violated | stops at first error | 1 s |
| `Finding-ProxyAfterCleanup` | `ProxyOwnership` violated | violated | stops at first error | 4 s |
| `Finding-ProxyAfterCleanup-Liveness` | `CloseCleansUp` (temporal) violated | violated | stops at first error | 6 s |
| `Finding-RestartAfterFailureSkipsFinalStop` | `NoOrphansOutsideLostAnswer` violated | violated | stops at first error | 1 s |
| `Finding-SeekDroppedByAttach` | `SeekIntentSurvivesAttach` violated | violated | stops at first error | 0 s |
| `Finding-StopNoJoin` | `JoinCoversCleanup` violated | violated | stops at first error | 1 s |
| `Finding-StopNoJoin-LateStart` | `NoOrphans` violated | violated | stops at first error | 1 s |
| `Finding-UnattendedRestartResetsSeekBudget` | `BoundedRestarts` violated | violated | stops at first error | 1 s |
| `Proposed-ControllerLatch` | pass | pass | 14,445,349 | 54 s |
| `Proposed-Fixes` | pass | pass | 14,504,233 | 54 s |
| `Proposed-Liveness` | pass | pass | 433,849 | 62 s |
| `Proposed-LivenessProxy` | pass | pass | 84,131 | 10 s |

- `Current-Core` checks `TypeOK`, `GenerationFencing`, `SeekHoldFencing`, `PauseIntent`,
  `DetachBeforeStop`, `ProxyOwnershipOutsideYieldRace`, `NoOrphansOutsideLostAnswer`,
  `CloseStaysEnabled` and `BoundedRestarts`, and so do the other `Current` configs.
- `Current-StartStreamingShape`: `Current-Core` with both cleanup shapes `FALSE`. It checks
  everything `Current-Core` does except `NoOrphans`, which that shape breaks (the two
  findings below).
- `Current-AutoRecovery`: the watchdogs and adaptive bitrate with one rung and two changes in
  the window, six sessions, `MaxGeneration = 13`, `AutoRestartBound = 5`, no user, proxies,
  failures or resume seeks. Fewer states than round 1 (1.1 M against 4.5 M): the change window
  now bounds stall/upshift cycles that only the generation bound stopped before.
- `Current-CancelPastCheck` (review focus 1): four sessions and three quality changes with
  proxies, no seeks, pauses, failures or resume seeks. Up to three tasks unwind at once, each
  cancelled at any await, and one cancelled at `oldProxyStop` goes on to write the slot.
- `Current-RetryRetry` (review focus 5): three Retry or quality actions with failures,
  `MaxGeneration = 9`, no proxies, seeks, pauses or resume seeks.
- `Liveness-Core`: two Retry or quality actions, no proxies or seeks. `Liveness-Proxy`: one
  user action over two sessions with everything on. Both run with `CancelDropsAnswer = TRUE`
  and check `CloseCleansUpOutsideRaceAndLost`, `AbandonedSessionStoppedOutsideLost`,
  `RetryRuns` (the full property, since #526; before it they checked the weaker
  `RetryJoinEnds`) and `SeekHoldReleased`.
- `Proposed-Fixes` and `Proposed-ControllerLatch` check the full `ProxyOwnership`,
  `NoOrphans`, `JoinCoversCleanup` and `SeekIntentSurvivesAttach` beside the rest, with
  `CancelDropsAnswer = FALSE`; `Proposed-Liveness`
  checks the full `RetryRuns`, and `Proposed-LivenessProxy` the full `CloseCleansUp` with
  proxies.

How the `Current` configs are scoped around the findings: each finding breaks one property and
leaves the rest of the model as it was, so the `Current` configs keep the behaviour and check
what the code does keep. For suspect 1 that is `ProxyOwnershipOutsideYieldRace` and
`CloseCleansUpOutsideYieldRace`, which excuse only the listeners that race touched and so
pin the defect to the one yield. For the lost answer it is `NoOrphansOutsideLostAnswer`, which
excuses only the session whose answer was lost. For the others the broken property is left to its `Finding` and
`Proposed` configs.

### Faithfulness and mutants

| Config | Flips | Violates | Trace |
| --- | --- | --- | --- |
| `Faithful-DetachBeforeStop-off` | `StopDetachesFirst` | `DetachBeforeStop` | Close sends the stop while the item is still attached (the order before #327). |
| `Faithful-RetryWedgedByAttach-off` | `FixRetryBailClearsTask` | `RetryRuns` | A restart from a failure overtakes a waiting retry task, which returns with `failureRetryTask` still set (the code before #526; trace under "Fixed findings"). |
| `Mutant-AttachUnfenced` | `AttachChecksGeneration` | `GenerationFencing` | Close cancels the task; its request lands and it attaches all the same. |
| `Mutant-SeekClearUnfenced` | `SeekClearChecksGeneration` | `SeekHoldFencing` | A native seek's completion releases the hold a later restart re-armed. |
| `Mutant-ResumeUnguarded` | `ResumeSeekGuarded` | `PauseIntent` | The user pauses before the item attaches; its resume seek completes and plays. |
| `Mutant-RetryDropsPause` | `RetryPreservesPause` | `PauseIntent` | Pause, fail, Retry: the controller's pause flag no longer matches what the user asked. |
| `Mutant-StartupRetryRearms` | `StartupRetryOneShot` | `BoundedRestarts` | Two startup-deadline retries in a row with no rung to re-arm the first. |
| `Mutant-BudgetNotEnforced` | `EscalateOnExhaustedBudget` | `BoundedRestarts` | A second seek rebuild on a budget of one. |
| `Mutant-CleanupKeepsProxy` | `CleanupClearsProxySlot` | `ProxyOwnershipOutsideYieldRace` | Close leaves the proxy in the slot. |
| `Mutant-CloseSkipsFinalStop` | `CloseSendsFinalStop` | `NoOrphansOutsideLostAnswer` | Close with a session playing and no stop. |
| `Mutant-RetrySkipsJoin` | `RetryJoinsPendingStops` | `NoOrphansOutsideLostAnswer` | Retry restarts while the failed attempt's task is still unwinding. |
| `Mutant-RestartRoomTwo` | `RestartRoom` (3 to 2) | `CloseStaysEnabled` | Round 1's bound: start, fail, Retry, fail, a quality change attaches at the bound, fail; the controller is open and cannot Close. |

`ProxyOwnership`, `JoinCoversCleanup`, `SeekIntentSurvivesAttach`,
`CloseCleansUp`, `NoOrphans` and `BoundedRestarts` are violated by the code as it stands; their
`Finding` configs are the proof they can fail and the `Proposed` configs the proof they can hold
(`BoundedRestarts` has no `Proposed` config with seeks and automatic recovery together; its
`Current` configs hold it with one or the other). `NoOrphansOutsideLostAnswer` fails in
`Mutant-CloseSkipsFinalStop`, `Mutant-RetrySkipsJoin` and
`Finding-RestartAfterFailureSkipsFinalStop`; `CloseStaysEnabled` in `Mutant-RestartRoomTwo`.
`AbandonedSessionStopped` fails only through the lost answer (with `CancelDropsAnswer = TRUE`;
the `Liveness` configs check its scoped form). `RetryRuns` fails in
`Faithful-RetryWedgedByAttach-off`. `SeekHoldReleased` holds by construction and
`RetryJoinEnds` has no failing run.

### Every branch is taken

The module ends with witnesses, each the negation of a state one branch reaches. Checked as
the only invariant with `Current-Core`'s constants, each is violated: `NeverTwoUnwinding`,
`NeverYieldRace`, `NeverRejectWait`, `NeverOwnProxyStopped`, `NeverLateStopPassed`,
`NeverRetryWaits`, `NeverRestartFromFailure`, `NeverStaleSettle`, `NeverAlreadyRebuilding`,
`NeverTailRearms`, `NeverBudgetExhausted`, `NeverResumeFenced`, `NeverSeekFenced`. No config
lists them; to repeat one, copy `Current-Core.cfg`, replace its `INVARIANTS` and `PROPERTIES`
with the witness and run TLC.

## Findings

Line numbers are `PlaybackController.swift` as of commit `0b7f3fcb`, the last to change it
before this model.
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
After `stop()` nothing stops it: `MediaSessionProxy` and `LoopbackOrigin` have no `deinit`.
`surfaceFailure` in place of `stop()` gives the same trace (5153, 5169 to 5172), but that leak
heals: the proxy is in the slot, so a later `stop()` stops it (1188), and so does a later
restart that stands up another proxy. Until then a listener is up while the failure shows.

`Finding-ProxyAfterCleanup-Liveness` is the same defect as liveness: `CloseCleansUp` is
violated, because the listener is still there however long one waits.

The window is the hop to the proxy actor and back, which is short: `MediaSessionProxy.stop`
does no I/O. It opens only on a restart that stands up a proxy while one is installed (a
second Dolby Vision injection session on Plex, a second deep-seek reopen on MediaBrowser), and
it needs `stop()` or `surfaceFailure` to be the next MainActor job.

A second way to a leak needs no cleanup: two tasks suspended at the yield for the same old
proxy, one of them cancelled by the restart that started the other. Each writes the slot when
it resumes and one write is lost. If the cancelled task resumes first, its own proxy is the
one left listening. If it resumes second, it pushes the current task's proxy out of the slot:
the item then plays through a listener that Close will never stop (18 states). Either order
needs a whole restart to fit inside one actor hop, so it is far less likely than the first.

`ProxyOwnershipOutsideYieldRace` leaves out exactly the listeners that race touches: the
proxy a task had stood up when it was cancelled at the yield, and a proxy its late write
pushed out of the slot (`Raced(c)`). Every other listener, in the same behaviour, is held to
the full property, and it holds.

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
| 2 | `Close`. The model sends no stop here: `cur` is empty, as no session exists yet | `stop()` calls `sendTranscodeStop` (1202), which does send one, under the reused `sessionID`, whether or not a transcode exists (1286 to 1293) |
| 3 | `NegotiateLands`: the server acts on the start | the start lands after that stop, which found nothing to end |
| 4 | `TaskResume`: the cancelled task returns at its check | 3001 or 3043 |

The session has no stop meant for it and no task holds it. The model and the Swift differ in
step 2 only: the Swift's stop is sent and wasted, the model's is never sent. Either way
nothing is sent after the start lands, because `sentTranscodeStop` is now set. Joining the
task would not help: the final stop has already gone. Cancelling the Swift task cancels the URL request, so the window is one
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

### New (review 2): a cancelled reopen loses its answer (`Finding-CancelledReopenLosesAnswer`)

`NoOrphans` is violated in 6 states with `Current-Core`'s constants.

| Step | Model | Swift |
| --- | --- | --- |
| 1 | `Start` | `start()`, `beginRemoteStream` 3231 |
| 2 | `UserQuality`: reopen A; with no session yet it asks for one at once | `reload` 2470, `restartAtCurrentPosition` 5710, `reopenRemoteStream`: `playbackTask?.cancel()` 5766, the new task's `try await remoteStreamReopener(request)` 5839 |
| 3 | `UserQuality` again: A is cancelled with its request on the wire | 5766 |
| 4 | `NegotiateLands(A)`: the server acts on A's PlaybackInfo and mints a session | `JellyfinBrowseService.swift` 256 to 258 and `DetailPlaybackLauncher.swift` 175 to 176 say PlaybackInfo may mint an encoder |
| 5 | `NegotiatedLost(A)`: A returns with no stop | cancelling the task cancelled the URLSession request; the await throws `CancellationError`; the `catch` fails `acceptsReopenResult` and returns (5903 to 5907). `stopRejectedRemoteStream` (5844) is never reached, and the client never learns the `PlaySessionId` |

The session has no stop meant for it, no task holds it and it is not the one playing. Any
cancellation does it: a second seek-settle reopen, a quality or track change, `stop()` (1181) or
`surfaceFailure` while A's request is out. It is likeliest during repeated deep seeks on
Jellyfin or Emby. This is not #525: joining the task does not help, because the task returns
with nothing to stop (`Finding-CancelledReopenLosesAnswer-JoinFix`, below).

`Finding-CancelledReopenLosesAnswer-JoinFix`: `Proposed-Fixes`' constants with
`CancelDropsAnswer = TRUE`. `JoinCoversCleanup` is violated in 7 states: `Start`, `UserQuality`
(reopen A), `Close` (A is cancelled and, with `FixJoinCancelledTasks`, joined), the start task
unwinds, `NegotiateLands(A)`, `NegotiatedLost(A)`. A's join ticket is done, so
`waitForPendingStopRequests` returns with A's session alive.

Proposed fix (`CancelDropsAnswer = FALSE`, checked by every `Proposed` config): run the
PlaybackInfo call without inheriting cancellation (an unstructured Task that is awaited, as
`stopAndWaitIgnoringCancellation` does) and, once the answer arrives, reject and stop it.

### New (review 2): an unattended restart resets the seek budget (`Finding-UnattendedRestartResetsSeekBudget`)

`BoundedRestarts` is violated in 9 states: seeks and automatic recovery on, one rung, four
sessions, `MaxGeneration = 10`, `AutoRestartBound` out of reach.

| Step | Model | Swift |
| --- | --- | --- |
| 1 | `Start` | `start()` |
| 2 | `UserSeek` out of the buffer: the target is recorded and the settle timer armed | `performUserSeek` 2597, `scheduleFinalTargetRebuild` 5665 |
| 3 | `SeekSettle`: a final-target rebuild; the budget of one is spent | `beginFinalTargetRebuild` 5943, `FinalTargetRebuildPolicy.beginRebuild`, `SeekRestartBudget.requestRestart` (`FinalTargetRebuildPolicy.swift` 45) |
| 4, 5 | `NegotiateLands`, `TaskResume` and `Attach` | `load` 3789 |
| 6 | `StallWatchdog`: a stall downshift; the budget is back to one | `handleStallTimeout` 5340, `attemptAdaptiveBitrateFallback` 5538, `applyAdaptiveBitrateDecision` 5577, `restartAtCurrentPosition(intent: .adaptiveBitrate)` 5602; the plan's `resetFinalTarget` calls `finalTargetRebuildPolicy.reset()` (5724 to 5725), which calls `budget.reset()` (`FinalTargetRebuildPolicy.swift` 72 to 75) |
| 7, 8 | `UserSeek`, `SeekSettle`: a second seek rebuild in the same window | as 2 and 3 |

`SeekRestartBudget.swift` 17 says `reset()` is "on explicit user intent (Retry, quality
reload)". An upshift does the same through the same plan, and `attemptStartupDeadlineRetry`
calls `finalTargetRebuildPolicy.reset()` itself (5462, 5482). Seek rebuilds can then pass `burstLimit` (5 in 60 s) inside
one window, against the #27 contract. Every rebuild still needs a user seek, and the unattended
restarts are themselves bounded (the one-shot, and `AdaptiveBitratePolicy`'s 4 changes per
600 s), so this matters only on a stream that is already struggling: severity low.

Proposed fix: unattended restarts (`adaptiveBitrate` intent, `attemptStartupDeadlineRetry`)
clear the pending target without resetting the budget, or the budget's contract is widened to
say unattended restarts reset it.

## Fixed findings

### Fixed (#526): Retry was dead after a restart from a failure overtook it (`Faithful-RetryWedgedByAttach-off`)

With the fix off, `RetryRuns` is violated: the behaviour ends with `retryGen` set for ever. The
trace and line numbers below are the code before the fix.

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

Fix (#526, `FixRetryBailClearsTask = TRUE`): after its join, a retry task that was not
cancelled clears `failureRetryTask` before the generation check, so every exit releases the
slot. A cancelled task returns without touching it: `stop()` and `restartAtCurrentPosition`
cancel the task before they release the slot, so a newer retry may own it by then. The
behavioural pin is `PlaybackFormalModelFindingsTests` "#526: Retry still runs after a quality
change superseded an earlier retry".

## Observations that are not findings
- MediaBrowser seek reopens bypass `FinalTargetRebuildPolicy`, so nothing budgets them.
- While a failure shows and a quality change is restarting, `surfaceFailure` is a no-op
  (its `guard !playbackError.isFailed`): a second failure of that restart ends the task and
  leaves the first failure's overlay up. The user still has Retry.

## For the backend modules

- This module does not check `OneEncoder`, `NoWrongKill` or `StopNeverKillsSuccessor`. With a
  cancelled task's request still on the wire, the core has two sessions at once (the rejected
  one and its successor) on every backend that does not chain its tasks.
- `Terminal(c, inTask, join, send, user)` is the shape of `stop()` and `surfaceFailure`;
  `RestartCore(c, rb)` the shape of a restart. A backend module copies the parts it needs: no
  module imports this one.
- The task record adds `inc`, `px`, `old` and `rb` to the base's `Task(g, pc, s)`. The base
  operators (`UnwindingAfterCancel`, `TaskRuns`, `TicketDone`) read only `gen`.
- Open questions handed on: the `startStreaming` late start (task 3), the unjoined rejected
  cleanup with a reused id (task 5), and whether Emby's transaction tail closes the same gap
  (task 4).
- The lost answer (`Finding-CancelledReopenLosesAnswer`) needs per-backend confirmation: whether
  a PlaybackInfo call alone starts an encoder on Jellyfin and on Emby. The code's own comments
  say it may (`JellyfinBrowseService.swift` 256 to 258, `DetailPlaybackLauncher.swift` 175 to
  176). Emby's transaction tail does not help: the predecessor join orders the next request,
  but the lost task still never learns its session.
