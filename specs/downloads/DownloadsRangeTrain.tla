------------------------- MODULE DownloadsRangeTrain -------------------------
(***************************************************************************)
(* The static-range lane of the downloads session: a train of parallel     *)
(* segment tasks, bodies that finish out of order and are held on disk     *)
(* under a durable manifest, in-order assembly into the working file, the  *)
(* two orphan sweeps, and recovery of the checkpoint after process death.  *)
(*                                                                         *)
(* A file is NSeg segments.  A body is <<attempt, offset>>: the response   *)
(* of the segment task that attempt started for that offset.  The working  *)
(* file is `dur` segments long, and a body may be appended only at offset  *)
(* `dur`.  A body that arrives ahead of the checkpoint is held:            *)
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
(*   Crash      Crash, Relaunch                                            *)
(*                                                                         *)
(* Abstractions (DownloadsRangeTrain.md lists what is not covered):        *)
(*  - Segments have unit length; a body is whole or absent.                *)
(*  - A task is named by its body, so one attempt never has two tasks for  *)
(*    one offset; the planner waits for the slot instead.                  *)
(*  - A held body's manifest commit and the completion that installs it    *)
(*    are one step (HoldManifested); a manifest removal, its file          *)
(*    deletion and its completion are one step (RetireDone).  The rename   *)
(*    that precedes the manifest is its own step, so the sweep can run     *)
(*    between the two.                                                     *)
(*  - A superseded or pause-swept task is cancelled at once.               *)
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
\* MODELS: PMSKit/Sources/PMSKit/Downloads/BackgroundTempFileCleanupPolicy.swift
\* MODELS: PMSKit/Sources/PMSKit/DownloadRetryPolicy.swift
EXTENDS DownloadsReducer, TLC

CONSTANTS
    Rows,               \* download keys; every row is on the static-range route
    NSeg,               \* segments in a file
    Depth,              \* StaticRangeTransferConfiguration.maxQueuedSegments
    MaxAttempt,         \* attempt IDs are 1..MaxAttempt
    MaxRestarts,        \* how often the source may change under the train (all rows)
    FixB00,             \* recovery measures the attempt working partial, not the published path
    FixB03,             \* the tmp/ stash sweep rechecks the claim of a queued append
    FixB22,             \* the durable held path is claimed before the rename; the sweep honours it
    CheckTrainEpoch,    \* MUTATION SWITCH: FALSE applies a body whose train was torn down
    CheckAlignment,     \* MUTATION SWITCH: FALSE appends a body wherever the checkpoint is
    FixDrainContinues,  \* PROPOSED (not in the code): a drain that a removal completion runs
                        \* continues the train (plan or finalize) like every other drain (R1)
    FixReconcileOwnedWork, \* PROPOSED (not in the code): reconcile counts session-owned work
                        \* of an active row as live, like the stale-row self-heal does (R2)
    AllowFailure,       \* a transport error may be terminal instead of retried
    ForegroundReattach, \* allow reattach + reconcile while the process stays alive
    BoundEnvironment,   \* TRUE: at most EnvBudget user/crash/foreground steps (liveness runs)
    EnvBudget

ASSUME /\ NSeg \in Nat \ {0} /\ Depth \in Nat \ {0}
       /\ MaxAttempt \in Nat \ {0} /\ MaxRestarts \in Nat /\ EnvBudget \in Nat

Attempts == 1..MaxAttempt
Offsets == 0..(NSeg - 1)
Bodies == Attempts \X Offsets

\* SYMMETRY for safety configs: every row is static, so nothing tells two apart.
RowSymmetry == Permutations(Rows)

VARIABLES
    \* ---- durable: the index row (survives Crash) ----
    row,         \* [Rows -> reducer state]        DownloadLifecycleState
    owner,       \* [Rows -> Attempts]             the row's current attempt ID
    manifest,    \* [Rows -> SUBSET Bodies]        metadata.heldRangeSegments
    \* ---- durable: files (survive Crash) ----
    dur,         \* [Rows -> Nat]                  segments in the attempt working file
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
    /\ dur \in [Rows -> 0..NSeg]
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
\* already submitted, the working file at d segments.
\* StaticRangeSegmentAssemblyPolicy.appendableRun: a held body behind the
\* checkpoint is discarded, the body exactly at the checkpoint is appended,
\* anything further waits.  A manifest removal is asynchronous, and the pass
\* stops as soon as it has submitted one, so it appends at most one body; a
\* body it appended stays in the map (now behind the checkpoint) until
\* RetireDone, and stops every later pass until then.  A halt stops the pass.
DrainPass(r, d, H, R) ==
    LET mine == Mine(r, H)
        behind == {b \in mine : b[2] < d}
        next == {b \in mine : b[2] = d}
        same == [dur |-> d, retire |-> R, bad |-> FALSE]
    IN IF halt[r] # "none" THEN same
       ELSE IF behind # {} THEN [same EXCEPT !.retire = R \cup behind]
       ELSE IF CheckAlignment THEN
           (IF next # {} THEN [dur |-> d + 1, retire |-> R \cup next, bad |-> FALSE]
                         ELSE same)
       \* MUTATION: append any held body, wherever the checkpoint is.
       ELSE IF mine # {} THEN
           (LET b == CHOOSE x \in mine : TRUE
            IN [dur |-> d + 1, retire |-> R \cup {b}, bad |-> b[2] # d])
       ELSE same

\* startRangeRemainder's liveSegments: every tracked task of the row, every
\* held body, and every claimed finished body of the current train.
Covered(r) ==
    {b[2] : b \in tracked[r] \cup Mine(r, held[r])
                  \cup Mine(r, (ioq[r] \ staleq[r]) \cup renamed[r])}

\* StaticRangeSegmentQueuePolicy.segmentsToEnqueue: the first uncovered
\* offsets from the checkpoint, up to the depth left over.
PlanSet(r, d) ==
    LET open == {o \in Offsets : o >= d /\ o \notin Covered(r)}
        room == Depth - Cardinality(Covered(r))
    IN {o \in open : Cardinality({p \in open : p < o}) < room}

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

\* The end of a range-IO block that left the working file at d segments with
\* the removals R submitted.  A pause halt keeps the bytes and parks the row
\* (writeThenPause; reducer: pause); otherwise the block finalizes a whole
\* file or asks for the next plan (continueRangeAfterBody).
Continue(r, d, R) ==
    /\ dur' = Upd(dur, r, d)
    /\ IF halt[r] = "pause" THEN
           /\ Submit(r, EvPause("user"))
           /\ retire' = Upd(retire, r, R)
           /\ UNCHANGED <<manifest, heldFile, held, fin, plan>>
       ELSE IF d >= NSeg THEN FinalizeWhole(r)
       ELSE
           /\ retire' = Upd(retire, r, R)
           /\ plan' = Upd(plan, r, TRUE)
           /\ UNCHANGED <<row, manifest, heldFile, held, fin>>

-----------------------------------------------------------------------------
(* Planner                                                                 *)

\* startRangeRemainder: drain what is contiguous, finalize a whole file, or
\* enqueue segment tasks for the uncovered offsets.  reducer: transferStarted.
Plan(r) ==
    /\ up /\ plan[r] /\ ActiveRow(r) /\ halt[r] = "none"
    \* After a relaunch nothing is planned before the reattach completion.
    /\ recon[r] # "launchReattach"
    /\ LET dp == DrainPass(r, dur[r], held[r], retire[r])
           new == {<<owner[r], o>> : o \in PlanSet(r, dp.dur)}
       IN /\ misaligned' = (misaligned \/ dp.bad)
          /\ dur' = Upd(dur, r, dp.dur)
          /\ IF dp.dur >= NSeg
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
\* reducer: transferFailed.
TerminalFail(r) ==
    /\ PurgeHeld(r)
    /\ halt' = Upd(halt, r, "cancel")
    /\ task' = Upd(task, r, [x \in Bodies |->
                   IF x \in tracked[r] /\ task[r][x] = "running" THEN "none"
                   ELSE task[r][x]])
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
           /\ LET dp == DrainPass(r, d + 1, held[r], retire[r])
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
    /\ task' = Upd(task, r, [x \in Bodies |->
                   IF x \in tracked[r] /\ task[r][x] = "running" THEN "none"
                   ELSE task[r][x]])
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
          /\ IF FixDrainContinues /\ moved /\ dp.dur >= NSeg /\ ActiveRow(r)
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
    /\ up /\ fin[r] /\ Life(r) = "finalizing" /\ dur[r] >= NSeg
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

