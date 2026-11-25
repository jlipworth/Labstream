------------------------- MODULE DownloadsRangeTrain -------------------------
(***************************************************************************)
(* The static-range lane of the downloads session: a train of parallel     *)
(* segment tasks, bodies that finish out of order and are held on disk     *)
(* under a durable manifest, in-order assembly into the working file, the  *)
(* two orphan sweeps, and recovery of the checkpoint after process death.  *)
(*                                                                         *)
(* A file is NSeg segments of SegBytes units ("bytes") each.  A body is    *)
(* <<attempt, offset, length>>: the response of the segment task that      *)
(* attempt started for that byte range.  The working file is `dur` bytes   *)
(* long, and a body may be appended only at offset `dur`.  A body that     *)
(* arrives ahead of the checkpoint is held:                                *)
(*                                                                         *)
(*   tmp/ stash  --rename-->  durable held file  --commit-->  manifest     *)
(*   (claimed by the queued hop)   (claimed by the hold)      (in the row) *)
(*                                                                         *)
(* and is appended by a drain pass once the checkpoint reaches it.         *)
(*                                                                         *)
(* Actors:                                                                 *)
(*   Planner    Plan (startRangeRemainder): drain, finalize, or top the    *)
(*              train up to Depth                                          *)
(*   Daemon     DaemonFinishes, DaemonFails (outlives the app)             *)
(*   Delegate   DidFinishDownloading, DidCompleteWithError                 *)
(*   Range IO   one serial queue: Apply (applyFinishedRangeBody),          *)
(*              ResourceChanged, HoldManifested, RetireDone                *)
(*   Finalizer  FinalizeOutcome                                            *)
(*   User       UserPause (+ PauseSweep), UserResume, UserRetry            *)
(*   Recovery   Reattach (restore of held bodies, adoption, both sweeps),  *)
(*              RelaunchObserved, AutoResume, StaleRowHeal                 *)
(*   Crash      Crash, CrashMidAppend, Relaunch                            *)
(*                                                                         *)
(* Abstractions (README.md lists what is not covered):                     *)
(*  - A body is whole or absent.  An append is atomic except at a crash:   *)
(*    CrashMidAppend leaves any proper prefix of the body in the working   *)
(*    file (the code appends in 4 MiB writes), so with SegBytes > 1 the    *)
(*    checkpoint can sit inside the grid the live train was planned on.    *)
(*    With SegBytes = 1 the model is segment-granular.                     *)
(*  - A task is named by its body, so one attempt never has two tasks for  *)
(*    one byte range; the planner waits for the slot instead.              *)
(*  - A held body's manifest commit and the completion that installs it    *)
(*    are one step (HoldManifested); a manifest removal, its file          *)
(*    deletion and its completion are one step (RetireDone).  The rename   *)
(*    that precedes the manifest is its own step, so the sweep can run     *)
(*    between the two.                                                     *)
(*  - A superseded or pause-swept task is cancelled at once.  A finished   *)
(*    task the pause sweep supersedes loses its body in the same step (the *)
(*    code ignores its finish callback later).                             *)
(*  - Resource validators are not modelled: a changed resource is the      *)
(*    environment step ResourceChanged, bounded by MaxRestarts.            *)
(*  - The train epoch is not a counter: when it advances, every queued     *)
(*    body is marked stale (`staleq`).                                     *)
(*  - Finalization is one step and always returns `complete`; Delete is    *)
(*    not modelled.  DownloadsSessionCore covers both.                     *)
(*  - A continuation (Plan) is always a later step.  The code runs it in   *)
(*    the same range-IO block when the finished task's entry carries its   *)
(*    request, and defers it to a request rebuild when it does not, which  *)
(*    is every task adopted after a relaunch.  The model is the deferred   *)
(*    case, which allows every ordering of the other.                      *)
(*  - After a relaunch nothing is planned before the reattach completion.  *)
(*                                                                         *)
(* Each row keeps a whole reducer state, and lifecycle changes only        *)
(* through Reduce.  There is no hand-written transition.                   *)
(***************************************************************************)
\* MODELS: Labstream/Capabilities/Downloads/Core/BackgroundDownloadSession.swift
\* MODELS: Labstream/Capabilities/Downloads/Core/DownloadStore.swift
\* MODELS: Labstream/Capabilities/Downloads/Core/StaticRangeTransferConfiguration.swift
\* MODELS: PMSKit/Sources/PMSKit/Downloads/StaticRangeSegmentAssemblyPolicy.swift
\* MODELS: PMSKit/Sources/PMSKit/Downloads/StaticRangeSegmentQueuePolicy.swift
\* MODELS: PMSKit/Sources/PMSKit/Downloads/StaticRangeTrainIntegrityPolicy.swift
\* MODELS: PMSKit/Sources/PMSKit/Downloads/StaticRangeFinishedBodyPolicy.swift
\* MODELS: PMSKit/Sources/PMSKit/Downloads/StaticRangeContinuationPolicy.swift
\* MODELS: PMSKit/Sources/PMSKit/Downloads/StaticRangeReattachPolicy.swift
\* MODELS: PMSKit/Sources/PMSKit/Downloads/BackgroundTempFileCleanupPolicy.swift
\* MODELS: PMSKit/Sources/PMSKit/DownloadRetryPolicy.swift
\* MODELS: PMSKit/Sources/PMSKit/Downloads/DownloadReconcileLiveWorkPolicy.swift
EXTENDS DownloadsReducer, TLC

CONSTANTS
    Rows,               \* download keys; every row is on the static-range route
    NSeg,               \* segments in a file
    SegBytes,           \* StaticRangeTransferConfiguration.segmentBytes, in model units
    Depth,              \* StaticRangeTransferConfiguration.maxQueuedSegments
    MaxAttempt,         \* attempt IDs are 1..MaxAttempt
    MaxRestarts,        \* how often the source may change under the train (all rows)
    FixB00,             \* the manager's stale-row detector and its retry policy measure the
                        \* attempt working partial, not the published path (852e9f7f)
    FixB03,             \* the tmp/ stash sweep rechecks the claim of a queued append
    FixB22,             \* the durable held path is claimed before the rename; the sweep honours it
    CheckTrainEpoch,    \* MUTATION SWITCH: FALSE applies a body whose train was torn down
    CheckAlignment,     \* MUTATION SWITCH: FALSE appends a body wherever the checkpoint is
    IntervalAwarePlan,  \* MUTATION SWITCH: FALSE plans a fresh full-size grid from the
                        \* checkpoint and skips a live segment only at an equal offset
    FixDrainContinues,  \* PROPOSED (not in the code): a drain that a removal completion runs
                        \* continues the train (plan or finalize) like every other drain (R1)
    FixReconcileOwnedWork, \* R2 (#476): reconcile asks the session, at the moment it
                        \* decides, whether it owns work for an active row, like the
                        \* stale-row self-heal does (DownloadReconcileLiveWorkPolicy)
    FixSnapshotOwnedWork, \* NOT IN THE CODE and NOT ENOUGH: reattach adds session-owned work
                        \* to the live-key snapshot it hands to reconcile (R2 as first proposed)
    FixHeadGapPlanned,  \* PROPOSED (not in the code): the planner always fetches the gap at
                        \* the checkpoint, even when held bodies already fill the depth (R4)
    FixPauseKeepsFinished, \* R3 (#474): the pause sweep leaves a finished segment task
                        \* tracked, so its body is written behind the pause
                        \* (StaticRangeFinishedBodyPolicy.pauseSweepDisposition)
    AllowFailure,       \* a transport error may be terminal instead of retried
    ForegroundReattach, \* allow reattach + reconcile while the process stays alive
    WakeWindsDown,      \* a background wake may end before a continuation refills the train
    BoundEnvironment,   \* TRUE: at most EnvBudget user/crash/foreground steps (liveness runs)
    EnvBudget

ASSUME /\ NSeg \in Nat \ {0} /\ SegBytes \in Nat \ {0} /\ Depth \in Nat \ {0}
       /\ MaxAttempt \in Nat \ {0} /\ MaxRestarts \in Nat /\ EnvBudget \in Nat

Attempts == 1..MaxAttempt
Total == NSeg * SegBytes
Offsets == 0..(Total - 1)
Lengths == 1..SegBytes
\* <<attempt, offset, length>>
Bodies == {b \in Attempts \X Offsets \X Lengths : b[2] + b[3] <= Total}
End(b) == b[2] + b[3]
Overlap(b, c) == b[2] < End(c) /\ c[2] < End(b)

\* SYMMETRY for safety configs: every row is static, so nothing tells two apart.
RowSymmetry == Permutations(Rows)

VARIABLES
    \* ---- durable: the index row (survives Crash) ----
    row,         \* [Rows -> reducer state]        DownloadLifecycleState
    owner,       \* [Rows -> Attempts]             the row's current attempt ID
    manifest,    \* [Rows -> SUBSET Bodies]        metadata.heldRangeSegments
    \* ---- durable: files (survive Crash) ----
    dur,         \* [Rows -> 0..Total]             bytes in the attempt working file
    published,   \* [Rows -> BOOLEAN]              the published, playable body
    stash,       \* [Rows -> SUBSET Bodies]        finished bodies in tmp/ (vp-range-body-*)
    heldFile,    \* [Rows -> SUBSET Bodies]        held bodies in Downloads (*.range-held-*)
    \* ---- the transfer daemon (survives Crash) ----
    task,        \* [Rows -> [Bodies -> TaskStates]]
    \* ---- in memory (lost at Crash) ----
    up,          \* BOOLEAN                        the app process is alive
    tracked,     \* [Rows -> SUBSET Bodies]        rangeInflight
    ioq,         \* [Rows -> SUBSET Bodies]        queued applyFinishedRangeBody hops (= tmp claims)
    staleq,      \* [Rows -> SUBSET Bodies]        queued bodies whose train epoch has passed
    renamed,     \* [Rows -> SUBSET Bodies]        held bodies renamed, manifest not yet committed
    held,        \* [Rows -> SUBSET Bodies]        heldRangeSegments
    retire,      \* [Rows -> SUBSET Bodies]        held bodies whose manifest removal is submitted
    halt,        \* [Rows -> HaltKinds]            rangeHaltKinds
    plan,        \* [Rows -> BOOLEAN]              a continuation / request rebuild is pending
    fin,         \* [Rows -> BOOLEAN]              the finalizer holds the row
    recon,       \* [Rows -> {"idle","launchReattach","needReattach","needReconcile"}]
    liveSnap,    \* [Rows -> BOOLEAN]              reattach's live-task snapshot for reconcile
    \* ---- environment bounds ----
    restarts,    \* 0..MaxRestarts
    budget,      \* 0..EnvBudget
    \* ---- ghosts (observe only; never read by an action's guard) ----
    misaligned,  \* BOOLEAN   a body was appended at an offset other than its own
    staleUse     \* BOOLEAN   a body of a torn-down train was appended or held

rowVars  == <<row, owner, manifest>>
fileVars == <<dur, published, stash, heldFile>>
memVars  == <<tracked, ioq, staleq, renamed, held, retire, halt, plan, fin, recon, liveSnap>>
envVars  == <<restarts, budget>>
ghosts   == <<misaligned, staleUse>>
vars     == <<rowVars, fileVars, task, up, memVars, envVars, ghosts>>

Life(r) == row[r].lifecycle
UserPaused(r) == Life(r) = "paused" /\ row[r].pauseCause = "user"
ActiveRow(r) == Life(r) \in {"admitted", "transferring"}
\* DownloadStore.ownsAttempt / BackgroundDownloadSession.stillOwnsAttempt
Owns(r, b) == owner[r] = b[1]
Mine(r, S) == {b \in S : b[1] = owner[r]}

Send(r, event) == Reduce(row[r], event, NoFacts)
\* Send it and store the result; a rejected event leaves the row alone.
Submit(r, event) ==
    LET t == Send(r, event)
    IN row' = IF IsApplied(t) THEN Upd(row, r, t.state) ELSE row

Spend == IF BoundEnvironment
            THEN budget > 0 /\ budget' = budget - 1
            ELSE UNCHANGED budget

TypeOK ==
    /\ \A r \in Rows : row[r].lifecycle \in Lifecycles
    /\ owner \in [Rows -> Attempts]
    /\ manifest \in [Rows -> SUBSET Bodies]
    /\ dur \in [Rows -> 0..Total]
    /\ published \in [Rows -> BOOLEAN]
    /\ stash \in [Rows -> SUBSET Bodies]
    /\ heldFile \in [Rows -> SUBSET Bodies]
    /\ task \in [Rows -> [Bodies -> TaskStates]]
    /\ up \in BOOLEAN
    /\ tracked \in [Rows -> SUBSET Bodies]
    /\ ioq \in [Rows -> SUBSET Bodies]
    /\ staleq \in [Rows -> SUBSET Bodies]
    /\ renamed \in [Rows -> SUBSET Bodies]
    /\ held \in [Rows -> SUBSET Bodies]
    /\ retire \in [Rows -> SUBSET Bodies]
    /\ halt \in [Rows -> HaltKinds]
    /\ plan \in [Rows -> BOOLEAN]
    /\ fin \in [Rows -> BOOLEAN]
    /\ recon \in [Rows -> {"idle", "launchReattach", "needReattach", "needReconcile"}]
    /\ liveSnap \in [Rows -> BOOLEAN]
    /\ restarts \in 0..MaxRestarts
    /\ budget \in 0..EnvBudget
    /\ misaligned \in BOOLEAN /\ staleUse \in BOOLEAN

Init ==
    /\ row = Const(Rows, InitialState("admitted"))
    /\ owner = Const(Rows, 1)
    /\ manifest = Const(Rows, {})
    /\ dur = Const(Rows, 0)
    /\ published = Const(Rows, FALSE)
    /\ stash = Const(Rows, {})
    /\ heldFile = Const(Rows, {})
    /\ task = Const(Rows, Const(Bodies, "none"))
    /\ up = TRUE
    /\ tracked = Const(Rows, {})
    /\ ioq = Const(Rows, {})
    /\ staleq = Const(Rows, {})
    /\ renamed = Const(Rows, {})
    /\ held = Const(Rows, {})
    /\ retire = Const(Rows, {})
    /\ halt = Const(Rows, "none")
    \* The admitted row's first start request is pending.
    /\ plan = Const(Rows, TRUE)
    /\ fin = Const(Rows, FALSE)
    /\ recon = Const(Rows, "idle")
    /\ liveSnap = Const(Rows, FALSE)
    /\ restarts = 0
    /\ budget = IF BoundEnvironment THEN EnvBudget ELSE 0
    /\ misaligned = FALSE
    /\ staleUse = FALSE

-----------------------------------------------------------------------------
(* Assembly: the drain pass and the planner's coverage                     *)

\* One pass of drainHeldRangeSegments over the held map H with removals R
\* already submitted, the working file at d bytes.
\* StaticRangeSegmentAssemblyPolicy.appendableRun: a held body that starts
\* behind the checkpoint is discarded (it is already durable, or it overlaps
\* the checkpoint without starting on it), the body exactly at the checkpoint
\* is appended, anything further waits.  A manifest removal is asynchronous,
\* and the pass stops as soon as it has submitted one, so it appends at most
\* one body; a body it appended stays in the map (now behind the checkpoint)
\* until RetireDone, and stops every later pass until then.  A halt stops
\* the pass.
DrainPass(r, d, H, R) ==
    LET mine == Mine(r, H)
        behind == {b \in mine : b[2] < d}
        next == {b \in mine : b[2] = d}
        same == [dur |-> d, retire |-> R, bad |-> FALSE]
    IN IF halt[r] # "none" THEN same
       ELSE IF behind # {} THEN [same EXCEPT !.retire = R \cup behind]
       ELSE IF CheckAlignment THEN
           (IF next # {}
               THEN LET b == CHOOSE x \in next : TRUE
                    IN [dur |-> End(b), retire |-> R \cup {b}, bad |-> FALSE]
               ELSE same)
       \* MUTATION: append any held body, wherever the checkpoint is.
       ELSE IF mine # {} THEN
           (LET b == CHOOSE x \in mine : TRUE
            IN [dur |-> d + b[3], retire |-> R \cup {b}, bad |-> b[2] # d])
       ELSE same

\* startRangeRemainder's liveSegments: every tracked task of the row, every
\* held body, and every claimed finished body of the current train.
LiveBodies(r) ==
    tracked[r] \cup Mine(r, held[r]) \cup Mine(r, (ioq[r] \ staleq[r]) \cup renamed[r])

Least(S) == CHOOSE x \in S : \A y \in S : x <= y

\* StaticRangeSegmentQueuePolicy.segmentsToEnqueue: walk from the checkpoint,
\* jump over every covered interval, and fill each gap with segments of at
\* most SegBytes that stop at the next covered start, until the depth left
\* over is used.  Coverage is by interval: after a crash in the middle of an
\* append the checkpoint is off the grid the live segments were planned on.
\* The result is a set of <<offset, length>>.
RECURSIVE PlanFrom(_, _, _)
PlanFrom(live, offset, room) ==
    IF room <= 0 \/ offset >= Total THEN {}
    ELSE LET covering ==
                 IF IntervalAwarePlan
                    THEN {b \in live : b[2] <= offset /\ offset < End(b)}
                    \* MUTATION: only a live segment at exactly this offset counts.
                    ELSE {b \in live : b[2] = offset}
         IN IF covering # {}
               THEN PlanFrom(live, End(CHOOSE b \in covering : TRUE), room)
               ELSE LET starts == {b[2] : b \in live} \cap ((offset + 1)..Total)
                        stop == IF IntervalAwarePlan /\ starts # {} THEN Least(starts) ELSE Total
                        len == Least({SegBytes, Total - offset, stop - offset})
                    IN {<<offset, len>>} \cup PlanFrom(live, offset + len, room - 1)

\* The depth left over is counted in segments, and a held body is one.  When
\* held bodies alone fill the depth and none of them covers the checkpoint,
\* nothing is left to fetch the gap they wait for (R4).
PlanSet(r, d) ==
    LET live == LiveBodies(r)
        room == Depth - Cardinality(live)
        headOpen == d < Total /\ ~\E b \in live : b[2] <= d /\ d < End(b)
    IN PlanFrom(live, d, IF FixHeadGapPlanned /\ headOpen /\ room < 1 THEN 1 ELSE room)

\* purgeHeldRangeSegments: every manifest of the row, with the files of the
\* held bodies and of the holds still in flight (their durable claims).
PurgeHeld(r) ==
    /\ manifest' = Upd(manifest, r, {})
    /\ heldFile' = Upd(heldFile, r, heldFile[r] \ (held[r] \cup retire[r] \cup manifest[r]
                         \cup (IF FixB22 THEN renamed[r] ELSE {})))
    /\ held' = Upd(held, r, {})
    /\ retire' = Upd(retire, r, {})

\* finalizeRangeWhole.  reducer: bodyAtWorking (publishTransferFinalizing).
FinalizeWhole(r) ==
    /\ PurgeHeld(r)
    /\ LET t == Send(r, Ev("bodyAtWorking"))
       IN /\ row' = IF IsApplied(t) THEN Upd(row, r, t.state) ELSE row
          /\ fin' = Upd(fin, r, IsApplied(t))
    /\ plan' = Upd(plan, r, FALSE)

\* The end of a range-IO block that left the working file at d bytes with
\* the removals R submitted.  A pause halt keeps the bytes and parks the row
\* (writeThenPause; reducer: pause); otherwise the block finalizes a whole
\* file or asks for the next plan (continueRangeAfterBody).  When a
\* background wake is winding down, the continuation keeps the checkpoint
\* and returns without refilling the train (reducer: transferRebuilding):
\* the row then waits for the next foreground recovery.
Continue(r, d, R) ==
    /\ dur' = Upd(dur, r, d)
    /\ IF halt[r] = "pause" THEN
           /\ Submit(r, EvPause("user"))
           /\ retire' = Upd(retire, r, R)
           /\ UNCHANGED <<manifest, heldFile, held, fin, plan>>
       ELSE IF d >= Total THEN FinalizeWhole(r)
       ELSE
           /\ retire' = Upd(retire, r, R)
           /\ \/ /\ plan' = Upd(plan, r, TRUE)
                 /\ UNCHANGED row
              \/ /\ WakeWindsDown /\ halt[r] = "none"
                 /\ Submit(r, Ev("transferRebuilding"))
                 /\ UNCHANGED plan
           /\ UNCHANGED <<manifest, heldFile, held, fin>>

-----------------------------------------------------------------------------
(* Planner                                                                 *)

\* startRangeRemainder: drain what is contiguous, finalize a whole file, or
\* enqueue segment tasks for the uncovered offsets.  reducer: transferStarted.
Plan(r) ==
    /\ up /\ plan[r] /\ ActiveRow(r) /\ halt[r] = "none"
    \* After a relaunch nothing is planned before the reattach completion.
    /\ recon[r] # "launchReattach"
    /\ LET dp == DrainPass(r, dur[r], held[r], retire[r])
           new == {<<owner[r], p[1], p[2]>> : p \in PlanSet(r, dp.dur)}
       IN /\ misaligned' = (misaligned \/ dp.bad)
          /\ dur' = Upd(dur, r, dp.dur)
          /\ IF dp.dur >= Total
                THEN /\ FinalizeWhole(r)
                     /\ UNCHANGED <<task, tracked>>
                ELSE \* A task is named by its body: wait for a busy slot.
                     /\ \A b \in new : /\ task[r][b] = "none"
                                       /\ b \notin stash[r] /\ b \notin ioq[r]
                     /\ task' = Upd(task, r, [b \in Bodies |->
                                    IF b \in new THEN "running" ELSE task[r][b]])
                     /\ tracked' = Upd(tracked, r, tracked[r] \cup new)
                     /\ retire' = Upd(retire, r, dp.retire)
                     /\ plan' = Upd(plan, r, FALSE)
                     /\ IF new # {} THEN Submit(r, Ev("transferStarted"))
                                    ELSE UNCHANGED row
                     /\ UNCHANGED <<manifest, heldFile, held, fin>>
    /\ UNCHANGED <<owner, published, stash, up, ioq, staleq, renamed, halt, recon, liveSnap,
                   envVars, staleUse>>

-----------------------------------------------------------------------------
(* Daemon: runs whether or not the app is alive                            *)

DaemonFinishes(r, b) ==
    /\ task[r][b] = "running"
    /\ task' = [task EXCEPT ![r][b] = "finished"]
    /\ UNCHANGED <<rowVars, fileVars, up, memVars, envVars, ghosts>>

DaemonFails(r, b) ==
    /\ task[r][b] = "running"
    /\ task' = [task EXCEPT ![r][b] = "failed"]
    /\ UNCHANGED <<rowVars, fileVars, up, memVars, envVars, ghosts>>

-----------------------------------------------------------------------------
(* Delegate callbacks                                                      *)

\* finishRangeRemainder.  The body leaves the OS temp for a tmp/ stash, the
\* stash is claimed and the apply is queued on the range-IO queue.  A cancel
\* halt discards the body; a pause halt keeps it.  An untracked task is a
\* dead finish and is adopted only for the row's exact attempt and a row that
\* is neither complete nor failed (adoptFinishedRangeSegment).
DidFinishDownloading(r, b) ==
    /\ up /\ task[r][b] = "finished"
    /\ task' = [task EXCEPT ![r][b] = "none"]
    /\ tracked' = Upd(tracked, r, tracked[r] \ {b})
    /\ LET keep == /\ Owns(r, b) /\ halt[r] # "cancel"
                   /\ (b \notin tracked[r] => Life(r) \notin {"complete", "failed"})
       IN /\ stash' = IF keep THEN Upd(stash, r, stash[r] \cup {b}) ELSE stash
          /\ ioq' = IF keep THEN Upd(ioq, r, ioq[r] \cup {b}) ELSE ioq
    /\ UNCHANGED <<rowVars, dur, published, heldFile, up, staleq, renamed, held, retire,
                   halt, plan, fin, recon, liveSnap, envVars, ghosts>>

\* setFailedPurgingHeldSegments: purge the held bodies, halt the attempt,
\* supersede and cancel the train, advance its epoch, then fail the row.
\* Every tracked task is superseded, also one that has already finished or
\* failed in the daemon: its callback is ignored when it arrives, which the
\* model folds into this step.
\* reducer: transferFailed.
TerminalFail(r) ==
    /\ PurgeHeld(r)
    /\ halt' = Upd(halt, r, "cancel")
    /\ task' = Upd(task, r, [x \in Bodies |->
                   IF x \in tracked[r] THEN "none" ELSE task[r][x]])
    /\ tracked' = Upd(tracked, r, {})
    /\ staleq' = Upd(staleq, r, ioq[r])
    /\ plan' = Upd(plan, r, FALSE)
    /\ Submit(r, EvReason("transferFailed", "network"))

\* urlSession(_:task:didCompleteWithError:) with an error.  A halted row
\* expects its cancellation.  Otherwise the segment is retried from the
\* durable checkpoint, or the retry budget is spent and the row fails.
DidCompleteWithError(r, b) ==
    /\ up /\ task[r][b] = "failed"
    /\ LET mine == b \in tracked[r] /\ Owns(r, b) /\ halt[r] = "none" /\ ActiveRow(r)
           forget == /\ task' = [task EXCEPT ![r][b] = "none"]
                     /\ tracked' = Upd(tracked, r, tracked[r] \ {b})
       IN \/ /\ forget
             /\ plan' = IF mine THEN Upd(plan, r, TRUE) ELSE plan
             /\ UNCHANGED <<row, manifest, heldFile, held, retire, halt, staleq>>
          \/ /\ AllowFailure /\ mine
             /\ TerminalFail(r)
    /\ UNCHANGED <<owner, dur, published, stash, up, ioq, renamed, fin, recon, liveSnap,
                   envVars, ghosts>>

-----------------------------------------------------------------------------
(* Range IO: one serial queue                                              *)

\* A queued body the apply may still use: its attempt owns the row, nothing
\* cancelled it, and its train was not torn down (shouldProcessFinishedBody).
Usable(r, b) ==
    /\ Owns(r, b) /\ halt[r] # "cancel"
    /\ (CheckTrainEpoch => b \notin staleq[r])

\* applyFinishedRangeBody.  The claim is released when the block ends.
Apply(r, b) ==
    /\ up /\ b \in ioq[r]
    /\ ioq' = Upd(ioq, r, ioq[r] \ {b})
    /\ staleq' = Upd(staleq, r, staleq[r] \ {b})
    /\ LET d == dur[r]
           gone == Upd(stash, r, stash[r] \ {b})
           replan == IF halt[r] = "none" /\ ActiveRow(r) THEN Upd(plan, r, TRUE) ELSE plan
           used == staleUse \/ b \in staleq[r]
       IN
       IF ~Usable(r, b) THEN
           \* A stale or cancelled body is discarded.
           /\ stash' = gone
           /\ UNCHANGED <<row, manifest, dur, heldFile, renamed, held, retire, plan, fin, ghosts>>
       ELSE IF Life(r) = "failed" THEN
           \* Reconcile failed the row and deleted its working file (it does so
           \* only at a zero checkpoint): the append has nothing to open.
           /\ stash' = gone
           /\ UNCHANGED <<row, manifest, dur, heldFile, renamed, held, retire, plan, fin, ghosts>>
       ELSE IF b \notin stash[r] THEN
           \* The stash is gone, so the move fails: re-fetch from the checkpoint.
           /\ plan' = replan
           /\ UNCHANGED <<row, manifest, dur, stash, heldFile, renamed, held, retire, fin, ghosts>>
       ELSE IF CheckAlignment /\ b[2] < d THEN
           \* durable_checkpoint_ahead: the bytes are already there.
           /\ stash' = gone
           /\ plan' = replan
           /\ UNCHANGED <<row, manifest, dur, heldFile, renamed, held, retire, fin, ghosts>>
       ELSE IF CheckAlignment /\ b[2] > d THEN
           \* Ahead of the checkpoint: hold it.  The durable path is claimed,
           \* then the stash is renamed onto it.  The manifest follows in
           \* HoldManifested.  Before B22 the durable path had no claim.
           /\ stash' = gone
           /\ heldFile' = Upd(heldFile, r, heldFile[r] \cup {b})
           /\ renamed' = Upd(renamed, r, renamed[r] \cup {b})
           /\ staleUse' = used
           /\ UNCHANGED <<row, manifest, dur, held, retire, plan, fin, misaligned>>
       ELSE
           \* At the checkpoint: append, then drain what became contiguous.
           /\ stash' = gone
           /\ LET dp == DrainPass(r, d + b[3], held[r], retire[r])
              IN /\ Continue(r, dp.dur, dp.retire)
                 /\ misaligned' = (misaligned \/ b[2] # d \/ dp.bad)
           /\ staleUse' = used
           /\ UNCHANGED renamed
    /\ UNCHANGED <<owner, published, task, up, tracked, halt, recon, liveSnap, envVars>>

\* restartRangeFromChangedResource, when an arriving body's validator differs
\* from the pinned one (arrivingBodyDecision): delete the partial, purge the
\* held bodies, supersede and cancel the train, advance its epoch and start
\* over from zero.  reducer: resourceChanged.
ResourceChanged(r, b) ==
    /\ up /\ b \in ioq[r] /\ b \in stash[r] /\ Usable(r, b)
    /\ halt[r] = "none" /\ ActiveRow(r)
    /\ restarts < MaxRestarts
    /\ restarts' = restarts + 1
    /\ ioq' = Upd(ioq, r, ioq[r] \ {b})
    /\ staleq' = Upd(staleq, r, ioq[r] \ {b})
    /\ stash' = Upd(stash, r, stash[r] \ {b})
    /\ dur' = Upd(dur, r, 0)
    /\ PurgeHeld(r)
    \* Every task of the row ends here.  A tracked one is superseded.  An
    \* untracked one (a zombie from before a relaunch) carries the old
    \* resource's validator: its body is discarded when it arrives
    \* (unownedBodyValidatorDecision), which the model folds into this step
    \* because it has no validators.
    /\ task' = Upd(task, r, Const(Bodies, "none"))
    /\ tracked' = Upd(tracked, r, {})
    /\ plan' = Upd(plan, r, TRUE)
    /\ Submit(r, Ev("resourceChanged"))
    /\ UNCHANGED <<owner, published, up, renamed, halt, fin, recon, liveSnap, budget, ghosts>>

\* submitHeldRangeSegment and its completion on the range-IO queue.  For the
\* row's attempt, not cancelled: the manifest is committed, the body joins
\* the held map and the train continues.  Otherwise the body is removed.  A
\* purge that ran since the rename already deleted the file and the manifest;
\* the completion still installs the map entry.
HoldManifested(r, b) ==
    /\ up /\ b \in renamed[r]
    /\ renamed' = Upd(renamed, r, renamed[r] \ {b})
    /\ IF Owns(r, b) /\ halt[r] # "cancel"
          THEN /\ manifest' = IF b \in heldFile[r]
                                 THEN Upd(manifest, r, manifest[r] \cup {b}) ELSE manifest
               /\ held' = Upd(held, r, held[r] \cup {b})
               /\ plan' = IF halt[r] = "none" /\ ActiveRow(r) THEN Upd(plan, r, TRUE) ELSE plan
               /\ UNCHANGED heldFile
          ELSE /\ heldFile' = Upd(heldFile, r, heldFile[r] \ {b})
               /\ manifest' = Upd(manifest, r, manifest[r] \ {b})
               /\ UNCHANGED <<held, plan>>
    /\ UNCHANGED <<row, owner, dur, published, stash, task, up, tracked, ioq, staleq, retire,
                   halt, fin, recon, liveSnap, envVars, ghosts>>

\* The completion of a held-body removal (removeHeldRangeSegments): the
\* manifest and the file are gone, the map entry and its claim are dropped,
\* and one more drain pass runs.  The code discards that pass's result: it
\* neither finalizes a file the pass completed nor tops the train up (R1).
RetireDone(r, b) ==
    /\ up /\ b \in retire[r]
    /\ manifest' = Upd(manifest, r, manifest[r] \ {b})
    /\ heldFile' = Upd(heldFile, r, heldFile[r] \ {b})
    /\ LET H == held[r] \ {b}
           dp == DrainPass(r, dur[r], H, retire[r] \ {b})
           moved == dp.dur # dur[r]
       IN /\ misaligned' = (misaligned \/ dp.bad)
          /\ dur' = Upd(dur, r, dp.dur)
          /\ retire' = Upd(retire, r, dp.retire)
          /\ IF FixDrainContinues /\ moved /\ dp.dur >= Total /\ ActiveRow(r)
                THEN \* PROPOSED: finalize the file this pass completed.  The body it
                     \* appended stays mapped until its own removal completes.
                     /\ held' = Upd(held, r, H)
                     /\ LET t == Send(r, Ev("bodyAtWorking"))
                        IN /\ row' = IF IsApplied(t) THEN Upd(row, r, t.state) ELSE row
                           /\ fin' = Upd(fin, r, IsApplied(t))
                     /\ plan' = Upd(plan, r, FALSE)
                ELSE /\ held' = Upd(held, r, H)
                     \* PROPOSED: continue the train after any removal.
                     /\ plan' = IF FixDrainContinues /\ halt[r] = "none" /\ ActiveRow(r)
                                   THEN Upd(plan, r, TRUE) ELSE plan
                     /\ UNCHANGED <<row, fin>>
    /\ UNCHANGED <<owner, published, stash, task, up, tracked, ioq, staleq, renamed, halt,
                   recon, liveSnap, envVars, staleUse>>

-----------------------------------------------------------------------------
(* Finalizer                                                               *)

\* reducer: finalizeOutcome(complete), then promotionCommitted.  Validation
\* and the promotion recipe are DownloadsSessionCore's subject.
FinalizeOutcome(r) ==
    /\ up /\ fin[r] /\ Life(r) = "finalizing" /\ dur[r] >= Total
    /\ LET t == Send(r, EvFinalize(owner[r], "complete", "src"))
       IN /\ Has(t, "publishComplete")
          /\ LET c == Reduce(t.state, EvPromotion("promotionCommitted", "complete"), NoFacts)
             IN /\ IsApplied(c)
                /\ row' = Upd(row, r, c.state)
    /\ published' = Upd(published, r, TRUE)
    /\ fin' = Upd(fin, r, FALSE)
    /\ UNCHANGED <<owner, manifest, dur, stash, heldFile, task, up, tracked, ioq, staleq,
                   renamed, held, retire, halt, plan, recon, liveSnap, envVars, ghosts>>

-----------------------------------------------------------------------------
(* User                                                                    *)

\* reducer: pause(.user), plus BackgroundDownloadSession.pause: the halt is
\* installed at once and queued rebuilds die (B02).  Held bodies are kept.
UserPause(r) ==
    /\ up /\ ActiveRow(r)
    /\ Spend
    /\ Submit(r, EvPause("user"))
    /\ halt' = Upd(halt, r, "pause")
    /\ plan' = Upd(plan, r, FALSE)
    /\ UNCHANGED <<owner, manifest, fileVars, task, up, tracked, ioq, staleq, renamed, held,
                   retire, fin, recon, liveSnap, restarts, ghosts>>

\* The pause's getAllTasks completion (pauseRangeTask): every listed segment
\* task of the row that is still transferring leaves tracking, is marked
\* superseded and is cancelled.  A task whose finish callback ran first is no
\* longer tracked, and its body is appended behind the pause
\* (writeThenPause).  A task that finished in the daemon but whose callback
\* is still queued behind this completion may still be listed.  It stays
\* tracked, so that callback writes its body the same way.  Before R3 it was
\* superseded too, its finish callback was then ignored and the finished
\* body was dropped.  S is what the sweep takes.
PauseSweep(r) ==
    /\ up /\ halt[r] = "pause"
    /\ \E S \in {{"running"}} \cup (IF FixPauseKeepsFinished THEN {}
                                        ELSE {{"running", "finished"}}) :
          LET swept == {b \in tracked[r] : task[r][b] \in S}
          IN /\ swept # {}
             /\ task' = Upd(task, r, [b \in Bodies |->
                            IF b \in swept THEN "none" ELSE task[r][b]])
             /\ tracked' = Upd(tracked, r, tracked[r] \ swept)
    /\ UNCHANGED <<rowVars, fileVars, up, ioq, staleq, renamed, held, retire, halt, plan, fin,
                   recon, liveSnap, envVars, ghosts>>

