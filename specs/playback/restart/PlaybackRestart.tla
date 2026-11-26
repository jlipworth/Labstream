-------------------------- MODULE PlaybackRestart --------------------------
\* MODELS: Labstream/Shared/Player/PlaybackController.swift
\* MODELS: Labstream/Shared/Player/PlaybackRestartIntent.swift
\* MODELS: Labstream/Shared/Player/PlaybackPositionModels.swift
\* MODELS: PMSKit/Sources/PMSKit/Transcode/SeekRestartBudget.swift
\* MODELS: PMSKit/Sources/PMSKit/Transcode/FinalTargetRebuildPolicy.swift
\* MODELS: PMSKit/Sources/PMSKit/Transcode/AdaptiveBitratePolicy.swift
\* MODELS: PMSKit/Sources/PMSKit/RemoteStreamLifecyclePolicy.swift
\* MODELS: Labstream/Shared/Player/PlaybackSessionSource.swift
(***************************************************************************)
(* PlaybackController's restart and cleanup core, with the backend's       *)
(* replacement order abstracted to "stop the prior session, then           *)
(* replace".  The Plex, Emby and Jellyfin orders are their own modules.    *)
(*                                                                         *)
(* Each MainActor run between two awaits is one action.                    *)
(*                                                                         *)
(*   User      UserSeek, UserQuality, UserPause, Retry, Close              *)
(*   Player    Fail, StallWatchdog, StartupDeadline, AbrSwitch,            *)
(*             ReadyToPlay, ResumeSeekComplete, SeekComplete,              *)
(*             SeekHoldCeiling                                             *)
(*   Timers    SeekSettle (finalTargetSettleTask), RetryProceeds and       *)
(*             RetryBails (failureRetryTask after                          *)
(*             waitForPendingStopRequests)                                 *)
(*   Task      the playbackTask of one start or restart, current or        *)
(*             cancelled and still unwinding:                              *)
(*               awaitStop     waiting for the prior session's stop        *)
(*               negotiate     the start or reopen request is on the wire  *)
(*               negotiated    the server accepted it; the answer is on    *)
(*                             its way back                                *)
(*               standUp       await proxy.standUpLoopback                 *)
(*               oldProxyStop  await oldProxy.stop(generation:), the       *)
(*                             yield the stand-up is split at:             *)
(*                             ProxyStandUp before, ProxyInstall after     *)
(*               stopOwnProxy  await proxy.stop for the task's own proxy   *)
(*               awaitReject   stopRejectedRemoteStream is waiting         *)
(*   Cleanup   ProxyStopRuns (a pendingStopTasks entry stops a listener)   *)
(*   Server    NegotiateLands, ServerAck, ServerFail, ServerDelay          *)
(*                                                                         *)
(* A cancelled task is not removed: cancellation is cooperative, so it     *)
(* stays in `unwinding` and runs to its next check, or to completion once  *)
(* it is past its last one.                                                *)
(*                                                                         *)
(* Every replacement is given a session id the server has not used.  Id    *)
(* reuse is the subject of the Plex and Jellyfin modules; no property      *)
(* here depends on it.                                                     *)
(***************************************************************************)
EXTENDS PlaybackControllerOps, TLC

CONSTANTS
    \* Bounds.
    MaxUserActions,   \* seeks, quality changes, pauses and Retry taps
    RestartBudget,    \* SeekRestartBudget.burstLimit, inside one burst window
    AbrRungs,         \* adaptive-bitrate rungs below the user's cap
    AbrMaxChanges,    \* AdaptiveBitratePolicy.maxChangesPerWindow, inside one
                      \* change window
    AutoRestartBound, \* the most restarts in a row with no user action
    RestartRoom,      \* generations a restart reserves: its own bump, its
                      \* load(), and one for a Close or failure after that

    \* What the run includes.
    UserSeeks,        \* the user seeks
    UserPauses,       \* the user pauses and resumes
    ResumeSeeks,      \* an attached item issues the client resume seek
    UsesProxy,        \* a replacement may stand up a loopback proxy
    EnvFails,         \* a negotiation or the player may fail
    AutoRecovery,     \* the stall watchdog, startup-deadline retry and ABR

    \* The two shapes PlaybackController has for a session's cleanup.
    RejectedResultStopped,
        \* TRUE: reopenRemoteStream.  A result the generation check rejects
        \* is stopped by stopRejectedRemoteStream.  FALSE: startStreaming.
        \* Every check is a bare return.
    StopLatchPerSession,
        \* TRUE: MediaBrowserPlaybackSession.didStop, cleared by the reopen
        \* that installs the next session's callbacks.  FALSE:
        \* sentTranscodeStop, one latch per controller that only retry()
        \* clears.

    \* Shipping behaviour.  TRUE is the code as it stands.
    StopDetachesFirst,
    AttachChecksGeneration,
    SeekClearChecksGeneration,
    ResumeSeekGuarded,
    RetryPreservesPause,
    EscalateOnExhaustedBudget,
    StartupRetryOneShot,
    CleanupClearsProxySlot,
    CloseSendsFinalStop,
    RetryJoinsPendingStops,
    CancelDropsAnswer,
        \* cancelling a playbackTask cancels the URLSession request of
        \* remoteStreamReopener with it: an answer to a request the server
        \* already acted on is lost, the catch's acceptsReopenResult guard
        \* fails and the task returns without stopping the session.  FALSE
        \* is the proposed fix: the request runs without inheriting
        \* cancellation and the rejected result is stopped.

    \* Proposed fixes.  FALSE is the code as it stands.
    FixProxyRecheck,
        \* re-check the generation after `await oldProxy.stop` and stop
        \* the new proxy instead of installing it
    FixJoinCancelledTasks,
        \* every playbackTask?.cancel() also appends `await task.value`
        \* to pendingStopTasks, as surfaceFailure does
    FixSettleSurvivesAttach,
        \* load() does not fence out a pending final-target settle
    FixRestartResetsStopLatch,
        \* every restart clears sentTranscodeStop, not only retry()
    FixRetryBailClearsTask
        \* failureRetryTask clears itself when its generation check fails

ASSUME /\ MaxUserActions \in Nat
       /\ RestartBudget \in Gens
       /\ AbrRungs \in Nat
       /\ AbrMaxChanges \in Nat
       /\ AutoRestartBound \in Nat
       /\ RestartRoom \in {2, 3}
       /\ MaxGeneration >= 2
       /\ \A b \in {UserSeeks, UserPauses, ResumeSeeks, UsesProxy, EnvFails,
                    AutoRecovery, RejectedResultStopped,
                    StopLatchPerSession, StopDetachesFirst,
                    AttachChecksGeneration, SeekClearChecksGeneration,
                    ResumeSeekGuarded, RetryPreservesPause,
                    EscalateOnExhaustedBudget, StartupRetryOneShot,
                    CleanupClearsProxySlot, CloseSendsFinalStop,
                    RetryJoinsPendingStops, CancelDropsAnswer,
                    FixProxyRecheck,
                    FixJoinCancelledTasks, FixSettleSurvivesAttach,
                    FixRestartResetsStopLatch, FixRetryBailClearsTask} :
              b \in BOOLEAN

VARIABLES
    life,           \* "new", "open", "closed"; "closing" exists only with
                    \* StopDetachesFirst off
    failed,         \* playbackError.isFailed
    cur,            \* the session whose stop callbacks the controller holds
    latch,          \* sentTranscodeStop
    retryGen,       \* failureRetryTask: the generation it captured, 0 for nil
    seekDone,       \* native seek completions queued, by hold generation
    resumeGen,      \* the item generation the resume seek was last issued for
    resumeDone,     \* resume-seek completions queued, by item generation
    playing,        \* the player was told to play and not to pause
    wantPause,      \* ghost: what the user last asked for
    settle,         \* finalTargetSettleTask: its captured generation, 0 for nil
    pendingTarget,  \* FinalTargetRebuildPolicy.pendingOffsetMs is set
    startupArmed,   \* ~startupDeadlineRetryAttempted
    rung,           \* downshifts the adaptive-bitrate policy still has
    abrLeft,        \* changes AdaptiveBitratePolicy still allows in the window
    autoRun,        \* ghost: restarts in a row with no user action
    seekRun,        \* ghost: seek rebuilds since the budget was last reset
    userLeft,       \* user actions left
    starts,         \* tasks started, all controllers: one session id each
    breach          \* ghost: fencing breaks seen so far

ownVars ==
    <<life, failed, cur, latch, retryGen, seekDone, resumeGen, resumeDone,
      playing, wantPause, settle, pendingTarget, startupArmed, rung, abrLeft, autoRun,
      seekRun, userLeft, starts, breach>>

\* ownVars without settle, for the steps that run beginStreaming's tail.
ownRest ==
    <<life, failed, cur, latch, retryGen, seekDone, resumeGen, resumeDone,
      playing, wantPause, pendingTarget, startupArmed, rung, abrLeft, autoRun,
      seekRun, userLeft, starts, breach>>

\* ownRest without breach, for a rejected result.
ownRejected ==
    <<life, failed, cur, latch, retryGen, seekDone, resumeGen, resumeDone,
      playing, wantPause, pendingTarget, startupArmed, rung, abrLeft, autoRun,
      seekRun, userLeft, starts>>

vars == <<serverVars, ctlVars, ownVars>>

-----------------------------------------------------------------------------
(* Vocabulary                                                              *)

Lives == {"new", "open", "closing", "closed"}

\* The session the controller would stop on Close.  `stopped` is didStop:
\* a stop meant for it has been sent.
NoCur == [sid |-> NoSession, inc |-> 0, stopped |-> TRUE]

TaskPcs ==
    {"awaitStop", "negotiate", "negotiated", "standUp", "oldProxyStop",
     "stopOwnProxy", "awaitReject"}

\* A playbackTask.  `gen` is the generation it captured, and names it.
\* `sid` and `inc` are the job its request created.  `px` is the proxy it
\* stood up (its own generation, 0 for none) and `old` the proxy whose
\* stop it awaits.  `rb` marks a final-target rebuild.
RTask(g, pc, s, i, px, old, rb) ==
    [gen |-> g, pc |-> pc, sid |-> s, inc |-> i, px |-> px, old |-> old,
     rb |-> rb]

IsRTask(t) ==
    /\ DOMAIN t = {"gen", "pc", "sid", "inc", "px", "old", "rb"}
    /\ t.gen \in 1..MaxGeneration
    /\ t.pc \in TaskPcs
    /\ t.sid \in SessionIds \cup {NoSession}
    /\ t.inc \in Gens /\ t.px \in Gens /\ t.old \in Gens
    /\ t.rb \in BOOLEAN

\* A fencing break: its kind and, for a proxy the yield race touched, the
\* generation of that proxy (0 otherwise).
B(kind) == <<kind, 0>>
\* A session whose answer was lost to cancellation is marked with its id
\* (ids are never reused here, so the id names the job).
BreachKinds ==
    ({"staleAttach", "staleSeekRelease", "staleResume", "retryBeforeJoin",
      "yieldRace"} \X {0})
    \cup ({"racedProxy"} \X ProxyGens)
    \cup ({"lostAnswer"} \X SessionIds)

TypeOK ==
    /\ BaseTypeOK
    /\ life \in [Controllers -> Lives]
    /\ failed \in [Controllers -> BOOLEAN]
    /\ cur \in [Controllers ->
                   [sid : SessionIds \cup {NoSession}, inc : Gens,
                    stopped : BOOLEAN]]
    /\ latch \in [Controllers -> BOOLEAN]
    /\ retryGen \in [Controllers -> Gens]
    /\ seekDone \in [Controllers -> SUBSET Gens]
    /\ resumeGen \in [Controllers -> Gens]
    /\ resumeDone \in [Controllers -> SUBSET Gens]
    /\ playing \in [Controllers -> BOOLEAN]
    /\ wantPause \in [Controllers -> BOOLEAN]
    /\ settle \in [Controllers -> Gens]
    /\ pendingTarget \in [Controllers -> BOOLEAN]
    /\ startupArmed \in [Controllers -> BOOLEAN]
    /\ rung \in [Controllers -> 0..AbrRungs]
    /\ abrLeft \in [Controllers -> 0..AbrMaxChanges]
    /\ autoRun \in [Controllers -> Nat]
    /\ seekRun \in [Controllers -> Nat]
    /\ userLeft \in [Controllers -> 0..MaxUserActions]
    /\ starts \in 0..Cardinality(SessionIds)
    /\ breach \in [Controllers -> SUBSET BreachKinds]
    /\ \A c \in Controllers :
          /\ task[c] = NoTask \/ IsRTask(task[c])
          /\ \A t \in unwinding[c] : IsRTask(t)

Init ==
    /\ ServerInit
    /\ ControllerInit(RestartBudget)
    /\ life = [c \in Controllers |-> "new"]
    /\ failed = [c \in Controllers |-> FALSE]
    /\ cur = [c \in Controllers |-> NoCur]
    /\ latch = [c \in Controllers |-> FALSE]
    /\ retryGen = [c \in Controllers |-> 0]
    /\ seekDone = [c \in Controllers |-> {}]
    /\ resumeGen = [c \in Controllers |-> 0]
    /\ resumeDone = [c \in Controllers |-> {}]
    /\ playing = [c \in Controllers |-> FALSE]
    /\ wantPause = [c \in Controllers |-> FALSE]
    /\ settle = [c \in Controllers |-> 0]
    /\ pendingTarget = [c \in Controllers |-> FALSE]
    /\ startupArmed = [c \in Controllers |-> TRUE]
    /\ rung = [c \in Controllers |-> AbrRungs]
    /\ abrLeft = [c \in Controllers |-> AbrMaxChanges]
    /\ autoRun = [c \in Controllers |-> 0]
    /\ seekRun = [c \in Controllers |-> 0]
    /\ userLeft = [c \in Controllers |-> MaxUserActions]
    /\ starts = 0
    /\ breach = [c \in Controllers |-> {}]

-----------------------------------------------------------------------------
(* Reading the controller                                                  *)

\* Every task of c that has not returned.
Tasks(c) ==
    unwinding[c] \cup (IF task[c] = NoTask THEN {} ELSE {task[c]})

\* !Task.isCancelled && generation == playbackGeneration, for task t.
\* task[c] always holds the newest generation: every step that bumps it
\* either replaces the task or clears the slot.
IsCurrentTask(c, t) == t = task[c]

\* FinalTargetRebuildPolicy.activeGeneration is set.  beginStreaming,
\* surfaceFailure and stop() clear it whenever they cancel the task.
RebuildActive(c) == task[c] # NoTask /\ task[c].rb

Detached(c) == IF item[c] = "attached" THEN "detached" ELSE item[c]

\* seekHold.begin: a new generation, held.
HoldBegin(c) == [gen |-> seekHold[c].gen + 1, held |-> TRUE]
\* The same at the bound of the model, for a step that cannot be skipped.
HoldBeginBounded(c) ==
    [gen |-> IF seekHold[c].gen < MaxGeneration THEN seekHold[c].gen + 1
             ELSE seekHold[c].gen,
     held |-> TRUE]
HoldClear(c) == [seekHold[c] EXCEPT !.held = FALSE]

InFlightStops(c, s, i) ==
    {r \in StopsFor(c, s, i) : r.status = "inFlight"}

\* A wait for the stops meant for job i of s is over: each has an answer,
\* or the bounded wait gave up.
StopWaitOver(c, s, i) ==
    \A r \in StopsFor(c, s, i) : r.status # "inFlight" \/ r.late

-----------------------------------------------------------------------------
(* Pieces shared by several actions                                        *)

\* task t becomes t2, wherever it is.
SetTask(c, t, t2) ==
    IF t = task[c]
    THEN /\ task' = Upd(task, c, t2)
         /\ UNCHANGED unwinding
    ELSE /\ unwinding' = Upd(unwinding, c, (unwinding[c] \ {t}) \cup {t2})
         /\ UNCHANGED task

\* task t returns.
DropTask(c, t) ==
    IF t = task[c]
    THEN /\ task' = Upd(task, c, NoTask)
         /\ UNCHANGED unwinding
    ELSE /\ unwinding' = Upd(unwinding, c, unwinding[c] \ {t})
         /\ UNCHANGED task

\* The breach set after the current task is cancelled: cancelling it at
\* the `await oldProxy.stop` yield is the race of suspect 1.
CancelBreach(c) ==
    IF task[c] # NoTask /\ task[c].pc = "oldProxyStop"
    THEN breach[c] \cup {B("yieldRace"), <<"racedProxy", task[c].px>>}
    ELSE breach[c]

\* The ticket the proposed fix adds when a task is cancelled.
CancelJoin(c) ==
    IF FixJoinCancelledTasks /\ task[c] # NoTask
    THEN {TaskJoinTicket(task[c].gen)}
    ELSE {}

\* beginStreaming's tail, which runs when a final-target rebuild task
\* returns, cancelled or not: a target recorded meanwhile is consumed and
\* scheduled again (scheduleFinalTargetRebuild), under generation g.
TailFires(c, t, failedNow) == t.rb /\ pendingTarget[c] /\ ~failedNow

Tail(c, t, failedNow, g) ==
    IF TailFires(c, t, failedNow)
    THEN /\ settle' = Upd(settle, c, g)
         /\ seekHold' = Upd(seekHold, c, HoldBeginBounded(c))
    ELSE UNCHANGED <<settle, seekHold>>

\* The bounds leave room for one more task: a generation for the restart,
\* one for its load(), one for a Close or failure after the load()
\* (RestartRoom = 3), and a session id.  With RestartRoom = 2 the last
\* attach the bound allows leaves no generation for Close
\* (Mutant-RestartRoomTwo).
RoomToRestart(c) ==
    /\ gen[c] + RestartRoom <= MaxGeneration
    /\ starts < Cardinality(SessionIds)

\* playbackTask?.cancel(), playbackGeneration += 1, detach, and the new
\* task: the part beginStreaming and reopenRemoteStream share.  The prior
\* session's stop goes out here and the task waits for it.  The caller
\* sets budget, pendingTarget, seekRun, startupArmed, rung, autoRun,
\* userLeft, retryGen, latch, failed, paused and breach.
RestartCore(c, rb) ==
    /\ RoomToRestart(c)
    /\ starts' = starts + 1
    /\ gen' = Upd(gen, c, gen[c] + 1)
    /\ unwinding' = Upd(unwinding, c, UnwindingAfterCancel(c))
    /\ task' = Upd(task, c,
           RTask(gen[c] + 1,
                 IF cur[c] = NoCur THEN "negotiate" ELSE "awaitStop",
                 NoSession, 0, 0, 0, rb))
    /\ pendingStops' = Upd(pendingStops, c, pendingStops[c] \cup CancelJoin(c))
    /\ IF cur[c] # NoCur /\ ~cur[c].stopped
       THEN /\ SendStopFor(c, cur[c].sid, cur[c].inc)
            /\ cur' = Upd(cur, c, [cur[c] EXCEPT !.stopped = TRUE])
       ELSE UNCHANGED <<serverVars, cur>>
    /\ item' = Upd(item, c, Detached(c))
    /\ playing' = Upd(playing, c, FALSE)
    /\ settle' = Upd(settle, c, 0)
    /\ seekHold' = Upd(seekHold, c, HoldBeginBounded(c))
    /\ UNCHANGED <<itemGen, proxy, jellyfinWindow, life, seekDone, resumeGen,
                   resumeDone, wantPause>>

\* The steps of a PlaybackRestartPlan every intent has: resetFinalTarget
\* (which also resets the restart budget) and rearmStartupDeadlineRetry.
\* `user`: the reset comes from explicit user intent (Retry, a quality or
\* track change, Close).  The ghost seekRun measures the budget against
\* SeekRestartBudget's contract, "reset() on explicit user intent"
\* (SeekRestartBudget.swift 17), so only those reset it; the code's own
\* budget is reset by every caller (Finding-UnattendedRestartResetsSeekBudget).
PlanResetG(c, user) ==
    /\ budget' = Upd(budget, c, RestartBudget)
    /\ pendingTarget' = Upd(pendingTarget, c, FALSE)
    /\ seekRun' = Upd(seekRun, c, IF user THEN 0 ELSE seekRun[c])
PlanReset(c) == PlanResetG(c, TRUE)

\* sendTranscodeStop / stopRemoteSessionIfNeeded would send a stop now.
FinalStopNeeded(c) ==
    /\ cur[c] # NoCur /\ ~cur[c].stopped
    /\ StopLatchPerSession \/ ~latch[c]

\* What pendingStopTasks gains: the stop sent now, and a stop already in
\* flight for the same session (Emby's beginFinalStop joins the barrier;
\* Plex sends the stop again under the same id).
FinalStopTickets(c) ==
    (IF FinalStopNeeded(c)
     THEN {ServerStopTicket(NextStopReq(c, cur[c].sid, cur[c].inc))}
     ELSE {})
    \cup (IF cur[c] = NoCur THEN {}
          ELSE {ServerStopTicket(r) :
                    r \in InFlightStops(c, cur[c].sid, cur[c].inc)})

\* What stop() and surfaceFailure share.  `inTask`: the failure is raised
\* by the current task itself, which then returns.  `join`: the cancelled
\* task is appended to pendingStopTasks.  `send`: server stops go out.
\* `user`: stop() is user intent, surfaceFailure is not.
Terminal(c, inTask, join, send, user) ==
    /\ gen[c] < MaxGeneration
    /\ gen' = Upd(gen, c, gen[c] + 1)
    /\ unwinding' =
           IF inTask THEN unwinding
           ELSE Upd(unwinding, c, UnwindingAfterCancel(c))
    /\ task' = Upd(task, c, NoTask)
    /\ pendingStops' = Upd(pendingStops, c,
           pendingStops[c]
           \cup (IF join /\ task[c] # NoTask
                 THEN {TaskJoinTicket(task[c].gen)} ELSE {})
           \cup (IF CleanupClearsProxySlot /\ proxy[c].slot # 0
                 THEN {ProxyStopTicket(proxy[c].slot)} ELSE {})
           \cup (IF send THEN FinalStopTickets(c) ELSE {}))
    /\ proxy' = Upd(proxy, c,
           IF CleanupClearsProxySlot
           THEN [proxy[c] EXCEPT !.slot = 0] ELSE proxy[c])
    /\ IF send /\ FinalStopNeeded(c)
       THEN /\ SendStopFor(c, cur[c].sid, cur[c].inc)
            /\ cur' = Upd(cur, c, [cur[c] EXCEPT !.stopped = TRUE])
       ELSE UNCHANGED <<serverVars, cur>>
    /\ latch' = Upd(latch, c, send \/ latch[c])
    /\ seekHold' = Upd(seekHold, c, HoldClear(c))
    /\ settle' = Upd(settle, c, 0)
    /\ PlanResetG(c, user)
    /\ playing' = Upd(playing, c, FALSE)
    /\ breach' = Upd(breach, c, IF inTask THEN breach[c] ELSE CancelBreach(c))

\* surfaceFailure, past its `guard !playbackError.isFailed`.  Playback
\* stays open, so the bound keeps a generation for the Close after it.
SurfaceFailure(c, inTask) ==
    /\ gen[c] + RestartRoom - 1 <= MaxGeneration
    /\ Terminal(c, inTask, TRUE, TRUE, FALSE)
    /\ failed' = Upd(failed, c, TRUE)
    /\ item' = Upd(item, c, Detached(c))
    /\ UNCHANGED <<itemGen, paused, jellyfinWindow, life, retryGen, seekDone,
                   resumeGen, resumeDone, wantPause, startupArmed, rung, abrLeft,
                   autoRun, userLeft, starts>>

\* load(): the task hands its session to the controller and attaches the
\* item.  load() bumps playbackGeneration again and clears playbackError.
Attach(c, t, proxyNew) ==
    /\ gen[c] < MaxGeneration
    /\ LET g == gen[c] + 1 IN
       /\ gen' = Upd(gen, c, g)
       /\ itemGen' = Upd(itemGen, c, g)
       /\ IF TailFires(c, t, FALSE)
          THEN /\ settle' = Upd(settle, c, g)
               /\ seekHold' = Upd(seekHold, c, HoldBeginBounded(c))
          ELSE /\ settle' = Upd(settle, c,
                      IF FixSettleSurvivesAttach /\ settle[c] # 0
                      THEN g ELSE settle[c])
               /\ UNCHANGED seekHold
    /\ item' = Upd(item, c, "attached")
    /\ cur' = Upd(cur, c, [sid |-> t.sid, inc |-> t.inc, stopped |-> FALSE])
    /\ failed' = Upd(failed, c, FALSE)
    /\ playing' = Upd(playing, c, ~paused[c])
    /\ proxy' = Upd(proxy, c, proxyNew)
    /\ DropTask(c, t)
    /\ breach' = Upd(breach, c,
           IF IsCurrentTask(c, t) THEN breach[c]
           ELSE breach[c] \cup {B("staleAttach")})
    /\ UNCHANGED <<serverVars, budget, paused, pendingStops, jellyfinWindow,
                   life, latch, retryGen, seekDone, resumeGen, resumeDone,
                   wantPause, pendingTarget, startupArmed, rung, abrLeft, autoRun,
                   seekRun, userLeft, starts>>

