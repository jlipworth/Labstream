# emby: the Emby replacement order

`PlaybackEmby.tla` models how `PlaybackController` replaces an Emby stream. Every negotiation
returns a play-session id the server minted, and the controller holds an exact-session stop for
the session it plays. A reopen detaches the old item, hands that stop to `EmbyReopenStopBarrier`,
waits for the reopen before it to return, waits for the stop to be acknowledged, and only then
negotiates. An unacknowledged stop fails the reopen with `priorSessionStopUnconfirmed` (LS-PB-008)
and keeps the stop for Retry.

```sh
scripts/check-tla-specs.sh specs/playback/emby
scripts/check-tla-specs.sh --deep specs/playback/emby/Deep-BackToBack.cfg
```

What the model shows:

- With one controller the order as it stands keeps every property but `JoinCoversCleanup`, given a
  server that never returns a used play-session id (`Current-Reopen`, `Current-LateAck`). With any
  id returned it also needs a stop that ends every job under the id it names
  (`StopEndsAllUnderId`, `Current-ReopenLive`): Emby can make a stopped job again (#421), and an
  acknowledged stop that ends only that job leaves the replacement it meant running. Once a stop
  can time out, `StopNeverKillsSuccessor` needs a server that never returns a used id.
- The two `precondition`s in `EmbyReopenStopBarrier.begin` are not reachable. The transaction
  tail is what keeps them so: without it both are reached (`Mutant-NoTransactionTail*`).
- The 2026-10-04 overlap is visible: `Faithful-EmbyOverlap-off`.
- One finding does not depend on the server: `stop()` does not join the task it cancels, so the
  cleanup of a rejected session is sent after `waitForPendingStopRequests` returns
  (`Finding-StopNoJoin`, the restart core's finding and the second half of suspect 4).
- Three findings are conditional on what Emby does, which the repository does not establish:
  a stale stop under a reused play-session id, within one playback
  (`Finding-LateStopKillsReusedId`) and across two (`Finding-BackToBackStaleStop`), and a
  cancelled negotiation the server still acts on (`Finding-AbandonedNegotiateOrphans`). See
  [What Emby does](#what-emby-does).

None of the findings has been reproduced in the app or against a server.

## What is modelled

Each MainActor run between two awaits is one action. Functions are in
`Labstream/Shared/Player/PlaybackController.swift` unless another file is named.

| Model | Swift |
| --- | --- |
| `Start` | `start()` with `beginRemoteStream`. `DetailPlaybackLauncher` negotiated the first session before the controller existed, so its job runs and its stop callbacks are installed |
| `Reopen` | a settled seek outside the buffer, `reload(bitrateKbps:)` and the track changes (`restartAtCurrentPosition`), `attemptEmbyVideoCopyFallback`, `attemptEmbyCopyReopenRetry` and the MediaBrowser branch of `attemptStartupDeadlineRetry`, each ending in `reopenRemoteStream` |
| `Approve`, `Decline` | `approveVideoTranscoding`, `declineVideoTranscoding` |
| `Retry`, `RetryProceeds` | `retry()`, `failureRetryTask`, `waitForPendingStopRequests` |
| `Close` | `stop()` |
| `Fail`, `NegotiateFails` | `handlePlaybackFailure` and the watchdogs, and the `catch` of `reopenRemoteStream`, each ending in `surfaceFailure` |
| `PlayerNeedsConsent` | the branch of `handlePlaybackFailure` that creates a task running `requestVideoTranscodeConsent` |
| `ReopenCore` | the synchronous part of `reopenRemoteStream` |
| `SurfaceFailure`, `StopRemote` | `surfaceFailure`; `stopRemoteSessionIfNeeded` with `beginEmbySessionStop` |
| `Begin`, `BeginFinal`, `HasAuthority`, `CurrentTicket` | `EmbyReopenStopBarrier.begin(stop:)`, `beginFinalStop()`, `hasAuthority`, `currentTicket` (`Labstream/Shared/Player/EmbyReopenStopBarrier.swift`) |
| `BarrierResolves` | the body of the barrier's own task, after `await operation()` |
| `TaskJoins` | `await predecessor?.value`, the first `acceptsReopenResult` check, and the choice of `currentTicket ?? stopBarrier` |
| `TaskStopAcked`, `TaskStopUnconfirmed` | the check after `await currentStopBarrier.value`; `throw PlaybackFailure(code: .priorSessionStopUnconfirmed)` and the `catch` |
| `NegotiateLands` | Emby answers the `remoteStreamReopener` request (a PlaybackInfo request) |
| `TaskAttaches` | `playableRemoteStreamURL` returns a URL; the session's callbacks are installed, `didStopRemoteSession = false`, `loadRemoteStream`, `load` |
| `TaskNeedsConsent` | `playableRemoteStreamURL` calls `requestVideoTranscodeConsent` and returns nil; the task then calls `stopRejectedRemoteStream` |
| `TaskRejects`, `TaskRejectDone`, `Reject` | `stopRejectedRemoteStream` after a failed `acceptsReopenResult` check |
| `TaskUnwindExit` | the `catch` of a cancelled task: `guard acceptsReopenResult(...) else { return }` |
| `InitialAttaches` | the task in `beginRemoteStream` |
| `ConsentBegins`, `ConsentStopAcked`, `ConsentStopUnconfirmed` | `requestVideoTranscodeConsent`, split at `await barrier.value` |
| `Accepts` | `RemoteStreamLifecyclePolicy.acceptsReopenResult` (`PMSKit/Sources/PMSKit/RemoteStreamLifecyclePolicy.swift`) and the `guard !Task.isCancelled, generation == playbackGeneration` of the consent request |
| `ServerResolves`, `ServerRecreatesJob`, `ClockTicks` | Emby applies an active-encoding stop (`MediaBrowserActiveEncodingStopExecutor.stop` with `MediaBrowserActiveEncodingStopPolicy.isConfirmedStopped`, `PMSKit/Sources/PMSKit/MediaBrowser/`), or it ends unacknowledged; Emby makes a stopped job again from a media request it had accepted (#421); the request timeout passes for the stop the barrier awaits |

The module's `MODELS` lines also name `DetailPlaybackLauncher.swift` (the first session, the stop
closures and `requiresActiveEncodingStop`), `PlaybackSessionSource.swift` (the one session object
whose `didStop` and callbacks every reopen reloads), `EmbyPlayback.swift` (the server-minted id
that `IdReuse` stands for) and the two `MediaBrowser` files above (which statuses count as
acknowledged, which `BarrierResolves` encodes).

A task is `[gen, pc, sid, inc, kind, pred, tk]`: the generation it captured, where it is, the
session its negotiation returned, whether it is the first start, a consent request or a reopen,
the reopen task it joins first, and the barrier ticket it captured or awaits. Its places:

| `pc` | The task is at |
| --- | --- |
| `begin` | created; a reopen is at `await predecessor?.value` |
| `awaitStop` | `await currentStopBarrier.value` |
| `negotiate` | `try await remoteStreamReopener(request)`, the request on the wire |
| `negotiated` | the answer is back and the task holds a session: from the return of the reopener to the end of `playableRemoteStreamURL` |
| `rejectStop` | `await barrier.value` in `stopRejectedRemoteStream` |
| `consentStop` | `await barrier.value` in `requestVideoTranscodeConsent` |

Cancelling a task moves it to `unwinding`; it keeps taking steps until it returns. A cancelled
reopen still waits for its predecessor and for its ticket before it returns, as the Swift does.

### The barrier

`bar[c]` is one `EmbyReopenStopBarrier`: `op` (`operation`, the job whose stop it owns),
`finalRetry` (`finalRetryAttempted`) and the tickets it has made. Ticket `n` is `latestTicket`,
and is `pending` while its result is `"pending"`. A ticket is one run of the operation, which is
one stop request. `Begin` is `begin(stop:)` as a function from the barrier and the offered stop
to the barrier afterwards, the stop to send, the ticket returned and the `precondition` that was
false, if one was. The task the barrier creates sends its request when it first runs; the model
sends it in the same step, since a request that leaves later is one that takes longer.

A `pendingStopTasks` entry for the barrier is `BarTicket(k)`. It ends when ticket `k` does, which
for a request that timed out is before the server answers, so `Joined(c)` is this module's own
reading of `waitForPendingStopRequests` and the base's `PendingStopsJoined` is not used.

### How a stop is judged

An Emby stop is an immutable closure over one negotiated session
(`DetailPlaybackLauncher.reopenStream`, `stopActiveEncodingNow`). The client always knows which
job a stop means, so every stop is sent with the incarnation the negotiation returned and the
base's `NoWrongKill` is the property: `StopNeverKillsSuccessor` is that name for it.

The base's `Owned` stops counting a job once a stop for it failed. That is the wrong judgement
for LS-PB-008, whose point is that the client must not start another encoder after an
unconfirmed stop. `NoEncoderWhileUnconfirmed` is stated over `Live(c)` instead, and
`Mutant-ProceedsUnconfirmed` is a run where it fails and `OneEncoder` holds.

## What Emby does

Four server behaviours decide results, and the repository does not settle them. No live server
was queried for this model.

| Evidence in the repository | Says |
| --- | --- |
| `EmbyPlayback.playbackInfoRequest` and `resolveMediaBrowserStream` (`PMSKit/Sources/PMSKit/Emby/EmbyPlayback.swift`) | The play-session id is read from the PlaybackInfo response: the server mints it, once per negotiation. |
| `EmbyLibrary.activeEncodingStopRequest` (`PMSKit/Sources/PMSKit/Emby/EmbyLibrary.swift`) | A stop is `DELETE /Videos/ActiveEncodings` with `DeviceId` and `PlaySessionId`. `DeviceId` is the app's client identifier, the same for every controller. |
| `MediaBrowserActiveEncodingStopPolicy.isConfirmedStopped` (`PMSKit/Sources/PMSKit/MediaBrowser/MediaBrowserPlaybackPolicy.swift`) | 2xx, 400, 404 and 410 are acknowledgements, so "nothing to stop" is one. A transport error, a timeout included, is not. |
| `EmbyBrowseService.stopActiveEncoding` (`Labstream/Shared/Backend/Emby/EmbyBrowseService.swift`) | The stop goes through `URLSession.shared` with no timeout of its own: the bound is the session's default request timeout. |
| `RemoteStreamLifecyclePolicy.priorSessionStopDecision`, and `EmbyReopenStopBarrierTests` (`same-session`; "A newly opened encoder may reuse an ID") | The code is written for a backend that can return an id again. Nothing records Emby doing so. |
| `docs/evidence/audits/2026-10-04-emby-reopen-session-overlap.md` | Two sessions overlapping on the server is the reproduced failure boundary. An acknowledgement is not proof the worker exited. |
| `DetailPlaybackLauncher.acceptInitialOpen` ("A successful stale response may already own an encoder"), and `docs/PLAYBACK-ARCHITECTURE.md`, "Emby" | The code treats a PlaybackInfo answer as something that may need a stop. Whether the encoder starts at PlaybackInfo or at the first playlist request is not recorded. |
| `MediaBrowserRemotePlayback.requiresActiveEncodingStop` (`Labstream/Shared/UI/DetailPlaybackLauncher.swift`) | For Emby the stop is sent only for a server-encoded stream; otherwise the callback answers `true` with no request. |
| `docs/PLAYBACK-ARCHITECTURE.md` ("Emby can still race two transcodes on one copy session") and #421 | An `init.mp4` request that lands while a seek-gap restart has the job unregistered starts a second writer for the same session: Emby makes a job again from the client's own media request, the mechanism of the Jellyfin audit. |
| `docs/evidence/audits/2026-09-17-jellyfin-terminal-cleanup.md` ("Server implementation boundary") | Jellyfin 10.11.11's stop ends a snapshot of every matching job. That is Jellyfin's server source; Emby's 4.x server is closed, and nothing in the repository shows what its stop ends when several jobs run under one id. |

So the model was run under each assumption:

| Assumption | Values |
| --- | --- |
| `IdReuse` | `"never"`: a negotiation returns an id the server has not used. `"stopped"`: also a used id with no job running under it. `"live"`: any id, the setting that assumes nothing |
| `AbandonedNegotiateCanLand` | `TRUE`: a PlaybackInfo request the client cancelled or gave up on may still be acted on, with nobody to hear the answer. `FALSE`: it never is |
| `IdsNeverShared` (base) | `TRUE`: an id is never given to a second controller. `FALSE`: it can be |
| `StopEndsAllUnderId` (base) | `TRUE`: a stop ends every job under its id. `FALSE`: any non-empty set of them, the setting that assumes nothing. `TRUE` only in the configs that reuse ids and say so |

What depends on them:

- **`IdReuse` and `StopEndsAllUnderId`, with `ServerRecreate` on.** With one controller and
  every stop answered within its timeout, `Current-Reopen` passes with `"never"`. With `"live"` or
  `"stopped"` and `StopEndsAllUnderId = FALSE`, `OneEncoder` fails (16 states, `Current-Reopen`'s
  constants with `"live"`): A's stop is acknowledged, Emby makes A again, a reopen gets A's id back
  and is superseded, the rejected result's stop is acknowledged but ends only the remade A, and the
  next reopen negotiates C beside the rejected result. The client cannot tell: it sent the exact
  stop and heard it acknowledged. With `StopEndsAllUnderId` the run passes (`Current-ReopenLive`,
  reduced bounds), and once a stop can time out every property but `StopNeverKillsSuccessor`
  still holds (`Current-LateAckLive`, one user action). `StopNeverKillsSuccessor` needs `"never"`
  once a stop can time out (`Finding-LateStopKillsReusedId` is `Current-LateAck` with
  `"stopped"`), and cannot fail without reuse, so the `"never"` configs do not list it.
- **Why the `"live"` results are conditional rather than assumed.** The review asked for either
  `StopEndsAllUnderId = TRUE` on the audit's evidence or a downgrade. The audit read Jellyfin
  10.11.11's `TranscodeManager`; Emby's 4.x server is closed source, and the two servers diverged
  long before it. The shared lineage makes "every matching job" plausible for Emby, not
  established, so the `"live"` and `"stopped"` passes are stated as conditional on it, and the
  unconditional `Current` claims are the `"never"` runs. A full-bound `"live"` run with
  `StopEndsAllUnderId` also outgrows the default tier (stopped past 29 million states).
- **`IdsNeverShared`.** `Deep-BackToBack` takes `FALSE`. There is no evidence for `TRUE`: the
  server mints the id, and the stop names the device and the id, with the same device for both
  controllers. With `FALSE` and `"stopped"` a second playback can be given an id the first one's
  stopped session had, and the run passes only where every stop is answered
  (`StopsCanFail = FALSE`). `Finding-BackToBackStaleStop` is the same run with failing stops.
- **`AbandonedNegotiateCanLand`.** `FALSE` in every config but
  `Finding-AbandonedNegotiateOrphans`.

## What is abstracted, and why

- **What the restart core covers** is left out: seeks and their budget, pause intent and the
  loopback proxy. `seekHold`, `budget`, `paused`, `proxy` and `jellyfinWindow` never change. No
  module is imported; the core's `Terminal` and `RestartCore` shapes are rewritten here around
  the barrier, because the core abstracts the barrier to "the stop was sent and the task waits".
- **A PlaybackInfo answer is a running job**, as the base says (contract, 7). Emby may start the
  encoder only at the first playlist request, which the model folds into the answer. For the
  current order this is the cautious reading, and it is what the Swift assumes when it stops a
  rejected result.
- **`playableRemoteStreamURL`'s awaits** (the copy playlist fetch, the prewarm) are folded into
  `negotiated`. A task cancelled there is rejected exactly as one cancelled before it.
- **Consent inside a reopen.** `requestVideoTranscodeConsent` would await a barrier ticket if
  the barrier held authority when a reopen's result needs consent. `TaskNeedsConsent` leaves
  that branch out, and `NoAuthorityAtPrepare` is the checked invariant that it is not reached.
  The return from `requestVideoTranscodeConsent` to `stopRejectedRemoteStream` has no await and
  is one step.
- **The legacy stop.** A session with no `onStopAcknowledged` gets `Task { false }` in
  `reopenRemoteStream` and `stopAndWaitIgnoringCancellation` when rejected.
  `DetailPlaybackLauncher` builds every Emby session with the callback, so neither is modelled.
  For the same reason `guard let operation else { return Task { false } }` in `begin` is not
  reached.
- **Every session here has an encoder.** A session that is not server-encoded acknowledges its
  stop with no request: `requiresActiveEncodingStop` is `backend == .jellyfin || usesServerEncoding`
  (`DetailPlaybackLauncher.swift` 392 to 393), and `stopActiveEncodingNow` returns `true` at 270.
  That includes a server-generated `DirectStreamUrl`, which `EmbyPlayback.resolveMediaBrowserStream`
  marks `usesServerEncoding: false` (`EmbyPlayback.swift` 507 to 515). **Unverified,
  server-dependent gap:** if that URL is a server remux, as it typically is when the source does
  not support direct play, the barrier reports "acknowledged" with no request and the reopen
  negotiates while the remux still runs: the 2026-10-04 overlap shape. Whether Emby's direct
  stream starts a process the active-encoding stop would end is not recorded. No config models it;
  it needs server evidence before it is a finding.
- **The progress stop** (`POST /Sessions/Playing/Stopped`, sent by the timeline) is not a stop
  of an encoder and is not modelled.
- **A stale auth context.** `DetailPlaybackLauncher.reopenStream` stops a result itself and
  throws when the backend context changed during the negotiation. Sign-out and backend
  switching belong to phase 3.
- **Time.** The request timeout is `ClockTicks`, which can fire for the stop a barrier awaits.
  The ticket then reads as unconfirmed and the request stays on the wire, where the server may
  still apply it.
- **`ServerRecreate` is enabled** (`ServerRecreatesJob`) in every safety config and judged against
  the server, as in Jellyfin. #421 is the same mechanism as the Jellyfin audit: a job made again
  from the client's own accepted media request. (#421 also tracks Emby 4.10 restarting a mid-file
  encoder on every request after losing its position; that is not a stopped job made again and is
  not modelled.) `Liveness-Reopen` takes `ServerRecreates = TRUE` and passes, so that the
  liveness claim is checked with it. `Liveness-BoundedWait`, the liveness mutants and
  `Proposed-Liveness` take `ServerRecreates = FALSE`, argued rather than checked: the step
  changes only `server`, and under their `"never"` and `"live"` reuse no client step, stop
  resolution or timeout depends on whether a stopped job runs again, so it adds states and no
  client behaviour; with it `Liveness-BoundedWait` grew from 107 s past the default tier's five
  minutes.
- **Automatic reopens** (the copy fallback, the copy reopen retry, the startup-deadline reopen)
  are `Reopen` steps and count against `MaxUserActions`.
- **`failureRetryTask`.** `Reopen` and `Approve` clear it, as `restartAtCurrentPosition` does. A
  seek's direct `reopenRemoteStream` does not; the retry task then wakes to another generation
  and, since #526, clears the slot itself (the restart core's `RetryBails`,
  `Faithful-RetryWedgedByAttach-off`). That step is left out here: `retryGen` stays set, which
  only bounds this model's Retry further.
- **The consent overlay.** A reopen needs no consent choice showing, apart from `Approve`.
  `reopenRemoteStream` does not clear `videoTranscodeConsent.generation` (`beginStreaming` and
  `reload` do), so a track change while the choice shows would leave a choice that neither
  button can dismiss. Whether the interface allows that was not checked; it changes nothing on
  the server.
- **One generation bump in `start()`**, and none for `beginRemoteStream`, which captures the
  generation it finds.

## Bounds

- One controller unless noted. `MaxGeneration` bounds `playbackGeneration` and the incarnations
  under one id. `GenerationsSuffice` is checked in every passing safety config: no guard on a
  generation counter ever disables an action.
- `MaxUserActions` bounds reopens, approvals and Retry taps together. Close, one failure per
  attempt and one consent request per attached item are always available.
- `SessionIds`: with `IdReuse = "never"` each negotiation uses one, so a config has one more id
  than user actions.
- `EnvFails`, `RestartFromFailure`, `ConsentPossible`, `StopsCanFail` and `StopsCanBeLate`
  switch parts of the environment on.

## Properties

| Property | Kind | Meaning |
| --- | --- | --- |
| `OneEncoder` (base) | invariant | At most one job the client still owns. |
| `NoEncoderWhileUnconfirmed` | invariant | At most one job runs for a controller with no acknowledged stop meant for it: no new encoder while the prior stop is unconfirmed (LS-PB-008). |
| `StopNeverKillsSuccessor` | invariant | No stop meant for an older job under an id ends a newer one. **Violated by the code if Emby returns an id again (conditional).** |
| `BarrierPreconditions` | invariant | Neither `precondition` in `EmbyReopenStopBarrier.begin` is reached false: `PendingTicketNeverReplaced` and `FailedTicketNeverReplaced`. |
| `NoAuthorityAtPrepare` | invariant | While a current reopen holds a session it has not attached, the barrier has no authority. This is what lets `TaskNeedsConsent` leave a branch out. |
| `DetachedWhileStopping` | invariant | The barrier never has a stop in flight while an item is attached. |
| `ConsentBoundary` | invariant | While the consent choice shows, nothing is attached, the old session's stop has been handed over and acknowledged, and the only authority the barrier may still hold is for a rejected, newly negotiated session. |
| `NoOrphans` | invariant | Every session a request created is the one whose stop the controller holds, is held by a task that will attach or stop it, or has had a stop sent; and after Close, or while a failure shows with nothing under way, the controller holds none. A stop that fails counts. **Violated by the code if Emby acts on a cancelled negotiation (conditional).** |
| `JoinCoversCleanup` | invariant | Once `waitForPendingStopRequests` would return after Close, no task still holds a session to stop and the barrier has no stop in flight. **Violated by the code (suspect 4).** |
| `GenerationsSuffice` | invariant | The generation bound is never what stops a behaviour. |
| `ReopenSettles` | liveness | A start, reopen or consent request ends: it attaches, shows the choice, fails or is closed. |
| `CloseCleansUp` | liveness | After Close every task returns and the joined cleanup ends. |

Liveness is checked under two fairness assumptions. `FairSpec` answers every stop.
`ClockFairSpec` never forces an answer and only runs the request timeout: a dead connection.

## Configs and results

2026-11-25, tla2tools v1.7.4, `TLC_WORKERS=auto TLC_HEAP=4g` on 30 cores. Unless noted: one
controller, three session ids, two user actions, `MaxGeneration = 12`, failures, restarts from a
failure, failing stops and `ServerRecreates` on, consent and late stops off, `IdReuse = "live"`,
`AbandonedNegotiateCanLand = FALSE`, `IdsNeverShared = TRUE` (no effect with one controller),
`StopEndsAllUnderId = FALSE`.

| Config | Expect | Result | Distinct states | Time |
| --- | --- | --- | --- | --- |
| `Current-Reopen` | pass | pass (given `IdReuse = "never"`) | 3,170,173 | 18 s |
| `Current-ReopenLive` | pass | pass (given `StopEndsAllUnderId`) | 518,573 | 3 s |
| `Current-LateAck` | pass | pass (given `IdReuse = "never"`) | 8,622,467 | 39 s |
| `Current-LateAckLive` | pass | pass (given `StopEndsAllUnderId`; `StopNeverKillsSuccessor` not checked) | 189,344 | 2 s |
| `Current-LateAckConsent` | pass | pass (given `IdReuse = "never"`) | 4,045,273 | 20 s |
| `Current-CloseAtConsent` | pass | pass (given `IdReuse = "never"`) | 7,379,778 | 34 s |
| `Liveness-Reopen` | pass | pass | 192,358 | 22 s |
| `Liveness-BoundedWait` | pass | pass | 787,928 | 107 s |
| `Faithful-EmbyOverlap-off` | `OneEncoder` violated | violated | stops at first error | 1 s |
| `Mutant-StopNotAwaited` | `StopNeverKillsSuccessor` violated | violated | stops at first error | 1 s |
| `Mutant-ProceedsUnconfirmed` | `NoEncoderWhileUnconfirmed` violated | violated | stops at first error | 1 s |
| `Mutant-NoTransactionTail` | `PendingTicketNeverReplaced` violated | violated | stops at first error | 1 s |
| `Mutant-NoTransactionTail-FailedTicket` | `FailedTicketNeverReplaced` violated | violated | stops at first error | 1 s |
| `Mutant-RejectedNotStopped` | `NoOrphans` violated | violated | stops at first error | 1 s |
| `Mutant-CloseSkipsFinalStop` | `NoOrphans` violated | violated | stops at first error | 1 s |
| `Mutant-StopBeforeDetach` | `DetachedWhileStopping` violated | violated | stops at first error | 1 s |
| `Mutant-ConsentSkipsStop` | `ConsentBoundary` violated | violated | stops at first error | 1 s |
| `Mutant-ConsentIgnoresAck` | `ConsentBoundary` violated | violated | stops at first error | 1 s |
| `Mutant-ConsentAttachesNegotiated` | `ConsentBoundary` violated | violated | stops at first error | 1 s |
| `Mutant-UnboundedStopWait` | `ReopenSettles` (temporal) violated | violated | stops at first error | 1 s |
| `Mutant-CloseUnboundedStopWait` | `CloseCleansUp` (temporal) violated | violated | stops at first error | 4 s |
| `Finding-StopNoJoin` | `JoinCoversCleanup` violated | violated | stops at first error | 1 s |
| `Finding-LateStopKillsReusedId` (conditional on Emby) | `StopNeverKillsSuccessor` violated | violated | stops at first error | 1 s |
| `Finding-BackToBackStaleStop` (conditional on Emby) | `StopNeverKillsSuccessor` violated | violated | stops at first error | 1 s |
| `Finding-AbandonedNegotiateOrphans` (conditional on Emby) | `NoOrphans` violated | violated | stops at first error | 1 s |
| `Proposed-CloseJoinsTask` | pass | pass (given `IdReuse = "never"`) | 7,239,047 | 34 s |
| `Proposed-Liveness` | pass | pass | 36,667 | 5 s |
| `Deep-BackToBack` (deep) | pass | pass (given `StopsCanFail = FALSE`, `StopEndsAllUnderId`) | 33,143,309 | 3 min 12 s |

- `Current-Reopen`: three user actions, four session ids, `MaxGeneration = 15`,
  `IdReuse = "never"`. It checks `TypeOK`, `OneEncoder`, `NoEncoderWhileUnconfirmed`,
  `BarrierPreconditions`, `NoAuthorityAtPrepare`, `DetachedWhileStopping`, `ConsentBoundary`,
  `NoOrphans` and `GenerationsSuffice`, and so do the other `Current` configs,
  `Proposed-CloseJoinsTask` and `Deep-BackToBack`. `StopNeverKillsSuccessor` cannot fail
  without reuse, so it is listed only where ids are reused: `Current-ReopenLive` (`"live"`,
  `StopEndsAllUnderId`, two user actions, three ids, `MaxGeneration = 12`) and
  `Deep-BackToBack`. Before `ServerRecreate` was enabled, `Current-Reopen` passed with `"live"`
  and no stop assumption (1,546,786 states); see [What Emby does](#what-emby-does) for why it no
  longer can.
- `Current-LateAck` (review focus 3): `StopsCanBeLate` and `IdReuse = "never"`. A stop times out,
  the reopen fails with LS-PB-008, the stop is retried, and the first request is acknowledged
  afterwards (witness `NeverLateAck`). With three user actions the run was 44,996,159 states and
  285 s, and passed, before the cancelled-first-start fix below (not re-run since); the config
  keeps two. `Current-LateAckLive`: the same run with
  `IdReuse = "live"`, `StopEndsAllUnderId` and one user action (with two it outgrows the default
  tier), checking every `Current` invariant except `StopNeverKillsSuccessor`, which
  `Finding-LateStopKillsReusedId` shows failing under reuse. `Current-LateAckConsent`: late stops
  with consent, `Liveness-BoundedWait`'s constants with `MaxGeneration = 12` under `Spec`, one
  user action, `IdReuse = "never"`, every `Current` invariant.
- `Current-CloseAtConsent` (review focus 4): `ConsentPossible`, `MaxGeneration = 15`,
  `IdReuse = "never"`.
- `Liveness-Reopen`: consent, one user action, `MaxGeneration = 11`, under `FairSpec`:
  `ReopenSettles` and `CloseCleansUp`. `Liveness-BoundedWait`: the same with late stops and
  `IdReuse = "never"`, under `ClockFairSpec`. `Liveness-Reopen` takes `ServerRecreates = TRUE`;
  `Liveness-BoundedWait`, the liveness mutants and `Proposed-Liveness` take `FALSE` (see the
  abstractions).
- `Proposed-CloseJoinsTask`: `Current-CloseAtConsent`'s run with `FixCloseJoinsTask`, checking
  `JoinCoversCleanup` beside the rest. `Proposed-Liveness`: `Liveness-Reopen`'s run with the fix.
- `Deep-BackToBack`: two controllers, three session ids, one user action each,
  `MaxGeneration = 12`, failures, no consent, no restart from a failure, `IdsNeverShared = FALSE`,
  `IdReuse = "stopped"`, `StopsCanFail = FALSE`, `StopEndsAllUnderId`. The second controller is
  given an id the first one used (witness `NeverSharedId`). With `StopEndsAllUnderId = FALSE` it
  fails `OneEncoder` through a remade job (as `Current-Reopen` with reuse); with consent as well
  it grew past 146 million states in 16 minutes and was stopped. `Finding-BackToBackStaleStop` is
  two controllers with consent and `StopsCanFail = TRUE`.

How the `Current` configs are scoped around the findings. `Finding-StopNoJoin` needs nothing
from the environment, so `JoinCoversCleanup` is left to its `Finding` and `Proposed` configs and
the `Current` configs keep the behaviour. The three conditional findings each need one server
assumption, and each `Current` or `Deep` config that would otherwise reach one states the
assumption it takes instead: `IdReuse = "never"` in `Current-LateAck` and
`Current-LateAckConsent` (`Current-LateAckLive` drops the one property instead),
`StopsCanFail = FALSE` in `Deep-BackToBack`, `AbandonedNegotiateCanLand = FALSE` everywhere.
`ServerRecreate` adds a fourth: every config that reuses ids takes `StopEndsAllUnderId`, and the
others take `IdReuse = "never"`.

### Faithfulness and mutants

| Config | Flips | Violates | Trace |
| --- | --- | --- | --- |
| `Faithful-EmbyOverlap-off` | `StopsBeforeNegotiate` | `OneEncoder` | A reopen negotiates with the old session still running and no stop sent: two owned jobs (the 2026-10-04 audit). |
| `Mutant-StopNotAwaited` | `WaitsForStopAck` | `StopNeverKillsSuccessor` | The stop is sent, the negotiation follows at once and returns the same id, and the stop ends the replacement. |
| `Mutant-ProceedsUnconfirmed` | `BlocksOnUnconfirmedStop` | `NoEncoderWhileUnconfirmed` | A stop is lost and the old job runs on; the reopen negotiates all the same. |
| `Mutant-NoTransactionTail` | `JoinsPredecessor` | `PendingTicketNeverReplaced` | Two reopens negotiate at once. Both are superseded; the first rejected session's stop is in flight when the second is offered to the barrier. |
| `Mutant-NoTransactionTail-FailedTicket` | `JoinsPredecessor` | `FailedTicketNeverReplaced` | The same, where the first rejected session's stop failed before the second is offered. |
| `Mutant-RejectedNotStopped` | `RejectedIsStopped` | `NoOrphans` | A superseded reopen's answer arrives and is dropped. |
| `Mutant-CloseSkipsFinalStop` | `CloseStopsSession` | `NoOrphans` | Close with a session playing and no stop. |
| `Mutant-StopBeforeDetach` | `DetachesBeforeStop` | `DetachedWhileStopping` | A reopen sends the stop with the old item still attached. |
| `Mutant-ConsentSkipsStop` | `ConsentStopsSession` | `ConsentBoundary` | The choice shows at the first start with the session's encoder running and its stop not sent. |
| `Mutant-ConsentIgnoresAck` | `ConsentRequiresAck` | `ConsentBoundary` | The old session's stop fails and the choice shows all the same. |
| `Mutant-ConsentAttachesNegotiated` | `ConsentRejectsNegotiated` | `ConsentBoundary` | A reopen's result needs consent; the choice shows over the attached result. |
| `Mutant-UnboundedStopWait` | `StopTimesOut` | `ReopenSettles` | A reopen waits for ever on a stop that is never answered. |
| `Mutant-CloseUnboundedStopWait` | `StopTimesOut` | `CloseCleansUp` | `Liveness-BoundedWait`'s run: a reopen's stop is never answered, the user closes the player, and the cleanup Close joins never ends. |

`StopNeverKillsSuccessor`, `NoOrphans` and `JoinCoversCleanup` also fail on the code as it
stands, in the `Finding` configs. `OneEncoder`'s failing run is the `Faithful` config.
`NoAuthorityAtPrepare` and `GenerationsSuffice` are checks on the model, not on the code: the
first fails with `Mutant-NoTransactionTail`'s constants, the second with any `Current` config and
a smaller `MaxGeneration`. `Mutant-CloseUnboundedStopWait` keeps consent on so that it differs
from the passing `Liveness-BoundedWait` in the one flag it injects.

An earlier version of `ConsentBegins` required `ConsentPossible` for a first start's task even on
its cancelled path, so with consent off a first start cancelled before attaching never returned.
That pruned safety coverage, not only liveness: after `Start`, `Fail`, `ServerResolves`, `Retry`
the retry waited for ever on the stranded task and `RetryProceeds` never ran. The guard now sits
on the live path only, as in the Swift, where a cancelled `beginRemoteStream` task returns. The
consent-off counts above are from the fixed module.

### Every branch is taken

The module ends with witnesses, each the negation of a state one branch reaches. Checked as the
only invariant, each is violated:

| Witness | Constants of |
| --- | --- |
| `NeverBlocked` (LS-PB-008 showing), `NeverFinalRetry`, `NeverRejected`, `NeverRejectFailed`, `NeverTwoUnwinding`, `NeverJoinedTicket` (a reopen awaits the stop of a rejected session), `NeverRestartFromFailure`, `NeverRetryWaits`, `NeverStopFailed`, `NeverRecreated` | `Current-Reopen` |
| `NeverReusedId` | `Current-ReopenLive` |
| `NeverTimedOut`, `NeverLateAck` | `Current-LateAck` |
| `NeverConsentShown`, `NeverConsentWhileRejecting`, `NeverClosedAtConsent`, `NeverClosedAtConsentRejecting` | `Current-CloseAtConsent` |

No config lists them; to repeat one, copy the named config, replace its `INVARIANTS` with the
witness and run TLC.

## Findings

Line numbers are `PlaybackController.swift` and `EmbyReopenStopBarrier.swift` as of commit
`0b7f3fcb`, the last to change either before this model. Traces are the shortest TLC finds with
one worker.

### Suspect 4, second half: `stop()` does not join the task it cancels (`Finding-StopNoJoin`)

`JoinCoversCleanup` is violated in 9 states. It depends on no server assumption. The restart
core has the same finding for a request still on the wire; this is its Emby form, with the
rejected session's stop.

| Step | Model | Swift |
| --- | --- | --- |
| 1 | `Start` | `start()` 1092, `beginRemoteStream` 3232 |
| 2 | `Reopen`: the old item is detached and the session's stop handed to the barrier | `reopenRemoteStream` 5750: 5766 to 5767, 5780, 5790 to 5793, `begin` at 5797 |
| 3 | `ServerResolves`: Emby acknowledges the stop | |
| 4 | `TaskJoins`: no predecessor; the task awaits the ticket | 5811, 5819 to 5822 |
| 5 | `BarrierResolves`: the barrier gives up the operation | `EmbyReopenStopBarrier.swift` 29 to 31 |
| 6 | `TaskStopAcked`: the task negotiates | 5823 to 5829, 5839 |
| 7 | `NegotiateLands`: the answer is back; the task holds the new session | |
| 8 | `Close`: the task is cancelled and dropped. The session has no stop installed and the barrier no authority, so nothing is appended to `pendingStopTasks` | `playbackTask?.cancel(); playbackTask = nil` at 1181 to 1182; `stopRemoteSessionIfNeeded` 1255: `beginEmbySessionStop` returns nil at 1252, `beginFinalStop` nil at 41 |

`waitForPendingStopRequests` (1236) now returns at once. The cancelled task then fails its check
at 5840 and calls `stopRejectedRemoteStream` (5844, 5919 to 5923), which sends the stop for the
session it negotiated. `surfaceFailure` does append the cancelled task (5155 to 5158), so the
same race after a failure is joined; `stop()` does not.

What it costs: a probe that joins `waitForPendingStopRequests` before publishing its final
report (the use `docs/PLAYBACK-ARCHITECTURE.md` gives the join) can report before this session's
stop has been sent. If that stop then fails, nothing retries it: the barrier keeps the
operation in a controller that is closed.

`Proposed-CloseJoinsTask` turns on `FixCloseJoinsTask`: `stop()` appends the task it cancels and
`embyReopenTransactionTail`. The tail is needed too, because a consent request's task replaces
`playbackTask` without joining the chain, and a superseded reopen may still be behind it.

### Conditional: a stop that timed out ends the replacement (`Finding-LateStopKillsReusedId`)

`StopNeverKillsSuccessor` is violated in 12 states with `StopsCanBeLate` and
`IdReuse = "stopped"`. It needs Emby to return a play-session id again, and to apply a request
the client has stopped waiting for.

| Step | Model | Swift |
| --- | --- | --- |
| 1 | `Start` | |
| 2 | `Fail`: a failure surfaces and the session's stop goes to the barrier. Request 1 | `surfaceFailure` 5133, `stopRemoteSessionIfNeeded` 5178: `beginEmbySessionStop` 1244 to 1250 |
| 3 | `ClockTicks`: the request passes its timeout with no answer | `URLSession.shared`'s request timeout; no other bound on the stop |
| 4 | `BarrierResolves`: the stop reads as unconfirmed and the barrier keeps it | `MediaBrowserActiveEncodingStopExecutor.stop` returns `false` for a transport error; `EmbyReopenStopBarrier.swift` 30 keeps `operation` |
| 5 | `Reopen`: a quality or track change while the failure shows. The barrier has authority, so it runs the operation again. Request 2 | `reopenRemoteStream` 5796 to 5797, `begin` 27 to 35 |
| 6 | `ServerResolves`: request 2 is acknowledged and ends the old job | |
| 7 to 9 | `TaskJoins`, `BarrierResolves`, `TaskStopAcked`: the acknowledgement is back and the task negotiates | 5822 to 5829, 5839 |
| 10 | `NegotiateLands`: Emby returns the old session's id for the replacement | |
| 11 | `ServerResolves`: request 1 is applied. It names the device and that id, and ends the replacement | `EmbyLibrary.activeEncodingStopRequest` |

Retry in place of the quality change gives the same trace, two steps longer (`Retry`,
`RetryProceeds`). Retaining the failed stop and retrying it is the design (LS-PB-008), and it is
what puts two requests for one session on the wire. The barrier knows the first one was never
answered; nothing uses that. If Emby mints a new id for every PlaybackInfo, the late request
finds nothing under its id and the trace ends harmlessly at step 10: `Current-LateAck`.

### Conditional: a closing playback's retried stop ends the next playback (`Finding-BackToBackStaleStop`)

`StopNeverKillsSuccessor` is violated in 8 states with two controllers, `IdsNeverShared = FALSE`
and `IdReuse = "stopped"`. No timeout is involved. It needs Emby to give the next playback a
play-session id the previous one's stopped session had.

| Step | Model | Swift |
| --- | --- | --- |
| 1 | `Start` (first controller) | |
| 2 | `Reopen`: the session's stop goes to the barrier. Request 1 | 5797 |
| 3 | `ServerResolves`: Emby applies it, and the answer is lost | |
| 4 | `BarrierResolves`: unconfirmed; the barrier keeps the operation | `EmbyReopenStopBarrier.swift` 30 |
| 5 | `Close`: the player is dismissed. Teardown retries the failed stop once. Request 2. Nothing waits for it | `stop()` 1203, `stopRemoteSessionIfNeeded` 1259, `beginFinalStop` 39 to 44 |
| 6 | `Start` (second controller): the next playback's negotiation returns the same id | `DetailPlaybackLauncher`, before the controller exists |
| 7 | `ServerResolves`: request 2 is applied and ends the new playback's job | |

`docs/PLAYBACK-ARCHITECTURE.md` says "UI teardown remains non-blocking", so the next playback
can start while request 2 is in flight. The single retry at teardown is deliberate. The trace
needs the first request to be applied without its answer arriving, and the id to come back
within the retry's flight.

### Conditional: a cancelled negotiation the server still acts on (`Finding-AbandonedNegotiateOrphans`)

`NoOrphans` is violated in 9 states with `AbandonedNegotiateCanLand`.

| Step | Model | Swift |
| --- | --- | --- |
| 1 to 6 | `Start`, `Reopen`, `ServerResolves`, `TaskJoins`, `BarrierResolves`, `TaskStopAcked`: the old session is stopped and the PlaybackInfo request is on the wire | 5839 |
| 7 | `Reopen`: a second reopen cancels the task, and with it the request. Close does the same | `playbackTask?.cancel()` 5766, or 1181 |
| 8 | `NegotiateLands`: Emby acts on the request all the same | |

The cancelled task's request throws and its `catch` returns (5903 to 5907): it has no result to
reject, so `stopRejectedRemoteStream` is never called and the client never learns the id. This
is suspect 4's late start in the MediaBrowser shape. It is a defect only if a PlaybackInfo answer
alone leaves something on the server that needs a stop. The Swift is written as if it may
(`acceptInitialOpen`, `stopRejectedRemoteStream`); if Emby starts the encoder at the first
playlist request instead, which the client never makes without the answer, nothing is left
behind.

## Checked and not found

- **The barrier's preconditions.** `BarrierPreconditions` holds in every `Current`, `Proposed`
  and `Deep` config. A stop is offered to the barrier in three places: a reopen or a teardown
  hands over the playing session's stop, and `stopRejectedRemoteStream` hands over a rejected
  one. The first two need a session whose callbacks are installed, which only an attach does,
  and an attach needs the barrier empty; the third comes from the one reopen that is past its
  predecessor. The transaction tail is what makes that "the one".
- **A restart from a failure.** The restart core's `Finding-RestartAfterFailureSkipsFinalStop`
  (fixed for Plex in #527, now `Faithful-RestartAfterFailureSkipsFinalStop-off`) does not carry over. `didStop` belongs to the session and an attach clears it, so a quality
  change while a failure shows leaves a session that Close stops. `Current-Reopen` has
  `RestartFromFailure` on and checks `NoOrphans`.
- **Retry's join.** `retry()` awaits `waitForPendingStopRequests` before it reopens. For Emby
  the barrier and the tail already hold the reopen back: `Current-Reopen` with
  `RetryJoinsPendingStops = FALSE` passes every property (5,317,743 distinct states). The join
  is not what keeps the order here, so no mutant is kept for it.
- **The #530 join on a restart from a failure.** Since #530 a quality or track change while a
  failure shows joins `pendingStopTasks` (as `retry()` does) before `reopenRemoteStream`. This
  model does not add that join: `Reopen` still reopens at once while a failure shows, as do the
  automatic reopens it also stands for. The model therefore allows the un-joined order as well,
  a superset of the code's behaviours, so its safety passes stay sound. One difference it does
  not show: when the failure's stop was not acknowledged, the reopen after the join makes one
  more stop attempt through the barrier.
- **Close while the consent choice shows** (review focus 4). `stop()` clears the consent
  generation, joins a rejected session's stop if one is in flight, and retries a failed one once.
  `Current-CloseAtConsent` reaches Close with the choice showing, with and without that stop in
  flight.

Two things the model shows about teardown that break no property, since a stop that was sent
counts:

- "Terminal cleanup has one bounded retry" holds only for a stop that had already failed before
  the teardown. A session that is playing at Close gets one request and no retry: `stop()` hands
  it over, `beginFinalStop` returns the ticket in flight, and nothing calls it again.
- A rejected session whose stop fails after Close is never retried. The barrier keeps it, in a
  controller nobody will ask again.

## For the Jellyfin module

- `IdReuse` is how this module lets the server choose the id it mints. `Mintable` offers one
  unused id for all of them, so configs need no symmetry set.
- A two-controller run with `IdsNeverShared = FALSE` passes here only without failing stops, and
  (with `ServerRecreate` on) with `StopEndsAllUnderId`. Any
  stop that can be sent twice for one job, or outlive its wait, reaches whatever the id names
  next.
- `BarTicket` shows how to keep a `pendingStops` entry whose end is not the request's end.
