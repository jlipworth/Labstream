--------------------------- MODULE DownloadsStatus ---------------------------
(***************************************************************************)
(* What the Downloads screen says: the speed at the top, each row's speed, *)
(* its bytes and its phase, and whether those stay true across headset     *)
(* sleep and wake, pause and resume, stalls, and process death.            *)
(*                                                                         *)
(* Actors                                                                  *)
(*   Daemon     the URLSession background daemon, which outlives the app   *)
(*              and keeps writing while the app is suspended or dead:      *)
(*              DaemonWrite, DaemonFinish                                  *)
(*   Session    delegate callbacks: Callback (didWriteData),               *)
(*              SegmentBoundary (a static-range segment finishes),         *)
(*              LateCallback (a callback already queued when Pause ran),   *)
(*              DeliverFinish, Finalize                                    *)
(*   Manager    Refresh (refreshRecords: rebuilds the published snapshot   *)
(*              and samples every row's rate estimator), WatchdogTick,     *)
(*              StallDetect, StartTask, Admit, Reconcile                   *)
(*   Clock      SettleExpire, GraceExpire, Expire: a timer running out     *)
(*   User/OS    Pause, Resume, Sleep, Wake, Stall, Unstall, Crash,         *)
(*              Relaunch, DropTask                                         *)
(*                                                                         *)
(* Lifecycle changes only through Reduce (DownloadsReducer.tla); each row  *)
(* keeps a whole reducer state.  The one hand-written transition is the    *)
(* B09 fix-off branch in LateCallback.                                     *)
(*                                                                         *)
(* Time is abstract.  A rate estimator is the stage it has reached, not    *)
(* its numbers:                                                            *)
(*   aggregate, per transfer   none -> settling -> settled -> window       *)
(*   per row                   none -> baseline -> window -> decaying      *)
(* and `aggQuiet` says a transfer's evidence ran out with no callback.     *)
(* The numeric side (interpolation, windows, clamps) is covered by the     *)
(* seeded tests in DownloadsFormalModelStatusTests.swift.                  *)
(*                                                                         *)
(* Timing assumptions, each one a guard that says so:                      *)
(*   A1  Bytes that piled up while the app could not see them are all      *)
(*       reported, and sampled by the refresh their callback schedules,    *)
(*       within 4 s of the first callback after it can see again           *)
(*       (SettleExpire, GraceExpire).  How late that FIRST callback is,    *)
(*       is not assumed.                                                   *)
(*   A2  A refresh that lands between two callbacks of a flowing row does  *)
(*       not zero its rate (RowSample: the "unchanged" arm).               *)
(*   A3  A scheduled refresh (0.5 to 1 s) runs before the user's next tap  *)
(*       (Resume).                                                         *)
(*                                                                         *)
(* Not modelled: server preparation and its captions, the percentage       *)
(* arithmetic, side-asset bytes, background execution (a suspended app     *)
(* runs nothing), naps shorter than callbackGap, Delete, retries of a      *)
(* forward-only row, and parallel segment trains beyond "a segment         *)
(* finished".  See README.md.                                              *)
(***************************************************************************)
\* MODELS: PMSKit/Sources/PMSKit/Downloads/DownloadAggregateRateEstimator.swift
\* MODELS: PMSKit/Sources/PMSKit/Downloads/DownloadRateEstimator.swift
\* MODELS: PMSKit/Sources/PMSKit/Downloads/DownloadJobSnapshot.swift
\* MODELS: PMSKit/Sources/PMSKit/Downloads/DownloadRowStatusCaptionPolicy.swift
\* MODELS: PMSKit/Sources/PMSKit/Downloads/OfflineDownloadAggregateStats.swift
\* MODELS: PMSKit/Sources/PMSKit/Downloads/OfflineSidebarStatusPolicy.swift
\* MODELS: PMSKit/Sources/PMSKit/Downloads/DownloadHealthSnapshotPolicy.swift
\* MODELS: PMSKit/Sources/PMSKit/Downloads/DownloadLiveRangeProgressPolicy.swift
\* MODELS: PMSKit/Sources/PMSKit/Downloads/DownloadWatchdogPolicy.swift
\* MODELS: PMSKit/Sources/PMSKit/Downloads/DownloadStallRecoveryPolicy.swift
\* MODELS: Labstream/Capabilities/Downloads/Core/DownloadManager.swift
EXTENDS DownloadsReducer, TLC

CONSTANTS
    Rows,               \* download keys
    ForwardRows,        \* rows on the forward-only route; the rest are static-range
    PlannedRows,        \* rows that start `planned` (waiting for admission)
    StallRows,          \* rows whose transfer the network may silently stall
    MaxBytes,           \* byte counters are 0..MaxBytes
    EnvBudget,          \* how many times the user, the OS and the network may interfere
    Endless,            \* TRUE: a transfer never finishes (its counter saturates)
    FixI379,            \* the aggregate needs fresh evidence from every transfer (#379)
    FixI224,            \* wake reset, callback-gap reset, settling, foreground grace (#224)
    FixI416,            \* a segment boundary's dip is held, not sampled (#416)
    FixPu33,            \* a row waiting for admission says so (pu-33)
    FixB09,             \* progress never promotes a paused row (B09)
    SilentCountsAsZero,             \* PROPOSED (S1): a transfer silent for callbackGap in an
                                    \* awake process counts as zero instead of hiding the total
    WatchdogCoversTransfers,        \* PROPOSED (S2): the refresh loop runs while any row transfers
    ForwardFirstCallbackRebaseline  \* PROPOSED (S4): a forward-only row re-baselines on its first
                                    \* callback after foreground, as a static row does

ASSUME /\ ForwardRows \subseteq Rows /\ PlannedRows \subseteq Rows /\ StallRows \subseteq Rows
       /\ MaxBytes \in Nat \ {0} /\ EnvBudget \in Nat
       /\ {Endless, FixI379, FixI224, FixI416, FixPu33, FixB09, SilentCountsAsZero,
           WatchdogCoversTransfers, ForwardFirstCallbackRebaseline} \subseteq BOOLEAN

VARIABLES
    \* Durable or outside the process: survives Crash.
    row,            \* the index row: a whole reducer state
    rec,            \* DownloadRecord.bytes: a static row's durable checkpoint, a
                    \* forward-only row's reported total
    task,           \* the row's URLSession task as the daemon sees it
    flow,           \* the network is delivering bytes to that task
    unrep,          \* bytes the daemon wrote that no callback has reported yet
    awake,          \* the app is foreground and running (FALSE: suspended)
    budget,         \* interference left
    \* In memory: lost on Crash.
    up,
    recovering,     \* relaunch reconcile has not run yet
    live,           \* liveRangeProgress: a static row's optimistic byte watermark
    aggActive,      \* DownloadAggregateRateEstimator.activeTransfers
    agg,            \* that estimator's stage per transfer
    aggQuiet,       \* the transfer's evidence ran out: no callback for too long
    rowEst,         \* the per-row DownloadRateEstimator's stage
    suppress,       \* its post-rebaseline suppression is running
    grace,          \* rateEstimatorForegroundGraceUntil is in the future
    fgPending,      \* rateEstimatorForegroundProgressPending holds the row
    newBytes,       \* known bytes moved since the row estimator last sampled
    lateCb,         \* a progress callback queued before Pause cancelled its task
    pubAgg,         \* published: the speed at the top of Downloads
    pubSpeed,       \* published: each row's speed
    refreshPending, \* a refreshRecords is scheduled
    watchdog,       \* downloadWatchdogTask is running
    \* Ghosts: written, never read by a guard.
    aggTaint,       \* the transfer's window had catch-up bytes appended to an older baseline
    cuRow,          \* known bytes gained catch-up bytes since the row estimator last sampled
    baseStale,      \* the row estimator's baseline was sampled while catch-up was outstanding
    rowTaint,       \* the row's window divides catch-up bytes by a post-wake interval
    pubMissing,     \* transfers the published number left out while they might be moving
    pubAggTaint,    \* the published number used a tainted window
    spuriousReset,  \* a segment boundary reset the batch
    resetRows,      \* rows whose bytes the last step reset through a reducer effect
    shownAtCrash    \* what each downloading row showed when the process died

durable == <<row, rec, task, flow, unrep, awake, budget>>
memory == <<up, recovering, live, aggActive, agg, aggQuiet, rowEst, suppress, grace,
            fgPending, newBytes, lateCb, pubAgg, pubSpeed, refreshPending, watchdog>>
ghosts == <<aggTaint, cuRow, baseStale, rowTaint, pubMissing, pubAggTaint, spuriousReset,
            resetRows, shownAtCrash>>
vars == <<durable, memory, ghosts>>

-----------------------------------------------------------------------------
(* Vocabulary                                                              *)

StaticRows == Rows \ ForwardRows
UnrepStates == {"none", "fresh", "catchup", "rest"}
\* Bytes written while the app could not see them: all of them ("catchup") or what is left
\* after a first callback reported part ("rest").
CatchUp == {"catchup", "rest"}
AggStages == {"none", "settling", "settled", "window"}
RowStages == {"none", "baseline", "window", "decaying"}
AggDisplays == {"hidden", "updating", "number"}
Speeds == {"none", "number"}
StatusTaskStates == {"none", "running", "finished"}

Larger(a, b) == IF a >= b THEN a ELSE b
Life(r) == row[r].lifecycle

\* DownloadLifecycle.derivedStatus
Status(r) ==
    CASE Life(r) \in {"planned", "admitted"} -> "queued"
      [] Life(r) = "serverPrep" -> "preparing"
      [] Life(r) \in {"transferring", "finalizing"} -> "downloading"
      [] OTHER -> Life(r)

\* Bytes the app knows of.  A forward-only row persists its reported total; a static row
\* persists only its checkpoint and keeps the optimistic total in memory.
Known(r) == IF r \in ForwardRows THEN rec[r] ELSE Larger(rec[r], live[r])
\* DownloadManager.displayBytes: the live overlay counts only while the row is downloading.
Shown(r) == IF Status(r) = "downloading" THEN Known(r) ELSE rec[r]

Flowing(r) == task[r] = "running" /\ flow[r]
Transferring == {r \in Rows : Life(r) = "transferring"}

\* DownloadRowStatusCaptionPolicy.phase, with DownloadManager's `isActive`
\* (`activeJobs.contains || status == .downloading`; a started task makes the row downloading).
Phase(r) ==
    CASE Life(r) = "failed" -> "failed"
      [] Life(r) = "paused" -> "paused"
      [] Life(r) \in Playable -> "complete"
      [] Life(r) = "finalizing" -> "transferFinalizing"
      [] OTHER ->
            (IF Shown(r) = 0
                THEN (IF Status(r) = "downloading"
                         THEN (IF r \in StaticRows THEN "activeStaticZeroByteTransfer"
                                                   ELSE "activeServerPrep")
                         ELSE "queued")
                ELSE (IF Status(r) = "downloading" THEN "activeTransfer"
                                                   ELSE "inactiveTransfer"))

\* DownloadJobSnapshot.persistedPhase
PersistedPhase(r) ==
    CASE Status(r) = "queued" -> "queued"
      [] Status(r) = "preparing" -> "activeServerPrep"
      [] Status(r) = "downloading" -> (IF rec[r] > 0 THEN "activeTransfer" ELSE "queued")
      [] Life(r) \in Playable -> "complete"
      [] OTHER -> Life(r)

\* DownloadJobPhase.isActiveWork, for the phases this model reaches.
ActiveWorkPhases ==
    {"transferFinalizing", "activeStaticZeroByteTransfer", "activeServerPrep", "queued",
     "activeTransfer"}

\* DownloadRowStatusCaptionPolicy.admissionWaitingCaption's `waiting`.
Waiting(r) ==
    \/ Life(r) = "planned"
    \/ Life(r) \in {"paused", "failed"} /\ row[r].admissionIntent = "retryRequested"

\* DownloadManager.statusCaption: the waiting caption overrides the phase caption (pu-33).
Caption(r) == IF FixPu33 /\ Waiting(r) THEN "waiting" ELSE Phase(r)

\* There is something that will move this row without the user: a task, queued admission or
\* start, or a finalization.
HasWork(r) == task[r] # "none" \/ Life(r) \in {"planned", "admitted", "finalizing"}

\* DownloadHealthRuntimeSnapshot.hasWork
HealthHasWork ==
    \/ \E r \in Rows : PersistedPhase(r) \in ActiveWorkPhases
    \/ \E r \in Rows : task[r] # "none" \/ Life(r) = "finalizing"

\* OfflineSidebarStatusPolicy.presentation's activeCount.
SidebarActive == {r \in Rows : Status(r) = "downloading"}

\* DownloadWatchdogPolicy.requiresWatchdog (server prep is not modelled).
WatchRow(r) ==
    \/ r \in ForwardRows /\ Status(r) = "downloading"
    \/ WatchdogCoversTransfers /\ Life(r) = "transferring"

\* DownloadRowFacts as relaunch reconcile reads them.
Facts(r) ==
    Fx(IF r \in ForwardRows THEN "forwardOnly" ELSE "staticRange",
       FALSE,
       IF r \in ForwardRows THEN "none"
          ELSE (IF rec[r] > 0 THEN "partial" ELSE "partialEmpty"),
       CASE Life(r) = "finalizing" -> "workingComplete"
         [] Life(r) \in Playable -> "published"
         [] OTHER -> "none",
       FALSE, FALSE, task[r] # "none", TRUE)

-----------------------------------------------------------------------------
(* Init                                                                    *)

Init ==
    /\ row = [r \in Rows |-> InitialState(IF r \in PlannedRows THEN "planned" ELSE "admitted")]
    /\ rec = Const(Rows, 0)
    /\ task = Const(Rows, "none")
    /\ flow = Const(Rows, FALSE)
    /\ unrep = Const(Rows, "none")
    /\ awake = TRUE
    /\ budget = EnvBudget
    /\ up = TRUE
    /\ recovering = FALSE
    /\ live = Const(Rows, 0)
    /\ aggActive = {}
    /\ agg = Const(Rows, "none")
    /\ aggQuiet = Const(Rows, FALSE)
    /\ rowEst = Const(Rows, "none")
    /\ suppress = Const(Rows, FALSE)
    /\ grace = Const(Rows, FALSE)
    /\ fgPending = Const(Rows, FALSE)
    /\ newBytes = Const(Rows, FALSE)
    /\ lateCb = Const(Rows, FALSE)
    /\ pubAgg = "hidden"
    /\ pubSpeed = Const(Rows, "none")
    /\ refreshPending = FALSE
    /\ watchdog = FALSE
    /\ aggTaint = Const(Rows, FALSE)
    /\ cuRow = Const(Rows, FALSE)
    /\ baseStale = Const(Rows, FALSE)
    /\ rowTaint = Const(Rows, FALSE)
    /\ pubMissing = {}
    /\ pubAggTaint = FALSE
    /\ spuriousReset = FALSE
    /\ resetRows = {}
    /\ shownAtCrash = Const(Rows, 0)

\* Frames.  `resetRows` describes the last step only, so every action writes it.
NoReset == resetRows' = {}
KeepRowRate == UNCHANGED <<rowEst, suppress, grace, fgPending, newBytes, cuRow, baseStale,
                           rowTaint, pubSpeed>>
KeepAgg == UNCHANGED <<aggActive, agg, aggQuiet, aggTaint, spuriousReset>>
KeepPublishedAgg == UNCHANGED <<pubAgg, pubMissing, pubAggTaint>>
KeepProcess == UNCHANGED <<up, recovering, awake, budget, shownAtCrash>>

\* The app is running and can see callbacks.
Observing == up /\ awake

-----------------------------------------------------------------------------
(* The daemon                                                              *)

\* The task receives bytes.  Whether a callback can report them now decides what they are.
DaemonWrite(r) ==
    /\ Flowing(r)
    /\ Endless \/ Known(r) < MaxBytes
    /\ IF Observing THEN unrep[r] = "none" /\ unrep' = Upd(unrep, r, "fresh")
                    ELSE unrep[r] \in {"none", "fresh"} /\ unrep' = Upd(unrep, r, "catchup")
    /\ NoReset
    /\ UNCHANGED <<row, rec, task, flow, live, lateCb, refreshPending, watchdog>>
    /\ KeepRowRate /\ KeepAgg /\ KeepPublishedAgg /\ KeepProcess

DaemonFinish(r) ==
    /\ ~Endless
    /\ Flowing(r)
    /\ Known(r) > 0 \/ unrep[r] # "none"
    /\ task' = Upd(task, r, "finished")
    /\ NoReset
    /\ UNCHANGED <<row, rec, flow, unrep, live, lateCb, refreshPending, watchdog>>
    /\ KeepRowRate /\ KeepAgg /\ KeepPublishedAgg /\ KeepProcess

-----------------------------------------------------------------------------
(* DownloadAggregateRateEstimator.sample                                   *)

\* The estimator after transfer `r` reports; `isCU` says the report carries catch-up bytes.
AggAfterSample(r, isCU) ==
    LET \* "now - last.time >= callbackGap": reset the whole batch.
        gapReset == FixI224 /\ aggQuiet[r] /\ (agg[r] # "none" \/ SilentCountsAsZero)
        base == IF gapReset THEN Const(Rows, "none") ELSE agg
        baseTaint == IF gapReset THEN Const(Rows, FALSE) ELSE aggTaint
        baseQuiet == IF gapReset THEN Const(Rows, FALSE) ELSE aggQuiet
        \* Fix off (#224): no settling; the first observation is a baseline at once.
        next == IF FixI224
                   THEN (CASE base[r] = "none" -> "settling"
                           [] base[r] = "settling" -> "settling"
                           [] OTHER -> "window")
                   ELSE (IF base[r] = "none" THEN "settled" ELSE "window")
        appended == base[r] \in {"settled", "window"}
    IN [agg |-> Upd(base, r, next),
        quiet |-> Upd(baseQuiet, r, FALSE),
        taint |-> Upd(baseTaint, r, IF appended THEN baseTaint[r] \/ isCU ELSE FALSE)]

\* Apply a sample from `r`, or drop it when `r` is not an active transfer.
SampleAggregate(r, isCU) ==
    IF r \in aggActive
       THEN LET s == AggAfterSample(r, isCU)
            IN agg' = s.agg /\ aggQuiet' = s.quiet /\ aggTaint' = s.taint
       ELSE UNCHANGED <<agg, aggQuiet, aggTaint>>

-----------------------------------------------------------------------------
(* The session                                                             *)

\* urlSession(_:downloadTask:didWriteData:...) reports the unreported bytes.
Callback(r) ==
    /\ Observing /\ ~recovering
    /\ task[r] # "none" /\ unrep[r] # "none"
    /\ LET t == Reduce(row[r], Ev("transferProgress"), NoFacts)
           isCU == unrep[r] \in CatchUp
           bumped == IF Known(r) < MaxBytes THEN Known(r) + 1 ELSE MaxBytes
           \* onRangeLiveProgress: the first callback after foreground re-baselines the row.
           rebase == fgPending[r]
       IN /\ IsApplied(t)
          /\ row' = Upd(row, r, t.state)
          /\ IF r \in ForwardRows
                THEN rec' = Upd(rec, r, bumped) /\ UNCHANGED live
                ELSE live' = Upd(live, r, bumped) /\ UNCHANGED rec
          \* A first report after a blackout may carry only part of what piled up (A1).
          /\ \E left \in (IF unrep[r] = "catchup" THEN {"none", "rest"} ELSE {"none"}) :
                /\ unrep' = Upd(unrep, r, left)
                /\ IF rebase
                      THEN /\ rowEst' = Upd(rowEst, r, "baseline")
                           /\ suppress' = Upd(suppress, r, TRUE)
                           /\ grace' = Upd(grace, r, TRUE)
                           /\ fgPending' = Upd(fgPending, r, FALSE)
                           /\ pubSpeed' = Upd(pubSpeed, r, "none")
                           /\ newBytes' = Upd(newBytes, r, FALSE)
                           /\ cuRow' = Upd(cuRow, r, FALSE)
                           /\ baseStale' = Upd(baseStale, r, left = "rest")
                           /\ rowTaint' = Upd(rowTaint, r, FALSE)
                      ELSE /\ newBytes' = Upd(newBytes, r, TRUE)
                           /\ cuRow' = Upd(cuRow, r, cuRow[r] \/ isCU)
                           /\ UNCHANGED <<rowEst, suppress, grace, fgPending, pubSpeed,
                                          baseStale, rowTaint>>
          /\ SampleAggregate(r, isCU)
    /\ refreshPending' = TRUE
    /\ NoReset
    /\ UNCHANGED <<task, flow, lateCb, watchdog, aggActive, spuriousReset>>
    /\ KeepPublishedAgg /\ KeepProcess

\* A static-range segment finishes and its body is appended to the durable partial.  The
\* in-flight total dips until the append lands; #416 holds the previous rate sample.
SegmentBoundary(r) ==
    /\ Observing /\ ~recovering
    /\ r \in StaticRows /\ task[r] = "running" /\ Life(r) = "transferring"
    /\ live[r] > rec[r]
    /\ rec' = Upd(rec, r, live[r])
    /\ IF FixI416 \/ r \notin aggActive
          THEN UNCHANGED <<agg, aggQuiet, aggTaint, spuriousReset>>
          \* Fix off (#416): the dip reads as a regression, which resets the batch.
          ELSE /\ agg' = Upd(Const(Rows, "none"), r, IF FixI224 THEN "settling" ELSE "settled")
               /\ aggQuiet' = Const(Rows, FALSE)
               /\ aggTaint' = Const(Rows, FALSE)
               /\ spuriousReset' = TRUE
    /\ refreshPending' = TRUE
    /\ NoReset
    /\ UNCHANGED <<row, task, flow, unrep, live, lateCb, watchdog, aggActive>>
    /\ KeepRowRate /\ KeepPublishedAgg /\ KeepProcess

\* A progress callback that was already on its way to the main actor when Pause ran.
LateCallback(r) ==
    /\ Observing /\ ~recovering
    /\ lateCb[r]
    /\ lateCb' = Upd(lateCb, r, FALSE)
    /\ LET t == Reduce(row[r], Ev("transferProgress"), NoFacts)
       IN IF FixB09
             THEN row' = IF IsApplied(t) THEN Upd(row, r, t.state) ELSE row
             \* Fix off (B09): progress promotes whatever row it finds.
             ELSE row' = Upd(row, r, RTo(row[r], "transferring"))
    /\ refreshPending' = TRUE
    /\ NoReset
    /\ UNCHANGED <<rec, task, flow, unrep, live, watchdog>>
    /\ KeepRowRate /\ KeepAgg /\ KeepPublishedAgg /\ KeepProcess

\* didFinishDownloadingTo, through to the body at its working path.
DeliverFinish(r) ==
    /\ Observing /\ ~recovering
    /\ task[r] = "finished"
    /\ LET t == Reduce(row[r], Ev("bodyAtWorking"), NoFacts)
       IN /\ IsApplied(t)
          /\ row' = Upd(row, r, t.state)
    /\ task' = Upd(task, r, "none")
    /\ flow' = Upd(flow, r, FALSE)
    /\ unrep' = Upd(unrep, r, "none")
    /\ rec' = Upd(rec, r, Known(r))
    /\ refreshPending' = TRUE
    /\ NoReset
    /\ UNCHANGED <<live, lateCb, watchdog>>
    /\ KeepRowRate /\ KeepAgg /\ KeepPublishedAgg /\ KeepProcess

\* The verdict and the promotion, as one step: this module does not study finalization.
Finalize(r) ==
    /\ Observing /\ ~recovering
    /\ Life(r) = "finalizing"
    /\ LET verdict == Reduce(row[r], EvFinalize("o1", "complete", "src"), NoFacts)
       IN /\ Has(verdict, "publishComplete")
          /\ LET done == Reduce(verdict.state, EvPromotion("promotionCommitted", "complete"),
                                NoFacts)
             IN /\ IsApplied(done)
                /\ row' = Upd(row, r, done.state)
    /\ refreshPending' = TRUE
    /\ NoReset
    /\ UNCHANGED <<rec, task, flow, unrep, live, lateCb, watchdog>>
    /\ KeepRowRate /\ KeepAgg /\ KeepPublishedAgg /\ KeepProcess

-----------------------------------------------------------------------------
(* The manager                                                             *)

Admit(r) ==
    /\ Observing /\ ~recovering
    /\ LET t == Reduce(row[r], Ev("admissionGranted"), NoFacts)
       IN /\ IsApplied(t)
          /\ row' = Upd(row, r, t.state)
    /\ refreshPending' = TRUE
    /\ NoReset
    /\ UNCHANGED <<rec, task, flow, unrep, live, lateCb, watchdog>>
    /\ KeepRowRate /\ KeepAgg /\ KeepPublishedAgg /\ KeepProcess

\* The session creates the task and submits transferStarted with it.
StartTask(r) ==
    /\ Observing /\ ~recovering
    /\ Life(r) = "admitted" /\ task[r] = "none"
    /\ LET t == Reduce(row[r], Ev("transferStarted"), NoFacts)
       IN /\ IsApplied(t)
          /\ row' = Upd(row, r, t.state)
    /\ task' = Upd(task, r, "running")
    /\ flow' = Upd(flow, r, TRUE)
    /\ unrep' = Upd(unrep, r, "none")
    \* A new task: the session rejects callbacks of the one Pause cancelled (B12).
    /\ lateCb' = Upd(lateCb, r, FALSE)
    /\ refreshPending' = TRUE
    /\ NoReset
    /\ UNCHANGED <<rec, live, watchdog>>
    /\ KeepRowRate /\ KeepAgg /\ KeepPublishedAgg /\ KeepProcess

\* One row's estimator sample inside refreshRecords.
RowSample(r) ==
    IF Status(r) # "downloading"
       THEN [est |-> "none", speed |-> "none", stale |-> FALSE, taint |-> FALSE]
    ELSE IF grace[r] \/ rowEst[r] = "none"
       \* During the foreground grace the estimator is replaced by a one-sample one.
       THEN [est |-> "baseline", speed |-> "none", stale |-> unrep[r] \in CatchUp,
             taint |-> FALSE]
    ELSE IF newBytes[r]
       THEN [est |-> "window", speed |-> IF suppress[r] THEN "none" ELSE "number",
             stale |-> baseStale[r], taint |-> rowTaint[r] \/ (cuRow[r] /\ baseStale[r])]
    ELSE IF Flowing(r)
       \* A2: a refresh between two callbacks of a flowing row.
       THEN [est |-> rowEst[r], speed |-> pubSpeed[r], stale |-> baseStale[r],
             taint |-> rowTaint[r]]
    ELSE IF rowEst[r] = "window"
       \* The first quiet sample: the window still holds the last movement.
       THEN [est |-> "decaying", speed |-> pubSpeed[r], stale |-> baseStale[r],
             taint |-> rowTaint[r]]
       \* The window is all quiet: the rate is zero and the speed is removed.
       ELSE [est |-> "baseline", speed |-> "none", stale |-> unrep[r] \in CatchUp,
             taint |-> FALSE]

\* refreshRecords, makeOfflineLibrarySnapshot and updateDownloadWatchdog.
Refresh ==
    /\ Observing
    /\ refreshPending
    /\ LET active == Transferring
           \* setActiveTransfers: a new member resets the batch; a departure does not.
           added == active \ aggActive # {}
           a1 == [r \in Rows |-> IF added \/ r \notin active THEN "none" ELSE agg[r]]
           q1 == [r \in Rows |-> ~added /\ r \in active /\ aggQuiet[r]]
           t1 == [r \in Rows |-> ~added /\ r \in active /\ aggTaint[r]]
           contributes(r) == a1[r] = "window" /\ ~q1[r]
           counted(r) == contributes(r) \/ (SilentCountsAsZero /\ q1[r])
           \* rate(at:).  Fix off (#379): the sum of whichever estimates exist.
           number == /\ active # {}
                     /\ IF FixI379 THEN \A r \in active : counted(r)
                                   ELSE \E r \in active : contributes(r)
           sample == [r \in Rows |-> RowSample(r)]
       IN /\ aggActive' = active
          /\ agg' = a1 /\ aggQuiet' = q1 /\ aggTaint' = t1
          \* OfflineDownloadAggregateStats.make
          /\ pubAgg' = IF number THEN "number"
                       ELSE IF active # {} THEN "updating" ELSE "hidden"
          /\ pubMissing' = IF number THEN {r \in active : ~counted(r) /\ ~q1[r]} ELSE {}
          /\ pubAggTaint' = (number /\ \E r \in active : contributes(r) /\ t1[r])
          /\ rowEst' = [r \in Rows |-> sample[r].est]
          /\ pubSpeed' = [r \in Rows |-> sample[r].speed]
          /\ baseStale' = [r \in Rows |-> sample[r].stale]
          /\ rowTaint' = [r \in Rows |-> sample[r].taint]
          /\ newBytes' = Const(Rows, FALSE)
          /\ cuRow' = Const(Rows, FALSE)
          \* Rate state is kept only for rows that are downloading.
          /\ suppress' = [r \in Rows |-> Status(r) = "downloading" /\ suppress[r]]
          /\ grace' = [r \in Rows |-> Status(r) = "downloading" /\ grace[r]]
          /\ fgPending' = [r \in Rows |-> Status(r) = "downloading" /\ fgPending[r]]
          /\ watchdog' = (number \/ \E r \in Rows : WatchRow(r))
    /\ refreshPending' = FALSE
    /\ NoReset
    /\ UNCHANGED <<row, rec, task, flow, unrep, live, lateCb, spuriousReset>>
    /\ KeepProcess

\* The watchdog loop: every second while a number shows, every 15 s otherwise.
WatchdogTick ==
    /\ Observing
    /\ watchdog /\ ~refreshPending
    /\ refreshPending' = TRUE
    /\ NoReset
    /\ UNCHANGED <<row, rec, task, flow, unrep, live, lateCb, watchdog>>
    /\ KeepRowRate /\ KeepAgg /\ KeepPublishedAgg /\ KeepProcess

\* detectForwardOnlyStreamStalls: only forward-only streams have a stall verdict.
StallDetect(r) ==
    /\ Observing /\ ~recovering
    /\ watchdog
    /\ r \in ForwardRows /\ Life(r) = "transferring"
    /\ task[r] = "running" /\ ~flow[r] /\ unrep[r] = "none"
    /\ LET t == Reduce(row[r], Ev("stallDetected"), NoFacts)
       IN /\ IsApplied(t)
          /\ row' = Upd(row, r, t.state)
    /\ task' = Upd(task, r, "none")
    /\ refreshPending' = TRUE
    /\ NoReset
    /\ UNCHANGED <<rec, flow, unrep, live, lateCb, watchdog>>
    /\ KeepRowRate /\ KeepAgg /\ KeepPublishedAgg /\ KeepProcess

\* beginDownloadRateForegroundRebaseline, shared by Wake and Relaunch.
ForegroundRebaseline ==
    IF FixI224
       THEN /\ agg' = Const(Rows, "none")
            /\ aggQuiet' = Const(Rows, FALSE)
            /\ aggTaint' = Const(Rows, FALSE)
            /\ grace' = [r \in Rows |-> grace[r] \/ Status(r) = "downloading"]
            /\ pubSpeed' = [r \in Rows |-> IF Status(r) = "downloading" THEN "none"
                                                                        ELSE pubSpeed[r]]
            /\ fgPending' = [r \in Rows |->
                    \/ fgPending[r]
                    \/ /\ Status(r) = "downloading"
                       /\ r \in StaticRows \/ ForwardFirstCallbackRebaseline]
       \* Fix off (#224): foreground changes nothing.
       ELSE UNCHANGED <<agg, aggQuiet, aggTaint, grace, pubSpeed, fgPending>>

\* Launch and foreground reconcile: relaunchObserved for every row.
Reconcile ==
    /\ Observing /\ recovering
    /\ LET t == [r \in Rows |-> Reduce(row[r], Ev("relaunchObserved"), Facts(r))]
           zeroed == {r \in Rows : Has(t[r], "resetBytesToZero") \/ Has(t[r], "deleteWorkingBody")}
           toCheckpoint == {r \in Rows : Has(t[r], "resetBytesToDurableCheckpoint")}
       IN /\ \A r \in Rows : IsApplied(t[r])
          /\ row' = [r \in Rows |-> t[r].state]
          /\ rec' = [r \in Rows |-> IF r \in zeroed THEN 0 ELSE rec[r]]
          /\ live' = [r \in Rows |-> IF r \in zeroed \cup toCheckpoint THEN 0 ELSE live[r]]
          /\ resetRows' = zeroed \cup toCheckpoint
    /\ recovering' = FALSE
    /\ refreshPending' = TRUE
    /\ UNCHANGED <<task, flow, unrep, lateCb, watchdog, up, awake, budget, shownAtCrash>>
    /\ KeepRowRate /\ KeepAgg /\ KeepPublishedAgg

-----------------------------------------------------------------------------
(* The clock                                                               *)

\* settlingDuration (4 s) has passed since the transfer's first callback.  A1.
SettleExpire(r) ==
    /\ Observing
    /\ agg[r] = "settling" /\ unrep[r] \notin CatchUp
    /\ agg' = Upd(agg, r, "settled")
    /\ NoReset
    /\ UNCHANGED <<row, rec, task, flow, unrep, live, lateCb, refreshPending, watchdog,
                   aggActive, aggQuiet, aggTaint, spuriousReset>>
    /\ KeepRowRate /\ KeepPublishedAgg /\ KeepProcess

\* The 4 s foreground grace and the 4 s rebaseline suppression run out.  A1 covers only the
\* remainder after a first callback, and the refresh that each callback schedules within a
\* second: nothing bounds how late that first callback is.
GraceExpire(r) ==
    /\ Observing
    /\ grace[r] \/ suppress[r]
    /\ unrep[r] # "rest" /\ ~cuRow[r]
    /\ grace' = Upd(grace, r, FALSE)
    /\ suppress' = Upd(suppress, r, FALSE)
    /\ NoReset
    /\ UNCHANGED <<row, rec, task, flow, unrep, live, lateCb, refreshPending, watchdog,
                   rowEst, fgPending, newBytes, cuRow, baseStale, rowTaint, pubSpeed>>
    /\ KeepAgg /\ KeepPublishedAgg /\ KeepProcess

\* An active transfer's evidence runs out with no callback: its answer goes after 3.5 s (the
\* 4 s window less the 0.5 s minimum) and it is stale after callbackGap (6 s).  Nothing orders
\* this against the row's own decay, which needs about 4 s of quiet refreshes: the seeded test
\* for finding S2 shows the aggregate goes first.
Expire(r) ==
    /\ Observing
    /\ r \in aggActive /\ ~aggQuiet[r]
    /\ ~Flowing(r) /\ unrep[r] = "none"
    /\ aggQuiet' = Upd(aggQuiet, r, TRUE)
    /\ NoReset
    /\ UNCHANGED <<row, rec, task, flow, unrep, live, lateCb, refreshPending, watchdog,
                   aggActive, agg, aggTaint, spuriousReset>>
    /\ KeepRowRate /\ KeepPublishedAgg /\ KeepProcess

-----------------------------------------------------------------------------
(* The user, the OS and the network.  Each step spends budget.             *)

Spend == budget > 0 /\ budget' = budget - 1
KeepProcessButBudget == UNCHANGED <<up, recovering, awake, shownAtCrash>>

Pause(r) ==
    /\ Spend
    /\ Observing /\ ~recovering
    /\ Life(r) \in {"admitted", "transferring"}
    /\ LET t == Reduce(row[r], EvPause("user"), NoFacts)
       IN /\ IsApplied(t)
          /\ row' = Upd(row, r, t.state)
    \* Pause cancels the task; one progress callback may already be queued.
    /\ lateCb' \in {Upd(lateCb, r, c) : c \in (IF task[r] = "running" THEN BOOLEAN ELSE {FALSE})}
    /\ task' = Upd(task, r, "none")
    /\ flow' = Upd(flow, r, FALSE)
    /\ unrep' = Upd(unrep, r, "none")
    \* The optimistic overlay is dropped: a paused row shows its resumable bytes.
    /\ live' = Upd(live, r, 0)
    /\ refreshPending' = TRUE
    /\ NoReset
    /\ UNCHANGED <<rec, watchdog>>
    /\ KeepRowRate /\ KeepAgg /\ KeepPublishedAgg /\ KeepProcessButBudget

\* Resume of a static row from its checkpoint.  A forward-only row is not resumed here.
\* A3: the refresh that the pause scheduled has run before the user taps again.
Resume(r) ==
    /\ Spend
    /\ Observing /\ ~recovering /\ ~refreshPending
    /\ r \in StaticRows /\ Life(r) = "paused"
    /\ LET t == Reduce(row[r], EvRetry("staticCheckpoint"), NoFacts)
       IN /\ IsApplied(t)
          /\ row' = Upd(row, r, t.state)
    /\ lateCb' = Upd(lateCb, r, FALSE)
    /\ refreshPending' = TRUE
    /\ NoReset
    /\ UNCHANGED <<rec, task, flow, unrep, live, watchdog>>
    /\ KeepRowRate /\ KeepAgg /\ KeepPublishedAgg /\ KeepProcessButBudget

\* The network stops delivering to one task, with no error.
Stall(r) ==
    /\ Spend
    /\ r \in StallRows /\ Flowing(r)
    /\ flow' = Upd(flow, r, FALSE)
    /\ NoReset
    /\ UNCHANGED <<row, rec, task, unrep, live, lateCb, refreshPending, watchdog>>
    /\ KeepRowRate /\ KeepAgg /\ KeepPublishedAgg /\ KeepProcessButBudget

Unstall(r) ==
    /\ Spend
    /\ task[r] = "running" /\ ~flow[r]
    /\ flow' = Upd(flow, r, TRUE)
    /\ NoReset
    /\ UNCHANGED <<row, rec, task, unrep, live, lateCb, refreshPending, watchdog>>
    /\ KeepRowRate /\ KeepAgg /\ KeepPublishedAgg /\ KeepProcessButBudget

\* The headset sleeps for longer than callbackGap: the app is suspended, its memory stays,
\* and every timer has run out by the time it wakes.
Sleep ==
    /\ Spend
    /\ Observing /\ ~recovering
    /\ awake' = FALSE
    /\ aggQuiet' = Const(Rows, TRUE)
    /\ grace' = Const(Rows, FALSE)
    /\ suppress' = Const(Rows, FALSE)
    /\ NoReset
    /\ UNCHANGED <<row, rec, task, flow, unrep, live, lateCb, refreshPending, watchdog,
                   aggActive, agg, aggTaint, spuriousReset, rowEst, fgPending, newBytes,
                   cuRow, baseStale, rowTaint, pubSpeed, up, recovering, shownAtCrash>>
    /\ KeepPublishedAgg

\* The scene becomes active again.
Wake ==
    /\ up /\ ~awake
    /\ awake' = TRUE
    /\ ForegroundRebaseline
    /\ refreshPending' = TRUE
    /\ NoReset
    /\ UNCHANGED <<row, rec, task, flow, unrep, live, lateCb, watchdog, aggActive,
                   spuriousReset, rowEst, suppress, newBytes, cuRow, baseStale, rowTaint,
                   up, recovering, budget, shownAtCrash>>
    /\ KeepPublishedAgg

\* The process dies.  Every in-memory variable returns to its Init value.
Crash ==
    /\ Spend
    /\ up
    /\ up' = FALSE
    /\ recovering' = FALSE
    /\ live' = Const(Rows, 0)
    /\ aggActive' = {}
    /\ agg' = Const(Rows, "none")
    /\ aggQuiet' = Const(Rows, FALSE)
    /\ rowEst' = Const(Rows, "none")
    /\ suppress' = Const(Rows, FALSE)
    /\ grace' = Const(Rows, FALSE)
    /\ fgPending' = Const(Rows, FALSE)
    /\ newBytes' = Const(Rows, FALSE)
    /\ lateCb' = Const(Rows, FALSE)
    /\ pubAgg' = "hidden"
    /\ pubSpeed' = Const(Rows, "none")
    /\ refreshPending' = FALSE
    /\ watchdog' = FALSE
    /\ aggTaint' = Const(Rows, FALSE)
    /\ cuRow' = Const(Rows, FALSE)
    /\ baseStale' = Const(Rows, FALSE)
    /\ rowTaint' = Const(Rows, FALSE)
    /\ pubMissing' = {}
    /\ pubAggTaint' = FALSE
    /\ shownAtCrash' = [r \in Rows |-> IF Status(r) = "downloading" THEN Shown(r) ELSE 0]
    /\ NoReset
    /\ UNCHANGED <<row, rec, task, flow, unrep, awake, spuriousReset>>

\* A foreground launch: the rate boundary starts at once, reconcile follows.
Relaunch ==
    /\ ~up
    /\ up' = TRUE
    /\ awake' = TRUE
    /\ recovering' = TRUE
    /\ ForegroundRebaseline
    /\ refreshPending' = TRUE
    /\ NoReset
    /\ UNCHANGED <<row, rec, task, flow, unrep, live, lateCb, watchdog, aggActive,
                   spuriousReset, rowEst, suppress, newBytes, cuRow, baseStale, rowTaint,
                   budget, shownAtCrash>>
    /\ KeepPublishedAgg

\* While the app is dead the system discards a task (a force quit does this to all of them).
DropTask(r) ==
    /\ Spend
    /\ ~up /\ task[r] = "running"
    /\ task' = Upd(task, r, "none")
    /\ flow' = Upd(flow, r, FALSE)
    /\ unrep' = Upd(unrep, r, "none")
    /\ NoReset
    /\ UNCHANGED <<row, rec, live, lateCb, refreshPending, watchdog>>
    /\ KeepRowRate /\ KeepAgg /\ KeepPublishedAgg /\ KeepProcessButBudget

-----------------------------------------------------------------------------
(* Spec                                                                    *)

Next ==
    \/ Refresh \/ WatchdogTick \/ Reconcile \/ Sleep \/ Wake \/ Crash \/ Relaunch
    \/ \E r \in Rows :
          \/ DaemonWrite(r) \/ DaemonFinish(r)
          \/ Callback(r) \/ SegmentBoundary(r) \/ LateCallback(r)
          \/ DeliverFinish(r) \/ Finalize(r)
          \/ Admit(r) \/ StartTask(r) \/ StallDetect(r)
          \/ SettleExpire(r) \/ GraceExpire(r) \/ Expire(r)
          \/ Pause(r) \/ Resume(r) \/ Stall(r) \/ Unstall(r) \/ DropTask(r)

Spec == Init /\ [][Next]_vars

\* Everything the app, the daemon and the clock do is fair, and so is coming back from a
\* sleep or a death.  Interference is not: it stops when the budget is spent.
FairSpec ==
    /\ Spec
    /\ WF_vars(Refresh) /\ WF_vars(WatchdogTick) /\ WF_vars(Reconcile)
    /\ WF_vars(Wake) /\ WF_vars(Relaunch)
    /\ \A r \in Rows :
          /\ WF_vars(DaemonWrite(r)) /\ WF_vars(DaemonFinish(r))
          /\ WF_vars(Callback(r)) /\ WF_vars(SegmentBoundary(r)) /\ WF_vars(LateCallback(r))
          /\ WF_vars(DeliverFinish(r)) /\ WF_vars(Finalize(r))
          /\ WF_vars(Admit(r)) /\ WF_vars(StartTask(r)) /\ WF_vars(StallDetect(r))
          /\ WF_vars(SettleExpire(r)) /\ WF_vars(GraceExpire(r)) /\ WF_vars(Expire(r))

RowSymmetry == Permutations(Rows)

-----------------------------------------------------------------------------
(* Invariants                                                              *)

TypeOK ==
    /\ \A r \in Rows : row[r].lifecycle \in Lifecycles
    /\ rec \in [Rows -> 0..MaxBytes]
    /\ task \in [Rows -> StatusTaskStates]
    /\ flow \in [Rows -> BOOLEAN]
    /\ unrep \in [Rows -> UnrepStates]
    /\ awake \in BOOLEAN /\ up \in BOOLEAN /\ recovering \in BOOLEAN
    /\ budget \in 0..EnvBudget
    /\ live \in [Rows -> 0..MaxBytes]
    /\ aggActive \subseteq Rows
    /\ agg \in [Rows -> AggStages]
    /\ aggQuiet \in [Rows -> BOOLEAN]
    /\ rowEst \in [Rows -> RowStages]
    /\ suppress \in [Rows -> BOOLEAN] /\ grace \in [Rows -> BOOLEAN]
    /\ fgPending \in [Rows -> BOOLEAN] /\ newBytes \in [Rows -> BOOLEAN]
    /\ lateCb \in [Rows -> BOOLEAN]
    /\ pubAgg \in AggDisplays
    /\ pubSpeed \in [Rows -> Speeds]
    /\ refreshPending \in BOOLEAN /\ watchdog \in BOOLEAN
    /\ aggTaint \in [Rows -> BOOLEAN] /\ cuRow \in [Rows -> BOOLEAN]
    /\ baseStale \in [Rows -> BOOLEAN] /\ rowTaint \in [Rows -> BOOLEAN]
    /\ pubMissing \subseteq Rows /\ pubAggTaint \in BOOLEAN /\ spuriousReset \in BOOLEAN
    /\ resetRows \subseteq Rows
    /\ shownAtCrash \in [Rows -> 0..MaxBytes]

\* The UI is live: the process runs, is foreground, and has reconciled.
Showing == up /\ awake /\ ~recovering

\* #379.  A published number accounts for every transfer of the batch: none that might be
\* moving is left out of the sum.
NoPartialSum == pubAgg = "number" => pubMissing = {}

\* #224, the aggregate.  A published number never rests on catch-up bytes appended to an
\* older baseline.
NoInflatedAggregate == pubAgg = "number" => ~pubAggTaint

\* #224, the row.  A published row speed never divides catch-up bytes by a post-wake interval.
NoInflatedRowRate == \A r \in Rows : pubSpeed[r] = "number" => ~rowTaint[r]

\* Once the scheduled refresh has run, the top of Downloads shows a speed or "Updating
\* speed..." exactly when some row is transferring.
AggregateMatchesBatch ==
    (Observing /\ ~refreshPending) => ((pubAgg = "hidden") <=> (Transferring = {}))

\* #416.  Only a wake, a new member, callbackGap of silence or a real loss resets the batch.
NoSpuriousReset == ~spuriousReset

\* The phase says active work only when something will move the row.
PhaseNoGhostWork ==
    Showing => \A r \in Rows : Phase(r) \in ActiveWorkPhases => HasWork(r)

\* The phase never reads idle while the row's task is running.
PhaseNeverIdleWhileTaskRuns ==
    Showing => \A r \in Rows : task[r] = "running" => Phase(r) \in ActiveWorkPhases

\* The sidebar counts a row as an active transfer only when it has work.
SidebarHonest == Showing => \A r \in SidebarActive : HasWork(r)

\* The health snapshot reports work exactly when some row has work.
HealthHonest == Showing => (HealthHasWork <=> \E r \in Rows : HasWork(r))

\* pu-33.  A row waiting for admission reads as waiting.
WaitingReadsAsWaiting == \A r \in Rows : Waiting(r) => Caption(r) = "waiting"

-----------------------------------------------------------------------------
(* Action properties                                                       *)

\* While the process lives and a row stays downloading, the bytes it shows never go down
\* unless a reducer effect reset them.  (Leaving `downloading` drops the optimistic overlay:
\* a paused or failed row shows its resumable bytes.  OfflineDownloadAggregateStats says so.)
BytesMonotone ==
    [][(up /\ up') =>
          \A r \in Rows :
             (Status(r) = "downloading" /\ Status(r)' = "downloading")
                => (Shown(r)' >= Shown(r) \/ r \in resetRows')]_vars

\* The same across a process death: a row that is still downloading after reconcile shows at
\* least what it showed before.  Finding S3 violates this.
RelaunchKeepsBytes ==
    [][(recovering /\ ~recovering') =>
          \A r \in Rows :
             (Status(r)' = "downloading" /\ r \notin resetRows')
                => Shown(r)' >= shownAtCrash[r]]_vars

-----------------------------------------------------------------------------
(* Liveness (FairSpec)                                                     *)

\* "Updating speed..." does not stay up for ever while a transferring row's bytes flow.
UpdatingResolves ==
    []<>~(Showing /\ pubAgg = "updating" /\ \E r \in Transferring : Flowing(r))

\* After a stall, a transferring row stops showing a speed.
SpeedSettlesAfterStall ==
    \A r \in Rows :
        <>[]((Showing /\ Life(r) = "transferring" /\ ~Flowing(r)) => pubSpeed[r] # "number")

\* The published speeds stop changing once interference stops.
EventuallyStable == <>[][pubAgg' = pubAgg /\ pubSpeed' = pubSpeed]_vars
=============================================================================