\* A cancelled task finds its result rejected.  reopenRemoteStream stops
\* the session it negotiated and waits; startStreaming returns.
Reject(c, t, proxyNew, breachNew) ==
    /\ proxy' = Upd(proxy, c, proxyNew)
    /\ breach' = Upd(breach, c, breachNew)
    /\ IF RejectedResultStopped
       THEN /\ SendStopFor(c, t.sid, t.inc)
            /\ SetTask(c, t, [t EXCEPT !.pc = "awaitReject"])
            /\ UNCHANGED <<settle, seekHold>>
       ELSE /\ DropTask(c, t)
            /\ Tail(c, t, failed[c], gen[c])
            /\ UNCHANGED serverVars
    /\ UNCHANGED <<gen, itemGen, item, budget, paused, pendingStops,
                   jellyfinWindow, ownRejected>>

-----------------------------------------------------------------------------
(* User                                                                    *)

\* start(), and beginStreaming or beginRemoteStream.
Start(c) ==
    /\ life[c] = "new"
    /\ starts < Cardinality(SessionIds)
    /\ starts' = starts + 1
    /\ life' = Upd(life, c, "open")
    /\ gen' = Upd(gen, c, 1)
    /\ task' = Upd(task, c, RTask(1, "negotiate", NoSession, 0, 0, 0, FALSE))
    /\ UNCHANGED <<serverVars, itemGen, item, unwinding, seekHold, budget,
                   paused, proxy, pendingStops, jellyfinWindow, failed, cur,
                   latch, retryGen, seekDone, resumeGen, resumeDone, playing,
                   wantPause, settle, pendingTarget, startupArmed, rung, abrLeft,
                   autoRun, seekRun, userLeft, breach>>

