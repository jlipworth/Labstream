---------------------------- MODULE PlaybackEmby ----------------------------
\* MODELS: Labstream/Shared/Player/PlaybackController.swift
\* MODELS: Labstream/Shared/Player/EmbyReopenStopBarrier.swift
\* MODELS: PMSKit/Sources/PMSKit/RemoteStreamLifecyclePolicy.swift
\* MODELS: PMSKit/Sources/PMSKit/Emby/EmbyPlayback.swift
\* MODELS: Labstream/Shared/UI/DetailPlaybackLauncher.swift
\* MODELS: Labstream/Shared/Player/PlaybackSessionSource.swift
\* MODELS: PMSKit/Sources/PMSKit/MediaBrowser/MediaBrowserPlaybackPolicy.swift
\* MODELS: PMSKit/Sources/PMSKit/MediaBrowser/MediaBrowserActiveEncodingStopExecutor.swift
(***************************************************************************)
(* The Emby replacement order.  Every negotiation (a PlaybackInfo request) *)
(* returns a play-session id the server minted, and the controller holds   *)
(* an exact-session stop for the session it plays.  A reopen               *)
(* (reopenRemoteStream) is, in this order:                                 *)
(*                                                                         *)
(*   1. detach the old item;                                               *)
(*   2. hand the old session's stop to EmbyReopenStopBarrier, which sends  *)
(*      it and keeps it until it is acknowledged;                          *)
(*   3. wait for the reopen before this one to return, its cleanup of a    *)
(*      rejected result included (embyReopenTransactionTail);              *)
(*   4. wait for the barrier's ticket.  Unacknowledged, the reopen fails   *)
(*      with priorSessionStopUnconfirmed and negotiates nothing;           *)
(*   5. negotiate the replacement;                                         *)
(*   6. attach it, or stop it through the barrier when the reopen is no    *)
(*      longer current or the result needs the user's consent.             *)
(*                                                                         *)
(* stop() and surfaceFailure hand the session's stop to the same barrier   *)
(* and append its ticket to pendingStopTasks.                              *)
(*                                                                         *)
(* Each MainActor run between two awaits is one action.                    *)
(*                                                                         *)
(*   User      Reopen (seek, quality or track change, and the two          *)
(*             automatic copy reopens), Approve, Decline, Retry, Close     *)
(*   Player    Fail, PlayerNeedsConsent                                    *)
(*   Timers    RetryProceeds (failureRetryTask after                       *)
(*             waitForPendingStopRequests)                                 *)
(*   Task      a playbackTask.  A reopen task is at:                       *)
(*               begin        created; awaiting its predecessor            *)
(*               awaitStop    awaiting the barrier's ticket                *)
(*               negotiate    its PlaybackInfo request is on the wire      *)
(*               negotiated   the answer is back; it holds a session       *)
(*               rejectStop   inside stopRejectedRemoteStream              *)
(*             The first start and a consent request are tasks too:        *)
(*               begin, then consentStop while the old session's stop is   *)
(*               awaited.                                                  *)
(*             A cancelled task runs on to its next check.                 *)
(*   Barrier   BarrierResolves (the barrier's own task hears the answer,   *)
(*             or its request times out)                                   *)
(*   Server    NegotiateLands, ServerResolves (a stop is applied or        *)
(*             fails), ServerRecreatesJob (#421: a stopped job made again  *)
(*             from an accepted media request), ClockTicks (the request    *)
(*             timeout passes for the stop the barrier awaits)             *)
(*                                                                         *)
(* What the restart core (specs/playback/restart) already covers is left   *)
(* out: seeks and their budget, pause intent, the loopback proxy.          *)
(* seekHold, budget, paused, proxy and jellyfinWindow never change here.   *)
(***************************************************************************)
EXTENDS PlaybackControllerOps, TLC

CONSTANTS
    \* Bound.
    MaxUserActions,   \* reopens, approvals and Retry taps

    \* What the run includes.
    EnvFails,         \* the player or a negotiation may fail
    RestartFromFailure,
        \* the user seeks or changes quality or track while a failure shows
    ConsentPossible,  \* a stream may need the user's consent to encode
    StopsCanFail,     \* a stop may end unacknowledged
    StopsCanBeLate,   \* a stop may go unanswered past the request timeout
    ServerRecreates,
        \* the server may make a stopped job again (#421).  TRUE in every
        \* safety config.  A liveness config may take FALSE: the step
        \* changes only `server`, and with IdReuse "never" or "live" no
        \* client step, stop resolution or timeout depends on whether a
        \* stopped job runs again, so it adds states and no behaviour of
        \* the client

    \* What the server does.  Not established for Emby; see the README.
    IdReuse,
        \* which play-session id a negotiation may return: "never" (one
        \* it has not used), "stopped" (also a used one with no job
        \* running under it), "live" (any)
    AbandonedNegotiateCanLand,
        \* a PlaybackInfo request the client cancelled or gave up on may
        \* still be acted on, with nobody to hear the answer

    \* Shipping behaviour.  TRUE is the code as it stands.
    StopsBeforeNegotiate,
        \* the 2026-10-04 correction: the old session's stop goes out, and
        \* is awaited, before the replacement is negotiated.  FALSE is the
        \* order before it: negotiate, attach, then stop the old session.
    WaitsForStopAck,          \* the reopen awaits the barrier's ticket
    BlocksOnUnconfirmedStop,  \* priorSessionStopUnconfirmed (LS-PB-008)
    JoinsPredecessor,         \* embyReopenTransactionTail
    RejectedIsStopped,        \* stopRejectedRemoteStream
    ConsentStopsSession,      \* the consent request stops the old session
    ConsentRequiresAck,       \* and shows the choice only once acknowledged
    ConsentRejectsNegotiated, \* a result that needs consent is not attached
    DetachesBeforeStop,       \* #43: the old item is detached first
    CloseStopsSession,        \* stop() calls stopRemoteSessionIfNeeded
    RetryJoinsPendingStops,
    StopTimesOut,             \* the stop request has a timeout

    \* Proposed fix.  FALSE is the code as it stands.
    FixCloseJoinsTask
        \* stop() appends the cancelled task and the transaction tail to
        \* pendingStopTasks, as surfaceFailure appends the task

ASSUME /\ MaxUserActions \in Nat
       /\ MaxGeneration >= 3
       /\ IdReuse \in {"never", "stopped", "live"}
       /\ \A b \in {EnvFails, RestartFromFailure, ConsentPossible,
                    StopsCanFail, StopsCanBeLate, ServerRecreates,
                    AbandonedNegotiateCanLand,
                    StopsBeforeNegotiate, WaitsForStopAck,
                    BlocksOnUnconfirmedStop, JoinsPredecessor,
                    RejectedIsStopped, ConsentStopsSession,
                    ConsentRequiresAck, ConsentRejectsNegotiated,
                    DetachesBeforeStop, CloseStopsSession,
                    RetryJoinsPendingStops, StopTimesOut,
                    FixCloseJoinsTask} :
              b \in BOOLEAN

VARIABLES
    st,     \* in memory, per controller: what PlaybackController holds
    bar,    \* in memory, per controller: its EmbyReopenStopBarrier
    wire,   \* remote: PlaybackInfo requests sent and not yet acted on
    ghost   \* per controller: bookkeeping for the properties.  No client
            \* action decides anything from it.

ownVars == <<st, bar, wire, ghost>>
\* Controller state this module never changes.
idleVars == <<seekHold, budget, paused, proxy, jellyfinWindow>>
vars == <<serverVars, ctlVars, ownVars>>

-----------------------------------------------------------------------------
(* Vocabulary                                                              *)

\* No job: a session whose stop was handed over (didStop), or none.
NoJ == <<NoSession, 0>>
JobRefs == Jobs \cup {NoJ}

TaskKinds == {"initial", "consent", "reopen"}
TaskPcs == {"begin", "awaitStop", "negotiate", "negotiated", "rejectStop",
            "consentStop"}

\* A playbackTask.  `gen` is the generation it captured; `sid` and `inc`
\* the session its negotiation returned; `pred` the generation of the
\* reopen task it joins first (embyReopenTransactionTail when it was
\* created, 0 for nil); `tk` the barrier ticket it captured or awaits (0
\* for nil).
ETask(g, kind, pred, tk) ==
    [gen |-> g, pc |-> "begin", sid |-> NoSession, inc |-> 0, kind |-> kind,
     pred |-> pred, tk |-> tk]

IsETask(t) ==
    /\ DOMAIN t = {"gen", "pc", "sid", "inc", "kind", "pred", "tk"}
    /\ t.gen \in 1..MaxGeneration
    /\ t.pc \in TaskPcs
    /\ t.sid \in SessionIds \cup {NoSession}
    /\ t.inc \in Gens
    /\ t.kind \in TaskKinds
    /\ t.pred \in Gens
    /\ t.tk \in Nat

\* st[c].
\*   sess      the job the session's stop callbacks would stop: set while
\*             !didStop and onStopAcknowledged is there, NoJ otherwise
\*   consent   videoTranscodeConsent.generation, 0 for nil
\*   retryGen  the generation failureRetryTask captured, 0 for nil
\*   tail      the generation of the task in embyReopenTransactionTail
StRecords ==
    [life : {"new", "open", "closed"}, failed : BOOLEAN, retryGen : Gens,
     consent : Gens, sess : JobRefs, tail : Gens,
     userLeft : 0..MaxUserActions]

\* bar[c], an EmbyReopenStopBarrier.
\*   op         `operation`: the job whose stop it owns, NoJ for nil
\*   n          tickets made so far.  Ticket n is `latestTicket`, and is
\*              `pending` while its result is "pending"
\*   tix[k]     ticket k: the job it stops, the number of its request
\*              among the stops sent for that job, and its result
\*   finalRetry `finalRetryAttempted`
TicketResults == {"pending", "ok", "no"}

IsBar(b) ==
    /\ DOMAIN b = {"op", "n", "tix", "finalRetry"}
    /\ b.op \in JobRefs
    /\ b.n \in Nat
    /\ DOMAIN b.tix = 1..b.n
    /\ \A k \in 1..b.n :
          /\ b.tix[k].job \in Jobs
          /\ b.tix[k].rn \in Nat
          /\ b.tix[k].res \in TicketResults
    /\ b.finalRetry \in BOOLEAN

EmptyBar == [op |-> NoJ, n |-> 0, tix |-> <<>>, finalRetry |-> FALSE]

\* ghost[c].
\*   trap      a `precondition` of EmbyReopenStopBarrier.begin was reached
\*             false: "pending" (a stop was offered while a ticket was in
\*             flight) or "failed" (while a failed ticket kept authority)
\*   rejected  sessions stopRejectedRemoteStream was given
\*   closedAtConsent  Close came while the consent choice was showing
Traps == {"none", "pending", "failed"}

IsGhost(g) ==
    /\ DOMAIN g = {"trap", "rejected", "closedAtConsent"}
    /\ g.trap \in SUBSET (Traps \ {"none"})
    /\ g.rejected \subseteq Jobs
    /\ g.closedAtConsent \in BOOLEAN

TypeOK ==
    /\ BaseTypeOK
    /\ st \in [Controllers -> StRecords]
    /\ DOMAIN bar = Controllers
    /\ wire \in [Controllers -> SUBSET (1..MaxGeneration)]
    /\ DOMAIN ghost = Controllers
    /\ \A c \in Controllers :
          /\ IsBar(bar[c])
          /\ IsGhost(ghost[c])
          /\ task[c] = NoTask \/ IsETask(task[c])
          /\ \A t \in unwinding[c] : IsETask(t)

Init ==
    /\ ServerInit
    /\ ControllerInit(0)
    /\ st = [c \in Controllers |->
                [life |-> "new", failed |-> FALSE, retryGen |-> 0,
                 consent |-> 0, sess |-> NoJ, tail |-> 0,
                 userLeft |-> MaxUserActions]]
    /\ bar = [c \in Controllers |-> EmptyBar]
    /\ wire = [c \in Controllers |-> {}]
    /\ ghost = [c \in Controllers |->
                   [trap |-> {}, rejected |-> {}, closedAtConsent |-> FALSE]]

-----------------------------------------------------------------------------
(* EmbyReopenStopBarrier, as operators on its state                        *)

\* `pending != nil`.
BarPending(b) == b.n > 0 /\ b.tix[b.n].res = "pending"
\* `hasAuthority`.
HasAuthority(b) == b.op # NoJ \/ BarPending(b)
\* `currentTicket`: the pending ticket or, for a failed one that keeps
\* authority, the latest.  Both are ticket n.
CurrentTicket(b) == IF HasAuthority(b) THEN b.n ELSE 0

NoBegin(b, k) == [bar |-> b, send |-> NoJ, trap |-> "none", tk |-> k]

\* begin(stop:) offered `job` (NoJ for a nil stop).  The result is the
\* barrier afterwards, the job whose stop goes on the wire now (NoJ for
\* none), the precondition that was false, and the ticket returned.
\*
\* The barrier's task is created here and the stop request leaves when it
\* first runs.  The model sends it in this step: a request that leaves a
\* little later is one that takes a little longer, and the barrier is
\* `pending` either way.
\*
\* `guard let operation else { return Task { false } }` is not reached:
\* every caller offers a stop or has checked hasAuthority or `operation`.
Begin(c, b, job) ==
    LET busy == BarPending(b)
        takes == ~busy /\ b.op = NoJ /\ job # NoJ
        op == IF takes THEN job ELSE b.op
        runs == ~busy /\ op # NoJ
        k == b.n + 1
    IN [bar |->
            IF runs
            THEN [op |-> op, n |-> k,
                  tix |-> [i \in 1..k |->
                              IF i < k THEN b.tix[i]
                              ELSE [job |-> op,
                                    rn |-> NextStopReq(c, op[1], op[2]).n,
                                    res |-> "pending"]],
                  finalRetry |-> IF takes THEN FALSE ELSE b.finalRetry]
            ELSE b,
        send |-> IF runs THEN op ELSE NoJ,
        trap |-> IF job = NoJ THEN "none"
                 ELSE IF busy THEN "pending"
                 ELSE IF b.op # NoJ THEN "failed"
                 ELSE "none",
        tk |-> IF runs THEN k ELSE IF busy THEN b.n ELSE 0]

\* beginFinalStop: join the ticket in flight, or retry a failed one once.
BeginFinal(c, b) ==
    IF BarPending(b) THEN NoBegin(b, b.n)
    ELSE IF b.op # NoJ /\ ~b.finalRetry
    THEN Begin(c, [b EXCEPT !.finalRetry = TRUE], NoJ)
    ELSE NoBegin(b, 0)

\* stopRemoteSessionIfNeeded for Emby: beginEmbySessionStop hands over the
\* session's stop, then beginFinalStop.  `tk` is the ticket appended to
\* pendingStopTasks.  The policy switch below them finds didStop set and
\* skips.
StopRemote(c) ==
    LET first == IF st[c].sess # NoJ THEN Begin(c, bar[c], st[c].sess)
                 ELSE NoBegin(bar[c], 0)
        fin == BeginFinal(c, first.bar)
    IN [bar |-> fin.bar,
        send |-> IF first.send # NoJ THEN first.send ELSE fin.send,
        trap |-> first.trap, tk |-> fin.tk]

\* What an action does with a result of the three operators above.
ApplyBar(c, r) ==
    /\ bar' = Upd(bar, c, r.bar)
    /\ IF r.send # NoJ THEN SendStopFor(c, r.send[1], r.send[2])
       ELSE UNCHANGED serverVars
Trapped(traps, r) == IF r.trap = "none" THEN traps ELSE traps \cup {r.trap}

\* A pendingStopTasks entry that awaits barrier ticket k.  It is not the
\* base's ServerStopTicket: the entry ends when the ticket does, which
\* for a request that timed out is before the request is answered.
BarTicket(k) == [kind |-> "serverStop", sid |-> NoSession, gen |-> 0, n |-> k]
TkDone(c, k) == bar[c].tix[k].res # "pending"

\* waitForPendingStopRequests would return now.
Joined(c) ==
    \A t \in pendingStops[c] :
        IF t.kind = "serverStop" THEN TkDone(c, t.n) ELSE TicketDone(c, t)

\* The request behind the pending ticket.
PendingReq(c) ==
    LET tx == bar[c].tix[bar[c].n]
    IN CHOOSE r \in StopsFor(c, tx.job[1], tx.job[2]) : r.n = tx.rn

-----------------------------------------------------------------------------
(* Reading the controller                                                  *)

Detached(c) == IF item[c] = "attached" THEN "detached" ELSE item[c]

Running(c) == (IF task[c] = NoTask THEN {} ELSE {task[c]}) \cup unwinding[c]

\* RemoteStreamLifecyclePolicy.acceptsReopenResult, and the
\* `guard !Task.isCancelled, generation == playbackGeneration` of the
\* consent request: the task is not cancelled and its generation is
\* current.  Every action that bumps the generation also moves the task
\* out of the slot, so that is the task in the slot.
Accepts(c, t) == t = task[c]

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

\* The requests still on the wire after the current task is cancelled or
\* its request fails.  Cancelling the task cancels its URLSession request.
WireAfterCancel(c) == IF AbandonedNegotiateCanLand THEN wire[c] ELSE {}

\* The ids a negotiation may return now.  This is the server choosing the
\* id it mints, not a client guard.  Ids it has never used are
\* interchangeable, so one stands for all of them.
Mintable ==
    LET room == {s \in SessionIds : Latest(s) < MaxGeneration}
        fresh == {s \in room : Latest(s) = 0}
        used == room \ fresh
    IN (IF fresh = {} THEN {} ELSE {CHOOSE s \in fresh : TRUE})
       \cup (CASE IdReuse = "never" -> {}
               [] IdReuse = "stopped" -> {s \in used : LiveUnder(s) = {}}
               [] OTHER -> used)

-----------------------------------------------------------------------------
(* Pieces shared by several actions                                        *)

\* reopenRemoteStream, its synchronous part: cancel the task, bump the
\* generation, detach, hand the session's stop to the barrier (or join
\* the authority it already holds), and create the task behind the
\* transaction tail.  `next` is st with the caller's own changes.
\*
\* The legacy branch (a session with no onStopAcknowledged) is left out:
\* DetailPlaybackLauncher builds every Emby session with one.
ReopenCore(c, next) ==
    LET g == gen[c] + 1
        r == IF StopsBeforeNegotiate
                /\ (st[c].sess # NoJ \/ HasAuthority(bar[c]))
             THEN Begin(c, bar[c], st[c].sess)
             ELSE NoBegin(bar[c], 0)
    IN
    /\ gen[c] + 2 <= MaxGeneration
    /\ gen' = Upd(gen, c, g)
    /\ unwinding' = Upd(unwinding, c, UnwindingAfterCancel(c))
    /\ task' = Upd(task, c, ETask(g, "reopen", st[c].tail, r.tk))
    /\ wire' = Upd(wire, c, WireAfterCancel(c))
    /\ item' = Upd(item, c, IF DetachesBeforeStop THEN Detached(c) ELSE item[c])
    /\ st' = [next EXCEPT
           ![c].sess = IF StopsBeforeNegotiate THEN NoJ ELSE @,
           ![c].tail = g]
    /\ ApplyBar(c, r)
    /\ ghost' = [ghost EXCEPT ![c].trap = Trapped(@, r)]
    /\ UNCHANGED <<itemGen, pendingStops, idleVars>>

\* surfaceFailure, past its `guard !playbackError.isFailed`.  `tin` is the
\* task that raises it and then returns, NoTask when the player or the
\* user does.  It joins the task it cancels and does not clear the
\* consent generation.
SurfaceFailure(c, tin, next) ==
    LET cur == task[c]
        external == cur # NoTask /\ cur # tin
        r == StopRemote(c)
    IN
    /\ gen[c] < MaxGeneration
    /\ gen' = Upd(gen, c, gen[c] + 1)
    /\ unwinding' =
           IF external THEN Upd(unwinding, c, unwinding[c] \cup {cur})
           ELSE unwinding
    /\ task' = Upd(task, c, NoTask)
    /\ wire' = Upd(wire, c, WireAfterCancel(c))
    /\ item' = Upd(item, c, Detached(c))
    /\ pendingStops' = Upd(pendingStops, c,
           pendingStops[c]
           \cup (IF external THEN {TaskJoinTicket(cur.gen)} ELSE {})
           \cup (IF r.tk # 0 THEN {BarTicket(r.tk)} ELSE {}))
    /\ st' = [next EXCEPT ![c].failed = TRUE, ![c].sess = NoJ]
    /\ ApplyBar(c, r)
    /\ ghost' = [ghost EXCEPT ![c].trap = Trapped(@, r)]
    /\ UNCHANGED <<itemGen, idleVars>>

\* load(): a new generation, a clean error surface, and the session's
\* stop callbacks installed (didStopRemoteSession = false).
AttachCore(c) ==
    /\ gen[c] < MaxGeneration
    /\ gen' = Upd(gen, c, gen[c] + 1)
    /\ itemGen' = Upd(itemGen, c, gen[c] + 1)
    /\ item' = Upd(item, c, "attached")
    /\ task' = Upd(task, c, NoTask)
    /\ UNCHANGED <<unwinding, pendingStops, idleVars>>

\* The consent choice appears.
ShowsConsent(c, next) == [next EXCEPT ![c].consent = gen[c]]

-----------------------------------------------------------------------------
(* User, player and timers                                                 *)

\* start().  DetailPlaybackLauncher negotiated the first session before
\* the controller existed, so its job runs and its stop callbacks are
\* installed; beginRemoteStream creates the task that prepares and loads
\* it.
Start(c) ==
    /\ st[c].life = "new"
    /\ \E s \in Mintable :
          /\ StartJob(c, s)
          /\ st' = [st EXCEPT ![c].life = "open",
                              ![c].sess = <<s, NextIncarnation(s)>>]
    /\ gen' = Upd(gen, c, 1)
    /\ task' = Upd(task, c, ETask(1, "initial", 0, 0))
    /\ UNCHANGED <<itemGen, item, unwinding, pendingStops, idleVars, bar,
                   wire, ghost>>

\* A settled seek outside the buffer, reload(bitrateKbps:), an audio or
\* subtitle change, or an automatic reopen (attemptEmbyVideoCopyFallback,
\* attemptEmbyCopyReopenRetry, the MediaBrowser branch of
\* attemptStartupDeadlineRetry), each ending in reopenRemoteStream.
\* Nothing in them asks whether a failure is showing, and only explicit
\* Retry and load() clear it.  It is not taken while a consent choice
\* shows: Approve is the reopen from there.
\*
\* restartAtCurrentPosition clears failureRetryTask, so retryGen goes.  A
\* seek's direct reopenRemoteStream leaves it, and the retry task then
\* wakes to another generation, clears failureRetryTask and returns (#526;
\* the restart core's RetryBails).  That step is left out here, so
\* retryGen stays set; it only bounds this model's Retry further.
Reopen(c) ==
    /\ st[c].life = "open"
    /\ st[c].userLeft > 0
    /\ st[c].consent = 0
    /\ st[c].failed => RestartFromFailure
    /\ ReopenCore(c, [st EXCEPT ![c].userLeft = @ - 1, ![c].retryGen = 0])

\* approveVideoTranscoding.
Approve(c) ==
    /\ st[c].life = "open"
    /\ st[c].consent # 0 /\ st[c].consent = gen[c]
    /\ st[c].userLeft > 0
    /\ ReopenCore(c, [st EXCEPT ![c].consent = 0, ![c].userLeft = @ - 1,
                                ![c].retryGen = 0])

\* declineVideoTranscoding.
Decline(c) ==
    /\ st[c].life = "open"
    /\ st[c].consent # 0 /\ st[c].consent = gen[c]
    /\ IF st[c].failed
       THEN /\ st' = [st EXCEPT ![c].consent = 0]
            /\ UNCHANGED <<serverVars, ctlVars, bar, wire, ghost>>
       ELSE SurfaceFailure(c, NoTask, [st EXCEPT ![c].consent = 0])

\* retry(): failureRetryTask, which first joins pendingStopTasks.
Retry(c) ==
    /\ st[c].life = "open"
    /\ st[c].failed
    /\ st[c].retryGen = 0
    /\ st[c].userLeft > 0
    /\ st' = [st EXCEPT ![c].retryGen = gen[c], ![c].userLeft = @ - 1]
    /\ UNCHANGED <<serverVars, ctlVars, bar, wire, ghost>>

\* failureRetryTask after `await waitForPendingStopRequests()`.
RetryProceeds(c) ==
    /\ st[c].retryGen # 0
    /\ st[c].retryGen = gen[c]
    /\ RetryJoinsPendingStops => Joined(c)
    /\ ReopenCore(c, [st EXCEPT ![c].retryGen = 0, ![c].failed = FALSE])

\* stop().  It cancels the task and appends nothing for it.
Close(c) ==
    LET cur == task[c]
        r == IF CloseStopsSession THEN StopRemote(c) ELSE NoBegin(bar[c], 0)
        joins == IF FixCloseJoinsTask
                 THEN {TaskJoinTicket(g) :
                          g \in ({st[c].tail} \cup
                                 (IF cur = NoTask THEN {} ELSE {cur.gen}))
                                \ {0}}
                 ELSE {}
    IN
    /\ st[c].life = "open"
    /\ gen[c] < MaxGeneration
    /\ gen' = Upd(gen, c, gen[c] + 1)
    /\ unwinding' = Upd(unwinding, c, UnwindingAfterCancel(c))
    /\ task' = Upd(task, c, NoTask)
    /\ wire' = Upd(wire, c, WireAfterCancel(c))
    /\ item' = Upd(item, c, Detached(c))
    /\ pendingStops' = Upd(pendingStops, c,
           pendingStops[c] \cup joins
           \cup (IF r.tk # 0 THEN {BarTicket(r.tk)} ELSE {}))
    /\ st' = [st EXCEPT
           ![c].life = "closed", ![c].retryGen = 0, ![c].consent = 0,
           ![c].sess = IF CloseStopsSession THEN NoJ ELSE @]
    /\ ApplyBar(c, r)
    /\ ghost' = [ghost EXCEPT
           ![c].trap = Trapped(@, r),
           ![c].closedAtConsent =
               @ \/ (st[c].consent # 0 /\ st[c].consent = gen[c])]
    /\ UNCHANGED <<itemGen, idleVars>>

\* The item fails with a server or unsupported-stream error, or a
\* watchdog fires: handlePlaybackFailure and the timeouts that end in
\* surfaceFailure.  handlePlaybackFailure returns while a consent choice
\* is pending.
Fail(c) ==
    /\ EnvFails
    /\ st[c].life = "open"
    /\ ~st[c].failed
    /\ st[c].consent = 0
    /\ item[c] = "attached" \/ task[c] # NoTask
    /\ SurfaceFailure(c, NoTask, st)

\* handlePlaybackFailure on an Original stream the user has not approved
\* encoding for: a new generation and a task that runs
\* requestVideoTranscodeConsent.  That task is not a reopen and is not
\* put in embyReopenTransactionTail.  The item stays until the task runs,
\* but its observers are removed, so it raises nothing more: the action
\* needs an item with no task behind it.
PlayerNeedsConsent(c) ==
    /\ ConsentPossible
    /\ st[c].life = "open"
    /\ ~st[c].failed
    /\ st[c].consent = 0
    /\ item[c] = "attached"
    /\ task[c] = NoTask
    /\ gen[c] + 1 < MaxGeneration
    /\ gen' = Upd(gen, c, gen[c] + 1)
    /\ task' = Upd(task, c, ETask(gen[c] + 1, "consent", 0, 0))
    /\ UNCHANGED <<serverVars, itemGen, item, unwinding, pendingStops,
                   idleVars, ownVars>>

-----------------------------------------------------------------------------
(* The reopen task                                                         *)

\* The task's PlaybackInfo request goes on the wire.
SendNegotiate(c, t) ==
    /\ SetTask(c, t, [t EXCEPT !.pc = "negotiate"])
    /\ wire' = Upd(wire, c, wire[c] \cup {t.gen})

\* `await predecessor?.value` returns.  A cancelled task waits for it
\* too, and then returns.  A current one reads currentTicket, or failing
\* that the ticket it captured, and awaits it; with no ticket it
\* negotiates at once.
TaskJoins(c, t) ==
    LET k == IF ~StopsBeforeNegotiate THEN 0
             ELSE IF HasAuthority(bar[c]) THEN CurrentTicket(bar[c])
             ELSE t.tk
    IN
    /\ t.kind = "reopen" /\ t.pc = "begin"
    /\ JoinsPredecessor => ~TaskRuns(c, t.pred)
    /\ IF ~Accepts(c, t) THEN EndTask(c, t) /\ UNCHANGED wire
       ELSE IF k = 0 THEN SendNegotiate(c, t)
       ELSE /\ SetTask(c, t, [t EXCEPT !.pc = "awaitStop", !.tk = k])
            /\ UNCHANGED wire
    /\ UNCHANGED <<serverVars, gen, itemGen, item, pendingStops, idleVars,
                   st, bar, ghost>>

\* The ticket's value is back.  Acknowledged, the task negotiates.
TaskStopAcked(c, t) ==
    /\ t.kind = "reopen" /\ t.pc = "awaitStop"
    /\ WaitsForStopAck => TkDone(c, t.tk)
    /\ IF ~Accepts(c, t) THEN EndTask(c, t) /\ UNCHANGED wire
       ELSE /\ \/ bar[c].tix[t.tk].res = "ok"
               \/ ~WaitsForStopAck
               \/ ~BlocksOnUnconfirmedStop
            /\ SendNegotiate(c, t)
    /\ UNCHANGED <<serverVars, gen, itemGen, item, pendingStops, idleVars,
                   st, bar, ghost>>

\* Unacknowledged: `throw PlaybackFailure(code: .priorSessionStopUnconfirmed)`.
\* The catch surfaces it, which does nothing when a failure already shows.
TaskStopUnconfirmed(c, t) ==
    /\ t.kind = "reopen" /\ t.pc = "awaitStop"
    /\ Accepts(c, t)
    /\ WaitsForStopAck /\ BlocksOnUnconfirmedStop
    /\ bar[c].tix[t.tk].res = "no"
    /\ IF st[c].failed
       THEN /\ EndTask(c, t)
            /\ UNCHANGED <<serverVars, gen, itemGen, item, pendingStops,
                           idleVars, ownVars>>
       ELSE SurfaceFailure(c, t, st)

\* stopRejectedRemoteStream: the session the task holds goes to the
\* barrier and the task awaits the ticket, cancelled or not.
Reject(c, t) ==
    LET j == <<t.sid, t.inc>>
        r == Begin(c, bar[c], j)
    IN IF RejectedIsStopped
       THEN /\ SetTask(c, t, [t EXCEPT !.pc = "rejectStop", !.tk = r.tk])
            /\ ApplyBar(c, r)
            /\ ghost' = [ghost EXCEPT ![c].trap = Trapped(@, r),
                                      ![c].rejected = @ \cup {j}]
       ELSE /\ EndTask(c, t)
            /\ ghost' = [ghost EXCEPT ![c].rejected = @ \cup {j}]
            /\ UNCHANGED <<serverVars, bar>>

\* The answer reaches a current task and playableRemoteStreamURL returns
\* a URL: the session's callbacks are installed and the item loaded.  The
\* awaits inside playableRemoteStreamURL (the copy playlist, the prewarm)
\* are folded into this step: a task cancelled there is rejected exactly
\* as one cancelled before it.
\*
\* With the order before the correction the old session's stop goes out
\* here, unless the server returned the same id
\* (RemoteStreamLifecyclePolicy.priorSessionStopDecision); the two-second
\* delay before it is folded in.
TaskAttaches(c, t) ==
    LET new == <<t.sid, t.inc>>
        old == st[c].sess
    IN
    /\ t.kind = "reopen" /\ t.pc = "negotiated"
    /\ Accepts(c, t)
    /\ AttachCore(c)
    /\ st' = [st EXCEPT ![c].sess = new, ![c].failed = FALSE]
    /\ IF old # NoJ /\ old[1] # new[1]
       THEN SendStopFor(c, old[1], old[2])
       ELSE UNCHANGED serverVars
    /\ UNCHANGED <<bar, wire, ghost>>

\* The answer reaches a current task and playableRemoteStreamURL calls
\* requestVideoTranscodeConsent, which sets the consent generation and
\* returns nil; the task then rejects the session it negotiated.  No
\* await separates the two.
\*
\* requestVideoTranscodeConsent would first await a ticket if the barrier
\* held authority.  It does not here: NoAuthorityAtPrepare.
TaskNeedsConsent(c, t) ==
    /\ ConsentPossible /\ StopsBeforeNegotiate
    /\ t.kind = "reopen" /\ t.pc = "negotiated"
    /\ Accepts(c, t)
    /\ IF ConsentRejectsNegotiated
       THEN /\ Reject(c, t)
            /\ st' = ShowsConsent(c, st)
            /\ UNCHANGED <<gen, itemGen, item, pendingStops, idleVars, wire>>
       ELSE /\ AttachCore(c)
            /\ st' = [st EXCEPT ![c].consent = gen[c] + 1,
                                ![c].sess = <<t.sid, t.inc>>]
            /\ UNCHANGED <<serverVars, bar, wire, ghost>>

\* The answer reaches a task that is no longer current.
TaskRejects(c, t) ==
    /\ t.kind = "reopen" /\ t.pc = "negotiated"
    /\ ~Accepts(c, t)
    /\ Reject(c, t)
    /\ UNCHANGED <<gen, itemGen, item, pendingStops, idleVars, st, wire>>

\* stopRejectedRemoteStream returns, whatever the ticket's value.
TaskRejectDone(c, t) ==
    /\ t.pc = "rejectStop"
    /\ TkDone(c, t.tk)
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
            /\ wire' = Upd(wire, c, WireAfterCancel(c))
            /\ UNCHANGED <<serverVars, gen, itemGen, item, pendingStops,
                           idleVars, st, bar, ghost>>
       ELSE SurfaceFailure(c, t, st)

-----------------------------------------------------------------------------
(* The first start, and the consent request                                *)

\* beginRemoteStream's task: playableRemoteStreamURL returns a URL and
\* the item is loaded.
InitialAttaches(c, t) ==
    /\ t.kind = "initial" /\ t.pc = "begin"
    /\ Accepts(c, t)
    /\ AttachCore(c)
    /\ UNCHANGED <<serverVars, ownVars>>

\* requestVideoTranscodeConsent, to its first await: from the first
\* start's playableRemoteStreamURL, or from the task PlayerNeedsConsent
\* made.  It detaches, hands the session's stop to the barrier
\* (beginEmbySessionStop) or reads currentTicket, and awaits the ticket.
\* With none it shows the choice at once.  A cancelled task returns here
\* whether or not consent is possible: a cancelled first start that never
\* attached simply returns (beginRemoteStream), consent or not.
ConsentBegins(c, t) ==
    LET r == IF ~ConsentStopsSession THEN NoBegin(bar[c], 0)
             ELSE IF st[c].sess # NoJ THEN Begin(c, bar[c], st[c].sess)
             ELSE NoBegin(bar[c], CurrentTicket(bar[c]))
        stopped == [st EXCEPT
                       ![c].sess = IF ConsentStopsSession THEN NoJ ELSE @]
    IN
    /\ t.kind \in {"initial", "consent"} /\ t.pc = "begin"
    /\ IF ~Accepts(c, t)
       THEN /\ EndTask(c, t)
            /\ UNCHANGED <<serverVars, item, st, bar, ghost>>
       ELSE /\ t.kind = "initial" => ConsentPossible
            /\ item' = Upd(item, c, Detached(c))
            /\ ApplyBar(c, r)
            /\ ghost' = [ghost EXCEPT ![c].trap = Trapped(@, r)]
            /\ IF r.tk = 0
               THEN EndTask(c, t) /\ st' = ShowsConsent(c, stopped)
               ELSE /\ SetTask(c, t, [t EXCEPT !.pc = "consentStop",
                                               !.tk = r.tk])
                    /\ st' = stopped
    /\ UNCHANGED <<gen, itemGen, pendingStops, idleVars, wire>>

\* The ticket's value is back: the choice is shown, or the unconfirmed
\* stop is surfaced.
ConsentStopAcked(c, t) ==
    /\ t.pc = "consentStop"
    /\ TkDone(c, t.tk)
    /\ IF ~Accepts(c, t) THEN UNCHANGED st
       ELSE /\ bar[c].tix[t.tk].res = "ok" \/ ~ConsentRequiresAck
            /\ st' = ShowsConsent(c, st)
    /\ EndTask(c, t)
    /\ UNCHANGED <<serverVars, gen, itemGen, item, pendingStops, idleVars,
                   bar, wire, ghost>>

ConsentStopUnconfirmed(c, t) ==
    /\ t.pc = "consentStop"
    /\ Accepts(c, t)
    /\ ConsentRequiresAck
    /\ bar[c].tix[t.tk].res = "no"
    /\ IF st[c].failed
       THEN /\ EndTask(c, t)
            /\ UNCHANGED <<serverVars, gen, itemGen, item, pendingStops,
                           idleVars, ownVars>>
       ELSE SurfaceFailure(c, t, st)

TaskStep(c) ==
    \E t \in Running(c) :
        \/ TaskJoins(c, t) \/ TaskStopAcked(c, t) \/ TaskStopUnconfirmed(c, t)
        \/ TaskAttaches(c, t) \/ TaskNeedsConsent(c, t) \/ TaskRejects(c, t)
        \/ TaskRejectDone(c, t) \/ TaskUnwindExit(c, t)
        \/ InitialAttaches(c, t) \/ ConsentBegins(c, t)
        \/ ConsentStopAcked(c, t) \/ ConsentStopUnconfirmed(c, t)

-----------------------------------------------------------------------------
(* The barrier's own task, and the server                                  *)

\* The barrier's task hears its stop's answer: acknowledged, it gives up
\* the operation; otherwise it keeps it.  A request that passed its
\* timeout reads as unacknowledged and stays on the wire.
BarrierResolves(c) ==
    LET r == PendingReq(c)
        res == IF r.status = "acked" THEN "ok" ELSE "no"
    IN
    /\ BarPending(bar[c])
    /\ r.status # "inFlight" \/ (StopTimesOut /\ r.late)
    /\ bar' = [bar EXCEPT ![c].tix[bar[c].n].res = res,
                          ![c].op = IF res = "ok" THEN NoJ ELSE @]
    /\ UNCHANGED <<serverVars, ctlVars, st, wire, ghost>>

\* The server acts on a PlaybackInfo request and returns an id of its
\* choosing.  The base counts the answer as a running job (contract, 7).
\* The current task hears it.  A request whose task was cancelled, or
\* that the client gave up on, is still here only with
\* AbandonedNegotiateCanLand, and then nobody hears the answer.
NegotiateLands(c, w) ==
    /\ w \in wire[c]
    /\ wire' = Upd(wire, c, wire[c] \ {w})
    /\ \E s \in Mintable :
          /\ StartJob(c, s)
          /\ IF task[c] # NoTask /\ task[c].gen = w
                /\ task[c].pc = "negotiate"
             THEN task' = Upd(task, c,
                      [task[c] EXCEPT !.pc = "negotiated", !.sid = s,
                                      !.inc = NextIncarnation(s)])
             ELSE UNCHANGED task
    /\ UNCHANGED <<gen, itemGen, item, unwinding, pendingStops, idleVars,
                   st, bar, ghost>>

\* A stop is applied, or ends unacknowledged.
ServerResolves(s) ==
    /\ ServerAck(s) \/ (StopsCanFail /\ ServerFail(s))
    /\ UNCHANGED <<ctlVars, ownVars>>

\* The server makes a stopped job again from a media request it had
\* already accepted: #421, an init.mp4 request landing while a seek-gap
\* restart has the job unregistered starts a second writer for the same
\* session.  Judged against the server, as in Jellyfin.
ServerRecreatesJob(s) ==
    /\ ServerRecreates
    /\ ServerRecreate(s)
    /\ UNCHANGED <<ctlVars, ownVars>>

\* The request timeout passes for the stop a barrier awaits.  A late stop
\* nobody awaits is no different from one on time.
TouchedReq == CHOOSE r \in stopReqs : r \notin stopReqs'
ClockTicks ==
    /\ StopsCanBeLate
    /\ ServerDelay
    /\ \E c \in Controllers :
          /\ BarPending(bar[c])
          /\ TouchedReq = PendingReq(c)
    /\ UNCHANGED <<ctlVars, ownVars>>

\* The current task's own request is answered or fails.
NegotiateResolves(c) ==
    \/ \E w \in wire[c] :
          /\ task[c] # NoTask /\ task[c].gen = w
          /\ NegotiateLands(c, w)
    \/ NegotiateFails(c)

Next ==
    \/ \E s \in SessionIds : ServerResolves(s) \/ ServerRecreatesJob(s)
    \/ ClockTicks
    \/ \E c \in Controllers :
          \/ Start(c) \/ Reopen(c) \/ Approve(c) \/ Decline(c)
          \/ Retry(c) \/ RetryProceeds(c) \/ Close(c)
          \/ Fail(c) \/ PlayerNeedsConsent(c)
          \/ TaskStep(c) \/ NegotiateFails(c)
          \/ BarrierResolves(c)
          \/ \E w \in wire[c] : NegotiateLands(c, w)

Spec == Init /\ [][Next]_vars

ClientFairness ==
    \A c \in Controllers :
        /\ WF_vars(TaskStep(c))
        /\ WF_vars(BarrierResolves(c))
        /\ WF_vars(RetryProceeds(c))
        /\ WF_vars(NegotiateResolves(c))

\* Every stop is answered or fails.  The user, failures and consent are
\* never forced.
FairSpec ==
    /\ Spec
    /\ ClientFairness
    /\ \A s \in SessionIds : WF_vars(ServerResolves(s))

\* No stop is ever forced to an answer; only the request timeout runs.
ClockFairSpec == Spec /\ ClientFairness /\ WF_vars(ClockTicks)

-----------------------------------------------------------------------------
(* Properties                                                              *)

\* The two `precondition`s of EmbyReopenStopBarrier.begin, which trap in
\* release builds.  No caller offers a stop while a ticket is in flight,
PendingTicketNeverReplaced ==
    \A c \in Controllers : "pending" \notin ghost[c].trap
\* or while a failed ticket keeps authority.
FailedTicketNeverReplaced ==
    \A c \in Controllers : "failed" \notin ghost[c].trap
BarrierPreconditions ==
    PendingTicketNeverReplaced /\ FailedTicketNeverReplaced

\* The branch TaskNeedsConsent leaves out is not reached: while a current
\* reopen holds a session it has not attached, the barrier has no
\* authority, so requestVideoTranscodeConsent has no ticket to await.
NoAuthorityAtPrepare ==
    \A c \in Controllers :
        (/\ task[c] # NoTask /\ task[c].kind = "reopen"
         /\ task[c].pc = "negotiated")
        => ~HasAuthority(bar[c])

Recreated(j) == server[j[1]][j[2]].serverRecreated

\* No new encoder while the prior stop is unconfirmed (LS-PB-008): at most
\* one job runs for a controller with no acknowledged stop meant for it.
\* The base's Owned drops a job once a stop for it failed, so OneEncoder
\* alone would let the client start the next encoder after a lost stop.
Unconfirmed(c) ==
    {j \in Live(c) : ~Recreated(j) /\ ~StopAckedFor(c, j[1], j[2])}
NoEncoderWhileUnconfirmed ==
    \A c \in Controllers : Cardinality(Unconfirmed(c)) <= 1

\* An Emby stop is an immutable closure over one negotiated session, so
\* the incarnation it means is known, and the base's judgement is the
\* property: no stop meant for an older job under an id ends a newer one.
StopNeverKillsSuccessor == NoWrongKill

\* The barrier never has a stop in flight for the session an attached
\* item plays from: the item is detached before the stop goes out (#43),
\* and nothing attaches while one is unanswered.
DetachedWhileStopping ==
    \A c \in Controllers : BarPending(bar[c]) => item[c] # "attached"

\* While the consent choice shows, nothing is attached, the old session's
\* stop has been handed over and acknowledged, and the only authority the
\* barrier may still hold is for a rejected, newly negotiated session.
ConsentShowing(c) == st[c].consent # 0 /\ st[c].consent = gen[c]
ConsentBoundary ==
    \A c \in Controllers :
        ConsentShowing(c)
        => /\ item[c] # "attached"
           /\ st[c].sess = NoJ
           /\ bar[c].op # NoJ => bar[c].op \in ghost[c].rejected

\* Every session a request of c's created is the one whose stop the
\* controller holds, is in the hands of a task that will attach or stop
\* it, or has had a stop sent; and after Close, or while a failure shows
\* with nothing under way, the controller holds none.  "Sent" is the
\* design's judgement: a stop that fails counts.
JobsOf(c) == {j \in Jobs : server[j[1]][j[2]].owner = c}
HeldByTask(c, j) ==
    \E t \in Running(c) :
        t.pc = "negotiated" /\ t.sid = j[1] /\ t.inc = j[2]
NoOrphans ==
    \A c \in Controllers :
        /\ \A j \in JobsOf(c) :
              \/ j = st[c].sess
              \/ HeldByTask(c, j)
              \/ SentStopFor(c, j[1], j[2])
        /\ (st[c].life = "closed" \/ (st[c].failed /\ task[c] = NoTask))
           => st[c].sess = NoJ

\* Once waitForPendingStopRequests would return after Close, nothing of
\* this playback is left to happen on the server.  The code does not keep
\* this: Finding-StopNoJoin, here and in the restart core.
JoinCoversCleanup ==
    \A c \in Controllers :
        (st[c].life = "closed" /\ Joined(c))
        => /\ \A t \in unwinding[c] : t.pc \notin {"negotiated", "rejectStop"}
           /\ ~BarPending(bar[c])
           /\ wire[c] = {}

\* MaxGeneration bounds no behaviour: no guard on a generation counter is
\* ever the one that disables an action.
GenerationsSuffice == \A c \in Controllers : gen[c] + 2 <= MaxGeneration

-----------------------------------------------------------------------------
(* Liveness                                                                *)

\* A start, reopen or consent request ends: it attaches, shows the
\* choice, fails or is closed.
ReopenSettles ==
    \A c \in Controllers : task[c] # NoTask ~> task[c] = NoTask

\* After Close every task returns and the joined cleanup ends.
CloseCleansUp ==
    \A c \in Controllers :
        st[c].life = "closed" ~> unwinding[c] = {} /\ Joined(c)

-----------------------------------------------------------------------------
(* Witnesses.  Each is the negation of a state one branch of the model     *)
(* reaches, so each is violated when checked as an invariant.  No config   *)
(* lists them; the README says how to repeat the check.                    *)

NeverBlocked ==
    \A c \in Controllers :
        ~(st[c].failed /\ bar[c].op # NoJ /\ ~BarPending(bar[c]))
NeverFinalRetry == \A c \in Controllers : ~bar[c].finalRetry
NeverRejected == \A c \in Controllers : ghost[c].rejected = {}
NeverRejectFailed ==
    \A c \in Controllers :
        ~(bar[c].op \in ghost[c].rejected /\ ~BarPending(bar[c]))
NeverTwoUnwinding ==
    \A c \in Controllers : Cardinality(unwinding[c]) < 2
NeverJoinedTicket ==
    \A c \in Controllers :
        ~(task[c] # NoTask /\ task[c].pc = "awaitStop"
          /\ bar[c].tix[task[c].tk].job \in ghost[c].rejected)
NeverReusedId == \A s \in SessionIds : Latest(s) < 2
NeverConsentShown == \A c \in Controllers : ~ConsentShowing(c)
NeverConsentWhileRejecting ==
    \A c \in Controllers : ~(ConsentShowing(c) /\ BarPending(bar[c]))
NeverClosedAtConsent == \A c \in Controllers : ~ghost[c].closedAtConsent
NeverClosedAtConsentRejecting ==
    \A c \in Controllers :
        ~(ghost[c].closedAtConsent /\ BarPending(bar[c]))
NeverRestartFromFailure ==
    \A c \in Controllers : ~(st[c].failed /\ task[c] # NoTask)
NeverRetryWaits ==
    \A c \in Controllers : ~(st[c].retryGen # 0 /\ ~Joined(c))
NeverTimedOut ==
    \A c \in Controllers :
        \A k \in 1..bar[c].n :
            LET tx == bar[c].tix[k] IN
            ~(tx.res = "no"
              /\ \E r \in StopsFor(c, tx.job[1], tx.job[2]) :
                    r.n = tx.rn /\ r.status = "inFlight")
NeverLateAck ==
    \A c \in Controllers :
        \A k \in 1..bar[c].n :
            LET tx == bar[c].tix[k] IN
            ~(tx.res = "no"
              /\ \E r \in StopsFor(c, tx.job[1], tx.job[2]) :
                    r.n = tx.rn /\ r.status = "acked")
NeverStopFailed == \A r \in stopReqs : r.status # "failed"
NeverRecreated ==
    \A j \in Jobs : ~server[j[1]][j[2]].serverRecreated
\* Two controllers: the second was given an id the first had used.
NeverSharedId == OneOwnerPerId
=============================================================================