\* reducer: retry(.staticCheckpoint): same attempt, same checkpoint, same
\* held bodies.  B00: DownloadRetryPolicy.shouldPromotePausedStaticPartial
\* measures the attempt working partial.  Before B00 it measured the
\* published path, found nothing, and Resume replaced the attempt
\* (`retry_replace`): the partial and its held bodies were deleted and the
\* download started over.  reducer then: retry(.freshAttempt).
UserResume(r) ==
    /\ up /\ Life(r) = "paused"
    /\ Spend
    /\ halt' = Upd(halt, r, "none")
    /\ plan' = Upd(plan, r, TRUE)
    /\ IF FixB00 \/ dur[r] = 0
          THEN /\ Submit(r, EvRetry("staticCheckpoint"))
               /\ UNCHANGED <<manifest, dur, heldFile, held, retire>>
          ELSE /\ Submit(r, EvRetry("freshAttempt"))
               /\ dur' = Upd(dur, r, 0)
               /\ PurgeHeld(r)
    /\ UNCHANGED <<owner, published, stash, task, up, tracked, ioq, staleq, renamed,
                   fin, recon, liveSnap, restarts, ghosts>>

\* Retry of a failed row mints a new attempt, which inherits the checkpoint.
\* reducer: retry(.staticCheckpoint), or retry(.freshAttempt) with no bytes.
UserRetry(r) ==
    /\ up /\ Life(r) = "failed" /\ owner[r] < MaxAttempt
    /\ Spend
    /\ owner' = Upd(owner, r, owner[r] + 1)
    /\ Submit(r, EvRetry(IF dur[r] > 0 THEN "staticCheckpoint" ELSE "freshAttempt"))
    /\ halt' = Upd(halt, r, "none")
    /\ plan' = Upd(plan, r, TRUE)
    /\ UNCHANGED <<manifest, fileVars, task, up, tracked, ioq, staleq, renamed, held, retire,
                   fin, recon, liveSnap, restarts, ghosts>>