\* reload(bitrateKbps:), and the audio and subtitle track changes: an
\* intent other than explicitRetry.  Nothing here asks whether playback
\* has failed, and the plan does not clear the error.
UserQuality(c) ==
    /\ life[c] = "open"
    /\ userLeft[c] > 0
    /\ RestartCore(c, FALSE)
    /\ PlanReset(c)
    /\ startupArmed' = Upd(startupArmed, c, TRUE)
    /\ rung' = Upd(rung, c, AbrRungs)
    /\ abrLeft' = Upd(abrLeft, c, AbrMaxChanges)
    /\ autoRun' = Upd(autoRun, c, 0)
    /\ userLeft' = Upd(userLeft, c, userLeft[c] - 1)
    /\ retryGen' = Upd(retryGen, c, 0)
    /\ latch' = Upd(latch, c,
           IF FixRestartResetsStopLatch THEN FALSE ELSE latch[c])
    /\ breach' = Upd(breach, c, CancelBreach(c))
    /\ UNCHANGED <<failed, paused>>

\* performUserSeek with a target AVPlayer can seek to itself (in the
\* buffer, on a lane that never reopens to seek, or after a failure):
\* hold the scrubber and wait for the completion handler.  The settle
\* timer is cancelled.  The Swift leaves the recorded target behind, but
\* nothing reads it before the next seek or reset overwrites it: only a
\* running rebuild's tail could, and while one runs there is no item to
\* seek natively.  The model clears it.
UserSeekNative(c) ==
    /\ ~RebuildActive(c)
    /\ seekHold' = Upd(seekHold, c, HoldBegin(c))
    /\ seekDone' = Upd(seekDone, c, seekDone[c] \cup {seekHold[c].gen + 1})
    /\ settle' = Upd(settle, c, 0)
    /\ pendingTarget' = Upd(pendingTarget, c, FALSE)

