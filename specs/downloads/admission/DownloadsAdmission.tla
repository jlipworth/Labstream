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
(*  - The simultaneous-downloads setting is the constant MaxTotal.         *)
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
    MaxTotal,           \* the simultaneous-downloads setting (1..5)
    MaxDeferrals,       \* transient start failures a row may wait out (code: 6)
    FixB63,             \* Resume All queues parked rows for a lane instead of starting them
    FixB65,             \* pausing a waiting first start keeps its intent; Resume re-requests it
    FixB66,             \* a granted start that left no work waits again (admissionDeferred)
    FixB67,             \* a backend outage defers a first start instead of failing it
    WakeAfterBackoff,   \* the pump arms a timer for the earliest backoff (FALSE: Mutant)
    FixRelaunchKeepsUnstarted,
                        \* PROPOSED (finding A1): relaunch never fails a row that has no
                        \* start evidence; a granted one waits again
    BoundEnvironment,   \* TRUE: at most EnvBudget user/crash/fault steps (liveness runs)
    EnvBudget

ASSUME /\ ForwardRows \subseteq Rows
       /\ MaxTotal \in 1..5
       /\ MaxDeferrals \in Nat
       /\ {FixB63, FixB65, FixB66, FixB67, WakeAfterBackoff,
           FixRelaunchKeepsUnstarted, BoundEnvironment} \subseteq BOOLEAN
       /\ EnvBudget \in Nat

StaticRows == Rows \ ForwardRows
\* Rows of one lane are interchangeable.
RowSymmetry == Permutations(ForwardRows) \cup Permutations(StaticRows)

VARIABLES
    \* Durable: the index row
    st,          \* [Rows -> reducer state]: lifecycle and history
    started,     \* [Rows -> BOOLEAN]: the row has start evidence (a transfer began)
    \* Durable: UserDefaults
    queuePaused, \* BOOLEAN: the Pause All gate
    \* Durable: the URLSession daemon
    live,        \* [Rows -> BOOLEAN]: a transfer task exists
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
    budget       \* 0..EnvBudget

durableVars == <<st, started, queuePaused, live>>
memVars     == <<recovered, sup, phase, backoff, deferrals, exempt, pumpFlag, lastSig,
                 timerArmed>>
vars        == <<durableVars, outage, up, memVars, held, budget>>

-----------------------------------------------------------------------------
(* Helpers                                                                 *)

LaneNames == {"staticFile", "liveForward"}
LaneRows(l) == IF l = "liveForward" THEN ForwardRows ELSE StaticRows
\* DownloadAdmissionLimits.maximumByLane
LaneCap(l) == IF l = "liveForward" THEN 1
              ELSE IF MaxTotal > 1 THEN MaxTotal - 1 ELSE 1

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

\* DownloadAdmissionPolicy.grants as a predicate: G can start beside `occ`.
Fits(occ, G) ==
    /\ G = {} \/ Cardinality(occ \cup G) <= MaxTotal
    /\ \A l \in LaneNames :
          G \cap LaneRows(l) = {} \/ Cardinality((occ \cup G) \cap LaneRows(l)) <= LaneCap(l)

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
            IF FixB65 THEN Apply(s, EvPause("user"))
            \* B65 off: the pause forgets that the row was waiting for its first start.
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
    /\ live \in [Rows -> BOOLEAN]
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
    /\ live = Const(Rows, FALSE)
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
    /\ held' = held \cup {r}
    /\ UNCHANGED <<started, queuePaused, outage, up, recovered, pumpFlag, lastSig,
                   timerArmed>>

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
    /\ IF st[r].admissionIntent = "seasonPlanned" THEN
           \* A paused first start goes back to `planned` and waits for the pump.
           /\ st' = Upd(st, r, Apply(st[r], EvIntent("admissionRequested", "seasonPlanned")))
           /\ pumpFlag' = TRUE
           /\ UNCHANGED <<sup, phase, backoff, deferrals>>
       ELSE IF HasRoom(r, queuePaused)
               \* B65 off: Resume starts the row without asking the window.
               \/ (~FixB65 /\ st[r].admissionIntent = "none") THEN
           /\ sup' = Upd(sup, r, "retry") /\ phase' = Upd(phase, r, "granted")
           /\ backoff' = Upd(backoff, r, FALSE) /\ deferrals' = Upd(deferrals, r, 0)
           /\ UNCHANGED <<st, pumpFlag>>
       ELSE
           /\ st' = Upd(st, r, Apply(st[r], EvIntent("admissionRequested", "retryRequested")))
           /\ pumpFlag' = TRUE
           /\ UNCHANGED <<sup, phase, backoff, deferrals>>
    /\ UNCHANGED <<started, queuePaused, live, outage, up, recovered, lastSig, timerArmed>>

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
    /\ held' = held \cup {r \in Rows : Pausable(r)}
    /\ UNCHANGED <<started, outage, up, recovered, pumpFlag, lastSig, timerArmed>>

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
    /\ UNCHANGED <<started, live, outage, up, recovered, backoff, deferrals, lastSig,
                   timerArmed>>

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
    /\ UNCHANGED <<durableVars, outage, up, recovered, backoff, deferrals, exempt, held,
                   budget>>

Pump == \E G \in SUBSET Rows : PumpPass(G)

\* The backoff of one row ends and the wake timer asks for a pass.
BackoffElapsed(r) ==
    /\ up /\ timerArmed /\ backoff[r]
    /\ backoff' = Upd(backoff, r, FALSE)
    /\ pumpFlag' = TRUE
    /\ UNCHANGED <<durableVars, outage, up, recovered, sup, phase, deferrals, exempt,
                   lastSig, timerArmed, held, budget>>

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
    /\ UNCHANGED <<started, queuePaused, live, outage, up, recovered, sup, backoff,
                   deferrals, exempt, pumpFlag, lastSig, timerArmed, held, budget>>