\* The pause's getAllTasks completion (pauseRangeTask): every live segment
\* task leaves tracking and is cancelled.  A task that finished first keeps
\* its tracking, and its body is appended behind the pause (writeThenPause).
PauseSweep(r) ==
    /\ up /\ halt[r] = "pause"
    /\ \E b \in tracked[r] : task[r][b] = "running"
    /\ task' = Upd(task, r, [b \in Bodies |->
                   IF b \in tracked[r] /\ task[r][b] = "running" THEN "none"
                   ELSE task[r][b]])
    /\ tracked' = Upd(tracked, r, {b \in tracked[r] : task[r][b] # "running"})
    /\ UNCHANGED <<rowVars, fileVars, up, ioq, staleq, renamed, held, retire, halt, plan, fin,
                   recon, liveSnap, envVars, ghosts>>

\* reducer: retry(.staticCheckpoint): same attempt, same checkpoint, same
\* held bodies.
UserResume(r) ==
    /\ up /\ Life(r) = "paused"
    /\ Spend
    /\ Submit(r, EvRetry("staticCheckpoint"))
    /\ halt' = Upd(halt, r, "none")
    /\ plan' = Upd(plan, r, TRUE)
    /\ UNCHANGED <<owner, manifest, fileVars, task, up, tracked, ioq, staleq, renamed, held,
                   retire, fin, recon, liveSnap, restarts, ghosts>>

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