\* performUserSeek out of the buffer: record the target and arm the
\* debounced rebuild, which captures playbackGeneration.
UserSeekRebuild(c) ==
    /\ ~failed[c]
    /\ seekHold' = Upd(seekHold, c, HoldBegin(c))
    /\ pendingTarget' = Upd(pendingTarget, c, TRUE)
    /\ settle' = Upd(settle, c, gen[c])
    /\ UNCHANGED seekDone

UserSeek(c) ==
    /\ UserSeeks
    /\ life[c] = "open"
    /\ userLeft[c] > 0
    /\ seekHold[c].gen < MaxGeneration
    /\ UserSeekNative(c) \/ UserSeekRebuild(c)
    /\ startupArmed' = Upd(startupArmed, c, TRUE)
    /\ autoRun' = Upd(autoRun, c, 0)
    /\ userLeft' = Upd(userLeft, c, userLeft[c] - 1)
    /\ UNCHANGED <<serverVars, gen, itemGen, item, task, unwinding, budget,
                   paused, proxy, pendingStops, jellyfinWindow, life, failed,
                   cur, latch, retryGen, resumeGen, resumeDone, playing,
                   wantPause, rung, abrLeft, seekRun, starts, breach>>

\* requestPause and requestPlay.
UserPause(c) ==
    /\ UserPauses
    /\ life[c] = "open"
    /\ userLeft[c] > 0
    /\ paused' = Upd(paused, c, ~paused[c])
    /\ wantPause' = Upd(wantPause, c, ~paused[c])
    /\ playing' = Upd(playing, c, paused[c] /\ item[c] = "attached")
    /\ userLeft' = Upd(userLeft, c, userLeft[c] - 1)
    /\ UNCHANGED <<serverVars, gen, itemGen, item, task, unwinding, seekHold,
                   budget, proxy, pendingStops, jellyfinWindow, life, failed,
                   cur, latch, retryGen, seekDone, resumeGen, resumeDone,
                   settle, pendingTarget, startupArmed, rung, abrLeft, autoRun,
                   seekRun, starts, breach>>

\* retry(): start failureRetryTask, which first joins pendingStopTasks.
Retry(c) ==
    /\ life[c] = "open"
    /\ failed[c]
    /\ retryGen[c] = 0
    /\ userLeft[c] > 0
    /\ RoomToRestart(c)
    /\ retryGen' = Upd(retryGen, c, gen[c])
    /\ userLeft' = Upd(userLeft, c, userLeft[c] - 1)
    /\ UNCHANGED <<serverVars, ctlVars, life, failed, cur, latch, seekDone,
                   resumeGen, resumeDone, playing, wantPause, settle,
                   pendingTarget, startupArmed, rung, abrLeft, autoRun, seekRun,
                   starts, breach>>

\* failureRetryTask after `await waitForPendingStopRequests()`:
\* restartAtCurrentPosition with the explicitRetry plan.
RetryProceeds(c) ==
    /\ retryGen[c] # 0
    /\ retryGen[c] = gen[c]
    /\ RetryJoinsPendingStops => PendingStopsJoined(c)
    /\ RestartCore(c, FALSE)
    /\ PlanReset(c)
    /\ startupArmed' = Upd(startupArmed, c, TRUE)
    /\ rung' = Upd(rung, c, AbrRungs)
    /\ abrLeft' = Upd(abrLeft, c, AbrMaxChanges)
    /\ autoRun' = Upd(autoRun, c, 0)
    /\ retryGen' = Upd(retryGen, c, 0)
    /\ latch' = Upd(latch, c, FALSE)
    /\ failed' = Upd(failed, c, FALSE)
    /\ paused' = Upd(paused, c, RetryPreservesPause /\ paused[c])
    /\ breach' = Upd(breach, c,
           CancelBreach(c)
           \cup (IF PendingStopsJoined(c) THEN {} ELSE {B("retryBeforeJoin")}))
    /\ UNCHANGED userLeft

\* failureRetryTask wakes to a generation that is no longer the one it
\* captured, without having been cancelled: a restart begun before the
\* Retry tap reached load().  The Swift returns at the guard and leaves
\* failureRetryTask set, which is no step at all; retry() then refuses
\* every later tap.  With the proposed fix the task clears the slot.
RetryBails(c) ==
    /\ FixRetryBailClearsTask
    /\ retryGen[c] # 0
    /\ retryGen[c] # gen[c]
    /\ RetryJoinsPendingStops => PendingStopsJoined(c)
    /\ retryGen' = Upd(retryGen, c, 0)
    /\ UNCHANGED <<serverVars, ctlVars, life, failed, cur, latch, seekDone,
                   resumeGen, resumeDone, playing, wantPause, settle,
                   pendingTarget, startupArmed, rung, abrLeft, autoRun, seekRun,
                   userLeft, starts, breach>>