\* Negotiation succeeded and the transfer task exists.
StartSucceeds(r) ==
    /\ up /\ phase[r] = "starting" /\ ~outage
    /\ LET t == Reduce(st[r], Ev("transferStarted"), NoFacts)
       IN /\ IsApplied(t)
          /\ st' = Upd(st, r, t.state)
    /\ live' = Upd(live, r, TRUE)
    /\ started' = Upd(started, r, TRUE)
    /\ phase' = Upd(phase, r, "returned")
    /\ UNCHANGED <<queuePaused, outage, up, recovered, sup, backoff, deferrals, exempt,
                   pumpFlag, lastSig, timerArmed, held, budget>>

\* The backend is unreachable: the start returns before any work exists
\* (startPlannedRecord's refresh outage).
StartNoWork(r) ==
    /\ up /\ phase[r] = "starting" /\ outage
    /\ st' = Upd(st, r,
                 IF FixB67 \/ sup[r] # "first" THEN st[r]
                 \* B67 off: the outage fails the first start.
                 ELSE Apply(st[r], EvReason("transferFailed", "server")))
    /\ phase' = Upd(phase, r, "returned")
    /\ UNCHANGED <<started, queuePaused, live, outage, up, recovered, sup, backoff,
                   deferrals, exempt, pumpFlag, lastSig, timerArmed, held, budget>>

\* A reachable backend refuses the start: transiently (network) or for good
\* (sourceMissing).
StartFails(r, reason) ==
    /\ up /\ phase[r] = "starting" /\ ~outage /\ Spend
    /\ st' = Upd(st, r, Apply(st[r], EvReason("transferFailed", reason)))
    /\ phase' = Upd(phase, r, "returned")
    /\ UNCHANGED <<started, queuePaused, live, outage, up, recovered, sup, backoff,
                   deferrals, exempt, pumpFlag, lastSig, timerArmed, held>>

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
    /\ UNCHANGED <<started, queuePaused, live, outage, up, recovered, exempt, lastSig,
                   timerArmed, held, budget>>

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
    /\ UNCHANGED <<started, queuePaused, outage, up, memVars, held, budget>>

TransferFails(r) ==
    /\ up /\ live[r] /\ st[r].lifecycle = "transferring" /\ Spend
    /\ st' = Upd(st, r, Apply(st[r], EvReason("transferFailed", "network")))
    /\ live' = Upd(live, r, FALSE)
    /\ UNCHANGED <<started, queuePaused, outage, up, memVars, held>>

OutageBegins ==
    /\ ~outage /\ Spend
    /\ outage' = TRUE
    /\ UNCHANGED <<durableVars, up, memVars, held>>

OutageEnds ==
    /\ outage
    /\ outage' = FALSE
    /\ UNCHANGED <<durableVars, up, memVars, held, budget>>

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
    /\ UNCHANGED <<durableVars, outage, held>>

Relaunch ==
    /\ ~up
    /\ up' = TRUE
    /\ UNCHANGED <<durableVars, outage, memVars, held, budget>>

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
    \* PROPOSED (finding A1): a row with no start evidence and no task never began.
    \* A granted one waits again; a paused one stays paused.
    IF /\ FixRelaunchKeepsUnstarted /\ ~started[r] /\ ~live[r]
       /\ s.lifecycle \in {"admitted", "paused"}
       THEN (IF s.lifecycle = "admitted"
                THEN Apply(s, EvIntent("admissionDeferred", "seasonPlanned")) ELSE s)
    ELSE IF IsApplied(t) THEN t.state ELSE s

\* Startup reconcile (reconcileOnWorker), then admission opens and the pump runs.
Recover ==
    /\ up /\ ~recovered
    /\ st' = [r \in Rows |-> RecoveredSt(r)]
    /\ recovered' = TRUE
    /\ pumpFlag' = TRUE
    /\ UNCHANGED <<started, queuePaused, live, outage, up, sup, phase, backoff, deferrals,
                   exempt, lastSig, timerArmed, held, budget>>

-----------------------------------------------------------------------------
Next ==
    \/ PauseAll \/ ResumeAll \/ Pump
    \/ OutageBegins \/ OutageEnds
    \/ Crash \/ Relaunch \/ Recover
    \/ \E r \in Rows :
          \/ UserPause(r) \/ UserResume(r)
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
          /\ WF_vars(BackoffElapsed(r))
          /\ WF_vars(StartApply(r)) /\ WF_vars(StartSucceeds(r))
          /\ WF_vars(StartNoWork(r)) /\ WF_vars(Finish(r))
          /\ WF_vars(TransferCompletes(r))

FairSpec == Spec /\ Fairness

-----------------------------------------------------------------------------
(* Safety                                                                  *)

\* No lane and no total ever holds more starts and transfers than its cap (B63).
LaneCapRespected ==
    /\ Cardinality(Occupants) <= MaxTotal
    /\ \A l \in LaneNames : Cardinality(Occupants \cap LaneRows(l)) <= LaneCap(l)

\* The same for the tasks themselves.
LiveTasksWithinCap ==
    /\ Cardinality({r \in Rows : live[r]}) <= MaxTotal
    /\ \A l \in LaneNames : Cardinality({r \in LaneRows(l) : live[r]}) <= LaneCap(l)

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

\* B65: a pause that parks a waiting first start keeps its intent, so Resume
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

\* Finding A1: startup recovery never fails a forward-only row that has no start
\* evidence.  (The code fails it: checked only by the Finding and Proposed runs.)
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