Crash ==
    /\ up
    /\ Spend
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
    /\ UNCHANGED <<rowVars, fileVars, task, restarts, ghosts>>

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
\*    carries the row's exact attempt and the row may be active; a paused
\*    row's task is cancelled instead (B02); a halted attempt's task is left
\*    alone.  Any other untracked task is cancelled.
\*  - sweepOrphanedRangeBodyStashes: a tmp/ stash whose task is no longer
\*    live is deleted.  B03: unless a queued apply still claims it.
\*  - sweepOrphanedDurableHeldRangeSegments: a held file that no manifest, no
\*    pending removal and no map entry references is deleted.  B22: unless a
\*    hold in flight claims it.
\*  - The live-key snapshot handed to reconcile is every tracked task.
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
                       /\ halt[r] = "none" /\ Life(r) # "paused"
           Cancel(b) == Untracked(b) /\ halt[r] = "none" /\ ~Adopt(b)
           adopted == {b \in Bodies : Adopt(b)}
       IN /\ held' = Upd(held, r, H)
          /\ manifest' = Upd(manifest, r, M)
          /\ task' = Upd(task, r, [b \in Bodies |->
                         IF Cancel(b) THEN "none" ELSE task[r][b]])
          /\ tracked' = Upd(tracked, r, tracked[r] \cup adopted)
          /\ IF adopted # {} THEN Submit(r, Ev("taskAdopted")) ELSE UNCHANGED row
          /\ liveSnap' = Upd(liveSnap, r, (tracked[r] \cup adopted) # {})
          /\ stash' = Upd(stash, r, {b \in stash[r] :
                         task[r][b] = "running" \/ (FixB03 /\ b \in ioq[r])})
          /\ heldFile' = Upd(heldFile, r, {b \in heldFile[r] \ (view \ good) :
                         \/ b \in M \cup retire[r] \cup H
                         \/ FixB22 /\ b \in renamed[r]})
    /\ UNCHANGED <<owner, dur, published, up, ioq, staleq, renamed, retire,
                   halt, plan, fin, envVars, ghosts>>