\* stop().  With StopDetachesFirst off (the order before #327) the server
\* stops go out first and the item is released in a later step.
Close(c) ==
    /\ life[c] = "open"
    /\ Terminal(c, FALSE, FixJoinCancelledTasks, CloseSendsFinalStop, TRUE)
    /\ life' = Upd(life, c, IF StopDetachesFirst THEN "closed" ELSE "closing")
    /\ item' = Upd(item, c, IF StopDetachesFirst THEN Detached(c) ELSE item[c])
    /\ retryGen' = Upd(retryGen, c, 0)
    /\ UNCHANGED <<itemGen, paused, jellyfinWindow, failed, seekDone,
                   resumeGen, resumeDone, wantPause, startupArmed, rung, abrLeft,
                   autoRun, userLeft, starts>>

CloseDetach(c) ==
    /\ life[c] = "closing"
    /\ life' = Upd(life, c, "closed")
    /\ item' = Upd(item, c, Detached(c))
    /\ UNCHANGED <<serverVars, gen, itemGen, task, unwinding, seekHold,
                   budget, paused, proxy, pendingStops, jellyfinWindow,
                   failed, cur, latch, retryGen, seekDone, resumeGen,
                   resumeDone, playing, wantPause, settle, pendingTarget,
                   startupArmed, rung, abrLeft, autoRun, seekRun, userLeft, starts,
                   breach>>

-----------------------------------------------------------------------------
(* Player and timers                                                       *)

\* The item fails, or the reconnect or preparation watchdog fires:
\* handlePlaybackFailure, surfaceReconnectTimeout,
\* handleItemPreparationTimeout.
Fail(c) ==
    /\ EnvFails
    /\ life[c] = "open"
    /\ ~failed[c]
    /\ item[c] = "attached" \/ task[c] # NoTask
    /\ SurfaceFailure(c, FALSE)

\* handleStallTimeout: a downshift while the adaptive-bitrate policy has a
\* lower rung and a change left in its window (intent adaptiveBitrate),
\* then the Retry overlay.  The reset is not user intent.
StallWatchdog(c) ==
    /\ AutoRecovery
    /\ life[c] = "open"
    /\ item[c] = "attached"
    /\ ~failed[c] /\ ~paused[c]
    /\ IF rung[c] > 0 /\ abrLeft[c] > 0
       THEN /\ RestartCore(c, FALSE)
            /\ PlanResetG(c, FALSE)
            /\ startupArmed' = Upd(startupArmed, c, TRUE)
            /\ rung' = Upd(rung, c, rung[c] - 1)
            /\ abrLeft' = Upd(abrLeft, c, abrLeft[c] - 1)
            /\ autoRun' = Upd(autoRun, c, autoRun[c] + 1)
            /\ breach' = Upd(breach, c, CancelBreach(c))
            /\ UNCHANGED <<failed, paused, latch, retryGen, userLeft>>
       ELSE SurfaceFailure(c, FALSE)

\* attemptStartupDeadlineRetry: one reopen per armed allowance, then the
\* Retry overlay.  It is not a restart intent: nothing re-arms it here.
StartupDeadline(c) ==
    /\ AutoRecovery
    /\ life[c] = "open"
    /\ item[c] = "attached"
    /\ ~failed[c]
    /\ IF startupArmed[c]
       THEN /\ RestartCore(c, FALSE)
            /\ PlanResetG(c, FALSE)
            /\ startupArmed' = Upd(startupArmed, c, ~StartupRetryOneShot)
            /\ autoRun' = Upd(autoRun, c, autoRun[c] + 1)
            /\ breach' = Upd(breach, c, CancelBreach(c))
            /\ UNCHANGED <<failed, paused, latch, retryGen, userLeft, rung, abrLeft>>
       ELSE SurfaceFailure(c, FALSE)

\* maybeAdaptBitrateAfterHealthyPlayback: an upshift, while the policy
\* has a change left in its window.  It is not user intent: the run of
\* unattended restarts goes on, bounded by AdaptiveBitratePolicy's
\* maxChangesPerWindow (only reload and explicitRetry reset the policy).
AbrSwitch(c) ==
    /\ AutoRecovery
    /\ life[c] = "open"
    /\ item[c] = "attached"
    /\ ~failed[c] /\ ~paused[c] /\ playing[c]
    /\ rung[c] < AbrRungs
    /\ abrLeft[c] > 0
    /\ RestartCore(c, FALSE)
    /\ PlanResetG(c, FALSE)
    /\ startupArmed' = Upd(startupArmed, c, TRUE)
    /\ rung' = Upd(rung, c, rung[c] + 1)
    /\ abrLeft' = Upd(abrLeft, c, abrLeft[c] - 1)
    /\ autoRun' = Upd(autoRun, c, autoRun[c] + 1)
    /\ breach' = Upd(breach, c, CancelBreach(c))
    /\ UNCHANGED <<failed, paused, latch, retryGen, userLeft>>

\* The .readyToPlay observer issues the client resume seek, once per item.
ReadyToPlay(c) ==
    /\ ResumeSeeks
    /\ life[c] = "open"
    /\ item[c] = "attached"
    /\ resumeGen[c] # itemGen[c]
    /\ resumeGen' = Upd(resumeGen, c, itemGen[c])
    /\ resumeDone' = Upd(resumeDone, c, resumeDone[c] \cup {itemGen[c]})
    /\ UNCHANGED <<serverVars, ctlVars, life, failed, cur, latch, retryGen,
                   seekDone, playing, wantPause, settle, pendingTarget,
                   startupArmed, rung, abrLeft, autoRun, seekRun, userLeft, starts,
                   breach>>

\* The resume seek's completion: resumeAfterCompletedSeek, after
\* isCurrentObservedItem.
ResumeSeekComplete(c, g) ==
    /\ g \in resumeDone[c]
    /\ resumeDone' = Upd(resumeDone, c, resumeDone[c] \ {g})
    /\ LET isCurrent == item[c] = "attached" /\ itemGen[c] = g /\ gen[c] = g
           resumes == IF ResumeSeekGuarded THEN isCurrent /\ ~paused[c]
                      ELSE TRUE
       IN /\ playing' = Upd(playing, c,
                 IF resumes THEN item[c] = "attached" ELSE playing[c])
          /\ breach' = Upd(breach, c,
                 IF resumes /\ ~isCurrent
                 THEN breach[c] \cup {B("staleResume")} ELSE breach[c])
    /\ UNCHANGED <<serverVars, ctlVars, life, failed, cur, latch, retryGen,
                   seekDone, resumeGen, wantPause, settle, pendingTarget,
                   startupArmed, rung, abrLeft, autoRun, seekRun, userLeft, starts>>

\* A native seek's completion handler: clearSeekHold(ifGeneration:).
SeekComplete(c, g) ==
    /\ g \in seekDone[c]
    /\ seekDone' = Upd(seekDone, c, seekDone[c] \ {g})
    /\ LET releases ==
               /\ seekHold[c].held
               /\ SeekClearChecksGeneration => seekHold[c].gen = g
       IN /\ seekHold' = Upd(seekHold, c,
                 IF releases THEN HoldClear(c) ELSE seekHold[c])
          /\ breach' = Upd(breach, c,
                 IF releases /\ seekHold[c].gen # g
                 THEN breach[c] \cup {B("staleSeekRelease")} ELSE breach[c])
    /\ UNCHANGED <<serverVars, gen, itemGen, item, task, unwinding, budget,
                   paused, proxy, pendingStops, jellyfinWindow, life, failed,
                   cur, latch, retryGen, resumeGen, resumeDone, playing,
                   wantPause, settle, pendingTarget, startupArmed, rung, abrLeft,
                   autoRun, seekRun, userLeft, starts>>

\* clearSeekHoldIfLanded: the clock reached the target, or the 12-second
\* ceiling passed.  The deadline is not a field: it can always fire.
SeekHoldCeiling(c) ==
    /\ seekHold[c].held
    /\ seekHold' = Upd(seekHold, c, HoldClear(c))
    /\ UNCHANGED <<serverVars, gen, itemGen, item, task, unwinding, budget,
                   paused, proxy, pendingStops, jellyfinWindow, ownVars>>

