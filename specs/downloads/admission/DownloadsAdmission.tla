------------------------- MODULE DownloadsAdmission -------------------------
(***************************************************************************)
(* The admission window of the downloads manager: lanes and caps, waiting  *)
(* rows, supervised starts, Pause All and Resume All, with process death.  *)
(*                                                                         *)
(* A row waits for a lane as `planned` (a first start) or as a paused or   *)
(* failed row with the `retryRequested` intent.  The pump grants waiting   *)
(* rows up to the caps; each grant is a supervised start that ends in      *)
(* finishAdmittedStart, which classifies what the start left behind.       *)
(*                                                                         *)
(*   User         UserPause, UserResume, PauseAll, ResumeAll               *)
(*   Coordinator  Pump (pumpAdmission), BackoffElapsed (the wake timer)    *)
(*   Supervisor   StartApply, StartSucceeds, StartNoWork, StartFails,      *)
(*                Finish (finishAdmittedStart)                             *)
(*   Transfer     TransferCompletes, TransferFails                         *)
(*   Backend      OutageBegins, OutageEnds                                 *)
(*   Crash        Crash drops every in-memory variable; Relaunch restarts; *)
(*                Recover is startup reconcile, after which admission opens*)
(*                                                                         *)
(* Durable state survives Crash; in-memory state does not.  See the        *)
(* VARIABLES block.  Each fix under test is a BOOLEAN constant: TRUE is    *)
(* the shipping behaviour.                                                 *)
(*                                                                         *)
(* Abstractions (README.md lists what is not covered):                     *)
(*  - Two lanes, staticFile and liveForward.  The server-preparation lane, *)
(*    lane switches (P4.5) and the render handoff (#414) are not modelled. *)
(*  - The simultaneous-downloads setting is the variable `cap`.  It starts *)
(*    at MaxTotal and the user may switch it to any value in CapChoices    *)
(*    while work is running.  Lowering it keeps the occupants: the         *)
(*    coordinator only wakes the pump (onLimitsChange).                    *)
(*  - ReuseRows are Emby Convert requests whose start finds a converted    *)
(*    source to reuse.  Until it starts, such a row is in the server-      *)
(*    preparation lane, which is not modelled as a cap (5, and outside the *)
(*    total).  It then hands off to the static lane without waiting for a  *)
(*    slot (handoffEmbyConvertedSource, waitsForTransferSlot: false).      *)
(*  - With AsyncCancel, a pause drops the app's tracking at once and the   *)
(*    daemon's task ends in a later step (getAllTasks, then cancel):       *)
(*    `cancelling` holds the tasks in between.                             *)
(*  - A pump pass is one step that grants any maximal set of eligible      *)
(*    requests that fits the caps.  The real order (user before automatic, *)
(*    oldest first) picks one of those sets, so request origin and age are *)
(*    not modelled.                                                        *)
(*  - Backoff is a flag per row (the request is not eligible yet) and one  *)
(*    wake timer.  The deferral count is capped at MaxDeferrals (the code  *)
(*    allows 6 transient failures).                                        *)
(*  - The pump is due when something asked for it (pumpFlag) or when the   *)
(*    occupancy signature changed (noteAdmissionOccupancy): the model      *)
(*    assumes refreshRecords follows every change.                         *)
(*  - A start is three steps: apply the grant, then negotiate, then        *)
(*    classify.  A backend outage ends negotiation without work.  A row    *)
(*    occupies a lane while it is supervised or has a transfer task.       *)
(*  - Pause ends the row's supervised start in the same step: the          *)
(*    generation fence and the reducer's guards make a stale continuation  *)
(*    inert, and the model does not keep it around.                        *)
(*  - A transfer is one task that completes or fails; finalization is one  *)
(*    step.  DownloadsSessionCore models that part.                        *)
(*  - Index persistence is atomic per action; the admission persistence    *)
(*    proof and write failures are not modelled.                           *)
(*                                                                         *)
(* Lifecycle and history change only through Reduce (DownloadsReducer.tla).*)
(* The hand-written exceptions are the "fix off" branches, which restore a *)
(* historical bug.                                                         *)
(***************************************************************************)
\* MODELS: Labstream/Capabilities/Downloads/Core/DownloadAdmissionCoordinator.swift
\* MODELS: Labstream/Capabilities/Downloads/Core/DownloadManager+Admission.swift
\* MODELS: PMSKit/Sources/PMSKit/Downloads/DownloadAdmissionPolicy.swift
\* MODELS: PMSKit/Sources/PMSKit/Downloads/DownloadQueueToolbarPolicy.swift
\* MODELS: PMSKit/Sources/PMSKit/Downloads/DownloadPausePolicy.swift
EXTENDS DownloadsReducer, TLC

CONSTANTS
    Rows,               \* download keys
    ForwardRows,        \* rows in the liveForward lane; the rest are in staticFile
    MaxTotal,           \* the simultaneous-downloads setting at the start (1..5)
    CapChoices,         \* values the user may switch the setting to at runtime
    ReuseRows,          \* static rows that are Emby Convert requests reusing a source
    AsyncCancel,        \* a pause's task cancel lands in a later step
    MutantStaleCap,     \* injected: grants use the highest cap seen, not the current one
    MutantPauseErasesIntent,
                        \* injected: pausing a waiting first start forgets its intent
    MaxDeferrals,       \* transient start failures a row may wait out (code: 6)
    FixB63,             \* Resume All queues parked rows for a lane instead of starting them
    FixB65,             \* Resume of a paused first start asks the window again; off, the
                        \*   generic Retry starts it at once, outside the window
    FixB66,             \* a granted start that left no work waits again (admissionDeferred)
    FixB67,             \* a backend outage defers a first start instead of failing it
    WakeAfterBackoff,   \* the pump arms a timer for the earliest backoff (FALSE: Mutant)
    FixRelaunchKeepsUnstarted,
                        \* A1 (#475): relaunch never fails a forward-only row with no task,
                        \* body or checkpoint; a granted one waits again (FALSE: Faithful-A1-off)
    BoundEnvironment,   \* TRUE: at most EnvBudget user/crash/fault steps (liveness runs)
    EnvBudget

ASSUME /\ ForwardRows \subseteq Rows
       /\ MaxTotal \in 1..5 /\ CapChoices \subseteq 1..5
       /\ ReuseRows \subseteq Rows \ ForwardRows
       /\ {AsyncCancel, MutantStaleCap, MutantPauseErasesIntent} \subseteq BOOLEAN
       /\ MaxDeferrals \in Nat
       /\ {FixB63, FixB65, FixB66, FixB67, WakeAfterBackoff,
           FixRelaunchKeepsUnstarted, BoundEnvironment} \subseteq BOOLEAN
       /\ EnvBudget \in Nat

StaticRows == Rows \ ForwardRows
\* Rows of one lane are interchangeable.
RowSymmetry == Permutations(ForwardRows) \cup Permutations(StaticRows \ ReuseRows)
                   \cup Permutations(ReuseRows)

VARIABLES
    \* Durable: the index row
    st,          \* [Rows -> reducer state]: lifecycle and history
    started,     \* [Rows -> BOOLEAN]: the row has start evidence (a transfer began)
    \* Durable: UserDefaults
    queuePaused, \* BOOLEAN: the Pause All gate
    cap,         \* 1..5: the simultaneous-downloads setting
    \* Durable: the URLSession daemon
    live,        \* [Rows -> BOOLEAN]: a transfer task the app tracks
    cancelling,  \* SUBSET Rows: a paused row's task whose cancel has not landed
    \* Environment
    outage,      \* BOOLEAN: the backend is unreachable
    \* In memory
    up,          \* BOOLEAN: the app process is alive
    recovered,   \* BOOLEAN: startup recovery finished; admission is open
    sup,         \* [Rows -> {"none", "first", "retry"}]: the supervised start and its kind
    phase,       \* [Rows -> {"none", "granted", "starting", "returned"}]: where that start is
    backoff,     \* [Rows -> BOOLEAN]: the row's request is not eligible yet
    deferrals,   \* [Rows -> 0..MaxDeferrals]: RequestState.deferrals, capped
    exempt,      \* SUBSET Rows: rows resumed by hand during Pause All
    pumpFlag,    \* BOOLEAN: an admission pass is scheduled
    lastSig,     \* the occupancy signature the last refresh saw
    timerArmed,  \* BOOLEAN: the backoff wake timer is set
    \* Ghost (read by properties only)
    held,        \* SUBSET Rows: rows whose last user word was Pause
    capHigh,     \* the highest value the setting has had
    budget       \* 0..EnvBudget

durableVars == <<st, started, queuePaused, cap, live, cancelling>>
memVars     == <<recovered, sup, phase, backoff, deferrals, exempt, pumpFlag, lastSig,
                 timerArmed>>
vars        == <<durableVars, outage, up, memVars, held, capHigh, budget>>

-----------------------------------------------------------------------------
(* Helpers                                                                 *)

LaneNames == {"staticFile", "liveForward"}
LaneRows(l) == IF l = "liveForward" THEN ForwardRows ELSE StaticRows
\* DownloadAdmissionLimits.maximumByLane, for a setting of n.
LaneCapOf(l, n) == IF l = "liveForward" THEN 1
                   ELSE IF n > 1 THEN n - 1 ELSE 1
\* coordinator.limits: read at every gate.
GateCap == IF MutantStaleCap THEN capHigh ELSE cap
LaneCap(l) == LaneCapOf(l, GateCap)

\* The event applied when the reducer accepts it; otherwise the row is unchanged
\* (applyLifecycleEvent returns false).
Apply(s, e) == LET t == Reduce(s, e, NoFacts) IN IF IsApplied(t) THEN t.state ELSE s

\* isWaitingForAdmission
WaitingIn(s) ==
    \/ s.lifecycle = "planned"
    \/ s.lifecycle \in {"paused", "failed"} /\ s.admissionIntent = "retryRequested"
Waiting(r) == WaitingIn(st[r])

\* occupiesAdmissionLane: an active-looking row with live work behind it.
Occupies(r) == st[r].lifecycle \in Active /\ live[r]

\* admissionOccupants: observed work plus supervised starts.
OccupantsOf(supf) == {r \in Rows : Occupies(r) \/ supf[r] # "none"}
Occupants == OccupantsOf(sup)

\* A reuse row that has not started is in the server-preparation lane: it is
\* not counted in the total or in the static lane.
InPrepLane(r, startedf) == r \in ReuseRows /\ ~startedf[r]
Counted(S, startedf) == {r \in S : ~InPrepLane(r, startedf)}

\* DownloadAdmissionPolicy.grants as a predicate: G can start beside `occ`.
\* Occupants are counted as observed, over a cap or not: nothing new enters a
\* lane, or the total, that is at or over its cap.
Fits(occ, G) ==
    LET C == Counted(occ, started)
        Gc == Counted(G, started)
    IN /\ Gc = {} \/ Cardinality(C \cup Gc) <= GateCap
       /\ \A l \in LaneNames :
             Gc \cap LaneRows(l) = {}
                \/ Cardinality((C \cup Gc) \cap LaneRows(l)) <= LaneCap(l)

\* The requests a pump pass considers.
Eligible ==
    {r \in Rows : /\ Waiting(r) /\ sup[r] = "none" /\ ~backoff[r]
                  /\ (~queuePaused \/ r \in exempt)}

\* noteAdmissionOccupancy's signature.
SigOf(supf, stf) ==
    <<{r \in Rows : (stf[r].lifecycle \in Active /\ live[r]) \/ supf[r] # "none"},
      {r \in Rows : WaitingIn(stf[r])}>>
PumpDue == pumpFlag \/ SigOf(sup, st) # lastSig

\* launchAdmittedStart: a planned row without a retry intent is a first start.
KindOf(r) == IF st[r].lifecycle = "planned" /\ st[r].admissionIntent # "retryRequested"
                THEN "first" ELSE "retry"

\* Rows Pause acts on: DownloadPausePolicy.shouldPauseDuringQueuePause, or supervised.
Pausable(r) == Waiting(r) \/ st[r].lifecycle \in Active \/ sup[r] # "none"

\* pause(record:): the row after a user pause.
PausedSt(r) ==
    LET s == st[r] IN
    IF Waiting(r) THEN
        IF s.lifecycle = "planned" THEN
            IF ~MutantPauseErasesIntent THEN Apply(s, EvPause("user"))
            \* Injected: the pause forgets that the row was waiting for its first start.
            ELSE RPause([s EXCEPT !.admissionIntent = "none"], "user")
        ELSE Apply(s, Ev("admissionWithdrawn"))
    ELSE IF s.lifecycle \in Active THEN Apply(s, EvPause("user"))
    ELSE s

\* The user or a fault takes a step; liveness runs bound how many.
Spend == IF BoundEnvironment THEN budget > 0 /\ budget' = budget - 1
                             ELSE UNCHANGED budget

-----------------------------------------------------------------------------
TypeOK ==
    /\ \A r \in Rows :
          /\ st[r].lifecycle \in Lifecycles
          /\ st[r].pauseCause \in PauseCauses
          /\ st[r].lastFailure \in FailureReasons
          /\ st[r].admissionIntent \in AdmissionIntents
    /\ started \in [Rows -> BOOLEAN]
    /\ queuePaused \in BOOLEAN
    /\ cap \in 1..5 /\ capHigh \in 1..5 /\ cap <= capHigh
    /\ live \in [Rows -> BOOLEAN]
    /\ cancelling \subseteq Rows
    /\ outage \in BOOLEAN
    /\ up \in BOOLEAN
    /\ recovered \in BOOLEAN
    /\ sup \in [Rows -> {"none", "first", "retry"}]
    /\ phase \in [Rows -> {"none", "granted", "starting", "returned"}]
    /\ \A r \in Rows : (sup[r] = "none") = (phase[r] = "none")
    /\ backoff \in [Rows -> BOOLEAN]
    /\ deferrals \in [Rows -> 0..MaxDeferrals]
    /\ exempt \subseteq Rows
    /\ pumpFlag \in BOOLEAN
    /\ timerArmed \in BOOLEAN
    /\ held \subseteq Rows
    /\ budget \in 0..EnvBudget

\* Every row is a committed season episode waiting for its first start.
Init ==
    /\ st = [r \in Rows |->
                [InitialState("planned") EXCEPT !.admissionIntent = "seasonPlanned"]]
    /\ started = Const(Rows, FALSE)
    /\ queuePaused = FALSE
    /\ cap = MaxTotal /\ capHigh = MaxTotal
    /\ live = Const(Rows, FALSE)
    /\ cancelling = {}
    /\ outage = FALSE
    /\ up = TRUE
    /\ recovered = TRUE
    /\ sup = Const(Rows, "none")
    /\ phase = Const(Rows, "none")
    /\ backoff = Const(Rows, FALSE)
    /\ deferrals = Const(Rows, 0)
    /\ exempt = {}
    /\ pumpFlag = TRUE
    /\ lastSig = <<{}, {}>>
    /\ timerArmed = FALSE
    /\ held = {}
    /\ budget = IF BoundEnvironment THEN EnvBudget ELSE 0

-----------------------------------------------------------------------------
(* User                                                                    *)

\* pause(record:).  withdrawAdmission ends the supervised start and forgets the
\* request and the exemption; session.pause cancels the task.
UserPause(r) ==
    /\ up /\ Pausable(r) /\ Spend
    /\ st' = Upd(st, r, PausedSt(r))
    /\ sup' = Upd(sup, r, "none") /\ phase' = Upd(phase, r, "none")
    /\ backoff' = Upd(backoff, r, FALSE) /\ deferrals' = Upd(deferrals, r, 0)
    /\ exempt' = exempt \ {r}
    /\ live' = Upd(live, r, FALSE)
    \* session.pause drops the tracking now; the daemon's task ends later.
    /\ cancelling' = IF AsyncCancel /\ live[r] THEN cancelling \cup {r} ELSE cancelling
    /\ held' = held \cup {r}
    /\ UNCHANGED <<started, queuePaused, cap, outage, up, recovered, pumpFlag, lastSig,
                   timerArmed, capHigh>>

\* admissionHasRoom, for a row the user acts on.
HasRoom(r, isExempt) ==
    /\ recovered /\ sup[r] = "none"
    /\ ~queuePaused \/ isExempt
    /\ Fits(Occupants \ {r}, {r})

\* admitRowAction: Resume or Retry on a parked row.
UserResume(r) ==
    /\ up /\ st[r].lifecycle \in {"paused", "failed"} /\ sup[r] = "none" /\ Spend
    /\ exempt' = IF queuePaused THEN exempt \cup {r} ELSE exempt
    /\ held' = held \ {r}
    /\ IF st[r].admissionIntent = "seasonPlanned" /\ FixB65 THEN
           \* A paused first start goes back to `planned` and waits for the pump.
           /\ st' = Upd(st, r, Apply(st[r], EvIntent("admissionRequested", "seasonPlanned")))
           /\ pumpFlag' = TRUE
           /\ UNCHANGED <<sup, phase, backoff, deferrals>>
       ELSE IF HasRoom(r, queuePaused)
               \* B65 off: the pending first start is tracked apart from the status,
               \* and the generic Retry starts the row without asking the window.
               \/ (~FixB65 /\ st[r].admissionIntent = "seasonPlanned") THEN
           /\ sup' = Upd(sup, r, "retry") /\ phase' = Upd(phase, r, "granted")
           /\ backoff' = Upd(backoff, r, FALSE) /\ deferrals' = Upd(deferrals, r, 0)
           /\ UNCHANGED <<st, pumpFlag>>
       ELSE
           /\ st' = Upd(st, r, Apply(st[r], EvIntent("admissionRequested", "retryRequested")))
           /\ pumpFlag' = TRUE
           /\ UNCHANGED <<sup, phase, backoff, deferrals>>
    /\ UNCHANGED <<started, queuePaused, cap, live, cancelling, outage, up, recovered,
                   lastSig, timerArmed, capHigh>>

\* DownloadQueueToolbarPolicy.action
HasActiveWork == \E r \in Rows : st[r].lifecycle \in Active \cup {"planned"}
HasIdleWork == \E r \in Rows : st[r].lifecycle \in {"paused", "failed"}

\* pauseQueue: the gate, then pause(record:) for every pausable row.
PauseAll ==
    /\ up /\ HasActiveWork /\ Spend
    /\ queuePaused' = TRUE
    /\ exempt' = {}
    /\ st' = [r \in Rows |-> IF Pausable(r) THEN PausedSt(r) ELSE st[r]]
    /\ sup' = Const(Rows, "none") /\ phase' = Const(Rows, "none")
    /\ backoff' = [r \in Rows |-> IF Pausable(r) THEN FALSE ELSE backoff[r]]
    /\ deferrals' = [r \in Rows |-> IF Pausable(r) THEN 0 ELSE deferrals[r]]
    /\ live' = [r \in Rows |-> IF Pausable(r) THEN FALSE ELSE live[r]]
    /\ cancelling' = IF AsyncCancel
                        THEN cancelling \cup {r \in Rows : Pausable(r) /\ live[r]}
                        ELSE cancelling
    /\ held' = held \cup {r \in Rows : Pausable(r)}
    /\ UNCHANGED <<started, cap, outage, up, recovered, pumpFlag, lastSig, timerArmed,
                   capHigh>>

\* resumeQueue: every parked row asks for a lane (B63), then one admission pass.
ResumeAll ==
    LET parked == {r \in Rows : st[r].lifecycle \in {"paused", "failed"}} IN
    /\ up /\ ~HasActiveWork /\ (HasIdleWork \/ queuePaused) /\ Spend
    /\ queuePaused' = FALSE
    /\ exempt' = {}
    /\ held' = held \ parked
    /\ IF FixB63 THEN
           /\ st' = [r \in Rows |->
                       IF r \in parked
                          THEN Apply(st[r], EvIntent("admissionRequested",
                                   IF st[r].admissionIntent = "seasonPlanned"
                                      THEN "seasonPlanned" ELSE "retryRequested"))
                          ELSE st[r]]
           /\ pumpFlag' = TRUE
           /\ UNCHANGED <<sup, phase>>
       ELSE
           \* B63 off: every parked row starts at once, outside the window.
           /\ sup' = [r \in Rows |-> IF r \in parked THEN "retry" ELSE sup[r]]
           /\ phase' = [r \in Rows |-> IF r \in parked THEN "granted" ELSE phase[r]]
           /\ UNCHANGED <<st, pumpFlag>>
    /\ UNCHANGED <<started, cap, live, cancelling, outage, up, recovered, backoff,
                   deferrals, lastSig, timerArmed, capHigh>>

-----------------------------------------------------------------------------
(* Coordinator                                                             *)

\* pumpAdmission.  Before recovery it grants nothing; after, it starts a maximal
\* set of eligible requests that fits, and arms the wake timer for any backoff.
PumpPass(G) ==
    /\ up /\ PumpDue
    /\ pumpFlag' = FALSE
    /\ IF ~recovered THEN
           /\ G = {}
           /\ lastSig' = SigOf(sup, st)
           /\ UNCHANGED <<sup, phase, timerArmed>>
       ELSE
           /\ G \subseteq Eligible
           /\ Fits(Occupants, G)
           /\ \A r \in Eligible \ G : ~Fits(Occupants, G \cup {r})
           /\ sup' = [r \in Rows |-> IF r \in G THEN KindOf(r) ELSE sup[r]]
           /\ phase' = [r \in Rows |-> IF r \in G THEN "granted" ELSE phase[r]]
           /\ lastSig' = SigOf(sup', st)
           /\ timerArmed' = (WakeAfterBackoff /\ \E r \in Rows : backoff[r])
    /\ UNCHANGED <<durableVars, outage, up, recovered, backoff, deferrals, exempt, held, capHigh,
                   budget>>

Pump == \E G \in SUBSET Rows : PumpPass(G)

\* The backoff of one row ends and the wake timer asks for a pass.
BackoffElapsed(r) ==
    /\ up /\ timerArmed /\ backoff[r]
    /\ backoff' = Upd(backoff, r, FALSE)
    /\ pumpFlag' = TRUE
    /\ UNCHANGED <<durableVars, outage, up, recovered, sup, phase, deferrals, exempt,
                   lastSig, timerArmed, held, capHigh, budget>>

-----------------------------------------------------------------------------
(* Start supervisor                                                        *)

\* The first step of a granted start.  A first start applies admissionGranted
\* (runFirstStart).  A retry promotes the parked row (retryRecordAsync); a static
\* row without a backend session is parked or failed instead
\* (deferStaticRangeResume) and the start returns.
StartApply(r) ==
    /\ up /\ phase[r] = "granted"
    /\ LET s == st[r]
           noSession == sup[r] = "retry" /\ outage /\ r \in StaticRows
           e == IF sup[r] = "first" THEN Ev("admissionGranted")
                ELSE IF ~noSession THEN EvRetry("freshAttempt")
                ELSE IF started[r] THEN EvBackendUnavailable("awaitingSession")
                ELSE EvReason("transferFailed", "auth")
           t == Reduce(s, e, NoFacts)
       IN /\ st' = Upd(st, r, IF IsApplied(t) THEN t.state ELSE s)
          /\ phase' = Upd(phase, r, IF IsApplied(t) /\ ~noSession
                                       THEN "starting" ELSE "returned")
    /\ UNCHANGED <<started, queuePaused, cap, live, cancelling, outage, up, recovered, sup, backoff,
                   deferrals, exempt, pumpFlag, lastSig, timerArmed, held, capHigh, budget>>

\* Negotiation succeeded and the transfer task exists.
StartSucceeds(r) ==
    /\ up /\ phase[r] = "starting" /\ ~outage
    /\ LET t == Reduce(st[r], Ev("transferStarted"), NoFacts)
       IN /\ IsApplied(t)
          /\ st' = Upd(st, r, t.state)
    /\ live' = Upd(live, r, TRUE)
    /\ started' = Upd(started, r, TRUE)
    /\ phase' = Upd(phase, r, "returned")
    /\ UNCHANGED <<queuePaused, cap, cancelling, outage, up, recovered, sup, backoff, deferrals, exempt,
                   pumpFlag, lastSig, timerArmed, held, capHigh, budget>>

\* The backend is unreachable: the start returns before any work exists
\* (startPlannedRecord's refresh outage).
StartNoWork(r) ==
    /\ up /\ phase[r] = "starting" /\ outage
    /\ st' = Upd(st, r,
                 IF FixB67 \/ sup[r] # "first" THEN st[r]
                 \* B67 off: the outage fails the first start.
                 ELSE Apply(st[r], EvReason("transferFailed", "server")))
    /\ phase' = Upd(phase, r, "returned")
    /\ UNCHANGED <<started, queuePaused, cap, live, cancelling, outage, up, recovered, sup, backoff,
                   deferrals, exempt, pumpFlag, lastSig, timerArmed, held, capHigh, budget>>

\* A reachable backend refuses the start: transiently (network) or for good
\* (sourceMissing).
StartFails(r, reason) ==
    /\ up /\ phase[r] = "starting" /\ ~outage /\ Spend
    /\ st' = Upd(st, r, Apply(st[r], EvReason("transferFailed", reason)))
    /\ phase' = Upd(phase, r, "returned")
    /\ UNCHANGED <<started, queuePaused, cap, live, cancelling, outage, up, recovered, sup, backoff,
                   deferrals, exempt, pumpFlag, lastSig, timerArmed, held, capHigh>>

\* finishAdmittedStart: what the row looks like once the start's work returned.
\* "defer" records a deferral (backoff); "clear" forgets the request.
FinishOutcome(r) ==
    LET s == st[r]
        L == s.lifecycle
        asked == Apply(s, EvIntent("admissionRequested", "retryRequested"))
        withdrawn == IF s.admissionIntent # "none"
                        THEN Apply(s, Ev("admissionWithdrawn")) ELSE s
    IN
    CASE L \in {"serverPrep", "transferring", "finalizing", "complete", "unverified"} ->
            [state |-> s, kind |-> "clear"]
      [] L = "admitted" ->
            (IF Occupies(r) THEN [state |-> s, kind |-> "clear"]
             \* B66 off: the request is forgotten and the row stays queued with no work.
             ELSE IF ~FixB66 THEN [state |-> s, kind |-> "clear"]
             ELSE IF sup[r] = "first" THEN
                 [state |-> Apply(s, EvIntent("admissionDeferred", "seasonPlanned")),
                  kind |-> "defer"]
             ELSE
                 [state |-> Apply(Apply(s, EvBackendUnavailable("deferredResume")),
                                  EvIntent("admissionRequested", "retryRequested")),
                  kind |-> "defer"])
      [] L = "planned" -> [state |-> s, kind |-> "defer"]
      [] L = "paused" ->
            (IF s.pauseCause = "user" THEN [state |-> withdrawn, kind |-> "clear"]
             ELSE [state |-> IF s.admissionIntent = "retryRequested" THEN s ELSE asked,
                   kind |-> "defer"])
      [] L = "failed" ->
            (IF /\ FixB67
                /\ s.lastFailure \in {"server", "network"}
                /\ deferrals[r] < MaxDeferrals
                THEN [state |-> asked, kind |-> "defer"]
                ELSE [state |-> withdrawn, kind |-> "clear"])

Finish(r) ==
    /\ up /\ phase[r] = "returned"
    /\ LET out == FinishOutcome(r)
       IN /\ st' = Upd(st, r, out.state)
          /\ backoff' = Upd(backoff, r, out.kind = "defer")
          /\ deferrals' = Upd(deferrals, r,
                              IF out.kind = "clear" THEN 0
                              ELSE IF deferrals[r] < MaxDeferrals THEN deferrals[r] + 1
                              ELSE deferrals[r])
    /\ sup' = Upd(sup, r, "none") /\ phase' = Upd(phase, r, "none")
    /\ pumpFlag' = TRUE
    /\ UNCHANGED <<started, queuePaused, cap, live, cancelling, outage, up, recovered, exempt, lastSig,
                   timerArmed, held, capHigh, budget>>

-----------------------------------------------------------------------------
(* Transfer and backend                                                    *)

\* The transfer finishes, validates and publishes (three reducer events).
TransferCompletes(r) ==
    /\ up /\ live[r] /\ st[r].lifecycle = "transferring"
    /\ LET t1 == Reduce(st[r], Ev("bodyAtWorking"), NoFacts)
           t2 == Reduce(t1.state, EvFinalize(1, "complete", "source"), NoFacts)
           t3 == Reduce(t2.state, EvPromotion("promotionCommitted", "complete"), NoFacts)
       IN /\ IsApplied(t1) /\ IsApplied(t2) /\ IsApplied(t3)
          /\ st' = Upd(st, r, t3.state)
    /\ live' = Upd(live, r, FALSE)
    /\ UNCHANGED <<started, queuePaused, cap, cancelling, outage, up, memVars, held,
                   capHigh, budget>>

TransferFails(r) ==
    /\ up /\ live[r] /\ st[r].lifecycle = "transferring" /\ Spend
    /\ st' = Upd(st, r, Apply(st[r], EvReason("transferFailed", "network")))
    /\ live' = Upd(live, r, FALSE)
    /\ UNCHANGED <<started, queuePaused, cap, cancelling, outage, up, memVars, held,
                   capHigh>>

\* The user changes the simultaneous-downloads setting.  The coordinator
\* observes the preference and only wakes admission: running work,
\* generations and requests are untouched.
SetCap(n) ==
    /\ up /\ n \in CapChoices /\ n # cap /\ Spend
    /\ cap' = n
    /\ capHigh' = IF n > capHigh THEN n ELSE capHigh
    /\ pumpFlag' = TRUE
    /\ UNCHANGED <<st, started, queuePaused, live, cancelling, outage, up, recovered, sup,
                   phase, backoff, deferrals, exempt, lastSig, timerArmed, held>>

\* The daemon ends a paused row's task (the getAllTasks completion's cancel).
CancelLands(r) ==
    /\ r \in cancelling
    /\ cancelling' = cancelling \ {r}
    /\ UNCHANGED <<st, started, queuePaused, cap, live, outage, up, memVars, held, capHigh,
                   budget>>

OutageBegins ==
    /\ ~outage /\ Spend
    /\ outage' = TRUE
    /\ UNCHANGED <<durableVars, up, memVars, held, capHigh>>

OutageEnds ==
    /\ outage
    /\ outage' = FALSE
    /\ UNCHANGED <<durableVars, up, memVars, held, capHigh, budget>>

-----------------------------------------------------------------------------
(* Crash and relaunch                                                      *)

Crash ==
    /\ up /\ Spend
    /\ up' = FALSE
    /\ recovered' = FALSE
    /\ sup' = Const(Rows, "none") /\ phase' = Const(Rows, "none")
    /\ backoff' = Const(Rows, FALSE) /\ deferrals' = Const(Rows, 0)
    /\ exempt' = {}
    /\ pumpFlag' = FALSE
    /\ lastSig' = <<{}, {}>>
    /\ timerArmed' = FALSE
    /\ UNCHANGED <<durableVars, outage, held, capHigh>>

Relaunch ==
    /\ ~up
    /\ up' = TRUE
    /\ UNCHANGED <<durableVars, outage, memVars, held, capHigh, budget>>

\* DownloadStore.observeLifecycleFacts, as far as this model has the facts.
RelaunchFacts(r) ==
    Fx(IF r \in ForwardRows THEN "forwardOnly" ELSE "staticRange", FALSE,
       IF r \in StaticRows /\ started[r] THEN "partial" ELSE "none",
       IF st[r].lifecycle \in Playable THEN "published" ELSE "none",
       FALSE, FALSE, live[r], TRUE)

RecoveredSt(r) ==
    LET s == st[r]
        t == Reduce(s, Ev("relaunchObserved"), RelaunchFacts(r))
    IN
    \* A1 off: relaunch fails a forward-only row with no task, body or checkpoint
    \* (the reducer before #475).  On, the reducer requeues a granted one and keeps
    \* a paused one paused.
    IF /\ ~FixRelaunchKeepsUnstarted /\ r \in ForwardRows /\ ~live[r]
       /\ s.lifecycle \in {"admitted", "paused"}
       THEN RRelaunchSet(s, "failed", "none", "network")
    ELSE IF IsApplied(t) THEN t.state ELSE s

\* Startup reconcile (reconcileOnWorker), then admission opens and the pump runs.
Recover ==
    /\ up /\ ~recovered
    /\ st' = [r \in Rows |-> RecoveredSt(r)]
    /\ recovered' = TRUE
    /\ pumpFlag' = TRUE
    /\ UNCHANGED <<started, queuePaused, cap, live, cancelling, outage, up, sup, phase, backoff, deferrals,
                   exempt, lastSig, timerArmed, held, capHigh, budget>>

-----------------------------------------------------------------------------
Next ==
    \/ PauseAll \/ ResumeAll \/ Pump
    \/ OutageBegins \/ OutageEnds
    \/ \E n \in CapChoices : SetCap(n)
    \/ Crash \/ Relaunch \/ Recover
    \/ \E r \in Rows :
          \/ UserPause(r) \/ UserResume(r)
          \/ CancelLands(r)
          \/ BackoffElapsed(r)
          \/ StartApply(r) \/ StartSucceeds(r) \/ StartNoWork(r) \/ Finish(r)
          \/ \E reason \in {"network", "sourceMissing"} : StartFails(r, reason)
          \/ TransferCompletes(r) \/ TransferFails(r)

Spec == Init /\ [][Next]_vars

\* Liveness assumptions: the app relaunches and recovers, a scheduled pass runs,
\* timers fire, started work proceeds, and an outage ends.
Fairness ==
    /\ WF_vars(Relaunch) /\ WF_vars(Recover) /\ WF_vars(Pump) /\ WF_vars(OutageEnds)
    /\ \A r \in Rows :
          /\ WF_vars(BackoffElapsed(r)) /\ WF_vars(CancelLands(r))
          /\ WF_vars(StartApply(r)) /\ WF_vars(StartSucceeds(r))
          /\ WF_vars(StartNoWork(r)) /\ WF_vars(Finish(r))
          /\ WF_vars(TransferCompletes(r))

FairSpec == Spec /\ Fairness

-----------------------------------------------------------------------------
(* Safety                                                                  *)

\* Observed occupancy for a given state: what the pump counts.
CountedOccupants(stf, livef, supf, startedf) ==
    Counted({r \in Rows : (stf[r].lifecycle \in Active /\ livef[r]) \/ supf[r] # "none"},
            startedf)

\* B63, B65: a new grant respects observed occupancy.  In every step that
\* begins a supervised start, the total and each lane that received a grant
\* are within the current cap afterwards, counting every occupant there is.
\* This is the guarantee the code makes (DownloadAdmissionPolicy.grants): it
\* holds from states that are already over a cap, where it means no grant.
GrantRespectsObservedOccupancy ==
    [][LET G == Counted({r \in Rows : sup[r] = "none" /\ sup'[r] # "none"}, started)
           C == CountedOccupants(st', live', sup', started')
       IN G # {} =>
            /\ Cardinality(C) <= cap'
            /\ \A l \in LaneNames :
                  G \cap LaneRows(l) # {}
                     => Cardinality(C \cap LaneRows(l)) <= LaneCapOf(l, cap')]_vars

\* What can put occupancy over the current cap: the setting was higher, or a
\* reuse row handed off into the static lane without a slot.  Occupancy never
\* exceeds the highest setting there has been plus those handoffs.
ReusedIn == {r \in ReuseRows : started[r] /\ (sup[r] # "none" \/ Occupies(r))}
OccupancyBoundedByHistory ==
    LET C == CountedOccupants(st, live, sup, started) IN
    /\ Cardinality(C) <= capHigh + Cardinality(ReusedIn)
    /\ Cardinality(C \cap LaneRows("liveForward")) <= 1
    /\ Cardinality(C \cap LaneRows("staticFile"))
          <= LaneCapOf("staticFile", capHigh) + Cardinality(ReusedIn)

\* Occupancy is within the current cap.  True only while the setting never
\* changes and no reuse row hands off: checked by the configs that fix both,
\* and violated by design otherwise (Current-CapLowered, Current-EmbyReuse).
LaneCapRespected ==
    LET C == CountedOccupants(st, live, sup, started) IN
    /\ Cardinality(C) <= cap
    /\ \A l \in LaneNames : Cardinality(C \cap LaneRows(l)) <= LaneCapOf(l, cap)

\* The tasks the daemon holds: the tracked ones are bounded like occupancy,
\* and each pause whose cancel has not landed adds one more.
DaemonTasksBounded ==
    Cardinality({r \in Rows : live[r]} \cup cancelling)
        <= capHigh + Cardinality(ReusedIn) + Cardinality(cancelling)

\* The same without the allowance, for the tracked tasks only.  True while the
\* setting never changes and no reuse row hands off.
LiveTasksWithinCap ==
    /\ Cardinality({r \in Rows : live[r]}) <= cap
    /\ \A l \in LaneNames : Cardinality({r \in LaneRows(l) : live[r]}) <= LaneCapOf(l, cap)

\* B66: once recovery is done, a queued (admitted) row always has a supervised
\* start behind it.  Nothing else would ever move it.
NoOrphanQueued ==
    up /\ recovered =>
        \A r \in Rows : st[r].lifecycle = "admitted" => sup[r] # "none"

\* Nothing is granted before startup recovery finished.
NothingGrantedBeforeRecovery == ~recovered => \A r \in Rows : sup[r] = "none"

\* During Pause All only a row the user resumed by hand may start.
QueuePauseHolds == queuePaused => \A r \in Rows : sup[r] # "none" => r \in exempt

\* Exemptions exist only while the queue is paused.
ExemptOnlyWhilePaused == exempt # {} => queuePaused

\* A row the user paused does not wait for a lane, is not being started and has
\* no active work, until the user resumes it: the pause withdrew a waiting retry.
UserPauseHolds ==
    \A r \in held :
        /\ ~Waiting(r) /\ sup[r] = "none" /\ st[r].lifecycle \notin Active /\ ~live[r]

\* B65: a first start goes through the window.  A row that still carries the
\* first-start intent is only ever started as a first start, by the pump.
FirstStartGoesThroughWindow ==
    [][\A r \in Rows :
          (sup[r] = "none" /\ sup'[r] # "none" /\ st[r].admissionIntent = "seasonPlanned")
             => sup'[r] = "first"]_vars

\* A pause that parks a waiting first start keeps its intent, so Resume
\* re-requests the same first start through the window.
PauseKeepsFirstStart ==
    [][\A r \in Rows :
          /\ st[r].lifecycle = "planned" /\ st[r].admissionIntent = "seasonPlanned"
          /\ st'[r].lifecycle = "paused"
          => st'[r].admissionIntent = "seasonPlanned"]_vars

\* B67: while the backend is unreachable, a first start never fails its row.
OutageDefersFirstStart ==
    [][\A r \in Rows :
          outage /\ sup[r] = "first" /\ phase[r] = "starting"
          => st'[r].lifecycle # "failed"]_vars

\* A1 (#475): startup recovery never fails a forward-only row that has no start
\* evidence.  Faithful-A1-off restores the old failure.
RelaunchKeepsUnstartedRow ==
    [][\A r \in ForwardRows :
          /\ ~recovered /\ recovered' /\ ~started[r] /\ ~live[r]
          /\ st[r].lifecycle \in {"admitted", "paused"}
          => st'[r].lifecycle # "failed"]_vars

-----------------------------------------------------------------------------
(* Liveness (FairSpec)                                                     *)

\* No row waits forever: a waiting row outside Pause All is eventually granted
\* (or the user parks it).
WaitingRowIsServed ==
    \A r \in Rows : (Waiting(r) /\ ~queuePaused) ~> ~Waiting(r)

\* A supervised start always ends.
SupervisedStartEnds ==
    \A r \in Rows : (sup[r] # "none") ~> (sup[r] = "none")
=============================================================================