-----------------------------------------------------------------------------
(* Crash and recovery                                                      *)

CrashEffects ==
    /\ up' = FALSE
    /\ tracked' = Const(Rows, {})
    /\ ioq' = Const(Rows, {})
    /\ staleq' = Const(Rows, {})
    /\ renamed' = Const(Rows, {})
    /\ held' = Const(Rows, {})
    /\ retire' = Const(Rows, {})
    /\ halt' = Const(Rows, "none")
    /\ plan' = Const(Rows, FALSE)
    /\ fin' = Const(Rows, FALSE)
    /\ recon' = Const(Rows, "idle")
    /\ liveSnap' = Const(Rows, FALSE)

Crash ==
    /\ up
    /\ Spend
    /\ CrashEffects
    /\ UNCHANGED <<rowVars, fileVars, task, restarts, ghosts>>

\* The process dies in the middle of an append (appendRangeBody copies in
\* 4 MiB writes): the first k bytes of body b are in the working file and
\* nothing else of the block happened.  The body was being appended by
\* applyFinishedRangeBody (queued, stashed, usable) or by a drain pass the
\* planner ran (held, nothing behind the checkpoint, not halted).  Its
\* stash or held file and its manifest are still on disk.
CrashMidAppend(r, b, k) ==
    /\ up /\ k \in 1..(b[3] - 1) /\ b[2] = dur[r]
    /\ \/ /\ b \in ioq[r] /\ b \in stash[r] /\ Usable(r, b) /\ Life(r) # "failed"
       \/ /\ b \in Mine(r, held[r]) \ retire[r] /\ halt[r] = "none"
          /\ plan[r] /\ ActiveRow(r) /\ recon[r] # "launchReattach"
          /\ \A x \in Mine(r, held[r]) : x[2] >= dur[r]
    /\ Spend
    /\ dur' = Upd(dur, r, dur[r] + k)
    /\ CrashEffects
    /\ UNCHANGED <<rowVars, published, stash, heldFile, task, restarts, ghosts>>