\* finalTargetSettleTask wakes after its debounce.  The cooldown answer
\* of the budget (.deferred) only re-arms the same timer and is left out.
SeekSettle(c) ==
    /\ settle[c] # 0
    /\ IF settle[c] # gen[c]
       THEN \* isCurrentPlaybackLifecycle fails: a bare return.
            /\ settle' = Upd(settle, c, 0)
            /\ UNCHANGED <<serverVars, gen, itemGen, item, task, unwinding,
                           seekHold, budget, paused, proxy, pendingStops,
                           jellyfinWindow, life, failed, cur, latch,
                           retryGen, seekDone, resumeGen, resumeDone,
                           playing, wantPause, pendingTarget, startupArmed,
                           rung, abrLeft, autoRun, seekRun, userLeft, starts, breach>>
       ELSE IF failed[c] \/ ~pendingTarget[c]
       THEN \* nothing to rebuild: setSeeking(false)
            /\ settle' = Upd(settle, c, 0)
            /\ seekHold' = Upd(seekHold, c, HoldClear(c))
            /\ UNCHANGED <<serverVars, gen, itemGen, item, task, unwinding,
                           budget, paused, proxy, pendingStops,
                           jellyfinWindow, life, failed, cur, latch,
                           retryGen, seekDone, resumeGen, resumeDone,
                           playing, wantPause, pendingTarget, startupArmed,
                           rung, abrLeft, autoRun, seekRun, userLeft, starts, breach>>
       ELSE IF RebuildActive(c)
       THEN \* .alreadyRebuilding: the target is recorded again and the
            \* running rebuild's tail picks it up.
            /\ settle' = Upd(settle, c, 0)
            /\ UNCHANGED <<serverVars, gen, itemGen, item, task, unwinding,
                           seekHold, budget, paused, proxy, pendingStops,
                           jellyfinWindow, life, failed, cur, latch,
                           retryGen, seekDone, resumeGen, resumeDone,
                           playing, wantPause, pendingTarget, startupArmed,
                           rung, abrLeft, autoRun, seekRun, userLeft, starts, breach>>
       ELSE IF budget[c] = 0 /\ EscalateOnExhaustedBudget
       THEN \* .escalate: surfaceFailure, "Playback keeps falling behind"
            SurfaceFailure(c, FALSE)
       ELSE \* .start: beginStreaming as a final-target rebuild
            /\ RestartCore(c, TRUE)
            /\ budget' = Upd(budget, c,
                   IF budget[c] > 0 THEN budget[c] - 1 ELSE 0)
            /\ seekRun' = Upd(seekRun, c, seekRun[c] + 1)
            /\ pendingTarget' = Upd(pendingTarget, c, FALSE)
            /\ breach' = Upd(breach, c, CancelBreach(c))
            /\ UNCHANGED <<failed, paused, latch, retryGen, startupArmed,
                           rung, abrLeft, autoRun, userLeft>>

-----------------------------------------------------------------------------
(* The task                                                                *)

\* The wait for the prior session's stop ends (acknowledged, failed, or
\* the bounded wait gave up) and the request for the replacement goes out.
\* What an unconfirmed stop does next is the backend's: Plex goes on, Emby
\* fails with priorSessionStopUnconfirmed.
TaskStopWaitDone(c) ==
    /\ task[c] # NoTask
    /\ task[c].pc = "awaitStop"
    /\ StopWaitOver(c, cur[c].sid, cur[c].inc)
    /\ task' = Upd(task, c, [task[c] EXCEPT !.pc = "negotiate"])
    /\ UNCHANGED <<serverVars, gen, itemGen, item, unwinding, seekHold,
                   budget, paused, proxy, pendingStops, jellyfinWindow,
                   ownVars>>

\* The server accepts the start or reopen request, of a current task or
\* of a cancelled one whose request was already on the wire.  The server
\* mints the session id: one it has not used.  Which one makes no
\* difference while ids are never reused, so the model takes a fixed
\* choice instead of every permutation.
FreshIds == {s \in SessionIds : Latest(s) = 0}

NegotiateLands(c, t) ==
    /\ t \in Tasks(c)
    /\ t.pc = "negotiate"
    /\ FreshIds # {}
    /\ LET s == CHOOSE x \in FreshIds : TRUE IN
       /\ StartJob(c, s)
       /\ SetTask(c, t, [t EXCEPT !.pc = "negotiated", !.sid = s,
                                  !.inc = NextIncarnation(s)])
    /\ UNCHANGED <<gen, itemGen, item, seekHold, budget, paused, proxy,
                   pendingStops, jellyfinWindow, ownVars>>

\* The current task's request fails: its catch calls surfaceFailure,
\* which does nothing when playback has already failed.
NegotiateFails(c) ==
    /\ EnvFails
    /\ life[c] = "open"
    /\ task[c] # NoTask
    /\ task[c].pc = "negotiate"
    /\ IF failed[c]
       THEN /\ task' = Upd(task, c, NoTask)
            /\ UNCHANGED <<serverVars, gen, itemGen, item, unwinding,
                           seekHold, budget, paused, proxy, pendingStops,
                           jellyfinWindow, ownVars>>
       ELSE SurfaceFailure(c, TRUE)

\* A cancelled task wakes at a check before it has a session and returns:
\* its request was dropped, or it was still waiting for the prior stop.
TaskUnwindExit(c, t) ==
    /\ t \in unwinding[c]
    /\ t.pc \in {"awaitStop", "negotiate"}
    /\ DropTask(c, t)
    /\ Tail(c, t, failed[c], gen[c])
    /\ UNCHANGED <<serverVars, gen, itemGen, item, budget, paused, proxy,
                   pendingStops, jellyfinWindow, ownRest>>

\* The answer reaches the task.  Current: attach, or begin standing up a
\* proxy.  Cancelled: the result is rejected.
TaskResume(c, t) ==
    /\ t \in Tasks(c)
    /\ t.pc = "negotiated"
    /\ IF IsCurrentTask(c, t)
       THEN \/ Attach(c, t, proxy[c])
            \/ /\ UsesProxy
               /\ SetTask(c, t, [t EXCEPT !.pc = "standUp"])
               /\ UNCHANGED <<serverVars, gen, itemGen, item, seekHold,
                              budget, paused, proxy, pendingStops,
                              jellyfinWindow, ownVars>>
       ELSE IF AttachChecksGeneration
            THEN Reject(c, t, proxy[c], breach[c])
            ELSE Attach(c, t, proxy[c])

\* ProxyStandUp, first half: standUpLoopback returns with the listener
\* bound.  A cancelled task stops it.  A current one installs it at once
\* when the slot is empty, and otherwise awaits oldProxy.stop.
ProxyStandUp(c, t) ==
    /\ t \in Tasks(c)
    /\ t.pc = "standUp"
    /\ LET listening == [proxy[c] EXCEPT !.live = @ \cup {t.gen}] IN
       IF ~IsCurrentTask(c, t)
       THEN /\ SetTask(c, t, [t EXCEPT !.pc = "stopOwnProxy", !.px = t.gen])
            /\ proxy' = Upd(proxy, c, listening)
            /\ UNCHANGED <<serverVars, gen, itemGen, item, seekHold, budget,
                           paused, pendingStops, jellyfinWindow, ownVars>>
       ELSE IF proxy[c].slot = 0
       THEN Attach(c, t, [listening EXCEPT !.slot = t.gen])
       ELSE /\ SetTask(c, t, [t EXCEPT !.pc = "oldProxyStop", !.px = t.gen,
                                       !.old = proxy[c].slot])
            /\ proxy' = Upd(proxy, c, listening)
            /\ UNCHANGED <<serverVars, gen, itemGen, item, seekHold, budget,
                           paused, pendingStops, jellyfinWindow, ownVars>>

\* ProxyStandUp, second half: the task resumes after
\* `await oldProxy.stop(generation:)` and writes remoteHLSProxy with no
\* check in between.  The next check is the caller's, after the write.
ProxyInstall(c, t) ==
    /\ t \in Tasks(c)
    /\ t.pc = "oldProxyStop"
    /\ LET oldGone == [proxy[c] EXCEPT !.live = @ \ {t.old}]
           installed == [oldGone EXCEPT !.slot = t.px]
       IN IF IsCurrentTask(c, t)
          THEN Attach(c, t, installed)
          ELSE IF FixProxyRecheck
          THEN /\ SetTask(c, t, [t EXCEPT !.pc = "stopOwnProxy"])
               /\ proxy' = Upd(proxy, c, oldGone)
               /\ UNCHANGED <<serverVars, gen, itemGen, item, seekHold,
                              budget, paused, pendingStops, jellyfinWindow,
                              ownVars>>
          ELSE \* The late write.  A proxy another task put in the slot
               \* meanwhile loses it, and is marked with the raced one.
               Reject(c, t, installed,
                      breach[c] \cup
                          (IF proxy[c].slot \in {0, t.old} THEN {}
                           ELSE {<<"racedProxy", proxy[c].slot>>}))

