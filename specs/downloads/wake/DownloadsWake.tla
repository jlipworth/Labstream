---------------------------- MODULE DownloadsWake ----------------------------
(***************************************************************************)
(* Background wakes: the OS hands the app a completion handler, the app    *)
(* must call it once its background URLSession work is safe, and must not  *)
(* hold it past the wake budget.                                           *)
(*                                                                         *)
(* Three pieces of code are modelled together, for the one background      *)
(* session identifier the app uses:                                        *)
(*                                                                         *)
(*  - the registry (MainActor): stored handlers, their receipts with the   *)
(*    frozen deadline, and the timer that covers a session that never      *)
(*    registers;                                                           *)
(*  - the wake coordinator (one lock): the wake, the handlers awaiting     *)
(*    finish-events, required operations, the persistence proof, and the   *)
(*    reserve, operation and absolute-deadline timers;                     *)
(*  - startup: the manager's recovery state and the session's admission    *)
(*    state (dormant, purging, active), including a startup block before   *)
(*    and after the transport exists.                                      *)
(*                                                                         *)
(* A handler is released in two steps, as in the code: the coordinator     *)
(* claims its token (the wake ends), then a MainActor hop calls it.        *)
(* `releaseQ` holds the tokens between the two steps.                      *)
(*                                                                         *)
(* This module has no download rows: nothing here changes a lifecycle, so  *)
(* it never calls Reduce and needs no projection config.  Transfer work    *)
(* is the abstract operations in `Ops` and one delayed retry.              *)
(*                                                                         *)
(* Abstractions:                                                           *)
(*  - Time is a small integer clock that keeps running while a timer      *)
(*    callback waits on its queue, as DispatchTime does.  A timer's        *)
(*    callback runs at most TimerSlack ticks after the later of its        *)
(*    deadline and the moment it was armed: Tick is disabled only once a   *)
(*    timer that exists is that late.  "Claimed within the budget" is      *)
(*    then an invariant with the slack in it, and it fails when the        *)
(*    timer that should claim is missing, whatever other timer is due.     *)
(*    Everything else (finish-events, flushes, operations, a new handler)  *)
(*    can happen between a deadline and its callback.  The MainActor hop   *)
(*    that calls a claimed handler is not bounded by time, only by         *)
(*    fairness.                                                            *)
(*  - Timers are derived from state instead of stored: a timer is due      *)
(*    when its wake still exists and its deadline has passed.  The code    *)
(*    checks the wake generation for the same purpose.  The model          *)
(*    therefore cannot find an arming mistake.  The four timers are        *)
(*    switched separately: FixB13 is the operation deadline alone.         *)
(*  - The persistence epoch is two booleans: whether the running flush     *)
(*    and the stored proof still cover the current epoch.                  *)
(*  - The registry's own startup memory (noteStartupWakeState on the       *)
(*    registry) is not modelled: nothing in the app calls it.              *)
(*  - Rebuild grace, deferred revalidation keys, the unsupported-schema    *)
(*    reset and per-task callback rejection are not modelled.              *)
(***************************************************************************)
\* MODELS: Labstream/Capabilities/Downloads/Core/BackgroundDownloadWakeCoordinator.swift
\* MODELS: Labstream/Capabilities/Downloads/Core/BackgroundDownloadCompletionRegistry.swift
\* MODELS: Labstream/Capabilities/Downloads/Core/DownloadWakeBudgetContract.swift
\* MODELS: PMSKit/Sources/PMSKit/Downloads/BackgroundDownloadCompletionHandlerStore.swift
EXTENDS DownloadsReducer, TLC

CONSTANTS
    Handlers,       \* completion-handler tokens the OS may supply
    Ops,            \* wake operations (append, finalization, held lifecycle, delayed retry)
    MaxTime,        \* the clock stops here
    WholeWake,      \* DownloadWakeBudget.wholeWake
    OpBudget,       \* DownloadWakeBudget.operation
    Reserve,        \* DownloadWakeBudget.persistenceReserve
    MaxCrash, MaxEvents, MaxOps, MaxFails, MaxRetries,  \* how often the environment may act
    AllowStuck,     \* an operation may leak: begin and never end
    FixB04,         \* a delayed retry holds a wake operation until its successor registers
    FixB05,         \* a block after the transport exists keeps running holds (no abort)
    FixB06,         \* the session remembers a startup block and releases a late handler
    FixB11,         \* the app delegate stores the handler synchronously
    FixB13,         \* the operation deadline exists: a leaked operation holds a wake
                    \*   for at most OpBudget
    TimerSlack,     \* how many ticks late a timer callback may run
    MutantNoAbsoluteDeadline,  \* injected: the wake's absolute-deadline timer is missing
    MutantNoRegistryTimer,     \* injected: the registry's own deadline timer is missing
    FixStaleDeadline,       \* PROPOSED (finding W1): a claimed token's receipt is not inherited
    MutantDrainByIdentifier \* injected: a release drains every handler for the identifier

ASSUME /\ WholeWake \in Nat /\ OpBudget \in Nat /\ Reserve \in Nat /\ MaxTime \in Nat
       /\ Reserve <= WholeWake /\ TimerSlack \in Nat

VARIABLES
    \* Durable or outside the process.
    now,            \* the clock
    evQ,            \* daemon: task events queued for the app
    env,            \* what is left of the Max* budgets
    \* In memory.
    up,
    hs,             \* handler -> "fresh" | "hop" | "stored" | "called" | "spent"
    hdl,            \* handler -> its receipt's absolute deadline (0 when it has no receipt)
    finishOwed,     \* the OS will call urlSessionDidFinishEvents once events are delivered
    mgr,            \* DownloadManager startup: "none" (not built) | "preparing" | "waiting"
                    \*   | "inflight" | "ready" | "blocked"
    adm,            \* StartupAdmissionState
    live,           \* the URLSession has been constructed
    failedAfter,    \* startupFailedAfterSessionConstruction
    sws,            \* the session's startupWakeState: "deferred" | "blockedBefore" | "failedAfter"
    c,              \* the wake coordinator (see CoordInit)
    op,             \* operation -> "idle" | "run" | "stuck"
    opStart,        \* operation -> when it began
    retry,          \* "none" | "pending": a delayed retry whose successor is not registered
    retryOp,        \* the operation that retry holds, or "none"
    releaseQ,       \* claimed tokens whose MainActor hop has not run
    \* Ghosts.
    hat,            \* handler -> when the timer that now covers it was armed
    texp,           \* operations a timed-out wake really was waiting for
    flags           \* what went wrong, by name

durable == <<now, evQ, env>>
memory == <<up, hs, hdl, finishOwed, mgr, adm, live, failedAfter, sws, c, op, opStart, retry,
            retryOp, releaseQ>>
ghosts == <<hat, texp, flags>>
vars == <<durable, memory, ghosts>>

Sym == Permutations(Handlers) \cup Permutations(Ops)

-----------------------------------------------------------------------------
(* Helpers                                                                 *)

MinOf(S) == CHOOSE x \in S : \A y \in S : x <= y
Min2(a, b) == IF a <= b THEN a ELSE b
Max2(a, b) == IF a >= b THEN a ELSE b

Stored == {h \in Handlers : hs[h] = "stored"}
Running == {o \in Ops : op[o] # "idle"}

-----------------------------------------------------------------------------
(* The wake coordinator (BackgroundDownloadWakeCoordinator)                *)

\* on..winding are the `wake`; reg is `operations`; expOps is `expiredOperations`;
\* authExp is `backgroundAuthorizationExpired`.  `at` is when the wake's timers were
\* armed (Wake.receivedAt for a new wake).
CoordInit ==
    [on |-> FALSE, dl |-> 0, at |-> 0, aw |-> {}, fin |-> {}, req |-> {}, flushing |-> FALSE,
     flushOK |-> FALSE, proofOK |-> FALSE, winding |-> FALSE,
     reg |-> {}, expOps |-> {}, authExp |-> FALSE]

NoWake(cc) ==
    [cc EXCEPT !.on = FALSE, !.dl = 0, !.at = 0, !.aw = {}, !.fin = {}, !.req = {},
               !.flushing = FALSE, !.flushOK = FALSE, !.proofOK = FALSE,
               !.winding = FALSE]

\* `epoch &+= 1`: neither the running flush nor the proof covers the new epoch.
Bump(cc) == [cc EXCEPT !.flushOK = FALSE, !.proofOK = FALSE]

\* A coordinator call returns the new coordinator and what it claimed.
Kept(cc) == [c |-> cc, batch |-> {}, outcome |-> "none", req |-> {}]

\* claimLocked
Claim(cc, outcome) ==
    IF ~cc.on THEN Kept(cc)
    ELSE [c |-> [NoWake(cc) EXCEPT
                    !.authExp = IF outcome = "timedOut" THEN TRUE ELSE @,
                    !.expOps = IF outcome = "timedOut" THEN @ \cup cc.req ELSE @],
          batch |-> cc.fin \cup cc.aw, outcome |-> outcome, req |-> cc.req]

\* progressLocked
Progress(cc, proactive) ==
    IF ~cc.on THEN Kept(cc)
    ELSE IF cc.aw = {} /\ cc.req = {} /\ cc.proofOK THEN Claim(cc, "drained")
    ELSE IF /\ ~cc.flushing
            /\ (proactive \/ (cc.aw = {} /\ cc.req = {}))
            /\ now < cc.dl
         THEN Kept([cc EXCEPT !.flushing = TRUE, !.flushOK = TRUE])
    ELSE Kept(cc)

\* storeHandler, for every token in H (register replays several at once).
StoreH(cc, H, dl) ==
    LET base == IF cc.on THEN cc
                ELSE [cc EXCEPT !.on = TRUE, !.dl = dl, !.at = now, !.authExp = FALSE,
                                !.req = cc.reg \ cc.expOps]
    IN Bump([base EXCEPT !.dl = Min2(base.dl, dl), !.aw = @ \cup H])

\* beginOperation(kind:)
BeginOp(cc, o) ==
    LET c1 == [cc EXCEPT !.reg = @ \cup {o},
                         !.expOps = IF ~cc.on /\ cc.expOps # {} THEN @ \cup {o} ELSE @]
    IN IF cc.on THEN Bump([c1 EXCEPT !.req = @ \cup {o}]) ELSE c1

\* endOperation(_:)
EndOp(cc, o) ==
    IF o \notin cc.reg THEN Kept(cc)
    ELSE LET c1 == [cc EXCEPT !.reg = @ \ {o}, !.expOps = @ \ {o}]
             c2 == IF o \in cc.req THEN Bump([c1 EXCEPT !.req = @ \ {o}]) ELSE c1
         IN Progress(c2, FALSE)

\* finishEvents(identifier:) and finishAllAwaitingEvents: there is one identifier.
FinishEv(cc) == Progress([cc EXCEPT !.fin = @ \cup cc.aw, !.aw = {}], FALSE)

\* abortAwaitingHandlers
Abort(cc) == Claim([cc EXCEPT !.reg = {}, !.expOps = {}], "startupBlocked")

-----------------------------------------------------------------------------
(* The session (BackgroundDownloadSession)                                 *)

\* releaseBackgroundCompletionAfterStartupFailure, once it knows admission is dormant.
\* B05: with the transport live, running holds are kept and only finish-events are forced.
StartupRelease(cc, transportLive) ==
    IF transportLive /\ FixB05 THEN FinishEv(cc) ELSE Abort(cc)

\* What that call does to startupWakeState.  B06: before the fix nothing was remembered.
SwsAfterBlock(transportLive) ==
    IF FixB06 /\ sws = "deferred"
    THEN (IF transportLive THEN "failedAfter" ELSE "blockedBefore")
    ELSE sws

\* noteBackgroundCompletionHandlerStored: store, then releaseIfStartupBlocked (B06).
SessionStore(cc, H, dl) ==
    LET c1 == StoreH(cc, H, dl)
    IN IF FixB06 /\ sws # "deferred" /\ adm = "dormant"
       THEN StartupRelease(c1, failedAfter)
       ELSE Kept(c1)

\* Apply a coordinator result: applyBackgroundWakeDrain queues the MainActor hop.
\* opAfter and retryAfter are the values this step leaves behind.
Commit(r, opAfter, retryAfter, extra) ==
    LET released == r.outcome \in {"drained", "startupBlocked"}
        texpNext == (IF r.outcome = "timedOut" THEN texp \cup r.req ELSE texp)
                        \cap {o \in Ops : opAfter[o] # "idle"}
    IN /\ c' = r.c
       /\ releaseQ' = releaseQ \cup r.batch
       /\ texp' = texpNext
       /\ flags' = flags \cup extra
            \cup (IF released /\ r.req # {} THEN {"heldWorkDropped"} ELSE {})
            \cup (IF /\ r.outcome = "drained" /\ retryAfter = "pending"
                     /\ retryOp \notin r.c.expOps
                  THEN {"retryUnregistered"} ELSE {})
            \cup (IF /\ r.outcome = "drained"
                     /\ \E o \in Ops : opAfter[o] # "idle" /\ o \notin texpNext
                  THEN {"unsettledWork"} ELSE {})

-----------------------------------------------------------------------------
(* The registry (BackgroundDownloadCompletionRegistry) and the OS          *)

\* store(identifier:completion:).  A new receipt takes the earliest deadline of the
\* receipts still held.  A receipt is dropped only when its handler is called, so it is
\* still held while its claimed token waits in releaseQ (finding W1).
RegStore(h) ==
    LET fresh == now + WholeWake
        inherit(S) == IF S = {} THEN fresh ELSE MinOf({hdl[g] : g \in S})
        unclaimed == Stored \ releaseQ
        dl == IF FixStaleDeadline THEN inherit(unclaimed) ELSE inherit(Stored)
        r == IF mgr # "none" THEN SessionStore(c, {h}, dl) ELSE Kept(c)
    IN /\ hs' = [hs EXCEPT ![h] = "stored"]
       /\ hdl' = [hdl EXCEPT ![h] = dl]
       /\ hat' = [hat EXCEPT ![h] = now]
       \* onBackgroundWakeAuthorized -> resumeStartupRecoveryAfterAuthorization
       /\ mgr' = IF mgr = "waiting" THEN "preparing" ELSE mgr
       /\ Commit(r, op, retry,
                 (IF dl < inherit(unclaimed) THEN {"staleDeadline"} ELSE {})
                 \cup (IF dl < inherit(unclaimed) /\ dl <= now THEN {"bornExpired"} ELSE {}))

\* application(_:handleEventsForBackgroundURLSession:completionHandler:)
\* B11: before the fix the handler reached the registry through a Task hop.
OSDeliver(h) ==
    /\ up /\ hs[h] = "fresh"
    /\ now + WholeWake <= MaxTime
    /\ finishOwed' = TRUE
    /\ IF FixB11
       THEN RegStore(h)
       ELSE /\ hs' = [hs EXCEPT ![h] = "hop"]
            /\ UNCHANGED <<hdl, mgr, c, releaseQ, hat, texp, flags>>
    /\ UNCHANGED <<durable, up, adm, live, failedAfter, sws, op, opStart, retry, retryOp>>

HopStore(h) ==
    /\ up /\ hs[h] = "hop"
    /\ RegStore(h)
    /\ UNCHANGED <<durable, up, finishOwed, adm, live, failedAfter, sws, op, opStart, retry,
                   retryOp>>

\* fireCompletions(in:) on the MainActor, for everything claimed so far.
MainFire ==
    /\ up /\ releaseQ # {}
    /\ LET fired == IF MutantDrainByIdentifier THEN Stored ELSE releaseQ \cap Stored
       IN /\ hs' = [h \in Handlers |-> IF h \in fired THEN "called" ELSE hs[h]]
          /\ hdl' = [h \in Handlers |-> IF h \in fired \cup releaseQ THEN 0 ELSE hdl[h]]
          /\ flags' = flags \cup (IF fired \ releaseQ # {} THEN {"earlyCall"} ELSE {})
    /\ releaseQ' = {}
    /\ UNCHANGED <<durable, up, finishOwed, mgr, adm, live, failedAfter, sws, c, op, opStart,
                   retry, retryOp, hat, texp>>

\* The registry's own deadline timer: only while no session has registered.
RegistryTimerDue ==
    up /\ ~MutantNoRegistryTimer /\ mgr = "none" /\ \E h \in Stored : now >= hdl[h]
RegistryTimer ==
    /\ RegistryTimerDue
    /\ LET fired == {h \in Stored : now >= hdl[h]}
       IN /\ hs' = [h \in Handlers |-> IF h \in fired THEN "called" ELSE hs[h]]
          /\ hdl' = [h \in Handlers |-> IF h \in fired THEN 0 ELSE hdl[h]]
    /\ UNCHANGED <<durable, up, finishOwed, mgr, adm, live, failedAfter, sws, c, op, opStart,
                   retry, retryOp, releaseQ, ghosts>>

-----------------------------------------------------------------------------
(* Startup (DownloadManager and the session's StartupAdmissionState)       *)

\* DownloadManager.init: register(session) replays every pending receipt into the dormant
\* session's coordinator, before activation can construct the URLSession.
ManagerInit ==
    /\ up /\ mgr = "none"
    /\ mgr' = "preparing"
    /\ LET r == IF Stored = {} THEN Kept(c)
                ELSE SessionStore(c, Stored, MinOf({hdl[h] : h \in Stored}))
       IN Commit(r, op, retry, {})
    \* The registry's timer stops covering these handlers; the wake's timers are armed now.
    /\ hat' = [h \in Handlers |-> IF h \in Stored THEN now ELSE hat[h]]
    /\ UNCHANGED <<durable, up, hs, hdl, finishOwed, adm, live, failedAfter, sws, op, opStart,
                   retry, retryOp>>

\* activateDownloadsForCurrentStore: wait when the wake authorization has expired,
\* otherwise activateCurrentStore constructs the transport and starts the purge.
ManagerActivate ==
    /\ up /\ mgr = "preparing"
    /\ IF c.authExp
       THEN mgr' = "waiting" /\ UNCHANGED <<adm, live>>
       ELSE mgr' = "inflight" /\ adm' = "purging" /\ live' = TRUE
    /\ UNCHANGED <<durable, up, hs, hdl, finishOwed, failedAfter, sws, c, op, opStart, retry,
                   retryOp, releaseQ, ghosts>>

PurgeDone ==
    /\ up /\ adm = "purging"
    /\ adm' = "active" /\ mgr' = "ready"
    /\ UNCHANGED <<durable, up, hs, hdl, finishOwed, live, failedAfter, sws, c, op, opStart,
                   retry, retryOp, releaseQ, ghosts>>

\* failStartupAdmission, then the manager's blockDownloadStartup.
PurgeFail ==
    /\ up /\ adm = "purging" /\ env.fails > 0
    /\ env' = [env EXCEPT !.fails = @ - 1]
    /\ adm' = "dormant" /\ failedAfter' = TRUE /\ mgr' = "blocked"
    /\ sws' = SwsAfterBlock(TRUE)
    /\ Commit(StartupRelease(c, TRUE), op, retry, {})
    /\ UNCHANGED <<now, evQ, up, hs, hdl, finishOwed, live, op, opStart, retry, retryOp,
                   hat>>

\* blockDownloadStartup from store admission (unreadable or inconsistent index).
BlockBefore ==
    /\ up /\ mgr = "preparing" /\ env.fails > 0
    /\ env' = [env EXCEPT !.fails = @ - 1]
    /\ mgr' = "blocked"
    /\ sws' = SwsAfterBlock(failedAfter)
    /\ Commit(StartupRelease(c, failedAfter), op, retry, {})
    /\ UNCHANGED <<now, evQ, up, hs, hdl, finishOwed, adm, live, failedAfter, op, opStart,
                   retry, retryOp,
                   hat>>

\* Retry Recovery, or the transient startup retry.
ManagerRetry ==
    /\ up /\ mgr = "blocked" /\ env.retries > 0
    /\ env' = [env EXCEPT !.retries = @ - 1]
    /\ mgr' = "preparing"
    /\ UNCHANGED <<now, evQ, up, hs, hdl, finishOwed, adm, live, failedAfter, sws, c, op,
                   opStart, retry, retryOp, releaseQ, ghosts>>

\* An active-scene edge: noteForegroundAuthorization, and startup recovery resumes.
Foreground ==
    /\ up /\ (c.authExp \/ mgr = "waiting")
    /\ c' = [c EXCEPT !.authExp = FALSE]
    /\ mgr' = IF mgr = "waiting" THEN "preparing" ELSE mgr
    /\ UNCHANGED <<durable, up, hs, hdl, finishOwed, adm, live, failedAfter, sws, op, opStart,
                   retry, retryOp, releaseQ, ghosts>>

-----------------------------------------------------------------------------
(* Transfer work                                                           *)

DaemonFinish ==
    /\ evQ = 0 /\ env.events > 0
    /\ evQ' = 1
    /\ env' = [env EXCEPT !.events = @ - 1]
    /\ UNCHANGED <<now, memory, ghosts>>

\* A task callback.  It may end by scheduling a delayed retry (scheduleRangeRetry).
\* B04: the fix holds a .delayedRetry operation across the delay.
TaskCallback ==
    /\ up /\ live /\ evQ > 0
    /\ evQ' = evQ - 1
    /\ \/ UNCHANGED <<env, c, op, opStart, retry, retryOp>>
       \/ /\ retry = "none"
          /\ retry' = "pending"
          /\ IF FixB04
             THEN \E o \in Ops :
                    /\ op[o] = "idle" /\ env.ops > 0
                    /\ env' = [env EXCEPT !.ops = @ - 1]
                    /\ op' = [op EXCEPT ![o] = "run"]
                    /\ opStart' = [opStart EXCEPT ![o] = now]
                    /\ retryOp' = o
                    /\ c' = BeginOp(c, o)
             ELSE UNCHANGED <<env, c, op, opStart, retryOp>>
    /\ UNCHANGED <<now, up, hs, hdl, finishOwed, mgr, adm, live, failedAfter, sws, releaseQ,
                   ghosts>>

\* The delayed retry runs and registers its successor task.
RetryRun ==
    /\ up /\ retry = "pending"
    /\ retry' = "none" /\ retryOp' = "none"
    /\ IF retryOp = "none"
       THEN UNCHANGED <<c, op, opStart, releaseQ, ghosts>>
       ELSE /\ op' = [op EXCEPT ![retryOp] = "idle"]
            /\ opStart' = [opStart EXCEPT ![retryOp] = 0]
            /\ Commit(EndOp(c, retryOp), op', "none", {})
            /\ UNCHANGED hat
    /\ UNCHANGED <<durable, up, hs, hdl, finishOwed, mgr, adm, live, failedAfter, sws>>

OpBegin(o, stuck) ==
    /\ up /\ live /\ op[o] = "idle" /\ env.ops > 0
    /\ stuck => AllowStuck
    /\ env' = [env EXCEPT !.ops = @ - 1]
    /\ op' = [op EXCEPT ![o] = IF stuck THEN "stuck" ELSE "run"]
    /\ opStart' = [opStart EXCEPT ![o] = now]
    /\ c' = BeginOp(c, o)
    /\ UNCHANGED <<now, evQ, up, hs, hdl, finishOwed, mgr, adm, live, failedAfter, sws, retry,
                   retryOp, releaseQ, ghosts>>

OpEnd(o) ==
    /\ up /\ op[o] = "run" /\ o # retryOp
    /\ op' = [op EXCEPT ![o] = "idle"]
    /\ opStart' = [opStart EXCEPT ![o] = 0]
    /\ Commit(EndOp(c, o), op', retry, {})
    /\ UNCHANGED <<durable, up, hs, hdl, finishOwed, mgr, adm, live, failedAfter, sws, retry,
                   retryOp,
                   hat>>

\* urlSessionDidFinishEvents: every queued event has been delivered.
DidFinishEvents ==
    /\ up /\ live /\ finishOwed /\ evQ = 0
    /\ finishOwed' = FALSE
    /\ Commit(FinishEv(c), op, retry, {})
    /\ UNCHANGED <<durable, up, hs, hdl, mgr, adm, live, failedAfter, sws, op, opStart, retry,
                   retryOp,
                   hat>>

\* persistenceFinished(_:committed:)
FlushDone(committed) ==
    /\ up /\ c.on /\ c.flushing
    /\ LET c1 == [c EXCEPT !.flushing = FALSE,
                           !.proofOK = IF committed THEN c.flushOK ELSE @]
           r == IF now >= c.dl THEN Claim(c1, "timedOut")
                ELSE IF ~committed THEN Kept(c1)
                ELSE Progress(c1, FALSE)
       IN Commit(r, op, retry, {})
    /\ UNCHANGED <<durable, up, hs, hdl, finishOwed, mgr, adm, live, failedAfter, sws, op,
                   opStart, retry, retryOp,
                   hat>>

-----------------------------------------------------------------------------
(* Timers (B13)                                                            *)

AbsDue == up /\ ~MutantNoAbsoluteDeadline /\ c.on /\ now >= c.dl
\* arm(_:): min(startedAt + operation, wake.deadline); the absolute deadline is the other
\* half of that minimum.  storeHandler re-arms the operations a new wake inherits.
WatchdogDue(o) ==
    up /\ FixB13 /\ c.on /\ o \in c.req /\ o \in c.reg /\ now >= opStart[o] + OpBudget
ReserveDue == up /\ c.on /\ ~c.winding /\ now + Reserve >= c.dl

\* A timer's callback has waited TimerSlack ticks since the later of its deadline and
\* the moment it was armed.
AbsLate == AbsDue /\ now >= Max2(c.dl, c.at) + TimerSlack
WatchdogLate(o) == WatchdogDue(o) /\ now >= Max2(opStart[o] + OpBudget, c.at) + TimerSlack
ReserveLate == ReserveDue /\ now + Reserve >= Max2(c.dl, c.at + Reserve) + TimerSlack
RegistryTimerLate ==
    RegistryTimerDue /\ \E h \in Stored : now >= Max2(hdl[h], hat[h]) + TimerSlack
TimerLate == AbsLate \/ ReserveLate \/ RegistryTimerLate \/ \E o \in Ops : WatchdogLate(o)

TimedOut ==
    /\ AbsDue \/ \E o \in Ops : WatchdogDue(o)
    /\ Commit(Claim(c, "timedOut"), op, retry, {})
    /\ UNCHANGED <<durable, up, hs, hdl, finishOwed, mgr, adm, live, failedAfter, sws, op,
                   opStart, retry, retryOp,
                   hat>>

\* The persistence-reserve timer: wind down and flush proactively.
ReserveFire ==
    /\ ReserveDue
    /\ Commit(Progress([c EXCEPT !.winding = TRUE], TRUE), op, retry, {})
    /\ UNCHANGED <<durable, up, hs, hdl, finishOwed, mgr, adm, live, failedAfter, sws, op,
                   opStart, retry, retryOp,
                   hat>>

\* The clock does not wait for a due timer, only for one that is TimerSlack late.
Tick ==
    /\ now < MaxTime /\ ~TimerLate
    /\ now' = now + 1
    /\ UNCHANGED <<evQ, env, memory, ghosts>>

-----------------------------------------------------------------------------
(* Process death                                                           *)

Crash ==
    /\ up /\ env.crash > 0
    /\ env' = [env EXCEPT !.crash = @ - 1]
    /\ up' = FALSE
    \* The dead process's handlers are gone; tokens the OS has not supplied stay fresh.
    /\ hs' = [h \in Handlers |-> IF hs[h] = "fresh" THEN "fresh" ELSE "spent"]
    /\ hdl' = Const(Handlers, 0)
    /\ hat' = Const(Handlers, 0)
    /\ finishOwed' = FALSE
    /\ mgr' = "none" /\ adm' = "dormant" /\ live' = FALSE /\ failedAfter' = FALSE
    /\ sws' = "deferred"
    /\ c' = CoordInit
    /\ op' = Const(Ops, "idle") /\ opStart' = Const(Ops, 0)
    /\ retry' = "none" /\ retryOp' = "none"
    /\ releaseQ' = {}
    /\ texp' = {}
    /\ UNCHANGED <<now, evQ, flags>>

\* Recovery is ManagerInit, which the relaunched process schedules.
Relaunch ==
    /\ ~up /\ up' = TRUE
    /\ UNCHANGED <<durable, hs, hdl, finishOwed, mgr, adm, live, failedAfter, sws, c, op,
                   opStart, retry, retryOp, releaseQ, ghosts>>

-----------------------------------------------------------------------------

Init ==
    /\ now = 0 /\ evQ = 0 /\ env = [crash |-> MaxCrash, events |-> MaxEvents, ops |-> MaxOps,
                              fails |-> MaxFails, retries |-> MaxRetries]
    /\ up = TRUE
    /\ hs = Const(Handlers, "fresh") /\ hdl = Const(Handlers, 0)
    /\ finishOwed = FALSE
    /\ mgr = "none" /\ adm = "dormant" /\ live = FALSE /\ failedAfter = FALSE
    /\ sws = "deferred"
    /\ c = CoordInit
    /\ op = Const(Ops, "idle") /\ opStart = Const(Ops, 0)
    /\ retry = "none" /\ retryOp = "none"
    /\ releaseQ = {}
    /\ hat = Const(Handlers, 0) /\ texp = {} /\ flags = {}

Next ==
    \/ \E h \in Handlers : OSDeliver(h) \/ HopStore(h)
    \/ MainFire \/ RegistryTimer
    \/ ManagerInit \/ ManagerActivate \/ PurgeDone \/ PurgeFail \/ BlockBefore
    \/ ManagerRetry \/ Foreground
    \/ DaemonFinish \/ TaskCallback \/ RetryRun
    \/ \E o \in Ops : OpEnd(o) \/ \E stuck \in BOOLEAN : OpBegin(o, stuck)
    \/ DidFinishEvents
    \/ \E committed \in BOOLEAN : FlushDone(committed)
    \/ TimedOut \/ ReserveFire \/ Tick
    \/ Crash \/ Relaunch

Spec == Init /\ [][Next]_vars

\* Timers fire, the clock moves and the MainActor runs its queue.  Nothing else is forced:
\* finish-events, operations, flushes and startup may all never happen.
FairSpec ==
    /\ Spec
    /\ WF_vars(Tick) /\ WF_vars(TimedOut) /\ WF_vars(ReserveFire) /\ WF_vars(RegistryTimer)
    /\ WF_vars(MainFire) /\ WF_vars(Relaunch)

-----------------------------------------------------------------------------
(* Properties                                                              *)

TypeOK ==
    /\ now \in 0..MaxTime /\ evQ \in 0..1
    /\ up \in BOOLEAN
    /\ hs \in [Handlers -> {"fresh", "hop", "stored", "called", "spent"}]
    /\ hdl \in [Handlers -> 0..MaxTime]
    /\ finishOwed \in BOOLEAN
    /\ mgr \in {"none", "preparing", "waiting", "inflight", "ready", "blocked"}
    /\ adm \in {"dormant", "purging", "active"}
    /\ live \in BOOLEAN /\ failedAfter \in BOOLEAN
    /\ sws \in {"deferred", "blockedBefore", "failedAfter"}
    /\ hat \in [Handlers -> 0..MaxTime]
    /\ c.on \in BOOLEAN /\ c.dl \in 0..MaxTime /\ c.at \in 0..MaxTime
    /\ c.aw \subseteq Handlers /\ c.fin \subseteq Handlers
    /\ c.req \subseteq c.reg /\ c.reg \subseteq Ops /\ c.expOps \subseteq c.reg
    /\ op \in [Ops -> {"idle", "run", "stuck"}]
    /\ opStart \in [Ops -> 0..MaxTime]
    /\ retry \in {"none", "pending"} /\ retryOp \in Ops \cup {"none"}
    /\ releaseQ \subseteq Handlers
    /\ texp \subseteq Ops

\* A stored handler is always on its way to being called: the coordinator holds its token,
\* or the token is claimed and queued for the MainActor, or no session has registered and
\* the registry's own timer covers it.
NoOrphanHandler ==
    \A h \in Stored : mgr = "none" \/ h \in c.aw \cup c.fin \cup releaseQ

\* No handler is still unclaimed TimerSlack after its deadline, or after the timer that
\* covers it was armed when that was later (a handler born expired, finding W1; a handler
\* handed from the registry's timer to the wake's at registration).  The absolute-deadline
\* and registry timers are what keep this; another timer being due does not excuse it.
HandlerClaimedWithinBudget ==
    \A h \in Stored : h \in releaseQ \/ now <= Max2(hdl[h], hat[h]) + TimerSlack

\* B13: an operation the wake is waiting for holds it for at most OpBudget from the
\* operation's start (from the wake's start for an operation the wake inherited), plus the
\* slack.  A leaked operation is claimed as timed out then, not at the absolute deadline.
OperationHoldBounded ==
    c.on => \A o \in c.req : now <= Max2(opStart[o] + OpBudget, c.at) + TimerSlack

\* B11: a handler waiting for finish-events is one the OS still owes finish-events for.
AwaitingHandlerIsOwedFinishEvents == c.aw # {} => finishOwed

\* B06: a startup blocked before the transport exists holds no wake, however late the
\* handler arrives.  No finish-events can ever come for it.
BlockedStartupHoldsNoHandler == (mgr = "blocked" /\ ~live) => ~c.on

\* B04: the gate is not released as drained while a delayed retry's successor is unregistered.
\* It is stated for a retry whose operation the coordinator has not marked expired.  A retry
\* scheduled while an expired operation lingers is marked expired at once and does not hold
\* the next wake: that case is finding W2 (NoDrainWithUnsettledWork), not B04.
GateHoldsForSuccessor == "retryUnregistered" \notin flags

\* B05: a release that is not a timeout never drops an operation the wake was waiting for.
LiveHoldsSurviveStartupBlock == "heldWorkDropped" \notin flags

\* A handler is called only after its own token was claimed (exact-token batches).
CalledOnlyAfterClaim == "earlyCall" \notin flags

\* Finding W1: a new handler never inherits the deadline of an already claimed batch.
NoStaleDeadline == "staleDeadline" \notin flags

\* Finding W1, the sharp case: the inherited deadline has already passed, so the new wake
\* is timed out the moment it is stored.
NoHandlerBornExpired == "bornExpired" \notin flags

\* Finding W2: a drained release leaves no operation in flight, except one that a
\* timed-out wake had already given up on.
NoDrainWithUnsettledWork == "unsettledWork" \notin flags

\* B06, B11, B13 together: every handler the app stored is called, or dies with the process.
HandlerEventuallyCalled ==
    \A h \in Handlers : (hs[h] = "stored") ~> (hs[h] \in {"called", "spent"})
=============================================================================