Relaunch ==
    /\ ~up
    /\ up' = TRUE
    /\ recon' = Const(Rows, "launchReattach")
    /\ UNCHANGED <<rowVars, fileVars, task, tracked, ioq, staleq, renamed, held, retire, halt,
                   plan, fin, liveSnap, envVars, ghosts>>

\* Returning to the foreground runs the same reattach + reconcile in the
\* live process (recoverStaticRangeTransfersAfterForeground).
ForegroundReattachBegins ==
    /\ ForegroundReattach /\ up
    /\ \A r \in Rows : recon[r] = "idle"
    /\ Spend
    /\ recon' = Const(Rows, "needReattach")
    /\ UNCHANGED <<rowVars, fileVars, task, up, tracked, ioq, staleq, renamed, held, retire,
                   halt, plan, fin, liveSnap, restarts, ghosts>>

\* The session owns work for the row (ownsInProgressStaticRangeWork): a live
\* task, a queued apply, a pending continuation or a claimed finalizer.
SessionOwnsWork(r) ==
    tracked[r] # {} \/ ioq[r] # {} \/ plan[r] \/ fin[r]

\* reattachToResumedTasks, one row's share of the getAllTasks completion,
\* atomic on the delegate queue.
\*  - restoreHeldRangeSegments: a manifest of the row is valid when the row
\*    is an active static row, the manifest carries the row's attempt, its
\*    offset is not behind the checkpoint and its file is there.  A valid one
\*    is claimed and joins the held map; an invalid one is removed with its
\*    file.  The row it reads is the in-memory one: a submitted removal is
\*    already gone from it.
\*  - A running, untracked task is adopted (reducer: taskAdopted) when it
\*    carries the row's exact attempt, its range starts at or ahead of the
\*    checkpoint (StaticRangeReattachPolicy: on any grid) and the row may be
\*    active; a paused row's task is cancelled instead (B02); a halted
\*    attempt's task is left alone.  Any other untracked task is cancelled.
\*    When that happens to a row that may be active (another attempt's task,
\*    or a range behind the checkpoint), the row counts as live and a request
\*    rebuild is asked for.
\*  - sweepOrphanedRangeBodyStashes: a tmp/ stash whose task is no longer
\*    live is deleted.  B03: unless a queued apply still claims it.
\*  - sweepOrphanedDurableHeldRangeSegments: a held file that no manifest, no
\*    pending removal and no map entry references is deleted.  B22: unless a
\*    hold in flight claims it.
\*  - The live-key snapshot handed to reconcile is every tracked task.  It is
\*    taken here and used later, in RelaunchObserved.
Reattach(r) ==
    /\ up /\ recon[r] \in {"launchReattach", "needReattach"}
    /\ recon' = Upd(recon, r, "needReconcile")
    /\ LET view == manifest[r] \ retire[r]
           Valid(b) == /\ Life(r) \in {"admitted", "transferring", "paused"}
                       /\ Owns(r, b) /\ b[2] >= dur[r] /\ b \in heldFile[r]
           good == {b \in view : Valid(b)}
           H == held[r] \cup good
           M == manifest[r] \ (view \ good)
           Untracked(b) == task[r][b] = "running" /\ b \notin tracked[r]
           Adopt(b) == /\ Untracked(b) /\ Owns(r, b) /\ Life(r) \notin Terminal
                       /\ halt[r] = "none" /\ Life(r) # "paused" /\ b[2] >= dur[r]
           Cancel(b) == Untracked(b) /\ halt[r] = "none" /\ ~Adopt(b)
           adopted == {b \in Bodies : Adopt(b)}
           rebuild == ActiveRow(r) /\ \E b \in Bodies : Cancel(b)
       IN /\ held' = Upd(held, r, H)
          /\ manifest' = Upd(manifest, r, M)
          /\ task' = Upd(task, r, [b \in Bodies |->
                         IF Cancel(b) THEN "none" ELSE task[r][b]])
          /\ tracked' = Upd(tracked, r, tracked[r] \cup adopted)
          /\ IF adopted # {} THEN Submit(r, Ev("taskAdopted")) ELSE UNCHANGED row
          /\ plan' = IF rebuild THEN Upd(plan, r, TRUE) ELSE plan
          /\ liveSnap' = Upd(liveSnap, r,
                \/ (tracked[r] \cup adopted) # {} \/ rebuild
                \* NOT IN THE CODE and NOT ENOUGH: the snapshot also holds session-owned work.
                \/ FixSnapshotOwnedWork /\ ActiveRow(r) /\ SessionOwnsWork(r))
          /\ stash' = Upd(stash, r, {b \in stash[r] :
                         task[r][b] = "running" \/ (FixB03 /\ b \in ioq[r])})
          /\ heldFile' = Upd(heldFile, r, {b \in heldFile[r] \ (view \ good) :
                         \/ b \in M \cup retire[r] \cup H
                         \/ FixB22 /\ b \in renamed[r]})
    /\ UNCHANGED <<owner, dur, published, up, ioq, staleq, renamed, retire,
                   halt, fin, envVars, ghosts>>

