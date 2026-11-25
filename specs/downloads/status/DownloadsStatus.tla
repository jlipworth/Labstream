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
(*              SegmentFinish and AppendLands (a static-range segment      *)
(*              finishes; its body is appended a moment later),            *)
(*              LateCallback (a callback already queued when Pause ran),   *)
(*              DeliverFinish, Finalize                                    *)
(*   Manager    Refresh (refreshRecords: rebuilds the published snapshot   *)
(*              and samples every row's rate estimator), WatchdogTick,     *)
(*              StallDetect, GrantRetry, StartTask, StartBlocked, Admit,   *)
(*              Reconcile                                                  *)
(*   Clock      SettleExpire, GraceExpire, OverlapRipen, Expire, GoStale:  *)
(*              a timer running out                                        *)
(*   User/OS    Pause, Resume, Sleep, Wake, Stall, Unstall, BackendToggle, *)
(*              Crash, Relaunch, DropTask                                  *)
(*                                                                         *)
(* Lifecycle changes only through Reduce (DownloadsReducer.tla); each row  *)
(* keeps a whole reducer state.  The one hand-written transition is the    *)
(* B09 fix-off branch in LateCallback.                                     *)
(*                                                                         *)
(* Bytes exist three times.  `disk` is the index file.  `rec` is the       *)
(* store's live row, which a forward-only progress sample changes at once  *)
(* and which reaches `disk` only with a persistence ticket (a status       *)
(* change or the 1 s cadence).  `pubBytes` is what the last refresh put    *)
(* on screen.  A death keeps `disk` only.                                  *)
(*                                                                         *)
(* Time is abstract.  A rate estimator is the stage it has reached, not    *)
(* its numbers:                                                            *)
(*   aggregate, per transfer   none -> settling -> settled -> window       *)
(*   per row                   none -> baseline -> window -> decaying      *)
(* `aggAge` is how long ago the transfer's last callback was (under 3.5 s, *)
(* 3.5 s to callbackGap, longer), and `aggOvl` with `ovlRipe` say whether  *)
(* the transfers' windows share the 0.5 s that rate(at:) needs.            *)
(* The numeric side (interpolation, windows, clamps) is covered by the     *)
(* seeded tests in DownloadsFormalModelStatusTests.swift.                  *)
(*                                                                         *)
(* Timing assumptions, each one a guard that says so:                      *)
(*   A1  Bytes that piled up while the app could not see them are all      *)
(*       reported, and sampled by the refresh their callback schedules,    *)
(*       within 4 s of the first callback after it can see again           *)
(*       (SettleExpire, GraceExpire).  How late that FIRST callback is,    *)
(*       is not assumed.  LateCatchUp = TRUE lifts A1 (finding S7).        *)
(*   A2  A refresh that lands between two callbacks of a flowing row does  *)
(*       not zero its rate (RowSample: the "unchanged" arm).               *)
(*   A3  A scheduled refresh (0.5 to 1 s) runs before the user's next tap  *)
(*       (Resume).                                                         *)
(*   A4  A row whose bytes flow calls back at least every 3.5 s (Expire),  *)
(*       unless it is one of SlowRows (finding S6).                        *)
(*                                                                         *)
(* Not modelled: server preparation and its captions, the percentage       *)
(* arithmetic, side-asset bytes, background execution (a suspended app     *)
(* runs nothing), Delete, a user retry of a forward-only row, what a       *)
(* returning backend session resumes, a persistence ticket that has not    *)
(* reached the file when the process dies, and parallel segment trains     *)
(* beyond "a finished segment awaits its append".  See README.md.          *)
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
\* MODELS: PMSKit/Sources/PMSKit/Downloads/DownloadForwardOnlyStallTracker.swift
\* MODELS: PMSKit/Sources/PMSKit/Downloads/DownloadProgressDisplay.swift
\* MODELS: Labstream/Capabilities/Downloads/Core/DownloadManager.swift
\* MODELS: Labstream/Capabilities/Downloads/Core/DownloadStore.swift
\* MODELS: Labstream/Capabilities/Downloads/Core/BackgroundDownloadSession.swift
EXTENDS DownloadsReducer, DownloadsStatusPhase, TLC

CONSTANTS
    Rows,               \* download keys
    ForwardRows,        \* rows on the forward-only route; the rest are static-range
    PlannedRows,        \* rows that start `planned` (waiting for admission)
    StallRows,          \* rows whose transfer the network may silently stall
    SlowRows,           \* rows whose callbacks may come more than 3.5 s apart while bytes flow
    MaxBytes,           \* byte counters are 0..MaxBytes
    EnvBudget,          \* how many times the user, the OS and the network may interfere
    Endless,            \* TRUE: a transfer never finishes (its counter saturates)
    MaxStallRestarts,   \* DownloadStallRecoveryPolicy.defaultMaxAutomaticRestarts (2 in the code)
    LateCatchUp,        \* TRUE lifts timing assumption A1: bytes that piled up may be reported
                        \* after the 4 s settling and grace windows have run out
    Env,                \* which kinds of interference may happen (see EnvKinds)
    Mutant,             \* "none", or one deliberately injected bug (see Mutants)
    FixPu33,            \* a row waiting for admission says so (pu-33)
    FixB09,             \* progress never promotes a paused row (B09)
    SilentCountsAsZero,             \* PROPOSED (S1): a transfer silent for callbackGap in an
                                    \* awake process counts as zero instead of hiding the total
    WatchdogCoversTransfers,        \* PROPOSED (S2): the refresh loop runs while any row transfers
    ForwardFirstCallbackRebaseline, \* PROPOSED (S4): a forward-only row re-baselines on its first
                                    \* callback after foreground, as a static row does
    StallCapFails                   \* PROPOSED (S5): a stall past the restart cap fails the row

\* One protection removed at a time.  noGapReset and noGrace have no config: see README.md.
\*   partialSum      #379: the top speed is the sum of whichever estimates exist
\*   quietOmitted    #379: a member whose evidence ran out is left out of the sum
\*   noOverlap       #379: no common 0.5 s window is required
\*   noWakeReset     #224: foreground does not reset the aggregate estimator
\*   noGapReset      #224: a callback after callbackGap of silence does not reset the batch
\*   noSettling      #224: a transfer's first observation is a baseline at once
\*   noGrace         #224: foreground starts no per-row grace
\*   segmentNoHold   #416: a dip explained by bodies awaiting append reaches the estimator
\* The kinds of interference.  "backend": the rows' backend session goes away or comes back.
EnvKinds == {"pause", "resume", "stall", "unstall", "sleep", "crash", "dropTask", "backend"}

Mutants ==
    {"none", "partialSum", "quietOmitted", "noOverlap", "noWakeReset", "noGapReset",
     "noSettling", "noGrace", "segmentNoHold"}

ASSUME /\ ForwardRows \subseteq Rows /\ PlannedRows \subseteq Rows /\ StallRows \subseteq Rows
       /\ SlowRows \subseteq Rows
       /\ MaxBytes \in Nat \ {0} /\ EnvBudget \in Nat /\ MaxStallRestarts \in Nat
       /\ Mutant \in Mutants /\ Env \subseteq EnvKinds
       /\ {Endless, LateCatchUp, FixPu33, FixB09, SilentCountsAsZero,
           WatchdogCoversTransfers, ForwardFirstCallbackRebaseline, StallCapFails}
              \subseteq BOOLEAN

VARIABLES
    \* Durable or outside the process: survives Crash.
    row,            \* the index row: a whole reducer state
    disk,           \* DownloadRecord.bytes as the index file holds it
    task,           \* the row's URLSession task as the daemon sees it
    flow,           \* the network is delivering bytes to that task
    unrep,          \* bytes the daemon wrote that no callback has reported yet
    awake,          \* the app is foreground and running (FALSE: suspended)
    backendOn,      \* the rows' backend has a session (isBackendConfigured)
    budget,         \* interference left
    \* In memory: lost on Crash.
    up,
    recovering,     \* relaunch reconcile has not run yet
    rec,            \* DownloadRecord.bytes in the store's live row: a static row's checkpoint,
                    \* a forward-only row's reported total.  Reloaded from `disk` after a death.
    live,           \* liveRangeProgress: a static row's optimistic byte watermark
    debt,           \* a finished segment's body is not yet appended (claim debt, #416)
    jobs,           \* DownloadManager.activeJobs
    stalls,         \* DownloadForwardOnlyStallTracker.restartAttempts
    aggActive,      \* DownloadAggregateRateEstimator.activeTransfers
    agg,            \* that estimator's stage per transfer
    aggAge,         \* how old the transfer's last observation is
    aggOvl,         \* the transfer's last observation is 0.5 s past the batch's newest baseline
    ovlRipe,        \* 0.5 s have passed since the batch's newest baseline
    rowEst,         \* the per-row DownloadRateEstimator's stage
    suppress,       \* its post-rebaseline suppression is running
    grace,          \* rateEstimatorForegroundGraceUntil is in the future
    fgPending,      \* rateEstimatorForegroundProgressPending holds the row
    newBytes,       \* known bytes moved since the row estimator last sampled
    lateCb,         \* a progress callback queued before Pause cancelled its task
    pubAgg,         \* published: the speed at the top of Downloads
    pubSpeed,       \* published: each row's speed
    pubBytes,       \* published: each downloading row's bytes, as of the last refresh
    refreshPending, \* a refreshRecords is scheduled
    watchdog,       \* downloadWatchdogTask is running
    \* Ghosts: written, never read by a guard that models the app.  The one reader is the
    \* guard of timing assumption A1 in GraceExpire (cuRow).
    aggTaint,       \* the transfer's window had catch-up bytes appended to an older baseline
    cuRow,          \* known bytes gained catch-up bytes since the row estimator last sampled
    baseStale,      \* the row estimator's baseline was sampled while catch-up was outstanding
    rowTaint,       \* the row's window divides catch-up bytes by a post-wake interval
    pubMissing,     \* transfers the published number left out
    pubAggTaint,    \* the published number used a tainted window
    pubThin,        \* the published number used a window some transfer does not share
    spuriousReset,  \* a segment boundary reset the batch
    resetRows,      \* rows whose bytes the last step reset through a reducer effect
    shownAtCrash,   \* what each downloading row had published when the process died
    dipRows         \* rows reconcile kept as they were, with no callback since, until the
                    \* first refresh after it

durable == <<row, disk, task, flow, unrep, awake, backendOn, budget>>
memory == <<up, recovering, rec, live, debt, jobs, stalls, aggActive, agg, aggAge, aggOvl,
            ovlRipe, rowEst, suppress, grace, fgPending, newBytes, lateCb, pubAgg, pubSpeed,
            pubBytes, refreshPending, watchdog>>
ghosts == <<aggTaint, cuRow, baseStale, rowTaint, pubMissing, pubAggTaint, pubThin,
            spuriousReset, resetRows, shownAtCrash, dipRows>>
vars == <<durable, memory, ghosts>>

-----------------------------------------------------------------------------
(* Vocabulary                                                              *)

StaticRows == Rows \ ForwardRows
UnrepStates == {"none", "fresh", "catchup", "rest"}
\* Bytes written while the app could not see them: all of them ("catchup") or what is left
\* after a first callback reported part ("rest").
CatchUp == {"catchup", "rest"}
AggStages == {"none", "settling", "settled", "window"}
\* Since the transfer's last callback: under 3.5 s (the 4 s window less the 0.5 s minimum),
\* 3.5 s to callbackGap (6 s), or longer.
AggAges == {"fresh", "thin", "stale"}
RowStages == {"none", "baseline", "window", "decaying"}
AggDisplays == {"hidden", "updating", "number"}
Speeds == {"none", "number"}
StatusTaskStates == {"none", "running", "finished"}

Larger(a, b) == IF a >= b THEN a ELSE b
Life(r) == row[r].lifecycle

\* DownloadLifecycle.derivedStatus
StatusOf(L) ==
    CASE L \in {"planned", "admitted"} -> "queued"
      [] L = "serverPrep" -> "preparing"
      [] L \in {"transferring", "finalizing"} -> "downloading"
      [] OTHER -> L
Status(r) == StatusOf(Life(r))

\* Bytes the app knows of.  A forward-only row's reported total is its row's bytes; a static
\* row's row holds only its checkpoint and the optimistic total is in memory.
Known(r) == IF r \in ForwardRows THEN rec[r] ELSE Larger(rec[r], live[r])
\* DownloadManager.displayBytes: the live overlay counts only while the row is downloading.
Shown(r) == IF Status(r) = "downloading" THEN Known(r) ELSE rec[r]

Flowing(r) == task[r] = "running" /\ flow[r]
Transferring == {r \in Rows : Life(r) = "transferring"}

\* PhaseOf (DownloadsStatusPhase.tla) is DownloadRowStatusCaptionPolicy.phase as a function of the
\* facts it reads.
\* DownloadRecord.progress has reached 1: the server declared a size and the row's bytes equal it.
ProgressDone(r) == ~Endless /\ rec[r] = MaxBytes
\* DownloadManager.publishedRowPhase: `activeJobs.contains(key) || status == .downloading`.
IsActive(r) == r \in jobs \/ Status(r) = "downloading"
Phase(r) ==
    PhaseOf(Life(r), Shown(r) = 0, ProgressDone(r), IsActive(r), r \in StaticRows, backendOn)

\* DownloadJobSnapshot.persistedPhase
PersistedPhase(r) ==
    CASE Status(r) = "queued" -> "queued"
      [] Status(r) = "preparing" -> "activeServerPrep"
      [] Status(r) = "downloading" -> (IF rec[r] > 0 THEN "activeTransfer" ELSE "queued")
      [] Life(r) \in Playable -> "complete"
      [] OTHER -> Life(r)

\* DownloadJobPhase.isActiveWork, for the phases this model reaches.  `waitingForBackend` and
\* `inactiveTransfer` are not active work.
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
    /\ disk = Const(Rows, 0)
    /\ task = Const(Rows, "none")
    /\ flow = Const(Rows, FALSE)
    /\ unrep = Const(Rows, "none")
    /\ awake = TRUE
    /\ backendOn = TRUE
    /\ budget = EnvBudget
    /\ up = TRUE
    /\ recovering = FALSE
    /\ rec = Const(Rows, 0)
    /\ live = Const(Rows, 0)
    /\ debt = Const(Rows, FALSE)
    \* An admitted row's start is under way.
    /\ jobs = Rows \ PlannedRows
    /\ stalls = Const(Rows, 0)
    /\ aggActive = {}
    /\ agg = Const(Rows, "none")
    /\ aggAge = Const(Rows, "fresh")
    /\ aggOvl = Const(Rows, FALSE)
    /\ ovlRipe = FALSE
    /\ rowEst = Const(Rows, "none")
    /\ suppress = Const(Rows, FALSE)
    /\ grace = Const(Rows, FALSE)
    /\ fgPending = Const(Rows, FALSE)
    /\ newBytes = Const(Rows, FALSE)
    /\ lateCb = Const(Rows, FALSE)
    /\ pubAgg = "hidden"
    /\ pubSpeed = Const(Rows, "none")
    /\ pubBytes = Const(Rows, 0)
    /\ refreshPending = FALSE
    /\ watchdog = FALSE
    /\ aggTaint = Const(Rows, FALSE)
    /\ cuRow = Const(Rows, FALSE)
    /\ baseStale = Const(Rows, FALSE)
    /\ rowTaint = Const(Rows, FALSE)
    /\ pubMissing = {}
    /\ pubAggTaint = FALSE
    /\ pubThin = FALSE
    /\ spuriousReset = FALSE
    /\ resetRows = {}
    /\ shownAtCrash = Const(Rows, 0)
    /\ dipRows = {}

\* Frames.  `resetRows` describes the last step only, so every action writes it.
NoReset == resetRows' = {}
KeepRowRate == UNCHANGED <<rowEst, suppress, grace, fgPending, newBytes, cuRow, baseStale,
                           rowTaint, pubSpeed>>
KeepAgg == UNCHANGED <<aggActive, agg, aggAge, aggOvl, ovlRipe, aggTaint, spuriousReset>>
KeepPublished == UNCHANGED <<pubAgg, pubMissing, pubAggTaint, pubThin, pubBytes>>
KeepProcess == UNCHANGED <<up, recovering, awake, backendOn, budget, shownAtCrash>>
KeepManager == UNCHANGED <<jobs, stalls, debt>>

\* A store write that carries a persistence ticket: the index file takes the whole snapshot.
Persist == disk' = rec'
\* The same for an action that leaves the bytes alone.
PersistSame == disk' = rec

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
    /\ UNCHANGED <<row, rec, disk, task, flow, live, lateCb, refreshPending, watchdog, dipRows>>
    /\ KeepRowRate /\ KeepAgg /\ KeepPublished /\ KeepProcess /\ KeepManager

DaemonFinish(r) ==
    /\ ~Endless
    /\ Flowing(r)
    /\ Known(r) > 0 \/ unrep[r] # "none"
    /\ task' = Upd(task, r, "finished")
    /\ NoReset
    /\ UNCHANGED <<row, rec, disk, flow, unrep, live, lateCb, refreshPending, watchdog, dipRows>>
    /\ KeepRowRate /\ KeepAgg /\ KeepPublished /\ KeepProcess /\ KeepManager

-----------------------------------------------------------------------------
(* DownloadAggregateRateEstimator.sample                                   *)

\* The estimator after transfer `r` reports.  `isCU`: the report carries catch-up bytes.
\* `regress`: the reported total is lower than the transfer's last one.
AggAfterSample(r, isCU, regress) ==
    LET \* "now - last.time >= callbackGap || bytes < last.bytes": reset the whole batch.
        gapReset == /\ Mutant # "noGapReset" /\ aggAge[r] = "stale"
                    /\ agg[r] # "none" \/ SilentCountsAsZero
        reset == gapReset \/ (regress /\ agg[r] # "none")
        base == IF reset THEN Const(Rows, "none") ELSE agg
        baseTaint == IF reset THEN Const(Rows, FALSE) ELSE aggTaint
        baseAge == IF reset THEN Const(Rows, "fresh") ELSE aggAge
        \* Mutant noSettling: the first observation is a baseline at once.
        next == IF Mutant # "noSettling"
                   THEN (CASE base[r] = "none" -> "settling"
                           [] base[r] = "settling" -> "settling"
                           [] OTHER -> "window")
                   ELSE (IF base[r] = "none" THEN "settled" ELSE "window")
        appended == base[r] \in {"settled", "window"}
    IN [agg |-> Upd(base, r, next),
        age |-> Upd(baseAge, r, "fresh"),
        taint |-> Upd(baseTaint, r, IF appended THEN baseTaint[r] \/ isCU ELSE FALSE),
        \* A replaced baseline is the batch's newest window start: nobody has an observation
        \* 0.5 s past it yet.  An appended one is past it when 0.5 s have gone by.
        ovl |-> IF appended THEN Upd(aggOvl, r, ovlRipe) ELSE Const(Rows, FALSE),
        ripe |-> appended /\ ovlRipe,
        didReset |-> reset]

\* Apply a sample from `r`, or drop it when `r` is not an active transfer.
SampleAggregate(r, isCU, regress) ==
    IF r \in aggActive
       THEN LET s == AggAfterSample(r, isCU, regress)
            IN /\ agg' = s.agg /\ aggAge' = s.age /\ aggTaint' = s.taint
               /\ aggOvl' = s.ovl /\ ovlRipe' = s.ripe
               /\ spuriousReset' = (spuriousReset \/ (regress /\ s.didReset))
       ELSE UNCHANGED <<agg, aggAge, aggTaint, aggOvl, ovlRipe, spuriousReset>>

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
           \* A finished segment has left the in-flight sum and its body is not appended yet,
           \* so the train total this callback computes is lower than the last one.
           \* rateSampleBytes holds the previous sample when that debt explains the dip (#416).
           dip == r \in StaticRows /\ debt[r] /\ Mutant = "segmentNoHold"
       IN /\ IsApplied(t)
          /\ row' = Upd(row, r, t.state)
          /\ IF r \in ForwardRows
                THEN /\ rec' = Upd(rec, r, bumped) /\ UNCHANGED live
                     \* submitProgress: a sample that changes the status, or that the 1 s
                     \* cadence selects, gets a persistence ticket.  Any other changes the live
                     \* row only.
                     /\ IF t.state.lifecycle # Life(r) THEN Persist
                                                       ELSE disk' \in {disk, rec'}
                     \* Forward progress gives the stall tracker its restart budget back.
                     /\ stalls' = Upd(stalls, r, 0)
                ELSE /\ live' = Upd(live, r, bumped)
                     /\ UNCHANGED <<rec, disk, stalls>>
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
          /\ SampleAggregate(r, isCU, dip)
    /\ refreshPending' = TRUE
    /\ dipRows' = dipRows \ {r}
    /\ NoReset
    /\ UNCHANGED <<task, flow, lateCb, watchdog, aggActive, jobs, debt>>
    /\ UNCHANGED <<pubAgg, pubMissing, pubAggTaint, pubThin, pubBytes>> /\ KeepProcess

\* A static-range segment finishes.  It leaves the in-flight sum at once; its body is appended
\* to the durable partial a moment later.
SegmentFinish(r) ==
    /\ Observing /\ ~recovering
    /\ r \in StaticRows /\ task[r] = "running" /\ Life(r) = "transferring"
    /\ live[r] > rec[r] /\ ~debt[r]
    /\ debt' = Upd(debt, r, TRUE)
    /\ NoReset
    /\ UNCHANGED <<row, rec, disk, task, flow, unrep, live, lateCb, refreshPending, watchdog,
                   jobs, stalls, dipRows>>
    /\ KeepRowRate /\ KeepAgg /\ KeepPublished /\ KeepProcess

\* The append lands: the checkpoint takes every byte reported so far.  The file is the
\* checkpoint, so it is durable at once.
AppendLands(r) ==
    /\ Observing /\ ~recovering
    /\ debt[r]
    /\ debt' = Upd(debt, r, FALSE)
    /\ rec' = Upd(rec, r, Larger(rec[r], live[r]))
    /\ Persist
    /\ refreshPending' = TRUE
    /\ NoReset
    /\ UNCHANGED <<row, task, flow, unrep, live, lateCb, watchdog, jobs, stalls, dipRows>>
    /\ KeepRowRate /\ KeepAgg /\ KeepPublished /\ KeepProcess

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
    /\ UNCHANGED <<rec, disk, task, flow, unrep, live, watchdog, dipRows>>
    /\ KeepRowRate /\ KeepAgg /\ KeepPublished /\ KeepProcess /\ KeepManager

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
    /\ Persist
    /\ debt' = Upd(debt, r, FALSE)
    /\ refreshPending' = TRUE
    /\ NoReset
    /\ UNCHANGED <<live, lateCb, watchdog, jobs, stalls, dipRows>>
    /\ KeepRowRate /\ KeepAgg /\ KeepPublished /\ KeepProcess

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
    /\ PersistSame
    /\ refreshPending' = TRUE
    /\ NoReset
    /\ UNCHANGED <<rec, task, flow, unrep, live, lateCb, watchdog, dipRows>>
    /\ KeepRowRate /\ KeepAgg /\ KeepPublished /\ KeepProcess /\ KeepManager

-----------------------------------------------------------------------------
(* The manager                                                             *)

Admit(r) ==
    /\ Observing /\ ~recovering
    /\ LET t == Reduce(row[r], Ev("admissionGranted"), NoFacts)
       IN /\ IsApplied(t)
          /\ row' = Upd(row, r, t.state)
    /\ jobs' = jobs \cup {r}
    /\ PersistSame
    /\ refreshPending' = TRUE
    /\ NoReset
    /\ UNCHANGED <<rec, task, flow, unrep, live, lateCb, watchdog, stalls, debt, dipRows>>
    /\ KeepRowRate /\ KeepAgg /\ KeepPublished /\ KeepProcess

\* The grant of a retry that a stall restart requested: the row starts again as a new attempt.
GrantRetry(r) ==
    /\ Observing /\ ~recovering
    \* restartStalledForwardOnlyStreamAsync calls refreshRecords before it asks for admission.
    /\ ~refreshPending
    /\ Life(r) = "failed" /\ row[r].admissionIntent = "retryRequested"
    /\ LET t == Reduce(row[r], EvRetry("freshAttempt"), NoFacts)
       IN /\ IsApplied(t)
          /\ row' = Upd(row, r, t.state)
    /\ jobs' = jobs \cup {r}
    /\ PersistSame
    /\ refreshPending' = TRUE
    /\ NoReset
    /\ UNCHANGED <<rec, task, flow, unrep, live, lateCb, watchdog, stalls, debt, dipRows>>
    /\ KeepRowRate /\ KeepAgg /\ KeepPublished /\ KeepProcess

\* The session creates the task and submits transferStarted with it.  A forward-only stream
\* starts from byte 0.
StartTask(r) ==
    /\ Observing /\ ~recovering
    /\ backendOn
    /\ Life(r) = "admitted" /\ task[r] = "none"
    /\ LET t == Reduce(row[r], Ev("transferStarted"), NoFacts)
       IN /\ IsApplied(t)
          /\ row' = Upd(row, r, t.state)
    /\ task' = Upd(task, r, "running")
    /\ flow' = Upd(flow, r, TRUE)
    /\ unrep' = Upd(unrep, r, "none")
    /\ rec' = IF r \in ForwardRows THEN Upd(rec, r, 0) ELSE rec
    /\ Persist
    /\ jobs' = jobs \cup {r}
    \* A new task: the session rejects callbacks of the one Pause cancelled (B12).
    /\ lateCb' = Upd(lateCb, r, FALSE)
    /\ refreshPending' = TRUE
    /\ NoReset
    /\ UNCHANGED <<live, watchdog, stalls, debt, dipRows>>
    /\ KeepRowRate /\ KeepAgg /\ KeepPublished /\ KeepProcess

\* A start that finds no backend session parks the row until one returns.
StartBlocked(r) ==
    /\ Observing /\ ~recovering
    /\ ~backendOn
    /\ Life(r) = "admitted" /\ task[r] = "none"
    /\ LET t == Reduce(row[r], EvBackendUnavailable("awaitingSession"), NoFacts)
       IN /\ IsApplied(t)
          /\ row' = Upd(row, r, t.state)
    /\ jobs' = jobs \ {r}
    /\ PersistSame
    /\ refreshPending' = TRUE
    /\ NoReset
    /\ UNCHANGED <<rec, task, flow, unrep, live, lateCb, watchdog, stalls, debt, dipRows>>
    /\ KeepRowRate /\ KeepAgg /\ KeepPublished /\ KeepProcess

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
           kept(r) == ~added /\ r \in active
           a1 == [r \in Rows |-> IF kept(r) THEN agg[r] ELSE "none"]
           g1 == [r \in Rows |-> IF kept(r) THEN aggAge[r] ELSE "fresh"]
           o1 == [r \in Rows |-> kept(r) /\ aggOvl[r]]
           t1 == [r \in Rows |-> kept(r) /\ aggTaint[r]]
           \* rate(at:).  Two observations, settled, and the last one inside the window.
           contributes(r) == a1[r] = "window" /\ g1[r] = "fresh"
           \* PROPOSED (S1): silent for callbackGap in an awake process counts as zero.
           zero(r) == SilentCountsAsZero /\ g1[r] = "stale"
           \* "duration >= minimumWindow": the contributing windows share 0.5 s.
           shared == \A r \in active : contributes(r) => o1[r]
           number ==
               /\ active # {}
               /\ CASE Mutant = "partialSum" -> \E r \in active : contributes(r)
                    [] Mutant = "quietOmitted" ->
                          /\ shared /\ \E r \in active : contributes(r)
                          /\ \A r \in active : contributes(r) \/ g1[r] # "fresh"
                    [] Mutant = "noOverlap" -> \A r \in active : contributes(r) \/ zero(r)
                    [] OTHER -> shared /\ \A r \in active : contributes(r) \/ zero(r)
           sample == [r \in Rows |-> RowSample(r)]
       IN /\ aggActive' = active
          /\ agg' = a1 /\ aggAge' = g1 /\ aggOvl' = o1 /\ aggTaint' = t1
          /\ ovlRipe' = (~added /\ ovlRipe)
          \* OfflineDownloadAggregateStats.make
          /\ pubAgg' = IF number THEN "number"
                       ELSE IF active # {} THEN "updating" ELSE "hidden"
          \* Left out of the sum: a member that neither contributes nor is counted as zero.
          /\ pubMissing' = IF number THEN {r \in active : ~contributes(r) /\ ~zero(r)} ELSE {}
          /\ pubAggTaint' = (number /\ \E r \in active : contributes(r) /\ t1[r])
          /\ pubThin' = (number /\ \E r \in active : contributes(r) /\ ~o1[r])
          /\ rowEst' = [r \in Rows |-> sample[r].est]
          /\ pubSpeed' = [r \in Rows |-> sample[r].speed]
          /\ pubBytes' = [r \in Rows |-> IF Status(r) = "downloading" THEN Shown(r) ELSE 0]
          /\ baseStale' = [r \in Rows |-> sample[r].stale]
          /\ rowTaint' = [r \in Rows |-> sample[r].taint]
          /\ newBytes' = Const(Rows, FALSE)
          /\ cuRow' = Const(Rows, FALSE)
          \* Rate state is kept only for rows that are downloading.
          /\ suppress' = [r \in Rows |-> Status(r) = "downloading" /\ suppress[r]]
          /\ grace' = [r \in Rows |-> Status(r) = "downloading" /\ grace[r]]
          /\ fgPending' = [r \in Rows |-> Status(r) = "downloading" /\ fgPending[r]]
          /\ watchdog' = (number \/ \E r \in Rows : WatchRow(r))
    \* terminalReleaseKeys: a parked or finished row gives up its in-flight slot.
    /\ jobs' = {r \in jobs : Life(r) \notin Terminal \cup {"paused"}}
    /\ refreshPending' = FALSE
    /\ dipRows' = {}
    /\ NoReset
    /\ UNCHANGED <<row, rec, disk, task, flow, unrep, live, lateCb, spuriousReset, stalls, debt>>
    /\ KeepProcess

\* The watchdog loop: every second while a number shows, every 15 s otherwise.
WatchdogTick ==
    /\ Observing
    /\ watchdog /\ ~refreshPending
    /\ refreshPending' = TRUE
    /\ NoReset
    /\ UNCHANGED <<row, rec, disk, task, flow, unrep, live, lateCb, watchdog, dipRows>>
    /\ KeepRowRate /\ KeepAgg /\ KeepPublished /\ KeepProcess /\ KeepManager

\* detectForwardOnlyStreamStalls and restartStalledForwardOnlyStream.  Only forward-only streams
\* have a stall verdict, and only while the tracker's restart budget lasts: the stalled attempt
\* fails and a retry is requested, which goes through admission.  At the cap
\* shouldRestartForwardOnlyStream answers no and nothing else looks at the row.
StallDetect(r) ==
    /\ Observing /\ ~recovering
    /\ watchdog
    /\ r \in ForwardRows /\ Life(r) = "transferring"
    /\ task[r] = "running" /\ ~flow[r] /\ unrep[r] = "none"
    /\ LET restart == stalls[r] < MaxStallRestarts
           t == Reduce(row[r], Ev("stallDetected"), NoFacts)
           again == Reduce(t.state, EvIntent("admissionRequested", "retryRequested"), NoFacts)
       IN /\ restart \/ StallCapFails
          /\ IsApplied(t)
          /\ IF restart
                THEN /\ IsApplied(again)
                     /\ row' = Upd(row, r, again.state)
                     /\ stalls' = Upd(stalls, r, stalls[r] + 1)
                \* PROPOSED (S5): past the cap the row fails and waits for the user.
                ELSE row' = Upd(row, r, t.state) /\ UNCHANGED stalls
    /\ task' = Upd(task, r, "none")
    /\ jobs' = jobs \ {r}
    /\ PersistSame
    /\ refreshPending' = TRUE
    /\ NoReset
    /\ UNCHANGED <<rec, flow, unrep, live, lateCb, watchdog, debt, dipRows>>
    /\ KeepRowRate /\ KeepAgg /\ KeepPublished /\ KeepProcess

\* beginDownloadRateForegroundRebaseline, shared by Wake and Relaunch.
ForegroundRebaseline ==
    /\ IF Mutant # "noWakeReset"
          THEN /\ agg' = Const(Rows, "none")
               /\ aggAge' = Const(Rows, "fresh")
               /\ aggOvl' = Const(Rows, FALSE)
               /\ ovlRipe' = FALSE
               /\ aggTaint' = Const(Rows, FALSE)
          ELSE UNCHANGED <<agg, aggAge, aggOvl, ovlRipe, aggTaint>>
    /\ IF Mutant # "noGrace"
          THEN /\ grace' = [r \in Rows |-> grace[r] \/ Status(r) = "downloading"]
               /\ pubSpeed' = [r \in Rows |-> IF Status(r) = "downloading" THEN "none"
                                                                           ELSE pubSpeed[r]]
          ELSE UNCHANGED <<grace, pubSpeed>>
    /\ fgPending' = [r \in Rows |->
            \/ fgPending[r]
            \/ /\ Status(r) = "downloading"
               /\ r \in StaticRows \/ ForwardFirstCallbackRebaseline]

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
          /\ dipRows' = Rows \ (zeroed \cup toCheckpoint)
    /\ Persist
    /\ recovering' = FALSE
    /\ refreshPending' = TRUE
    /\ UNCHANGED <<task, flow, unrep, lateCb, watchdog, up, awake, backendOn, budget,
                   shownAtCrash>>
    /\ KeepRowRate /\ KeepAgg /\ KeepPublished /\ KeepManager

-----------------------------------------------------------------------------
(* The clock                                                               *)

\* settlingDuration (4 s) has passed since the transfer's first callback.  A1.
SettleExpire(r) ==
    /\ Observing
    /\ agg[r] = "settling"
    /\ LateCatchUp \/ unrep[r] \notin CatchUp
    /\ agg' = Upd(agg, r, "settled")
    /\ NoReset
    /\ UNCHANGED <<row, rec, disk, task, flow, unrep, live, lateCb, refreshPending, watchdog,
                   aggActive, aggAge, aggOvl, ovlRipe, aggTaint, spuriousReset, dipRows>>
    /\ KeepRowRate /\ KeepPublished /\ KeepProcess /\ KeepManager

\* The 4 s foreground grace and the 4 s rebaseline suppression run out.  A1 covers only the
\* remainder after a first callback, and the refresh that each callback schedules within a
\* second: nothing bounds how late that first callback is.
GraceExpire(r) ==
    /\ Observing
    /\ grace[r] \/ suppress[r]
    /\ LateCatchUp \/ (unrep[r] # "rest" /\ ~cuRow[r])
    /\ grace' = Upd(grace, r, FALSE)
    /\ suppress' = Upd(suppress, r, FALSE)
    /\ NoReset
    /\ UNCHANGED <<row, rec, disk, task, flow, unrep, live, lateCb, refreshPending, watchdog,
                   rowEst, fgPending, newBytes, cuRow, baseStale, rowTaint, pubSpeed, dipRows>>
    /\ KeepAgg /\ KeepPublished /\ KeepProcess /\ KeepManager

\* minimumWindow (0.5 s) has passed since the batch's newest baseline.
OverlapRipen ==
    /\ Observing
    /\ ~ovlRipe /\ \E r \in aggActive : agg[r] # "none"
    /\ ovlRipe' = TRUE
    /\ NoReset
    /\ UNCHANGED <<row, rec, disk, task, flow, unrep, live, lateCb, refreshPending, watchdog,
                   aggActive, agg, aggAge, aggOvl, aggTaint, spuriousReset, dipRows>>
    /\ KeepRowRate /\ KeepPublished /\ KeepProcess /\ KeepManager

\* An active transfer's last observation leaves the window: 3.5 s with no callback (the 4 s
\* window less the 0.5 s minimum) and the batch has no common interval.  A4: a row whose bytes
\* flow calls back more often than that, unless it is one of SlowRows.  Nothing orders this
\* against the row's own decay, which needs about 4 s of quiet refreshes: the seeded test for
\* finding S2 shows the aggregate goes first.
Expire(r) ==
    /\ Observing
    /\ r \in aggActive /\ aggAge[r] = "fresh"
    /\ r \in SlowRows \/ (~Flowing(r) /\ unrep[r] = "none")
    /\ aggAge' = Upd(aggAge, r, "thin")
    /\ NoReset
    /\ UNCHANGED <<row, rec, disk, task, flow, unrep, live, lateCb, refreshPending, watchdog,
                   aggActive, agg, aggOvl, ovlRipe, aggTaint, spuriousReset, dipRows>>
    /\ KeepRowRate /\ KeepPublished /\ KeepProcess /\ KeepManager

\* callbackGap (6 s) with no callback: the transfer's next sample resets the batch.
GoStale(r) ==
    /\ Observing
    /\ r \in aggActive /\ aggAge[r] = "thin"
    /\ ~Flowing(r) /\ unrep[r] = "none"
    /\ aggAge' = Upd(aggAge, r, "stale")
    /\ NoReset
    /\ UNCHANGED <<row, rec, disk, task, flow, unrep, live, lateCb, refreshPending, watchdog,
                   aggActive, agg, aggOvl, ovlRipe, aggTaint, spuriousReset, dipRows>>
    /\ KeepRowRate /\ KeepPublished /\ KeepProcess /\ KeepManager

-----------------------------------------------------------------------------
(* The user, the OS and the network.  Each step spends budget.             *)

Spend(kind) == kind \in Env /\ budget > 0 /\ budget' = budget - 1
KeepProcessButBudget == UNCHANGED <<up, recovering, awake, backendOn, shownAtCrash>>

Pause(r) ==
    /\ Spend("pause")
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
    /\ debt' = Upd(debt, r, FALSE)
    /\ jobs' = jobs \ {r}
    /\ PersistSame
    /\ refreshPending' = TRUE
    /\ NoReset
    /\ UNCHANGED <<rec, watchdog, stalls, dipRows>>
    /\ KeepRowRate /\ KeepAgg /\ KeepPublished /\ KeepProcessButBudget

\* Resume of a static row from its checkpoint.  A forward-only row is not resumed here.
\* A3: the refresh that the pause scheduled has run before the user taps again.
Resume(r) ==
    /\ Spend("resume")
    /\ Observing /\ ~recovering /\ ~refreshPending
    /\ r \in StaticRows /\ Life(r) = "paused"
    /\ LET t == Reduce(row[r], EvRetry("staticCheckpoint"), NoFacts)
       IN /\ IsApplied(t)
          /\ row' = Upd(row, r, t.state)
    /\ lateCb' = Upd(lateCb, r, FALSE)
    /\ jobs' = jobs \cup {r}
    /\ PersistSame
    /\ refreshPending' = TRUE
    /\ NoReset
    /\ UNCHANGED <<rec, task, flow, unrep, live, watchdog, stalls, debt, dipRows>>
    /\ KeepRowRate /\ KeepAgg /\ KeepPublished /\ KeepProcessButBudget

\* The network stops delivering to one task, with no error.
Stall(r) ==
    /\ Spend("stall")
    /\ r \in StallRows /\ Flowing(r)
    /\ flow' = Upd(flow, r, FALSE)
    /\ NoReset
    /\ UNCHANGED <<row, rec, disk, task, unrep, live, lateCb, refreshPending, watchdog, dipRows>>
    /\ KeepRowRate /\ KeepAgg /\ KeepPublished /\ KeepProcessButBudget /\ KeepManager

Unstall(r) ==
    /\ Spend("unstall")
    /\ task[r] = "running" /\ ~flow[r]
    /\ flow' = Upd(flow, r, TRUE)
    /\ NoReset
    /\ UNCHANGED <<row, rec, disk, task, unrep, live, lateCb, refreshPending, watchdog, dipRows>>
    /\ KeepRowRate /\ KeepAgg /\ KeepPublished /\ KeepProcessButBudget /\ KeepManager

\* The backend's session goes away (sign-out, a server switch) or comes back.  Running
\* transfers keep their URLs; a start needs the session.
BackendToggle ==
    /\ Spend("backend")
    /\ up
    /\ backendOn' = ~backendOn
    /\ refreshPending' = TRUE
    /\ NoReset
    /\ UNCHANGED <<row, rec, disk, task, flow, unrep, live, lateCb, watchdog, dipRows,
                   up, recovering, awake, shownAtCrash>>
    /\ KeepRowRate /\ KeepAgg /\ KeepPublished /\ KeepManager

\* The device sleeps and the app is suspended; its memory stays.  After a long sleep (longer
\* than callbackGap) every timer has run out by the time it wakes.  After a nap none has.
Sleep ==
    /\ Spend("sleep")
    /\ Observing /\ ~recovering
    /\ awake' = FALSE
    /\ \E long \in BOOLEAN :
          IF long
             THEN /\ aggAge' = Const(Rows, "stale")
                  /\ grace' = Const(Rows, FALSE)
                  /\ suppress' = Const(Rows, FALSE)
             ELSE UNCHANGED <<aggAge, grace, suppress>>
    /\ NoReset
    /\ UNCHANGED <<row, rec, disk, task, flow, unrep, live, lateCb, refreshPending, watchdog,
                   aggActive, agg, aggOvl, ovlRipe, aggTaint, spuriousReset, rowEst, fgPending,
                   newBytes, cuRow, baseStale, rowTaint, pubSpeed, up, recovering, backendOn,
                   shownAtCrash, dipRows>>
    /\ KeepPublished /\ KeepManager

\* The scene becomes active again.
Wake ==
    /\ up /\ ~awake
    /\ awake' = TRUE
    /\ ForegroundRebaseline
    /\ refreshPending' = TRUE
    /\ NoReset
    /\ UNCHANGED <<row, rec, disk, task, flow, unrep, live, lateCb, watchdog, aggActive,
                   spuriousReset, rowEst, suppress, newBytes, cuRow, baseStale, rowTaint,
                   up, recovering, backendOn, budget, shownAtCrash, dipRows>>
    /\ UNCHANGED <<pubAgg, pubMissing, pubAggTaint, pubThin, pubBytes>> /\ KeepManager

\* The process dies.  Every in-memory variable returns to its Init value; the row's bytes
\* are what the index file holds.
Crash ==
    /\ Spend("crash")
    /\ up
    /\ up' = FALSE
    /\ recovering' = FALSE
    /\ rec' = disk
    /\ live' = Const(Rows, 0)
    /\ debt' = Const(Rows, FALSE)
    /\ jobs' = {}
    /\ stalls' = Const(Rows, 0)
    /\ aggActive' = {}
    /\ agg' = Const(Rows, "none")
    /\ aggAge' = Const(Rows, "fresh")
    /\ aggOvl' = Const(Rows, FALSE)
    /\ ovlRipe' = FALSE
    /\ rowEst' = Const(Rows, "none")
    /\ suppress' = Const(Rows, FALSE)
    /\ grace' = Const(Rows, FALSE)
    /\ fgPending' = Const(Rows, FALSE)
    /\ newBytes' = Const(Rows, FALSE)
    /\ lateCb' = Const(Rows, FALSE)
    /\ pubAgg' = "hidden"
    /\ pubSpeed' = Const(Rows, "none")
    /\ pubBytes' = Const(Rows, 0)
    /\ refreshPending' = FALSE
    /\ watchdog' = FALSE
    /\ aggTaint' = Const(Rows, FALSE)
    /\ cuRow' = Const(Rows, FALSE)
    /\ baseStale' = Const(Rows, FALSE)
    /\ rowTaint' = Const(Rows, FALSE)
    /\ pubMissing' = {}
    /\ pubAggTaint' = FALSE
    /\ pubThin' = FALSE
    \* What the screen showed: the last published snapshot, not the live rows.
    /\ shownAtCrash' = pubBytes
    /\ dipRows' = {}
    /\ NoReset
    /\ UNCHANGED <<row, disk, task, flow, unrep, awake, backendOn, spuriousReset>>

\* A foreground launch: the rate boundary starts at once, reconcile follows.
Relaunch ==
    /\ ~up
    /\ up' = TRUE
    /\ awake' = TRUE
    /\ recovering' = TRUE
    /\ ForegroundRebaseline
    /\ refreshPending' = TRUE
    /\ NoReset
    /\ UNCHANGED <<row, rec, disk, task, flow, unrep, live, lateCb, watchdog, aggActive,
                   spuriousReset, rowEst, suppress, newBytes, cuRow, baseStale, rowTaint,
                   backendOn, budget, shownAtCrash, dipRows>>
    /\ UNCHANGED <<pubAgg, pubMissing, pubAggTaint, pubThin, pubBytes>> /\ KeepManager

\* While the app is dead the system discards a task (a force quit does this to all of them).
DropTask(r) ==
    /\ Spend("dropTask")
    /\ ~up /\ task[r] = "running"
    /\ task' = Upd(task, r, "none")
    /\ flow' = Upd(flow, r, FALSE)
    /\ unrep' = Upd(unrep, r, "none")
    /\ NoReset
    /\ UNCHANGED <<row, rec, disk, live, lateCb, refreshPending, watchdog, dipRows>>
    /\ KeepRowRate /\ KeepAgg /\ KeepPublished /\ KeepProcessButBudget /\ KeepManager

-----------------------------------------------------------------------------
(* Spec                                                                    *)

Next ==
    \/ Refresh \/ WatchdogTick \/ Reconcile \/ Sleep \/ Wake \/ Crash \/ Relaunch
    \/ OverlapRipen \/ BackendToggle
    \/ \E r \in Rows :
          \/ DaemonWrite(r) \/ DaemonFinish(r)
          \/ Callback(r) \/ SegmentFinish(r) \/ AppendLands(r) \/ LateCallback(r)
          \/ DeliverFinish(r) \/ Finalize(r)
          \/ Admit(r) \/ GrantRetry(r) \/ StartTask(r) \/ StartBlocked(r) \/ StallDetect(r)
          \/ SettleExpire(r) \/ GraceExpire(r) \/ Expire(r) \/ GoStale(r)
          \/ Pause(r) \/ Resume(r) \/ Stall(r) \/ Unstall(r) \/ DropTask(r)

Spec == Init /\ [][Next]_vars

\* Everything the app, the daemon and the clock do is fair, and so is coming back from a
\* sleep or a death.  Interference is not: it stops when the budget is spent.
FairSpec ==
    /\ Spec
    /\ WF_vars(Refresh) /\ WF_vars(WatchdogTick) /\ WF_vars(Reconcile)
    /\ WF_vars(Wake) /\ WF_vars(Relaunch) /\ WF_vars(OverlapRipen)
    /\ \A r \in Rows :
          /\ WF_vars(DaemonWrite(r)) /\ WF_vars(DaemonFinish(r))
          /\ WF_vars(Callback(r)) /\ WF_vars(SegmentFinish(r)) /\ WF_vars(AppendLands(r))
          /\ WF_vars(LateCallback(r))
          /\ WF_vars(DeliverFinish(r)) /\ WF_vars(Finalize(r))
          /\ WF_vars(Admit(r)) /\ WF_vars(GrantRetry(r)) /\ WF_vars(StartTask(r))
          /\ WF_vars(StartBlocked(r)) /\ WF_vars(StallDetect(r))
          /\ WF_vars(SettleExpire(r)) /\ WF_vars(GraceExpire(r))
          /\ WF_vars(Expire(r)) /\ WF_vars(GoStale(r))

RowSymmetry == Permutations(Rows)

-----------------------------------------------------------------------------
(* Invariants                                                              *)

TypeOK ==
    /\ \A r \in Rows : row[r].lifecycle \in Lifecycles
    /\ rec \in [Rows -> 0..MaxBytes] /\ disk \in [Rows -> 0..MaxBytes]
    /\ task \in [Rows -> StatusTaskStates]
    /\ flow \in [Rows -> BOOLEAN]
    /\ unrep \in [Rows -> UnrepStates]
    /\ awake \in BOOLEAN /\ up \in BOOLEAN /\ recovering \in BOOLEAN /\ backendOn \in BOOLEAN
    /\ budget \in 0..EnvBudget
    /\ live \in [Rows -> 0..MaxBytes]
    /\ debt \in [Rows -> BOOLEAN]
    /\ jobs \subseteq Rows
    /\ stalls \in [Rows -> 0..MaxStallRestarts]
    /\ aggActive \subseteq Rows
    /\ agg \in [Rows -> AggStages]
    /\ aggAge \in [Rows -> AggAges]
    /\ aggOvl \in [Rows -> BOOLEAN] /\ ovlRipe \in BOOLEAN
    /\ rowEst \in [Rows -> RowStages]
    /\ suppress \in [Rows -> BOOLEAN] /\ grace \in [Rows -> BOOLEAN]
    /\ fgPending \in [Rows -> BOOLEAN] /\ newBytes \in [Rows -> BOOLEAN]
    /\ lateCb \in [Rows -> BOOLEAN]
    /\ pubAgg \in AggDisplays
    /\ pubSpeed \in [Rows -> Speeds]
    /\ pubBytes \in [Rows -> 0..MaxBytes]
    /\ refreshPending \in BOOLEAN /\ watchdog \in BOOLEAN
    /\ aggTaint \in [Rows -> BOOLEAN] /\ cuRow \in [Rows -> BOOLEAN]
    /\ baseStale \in [Rows -> BOOLEAN] /\ rowTaint \in [Rows -> BOOLEAN]
    /\ pubMissing \subseteq Rows /\ pubAggTaint \in BOOLEAN /\ pubThin \in BOOLEAN
    /\ spuriousReset \in BOOLEAN
    /\ resetRows \subseteq Rows /\ dipRows \subseteq Rows
    /\ shownAtCrash \in [Rows -> 0..MaxBytes]

\* The UI is live: the process runs, is foreground, and has reconciled.
Showing == up /\ awake /\ ~recovering

\* #379.  A published number accounts for every transfer of the batch: none is left out of
\* the sum, whether it is warming up or has gone quiet.
NoPartialSum == pubAgg = "number" => pubMissing = {}

\* #379.  A published number is measured over an interval every counted transfer shares.
NoUnsharedWindow == pubAgg = "number" => ~pubThin

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

\* "Waiting for <backend>" is said only of a row with no session and no task.
PhaseBackendHonest ==
    Showing => \A r \in Rows :
        Phase(r) = "waitingForBackend" => (~backendOn /\ task[r] = "none")

\* The sidebar counts a row as an active transfer only when it has work.
SidebarHonest == Showing => \A r \in SidebarActive : HasWork(r)

\* The health snapshot reports work exactly when some row has work.
HealthHonest == Showing => (HealthHasWork <=> \E r \in Rows : HasWork(r))

\* pu-33.  A row waiting for admission reads as waiting.
WaitingReadsAsWaiting == \A r \in Rows : Waiting(r) => Caption(r) = "waiting"

\* The tracker never restarts a stream more often than its cap between two forward bytes.
StallRestartsCapped == \A r \in Rows : stalls[r] <= MaxStallRestarts

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

\* The same across a process death.  The first snapshot published after reconcile shows, for
\* every row that reconcile left as it was and that is still downloading, at least what the
\* last snapshot before the death showed.  A row whose callback already arrived is not
\* judged: the callback carries the daemon's own total.  Finding S3 violates this.
RelaunchKeepsBytes ==
    [][(up' /\ refreshPending /\ ~refreshPending') =>
          \A r \in dipRows :
             Status(r)' = "downloading" => pubBytes'[r] >= shownAtCrash[r]]_vars

-----------------------------------------------------------------------------
(* Liveness (FairSpec)                                                     *)

\* "Updating speed..." does not stay up for ever while a transferring row's bytes flow.
UpdatingResolves ==
    []<>~(Showing /\ pubAgg = "updating" /\ \E r \in Transferring : Flowing(r))

\* After a stall, a transferring row stops showing a speed.
SpeedSettlesAfterStall ==
    \A r \in Rows :
        <>[]((Showing /\ Life(r) = "transferring" /\ ~Flowing(r)) => pubSpeed[r] # "number")

\* A forward-only stream that has stopped moving does not stay `transferring` for ever: it
\* is restarted or it fails.  Finding S5 violates this.
ForwardStallGetsVerdict ==
    \A r \in ForwardRows :
        []<>~(/\ Showing /\ Life(r) = "transferring"
              /\ task[r] = "running" /\ ~flow[r] /\ unrep[r] = "none")

\* The published speeds stop changing once interference stops.  The model sees a speed only
\* as "a number" or "none", so this is about a figure appearing and disappearing, not about
\* its value.  Finding S6 violates this.
EventuallyStable == <>[][pubAgg' = pubAgg /\ pubSpeed' = pubSpeed]_vars
=============================================================================