\* The facts reconcile reports for row r.  B00: the checkpoint is the attempt
\* working partial.  Before B00 it was measured at the published path, where
\* a row that is still transferring has no file.
RelaunchFacts(r) ==
    Fx("staticRange", FALSE,
       IF FixB00 /\ dur[r] > 0 /\ ~row[r].bodyCondemned THEN "partial" ELSE "none",
       IF Life(r) \in Terminal THEN (IF published[r] THEN "published" ELSE "none")
       ELSE IF Life(r) = "finalizing" /\ dur[r] >= NSeg THEN "workingComplete"
       ELSE "none",
       FALSE, FALSE,
       \* The live-task fact is reattach's snapshot of tracked tasks.  It does
       \* not count a queued apply, a pending continuation or the finalizer (R2).
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
\* it never exists, so the self-heal never fired.
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
    \/ Crash \/ Relaunch \/ ForegroundReattachBegins

Spec == Init /\ [][Next]_vars

\* Liveness: every app step is weakly fair, the daemon resolves every task,
\* and a task that keeps being retried eventually finishes.  The environment
\* (user, crashes, foreground, source changes) is not fair.
Fairness ==
    /\ WF_vars(Relaunch)
    /\ \A r \in Rows :
          /\ WF_vars(Plan(r)) /\ WF_vars(FinalizeOutcome(r)) /\ WF_vars(PauseSweep(r))
          /\ WF_vars(Reattach(r)) /\ WF_vars(RelaunchObserved(r))
          /\ WF_vars(AutoResume(r)) /\ WF_vars(StaleRowHeal(r))
          /\ \A b \in Bodies :
                /\ WF_vars(DidFinishDownloading(r, b))
                /\ WF_vars(DidCompleteWithError(r, b))
                /\ WF_vars(Apply(r, b))
                /\ WF_vars(HoldManifested(r, b)) /\ WF_vars(RetireDone(r, b))
                /\ WF_vars(DaemonFinishes(r, b) \/ DaemonFails(r, b))
                /\ SF_vars(DaemonFinishes(r, b))

FairSpec == Spec /\ Fairness

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
        Owns(r, b) /\ halt[r] # "cancel" /\ restarts = 0 => b \in heldFile[r]

\* A manifest names a file that exists.  (A purge that overtakes a hold in
\* flight is the exception the code handles at drain time; it needs a
\* changed resource.)
ManifestedBodyExists ==
    \A r \in Rows : \A b \in manifest[r] : b \in heldFile[r]

\* A held body the session may drain is on disk.
HeldBodyExists ==
    \A r \in Rows : \A b \in Mine(r, held[r]) \ retire[r] :
        restarts = 0 /\ Life(r) \in {"admitted", "transferring", "paused"}
        => b \in heldFile[r]

\* A finalizing or playable row has the whole file.
FinalizingHasBody ==
    \A r \in Rows : Life(r) = "finalizing" => dur[r] >= NSeg
CompleteIsWhole ==
    \A r \in Rows : Life(r) \in Playable => dur[r] >= NSeg /\ published[r]

\* The planner never tops the train up beyond its depth: after a step that
\* starts a task, the tracked tasks, held bodies and claimed finished bodies
\* together cover at most Depth offsets.
PlannerRespectsDepth ==
    [][\A r \in Rows :
          (\E b \in Bodies : task[r][b] # "running" /\ task'[r][b] = "running")
          => Cardinality(Covered(r))' <= Depth]_vars

\* R1: the train is never left with nothing to do.  An active, unhalted row
\* always has a live task, queued range IO, a pending continuation or a
\* finalizer, unless recovery is about to look at it.
InFlight(r) ==
    \/ SessionOwnsWork(r) \/ renamed[r] # {} \/ retire[r] # {}
    \/ \E b \in Bodies : task[r][b] \in {"finished", "failed"}
TrainNeverStranded ==
    \A r \in Rows :
        up /\ ActiveRow(r) /\ halt[r] = "none" /\ recon[r] = "idle" => InFlight(r)

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
\* holds only with the proposed fix.
ReconcileNeverFailsOwnedWork ==
    [][\A r \in Rows :
          /\ recon[r] = "needReconcile" /\ recon'[r] = "idle"
          /\ ActiveRow(r) /\ SessionOwnsWork(r)
          => Life(r)' # "failed"]_vars

\* B00: recovery never discards the attempt's checkpoint.  The working file
\* only shrinks when the source changed (ResourceChanged).
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