\* The facts reconcile reports for row r (DownloadStore.observeLifecycleFacts):
\* the checkpoint is the attempt working partial.
RelaunchFacts(r) ==
    Fx("staticRange", FALSE,
       IF dur[r] > 0 /\ ~row[r].bodyCondemned THEN "partial" ELSE "none",
       IF Life(r) \in Terminal THEN (IF published[r] THEN "published" ELSE "none")
       ELSE IF Life(r) = "finalizing" /\ dur[r] >= Total THEN "workingComplete"
       ELSE "none",
       FALSE, FALSE,
       \* The live-task fact is reattach's snapshot of tracked tasks, taken
       \* earlier, which does not count a queued apply, a pending continuation
       \* or the finalizer, or what the session owns now (R2; only for an
       \* active row, never a paused one).
       liveSnap[r] \/ (FixReconcileOwnedWork /\ ActiveRow(r) /\ SessionOwnsWork(r)),
       TRUE)

\* reducer: relaunchObserved.  deleteWorkingBody deletes the working partial;
\* requestFinalization restarts the finalizer.
RelaunchObserved(r) ==
    /\ up /\ recon[r] = "needReconcile"
    /\ recon' = Upd(recon, r, "idle")
    /\ LET t == Reduce(row[r], Ev("relaunchObserved"), RelaunchFacts(r))
       IN /\ row' = IF IsApplied(t) THEN Upd(row, r, t.state) ELSE row
          /\ dur' = IF Has(t, "deleteWorkingBody") THEN Upd(dur, r, 0) ELSE dur
          /\ fin' = IF Has(t, "requestFinalization") THEN Upd(fin, r, TRUE) ELSE fin
    /\ UNCHANGED <<owner, manifest, published, stash, heldFile, task, up, tracked, ioq, staleq,
                   renamed, held, retire, halt, plan, liveSnap, envVars, ghosts>>

