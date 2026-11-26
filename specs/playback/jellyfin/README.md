# jellyfin: the Jellyfin replacement order

`PlaybackJellyfin.tla` models how `PlaybackController` replaces a Jellyfin stream. Every
negotiation returns a play-session id the server minted. A reopen captures the playing session's
stop callback and id, detaches the old item, negotiates, attaches the replacement, and only then
schedules the old session's stop on an unstructured `Task` that sleeps two seconds and calls it
(`scheduleDeferredRemoteSessionStop`). The stop is skipped when the replacement came back under
the captured id (`RemoteStreamLifecyclePolicy.priorSessionStopDecision`, commit `94a9ca4e`).

```sh
scripts/check-tla-specs.sh specs/playback/jellyfin
scripts/check-tla-specs.sh --deep specs/playback/jellyfin/Deep-BackToBack.cfg
```

What the model shows:

- With one controller, no consent, every stop answered or failed within its request timeout, and
  no second replacement or Retry started while the first one's cleanup is still under way, the
  order as it stands keeps `OneEncoder` and `NoOrphans` (`Current-Reopen`), and
  `StopNeverKillsSuccessor` under id reuse given a server that ends a job when it returns that
  job's id again: the server the same-id skip is written for (`Current-ReusedId`). With quick
  reopens and Retry, `NoOrphans` still holds (`Current-QuickReopen`); only `OneEncoder` fails.
