# plex: the Plex replacement order

`PlaybackPlex.tla` models how `PlaybackController` replaces a Plex transcode in place. One
controller mints one `sessionID` and every transcode it starts runs under it, so the old job and
its replacement always share a session id. The order of an in-place restart is: send the stop
and wait up to two seconds for its answer, detach the old item, request the replacement, attach.

```sh
scripts/check-tla-specs.sh specs/playback/plex
scripts/check-tla-specs.sh --deep specs/playback/plex/Deep-BackToBack.cfg
```

The model reproduces both halves of suspect 2, finds three more ways for a stale stop to end a
replacement (one of them Retry after the failure's detached stop timed out, fixed by #539:
`Faithful-RetryAfterTimedOutStop-off`; another, a restart from the error overlay racing the
failure's own stop, is fixed by #530), judges suspect 4's
late start for Plex, and models Plex's consent boundary, where the choice can show over a copy
job that is still running. Each has a `Finding-*` config and a trace below. None has been
reproduced in the app or against a server. Two results depend on what PMS does with a stop when
several jobs run under one session id, which the repository does not establish; they are
conditional findings, listed under [What PMS does](#what-pms-does).

## What is modelled

Each MainActor run between two awaits is one action. Functions are in
`Labstream/Shared/Player/PlaybackController.swift` unless another file is named.

| Model | Swift |
| --- | --- |
| `Sid(c)` | `sessionID`, minted once per controller |
| `Start` | `start()`: `beginStreaming(stoppingPreviousTranscode: false)` |
| `UserQuality` | `reload(bitrateKbps:)` and the audio and subtitle track changes: `restartAtCurrentPosition` with an intent other than `explicitRetry`, then `beginStreaming`. While a failure shows, `FailureRestartJoinsPendingStops` (#530) makes it a `failureRetryTask` that first joins `pendingStopTasks`, as `retry()` does (`retryKind = "restart"`, then `RetryProceeds`); the restart it then runs keeps that change's plan, clearing neither the error nor `sentTranscodeStop`. Since #539 that task's join is `joinFailedAttemptStop`, as Retry's: an unconfirmed failure stop is re-sent once and the change runs only once it is answered (`RetryRestops`, `RetryRestopConfirmed`), otherwise LS-PB-008 (`RetryRefused`) |
| `StopUnconfirmed`, `st.failStop` | `failedAttemptStopUnconfirmed` (#539). `surfaceFailure` sends its stop with `sendTranscodeStop(tracksFailedAttempt: true)` through `plexFailedAttemptStop`, on a copy of the control client bounded by `failedAttemptStopTimeout` (30 s; `PlexClient.withTimeoutBound`), and `trackFailedAttemptStop` sets the flag when no HTTP answer came, in the failure's generation. Reset by each failure, cleared by an answered re-send. The model's `late` on that stop is the bound passing. A transport error at once (`serverUnreachable`, e.g. no network) also sets it in the Swift; the model has no such outcome, and the gap is safe: such a request never reached PMS, and Retry only re-sends |
| `RetryRestops`, `st.restop` | `joinFailedAttemptStop`: `resendFailedAttemptStop` sends one more stop through `plexFailedAttemptStop`, not behind `sentTranscodeStop`, as a `pendingStopTasks` entry bounded by `failedAttemptRestopTimeout` (10 s). Not while a restart from the error overlay runs (`restartInFlight`: `restartInFlightGeneration`, set by `beginStreaming` and cleared when its task body exits in the same generation; `task[c] # NoTask` in the model, where an ended task leaves the slot): the re-send could end the job that restart starts (`Proposed-StartAfterOwnStops` found it), so that tap keeps LS-PB-008 without ending the restart's reconnect status. A restart whose task has ended (for example its decision failed while the error showed) no longer counts, and the next tap re-sends |
| `RetryRestopConfirmed`, `RetryRefused` | after the re-send, the generation and cancellation check: answered clears the flag and the restart runs; otherwise `playbackError.set(PlaybackFailure(code: .priorSessionStopUnconfirmed))` with `failureRetryTask` cleared, so the next tap re-sends again. Close resets `restop` |
| `Retry`, `RetryProceeds`, `Joined` | `retry()` 2566, `failureRetryTask`, `waitForPendingStopRequests` 1236 awaited at 2580: it returns when every `pendingStopTasks` entry has, and a `sendTranscodeStop` entry returns when its request is answered or times out (`try?` drops the error). `restartAtCurrentPosition` with `.explicitRetry` then switches to the recovery client (5743, `switchToRecoveryControlClient` 2689) |
| `Close` | `stop()` |
| `Fail`, `StartFails` | `handlePlaybackFailure` and the watchdogs, and the `catch`es of `startStreaming`, each ending in `surfaceFailure` |
| `WarmRetry` | `attemptStartupDeadlineRetry` on the Plex lane: `beginStreaming(stoppingPreviousTranscode: false)` |
| `PlayerNeedsConsent` | `handlePlaybackFailure` on a failed copy lane (`directPlayFallbackArmed`, 5073 to 5093): `removeObservers` and `beginStreaming(resumeOffsetMsOverride:)`, an in-place restart whose task asks for consent instead of starting |
| `TaskAsksConsent`, `ConsentShows` | that task past `stopPreviousTranscode` and the detach: `copyFailed` sends it to `requestVideoTranscodeConsent` (2956 to 2959), which detaches, calls `stopPreviousTranscode` again (2514) with its result discarded, finds `mediaBrowserSession` nil, passes the generation check and shows the choice (2531 to 2533) |
| `Approve`, `Decline` | `approveVideoTranscoding` 2536 (`videoTranscodeApprovedForCurrentItem`, then `beginStreaming`, an in-place restart), `declineVideoTranscoding` 2549 (`surfaceFailure`) |
| `RestartCore` | the synchronous part of `beginStreaming` |
| `Terminal`, `SurfaceFailure` | what `stop()` and `surfaceFailure` share, with `sendTranscodeStop` and the `sentTranscodeStop` latch |
| `TaskSendsStop` | the first run of `startStreaming`: its guard, then `stopPreviousTranscode` |
| `StopWaitOver`, `AbandonedStop` | the task group in `stopPreviousTranscode`: the stop against `Task.sleep(for: .seconds(2))`, then `group.cancelAll()`; and `PlexClient.send`, which turns a cancelled `URLSession` request into `CancellationError` (`Labstream/Shared/Networking/PlexClient.swift`) |
| `TaskIssuesStart` | the guard after `stopPreviousTranscode`, the detach of the old item, and the request that starts the transcoder: the `start.m3u8` fetch and `HLSSessionPrewarmer.prewarm` on the Original lane, or AVPlayer after `load` on a capped quality |
| `TaskAttaches` | the last guard of `startStreaming`, and `load(_:resumeOffsetMs:)` |
| `TaskUnwindExit` | any `guard !Task.isCancelled, generation == playbackGeneration else { return }` of `startStreaming` |
| `ServerStarts` (`StartLands`) | PMS acts on a start request |
| `ServerResolves`, `ClockTicks` | PMS applies a stop, or it ends unacknowledged; two seconds pass for a stop a task awaits, or the `URLSession` request timeout passes for a detached stop (`PlexClient.recovery`, `Labstream/Shared/Networking/PlexClient.swift` 39 to 41, and `PlexSessionConfiguration.recoveryControlPlane`, `PMSKit/Sources/PMSKit/PlexSessionConfiguration.swift` 13 to 16: 5 s on the recovery client) |

A task is `[gen, pc, seq, stop, stopping, warm]`: the generation it captured, where it is, its
start request, the stop it awaits, `stoppingPreviousTranscode`, and whether it is the
startup-deadline retry. Its places:

| `pc` | The task is at |
| --- | --- |
| `begin` | created by `beginStreaming`, not yet run |
| `awaitStop` | `await stopPreviousTranscode` |
| `negotiate` | its start request, on the wire |
| `negotiated` | the answer to a request the server acted on, on its way back |
| `consentStop` | `await stopPreviousTranscode` inside `requestVideoTranscodeConsent` |

Cancelling a task moves it to `unwinding`. Every check in `startStreaming` is a bare `return`,
so a cancelled task does nothing more; what its request created stays.

### How a stop is judged

A Plex stop carries the session id and nothing else (`TranscodeRequest.stop`). The model
therefore judges a stop by when it was sent. Start requests are numbered in the order the client
sent them, and each stop records how many had gone out (`stopLog`, `at`). A stop *covers* the
starts sent before it. `StopNeverKillsSuccessor` fails when a stop ends a job whose own start
request was sent after the stop.

The base's stop records need an incarnation. `Aim(c)` gives the newest job a start of this
controller created, or, when none has, the top incarnation, which the model never starts. A stop
sent before any job exists therefore never counts in `Owned` as a stop for a job that arrives
later. With that choice `Owned` is never smaller than "live, and no stop covering the job has
failed", so a pass of `OneEncoder` is sound. The base's `NoWrongKill` is checked beside
`StopNeverKillsSuccessor` where requests are served in order.

## What is abstracted, and why

- **What the restart core covers** is left out: seeks and their budget, pause intent, the
  loopback proxy, attach fencing, and `RetryBails` (`Faithful-RetryWedgedByAttach-off` there, fixed in #526).
  `seekHold`, `budget`, `paused`, `proxy` and `jellyfinWindow` never change. No module is
  imported: the core's `Terminal` and `RestartCore` are rewritten here for the Plex order, about
  forty lines, because the core sends the prior stop synchronously and detaches at once.
- **Two statements of the restart core do not hold here**, as its README warns.
  `DetachBeforeStop` holds for `stop()` and `surfaceFailure` only: a restart's stop is on the
  wire while the old item is attached (witness `NeverStopWhileAttached`). The second half of
  `GenerationFencing` fails too: an attached item has a restart behind it
  (`NeverRestartBehindItem`). Neither is a defect; `NoZombieItem` is the rule this order keeps
  instead.
- **The awaits between the stop and the start request** (stream selection, the decision
  request) are folded into `TaskIssuesStart`. A task cancelled there has sent its stop and no
  start, which a task cancelled in `awaitStop` after its answer also reaches.
- **The adaptive-bitrate restart** (`PlaybackRestartIntent.adaptiveBitrate`, from the stall
  watchdog and healthy-playback upshift) is not a separate action. It enters `beginStreaming`
  exactly as `UserQuality` does and differs only in not being a user action, so it is covered
  by `UserQuality`'s steps but counted against `MaxUserActions`.
- **The consent boundary** is modelled for the copy-lane failure route (`PlayerNeedsConsent`), the
  one that has a job to stop. The other calls of `requestVideoTranscodeConsent` from
  `startStreaming` (2958, 2993, 3006: the decision or the copy-playlist fetch says video needs
  encoding) come after the same stop and wait, and on a first start there is no job to stop; they
  are not separate actions. The Original-quality condition is not modelled. Once the item's
  encoding is approved no consent is asked again until `reload` clears the approval
  (`videoTranscodeApprovedForCurrentItem = false`, 2475): a `UserQuality` step is either a
  reload, which clears it, or a track change, which keeps it.
- **Which request starts a transcoder.** On a cold session `start.m3u8` alone does not; the
  fetch of the media playlist does (the comment above the prewarm in `startStreaming`). The
  model has one start request per attempt and two places for it: the task makes it and waits
  (Original lane), or the task attaches and AVPlayer makes it (capped qualities).
- **Request order.** Without `LateStarts` requests are served in the order sent, a cancelled
  start request never reaches the server, and the two places above differ by nothing a stop
  could see, so only the first is taken. With `LateStarts` a start request can be overtaken by a
  stop sent after it, and can land after its task was cancelled or its item detached.
  `TaskIssuesStart(c, TRUE)` (AVPlayer's request after the attach) exists only with `LateStarts`:
  without it, a capped-quality start whose task is cancelled is dropped rather than landing before
  the stop that follows, which is harmless only because requests are then served in order.
- **A cancelled stop.** When the wait gives up, or the awaiting task is cancelled, the task
  group cancels the `URLSession` request. The client hears nothing more. With
  `CancelledStopCanLand` the server may still apply it; without, it never does. Either way the
  job it was aimed at stays owned until the request ends: the client cancelled it, so the base's
  rule that a failed stop hands the job to the server does not excuse it.
- **Time.** `ClockTicks` is the two-second bound for a stop a task awaits, and the `URLSession`
  request timeout for a detached stop (`sendTranscodeStop`, a `pendingStopTasks` entry): 5 s on
  the recovery client that every Retry switches to, 60 s otherwise. A detached stop that timed
  out stays on the wire, as in the Emby and Jellyfin modules; the client dropped its connection,
  so it is applied only with `CancelledStopCanLand`, and the join (`Joined`) ends at the timeout.
  An earlier version treated the timeout as `ServerFail`, so a detached stop could never land
  after the client stopped waiting, and the Retry route below was hidden. A kill by a timed-out
  detached stop counts as `"live"`: the client's own code cancelled nothing, so the weaker
  properties do not excuse it.
- **`Terminal` for a failure raised inside the task** adds no join of that task, where
  `surfaceFailure` does append it (5155 to 5158). The task returns right after, so nothing
  changes.
- **`ServerRecreate` is not enabled.** A detached Plex item's requests to a stopped session get
  404 (the comment above the detach in `startStreaming`); nothing in the repository shows PMS
  restarting a stopped job by itself.
- **One generation bump in `start()`**, where the Swift bumps twice in one MainActor run.

## What PMS does

Two server behaviours decide results, and the repository does not settle either. No live server
was queried for this model.

| Evidence in the repository | Says |
| --- | --- |
| `TranscodeRequest.stop` (`PMSKit/Sources/PMSKit/Transcode/TranscodeRequest.swift`) | A stop names a session and nothing else. |
| Commit `1a47c24d` (#27) and the comment on `beginStreaming` | 21 software transcoders ran at once for one session id within about a minute: a new `start.m3u8` under a live id does not reliably replace the job. `StartJob` under a live id adds a job. |
| Commit `47081678`, since removed from `docs/DEVELOPMENT.md` | The earlier belief that "PMS replaces the job in place" on a same-session reload, which #27 contradicted. |
| `LivePlexTimelineProbeTests` (`PMSKit/Tests/PMSKitTests/`) | A stop returns 200 whether or not anything was running: an acknowledgement does not show that a job ended. |
| `RemoteSeekModePolicy.StreamKind.plexStreamingCopyHLS` (`PMSKit/Sources/PMSKit/Playback/RemoteSeekModePolicy.swift`) | Stopping and re-minting the same session id back to back left the fresh session without a header for over 20 s, then HTTP 400. Consistent with a stop reaching the replacement; not proof of it. |
| The comment above the detach in `startStreaming` (#196) | A request from the old item landed on the restarted session and moved its transcoder: PMS routes by session id, not by job. |
| `attemptStartupDeadlineRetry` | The retry asks again under the same id "against the SAME session" and expects the running job to serve it. |

Nothing says which jobs a stop ends when several run under one id: before #27 no stop was sent
on a restart, and since #27 the client tries never to have two. So the model was run both ways.

| Assumption | `TRUE` | `FALSE` |
| --- | --- | --- |
| `StopEndsAllUnderId` (base) | a stop ends every job under the id | it ends any non-empty set of them |
| `WarmStartJoinsJob` | a request that asks again for what a running job was started for is served by that job | every start request adds a job |
| `CancelledStopCanLand` | PMS may apply a stop the client cancelled, or whose `URLSession` request timed out | it never does |

What depends on them:

- **`StopEndsAllUnderId`.** `Current-InPlace` passes with `FALSE`: where every stop is
  acknowledged in time, no two jobs ever run under the id. `Current-ReusedId`,
  `Current-LateAck`, `Deep-BackToBack` and `Proposed-StartAfterOwnStops` need `TRUE`: once a
  stop is lost and the job runs on beside its replacement, only a stop that ends both keeps one
  encoder. `Finding-StopEndsOnlySome` is `Current-ReusedId` with `FALSE`, the setting that
  assumes nothing: a job outlives an acknowledged final stop, and `OneEncoder` fails too. It is
  a conditional finding: a defect of the current design unless PMS ends every job under the id,
  and then no ordering of the client's requests under one session id repairs it.
- **`WarmStartJoinsJob`.** Every config uses `TRUE` except `Finding-WarmStartAddsJob`, where the
  startup-deadline retry runs two transcoders by design. It is a conditional finding: a defect
  unless PMS serves that request from the running job.
- **`CancelledStopCanLand`.** The kill half of suspect 2 needs `TRUE`, and so do
  `Faithful-RetryAfterTimedOutStop-off` (#539, the code before the fix) and
  `Finding-CancelledConsentStopKillsApproved`. The pile-up
  half does not depend on it, nor on `StopEndsAllUnderId`. `Faithful-FinalStopKillsReplacement-off`
  and `Finding-ConsentShowsOverRunningJob` need none of the three.

## Bounds

- One controller, one session id. `MaxGeneration` bounds `playbackGeneration` and the
  incarnations; a controller sends at most `MaxGeneration - 1` start requests. It is set high
  enough that `MaxUserActions` runs out first (16 for two actions, 21 for three, 11 for one).
  The consent configs take 19: a failing copy lane restarts without a user action. The distinct
  state count of `Current-Consent` grows up to `MaxGeneration = 19` and is the same at 21 and 23.
- `MaxUserActions` bounds quality changes and Retry taps together. Close and one failure per
  attempt are always available.
- `EnvFails`, `RestartFromFailure`, `WarmRetries`, `StopsCanFail`, `StopsCanBeLate` and
  `LateStarts` switch parts of the environment on.

## Properties

| Property | Kind | Meaning |
| --- | --- | --- |
| `OneEncoder` (base) | invariant | At most one job the client still owns. **Violated by the code (suspect 2).** |
| `OneEncoderOutsideCancelledStops` | invariant | The same, beside the jobs a cancelled and still unanswered stop was aimed at. This is what the code keeps. |
| `StopNeverKillsSuccessor` | invariant | No stop ends a job whose start request was sent after it. **Violated by the code (suspect 2).** |
| `LiveStopNeverKillsSuccessor` | invariant | The same for every stop the client had not cancelled. **Violated by the code (conditional) when Retry follows a failure whose stop timed out.** A restart from a failure without Retry violated it until #530 (`Faithful-FinalStopKillsReplacement-off`). |
| `NoWrongKill` (base) | invariant | No stop aimed at an older incarnation ended a newer one. |
| `NoZombieItem` | invariant | No start request goes out while an older item is attached (#196). |
| `NoOrphans` | invariant | After Close, and while a failure shows with nothing under way, a stop covering every job has been sent. A stop that fails counts. **Violated by the code after a restart from a failure (the restart core's finding).** |
| `CleanAfterAckedClose` | invariant | Once Close's stop is acknowledged and nothing of the controller's is on the wire, the server runs nothing for it. **Violated by the code with a late start (suspect 4).** |
| `ConsentBoundary` | invariant | While the consent choice shows, nothing is attached and no job the client owns runs ("Stop any copy/audio-conversion job before presenting the choice"). **Violated by the code when a stop takes over two seconds (`Finding-ConsentShowsOverRunningJob`).** |
| `RestartSettles` | liveness | A start or restart ends: it attaches, fails or is closed. |
| `CloseCleansUp` | liveness | After Close every task returns and the joined cleanup ends. |

`RestartSettles` is checked under two fairness assumptions. `FairSpec` answers every stop.
`ClockFairSpec` never forces an answer and only runs the two-second clock: the dead connection
the bound exists for.

## Configs and results

2026-11-25, tla2tools v1.7.4, `TLC_WORKERS=auto TLC_HEAP=4g` on 30 cores. Unless noted: one
controller, two user actions, `MaxGeneration = 16`, failures and the startup-deadline retry on,
`RestartFromFailure`, `StopsCanFail`, `StopsCanBeLate`, `LateStarts`, `ConsentPossible` and
`CancelledStopCanLand` off, `StopEndsAllUnderId = FALSE`, `WarmStartJoinsJob = TRUE`.

| Config | Expect | Result | Distinct states | Time |
| --- | --- | --- | --- | --- |
| `Current-InPlace` | pass | pass | 2,801,859 | 12 s |
| `Current-ReusedId` | pass | pass (given `StopEndsAllUnderId`) | 1,262,840 | 6 s |
| `Current-LateAck` | pass | pass (given `StopEndsAllUnderId`) | 2,534,848 | 10 s |
| `Current-LateFail` | pass | pass (given `StopEndsAllUnderId`; `LiveStopNeverKillsSuccessor` not checked, `Finding-RetryRestopDoesNotFence` owns it) | 109,047 | 2 s |
| `Current-Consent` | pass | pass | 1,530,725 | 8 s |
| `Current-RestartFromFailure` | pass | pass | 4,422,329 | 18 s |
| `Liveness-InPlace` | pass | pass | 240,066 | 16 s |
| `Liveness-BoundedWait` | pass | pass | 149,595 | 7 s |
| `Faithful-StopPrevious-off` | `OneEncoder` violated | violated | stops at first error | 1 s |
| `Faithful-DetachBeforeStart-off` | `NoZombieItem` violated | violated | stops at first error | 1 s |
| `Faithful-RetryAfterTimedOutStop-off` (conditional on PMS) | `LiveStopNeverKillsSuccessor` violated | violated | stops at first error | 1 s |
| `Finding-RetryRestopDoesNotFence` (conditional on PMS, #536) | `LiveStopNeverKillsSuccessor` violated | violated | stops at first error | 2 s |
| `Current-LateFailNoLanding` | pass | pass (that finding with `CancelledStopCanLand = FALSE`: every `Current-LateAck` invariant, `LiveStopNeverKillsSuccessor` included, with failures and the re-send) | 131,212 | 2 s |
| `Faithful-RestartAfterFailureSkipsFinalStop-off` | `NoOrphans` violated | violated | stops at first error | 1 s |
| `Mutant-StopNotAwaited` | `LiveStopNeverKillsSuccessor` violated | violated | stops at first error | 1 s |
| `Mutant-StopNotAwaited-PileUp` | `OneEncoderOutsideCancelledStops` violated | violated | stops at first error | 1 s |
| `Mutant-RetrySkipsJoin` | `LiveStopNeverKillsSuccessor` violated | violated | stops at first error | 1 s |
| `Faithful-FinalStopKillsReplacement-off` | `LiveStopNeverKillsSuccessor` violated | violated | stops at first error | 1 s |
| `Mutant-CloseSkipsFinalStop` | `NoOrphans` violated | violated | stops at first error | 0 s |
| `Mutant-UnboundedStopWait` | `RestartSettles` (temporal) violated | violated | stops at first error | 3 s |
| `Finding-LateStopKillsReplacement` | `StopNeverKillsSuccessor` violated | violated | stops at first error | 1 s |
| `Finding-LateStopKillsReplacement-CancelledWait` | `StopNeverKillsSuccessor` violated | violated | stops at first error | 1 s |
| `Finding-LateStopPilesUp` | `OneEncoder` violated | violated | stops at first error | 1 s |
| `Finding-LateStartOutlivesStop` | `CleanAfterAckedClose` violated | violated | stops at first error | 1 s |
| `Finding-LateStartPilesUp` | `OneEncoder` violated | violated | stops at first error | 1 s |
| `Finding-ConsentShowsOverRunningJob` | `ConsentBoundary` violated | violated | stops at first error | 1 s |
| `Finding-CancelledConsentStopKillsApproved` (conditional on PMS) | `StopNeverKillsSuccessor` violated | violated | stops at first error | 1 s |
| `Finding-StopEndsOnlySome` (conditional on PMS) | `CleanAfterAckedClose` violated | violated | stops at first error | 1 s |
| `Finding-WarmStartAddsJob` (conditional on PMS) | `OneEncoder` violated | violated | stops at first error | 1 s |
| `Proposed-StartAfterOwnStops` | pass | pass (given `StopEndsAllUnderId`) | 33,653,572 | 210 s |
| `Proposed-Liveness` | pass | pass (given `StopEndsAllUnderId`) | 127,890 | 15 s |
| `Deep-BackToBack` (deep) | pass | pass (given `StopEndsAllUnderId`) | 224,250,625 | 18 min 51 s |

- `Current-InPlace`: three user actions, `MaxGeneration = 21`. Every stop is acknowledged within
  the wait, a cancelled request reaches nobody and requests are served in order. It checks
  `TypeOK`, `OneEncoder`, `NoWrongKill`, `StopNeverKillsSuccessor`, `NoZombieItem`, `NoOrphans`
  and `CleanAfterAckedClose`, and so do `Current-ReusedId`, `Proposed-StartAfterOwnStops` and
  `Deep-BackToBack`.
- `Current-ReusedId` (review focus 2): `StopsCanFail` and `StopEndsAllUnderId`. A job whose stop
  was lost runs on under the id beside its replacement.
- `Current-LateAck` (review focus 3): `StopsCanFail`, `StopsCanBeLate`, `CancelledStopCanLand`
  and `StopEndsAllUnderId`, no failures. It checks `TypeOK`, `OneEncoderOutsideCancelledStops`,
  `LiveStopNeverKillsSuccessor`, `NoZombieItem`, `NoOrphans` and `CleanAfterAckedClose`. With
  failures and without #539's check it fails `LiveStopNeverKillsSuccessor`
  (`Faithful-RetryAfterTimedOutStop-off`, the same constants with `EnvFails` and
  `RetryNeedsConfirmedStop = FALSE`); before the detached stop's timeout was modelled it passed
  with them (20,963,959 states). `Current-LateFail`: `Current-LateAck` with `EnvFails`, one user
  action and `MaxGeneration = 11`, every `Current-LateAck` invariant except
  `LiveStopNeverKillsSuccessor` (owned by `Finding-RetryRestopDoesNotFence`, which is it with the
  property), so late stops and failures are checked together.
- `Current-Consent`: `Current-InPlace` with `ConsentPossible`, two user actions,
  `MaxGeneration = 19`, every `Current-InPlace` invariant and `ConsentBoundary`.
  `Finding-ConsentShowsOverRunningJob` is it with late stops (checking `ConsentBoundary` only),
  and `Finding-CancelledConsentStopKillsApproved` with late stops, `CancelledStopCanLand`, one
  user action, no failures or startup-deadline retry and `CONSTRAINT ConsentRoute`.
- `Liveness-InPlace`: `Current-LateAck`'s run with one user action and `MaxGeneration = 11`,
  under `FairSpec`: `RestartSettles` and `CloseCleansUp`. `Liveness-BoundedWait`: late and
  cancelled stops, one user action, under `ClockFairSpec`: `RestartSettles`.
- `Proposed-StartAfterOwnStops`: both fixes, `Current-LateAck`'s run plus failures and
  `RestartFromFailure`.
  `Proposed-Liveness`: the same with one user action under `FairSpec`.
- `Deep-BackToBack`: two controllers, each under its own session id, `Current-ReusedId`'s run
  with one user action each and `MaxGeneration = 11`. With `IdsNeverShared` the two share the
  server and nothing else, so a closing playback cannot reach the next one's session.

How the `Current` configs are scoped around the findings, as in the restart core: each finding
needs one thing from the environment, so a `Current` config either leaves that thing out and
checks the full property, or keeps it and checks what the code still keeps.
`OneEncoderOutsideCancelledStops` and `LiveStopNeverKillsSuccessor` excuse only the stops the
client itself cancelled, which pins suspect 2 to `stopPreviousTranscode`'s give-up and to a
cancelled wait. `LateStarts` is off in every `Current` config; its `Finding` configs turn on
nothing else. `FixRestartResetsStopLatch` is `TRUE` (shipping since #527) everywhere but
`Faithful-RestartAfterFailureSkipsFinalStop-off`, and `FailureRestartJoinsPendingStops` (shipping
since #530) everywhere but `Faithful-FinalStopKillsReplacement-off`. `RestartFromFailure` is on in
`Current-RestartFromFailure`, which checks every `Current-InPlace` invariant with it.
`Current-LateAck` has no failures (`Current-LateFail` has
them and drops `LiveStopNeverKillsSuccessor`), and `Current-Consent`
no late stops, for the same reason (`Finding-ConsentShowsOverRunningJob`; before #539 also the
route now in `Faithful-RetryAfterTimedOutStop-off`).

### Faithfulness and mutants

| Config | Flips | Violates | Trace |
| --- | --- | --- | --- |
| `Faithful-StopPrevious-off` | `StopsPreviousFirst` | `OneEncoder` | A quality change requests the replacement with no stop; both jobs run (#27). |
| `Faithful-DetachBeforeStart-off` | `DetachesBeforeStart` | `NoZombieItem` | The stop is acknowledged and the replacement requested with the old item still attached (#196). |
| `Faithful-RestartAfterFailureSkipsFinalStop-off` | `FixRestartResetsStopLatch` | `NoOrphans` | The latch before #527: fail, a quality change from the overlay, Close sends no stop for the job it started. |
| `Mutant-StopNotAwaited` | `WaitsForPreviousStop` | `LiveStopNeverKillsSuccessor` | The stop is sent, the start follows at once, and the stop is applied after the job starts. |
| `Mutant-StopNotAwaited-PileUp` | `WaitsForPreviousStop` | `OneEncoderOutsideCancelledStops` | The same, before the stop is applied: two owned jobs. |
| `Mutant-RetrySkipsJoin` | `RetryJoinsPendingStops` | `LiveStopNeverKillsSuccessor` | Fail, Retry: the failure's detached stop is still unanswered when the restart starts its job, and ends it. |
| `Faithful-FinalStopKillsReplacement-off` | `FailureRestartJoinsPendingStops` | `LiveStopNeverKillsSuccessor` | Fail, a quality or track change from the error overlay: the restart does not join the failure's stop, which ends the replacement (#530; trace below). |
| `Mutant-CloseSkipsFinalStop` | `CloseSendsFinalStop` | `NoOrphans` | Close with a job running and no stop. |
| `Mutant-UnboundedStopWait` | `BoundedStopWait` | `RestartSettles` | A restart waits for ever on a stop that is never answered. |

`OneEncoder`, `StopNeverKillsSuccessor`, `LiveStopNeverKillsSuccessor`,
`CleanAfterAckedClose` and `ConsentBoundary` are violated by the code as it stands (`NoOrphans`
was too until #527; `Faithful-RestartAfterFailureSkipsFinalStop-off` and
`Mutant-CloseSkipsFinalStop` are its failing runs now); their `Finding` configs also show
they can fail, and `Proposed-StartAfterOwnStops` that they can hold. `CleanAfterAckedClose` has
no mutant of its own: `Finding-LateStartOutlivesStop` and `Finding-StopEndsOnlySome` are its
failing runs.

Two `Finding` configs flip a server assumption and no client code. Each is the current design
against a server the repository does not rule out:

| Config | Server assumption | Violates | Trace |
| --- | --- | --- | --- |
| `Finding-StopEndsOnlySome` | `StopEndsAllUnderId = FALSE` | `CleanAfterAckedClose` (and `OneEncoder`) | A stop is lost, the replacement starts beside the old job, and Close's acknowledged stop ends one of the two. |
| `Finding-WarmStartAddsJob` | `WarmStartJoinsJob = FALSE` | `OneEncoder` | The startup-deadline retry's request starts a second job. |
 `NoWrongKill`'s mutant is
`Base-Mutant-StartBeforeStopResolves`. `CloseCleansUp` has no failing run.

### Every branch is taken

The module ends with witnesses, each the negation of a state one branch reaches. Checked as the
only invariant, each is violated:

| Witness | Constants of |
| --- | --- |
| `NeverStopWhileAttached`, `NeverRestartBehindItem`, `NeverBlankStop`, `NeverCancelledWait`, `NeverWarmJoin`, `NeverRetryWaits` | `Current-InPlace` |
| `NeverTwoUnderOneId`, `NeverStopFailed` | `Current-ReusedId` |
| `NeverGaveUp`, `NeverCancelledStopLands`, `NeverDetachedTimedOut` (Close's detached stop timed out) | `Current-LateAck` |
| `NeverRetryRestops`, `NeverRestopConfirmed`, `NeverRetryRefused` (a tap re-sends the failure's stop; PMS answers it; the bound passes) | `Current-LateFail` |
| `NeverConsentShown` | `Current-Consent` |
| `NeverRestartFromFailure` | `Proposed-StartAfterOwnStops` |
| `NeverLateStart` | `Finding-LateStartPilesUp` |

No config lists them; to repeat one, copy the named config, replace its `INVARIANTS` with the
witness and run TLC.

## Findings

Line numbers are `PlaybackController.swift` as of commit `0b7f3fcb`, the last to change it before
this model. Traces are the shortest TLC finds with one worker.

### Suspect 2, reproduced: a late stop ends the replacement (`Finding-LateStopKillsReplacement`)

`StopNeverKillsSuccessor` is violated in 8 states. It needs `CancelledStopCanLand`.

| Step | Model | Swift |
| --- | --- | --- |
| 1 | `Start` | `start()` 1128, `beginStreaming` 2715 |
| 2 | `UserQuality`: a quality or track change during startup. The first task is cancelled before it requested anything | `reload` 2470, `restartAtCurrentPosition` 5710, `beginStreaming` 5746: 2707, 2712, 2715 |
| 3 | `TaskSendsStop`: the stop goes out under `sessionID`, whether or not anything runs there | `startStreaming` 2758 to 2767, `stopPreviousTranscode` 2739 to 2743 |
| 4 | `ClockTicks`: two seconds pass with no answer | `Task.sleep` 2744 wins `group.next()` 2745 |
| 5 | `TaskIssuesStart`: the wait gives up and cancels the request; the task passes its guard and requests the replacement | `group.cancelAll()` 2746; `PlexClient.send` maps the cancellation and `try?` drops it; guard 2768; the request at 2999 or 3040, or AVPlayer's after `load` 3158 |
| 6 | `ServerStarts`: PMS starts the transcoder | |
| 7 | `ServerResolves`: PMS applies the stop. It names the session only, so it ends the job that started in step 6 | `TranscodeRequest.stop` |

The comment on `stopPreviousTranscode` says the stop is "awaited (so the stop can never race past
the new start and whack the replacement job)". That holds only while the wait is still running.
The same trace from a playing item is three steps longer (`TaskIssuesStart`, `ServerStarts` and
`TaskAttaches` before the quality change), and there the stop ends the old job, the replacement
or both, depending on `StopEndsAllUnderId`.

The player is then attached to a session PMS has stopped. What it does next is outside this
model.

Whether PMS applies a request whose connection the client reset is not established. It needs
the request to have left the device and the answer to take over two seconds: a server slow to
answer, or bytes already on a lossy link that arrive late, not a dead link.

### Suspect 2 with no timeout: the stop of a cancelled restart (`Finding-LateStopKillsReplacement-CancelledWait`)

`StopNeverKillsSuccessor` is violated in 10 states with `StopsCanBeLate = FALSE`. It needs
`CancelledStopCanLand`.

| Step | Model | Swift |
| --- | --- | --- |
| 1 to 3 | `Start`, `UserQuality`, `TaskSendsStop`: a restart's task is in `stopPreviousTranscode` | 2767, 2743 |
| 4 | `UserQuality`: a second restart cancels that task. Cancelling it cancels the task group's children, so the first stop's request is cancelled at once | `playbackTask?.cancel()` 2707; the group at 2742 |
| 5 | `TaskSendsStop`: the new task sends its own stop and awaits only that one | 2767 |
| 6 | `ServerResolves`: the second stop is acknowledged | |
| 7, 8 | `TaskIssuesStart`, `ServerStarts`: the replacement starts | 2768, 2999 or 3040 or 3158 |
| 9 | `ServerResolves`: the first stop is applied and ends it | |

Nobody waits for the first stop: its own task is gone and the task that cancelled it does not
inherit it. This needs the first stop to be delayed only past the second stop's round trip and
the new start, which can be far less than two seconds when two restarts come close together (two
quality or track taps, or a rebuild behind a quality change). It also needs the two stops to be
served out of order.

### Suspect 2, the pile-up half: the replacement starts beside the old job (`Finding-LateStopPilesUp`)

`OneEncoder` is violated in 9 states. It does not depend on `CancelledStopCanLand` or
`StopEndsAllUnderId`.

| Step | Model | Swift |
| --- | --- | --- |
| 1 to 3 | `Start`, `TaskIssuesStart`, `ServerStarts`: a job runs | |
| 4, 5 | `UserQuality`, `TaskSendsStop` | 2707 to 2715, 2767 |
| 6 | `ClockTicks` | 2744 |
| 7 | `TaskIssuesStart`: the wait gives up; the old job has not been stopped | 2746, 2768 |
| 8 | `ServerStarts`: a second job runs under the id | |

This is the state #27 exists to prevent ("so superseded jobs can't pile up and OOM the server",
2761). If PMS ends every job under the id per stop, the next acknowledged stop (the next
restart's, or Close's) ends both, so the pile-up lasts until then. If it ends only some, the
extra job can outlive Close (`Finding-StopEndsOnlySome`).

### Fixed (#530): a restart from a failure raced the failure's own stop (`Faithful-FinalStopKillsReplacement-off`)

Fixed by #530: `restartAtCurrentPosition` now joins `pendingStopTasks` before a restart that
begins while a failure shows, as `retry()` does, and `FailureRestartJoinsPendingStops = TRUE`
models it. `Current-RestartFromFailure` checks the full `StopNeverKillsSuccessor` with restarts
from a failure on. The trace below is the code before the fix, which
`Faithful-FinalStopKillsReplacement-off` (the former `Finding-FinalStopKillsReplacement`) still
reproduces with the join off.

`LiveStopNeverKillsSuccessor` is violated in 9 states, with every stop answered in time and no
cancelled request.

| Step | Model | Swift |
| --- | --- | --- |
| 1 | `Start` | |
| 2 | `Fail`: a failure surfaces. Its stop is detached and nobody awaits it | `surfaceFailure` 5133, `sendTranscodeStop` 5177: 1290, 1294 |
| 3 | `UserQuality`: a quality or track change while the failure shows. Nothing joins `pendingStopTasks` | `reload` 2470 has no failure guard; `restartAtCurrentPosition` 5710. Only `retry()` joins (2580) |
| 4, 5 | `TaskSendsStop`, `ServerResolves`: the restart's own stop is sent and acknowledged | 2767 |
| 6, 7 | `TaskIssuesStart`, `ServerStarts`: the replacement starts | |
| 8 | `ServerResolves`: the failure's stop is applied and ends it | |

`retry()` waits for exactly this ("Do not mint a replacement while the failed attempt's
exact-session stop is still in flight", 2578 to 2580), and `Mutant-RetrySkipsJoin` shows the wait
is needed. A quality or track change from the failure overlay took the other path and skipped it.
It needed the two stops to be served out of order, or the first to be slow: the dead-connection
case a failure overlay usually follows, where the failure message itself suggests a lower
quality.

The deferred restart takes the `failureRetryTask` slot and shows the reconnect status, so a Retry
tap while it waits is ignored (the restart already under way is the recovery), and Close or a newer
change cancels it. Its restart goes through `beginStreaming`, which clears `sentTranscodeStop`
(#527), so Close covers the replacement.

### Fixed (#527): the restart core's finding under the Plex order (`Faithful-RestartAfterFailureSkipsFinalStop-off`)

Fixed: `beginStreaming` clears `sentTranscodeStop`, so each new transcode gets its own final
stop. `FixRestartResetsStopLatch` is `TRUE` in every config but this `Faithful` one, which keeps
the old latch; with the fix on, its constants pass (392,451 distinct states). The old trace:
`NoOrphans` is violated in 9 states: `Start`, `Fail` (1290 sets `sentTranscodeStop`),
`UserQuality`, the restart's stop and its acknowledgement, the replacement starts, `Close`.
`sendTranscodeStop` returns at 1289 and no stop covers the running job. Since #530 the restart
first waits for the failure's stop (`ServerResolves`, then `RetryProceeds`), so the trace is longer; the
latch is untouched. Reusing the session id
does not help: every later restart stops its predecessor, but the last job has only Close.

### Suspect 4 on Plex: a start acted on after the final stop (`Finding-LateStartOutlivesStop`)

`CleanAfterAckedClose` is violated in 6 states with `LateStarts`.

| Step | Model | Swift |
| --- | --- | --- |
| 1, 2 | `Start`, `TaskIssuesStart`: a request that starts the transcoder is on the wire | 2999, 3040, or AVPlayer after 3158 |
| 3 | `Close`: the task is cancelled, the item released and the stop sent | 1181, 1201, 1202 |
| 4 | `ServerResolves`: the stop is acknowledged, having found nothing | PMS answers 200 either way |
| 5 | `ServerStarts`: PMS acts on the start | |

This answers the question the restart core handed on. The stop is sent (so `NoOrphans`, which
judges what the client sent, holds), and it does not help: nothing is sent after it, because
`sentTranscodeStop` is set. The transcoder runs until PMS reaps it. It needs PMS to finish a
start whose connection the client has dropped, after a stop sent later. `Finding-LateStartPilesUp`
is the same request order across a restart: `OneEncoder` is violated in 9 states, with the
overtaken start's job beside the replacement's.

### Fixed (#539), conditional: Retry after the failure's stop timed out (`Faithful-RetryAfterTimedOutStop-off`)

Before #539, and in `Faithful-RetryAfterTimedOutStop-off` with `RetryNeedsConfirmedStop = FALSE`
(line numbers as they were then), `LiveStopNeverKillsSuccessor` is violated in 12 states with
late stops. Its one server assumption
is `CancelledStopCanLand`: PMS applies a stop whose connection the client dropped. The client
cancels nothing itself, so the weaker property fails, not only `StopNeverKillsSuccessor`.

| Step | Model | Swift |
| --- | --- | --- |
| 1 | `Start` | `start()`, `beginStreaming` 2715 |
| 2 | `Fail`: a failure surfaces; its stop is detached, a `pendingStopTasks` entry | `surfaceFailure` 5133, `sendTranscodeStop` 5177: 1288 to 1294 |
| 3 | `ClockTicks`: the request passes its `URLSession` timeout unanswered; the entry's `try?` returns, the request stays on the wire | 1294; 5 s on the recovery client (`PlexClient.recovery` 39 to 41) once any earlier Retry ran, 60 s otherwise |
| 4, 5 | `Retry`, and the cancelled first task returns | `retry()` 2566 |
| 6 | `RetryProceeds`: the join returns | `waitForPendingStopRequests` 1236, awaited at 2580; `restartAtCurrentPosition` 2584, `switchToRecoveryControlClient` 5743 |
| 7, 8 | `TaskSendsStop`, `ServerResolves`: the Retry's own stop is sent and acknowledged | `stopPreviousTranscode` 2738 to 2747, called at 2767 |
| 9, 10 | `TaskIssuesStart`, `ServerStarts`: the replacement starts | 2768; 2999, 3040 or AVPlayer after 3158 |
| 11 | `ServerResolves`: the timed-out failure stop is applied. It names the session only (`TranscodeRequest.stop`), so it ends the replacement | |

The comment at 2578 to 2579 is the rule this breaks: do not mint a replacement while the failed
attempt's exact-session stop is still in flight. A timed-out request is still in flight, and the
join cannot tell it from an answered one. The recovery client makes the timeout short: every
Retry switches to it, so from the second failure on the detached stop gives up after 5 s.
`Mutant-RetrySkipsJoin` is the same route with no join at all.

The fix keeps tracking the stop past the control client's timeout, with a bound, and does not
treat it as joined when the bound passes. `surfaceFailure` sends it on its own copy of the control
client whose request and resource timeouts are `failedAttemptStopTimeout` (30 s), so after a Retry
it is no longer cut off by the recovery client's 5 s. An HTTP answer of any status counts as
answered. No answer within the bound (or a transport error at once) sets
`failedAttemptStopUnconfirmed` for that failure. The Retry tap then re-sends the stop once
(`joinFailedAttemptStop`, which the restart-from-failure path can share), bypassing the
`sentTranscodeStop` latch, bounded by `failedAttemptRestopTimeout` (10 s). Both bounds are
judgment calls. If PMS answers, the flag is cleared and Retry restarts; if not, Retry surfaces
`priorSessionStopUnconfirmed` (LS-PB-008), starts nothing and clears `failureRetryTask`, so the
next tap tries again. Each tap makes at most one request and waits at most the bound. The trace
now ends in `RetryRestops` and `RetryRefused`, or in `RetryRestopConfirmed` and a restart.

What it does not fence (`Finding-RetryRestopDoesNotFence`, conditional on
`CancelledStopCanLand`, #536; 14 states): the re-send is answered, Retry restarts under the same
session id, and the first stop, which the client stopped waiting for, is applied and ends the
replacement. On Plex the session id is always reused, so the fix narrows the route (a second stop
must be answered first) but does not close it; only PMS dropping an abandoned request, or a fresh
session id per restart, would. `Current-LateFail` therefore still leaves out
`LiveStopNeverKillsSuccessor`, now owned by that finding. `Current-LateFailNoLanding` is that
finding with `CancelledStopCanLand = FALSE` and passes with the property checked: the server
assumption is the only gap left.

### The consent choice shows over a running copy job (`Finding-ConsentShowsOverRunningJob`)

`ConsentBoundary` is violated in 11 states with late stops; no server assumption.

| Step | Model | Swift |
| --- | --- | --- |
| 1 to 4 | `Start`, `TaskIssuesStart`, `ServerStarts`, `TaskAttaches`: the copy lane plays | |
| 5 | `PlayerNeedsConsent`: the copy lane fails | `handlePlaybackFailure` 5073 to 5093: `beginStreaming` |
| 6 | `TaskSendsStop`: the rebuild's stop | 2767 |
| 7 | `ClockTicks`: two seconds, no answer | 2744 to 2746 |
| 8 | `TaskAsksConsent`: the wait gave up and cancelled the request; the copy lane failed, so `requestVideoTranscodeConsent` detaches and sends a second stop | 2956 to 2959; 2512, 2514 |
| 9 | `ClockTicks`: two seconds again | |
| 10 | `ConsentShows`: `stopPreviousTranscode` returns with its result discarded, and the choice shows | 2531 to 2533 |

The copy job may still be running when the user is asked whether to start an encoder:
"Stop any copy/audio-conversion job before presenting the choice" (2502) holds only while each stop
is answered within two seconds. Emby's consent request awaits an acknowledged stop and fails with
LS-PB-008 otherwise (`ConsentRequiresAck` there); Plex has no such check.

### Conditional: the consent request's cancelled stop ends the approved encode (`Finding-CancelledConsentStopKillsApproved`)

`StopNeverKillsSuccessor` is violated in 17 states with late stops and `CancelledStopCanLand`, with
the user's one action Approve and the Approve restart's own stop answered in time
(`CONSTRAINT ConsentRoute`; without it TLC shows the shorter give-up in the Approve restart itself,
which is `Finding-LateStopKillsReplacement`'s route). Steps 1 to 7 as above, but the rebuild's stop
is acknowledged; then `TaskAsksConsent` sends the consent request's stop, it gives up after two
seconds (`ConsentShows`), the user approves (`approveVideoTranscoding` 2536, `beginStreaming`),
the Approve restart's stop is sent and acknowledged, the encode starts, and the consent request's
stop, cancelled by its task group (2746), is applied and ends it. It needs that stop delayed past
the user's decision, which fits the 60 s default client better than the 5 s recovery client.

### Proposed fixes

`Proposed-StartAfterOwnStops` and `Proposed-Liveness` turn on:

- `FixStartAfterOwnStops`: no start request goes out while a stop of this controller's is
  unanswered. That is one rule for all four stale-stop routes: the wait that gave up, the stop
  of a cancelled restart, the failure's detached stop, and Retry's existing join. A client
  cannot hear the fate of a request it cancelled, so the fix also means the stop is a tracked
  request that neither the two-second bound nor a cancelled task cancels (`AbandonedStop` is
  empty with the fix on). The wait is no
  longer bounded by two seconds, so it leans on the request's own timeout (5 s on the recovery
  client that Retry switches to, 60 s otherwise); `Mutant-UnboundedStopWait` is what it costs if
  a stop is never answered at all.
- `FixRestartResetsStopLatch`, from the restart core. Shipping since #527 (`TRUE` in every
  config but its `Faithful` one).

With both, every property holds in full under late and lost stops and restarts from a
failure, given `StopEndsAllUnderId`, and `Faithful-RetryAfterTimedOutStop-off`'s route is closed too: a
detached stop past its `URLSession` timeout still counts as unanswered. The model's fix waits for
the server's outcome, which a request that timed out never reports to the client, so in Swift the
fix needs the stop tracked past its timeout (or Retry to treat a timed-out exact-session stop as
not joined), not only a guard on the join's return. The late start is not addressed (`LateStarts` is off
there); the restart core's `FixJoinCancelledTasks` does not help it either, since the stop has
already gone when the start lands.

Not modelled: minting a session id per restart. A stale stop could then never reach a
replacement whatever PMS does, and `StopEndsAllUnderId` would stop mattering.

## For the Emby and Jellyfin modules

- The base gained `StopEndsAllUnderId`; every config assigns it. `FALSE` is the choice that
  assumes nothing.
- `TouchedReq` and `Ended(s)` read which stop a base server action resolved and which jobs it
  ended, from the primed variables in the same step. That is how this module keeps a ghost
  beside `ServerAck` without changing the base.
- A stop sent before the job it could reach exists needs an incarnation that is never started
  (`Blank`), or `Owned` will treat a later job as already stopped.