\* A row parked `deferredResume` restarts by itself from its checkpoint.
\* reducer: retry(.staticCheckpoint)
AutoResume(r) ==
    /\ up /\ Life(r) = "paused" /\ row[r].pauseCause = "deferredResume"
    /\ halt[r] = "none" /\ recon[r] = "idle"
    /\ Submit(r, EvRetry("staticCheckpoint"))
    /\ plan' = Upd(plan, r, TRUE)
    /\ UNCHANGED <<owner, manifest, fileVars, task, up, tracked, ioq, staleq, renamed, held,
                   retire, halt, fin, recon, liveSnap, envVars, ghosts>>

\* DownloadManager.refreshRecords' stale-row self-heal
\* (shouldDemoteStaleQueuedStaticPartial): an active static row with a durable
\* checkpoint and no session work restarts from the checkpoint.  B00: the
\* checkpoint is the attempt working partial; measured at the published path
\* it never exists, so the self-heal never fired.  It runs from a manager
\* refresh on the main actor, which a suspended background app does not get:
\* ForegroundFairness below is the assumption that it eventually runs.
StaleRowHeal(r) ==
    /\ up /\ ActiveRow(r) /\ halt[r] = "none" /\ recon[r] = "idle"
    /\ ~SessionOwnsWork(r)
    /\ FixB00 /\ dur[r] > 0
    /\ plan' = Upd(plan, r, TRUE)
    /\ UNCHANGED <<rowVars, fileVars, task, up, tracked, ioq, staleq, renamed, held, retire,
                   halt, fin, recon, liveSnap, envVars, ghosts>>