\* A cancelled task's own proxy has stopped; its result is rejected.
ProxyOwnStopped(c, t) ==
    /\ t \in unwinding[c]
    /\ t.pc = "stopOwnProxy"
    /\ Reject(c, t, [proxy[c] EXCEPT !.live = @ \ {t.px}], breach[c])

\* A cancelled task at `negotiated` loses its answer: cancelling the task
\* cancelled the URLSession request inside remoteStreamReopener
\* (PlaybackController.swift 5839) after the server had acted on it, the
\* await throws CancellationError, and the catch (5903 to 5907) fails
\* acceptsReopenResult and returns.  stopRejectedRemoteStream is never
\* reached and the client never learns the session.  Only the
\* reopenRemoteStream shape (the startStreaming shape drops a rejected
\* result in Reject already), and only a restart's task: start()'s task
\* (generation 1) is beginRemoteStream, whose session the launcher
\* negotiated before the controller existed.  The session is marked
\* lostAnswer.
NegotiatedLost(c, t) ==
    /\ CancelDropsAnswer
    /\ RejectedResultStopped
    /\ t \in unwinding[c]
    /\ t.gen > 1
    /\ t.pc = "negotiated"
    /\ DropTask(c, t)
    /\ Tail(c, t, failed[c], gen[c])
    /\ breach' = Upd(breach, c, breach[c] \cup {<<"lostAnswer", t.sid>>})
    /\ UNCHANGED <<serverVars, gen, itemGen, item, budget, paused, proxy,
                   pendingStops, jellyfinWindow, ownRejected>>

\* stopRejectedRemoteStream returns and the cancelled task with it.
TaskRejectDone(c, t) ==
    /\ t \in unwinding[c]
    /\ t.pc = "awaitReject"
    /\ StopWaitOver(c, t.sid, t.inc)
    /\ DropTask(c, t)
    /\ Tail(c, t, failed[c], gen[c])
    /\ UNCHANGED <<serverVars, gen, itemGen, item, budget, paused, proxy,
                   pendingStops, jellyfinWindow, ownRest>>

\* A pendingStopTasks entry runs proxy.stop(generation:).
ProxyStopRuns(c, g) ==
    /\ ProxyStopTicket(g) \in pendingStops[c]
    /\ g \in proxy[c].live
    /\ proxy' = Upd(proxy, c, [proxy[c] EXCEPT !.live = @ \ {g}])
    /\ UNCHANGED <<serverVars, gen, itemGen, item, task, unwinding, seekHold,
                   budget, paused, pendingStops, jellyfinWindow, ownVars>>

-----------------------------------------------------------------------------
(* Server                                                                  *)

ServerStep ==
    /\ \/ \E s \in SessionIds : ServerAck(s) \/ ServerFail(s)
       \/ ServerDelay
    /\ UNCHANGED <<ctlVars, ownVars>>

TaskStep(c) ==
    \/ TaskStopWaitDone(c)
    \/ \E t \in Tasks(c) :
          \/ NegotiateLands(c, t)
          \/ TaskUnwindExit(c, t)
          \/ TaskResume(c, t)
          \/ ProxyStandUp(c, t)
          \/ ProxyInstall(c, t)
          \/ ProxyOwnStopped(c, t)
          \/ TaskRejectDone(c, t)
          \/ NegotiatedLost(c, t)

Next ==
    \/ ServerStep
    \/ \E c \in Controllers :
          \/ Start(c) \/ UserQuality(c) \/ UserSeek(c) \/ UserPause(c)
          \/ Retry(c) \/ RetryProceeds(c) \/ RetryBails(c)
          \/ Close(c) \/ CloseDetach(c)
          \/ Fail(c) \/ NegotiateFails(c)
          \/ StallWatchdog(c) \/ StartupDeadline(c) \/ AbrSwitch(c)
          \/ ReadyToPlay(c) \/ SeekSettle(c) \/ SeekHoldCeiling(c)
          \/ \E g \in Gens : SeekComplete(c, g) \/ ResumeSeekComplete(c, g)
          \/ TaskStep(c)
          \/ \E g \in ProxyGens : ProxyStopRuns(c, g)

Spec == Init /\ [][Next]_vars

\* The app's own continuations run when they can, and every stop the
\* client sent gets an answer or fails.  The user, the player's failures
\* and the watchdogs are never forced.
Fairness ==
    /\ \A s \in SessionIds :
          WF_vars((ServerAck(s) \/ ServerFail(s))
                  /\ UNCHANGED <<ctlVars, ownVars>>)
    /\ \A c \in Controllers :
          /\ WF_vars(TaskStep(c))
          /\ WF_vars(RetryProceeds(c))
          /\ WF_vars(RetryBails(c))
          /\ WF_vars(SeekSettle(c))
          /\ WF_vars(SeekHoldCeiling(c))
          /\ WF_vars(CloseDetach(c))
          /\ WF_vars(\E g \in Gens : SeekComplete(c, g))
          /\ WF_vars(\E g \in ProxyGens : ProxyStopRuns(c, g))

FairSpec == Spec /\ Fairness

-----------------------------------------------------------------------------
(* Properties                                                              *)

\* The jobs the server holds that c's requests created.  A judgement.
JobsOf(c) == {j \in Jobs : server[j[1]][j[2]].owner = c}

HeldByTask(c, j) ==
    \E t \in Tasks(c) : t.sid = j[1] /\ t.inc = j[2]

\* j is the session the item plays from: only while playback is open and
\* has not failed.
IsCur(c, j) ==
    /\ cur[c].sid = j[1] /\ cur[c].inc = j[2] /\ ~cur[c].stopped
    /\ life[c] = "open" /\ ~failed[c]

\* A stale replacement never attaches over a newer intent: only the
\* current task attaches, and an attached item has no restart behind it.
GenerationFencing ==
    \A c \in Controllers :
        /\ B("staleAttach") \notin breach[c]
        /\ item[c] = "attached" /\ life[c] = "open" =>
               task[c] = NoTask /\ itemGen[c] = gen[c]

\* The other half of the same rule, which the code does not keep (see
\* Finding-SeekDroppedByAttach): an older replacement's attach does not
\* discard a newer seek target.  A recorded target always has something
\* that will act on it: its settle timer, still current, or a running
\* rebuild whose tail consumes it.
SeekIntentSurvivesAttach ==
    \A c \in Controllers :
        pendingTarget[c] /\ life[c] = "open" /\ ~failed[c] =>
            settle[c] = gen[c] \/ RebuildActive(c)

\* A stale seek completion never releases a newer seek hold.
SeekHoldFencing ==
    \A c \in Controllers : B("staleSeekRelease") \notin breach[c]

\* An exhausted budget stops recovery, and restarts with no user action
\* are bounded.  Both are counts kept beside the code's own counters.
BoundedRestartsNow ==
    \A c \in Controllers :
        /\ seekRun[c] <= RestartBudget
        /\ autoRun[c] <= AutoRestartBound
