-------------------------- MODULE PlaybackJellyfin --------------------------
\* MODELS: Labstream/Shared/Player/PlaybackController.swift
\* MODELS: PMSKit/Sources/PMSKit/Jellyfin/JellyfinPlayback.swift
\* MODELS: PMSKit/Sources/PMSKit/RemoteStreamLifecyclePolicy.swift
\* MODELS: Labstream/Shared/UI/DetailPlaybackLauncher.swift
\* MODELS: Labstream/Shared/Player/PlaybackSessionSource.swift
\* MODELS: PMSKit/Sources/PMSKit/MediaBrowser/MediaBrowserPlaybackPolicy.swift
\* MODELS: PMSKit/Sources/PMSKit/MediaBrowser/MediaBrowserActiveEncodingStopExecutor.swift
(***************************************************************************)
(* The Jellyfin replacement order.  Every negotiation (a PlaybackInfo      *)
(* request) returns a play-session id the server minted, and the           *)
(* controller holds the stop callbacks of the session it plays.  A reopen  *)
(* (reopenRemoteStream) is, in this order:                                 *)
(*                                                                         *)
(*   1. capture the playing session's stop (priorStop, nil once didStop)   *)
(*      and its id (priorPlaySessionId), cancel the task, detach the old   *)
(*      item.  The old session's callbacks stay installed;                 *)
(*   2. negotiate the replacement;                                         *)
(*   3. attach it, or stop it (stopRejectedRemoteStream) when the reopen   *)
(*      is no longer current or the result needs the user's consent;       *)
(*   4. after an attach, unless the new id equals priorPlaySessionId       *)
(*      (RemoteStreamLifecyclePolicy.priorSessionStopDecision), schedule   *)
(*      priorStop on an unstructured Task that sleeps two seconds and      *)
(*      calls it (scheduleDeferredRemoteSessionStop).  Nothing keeps,      *)
(*      cancels, joins or fences that Task, and the callback itself        *)
(*      sends the request on another Task nobody awaits.                   *)
(*                                                                         *)
(* stop() and surfaceFailure stop the playing session through              *)
(* stopRemoteSessionIfNeeded, whose request is a pendingStopTasks entry.   *)
(*                                                                         *)
(* Each MainActor run between two awaits is one action.                    *)
(*                                                                         *)
(*   User      Reopen (seek, quality or track change, the startup-deadline *)
(*             reopen), Approve, Decline, Retry, Close                     *)
(*   Player    Fail, PlayerNeedsConsent                                    *)
(*   Timers    RetryProceeds, RetryRestops, RetryRestopConfirmed,           *)
(*             RetryRefused (failureRetryTask after                        *)
(*             waitForPendingStopRequests), DeferredFires (the two-second  *)
(*             sleep ends and the prior session's stop goes out)           *)
(*   Task      a playbackTask.  A reopen task is at:                       *)
(*               begin        created, not yet run                         *)
(*               negotiate    its PlaybackInfo request is on the wire      *)
(*               negotiated   the answer is back; it holds a session       *)
(*               consentStop  in requestVideoTranscodeConsent, awaiting    *)
(*                            the playing session's stop                   *)
(*               rejectStop   in stopRejectedRemoteStream                  *)
(*             The first start's task is at begin, then consentStop when   *)
(*             its stream needs consent.  A consent request from           *)
(*             handlePlaybackFailure is a task too: begin, then            *)
(*             consentStop.                                                *)
(*             A cancelled task runs on to its next check.                 *)
(*   Server    NegotiateLands, ServerResolves (a stop is applied or        *)
(*             fails), ServerRecreates (the 2026-09-17 audit's job made    *)
(*             again from an accepted media request), ClockTicks (the      *)
(*             request timeout passes for a stop somebody awaits)          *)
(*                                                                         *)
(* What the restart core (specs/playback/restart) already covers is left   *)
(* out: seeks and their budget, pause intent, the loopback proxy.          *)
(* seekHold, budget, paused and proxy never change here.                   *)
(*                                                                         *)
(* jellyfinWindow is a ghost this module recomputes after every step from  *)
(* the state the step left (Next): a server step can close it.             *)
(***************************************************************************)
EXTENDS PlaybackControllerOps, TLC

CONSTANTS
    \* Bound.
    MaxUserActions,   \* reopens, approvals and Retry taps

    \* What the run includes.
    EnvFails,         \* the player or a negotiation may fail
    RestartFromFailure,
        \* the user changes quality or track while a failure shows
    ConsentPossible,  \* a stream may need the user's consent to encode
    StopsCanFail,     \* a stop may end unacknowledged
    StopsCanBeLate,   \* a stop may go unanswered past the request timeout
    QuickReopen,
        \* a reopen may start while the replace-then-clean-up window is
        \* open: within about two seconds of the last replacement, or
        \* before its stops are answered
    QuickRetry,
        \* the same for a Retry tap

    \* What the server does.  Not established for Jellyfin; see the README.
    IdReuse,
        \* which play-session id a negotiation may return: "never" (one
        \* it has not used), "latest" (also the one it minted last, for
        \* this device), "stopped" (also a used one with no job running
        \* under it), "live" (any)
    ReusedIdReplacesJob,
        \* a negotiation that returns an id with a job running under it
        \* ends that job: the new one replaces it

    \* Shipping behaviour.  TRUE is the code as it stands.
    SkipsReusedIdStop,   \* 94a9ca4e: no deferred stop when the id came back
    DefersPriorStop,     \* the prior session is stopped after the attach
    RejectedIsStopped,   \* stopRejectedRemoteStream
    ConsentStopsSession, \* requestVideoTranscodeConsent stops the session
    ConsentRejectsNegotiated, \* a result that needs consent is not attached
    CloseStopsSession,   \* stop() calls stopRemoteSessionIfNeeded
    RetryJoinsPendingStops,
    RetryNeedsConfirmedStop,
        \* #539: Retry (or a restart from the error overlay, #530) mints a
        \* replacement only after the failed session's stop was acknowledged.
        \* Otherwise the task re-sends that stop once (joinFailedAttemptStop),
        \* proceeds if the re-send is acknowledged and fails with
        \* priorSessionStopUnconfirmed if not
    FailureRestartJoinsPendingStops,
        \* #530: a quality or track change while a failure shows joins
        \* pendingStopTasks first, as retry() does
    StopTimesOut,        \* an awaited stop request has a timeout

    \* The model's own judgement.
    WindowEndsWithCleanup,
        \* jellyfinWindow closes once the replacement and its cleanup are
        \* over.  FALSE leaves it open for good (Mutant-WindowStaysOpen)

    \* Proposed fixes.  FALSE is the code as it stands.
    FixCloseJoinsTask,
        \* stop() appends every task it or an earlier reopen cancelled to
        \* pendingStopTasks, as surfaceFailure appends the current one
    FixTracksDeferredStop,
        \* the deferred stop is a pendingStopTasks entry that awaits its
        \* request, so stop() and retry() join it
    FixConsentStopFenced
        \* requestVideoTranscodeConsent marks the session stopped before
        \* its await, not after

ASSUME /\ MaxUserActions \in Nat
       /\ MaxGeneration >= 3
       /\ IdReuse \in {"never", "latest", "stopped", "live"}
       /\ \A b \in {EnvFails, RestartFromFailure, ConsentPossible,
                    StopsCanFail, StopsCanBeLate, QuickReopen, QuickRetry,
                    ReusedIdReplacesJob, SkipsReusedIdStop, DefersPriorStop,
                    RejectedIsStopped, ConsentStopsSession,
                    ConsentRejectsNegotiated, CloseStopsSession,
                    RetryJoinsPendingStops, RetryNeedsConfirmedStop,
                    FailureRestartJoinsPendingStops, StopTimesOut,
                    WindowEndsWithCleanup, FixCloseJoinsTask,
                    FixTracksDeferredStop, FixConsentStopFenced} :
              b \in BOOLEAN

VARIABLES
    st,        \* in memory, per controller: what PlaybackController holds
    deferred,  \* per controller: prior-session stops sleeping on their Task.
               \* The Task captures only the callback, so it outlives the
               \* controller.
    wire,      \* remote: PlaybackInfo requests sent and not yet acted on
    minted,    \* remote: the id the server minted last (one device)
    ghost,     \* per controller: bookkeeping for the properties
    harm       \* ghost: jobs a stale stop ended while the client still
               \* wanted them.  No client action reads either ghost.

ownVars == <<st, deferred, wire, minted, ghost, harm>>
\* Controller state the actions set.  jellyfinWindow is set by Next.
ctlRest == <<gen, itemGen, item, task, unwinding, seekHold, budget, paused,
             proxy, pendingStops>>
\* Controller state this module never changes.
idleVars == <<seekHold, budget, paused, proxy>>
vars == <<serverVars, ctlVars, ownVars>>

-----------------------------------------------------------------------------
(* Vocabulary                                                              *)

\* No job.
NoJ == <<NoSession, 0>>
JobRefs == Jobs \cup {NoJ}

\* A stop request the controller awaits: the job it means and its number.
NoRq == [sid |-> NoSession, gen |-> 0, n |-> 0]
RqOf(r) == [sid |-> r.sid, gen |-> r.gen, n |-> r.n]

TaskKinds == {"initial", "reopen", "consent"}
TaskPcs == {"begin", "negotiate", "negotiated", "consentStop", "rejectStop"}

\* A playbackTask.  `gen` is the generation it captured; `sid` and `inc`
\* the session its negotiation returned; `prior` the job whose stop it
\* captured (priorStop, NoJ for nil); `psid` the id it captured
\* (priorPlaySessionId); `rq` the stop request it awaits.
JTask(g, kind, prior, psid) ==
    [gen |-> g, pc |-> "begin", sid |-> NoSession, inc |-> 0, kind |-> kind,
     prior |-> prior, psid |-> psid, rq |-> NoRq]

IsJTask(t) ==
    /\ DOMAIN t = {"gen", "pc", "sid", "inc", "kind", "prior", "psid", "rq"}
    /\ t.gen \in 1..MaxGeneration
    /\ t.pc \in TaskPcs
    /\ t.sid \in SessionIds \cup {NoSession}
    /\ t.inc \in Gens
    /\ t.kind \in TaskKinds
    /\ t.prior \in JobRefs
    /\ t.psid \in SessionIds \cup {NoSession}
    /\ t.rq.sid \in SessionIds \cup {NoSession} /\ t.rq.gen \in Gens
    /\ t.rq.n \in Nat

\* st[c].
\*   cur       the session whose callbacks are installed (the
\*             MediaBrowserPlaybackSession's onStop and playSessionID)
\*   didStop   its stop was handed over (session.didStop)
\*   consent   videoTranscodeConsent.generation, 0 for nil
\*   retryGen  the generation failureRetryTask captured, 0 for nil
\*   retryKind what that task reopens with: "retry" (retry()) or
\*             "restart" (a quality or track change while a failure
\*             shows, FailureRestartJoinsPendingStops)
\*   approved  videoTranscodeApprovedForCurrentItem
\*   failStop  the current failure's tracked stop request, NoRq once it is
\*             confirmed or when the failure sent none (#539)
\*   restop    the stop a Retry tap re-sent and awaits, NoRq for none
RqRecs == [sid : SessionIds \cup {NoSession}, gen : Gens, n : Nat]
StRecords ==
    [life : {"new", "open", "closed"}, failed : BOOLEAN, retryGen : Gens,
     retryKind : {"retry", "restart"}, consent : Gens, cur : JobRefs, didStop : BOOLEAN,
     userLeft : 0..MaxUserActions, approved : BOOLEAN,
     failStop : RqRecs, restop : RqRecs]

\* ghost[c].
\*   rejected  sessions stopRejectedRemoteStream was given
\*   skipped   a deferred stop was skipped for a reused id
\*   fired     prior sessions whose deferred stop has gone out
IsGhost(g) ==
    /\ DOMAIN g = {"rejected", "skipped", "fired"}
    /\ g.fired \subseteq Jobs
    /\ g.rejected \subseteq Jobs
    /\ g.skipped \in BOOLEAN

TypeOK ==
    /\ BaseTypeOK
    /\ st \in [Controllers -> StRecords]
    /\ deferred \in [Controllers -> SUBSET Jobs]
    /\ wire \in [Controllers -> SUBSET (1..MaxGeneration)]
    /\ minted \in SessionIds \cup {NoSession}
    /\ harm \subseteq Jobs
    /\ DOMAIN ghost = Controllers
    /\ \A c \in Controllers :
          /\ IsGhost(ghost[c])
          /\ task[c] = NoTask \/ IsJTask(task[c])
          /\ \A t \in unwinding[c] : IsJTask(t)

Init ==
    /\ ServerInit
    /\ ControllerInit(0)
    /\ st = [c \in Controllers |->
                [life |-> "new", failed |-> FALSE, retryGen |-> 0,
                 retryKind |-> "retry", consent |-> 0, cur |-> NoJ, didStop |-> FALSE,
                 userLeft |-> MaxUserActions, approved |-> FALSE,
                 failStop |-> NoRq, restop |-> NoRq]]
    /\ deferred = [c \in Controllers |-> {}]
    /\ wire = [c \in Controllers |-> {}]
    /\ minted = NoSession
    /\ ghost = [c \in Controllers |-> [rejected |-> {}, skipped |-> FALSE,
                                         fired |-> {}]]
    /\ harm = {}

-----------------------------------------------------------------------------
(* Reading the controller                                                  *)

\* The next four are PlaybackEmby's.  That module cannot be instantiated
\* here without its own twenty constants and four variables, and the
\* base has no home for them yet (see the README).
Detached(c) == IF item[c] = "attached" THEN "detached" ELSE item[c]

Running(c) == (IF task[c] = NoTask THEN {} ELSE {task[c]}) \cup unwinding[c]

EndTask(c, t) ==
    IF t = task[c]
    THEN task' = Upd(task, c, NoTask) /\ UNCHANGED unwinding
    ELSE /\ unwinding' = Upd(unwinding, c, unwinding[c] \ {t})
         /\ UNCHANGED task

SetTask(c, t, u) ==
    IF t = task[c]
    THEN task' = Upd(task, c, u) /\ UNCHANGED unwinding
    ELSE /\ unwinding' = Upd(unwinding, c, (unwinding[c] \ {t}) \cup {u})
         /\ UNCHANGED task

\* RemoteStreamLifecyclePolicy.acceptsReopenResult, and the
\* `guard !Task.isCancelled, generation == playbackGeneration` checks: the
\* task is not cancelled and its generation is current.  Every action that
\* bumps the generation moves the task out of the slot.
Accepts(c, t) == t = task[c]

\* The awaited request rq of c's has an answer, or passed its timeout.
\* A request that timed out stays on the wire.
ReqDone(c, rq) ==
    \A r \in StopsFor(c, rq.sid, rq.gen) :
        r.n = rq.n => (r.status # "inFlight" \/ (StopTimesOut /\ r.late))

\* waitForPendingStopRequests would return now.  A stop entry ends when
\* its request does or times out (the base's TicketDone has no timeout).
Joined(c) ==
    /\ \A k \in pendingStops[c] :
          IF k.kind = "serverStop" THEN ReqDone(c, k) ELSE TicketDone(c, k)
    /\ FixTracksDeferredStop => deferred[c] = {}

\* failedAttemptStopUnconfirmed is set: onStopAcknowledged returned false
\* for the current failure's stop.  It does when the request failed, and
\* when it timed out (`late`), whatever the server does with it later.  A
\* request still inside its timeout has not returned yet.  surfaceFailure
\* resets it (failStop is the new failure's stop, or NoRq), and an
\* acknowledged re-send clears it (failStop becomes NoRq).
Unconfirmed(c, rq) ==
    /\ rq # NoRq
    /\ \E r \in StopsFor(c, rq.sid, rq.gen) :
          r.n = rq.n /\ (r.status = "failed" \/ r.late)
StopUnconfirmed(c) == Unconfirmed(c, st[c].failStop)

\* jellyfinWindow, the base's replace-then-clean-up window: from the
\* replacement request to the end of the prior session's deferred
\* cleanup.  Open while a reopen task runs, a deferred stop sleeps, or the
\* stop of a prior session whose deferred stop went out, or of a rejected
\* result, is unanswered.  The rejected results are part of the same
\* cleanup: Close during a reopen leaves the prior's and the rejected
\* result's stops both in flight.
WindowCause(c) ==
    \/ \E t \in Running(c) : t.kind = "reopen"
    \/ deferred[c] # {}
    \/ \E r \in stopReqs :
          /\ r.c = c /\ r.status = "inFlight"
          /\ <<r.sid, r.gen>> \in ghost[c].fired \cup ghost[c].rejected

\* Cleanup of c's still under way on the user's clock: a reopen task
\* runs, a deferred stop sleeps (the two seconds), a stop c sent is
\* unanswered and still inside its request timeout, or a task still
\* awaits a stop.  A stop past its timeout does not count: the client
\* has stopped waiting for it, and so does the user, who may tap Retry or
\* change quality at any later time.  Only the user-timing constants
\* read it.
CleanupUnderway(c) ==
    \/ \E t \in Running(c) : t.kind = "reopen"
    \/ deferred[c] # {}
    \/ \E r \in stopReqs : r.c = c /\ r.status = "inFlight" /\ ~r.late
    \/ \E t \in Running(c) : t.pc \in {"consentStop", "rejectStop"}

\* The user starts another replacement while cleanup is under way: within
\* about two seconds of the last replacement, or before the stops it
\* caused are answered or time out and the tasks awaiting them have run
\* on.
Replacing(c) == CleanupUnderway(c)

\* The ids a negotiation may return now.  This is the server choosing the
\* id it mints, not a client guard.  Ids it has never used are
\* interchangeable, so one stands for all of them.
Mintable ==
    LET room == {s \in SessionIds : Latest(s) < MaxGeneration}
        fresh == {s \in room : Latest(s) = 0}
        used == room \ fresh
    IN (IF fresh = {} THEN {} ELSE {CHOOSE s \in fresh : TRUE})
       \cup (CASE IdReuse = "never" -> {}
               [] IdReuse = "latest" -> used \cap {minted}
               [] IdReuse = "stopped" -> {s \in used : LiveUnder(s) = {}}
               [] OTHER -> used)

\* The server accepts a negotiation under s.  With ReusedIdReplacesJob a
\* job still running under s ends as the new one starts; that is the
\* server's doing, so no stop is marked as having ended it.  The base's
\* StartJob never replaces, so this repeats its body (contract, 7).
StartJobReplacing(c, s) ==
    LET k == NextIncarnation(s)
        ended == [server EXCEPT ![s] = [g \in Incarnations |->
                     IF server[s][g].state \in LiveStates
                     THEN [server[s][g] EXCEPT !.state = "stopped"]
                     ELSE server[s][g]]]
    IN
    /\ Latest(s) < MaxGeneration
    /\ IdsNeverShared => IdOwner(s) \in {NoController, c}
    /\ server' = Settled(
           [ended EXCEPT ![s][k] =
               [state |-> "encoding", owner |-> c, gen |-> k,
                serverRecreated |-> FALSE, endedBy |-> 0]],
           stopReqs)
    /\ UNCHANGED stopReqs

Mint(c, s) ==
    /\ IF ReusedIdReplacesJob THEN StartJobReplacing(c, s) ELSE StartJob(c, s)
    /\ minted' = s

\* Send the stop for job j and return the request handle.
SendJ(c, j) == SendStopFor(c, j[1], j[2])
RqFor(c, j) == RqOf(NextStopReq(c, j[1], j[2]))

-----------------------------------------------------------------------------
(* Pieces shared by several actions                                        *)

\* reopenRemoteStream, its synchronous part: capture priorStop and
\* priorPlaySessionId, cancel the task, bump the generation, detach, and
\* create the task.  The old session's callbacks stay installed and
\* didStop is not set.  `next` is st with the caller's own changes.
ReopenCore(c, next) ==
    LET g == gen[c] + 1
        prior == IF st[c].didStop THEN NoJ ELSE st[c].cur
        psid == st[c].cur[1]
    IN
    /\ gen[c] + 2 <= MaxGeneration
    /\ gen' = Upd(gen, c, g)
    /\ unwinding' = Upd(unwinding, c, UnwindingAfterCancel(c))
    /\ task' = Upd(task, c, JTask(g, "reopen", prior, psid))
    /\ wire' = Upd(wire, c, {})
    /\ item' = Upd(item, c, Detached(c))
    /\ st' = next
    /\ UNCHANGED <<serverVars, itemGen, pendingStops, idleVars, deferred,
                   minted, ghost, harm>>

\* stopRemoteSessionIfNeeded for Jellyfin sends the playing session's
\* onStopAndWait, once, as a pendingStopTasks entry: TRUE when it does
\* (`on` is the caller's own switch).
StopsNow(c, on) == on /\ st[c].cur # NoJ /\ ~st[c].didStop

\* surfaceFailure, past its `guard !playbackError.isFailed`.  `tin` is the
\* task that raises it and then returns, NoTask when the player or the
\* user does.  It joins the task it cancels.
SurfaceFailure(c, tin, next) ==
    LET cur == task[c]
        external == cur # NoTask /\ cur # tin
        stops == StopsNow(c, TRUE)
    IN
    /\ gen[c] < MaxGeneration
    /\ gen' = Upd(gen, c, gen[c] + 1)
    /\ unwinding' =
           IF external THEN Upd(unwinding, c, unwinding[c] \cup {cur})
           ELSE unwinding
    /\ task' = Upd(task, c, NoTask)
    /\ wire' = Upd(wire, c, {})
    /\ item' = Upd(item, c, Detached(c))
    /\ pendingStops' = Upd(pendingStops, c,
           pendingStops[c]
           \cup (IF external THEN {TaskJoinTicket(cur.gen)} ELSE {})
           \cup (IF stops
                 THEN {ServerStopTicket(NextStopReq(c, st[c].cur[1],
                                                    st[c].cur[2]))}
                 ELSE {}))
    /\ st' = [next EXCEPT ![c].failed = TRUE,
                          ![c].didStop = IF stops THEN TRUE ELSE @,
                          ![c].failStop =
                              IF stops
                              THEN RqOf(NextStopReq(c, st[c].cur[1],
                                                    st[c].cur[2]))
                              ELSE NoRq]
    /\ IF stops THEN SendJ(c, st[c].cur) ELSE UNCHANGED serverVars
    /\ UNCHANGED <<itemGen, idleVars, deferred, minted, ghost, harm>>

\* load(): a new generation and the item attached.
AttachCore(c) ==
    /\ gen[c] < MaxGeneration
    /\ gen' = Upd(gen, c, gen[c] + 1)
    /\ itemGen' = Upd(itemGen, c, gen[c] + 1)
    /\ item' = Upd(item, c, "attached")
    /\ task' = Upd(task, c, NoTask)
    /\ UNCHANGED <<unwinding, pendingStops, idleVars>>

\* stopRejectedRemoteStream for Jellyfin: stopAndWaitIgnoringCancellation,
\* cancelled or not.  The task awaits the request.
RejectHeld(c, t, u) ==
    LET j == <<t.sid, t.inc>> IN
    /\ IF RejectedIsStopped
       THEN /\ SetTask(c, t, [u EXCEPT !.pc = "rejectStop",
                                       !.rq = RqFor(c, j)])
            /\ SendJ(c, j)
       ELSE /\ EndTask(c, t)
            /\ UNCHANGED serverVars
    /\ ghost' = [ghost EXCEPT ![c].rejected = @ \cup {j}]

-----------------------------------------------------------------------------
(* User, player and timers                                                 *)

\* start().  DetailPlaybackLauncher negotiated the first session before
\* the controller existed, so its job runs and its callbacks are
\* installed; beginRemoteStream creates the task that prepares and loads
\* it.
Start(c) ==
    /\ st[c].life = "new"
    /\ \E s \in Mintable :
          /\ Mint(c, s)
          /\ st' = [st EXCEPT ![c].life = "open",
                              ![c].cur = <<s, NextIncarnation(s)>>]
    /\ gen' = Upd(gen, c, 1)
    /\ task' = Upd(task, c, JTask(1, "initial", NoJ, NoSession))
    /\ UNCHANGED <<itemGen, item, unwinding, pendingStops, idleVars,
                   deferred, wire, ghost, harm>>

\* A settled seek outside the buffer, reload(bitrateKbps:), an audio or
\* subtitle change, or the MediaBrowser branch of
\* attemptStartupDeadlineRetry, each ending in reopenRemoteStream.  Not
\* taken while a consent choice shows: Approve is the reopen from there.
\* restartAtCurrentPosition clears failureRetryTask.  reload also clears
\* videoTranscodeApprovedForCurrentItem; a seek or a track change keeps it
\* (`isReload` picks which one the step is).  While a failure shows (only
\* a quality or track change: a seek reopens natively then, and the
\* startup-deadline retry's observers are gone), FailureRestartJoinsPendingStops
\* (#530) makes the reopen a failureRetryTask that joins pendingStopTasks
\* first (RetryProceeds); without it the reopen begins at once.
Reopen(c) ==
    /\ st[c].life = "open"
    /\ st[c].userLeft > 0
    /\ st[c].consent = 0
    /\ st[c].failed => RestartFromFailure
    /\ QuickReopen \/ ~Replacing(c)
    /\ \E isReload \in BOOLEAN :
        IF st[c].failed /\ FailureRestartJoinsPendingStops
        THEN /\ st' = [st EXCEPT ![c].userLeft = @ - 1, ![c].retryGen = gen[c],
                                 ![c].retryKind = "restart",
                   ![c].failStop = IF st[c].restop # NoRq THEN st[c].restop ELSE @,
                   ![c].restop = NoRq,
                                 ![c].approved = @ /\ ~isReload]
             /\ UNCHANGED <<serverVars, ctlRest, deferred, wire, minted,
                            ghost, harm>>
        ELSE ReopenCore(c, [st EXCEPT ![c].userLeft = @ - 1, ![c].retryGen = 0,
                                      ![c].restop = NoRq,
                                      ![c].approved = @ /\ ~isReload])

\* approveVideoTranscoding.  The tap is a replacement like Reopen, so the
\* same user-timing assumption gates it.
Approve(c) ==
    /\ st[c].life = "open"
    /\ st[c].consent # 0 /\ st[c].consent = gen[c]
    /\ st[c].userLeft > 0
    /\ QuickReopen \/ ~Replacing(c)
    /\ ReopenCore(c, [st EXCEPT ![c].consent = 0, ![c].userLeft = @ - 1,
                                ![c].retryGen = 0, ![c].approved = TRUE,
                                ![c].restop = NoRq])

\* declineVideoTranscoding.
Decline(c) ==
    /\ st[c].life = "open"
    /\ st[c].consent # 0 /\ st[c].consent = gen[c]
    /\ IF st[c].failed
       THEN /\ st' = [st EXCEPT ![c].consent = 0]
            /\ UNCHANGED <<serverVars, ctlRest, deferred, wire, minted,
                           ghost, harm>>
       ELSE SurfaceFailure(c, NoTask, [st EXCEPT ![c].consent = 0])

\* The failureRetryTask's join: Retry's under RetryJoinsPendingStops, a
\* restart's (#530) always.
TaskJoined(c) ==
    IF st[c].retryKind = "retry" THEN RetryJoinsPendingStops => Joined(c)
    ELSE Joined(c)

\* retry(): failureRetryTask, which first joins pendingStopTasks.
Retry(c) ==
    /\ st[c].life = "open"
    /\ st[c].failed
    /\ QuickRetry \/ ~Replacing(c)
    /\ st[c].retryGen = 0
    /\ st[c].userLeft > 0
    /\ st' = [st EXCEPT ![c].retryGen = gen[c], ![c].retryKind = "retry",
                        ![c].userLeft = @ - 1]
    /\ UNCHANGED <<serverVars, ctlRest, deferred, wire, minted, ghost, harm>>

\* failureRetryTask after the join in joinFailedAttemptStop, the failure's
\* stop confirmed.  A "restart" task (a quality or track change while the
\* failure showed, #530) reopens after clearing the error.  A "restart" task that wakes to another generation takes
\* no step, where the Swift clears the slot; no action bumps the generation
\* during the wait without cancelling the task, so nothing is lost.
RetryProceeds(c) ==
    LET isRetry == st[c].retryKind = "retry" IN
    /\ st[c].retryGen # 0
    /\ st[c].retryGen = gen[c]
    /\ st[c].restop = NoRq
    /\ TaskJoined(c)
    /\ RetryNeedsConfirmedStop => ~StopUnconfirmed(c)
    /\ ReopenCore(c, [st EXCEPT ![c].retryGen = 0,
                                ![c].failed = FALSE])

\* The same task finding failedAttemptStopUnconfirmed set (#539): it re-sends
\* the failed session's stop once (failedAttemptSessionStop, kept after
\* didStop) as a pendingStopTasks entry and awaits it, bounded.  Not while
\* a reopen from the error overlay runs (playbackTask != nil): that is
\* refused.
RetryRestops(c) ==
    LET j == <<st[c].failStop.sid, st[c].failStop.gen>> IN
    /\ RetryNeedsConfirmedStop
    /\ st[c].retryGen # 0
    /\ st[c].retryGen = gen[c]
    /\ st[c].restop = NoRq
    /\ TaskJoined(c)
    /\ StopUnconfirmed(c)
    /\ task[c] = NoTask
    /\ pendingStops' = Upd(pendingStops, c,
           pendingStops[c] \cup {ServerStopTicket(NextStopReq(c, j[1], j[2]))})
    /\ st' = [st EXCEPT ![c].restop = RqFor(c, j)]
    /\ SendJ(c, j)
    /\ UNCHANGED <<gen, itemGen, item, task, unwinding, idleVars, deferred,
                   wire, minted, ghost, harm>>

\* The re-sent stop is acknowledged within its bound and the generation is
\* unchanged: the flag is cleared and the Retry reopens in the same run.
RetryRestopConfirmed(c) ==
    LET rq == st[c].restop IN
    /\ rq # NoRq
    /\ st[c].retryGen # 0
    /\ st[c].retryGen = gen[c]
    /\ \E r \in StopsFor(c, rq.sid, rq.gen) :
          r.n = rq.n /\ r.status = "acked" /\ ~r.late
    /\ ReopenCore(c, [st EXCEPT ![c].retryGen = 0,
                                ![c].failed = FALSE,
                                ![c].failStop = NoRq, ![c].restop = NoRq])

\* The re-sent stop failed or passed its bound: priorSessionStopUnconfirmed,
\* failureRetryTask cleared, so the next tap re-sends again.  Nothing is
\* minted.
RetryRefused(c) ==
    /\ st[c].retryGen # 0
    /\ st[c].retryGen = gen[c]
    /\ \/ Unconfirmed(c, st[c].restop)
       \/ /\ st[c].restop = NoRq
          /\ TaskJoined(c)
          /\ StopUnconfirmed(c)
          /\ task[c] # NoTask
    /\ st' = [st EXCEPT ![c].retryGen = 0, ![c].restop = NoRq]
    /\ UNCHANGED <<serverVars, ctlRest, deferred, wire, minted, ghost, harm>>

\* stop().  It cancels the task and appends nothing for it.  It does not
\* touch a deferred stop.
Close(c) ==
    LET stops == StopsNow(c, CloseStopsSession)
        joins == IF FixCloseJoinsTask
                 THEN {TaskJoinTicket(t.gen) : t \in Running(c)}
                 ELSE {}
    IN
    /\ st[c].life = "open"
    /\ gen[c] < MaxGeneration
    /\ gen' = Upd(gen, c, gen[c] + 1)
    /\ unwinding' = Upd(unwinding, c, UnwindingAfterCancel(c))
    /\ task' = Upd(task, c, NoTask)
    /\ wire' = Upd(wire, c, {})
    /\ item' = Upd(item, c, Detached(c))
    /\ pendingStops' = Upd(pendingStops, c,
           pendingStops[c] \cup joins
           \cup (IF stops
                 THEN {ServerStopTicket(NextStopReq(c, st[c].cur[1],
                                                    st[c].cur[2]))}
                 ELSE {}))
    /\ st' = [st EXCEPT
           ![c].life = "closed", ![c].retryGen = 0, ![c].consent = 0,
           ![c].restop = NoRq,
           ![c].didStop = IF stops THEN TRUE ELSE @]
    /\ IF stops THEN SendJ(c, st[c].cur) ELSE UNCHANGED serverVars
    /\ UNCHANGED <<itemGen, idleVars, deferred, minted, ghost, harm>>

\* The item fails, or a watchdog fires: handlePlaybackFailure and the
\* timeouts that end in surfaceFailure.
Fail(c) ==
    /\ EnvFails
    /\ st[c].life = "open"
    /\ ~st[c].failed
    /\ st[c].consent = 0
    /\ item[c] = "attached" \/ task[c] # NoTask
    /\ SurfaceFailure(c, NoTask, st)

\* The attached item fails on Original quality with no approval yet:
\* handlePlaybackFailure cancels the task, bumps the generation, and
\* starts a task that runs requestVideoTranscodeConsent.  The item stays
\* attached until that task runs.  Not taken while a task runs, nor once
\* the user approved encoding for the item; the Original-quality
\* condition is not modelled (as Emby's).
PlayerNeedsConsent(c) ==
    /\ ConsentPossible
    /\ st[c].life = "open"
    /\ ~st[c].failed
    /\ ~st[c].approved
    /\ st[c].consent = 0
    /\ item[c] = "attached"
    /\ task[c] = NoTask
    /\ gen[c] + 1 < MaxGeneration
    /\ gen' = Upd(gen, c, gen[c] + 1)
    /\ task' = Upd(task, c, JTask(gen[c] + 1, "consent", NoJ, NoSession))
    /\ UNCHANGED <<serverVars, itemGen, item, unwinding, pendingStops,
                   idleVars, ownVars>>

\* The two-second sleep ends and priorStop() runs.  Nothing checks a
\* generation, and the callback's own Task sends the request with nobody
\* awaiting it; it runs whether or not the controller is still open.
DeferredFires(c, j) ==
    /\ j \in deferred[c]
    /\ deferred' = Upd(deferred, c, deferred[c] \ {j})
    /\ SendJ(c, j)
    /\ pendingStops' =
           IF FixTracksDeferredStop
           THEN Upd(pendingStops, c,
                    pendingStops[c]
                    \cup {ServerStopTicket(NextStopReq(c, j[1], j[2]))})
           ELSE pendingStops
    /\ ghost' = [ghost EXCEPT ![c].fired = @ \cup {j}]
    /\ UNCHANGED <<gen, itemGen, item, task, unwinding, idleVars, st, wire,
                   minted, harm>>

-----------------------------------------------------------------------------
(* The reopen task                                                         *)

\* The task runs: `await predecessor?.value` (nil for Jellyfin), the first
\* acceptsReopenResult check, and the PlaybackInfo request.
TaskBegins(c, t) ==
    /\ t.kind = "reopen" /\ t.pc = "begin"
    /\ IF ~Accepts(c, t)
       THEN EndTask(c, t) /\ UNCHANGED wire
       ELSE /\ SetTask(c, t, [t EXCEPT !.pc = "negotiate"])
            /\ wire' = Upd(wire, c, wire[c] \cup {t.gen})
    /\ UNCHANGED <<serverVars, gen, itemGen, item, pendingStops, idleVars,
                   st, deferred, minted, ghost, harm>>

\* The answer reaches a current task and playableRemoteStreamURL returns
\* a URL: the new session's callbacks are installed (didStop = false) and
\* the item loaded.  Then priorSessionStopDecision: skip when the new id
\* is the captured priorPlaySessionId, otherwise schedule priorStop.  The
\* awaits inside playableRemoteStreamURL are folded into this step.
TaskAttaches(c, t) ==
    LET new == <<t.sid, t.inc>>
        same == t.psid = t.sid
        skip == SkipsReusedIdStop /\ same
    IN
    /\ t.kind = "reopen" /\ t.pc = "negotiated"
    /\ Accepts(c, t)
    /\ AttachCore(c)
    /\ st' = [st EXCEPT ![c].cur = new, ![c].didStop = FALSE,
                        ![c].failed = FALSE]
    /\ deferred' =
           IF ~skip /\ DefersPriorStop /\ t.prior # NoJ
           THEN Upd(deferred, c, deferred[c] \cup {t.prior})
           ELSE deferred
    /\ ghost' = [ghost EXCEPT ![c].skipped = @ \/ (skip /\ t.prior # NoJ)]
    /\ UNCHANGED <<serverVars, wire, minted, harm>>

\* The answer reaches a current task and playableRemoteStreamURL calls
\* requestVideoTranscodeConsent: it stops the playing session (its
\* onStopAndWait, awaited) unless didStop, shows the choice, returns nil,
\* and the task rejects the session it negotiated.
TaskNeedsConsent(c, t) ==
    /\ ConsentPossible
    /\ t.kind = "reopen" /\ t.pc = "negotiated"
    /\ Accepts(c, t)
    /\ IF ~ConsentRejectsNegotiated
       THEN /\ AttachCore(c)
            /\ st' = [st EXCEPT ![c].consent = gen[c] + 1,
                                ![c].cur = <<t.sid, t.inc>>,
                                ![c].didStop = FALSE]
            /\ UNCHANGED <<serverVars, ghost>>
       ELSE IF StopsNow(c, ConsentStopsSession)
       THEN /\ SetTask(c, t, [t EXCEPT !.pc = "consentStop",
                                       !.rq = RqFor(c, st[c].cur)])
            /\ SendJ(c, st[c].cur)
            /\ st' = [st EXCEPT ![c].didStop =
                                    IF FixConsentStopFenced THEN TRUE ELSE @]
            /\ UNCHANGED <<gen, itemGen, item, pendingStops, idleVars, ghost>>
       ELSE /\ st' = [st EXCEPT ![c].consent = gen[c]]
            /\ RejectHeld(c, t, t)
            /\ UNCHANGED <<gen, itemGen, item, pendingStops, idleVars>>
    /\ UNCHANGED <<deferred, wire, minted, harm>>

\* The answer reaches a task that is no longer current.
TaskRejects(c, t) ==
    /\ t.kind = "reopen" /\ t.pc = "negotiated"
    /\ ~Accepts(c, t)
    /\ RejectHeld(c, t, t)
    /\ UNCHANGED <<gen, itemGen, item, pendingStops, idleVars, st, deferred,
                   wire, minted, harm>>

\* stopRejectedRemoteStream returns: its request was answered or timed out.
TaskRejectDone(c, t) ==
    /\ t.pc = "rejectStop"
    /\ ReqDone(c, t.rq)
    /\ EndTask(c, t)
    /\ UNCHANGED <<serverVars, gen, itemGen, item, pendingStops, idleVars,
                   ownVars>>

\* A cancelled task's request throws, and its catch returns.
TaskUnwindExit(c, t) ==
    /\ t \in unwinding[c]
    /\ t.pc = "negotiate"
    /\ EndTask(c, t)
    /\ UNCHANGED <<serverVars, gen, itemGen, item, pendingStops, idleVars,
                   ownVars>>

\* The current task's request fails or times out.
NegotiateFails(c) ==
    LET t == task[c] IN
    /\ EnvFails
    /\ t # NoTask /\ t.pc = "negotiate"
    /\ IF st[c].failed
       THEN /\ EndTask(c, t)
            /\ wire' = Upd(wire, c, {})
            /\ UNCHANGED <<serverVars, gen, itemGen, item, pendingStops,
                           idleVars, st, deferred, minted, ghost, harm>>
       ELSE SurfaceFailure(c, t, st)

-----------------------------------------------------------------------------
(* The first start, and the consent request                                *)

\* beginRemoteStream's task: playableRemoteStreamURL returns a URL and the
\* item is loaded, or the task was cancelled and returns.  A consent
\* task that was cancelled before it ran returns at its first guard.
InitialRuns(c, t) ==
    /\ t.kind \in {"initial", "consent"} /\ t.pc = "begin"
    /\ t.kind = "consent" => ~Accepts(c, t)
    /\ IF Accepts(c, t)
       THEN AttachCore(c)
       ELSE EndTask(c, t) /\ UNCHANGED <<gen, itemGen, item, pendingStops,
                                         idleVars>>
    /\ UNCHANGED <<serverVars, ownVars>>

\* The first start's stream needs consent, or the task PlayerNeedsConsent
\* started runs: requestVideoTranscodeConsent detaches and stops the
\* playing session, awaited, unless didStop.
InitialNeedsConsent(c, t) ==
    /\ ConsentPossible
    /\ t.kind \in {"initial", "consent"} /\ t.pc = "begin"
    /\ Accepts(c, t)
    /\ item' = Upd(item, c, Detached(c))
    /\ IF StopsNow(c, ConsentStopsSession)
       THEN /\ SetTask(c, t, [t EXCEPT !.pc = "consentStop",
                                       !.rq = RqFor(c, st[c].cur)])
            /\ SendJ(c, st[c].cur)
            /\ st' = [st EXCEPT ![c].didStop =
                                    IF FixConsentStopFenced THEN TRUE ELSE @]
       ELSE /\ EndTask(c, t)
            /\ st' = [st EXCEPT ![c].consent = gen[c]]
            /\ UNCHANGED serverVars
    /\ UNCHANGED <<gen, itemGen, pendingStops, idleVars, deferred, wire,
                   minted, ghost, harm>>

\* `await stop()` returns.  `session.didStop = true` follows it with no
\* check: the session object is the controller's one
\* MediaBrowserPlaybackSession, whose callbacks a reopen may have replaced
\* meanwhile.  Then the generation check: a current task shows the
\* choice.  A reopen task then rejects the session it negotiated, current
\* or not (playableRemoteStreamURL returned nil).
ConsentStopDone(c, t) ==
    LET shows == Accepts(c, t)
        marked == [st EXCEPT ![c].didStop =
                                IF FixConsentStopFenced THEN @ ELSE TRUE]
        next == IF shows THEN [marked EXCEPT ![c].consent = gen[c]]
                ELSE marked
    IN
    /\ t.pc = "consentStop"
    /\ ReqDone(c, t.rq)
    /\ st' = next
    /\ IF t.kind \in {"initial", "consent"}
       THEN /\ EndTask(c, t)
            /\ UNCHANGED <<serverVars, ghost>>
       ELSE RejectHeld(c, t, t)
    /\ UNCHANGED <<gen, itemGen, item, pendingStops, idleVars, deferred,
                   wire, minted, harm>>

TaskStep(c) ==
    \E t \in Running(c) :
        \/ TaskBegins(c, t) \/ TaskAttaches(c, t) \/ TaskNeedsConsent(c, t)
        \/ TaskRejects(c, t) \/ TaskRejectDone(c, t) \/ TaskUnwindExit(c, t)
        \/ InitialRuns(c, t) \/ InitialNeedsConsent(c, t)
        \/ ConsentStopDone(c, t)

-----------------------------------------------------------------------------
(* The server                                                              *)

\* The server acts on a PlaybackInfo request and returns an id of its
\* choosing.  The base counts the answer as a running job (contract, 7).
\* Only the current task's request is on the wire: cancelling a task
\* cancels its request.
NegotiateLands(c, w) ==
    /\ w \in wire[c]
    /\ task[c] # NoTask /\ task[c].gen = w /\ task[c].pc = "negotiate"
    /\ wire' = Upd(wire, c, wire[c] \ {w})
    /\ \E s \in Mintable :
          /\ Mint(c, s)
          /\ task' = Upd(task, c,
                 [task[c] EXCEPT !.pc = "negotiated", !.sid = s,
                                 !.inc = NextIncarnation(s)])
    /\ UNCHANGED <<gen, itemGen, item, unwinding, pendingStops, idleVars,
                   st, deferred, ghost, harm>>

\* Jobs of s this step ended with a stop meant for an older incarnation,
\* while the client had sent no stop of its own for them and no
\* cancelled task held them for rejection.  A recreated job is the
\* server's, as in Owned.
Harmed(s) ==
    {<<s, g>> : g \in
        {g \in Incarnations :
            LET o == server[s][g].owner IN
            /\ server[s][g].state \in LiveStates
            /\ server'[s][g].state = "stopped"
            /\ server'[s][g].endedBy < g
            /\ RecreateCountsAgainstServer => ~server[s][g].serverRecreated
            /\ ~SentStopFor(o, s, g)
            /\ ~\E t \in unwinding[o] :
                  t.sid = s /\ t.inc = g /\ t.pc = "negotiated"}}

\* A stop is applied, or ends unacknowledged.
ServerResolves(s) ==
    /\ ServerAck(s) \/ (StopsCanFail /\ ServerFail(s))
    /\ harm' = harm \cup Harmed(s)
    /\ UNCHANGED <<ctlRest, st, deferred, wire, minted, ghost>>

\* The 2026-09-17 race: a stopped job made again from a media request the
\* server had already accepted.  Judged against the server.
ServerRecreates(s) ==
    /\ ServerRecreate(s)
    /\ UNCHANGED <<ctlRest, ownVars>>

\* The request timeout passes for a stop somebody awaits: a task, or a
\* pendingStopTasks entry.  A late stop nobody awaits is no different
\* from one on time.
Awaited(c, r) ==
    \/ \E t \in Running(c) :
          t.pc \in {"consentStop", "rejectStop"} /\ t.rq = RqOf(r)
    \/ \E k \in pendingStops[c] :
          k.kind = "serverStop" /\ k.sid = r.sid /\ k.gen = r.gen /\ k.n = r.n
TouchedReq == CHOOSE r \in stopReqs : r \notin stopReqs'
ClockTicks ==
    /\ StopsCanBeLate
    /\ ServerDelay
    /\ Awaited(TouchedReq.c, TouchedReq)
    /\ UNCHANGED <<ctlRest, ownVars>>

\* The current task's own request is answered or fails.
NegotiateResolves(c) ==
    \/ \E w \in wire[c] : NegotiateLands(c, w)
    \/ NegotiateFails(c)

Step ==
    \/ \E s \in SessionIds : ServerResolves(s) \/ ServerRecreates(s)
    \/ ClockTicks
    \/ \E c \in Controllers :
          \/ Start(c) \/ Reopen(c) \/ Approve(c) \/ Decline(c)
          \/ Retry(c) \/ RetryProceeds(c) \/ RetryRestops(c)
          \/ RetryRestopConfirmed(c) \/ RetryRefused(c) \/ Close(c)
          \/ Fail(c)
          \/ PlayerNeedsConsent(c) \/ TaskStep(c) \/ NegotiateResolves(c)
          \/ \E j \in deferred[c] : DeferredFires(c, j)

\* The window after the step, from the state the step left.
SetsWindow ==
    jellyfinWindow' =
        [c \in Controllers |->
            WindowCause(c)' \/ (~WindowEndsWithCleanup /\ jellyfinWindow[c])]

\* An action of the module, with the window recomputed.
W(A) == A /\ SetsWindow

Next == W(Step)

Spec == Init /\ [][Next]_vars

ClientFairness ==
    \A c \in Controllers :
        /\ WF_vars(W(TaskStep(c)))
        /\ WF_vars(W(RetryProceeds(c)))
        /\ WF_vars(W(RetryRestops(c)))
        /\ WF_vars(W(RetryRestopConfirmed(c)))
        /\ WF_vars(W(RetryRefused(c)))
        /\ WF_vars(W(NegotiateResolves(c)))
        /\ WF_vars(W(\E j \in deferred[c] : DeferredFires(c, j)))

\* Every stop is answered or fails.  The user, failures and consent are
\* never forced.
FairSpec ==
    /\ Spec
    /\ ClientFairness
    /\ \A s \in SessionIds : WF_vars(W(ServerResolves(s)))

\* No stop is ever forced to an answer; only the request timeout runs.
ClockFairSpec == Spec /\ ClientFairness /\ WF_vars(W(ClockTicks))

-----------------------------------------------------------------------------
(* Properties                                                              *)

Recreated(j) == server[j[1]][j[2]].serverRecreated

\* A Jellyfin stop is a closure over one negotiated session
\* (DetailPlaybackLauncher.stopActiveEncoding(remote:)), so the
\* incarnation it means is known.  No stop meant for an older job under an
\* id ends a newer one the client still wanted: the base's NoWrongKill,
\* less the jobs the client had itself stopped or was about to reject.
StopNeverKillsSuccessor == harm = {}

\* Every live session a request of c's created is the playing one, held
\* by a task that will attach or stop it, asleep on a deferred stop, or
\* has had a stop sent; and after Close, or while a failure shows with
\* nothing under way, the playing session has had its stop sent.  "Sent"
\* is the design's judgement: a stop that fails counts.
JobsOf(c) ==
    {j \in Jobs : server[j[1]][j[2]].owner = c
                  /\ server[j[1]][j[2]].state \in LiveStates
                  /\ (RecreateCountsAgainstServer => ~Recreated(j))}
HeldByTask(c, j) ==
    \E t \in Running(c) :
        /\ t.kind = "reopen"
        /\ t.pc \in {"negotiated", "consentStop"}
        /\ t.sid = j[1] /\ t.inc = j[2]
NoOrphans ==
    \A c \in Controllers :
        /\ \A j \in JobsOf(c) :
              \/ j = st[c].cur /\ ~st[c].didStop
              \/ HeldByTask(c, j)
              \/ j \in deferred[c]
              \/ SentStopFor(c, j[1], j[2])
        /\ (st[c].life = "closed" \/ (st[c].failed /\ task[c] = NoTask))
           => (st[c].cur = NoJ \/ SentStopFor(c, st[c].cur[1], st[c].cur[2]))

\* While the consent choice shows, nothing is attached, the playing
\* session's stop has been sent and every rejected session's too.
ConsentShowing(c) == st[c].consent # 0 /\ st[c].consent = gen[c]
ConsentBoundary ==
    \A c \in Controllers :
        ConsentShowing(c)
        => /\ item[c] # "attached"
           /\ st[c].cur = NoJ
              \/ SentStopFor(c, st[c].cur[1], st[c].cur[2])
           /\ \A j \in ghost[c].rejected : SentStopFor(c, j[1], j[2])

\* Once waitForPendingStopRequests would return after Close, nothing of
\* this playback is left to happen on the server: no task holds a session
\* to stop, no request is on the wire, no deferred stop sleeps, and every
\* stop sent was answered or timed out.  The code does not keep this.
JoinCoversCleanup ==
    \A c \in Controllers :
        (st[c].life = "closed" /\ Joined(c))
        => /\ \A t \in unwinding[c] :
                 t.pc \notin {"negotiated", "consentStop", "rejectStop"}
           /\ wire[c] = {}
           /\ deferred[c] = {}
           /\ \A r \in stopReqs :
                 r.c = c => (r.status # "inFlight" \/ (StopTimesOut /\ r.late))

\* MaxGeneration bounds no behaviour: no guard on a generation counter is
\* ever the one that disables an action.
GenerationsSuffice == \A c \in Controllers : gen[c] + 2 <= MaxGeneration

\* A request on the wire always has an id the server can return.
IdsSuffice == (\E c \in Controllers : wire[c] # {}) => Mintable # {}

\* OneEncoder in the states where a replacement plays and nothing is under
\* way.  Finding-ThirdEncoder-Attached checks it, so that its trace is the
\* shape where every replacement attached.
OneEncoderWhilePlaying ==
    \A c \in Controllers :
        (item[c] = "attached" /\ Running(c) = {})
        => Cardinality(Owned(c)) <= IF jellyfinWindow[c] THEN 2 ELSE 1

-----------------------------------------------------------------------------
(* Liveness                                                                *)

\* A start, reopen or consent request ends: it attaches, shows the
\* choice, fails or is closed.
ReopenSettles ==
    \A c \in Controllers : task[c] # NoTask ~> task[c] = NoTask

\* After Close every task returns, the joined cleanup ends and every
\* deferred stop has gone out.
CloseCleansUp ==
    \A c \in Controllers :
        st[c].life = "closed"
        ~> (unwinding[c] = {} /\ Joined(c) /\ deferred[c] = {})

\* The replace-then-clean-up window closes.
WindowCloses ==
    \A c \in Controllers : jellyfinWindow[c] ~> ~jellyfinWindow[c]

-----------------------------------------------------------------------------
(* Route constraints.  A Finding config that must show one route to a      *)
(* violation, where a shorter route exists, names one of these as its      *)
(* CONSTRAINT: states past it are not explored.  No other config uses      *)
(* them.                                                                   *)

\* No result is ever rejected, so no rejected session's stop is sent.
NoRejection == \A c \in Controllers : ghost[c].rejected = {}

\* No Retry tap re-sends the failure's stop (#539), so no state after a
\* re-send is explored.  Deep-BackToBack uses it to set aside the route
\* Finding-RetryRestopKillsOtherPlayback shows.
NoRestop == \A c \in Controllers : st[c].restop = NoRq

\* The first start never asks for consent, so a consent request comes from
\* handlePlaybackFailure or a reopen.
NoInitialConsent ==
    \A c \in Controllers :
        ~(task[c] # NoTask /\ task[c].kind = "initial"
          /\ task[c].pc = "consentStop")

-----------------------------------------------------------------------------
(* Witnesses.  Each is the negation of a state one branch of the model     *)
(* reaches, so each is violated when checked as an invariant.  No config   *)
(* lists them; the README says how to repeat the check.                    *)

NeverDeferred == \A c \in Controllers : deferred[c] = {}
NeverDeferredAfterClose ==
    \A c \in Controllers : ~(st[c].life = "closed" /\ deferred[c] # {})
NeverSkipped == \A c \in Controllers : ~ghost[c].skipped
NeverWindowTwo ==
    \A c \in Controllers : ~(jellyfinWindow[c] /\ Cardinality(Owned(c)) = 2)
NeverRejected == \A c \in Controllers : ghost[c].rejected = {}
NeverRecreated == \A j \in Jobs : ~Recreated(j)
NeverReplacedById ==
    \A j \in Jobs :
        ~(server[j[1]][j[2]].state = "stopped"
          /\ server[j[1]][j[2]].endedBy = 0)
NeverReusedId == \A s \in SessionIds : Latest(s) < 2
NeverConsentShown == \A c \in Controllers : ~ConsentShowing(c)
NeverPlayerConsent ==
    \A c \in Controllers : ~(task[c] # NoTask /\ task[c].kind = "consent")
NeverRetryRefused == \A c \in Controllers : ~ENABLED RetryRefused(c)
NeverRetryRestops == \A c \in Controllers : ~ENABLED RetryRestops(c)
NeverRestopConfirmed ==
    \A c \in Controllers : ~ENABLED RetryRestopConfirmed(c)
NeverRetryWaits ==
    \A c \in Controllers : ~(st[c].retryGen # 0 /\ ~Joined(c))
NeverTimedOut ==
    \A r \in stopReqs : ~(r.late /\ r.status = "inFlight")
NeverStopFailed == \A r \in stopReqs : r.status # "failed"
NeverQuickReopen ==
    \A c \in Controllers :
        ~(deferred[c] # {} /\ task[c] # NoTask /\ task[c].kind = "reopen")
\* Two controllers: the second was given an id the first had used.
NeverSharedId == OneOwnerPerId
=============================================================================