-----------------------------------------------------------------------------

AppStep(r) ==
    \/ Plan(r) \/ FinalizeOutcome(r) \/ PauseSweep(r)
    \/ Reattach(r) \/ RelaunchObserved(r) \/ AutoResume(r) \/ StaleRowHeal(r)
    \/ \E b \in Bodies :
          \/ DidFinishDownloading(r, b) \/ DidCompleteWithError(r, b)
          \/ Apply(r, b) \/ ResourceChanged(r, b)
          \/ HoldManifested(r, b) \/ RetireDone(r, b)

UserStep(r) == UserPause(r) \/ UserResume(r) \/ UserRetry(r)

Next ==
    \/ \E r \in Rows : AppStep(r) \/ UserStep(r)
    \/ \E r \in Rows, b \in Bodies : DaemonFinishes(r, b) \/ DaemonFails(r, b)
    \/ \E r \in Rows, b \in Bodies, k \in 1..(SegBytes - 1) : CrashMidAppend(r, b, k)
    \/ Crash \/ Relaunch \/ ForegroundReattachBegins

Spec == Init /\ [][Next]_vars

\* Liveness assumptions, each one a thing the code cannot promise by itself:
\*  - SessionFairness: every step the session, the delegate queue and the
\*    range-IO queue take is weakly fair, and the daemon resolves every task.
\*    True while the process runs or the daemon can wake it.
\*  - NetworkFairness: a segment that keeps being retried eventually
\*    finishes (strong fairness).  The code has a retry budget instead: with
\*    AllowFailure the row may also fail, which is a stable end, but nothing
\*    here counts the budget, so without this assumption a segment could fail
\*    and be retried forever.
\*  - ForegroundFairness: the manager's two recovery steps run.  StaleRowHeal
\*    and AutoResume are driven by DownloadManager.refreshRecords and the
\*    foreground resume pass on the main actor, gated on the queue not being
\*    paused, a backend session and no pending resume intent.  A suspended
\*    background app runs neither.  Mutant-NoForegroundRefresh.cfg drops this
\*    assumption and shows the stranded train (R1, or a wake that wound
\*    down) then never moves.
\* The environment (user, crashes, foreground, source changes) is not fair.
SessionFairness ==
    /\ WF_vars(Relaunch)
    /\ \A r \in Rows :
          /\ WF_vars(Plan(r)) /\ WF_vars(FinalizeOutcome(r)) /\ WF_vars(PauseSweep(r))
          /\ WF_vars(Reattach(r)) /\ WF_vars(RelaunchObserved(r))
          /\ \A b \in Bodies :
                /\ WF_vars(DidFinishDownloading(r, b))
                /\ WF_vars(DidCompleteWithError(r, b))
                /\ WF_vars(Apply(r, b))
                /\ WF_vars(HoldManifested(r, b)) /\ WF_vars(RetireDone(r, b))
                /\ WF_vars(DaemonFinishes(r, b) \/ DaemonFails(r, b))
NetworkFairness ==
    \A r \in Rows : \A b \in Bodies : SF_vars(DaemonFinishes(r, b))
ForegroundFairness ==
    \A r \in Rows : WF_vars(AutoResume(r)) /\ WF_vars(StaleRowHeal(r))

Fairness == SessionFairness /\ NetworkFairness /\ ForegroundFairness

FairSpec == Spec /\ Fairness
\* The same without the foreground: the app is never serviced on the main actor.
BackgroundFairSpec == Spec /\ SessionFairness /\ NetworkFairness

-----------------------------------------------------------------------------
(* Properties                                                              *)

\* Appends stay offset-aligned: every body is appended at its own offset.
AppendsAligned == ~misaligned