BoundedRestarts ==
    [][\A c \in Controllers :
           /\ seekRun'[c] <= RestartBudget
           /\ autoRun'[c] <= AutoRestartBound]_vars

\* The player never plays against the user's pause, a resume-seek
\* completion resumes only its own current item, and nothing but the user
\* changes the pause intent.
PauseIntent ==
    \A c \in Controllers :
        /\ wantPause[c] => ~playing[c]
        /\ paused[c] = wantPause[c]
        /\ B("staleResume") \notin breach[c]

\* No stop is on the wire for the session an attached item plays from.
DetachBeforeStop ==
    \A c \in Controllers :
        item[c] = "attached" /\ cur[c] # NoCur =>
            ~SentStopFor(c, cur[c].sid, cur[c].inc)

\* Every listener is the one in the slot or is being stopped, and the
\* slot is empty after Close and while a failure is showing.
\* X is a set of listeners left out of the judgement.
ListenersAccounted(c, X) ==
    \A g \in proxy[c].live \ X :
        \/ g = proxy[c].slot
        \/ ProxyStopTicket(g) \in pendingStops[c]
        \/ \E t \in Tasks(c) :
              \/ t.pc \in {"oldProxyStop", "stopOwnProxy"} /\ t.px = g
              \/ t.pc = "oldProxyStop" /\ t.old = g
NoProxyAfterCleanup(c, X) ==
    life[c] \in {"closing", "closed"} \/ failed[c] =>
        proxy[c].slot \in {0} \cup X

ProxyOwnership ==
    \A c \in Controllers :
        ListenersAccounted(c, {}) /\ NoProxyAfterCleanup(c, {})

\* The proxies the yield race touched: one a task had stood up when it
\* was cancelled while suspended at `await oldProxy.stop`, and one that
\* task's late write then pushed out of the slot.
Raced(c) == {g \in ProxyGens : <<"racedProxy", g>> \in breach[c]}

\* What the code as it stands keeps: the same for every listener but
\* those.  Any other listener is still held to the full property.
ProxyOwnershipOutsideYieldRace ==
    \A c \in Controllers :
        ListenersAccounted(c, Raced(c)) /\ NoProxyAfterCleanup(c, Raced(c))

\* Every session a request of c's created is the one playing, has had a
\* stop sent, or is in the hands of a task that will attach or stop it;
\* and Retry restarts only after pendingStopTasks is joined.
\* L(c) is a set of session ids left out of the judgement.
NoOrphansExcept(L(_)) ==
    \A c \in Controllers :
        /\ \A j \in JobsOf(c) :
              \/ j[1] \in L(c)
              \/ SentStopFor(c, j[1], j[2])
              \/ HeldByTask(c, j)
              \/ IsCur(c, j)
        /\ B("retryBeforeJoin") \notin breach[c]

NoOrphans == NoOrphansExcept(LAMBDA c : {})

\* The sessions whose answer a cancelled task lost (NegotiatedLost).
LostAnswer(c) == {s \in SessionIds : <<"lostAnswer", s>> \in breach[c]}

\* What the code as it stands keeps: the same for every session but one
\* whose answer was lost to cancellation (Finding-CancelledReopenLosesAnswer).
\* Every other session in the same behaviour is still held to it.
NoOrphansOutsideLostAnswer == NoOrphansExcept(LostAnswer)

\* A task that can still reach the server: its request may yet create a
\* job, or it has a job or a listener to dispose of.
ReachesServer(t) == t.pc # "awaitStop"

\* Once waitForPendingStopRequests would return after Close, or after a
\* surfaced failure with no restart under way, nothing of this playback
\* is left to happen on the server.  The code does not keep this (see
\* Finding-StopNoJoin).  The consequent asks that a stop was sent, not
\* that it was answered: the prior session's stop of a restart is not
\* ticketed, and a late one may still be on the wire (see the README).
JoinCoversCleanup ==
    \A c \in Controllers :
        /\ life[c] = "closed" \/ (failed[c] /\ task[c] = NoTask)
        /\ PendingStopsJoined(c)
        => /\ \A t \in unwinding[c] : ~ReachesServer(t)
           /\ \A j \in JobsOf(c) : SentStopFor(c, j[1], j[2])

-----------------------------------------------------------------------------
(* Liveness, under FairSpec                                                *)

\* After Close every task returns, the joined cleanup finishes, every
\* session has had a stop sent and no listener but those in X is left.
CleanedUp(c, X) ==
    /\ unwinding[c] = {}
    /\ PendingStopsJoined(c)
    /\ \A j \in JobsOf(c) : SentStopFor(c, j[1], j[2])
    /\ proxy[c].live \subseteq X

\* The code does not keep this with proxies (suspect 1; see
\* Finding-ProxyAfterCleanup-Liveness).
CloseCleansUp ==
    \A c \in Controllers : life[c] = "closed" ~> CleanedUp(c, {})

\* What the code keeps: the same but for a proxy raced at the yield.
CloseCleansUpOutsideYieldRace ==
    \A c \in Controllers : life[c] = "closed" ~> CleanedUp(c, Raced(c))

\* CloseCleansUpOutsideYieldRace and AbandonedSessionStopped scoped for
\* CancelDropsAnswer = TRUE: a session in LostAnswer(c) is excused (nobody
\* holds its id to stop it; Finding-CancelledReopenLosesAnswer), every other
\* session is held to the full property.
CleanedUpL(c, X) ==
    /\ unwinding[c] = {}
    /\ PendingStopsJoined(c)
    /\ \A j \in JobsOf(c) : SentStopFor(c, j[1], j[2]) \/ j[1] \in LostAnswer(c)
    /\ proxy[c].live \subseteq X
CloseCleansUpOutsideRaceAndLost ==
    \A c \in Controllers : life[c] = "closed" ~> CleanedUpL(c, Raced(c))
AbandonedSessionStoppedOutsideLost ==
    \A c \in Controllers :
        []<>(\A j \in JobsOf(c) : SentStopFor(c, j[1], j[2]) \/ IsCur(c, j) \/ j[1] \in LostAnswer(c))

\* A session that is not the one playing gets a stop.
AbandonedSessionStopped ==
    \A c \in Controllers :
        []<>(\A j \in JobsOf(c) : SentStopFor(c, j[1], j[2]) \/ IsCur(c, j))

\* Retry's wait for the previous attempt's cleanup ends, and the task
\* with it, so that Retry can be tapped again.  The code does not keep
\* this (see Finding-RetryWedgedByAttach).
RetryRuns ==
    \A c \in Controllers : retryGen[c] # 0 ~> retryGen[c] = 0

\* What the code keeps: the wait of a retry task that is still current
\* ends.
RetryJoinEnds ==
    \A c \in Controllers :
        retryGen[c] # 0 /\ retryGen[c] = gen[c]
            ~> retryGen[c] = 0 \/ retryGen[c] # gen[c]

\* The scrubber is never held for ever.  This holds by construction:
\* SeekHoldCeiling is enabled whenever the hold is, under weak fairness.
\* It is kept as a check of the model, not of the code.
SeekHoldReleased ==
    \A c \in Controllers : seekHold[c].held ~> ~seekHold[c].held

-----------------------------------------------------------------------------
(* Witnesses.  Each is the negation of a state one branch of the model     *)
(* reaches, so each is violated when checked as an invariant.  No config   *)
(* lists them; the README says how to repeat the check.                    *)

NeverTwoUnwinding == \A c \in Controllers : Cardinality(unwinding[c]) < 2
NeverYieldRace == \A c \in Controllers : B("yieldRace") \notin breach[c]
NeverRejectWait ==
    \A c \in Controllers : \A t \in unwinding[c] : t.pc # "awaitReject"
NeverOwnProxyStopped ==
    \A c \in Controllers : \A t \in unwinding[c] : t.pc # "stopOwnProxy"
\* The bounded wait for the prior stop gave up and the task went on.
NeverLateStopPassed ==
    \A c \in Controllers :
        ~(/\ task[c] # NoTask /\ task[c].pc = "negotiate"
          /\ \E r \in stopReqs : r.c = c /\ r.status = "inFlight" /\ r.late)
NeverRetryWaits ==
    \A c \in Controllers : ~(retryGen[c] # 0 /\ ~PendingStopsJoined(c))
NeverRestartFromFailure ==
    \A c \in Controllers : ~(failed[c] /\ task[c] # NoTask)
NeverStaleSettle ==
    \A c \in Controllers : settle[c] = 0 \/ settle[c] = gen[c]
\* .alreadyRebuilding left a target for the running rebuild's tail.
NeverAlreadyRebuilding ==
    \A c \in Controllers :
        ~(RebuildActive(c) /\ pendingTarget[c] /\ settle[c] = 0)
\* The tail re-armed the settle timer under the generation after load().
NeverTailRearms ==
    \A c \in Controllers :
        ~(item[c] = "attached" /\ pendingTarget[c] /\ settle[c] = gen[c])
\* The next settle can only escalate.
NeverBudgetExhausted ==
    \A c \in Controllers :
        ~(/\ budget[c] = 0 /\ pendingTarget[c] /\ settle[c] = gen[c]
          /\ ~RebuildActive(c))
NeverResumeFenced ==
    \A c \in Controllers : \A g \in resumeDone[c] : g = gen[c]
NeverSeekFenced ==
    \A c \in Controllers :
        \A g \in seekDone[c] : seekHold[c].held => g = seekHold[c].gen

-----------------------------------------------------------------------------
(* The bound of the model                                                  *)

\* Close's guard holds in every open state: no behaviour reaches an open
\* controller that the generation bound forbids to close.  Close needs
\* only life = "open" and room for Terminal's bump.
CloseStaysEnabled ==
    \A c \in Controllers : life[c] = "open" => gen[c] < MaxGeneration
=============================================================================