- **Fixed (#539): a stop that timed out no longer defeats Retry's join.** `retry()` awaits
  `waitForPendingStopRequests`, which returns when the failed session's stop request times out.
  The failure's stop now goes through `onStopAcknowledged`. When it was not acknowledged (timed
  out, failed, or never connected), each Retry tap re-sends it once, bounded, and negotiates only
  if the re-send is acknowledged; otherwise it fails with `priorSessionStopUnconfirmed`
  (LS-PB-008) and the next tap tries again, as Emby's barrier re-runs a retained failed stop
  (`RetryNeedsConfirmedStop`, `RetryRestops`, `RetryRestopConfirmed`, `RetryRefused`). With late
  stops and Retry, `OneEncoder` holds (`Current-LateRetry`); without the check the replacement
  attaches beside the failed session's job (`Faithful-RetryAfterTimedOutStop-off`) and, under id
  reuse, the timed-out stop ends it (`Faithful-RetryAfterTimedOutStop-ReusedId-off`). Still open,
  both conditional on id reuse and on a stop the client abandoned still being applied (#536): an
  acknowledged re-send does not fence the abandoned first stop, which can still end the Retry's
  replacement (`Finding-RetryRestopDoesNotFence-ReusedId`); and a *rejected result's* stop that
  timed out in the task the failure cancelled is joined the same way
  (`Finding-RetryAfterTimedOutRejectStop-ReusedId`, the `Finding-RejectedStopKillsReusedId`
  family). A quality or track change after the timeout
  overlaps the same way (the route of `Finding-RestartFromFailureOverlap`, here with no quick
  reopen; #530). Late stops without failures pass (`Current-LateStops`).
- The skip of `94a9ca4e` is what keeps a reused id safe: without it the deferred stop ends the
  replacement (`Faithful-JellyfinReusedIdStop-off`).
- **Suspect 3 is reproduced, conditional on the server.** The deferred stop is unfenced, is not
  cancelled or joined by `stop()`, is not joined by `retry()`, and the skip compares only against
  the immediate successor. If the server can return the id of a session that is still running
  (`IdReuse = "live"`), a second reopen (`Finding-DeferredStopUnfenced`) or a Retry
  (`Finding-DeferredStopUnfenced-Retry`) inside the two-second sleep gets that id, and the
  deferred stop ends the replacement. The join half needs no server assumption:
  `Finding-DeferredStopNotJoined`. It is refuted for servers that never reuse an id, reuse only
  the id they minted last, or reuse only ids with nothing running under them.
- Three findings need no server assumption:
  - `requestVideoTranscodeConsent` sets `session.didStop = true` after its await, with no check, on
    the one session object a reopen may have reloaded meanwhile. The new session is then never
    stopped, and a later consent choice shows over its running encoder
    (`Finding-ConsentClobbersDidStop`). The consent request `handlePlaybackFailure` starts is a
    second route into it (`Finding-ConsentClobbersDidStop-PlayerFailure`).
  - Jellyfin has no transaction tail. A quick second reopen negotiates while the first one's
    result is still to be rejected and the session before both still runs: three jobs at once
    (`Finding-ThirdEncoder`). Two quick reopens that both attach leave the first two sessions
    asleep on their deferred stops while the third plays (`Finding-ThirdEncoder-Attached`).
  - A quality or track change while a failure shows reopens without the join `retry()` has, so the
    failed attempt's session overlaps the replacement past the window
    (`Finding-RestartFromFailureOverlap`).
- `stop()` does not join the task it cancels (`Finding-StopNoJoin`, the restart core's finding).
- Four more stale-stop routes need id reuse: a rejected result's stop that the next negotiation
  does not wait for, through a reopen or through Retry (`Finding-RejectedStopKillsReusedId`,
  `-Retry`); a restart while a failure shows, which does not wait for the failed attempt's stop
  (`Finding-RestartFromFailureStaleStop`); and a closing playback's stop reaching the next one
  (`Finding-BackToBackStaleStop`). A server that keeps the old job running under a returned id
  leaves the skipped prior with no stop (`Finding-SameIdSkipLeavesPrior`).
- `ServerRecreate` (the 2026-09-17 audit's job made again from an accepted HLS request) is on in
  every config and judged against the server.

None of the findings has been reproduced in the app or against a server.

## What is modelled

Each MainActor run between two awaits is one action. Functions are in
`Labstream/Shared/Player/PlaybackController.swift` unless another file is named. Line numbers
are as of commit `abe0feab`; none of the modelled files changed after `0b7f3fcb`
(`RemoteStreamLifecyclePolicy.swift` after `bf77f609`, `DetailPlaybackLauncher.swift` after
`fa787dae`).

| Model | Swift |
| --- | --- |
| `Start` | `start()` with `beginRemoteStream` (3232). `DetailPlaybackLauncher` negotiated the first session before the controller existed (`DetailPlaybackLauncher.open`), so its job runs and its callbacks are installed |
| `Reopen` | a settled seek outside the buffer (5697), `reload(bitrateKbps:)` (2470) and the track changes through `restartAtCurrentPosition` (5710), and the MediaBrowser branch of `attemptStartupDeadlineRetry` (5463), each ending in `reopenRemoteStream` (5750) |
| `ReopenCore` | the synchronous part of `reopenRemoteStream`: `playbackTask?.cancel()` 5766, the generation bump, `priorStop = didStopRemoteSession ? nil : onStopRemoteSession` 5770, `priorPlaySessionId` 5771, the detach 5777 to 5780, the task at 5808. The Emby branch (5782 to 5800) is not taken |
| `TaskBegins` | `await predecessor?.value` (nil for Jellyfin, 5811), the first `acceptsReopenResult` check, and `remoteStreamReopener(request)` 5839 |
| `NegotiateLands` | Jellyfin answers the PlaybackInfo request (`JellyfinPlayback.playbackInfoRequest`, `PMSKit/Sources/PMSKit/Jellyfin/JellyfinPlayback.swift` 139). The request carries no play-session id; the id is read from the response (`resolveMediaBrowserStream`, 285) |
| `TaskAttaches` | `playableRemoteStreamURL` returns a URL; the new callbacks are installed and `didStopRemoteSession = false` (5885 to 5888), `loadRemoteStream` 5890, then `priorSessionStopDecision` (5891 to 5901; `RemoteStreamLifecyclePolicy.swift` 27 to 35) |
| `DeferredFires` | the body of `scheduleDeferredRemoteSessionStop` (5929 to 5941): `try? await Task.sleep` 5938, `stop()` 5939, which is the session's `onStop`, `DetailPlaybackLauncher.stopActiveEncoding(remote:)` (261 to 265): another `Task` that sends the request |
| `TaskRejects`, `RejectHeld`, `TaskRejectDone` | `stopRejectedRemoteStream` (5844, 5859, 5919 to 5927) with `stopAndWaitIgnoringCancellation` (`PlaybackSessionSource.swift` 65) |
| `TaskUnwindExit` | the `catch` of a cancelled task (5903 to 5907) |
| `NegotiateFails` | the `catch` of the current task: `surfaceFailure(error)` 5913 |
| `TaskNeedsConsent`, `InitialNeedsConsent`, `ConsentStopDone` | `prepareRemoteStreamURL` calling `requestVideoTranscodeConsent` (3342, 3359, 3372; 2504 to 2534), split at `await stop()` 2525; `session.didStop = true` 2528; the generation check 2531; `videoTranscodeConsent.generation = generation` 2533 |
| `InitialRuns` | the task in `beginRemoteStream` (3239 to 3253) |
| `PlayerNeedsConsent` | the branch of `handlePlaybackFailure` (5058 to 5069) that cancels the task, bumps the generation and starts a task running `requestVideoTranscodeConsent`; that task then takes `InitialNeedsConsent` and `ConsentStopDone`, or returns at its first guard (`InitialRuns`) if it was cancelled first |
| `Approve`, `Decline` | `approveVideoTranscoding` 2536 (it sets `videoTranscodeApprovedForCurrentItem`, which `PlayerNeedsConsent` reads), `declineVideoTranscoding` 2549 |
| `Retry`, `RetryProceeds` | `retry()`, `failureRetryTask` with `waitForPendingStopRequests` and `restartAtCurrentPosition` |
| `StopUnconfirmed`, `st.failStop` | `failedAttemptStopUnconfirmed`: set by `trackFailedAttemptStop` when the failure's `onStopAcknowledged` (`stopRemoteSessionIfNeeded(tracksFailedAttempt: true)` from `surfaceFailure`) returns false in the failure's generation; reset by each `surfaceFailure`, cleared by an acknowledged re-send |
| `RetryRestops`, `st.restop` | `joinFailedAttemptStop` after the join: `resendFailedAttemptStop` re-runs `failedAttemptSessionStop` (kept after `didStop`) once, as a `pendingStopTasks` entry, bounded by `failedAttemptRestopTimeout` (10 s). Not while a reopen from the error overlay runs (`playbackTask != nil`, `task[c] # NoTask`); that tap is refused |
| `RetryRestopConfirmed`, `RetryRefused` | the generation and cancellation check after the re-send: acknowledged clears the flag and `restartAtCurrentPosition` runs; otherwise `playbackError.set(PlaybackFailure(code: .priorSessionStopUnconfirmed))` with `failureRetryTask` cleared, so the next tap re-sends again. A cancelled or superseded task does nothing (Close resets `restop`) |
| `Close` | `stop()` 1135: the task cancelled and dropped at 1181 to 1182, the detach 1201, `stopRemoteSessionIfNeeded` 1203 |
| `SurfaceFailure`, `StopsNow` | `surfaceFailure` 5133 (the cancelled task joined at 5155 to 5158, `stopRemoteSessionIfNeeded` 5178); `stopRemoteSessionIfNeeded` 1255 for Jellyfin: `onStopAndWait` as a `pendingStopTasks` entry at 1268 |
| `Fail` | `handlePlaybackFailure` and the watchdogs that end in `surfaceFailure` |
| `Accepts` | `RemoteStreamLifecyclePolicy.acceptsReopenResult` and the `guard !Task.isCancelled, generation == playbackGeneration` checks |
| `Joined` | `waitForPendingStopRequests` (1236) |
| `ServerResolves`, `ServerRecreates`, `ClockTicks` | Jellyfin applies a `DELETE /Videos/ActiveEncodings` for a device and play-session id (`JellyfinLibrary.activeEncodingStopRequest`), or it ends unacknowledged; the server remakes a stopped job; the request timeout passes for a stop somebody awaits |

The module's `MODELS` lines name, beside `PlaybackController.swift`, `JellyfinPlayback.swift` and
`RemoteStreamLifecyclePolicy.swift`: `DetailPlaybackLauncher.swift` (the first session and the
stop closures: `DeferredFires` is `stopActiveEncoding(remote:)`'s extra `Task`),
`PlaybackSessionSource.swift` (`stopAndWaitIgnoringCancellation`, which `TaskRejects` encodes, and
the one `MediaBrowserPlaybackSession` object #531 rests on), and
`PMSKit/Sources/PMSKit/MediaBrowser/MediaBrowserPlaybackPolicy.swift` with
`MediaBrowserActiveEncodingStopExecutor.swift` (a transport error, a timeout included, ends the
stop unacknowledged, so the awaiting closure returns: `ReqDone`'s timeout).

A task is `[gen, pc, sid, inc, kind, prior, psid, rq]`: the generation it captured, where it is,
the session its negotiation returned, whether it is the first start or a reopen, the stop it
captured (`priorStop`), the id it captured (`priorPlaySessionId`), and the stop request it awaits.

| `pc` | The task is at |
| --- | --- |
| `begin` | created, not yet run |
| `negotiate` | `try await remoteStreamReopener(request)`, the request on the wire |
| `negotiated` | the answer is back and the task holds a session, up to the end of `playableRemoteStreamURL` |
| `consentStop` | `await stop()` in `requestVideoTranscodeConsent` |
| `rejectStop` | `await` in `stopRejectedRemoteStream` |

`st[c].cur` is the session whose callbacks the controller's one `MediaBrowserPlaybackSession`
holds and `st[c].didStop` its `didStop`. `sessionSource` is a `let` (173) and
`mediaBrowserSession` returns that same object (180), so every reopen reloads the same object in
place; this is what makes the consent finding possible. `deferred[c]` holds the prior-session
stops still asleep. Their `Task` captures only the callback, so they fire after Close too.

### How a stop is judged

A Jellyfin stop is a closure over one negotiated session, so the incarnation it means is known.
`StopNeverKillsSuccessor` is the base's `NoWrongKill` less two cases the client wanted anyway: a
job whose own stop the client had already sent, and a job a cancelled task holds and is about to
reject. Both happen on the current code without harm, for example Close's stop for the playing
session ending a reopen result under the same id that the cancelled reopen task then rejects
(witness: `NoWrongKill` is violated in `Current-ReusedId`, which passes). The ghost `harm`
records each other wrong kill when the server step makes it (`Harmed(s)`).

### The window

`jellyfinWindow` is the base's replace-then-clean-up window: from the replacement request to the
end of the prior session's deferred cleanup. It is recomputed after every step (`SetsWindow` in
`Next`, so a server step can close it) and is open while a reopen task runs, a deferred stop
sleeps, or the stop of a prior session whose deferred stop went out (`ghost.fired`), or of a
rejected result, is unanswered. The rejected results belong to the same cleanup: Close during a
reopen leaves the prior's and the rejected result's stops both in flight, and without that clause
`Current-Reopen` fails `OneEncoder` there. Inside the window `OneEncoder` allows two jobs, outside
it one. A stop sent by Close, `surfaceFailure` or a consent request does not hold the window open,
so a replacement that overlaps such a session past the window fails `OneEncoder`
(`Finding-RestartFromFailureOverlap`; `Mutant-RetrySkipsJoin-Overlap` is the same overlap made by
removing Retry's join). `WindowCloses` (liveness) checks that the window closes, and
`Mutant-WindowStaysOpen` is a window that never closes once open. This recomputation is the one
place server steps change controller state (a ghost) beside the base contract's
`UNCHANGED ctlVars`.

### User timing

`QuickReopen` and `QuickRetry` say whether the user (or an automatic reopen) may start another
replacement (a reopen or `Approve`), or tap Retry, while cleanup is under way
(`CleanupUnderway`): a reopen task runs, a deferred stop sleeps, a stop the controller sent is
unanswered and still inside its request timeout, or a task still awaits a stop. In practice that
is within about two seconds of the last replacement, or before its stops are answered or time
out. A stop past its request timeout does not count: the client has stopped waiting for it, and a
user who taps Retry ten seconds later is not "quick". They are environment assumptions, not
client guards. The Current configs take `FALSE`, and every finding that needs `TRUE` says so.

An earlier version counted every unanswered stop, a timed-out one included, which stays on the
wire for good in the model. `QuickRetry = FALSE` then blocked Retry for ever after any timed-out
stop, far more than the two seconds the assumption stands for, and hid what was
`Finding-RetryAfterTimedOutStop` (#539, now `Faithful-RetryAfterTimedOutStop-off`).

## What Jellyfin does

Three server behaviours decide results, and the repository does not settle all of them. No live
server was queried for this model.

| Evidence in the repository | Says |
| --- | --- |
| `JellyfinPlayback.playbackInfoRequest` and `resolveMediaBrowserStream` | The PlaybackInfo request carries no play-session id; the server mints it, once per negotiation. |
| `JellyfinBrowseService.stopActiveEncoding` and `JellyfinLibrary.activeEncodingStopRequest` | A stop names the device (`identity.clientIdentifier`, the same for every controller) and the play-session id. |
| `docs/evidence/audits/2026-09-17-jellyfin-terminal-cleanup.md` ("Server implementation boundary") | The server's stop selects a snapshot of the matching active jobs, and a job can be made again from an already accepted segment request. |
| `RemoteStreamLifecyclePolicy.priorSessionStopDecision` and commit `94a9ca4e` | The code is written for a server that may return the replaced session's id for its replacement while that session still runs. Nothing records Jellyfin doing so. |

So the model was run under each assumption:

| Assumption | Values |
| --- | --- |
| `IdReuse` | `"never"`; `"latest"`: also the id the server minted last for this device; `"stopped"`: also a used id with nothing running under it; `"live"`: any used id, the setting that assumes nothing |
| `ReusedIdReplacesJob` | `TRUE`: a job still running under a returned id ends as the new one starts, the server the skip needs. `FALSE`: both run |
| `StopEndsAllUnderId` (base) | `TRUE` where ids are reused, from the audit's reading of the server's stop (a snapshot of every matching job). `FALSE` where it changes nothing |
| `IdsNeverShared` (base) | `FALSE` with two controllers: the server mints the id and the stop names one device for both |

What depends on them:

- `"never"`: no stale stop can reach anything (`Current-Reopen`, where `StopNeverKillsSuccessor`
  cannot fail and is checked elsewhere).
- `"latest"` with `ReusedIdReplacesJob`: `Current-ReusedId` passes; the skip is what makes it
  pass. Without `ReusedIdReplacesJob`: `Finding-SameIdSkipLeavesPrior`. With quick reopens,
  quick Retry during a restart, a restart while a failure shows, or two controllers: the four
  stale-stop findings above.
- `"live"`: suspect 3. A deferred stop meant for the session two back reaches a replacement
  that came back under that session's id.
- `"stopped"`: no stale stop reaches anything, because a stop that has not been answered keeps
  its job running. `Deep-BackToBack` uses it to let the second playback reuse the first one's
  ids.
- `StopEndsAllUnderId = FALSE` with reuse fails `OneEncoder` in `Current-ReusedId`'s run: an
  acknowledged stop ends only a recreated older job under the id and leaves the one it meant.

## What is abstracted, and why

- **What the restart core covers** is left out: seeks and their budget, pause intent and the
  loopback proxy. `seekHold`, `budget`, `paused` and `proxy` never change.
- **Shared helpers.** `Detached`, `Running`, `EndTask` and `SetTask` are copied from
  `PlaybackEmby`. That module cannot be instantiated here without supplying its twenty constants
  and four variables, and `PlaybackControllerOps` has no home for them; adding one there means a
  base change that every module rebases onto. Moving them into the base is left to the review.
- **A PlaybackInfo answer is a running job**, as the base says (contract, 7). Jellyfin probably
  starts the encoder at the first HLS request, which the client makes only after attaching. This
  is the cautious reading, and it is what the Swift assumes when it stops a rejected result. It
  matters for `Finding-ThirdEncoder`: only its variant with an attached second job is certain to
  have three encoders.
- **`StartJobReplacing`** repeats the base's `StartJob` with the replacement assumption, because
  the base never ends a job on a start.
- **`playableRemoteStreamURL`'s awaits** (the copy playlist, the prewarm) are folded into
  `negotiated`. Inside a reopen, `requestVideoTranscodeConsent` returning and
  `stopRejectedRemoteStream` sending its request are one step.
- **The consent request from `handlePlaybackFailure`** (`PlayerNeedsConsent`) is taken only with
  an attached item and no task running, and not once the item's encoding was approved, as Emby's.
  `reload` clears the approval (2475): a `Reopen` step is either a reload, which clears it, or a
  seek or track change, which keeps it.
  Its Original-quality condition (`maxVideoBitrateKbps <= 0`) is not modelled.
- **Left out:** direct play, whose stop sends no request;
  the progress stop (`Sessions/Playing/Stopped`), which is not an encoder stop; a stale auth
  context (phase 3); a cancelled negotiation the server still acts on (Emby's
  `Finding-AbandonedNegotiateOrphans` applies unchanged, and is less likely for Jellyfin given the
  item above).
- **Time.** The two-second sleep is `DeferredFires`, which can come at any point. The request
  timeout is `ClockTicks`, for a stop a task or a `pendingStopTasks` entry awaits; the request then
  stays on the wire.
- **`ServerRecreate`** is always enabled and judged against the server, as the base intends
  (`RecreateCountsAgainstServer = TRUE` everywhere).
- **Automatic reopens** (the startup-deadline reopen) are `Reopen` steps and count against
  `MaxUserActions`.
- **The consent overlay.** No reopen starts while a choice shows, apart from `Approve`.

## Bounds

- One controller unless noted. `MaxGeneration` bounds `playbackGeneration` and the incarnations
  under one id. `GenerationsSuffice` is checked in every passing safety config: no guard on a
  generation counter ever disables an action. It fails with `MaxGeneration = 11` in
  `Current-ReopenSmall`, so the bound is tight. The consent configs take `MaxGeneration = 15`:
  the consent request from a failing item bumps the generation without a user action, and
  `GenerationsSuffice` fails at 14 in `Current-Consent`.
- `MaxUserActions` bounds reopens, approvals and Retry taps together. Close, one failure per
  attempt and consent requests are always available.
- `SessionIds`: with `IdReuse = "never"` each negotiation uses one, so a config has one more id
  than user actions per controller. `IdsSuffice` checks that a request on the wire always has an
  id the server can return; it fails in `Deep-BackToBack` with three ids.

## Properties

| Property | Kind | Meaning |
| --- | --- | --- |
| `OneEncoder` (base) | invariant | At most one job the client still owns, two inside the window. **Violated by the code with a quick second reopen (`Finding-ThirdEncoder`), a quick restart while a failure shows (`Finding-RestartFromFailureOverlap`) and through the consent finding; conditionally by the skip. Retry after a stop that timed out no longer violates it (#539, `Current-LateRetry`).** |
| `OneEncoderWhilePlaying` | invariant | `OneEncoder` in the states where a replacement plays and no task runs. Only `Finding-ThirdEncoder-Attached` checks it, to pin the attached shape. |
| `StopNeverKillsSuccessor` | invariant | No stop meant for an older job under an id ends a newer one the client still wanted. **Violated by the code if Jellyfin reuses ids (conditional), suspect 3 included.** |
| `NoOrphans` | invariant | Every live job of the controller's is the playing session, held by a task that will attach or stop it, asleep on a deferred stop, or has had a stop sent; and after Close, or while a failure shows with nothing under way, the playing session has had its stop sent. **Violated by the code (`Finding-ConsentClobbersDidStop`).** |
| `ConsentBoundary` | invariant | While a consent choice shows, nothing is attached and the playing session's stop and every rejected session's stop have been sent. **Violated by the code through the consent finding.** |
| `JoinCoversCleanup` | invariant | Once `waitForPendingStopRequests` would return after Close, no task holds a session to stop, no request is on the wire, no deferred stop sleeps, and every stop sent was answered or timed out. **Violated by the code (suspects 3 and 4).** |
| `GenerationsSuffice`, `IdsSuffice` | invariant | The bounds are never what stops a behaviour. |
| `ReopenSettles` | liveness | A start, reopen or consent request ends. |
| `CloseCleansUp` | liveness | After Close every task returns, the joined cleanup ends and every deferred stop has gone out. |
| `WindowCloses` | liveness | The replace-then-clean-up window closes. |

Liveness is checked under `FairSpec` (every stop is answered or fails) and `ClockFairSpec` (no
stop is ever answered; only the request timeout runs). Under `ClockFairSpec` the window kept open
by a stop nobody awaits never closes, so `WindowCloses` is checked under `FairSpec` only (checked
by hand: it fails under `ClockFairSpec`).

## Configs and results

2026-11-25, tla2tools v1.7.4, `TLC_WORKERS=auto TLC_HEAP=4g`. Unless noted: one controller, three
session ids, two user actions, `MaxGeneration = 12`, failures, restarts from a failure and
failing stops on, consent, late stops, quick reopens and quick Retry off, `IdReuse = "never"`,
`ReusedIdReplacesJob = FALSE`, `StopEndsAllUnderId = FALSE`, `IdsNeverShared = TRUE`, and the
shipping value of every behaviour constant.

| Config | Built from | Expect | Result | Distinct states | Time |
| --- | --- | --- | --- | --- | --- |
| `Current-ReopenSmall` | — | pass | pass | 43,146 | 1 s |
| `Current-Reopen` | — | pass | pass | 723,971 | 5 s |
| `Current-LateStops` | `Current-Reopen` + `StopsCanBeLate` − `EnvFails`, `RestartFromFailure` | pass | pass | 38,913 | 1 s |
| `Current-LateFail` | `Current-ReopenSmall` + `StopsCanBeLate` | pass | pass (`OneEncoder` not checked; the restart route, `Finding-RestartFromFailureOverlap`, owns it) | 153,876 | 4 s |
| `Current-LateRetry` | `Current-ReopenSmall` + `StopsCanBeLate` − `RestartFromFailure` | pass | pass (every invariant, `OneEncoder` included) | 256,833 | 3 s |
| `Current-ReusedId` | — | pass | pass (given `"latest"` reuse that replaces the job, `StopEndsAllUnderId`) | 233,522 | 2 s |
| `Current-Consent` | `Current-ReopenSmall` + `ConsentPossible`, `MaxGeneration = 15` | pass | pass (no reopen while a task awaits a stop) | 2,221,320 | 12 s |
| `Current-QuickRetry` | `Current-ReopenSmall` + `QuickRetry` | pass | pass | 55,495 | 1 s |
| `Current-QuickReopen` | `Current-ReopenSmall` + `QuickReopen`, `QuickRetry` | pass | pass (`OneEncoder` not checked) | 97,540 | 2 s |
| `Liveness-Reopen` | — | pass | pass | 33,430 | 4 s |
| `Liveness-BoundedWait` | — | pass | pass | 271,978 | 21 s |
| `Faithful-JellyfinReusedIdStop-off` | `Current-ReusedId` − `SkipsReusedIdStop` | `StopNeverKillsSuccessor` violated | violated | stops at first error | 1 s |
| `Mutant-NoDeferredStop` | `Current-ReopenSmall` − `DefersPriorStop` | `OneEncoder` violated | violated | stops at first error | 1 s |
| `Mutant-RejectedNotStopped` | `Current-ReopenSmall` − `RejectedIsStopped` | `NoOrphans` violated | violated | stops at first error | 1 s |
| `Mutant-CloseSkipsFinalStop` | `Current-ReopenSmall` − `CloseStopsSession` | `NoOrphans` violated | violated | stops at first error | 0 s |
| `Mutant-RetrySkipsJoin` | `Current-ReusedId` − `RetryJoinsPendingStops` | `StopNeverKillsSuccessor` violated | violated | stops at first error | 1 s |
| `Mutant-RetrySkipsJoin-Overlap` | `Current-QuickRetry` − `RetryJoinsPendingStops` | `OneEncoder` violated | violated | stops at first error | 1 s |
| `Mutant-ConsentSkipsStop` | `Current-Consent` − `ConsentStopsSession` | `ConsentBoundary` violated | violated | stops at first error | 1 s |
| `Mutant-ConsentAttachesNegotiated` | `Current-Consent` − `ConsentRejectsNegotiated` | `ConsentBoundary` violated | violated | stops at first error | 1 s |
| `Mutant-WindowStaysOpen` | `Liveness-Reopen` − `WindowEndsWithCleanup` | `WindowCloses` (temporal) violated | violated | stops at first error | 7 s |
| `Mutant-UnboundedStopWait` | `Liveness-BoundedWait` − `StopTimesOut` (only `ReopenSettles` listed) | `ReopenSettles` (temporal) violated | violated | stops at first error | 3 s |
| `Finding-ThirdEncoder` | `Current-ReopenSmall` + `QuickReopen` | `OneEncoder` violated | violated | stops at first error | 1 s |
| `Finding-ThirdEncoder-Attached` | `Finding-ThirdEncoder` − `EnvFails`, `RestartFromFailure` | `OneEncoderWhilePlaying` violated | violated | stops at first error | 1 s |
| `Finding-RestartFromFailureOverlap` | `Current-ReopenSmall` + `QuickReopen`, one user action | `OneEncoder` violated | violated | stops at first error | 1 s |
| `Faithful-RetryAfterTimedOutStop-off` | `Current-LateRetry` − `RetryNeedsConfirmedStop` | `OneEncoder` violated | violated | stops at first error | 2 s |
| `Finding-ConsentClobbersDidStop` | `Current-Consent` + `QuickReopen` | `NoOrphans` violated | violated | stops at first error | 1 s |
| `Finding-ConsentClobbersDidStop-PlayerFailure` | `Finding-ConsentClobbersDidStop`, route constraint | `NoOrphans` violated | violated | stops at first error | 1 s |
| `Finding-StopNoJoin` | `Current-ReopenSmall` | `JoinCoversCleanup` violated | violated | stops at first error | 1 s |
| `Finding-DeferredStopNotJoined` | `Current-ReopenSmall` + `FixCloseJoinsTask` | `JoinCoversCleanup` violated | violated | stops at first error | 1 s |
| `Finding-DeferredStopUnfenced` (conditional) | `Current-ReusedId` + `"live"`, `QuickReopen`, `RestartFromFailure` − `QuickRetry`, `EnvFails`, route constraint | `StopNeverKillsSuccessor` violated | violated | stops at first error | 2 s |
| `Finding-DeferredStopUnfenced-Retry` (conditional) | `Current-ReusedId` + `"live"`, route constraint | `StopNeverKillsSuccessor` violated | violated | stops at first error | 1 s |
| `Finding-RejectedStopKillsReusedId` (conditional) | `Current-ReusedId` + `QuickReopen` − `QuickRetry` | `StopNeverKillsSuccessor` violated | violated | stops at first error | 1 s |
| `Finding-RejectedStopKillsReusedId-Retry` (conditional) | `Current-ReusedId` + `RestartFromFailure` | `StopNeverKillsSuccessor` violated | violated | stops at first error | 1 s |
| `Finding-RestartFromFailureStaleStop` (conditional) | `Current-ReusedId` + `RestartFromFailure`, `QuickReopen` − `QuickRetry` | `StopNeverKillsSuccessor` violated | violated | stops at first error | 1 s |
| `Faithful-RetryAfterTimedOutStop-ReusedId-off` (conditional) | `Current-ReusedId` + `StopsCanBeLate` − `RetryNeedsConfirmedStop` | `StopNeverKillsSuccessor` violated | violated | stops at first error | 2 s |
| `Finding-RetryRestopDoesNotFence-ReusedId` (conditional, #536) | `Current-ReusedId` + `StopsCanBeLate`, one user action | `StopNeverKillsSuccessor` violated | violated | stops at first error | 2 s |
| `Finding-RetryAfterTimedOutRejectStop-ReusedId` (conditional, #536) | `Current-ReusedId` + `StopsCanBeLate` | `StopNeverKillsSuccessor` violated | violated | stops at first error | 2 s |
| `Finding-SameIdSkipLeavesPrior` (conditional) | `Current-ReusedId` − `ReusedIdReplacesJob` | `OneEncoder` violated | violated | stops at first error | 1 s |
| `Finding-BackToBackStaleStop` (conditional) | two controllers, see the config | `StopNeverKillsSuccessor` violated | violated | stops at first error | 1 s |
| `Proposed-CloseJoins` | `Current-ReopenSmall` + both join fixes | pass | pass | 48,176 | 2 s |
| `Proposed-ConsentStopFenced` | `Finding-ConsentClobbersDidStop` + `FixConsentStopFenced` | pass | pass (`OneEncoder` not checked) | 2,274,728 | 11 s |
| `Proposed-TracksDeferredStop` | `Finding-DeferredStopUnfenced-Retry` + `FixTracksDeferredStop`, no constraint | pass | pass (given `StopsCanBeLate = FALSE`) | 270,612 | 2 s |
| `Deep-BackToBack` (deep) | — | pass | pass (given `IdReuse = "stopped"`) | 122,691,237 | 11 min 34 s |

- `Current-Reopen`: three user actions, four session ids, `MaxGeneration = 15`. It checks
  `TypeOK`, `OneEncoder`, `NoOrphans`, `GenerationsSuffice` and `IdsSuffice`. Late stops are off:
  with them `OneEncoder` fails by the restart route (before #539 also by Retry after a timed-out stop)
  (8 states: `Fail`, the stop times out, a quality change while the failure shows, the
  replacement attaches). Before the user-timing gate was corrected the run passed with late
  stops (6,229,375 states) only because a timed-out stop blocked Retry and restarts for ever.
  `Current-LateStops` keeps late stops and drops failures. `Current-LateFail` keeps both on
  `Current-ReopenSmall`'s run and checks every invariant but `OneEncoder`. `StopNeverKillsSuccessor` cannot fail
  without id reuse, so it is listed only in the configs that reuse ids (`Current-ReusedId`, the
  conditional findings, `Proposed-TracksDeferredStop`, `Deep-BackToBack`).
  `Current-ReopenSmall` is its smaller run (two user actions, three ids, `MaxGeneration = 12`),
  committed as the base most other one-controller configs are built from. The "Built from" column names each config's base and the constants it changes
  (+ sets a switch, − clears one); every Mutant and the Faithful config change exactly one.
- `Current-ReusedId` (review focus 2): `IdReuse = "latest"`, `ReusedIdReplacesJob`,
  `StopEndsAllUnderId`, quick Retry, no restart from a failure. The same-id skip is taken
  (witness `NeverSkipped`), ids are reused (`NeverReusedId`) and a job is replaced by id
  (`NeverReplacedById`). `Mutant-RetrySkipsJoin`, `Faithful-JellyfinReusedIdStop-off` and
  `Finding-SameIdSkipLeavesPrior` differ from it in one constant each; the other reuse
  findings differ in the timing and restart constants their routes need, and in `IdReuse`.
- `Current-Consent`: consent on (the first start, a reopen's result and a failing item), every
  invariant including `ConsentBoundary` and `NoOrphans`.
  The two consent mutants differ from it in one constant, `Finding-ConsentClobbersDidStop` in
  `QuickReopen`, and `Proposed-ConsentStopFenced` is the finding's run with the fix: the clobber
  is reachable there, and `NoOrphans`, `ConsentBoundary` and `StopNeverKillsSuccessor` hold.
- `Current-QuickReopen`: quick reopens and Retry, every invariant but `OneEncoder`.
  `Current-QuickRetry`: quick Retry only, every invariant.
- `Liveness-Reopen`: consent, one user action, two ids, `MaxGeneration = 10`, `FairSpec`:
  `ReopenSettles`, `CloseCleansUp`, `WindowCloses`. `Liveness-BoundedWait`: the same with late
  stops under `ClockFairSpec`: `ReopenSettles`, `CloseCleansUp`.
- `Proposed-CloseJoins`: `FixCloseJoinsTask` and `FixTracksDeferredStop`, checking
  `JoinCoversCleanup` beside the rest. `Proposed-TracksDeferredStop`:
  `Finding-DeferredStopUnfenced-Retry`'s constants with `FixTracksDeferredStop` and without its
  route constraint.
- `Deep-BackToBack`: two controllers, four ids, one user action each, `MaxGeneration = 10`,
  `IdsNeverShared = FALSE`, `IdReuse = "stopped"`, `StopEndsAllUnderId`, failing stops, no
  consent, no restart from a failure. The second controller is given an id the first used
  (witness `NeverSharedId`). `Finding-BackToBackStaleStop` is two controllers with
  `"latest"` reuse.

Two Finding configs carry `CONSTRAINT NoRejection` (no state with a rejected result is explored),
so that TLC shows the deferred-stop route rather than the shorter rejected-stop route, and
`Finding-ConsentClobbersDidStop-PlayerFailure` carries `CONSTRAINT NoInitialConsent`, so that it
shows the failing item's consent request rather than the first start's. The constraints are
defined in the module and used nowhere else.

### Faithfulness and mutants

| Config | Flips | Violates | Trace |
| --- | --- | --- | --- |
| `Faithful-JellyfinReusedIdStop-off` | `SkipsReusedIdStop` | `StopNeverKillsSuccessor` | A reopen comes back under the prior's id; the deferred prior stop goes out anyway and ends the replacement (8 states). |
| `Mutant-NoDeferredStop` | `DefersPriorStop` | `OneEncoder` | After a replacement attaches, the prior session runs on with no stop and nothing under way. |
| `Mutant-RejectedNotStopped` | `RejectedIsStopped` | `NoOrphans` | A superseded reopen's result is dropped. |
| `Mutant-CloseSkipsFinalStop` | `CloseStopsSession` | `NoOrphans` | Close with a session playing and no stop. |
| `Mutant-RetrySkipsJoin` | `RetryJoinsPendingStops` | `StopNeverKillsSuccessor` | A failure's stop is in flight, Retry reopens at once and gets the same id, and the stop ends the replacement. |
| `Mutant-RetrySkipsJoin-Overlap` | `RetryJoinsPendingStops` (from `Current-QuickRetry`) | `OneEncoder` | Without id reuse: the failure's stop is still in flight when the Retry's replacement attaches. That session is not a replaced prior, so the overlap lasts past the window. |
| `Faithful-RetryAfterTimedOutStop-off` | `RetryNeedsConfirmedStop` (from `Current-LateRetry`) | `OneEncoder` | The failure's stop times out, Retry's join returns, and the replacement attaches beside the failed session's job (10 states; the trace below). |
| `Faithful-RetryAfterTimedOutStop-ReusedId-off` | `RetryNeedsConfirmedStop` (from `Current-ReusedId` + `StopsCanBeLate`) | `StopNeverKillsSuccessor` | The same with the failed session's id returned: the timed-out stop ends the replacement. |
| `Mutant-ConsentSkipsStop` | `ConsentStopsSession` | `ConsentBoundary` | The choice shows with the session's encoder running and no stop sent. |
| `Mutant-ConsentAttachesNegotiated` | `ConsentRejectsNegotiated` | `ConsentBoundary` | A reopen's result needs consent; the choice shows over the attached result. |
| `Mutant-WindowStaysOpen` | `WindowEndsWithCleanup` | `WindowCloses` | The window opens at the first reopen and never closes. |
| `Mutant-UnboundedStopWait` | `StopTimesOut` | `ReopenSettles` | A consent request waits for ever on a stop that is never answered. |

`GenerationsSuffice` and `IdsSuffice` are checks on the model, failing with smaller bounds (see
Bounds).

### Every branch is taken

Checked as the only invariant, each witness is violated:

| Witness | Constants of |
| --- | --- |
| `NeverDeferred`, `NeverDeferredAfterClose`, `NeverRejected`, `NeverRecreated`, `NeverStopFailed`, `NeverRetryWaits`, `NeverWindowTwo` | `Current-Reopen` |
| `NeverTimedOut` | `Current-LateStops` |
| `NeverRetryRestops`, `NeverRestopConfirmed`, `NeverRetryRefused` (a tap re-sends the failure's stop; the re-send is acknowledged; it is not) | `Current-LateRetry` |
| `NeverSkipped`, `NeverReusedId`, `NeverReplacedById`, `NoWrongKill` (the excused wrong kill) | `Current-ReusedId` |
| `NeverConsentShown`, `NeverPlayerConsent` (the consent request from a failing item) | `Current-Consent` |
| `NeverSharedId` | `Deep-BackToBack` |

No config lists them; to repeat one, copy the named config, replace its `INVARIANTS` with the
witness, set `SPECIFICATION Spec`, and run TLC.

## Findings

Traces are the shortest TLC finds. Line numbers as in [What is modelled](#what-is-modelled).

### Suspect 3: the deferred stop (`Finding-DeferredStopUnfenced`, `-Retry`, `Finding-DeferredStopNotJoined`)

Confirmed in the Swift: the `Task` at 5937 is not stored, so nothing can cancel or join it;
`stop()` (1135) and `surfaceFailure` (5133) do not touch it; `retry()` joins `pendingStopTasks`
(2580), which it is not in; it checks no generation; and the only reuse check is
`priorSessionStopDecision(priorPlaySessionID:reopenedPlaySessionID:)` at 5891, comparing the
captured prior id with the immediate replacement's.

**Reopen path** (`Finding-DeferredStopUnfenced`, 11 states; conditional on `IdReuse = "live"`):

| Step | Model | Swift |
| --- | --- | --- |
| 1 | `Start`: session A under id a | `start()`, `beginRemoteStream` 3232 |
| 2 | `Reopen`: priorStop = A, priorPlaySessionId = a | 5766 to 5780 |
| 3, 4 | `TaskBegins`, `NegotiateLands`: session B under a new id b | 5839 |
| 5 | `TaskAttaches`: B installed; b differs from a, so A's stop is scheduled | 5885 to 5899, 5929 to 5937 |
| 6 | `Reopen` within the two seconds: priorStop = B, priorPlaySessionId = b | 5770, 5771 |
| 7, 8 | `TaskBegins`, `NegotiateLands`: the server returns a, A's id, while A still runs; session C | |
| 9 | `DeferredFires`: A's sleep ends and its stop goes out, naming a | 5938, 5939; `stopActiveEncoding(remote:)` |
| 10 | `ServerResolves`: the stop ends C | `activeEncodingStopRequest` names device and id only |

When C attaches, the check compares b with a and schedules B's stop, which is correct; nothing
compares A's id with C's. With `ReusedIdReplacesJob = FALSE` the same trace ends C or both.

**Retry path** (`Finding-DeferredStopUnfenced-Retry`, 14 states; same assumption): steps 1 to 5
as above, then `Fail` (B's stop, joined), its answer, `Retry` within the two seconds,
`RetryProceeds` (the join returns: A's stop is not in it), the Retry's negotiation returns a, and
A's deferred stop ends the replacement. `Proposed-TracksDeferredStop` shows that making the
deferred stop a `pendingStopTasks` entry that awaits its request removes this path; the reopen
path is untouched by it.

**Join path** (`Finding-DeferredStopNotJoined`, 9 states, no server assumption, with
`FixCloseJoinsTask` so that the cancelled-task route below is closed): `Start`, `Reopen`, the
reopen attaches B and schedules A's stop, `Close` (B's stop joined), B's stop answered.
`waitForPendingStopRequests` now returns with A's stop not yet sent. The stop still goes out:
the `Task` outlives the controller. What it costs is what `Finding-StopNoJoin` costs: a probe that
joins before its final report can report while A's encoder is still running.

**Refuted** for `"never"`, `"latest"` and `"stopped"`: the deferred stop names A's id, which a
`"latest"` server never returns after it has minted B's, and a stop that has not been answered
keeps A running, so a `"stopped"` server cannot return a either. A fence on the generation would
not help: the stop is meant for A and must go out; what is missing is either a check of every
outstanding deferred id against the replacement's id, or a server that never returns a running
session's id.

### Fixed (#539): a stop that timed out defeated Retry's join (`Faithful-RetryAfterTimedOutStop-off`, `-ReusedId-off`)

Before #539, `OneEncoder` was violated in 10 states with `StopsCanBeLate`; no server assumption
and no quick tap: the Retry comes after the stop timed out. The trace is what
`Faithful-RetryAfterTimedOutStop-off` still shows with `RetryNeedsConfirmedStop = FALSE` (line
numbers as they were then).

| Step | Model | Swift |
| --- | --- | --- |
| 1, 2 | `Start`, `InitialRuns`: session A plays | `start()`, `beginRemoteStream` 3232 |
| 3 | `Fail`: A's `onStopAndWait` becomes a `pendingStopTasks` entry | `surfaceFailure` 5133, `stopRemoteSessionIfNeeded` 5178, the entry at 1268 |
| 4 | `ClockTicks`: the request passes its timeout unanswered; it stays on the wire | `MediaBrowserActiveEncodingStopExecutor.stop` returns `false` on the transport error, so `onStopAndWait` (`DetailPlaybackLauncher.swift` 253 to 255) returns |
| 5 | `Retry` | `retry()` 2566 |
| 6 | `RetryProceeds`: the join returns, because the entry's `Task` has finished | `waitForPendingStopRequests` 1236, awaited at 2580; `restartAtCurrentPosition` 2584 |
| 7 to 9 | `TaskBegins`, `NegotiateLands`, `TaskAttaches`: B attaches | 5839, 5885 to 5890 |

A's job is still running (its stop unanswered) beside B, and A is not a replaced prior, so the
window does not cover it. The comment at 2578 to 2579 says the join exists so as not to "mint a
replacement while the failed attempt's exact-session stop is still in flight"; a timed-out
request is still in flight, and the join cannot tell it from an answered one. Emby blocks this
case with LS-PB-008 (an unconfirmed stop fails the reopen); Jellyfin has no such check.

Under id reuse (`-ReusedId`, conditional on `"latest"` reuse that replaces the job, as
`Current-ReusedId`; 10 states): steps 1 to 6 as above (Retry tapped before the timeout, the join
returning after it), the Retry's negotiation returns A's id, and A's timed-out stop, still on the
wire, is applied and ends the replacement (`StopNeverKillsSuccessor`). It is not suspect 4's
missing join (#530): Retry joins here, and the join gives up at the request timeout.

The fix: `surfaceFailure` stops the failed session through `onStopAcknowledged`
(`stopRemoteSessionIfNeeded(tracksFailedAttempt: true)`) and records an unacknowledged answer in
`failedAttemptStopUnconfirmed` before the `pendingStopTasks` entry ends, if no later generation
has taken over; each failure resets it. After the join, `joinFailedAttemptStop` (the helper the
restart-from-failure path can share) checks it and, set, re-sends the failed session's stop once
(`failedAttemptSessionStop`, kept after `didStop` as the Emby barrier keeps its operation), as a
`pendingStopTasks` entry bounded by `failedAttemptRestopTimeout` (10 s; the failure-time
tracking stays at the request's own timeout). It re-checks the generation and cancellation: an
acknowledged re-send clears the flag and the Retry negotiates; otherwise it surfaces
`priorSessionStopUnconfirmed` and clears `failureRetryTask`, so the next tap re-sends again. A
blip that made the first DELETE fail at once no longer leaves Retry dead. Each tap makes at most
one request and waits at most the bound, so there is no loop. Both traces now end in
`RetryRestops` followed by `RetryRestopConfirmed` or `RetryRefused`, and every invariant holds in
`Current-LateRetry`.

What it does not fence (`Finding-RetryRestopDoesNotFence-ReusedId`, conditional on `"latest"`
reuse and on #536, 12 states): the failure's stop times out, the tap re-sends it and the re-send
is acknowledged (ending A), the Retry's negotiation returns A's id, and the first stop, still on
the wire, ends the replacement. Nothing the client hears about the second request says what
became of the first. A server that never returns a used id, or one that drops a request whose
client went away, closes it; so would a fresh id per Retry, which is not modelled.

What it does not cover (`Finding-RetryAfterTimedOutRejectStop-ReusedId`, conditional on
`"latest"` reuse and #536, 15 states): `Reopen` negotiates A's id again, `Fail` cancels that reopen and
joins it, the reopen's `stopRejectedRemoteStream` sends the rejected result's stop, which times
out, so the joined task returns; A's own stop was acknowledged, so Retry proceeds, its
negotiation returns A's id once more, and the rejected result's stop ends the replacement. It is
the `Finding-RejectedStopKillsReusedId` family with a timed-out stop instead of an unjoined task.

### Consent marks a reloaded session stopped (`Finding-ConsentClobbersDidStop`)

`NoOrphans` is violated in 9 states. No server assumption; it needs a reopen while a consent
request awaits the playing session's stop (`QuickReopen`), for example a quality change, or the
startup-deadline reopen, while the first start's request waits on a slow stop.

| Step | Model | Swift |
| --- | --- | --- |
| 1 | `Start`: session A | |
| 2 | `InitialNeedsConsent`: the first start's stream needs consent; A's `onStopAndWait` is awaited | `prepareRemoteStreamURL` 3342, `requestVideoTranscodeConsent` 2504, `await stop()` 2525 |
| 3 | `ServerResolves`: A's stop is answered (in the Swift this can equally come after step 7) | |
| 4 | `Reopen`: the consent task is cancelled; priorStop = A, since didStop is still false | 5766, 5770 |
| 5 to 7 | the reopen negotiates B and attaches it: B's callbacks on the same session object, `didStop = false` | 5885 to 5888 |
| 8 | `ConsentStopDone`: the cancelled consent task resumes and sets `session.didStop = true`, now B's flag | 2528, before the generation check at 2531 |

B is now marked stopped with no stop sent. Close skips it (`finalSessionStopDecision` reads
`didStop`, 1263 to 1264), the next reopen captures no priorStop for it (5770), and a later
consent request skips stopping it and shows the choice over its running encoder: the run
`Current-Consent` excludes violates `OneEncoder` and `ConsentBoundary` the same way. The Emby
path is not affected: `beginEmbySessionStop` sets `didStop` before its await (1249).
`Proposed-ConsentStopFenced` sets it before the await here too, and every property holds.

The consent request `handlePlaybackFailure` starts is a second route
(`Finding-ConsentClobbersDidStop-PlayerFailure`, 11 states, the first start's consent request
excluded by `CONSTRAINT NoInitialConsent`): `Start` and the attach, `PlayerNeedsConsent` (the item
fails on Original, 5058 to 5069), the task stops A and awaits (2525), A's stop is answered, a
quality change or seek-settle reopen (`QuickReopen`) negotiates and attaches B, and the consent
task resumes and sets `didStop` on B (2528).

### A quick second reopen makes a third encoder (`Finding-ThirdEncoder`)

`OneEncoder` is violated in 7 states with `QuickReopen`; no server assumption. `Start` (A),
`Reopen`, its negotiation returns B, `Reopen` again (the first task is cancelled holding B, and
A, still the installed session, is captured again as priorStop), the second negotiation returns
C: A, B and C run at once. The variant where the first reopen attaches B first is the same with A
asleep on its deferred stop. Emby's transaction tail exists to prevent the first shape; Jellyfin
has nothing in its place, and its prior stop is deferred by design. The cost is server load for
up to two seconds plus a stop's flight; the property says two.

The attached shape (`Finding-ThirdEncoder-Attached`, 11 states, no failures): `Start` (A),
`Reopen`, its negotiation returns B, B attaches and A's stop is scheduled (5899), a second `Reopen`
within the two seconds, its negotiation returns C, C attaches and B's stop is scheduled. A and B
are both asleep on their deferred stops while C plays: three running encoders with nothing under
way, independent of when Jellyfin starts an encoder.

### A restart while a failure shows overlaps the failed session (`Finding-RestartFromFailureOverlap`)

`OneEncoder` is violated in 7 states with `QuickReopen`; no server assumption. `Start` (A),
`Fail` (A's stop sent and joined by nothing yet), a quality or track change while the failure
shows starts a reopen (it does not await `waitForPendingStopRequests`, as `retry()` does at
2580), its negotiation returns B, and B attaches with A's stop still unanswered. A is not a
replaced prior (its stop came from `surfaceFailure`, not the deferred path), so the window does not
cover it. `Mutant-RetrySkipsJoin-Overlap` shows the same overlap on the Retry path once its join
is removed. `Finding-RestartFromFailureStaleStop` is this route under id reuse.

### `stop()` does not join the task it cancels (`Finding-StopNoJoin`)

`JoinCoversCleanup` is violated in 7 states: `Start`, `Reopen`, its negotiation returns B, `Close`
(the task is cancelled and dropped at 1181 to 1182 with nothing appended; A's stop is joined),
A's stop answered. The join returns, and the cancelled task then rejects B (5844) and sends its
stop. This is the restart core's finding in the Jellyfin shape. `Proposed-CloseJoins`
(`FixCloseJoinsTask` with `FixTracksDeferredStop`) keeps `JoinCoversCleanup`.

### Conditional: stale stops under a reused id

Each needs `IdReuse = "latest"` (a server that may return the id it minted last) and
`ReusedIdReplacesJob`, as `Current-ReusedId`.

- **`Finding-RejectedStopKillsReusedId`** (10 states, `QuickReopen`): `Reopen`, its negotiation
  returns A's id (`"latest"`), `Reopen` again, the first task rejects that result and sends its
  stop (5844, 5919), the second task negotiates at once (nothing orders it behind the
  rejection) and gets the same id, and the rejected result's stop ends it.
- **`Finding-RejectedStopKillsReusedId-Retry`** (14 states, `QuickRetry`, `RestartFromFailure`):
  `Fail`, a quality change while the failure shows starts a reopen, `Retry`, `RetryProceeds`
  cancels that reopen without joining it (`restartAtCurrentPosition` from `failureRetryTask`;
  only the task `surfaceFailure` cancelled is joined), and the cancelled reopen's rejected result's
  stop ends the Retry's replacement. This is the case the restart core asked this module to check.
- **`Finding-RestartFromFailureStaleStop`** (7 states, `QuickReopen`, `RestartFromFailure`):
  `Fail` sends A's stop, a quality or track change while the failure shows reopens without the
  join `retry()` has, gets A's id, and A's stop ends the replacement.
- **`Finding-BackToBackStaleStop`** (5 states, two controllers, `IdsNeverShared = FALSE`): the
  first playback is closed and its stop is not awaited (UI teardown is non-blocking); the next
  playback's first negotiation returns the same id, and the stop ends it.
- **`Finding-SameIdSkipLeavesPrior`** (6 states, `ReusedIdReplacesJob = FALSE`): a reopen comes back
  under the prior's id, the skip sends no stop, and the prior job runs beside the replacement
  until a stop for the id ends both.

If Jellyfin mints a fresh id for every PlaybackInfo, as its request shape suggests, none of these
can happen.

## Checked and not found

- **The same-id skip itself** is sound under the server it is written for: `Current-ReusedId`
  passes with the skip taken, and fails without it.
- **Retry's join** matters here, unlike in Emby: without it a failure's stop reaches the Retry's
  replacement under a reused id (`Mutant-RetrySkipsJoin`).
- **`ServerRecreate`** breaks no property: a recreated job is the server's, and with
  `StopEndsAllUnderId` a later stop for the id ends it too.
- **Close during a reopen** stops the still-installed prior session, and the cancelled task
  rejects the result: `NoOrphans` holds (`Current-Reopen`).

## For the proxy module and the review

- `W(A)` recomputes the ghost window after the step; TLC then names every step `W`, so traces are
  read by their state changes, not their action names.
- The four shared task helpers could move to the base (see above).