\* A body whose train was torn down is never appended or held.
StaleTrainBodyInert == ~staleUse

\* B03: a body whose apply is still queued is never unlinked.
QueuedBodyNotSwept ==
    \A r \in Rows : \A b \in ioq[r] : Usable(r, b) => b \in stash[r]

\* B22: a held body is never swept between its rename and its manifest.
HeldBodyNotSweptBeforeManifest ==
    \A r \in Rows : \A b \in renamed[r] :
        \* A body the checkpoint has passed is purged with the finished file.
        Owns(r, b) /\ halt[r] # "cancel" /\ restarts = 0 /\ b[2] >= dur[r]
        => b \in heldFile[r]

\* A manifest names a file that exists.  (A purge that overtakes a hold in
\* flight is the exception the code handles at drain time; it needs a
\* changed resource.)
ManifestedBodyExists ==
    \A r \in Rows : \A b \in manifest[r] : b \in heldFile[r]

\* A held body the session may still append is on disk.  One that starts
\* behind the checkpoint is only ever discarded: a restore removes its
\* manifest and file while the in-memory map keeps the entry until a drain.
HeldBodyExists ==
    \A r \in Rows : \A b \in Mine(r, held[r]) \ retire[r] :
        /\ restarts = 0 /\ Life(r) \in {"admitted", "transferring", "paused"}
        /\ b[2] >= dur[r]
        => b \in heldFile[r]

\* A finalizing or playable row has the whole file.
FinalizingHasBody ==
    \A r \in Rows : Life(r) = "finalizing" => dur[r] >= Total
CompleteIsWhole ==
    \A r \in Rows : Life(r) \in Playable => dur[r] >= Total /\ published[r]

\* The planner never tops the train up beyond its depth: after a step that
\* starts a task, the tracked tasks, held bodies and claimed finished bodies
\* together are at most Depth segments.  PROPOSED (R4): beyond the depth it
\* starts one segment only, the one at the checkpoint.
Started(r, b) == task[r][b] # "running" /\ task'[r][b] = "running"
PlannerRespectsDepth ==
    [][\A r \in Rows :
          (\E b \in Bodies : Started(r, b))
          => \/ Cardinality(LiveBodies(r))' <= Depth
             \/ /\ FixHeadGapPlanned
                /\ \A b \in Bodies : Started(r, b) => b[2] = dur'[r]]_vars

\* The planner fills gaps only: a segment it starts begins at or ahead of
\* the checkpoint and overlaps no other live segment of the attempt, on
\* whatever grid that segment was planned (interval coverage).  After a
\* crash in the middle of an append this is what keeps the adopted train
\* from being fetched a second time.
PlannerFillsGapsOnly ==
    [][\A r \in Rows : \A b \in Bodies :
          Started(r, b) =>
              /\ b[2] >= dur'[r]
              /\ \A c \in Mine(r, LiveBodies(r))' \ {b} : ~Overlap(b, c)]_vars

\* R3: a pause keeps a finished segment.  A tracked segment task of the
\* row's attempt that has finished in the daemon stays finished, or its body
\* reaches the stash, while the pause halt stands in a live process.
PauseKeepsFinishedSegment ==
    [][\A r \in Rows : \A b \in tracked[r] :
          /\ halt[r] = "pause" /\ halt'[r] = "pause" /\ up'
          /\ Owns(r, b) /\ task[r][b] = "finished"
          => task'[r][b] = "finished" \/ b \in stash'[r]]_vars

\* R1: the train is never left with nothing to do.  An active, unhalted row
\* always has a live task, queued range IO, a pending continuation or a
\* finalizer, unless recovery is about to look at it.
InFlight(r) ==
    \/ SessionOwnsWork(r) \/ renamed[r] # {} \/ retire[r] # {}
    \/ \E b \in Bodies : task[r][b] \in {"finished", "failed"}
TrainNeverStranded ==
    \A r \in Rows :
        up /\ ActiveRow(r) /\ halt[r] = "none" /\ recon[r] = "idle" => InFlight(r)

\* R4: the train is never wedged.  An active, unhalted row with an unfinished
\* file, no task anywhere, nothing queued and nothing a drain can append can
\* always plan its next segment.  Otherwise no step of the session, the
\* daemon or the manager's self-heal ever moves it again.
Wedged(r) ==
    /\ up /\ ActiveRow(r) /\ halt[r] = "none" /\ recon[r] = "idle" /\ ~fin[r]
    /\ dur[r] < Total
    /\ tracked[r] = {} /\ ioq[r] = {} /\ renamed[r] = {} /\ retire[r] = {}
    /\ \A b \in Bodies : task[r][b] = "none"
    /\ DrainPass(r, dur[r], held[r], {}).dur = dur[r]
    /\ DrainPass(r, dur[r], held[r], {}).retire = {}
    /\ PlanSet(r, dur[r]) = {}
TrainNeverWedged == \A r \in Rows : ~Wedged(r)

\* R2: reconcile never fails an active row while a finished body of it is
\* stashed and queued for its append.
QueuedBody(r) == \E b \in ioq[r] : Usable(r, b) /\ b \in stash[r]
ReconcileKeepsQueuedBody ==
    [][\A r \in Rows :
          /\ recon[r] = "needReconcile" /\ recon'[r] = "idle"
          /\ ActiveRow(r) /\ QueuedBody(r)
          => Life(r)' # "failed"]_vars

\* The general form: reconcile never fails an active row while the session
\* owns any work for it (a live task, a queued apply, a continuation).  It
\* holds only with the reconcile-time fix.
ReconcileNeverFailsOwnedWork ==
    [][\A r \in Rows :
          /\ recon[r] = "needReconcile" /\ recon'[r] = "idle"
          /\ ActiveRow(r) /\ SessionOwnsWork(r)
          => Life(r)' # "failed"]_vars

\* R2, the part no ownership check closes: reconcile never fails an active
\* row while the daemon holds a finished task of its attempt whose callback
\* has not been delivered yet.  The session owns nothing for it at that
\* moment, so this fails with FixReconcileOwnedWork too: the body arrives
\* after the row is failed and is dropped.
ReconcileKeepsUndeliveredBody ==
    [][\A r \in Rows :
          /\ recon[r] = "needReconcile" /\ recon'[r] = "idle" /\ ActiveRow(r)
          /\ \E b \in Bodies : Owns(r, b) /\ task[r][b] = "finished"
          => Life(r)' # "failed"]_vars

\* B00: neither recovery nor a Resume discards the attempt's checkpoint.  The
\* working file only shrinks when the source changed (ResourceChanged).
CheckpointNeverDiscarded ==
    [][\A r \in Rows : dur'[r] < dur[r] => restarts' # restarts]_vars

\* Nothing starts a task for a user-paused row.
NoStartWhileUserPaused ==
    [][\A r \in Rows : \A b \in Bodies :
          UserPaused(r) /\ task[r][b] # "running" => task'[r][b] # "running"]_vars

\* A pause keeps the held bodies: while the row stays user-paused in a live
\* process, a held body leaves the disk only by being appended.
PauseKeepsHeldBodies ==
    [][\A r \in Rows :
          UserPaused(r) /\ UserPaused(r)' /\ up /\ up' /\ recon[r] = "idle"
          => \A b \in Mine(r, held[r]) \cap heldFile[r] :
                b \in heldFile'[r] \/ dur'[r] > b[2]]_vars

\* Liveness: an admitted row eventually reaches a stable state.
Stable(r) == Life(r) \in Terminal \/ UserPaused(r)
AdmittedEventuallyStable ==
    \A r \in Rows : (Life(r) = "admitted") ~> Stable(r)
=============================================================================
