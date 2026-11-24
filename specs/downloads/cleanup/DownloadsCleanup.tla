-------------------------- MODULE DownloadsCleanup --------------------------
(***************************************************************************)
(* Delete, from the tap to the last reclaimed byte: the row-deletion       *)
(* barrier in the index, the artifact worker that unlinks files, the       *)
(* server-cleanup intent journal and its runner, and a volume that can be  *)
(* completely full.                                                        *)
(*                                                                         *)
(* Actors:                                                                 *)
(*   User      UserFirstDelete, UserRetap (Delete again), UserRetry        *)
(*   Manager   PrepJournal, PrepProof (prepareForDestructiveDeletionAsync) *)
(*   Writer    Commit: the revisioned index writer saves a full snapshot   *)
(*   Worker    the serial artifact worker.  Deletion: DelPrepared,         *)
(*             DelUnlinkOne, DelRemoveRow, DelCommitted and their failure  *)
(*             steps.  Promotion (the head a Delete can queue behind):     *)
(*             SubmitPromotion, PromoRename, PromoCommitted, PromoIOFails, *)
(*             RetireCommitted.  AutoRetryHead, ExplicitRecover.           *)
(*   Recovery  RecoverRename, RecoverCommit: the launch pass that finishes *)
(*             a legacy validated promotion                                *)
(*   Runner    JournalTerminalRelease, RunnerCancel, RunnerClearRef,       *)
(*             RunnerRetire                                                *)
(*   Server    a job is running or cancelled; RunnerCancel is its DELETE   *)
(*   Disk      FillDisk, FreeDisk, OsFlush                                 *)
(*   Crash     Crash (process death), PowerLoss (also drops unsynced       *)
(*             journal bytes), Relaunch                                    *)
(*                                                                         *)
(* Durable state survives Crash; in-memory state does not.  See the        *)
(* VARIABLES block.  Each fix under test is a BOOLEAN constant: TRUE is    *)
(* the shipping behaviour, FALSE restores the bug.  PROPOSED constants are *)
(* fixes that are not in the code.                                         *)
(*                                                                         *)
(* Abstractions (DownloadsCleanup.md lists what is not covered):           *)
(*  - A row is one attempt.  Retry-by-replacement and two rows naming the  *)
(*    same path are not modelled, so the cross-row exclusion in            *)
(*    executeRowDeletion is not exercised.                                 *)
(*  - A row has at most two files, "working" and "stable".  Side assets,   *)
(*    resume blobs and held range bodies are not modelled.                 *)
(*  - The index is one snapshot: Commit copies every in-memory row to      *)
(*    disk.  "This revision is committed" is "this row's durable copy      *)
(*    equals its in-memory copy" (Durable).                                *)
(*  - The volume is full or not.  When it is full every index and journal  *)
(*    commit fails; unlinking a file makes room again.                     *)
(*  - A row has at most one server job, and every job is resumable (an     *)
(*    Emby Convert job): a failed row keeps it for Retry.  Encoders,       *)
(*    abandonment intents and the ownership recheck against other rows are *)
(*    not modelled.                                                        *)
(*  - The journal holds at most one intent per row.  Backoff and timers    *)
(*    are not modelled: a step that can run may run.                       *)
(*                                                                         *)
(* Lifecycle and history change only through Reduce (DownloadsReducer.tla).*)
(***************************************************************************)
\* MODELS: Labstream/Capabilities/Downloads/Core/DownloadStore.swift
\* MODELS: Labstream/Capabilities/Downloads/Core/DownloadManager.swift
\* MODELS: Labstream/Capabilities/Downloads/Core/DownloadManager+CleanupRunner.swift
\* MODELS: Labstream/Capabilities/Downloads/Core/DownloadCleanupOrdering.swift
\* MODELS: Labstream/Capabilities/Downloads/Core/DownloadCleanupIntentJournal.swift
\* MODELS: Labstream/Capabilities/Downloads/Core/DownloadCleanupIntentRunner.swift
\* MODELS: Labstream/Capabilities/Downloads/Core/DownloadArtifactLifecycleCoordinator.swift
\* MODELS: Labstream/Capabilities/Downloads/Core/DurableJournalCommit.swift
\* MODELS: PMSKit/Sources/PMSKit/Downloads/DurableDownloadCleanupIntent.swift
\* MODELS: PMSKit/Sources/PMSKit/Downloads/CleanupIntentEligibilityPolicy.swift
EXTENDS DownloadsReducer, TLC

CONSTANTS
    Rows,              \* download keys
    InitKinds,         \* the kinds of row a run may start with (RowKinds)
    LegacyFiles,       \* the file sets a "legacy" row may start with
    FixB18,            \* a journal write is reported committed only after a full sync
    FixB28,            \* Delete journals server cleanup and cancels only after the row is gone
    FixB44,            \* a failed row keeps its Convert job for Retry
    FixC1,             \* PROPOSED (not in the code): a re-registered row deletion still
                       \*   waits for its intent to be durable before it unlinks
    FixB27,            \* PROPOSED (not in the code): Delete preempts a legacy validated promotion
    FixB27Fence,       \* PROPOSED (not in the code): that Delete and the launch recovery
                       \*   exclude each other
    FixB30,            \* PROPOSED (not in the code): reserved capacity for Delete's own writes
    ExplicitRecovery,  \* other work in the process triggers explicit artifact recovery
    DiskFills,         \* the volume may become completely full
    DiskFrees,         \* something outside the app may free space
    PromoFails,        \* a promotion's rename may fail
    BoundEnvironment,  \* TRUE: at most EnvBudget environment steps (liveness runs)
    EnvBudget

RowKinds == {"complete", "completeJob", "prep", "failedJob", "finalizing", "legacy"}
FileNames == {"working", "stable"}

ASSUME /\ InitKinds \subseteq RowKinds /\ InitKinds # {}
       /\ LegacyFiles \subseteq SUBSET FileNames /\ LegacyFiles # {}
       /\ EnvBudget \in Nat

\* SYMMETRY for safety configs: rows are model values and every row draws its
\* kind from the same set, so nothing tells two rows apart.
RowSymmetry == Permutations(Rows)

\* Row.ArtifactIntentOperation, the two this model follows.
IntentKinds == {"promo", "del"}
\* DurableDownloadCleanupIntent.Provenance without abandonment, plus "none".
JournalEntries == {"none", "rowDeletion", "terminalRelease"}

VARIABLES
    \* ---- durable: the committed index (survives Crash) ----
    dIdx,      \* [Rows -> row]  see RowOK
    \* ---- durable: files, the volume, the cleanup journal ----
    files,     \* [Rows -> SUBSET FileNames]
    full,      \* BOOLEAN   the volume has no free block
    jrnl,      \* [Rows -> JournalEntries]  download-cleanup-intents.json
    jSynced,   \* [Rows -> BOOLEAN]  the entry would survive power loss
    \* ---- the server (survives Crash) ----
    job,       \* [Rows -> {"none","running","cancelled"}]
    \* ---- the user (survives Crash) ----
    userWants, \* [Rows -> BOOLEAN]  the user has asked for this row to be deleted
    \* ---- in memory (lost at Crash) ----
    up,        \* BOOLEAN
    mIdx,      \* [Rows -> row]  DownloadStore.rows
    wk,        \* [Rows -> WorkerStates]  the row's artifact queue head, if active
    waived,    \* [Rows -> BOOLEAN]  the active head's ticket has preparedRevision 0
    headIO,    \* [Rows -> BOOLEAN]  failedArtifactIOIntentIDs: no automatic retry
    todo,      \* [Rows -> SUBSET FileNames]  paths the deletion worker has yet to unlink
    saved,     \* [Rows -> row]  the row a worker took out of memory, for restore
    prep,      \* [Rows -> PrepStates]  deletionPreparationTasks
    recov,     \* [Rows -> RecovStates]  the legacy promotion recovery pass
    \* ---- ghost (never read by a guard) ----
    budget     \* 0..EnvBudget

WorkerStates ==
    {"idle", "delWait", "delUnlink", "delCommit", "promoWait", "promoCommit",
     "retireCommit"}
\* artifactRetirementKeys: the row is between a terminal mutation and its commit.
Retiring == {"delCommit", "promoCommit", "retireCommit"}
PrepStates == {"idle", "reserving", "journaled", "journalFailed"}
RecovStates == {"idle", "pending", "renamed"}

durVars == <<dIdx, files, full, jrnl, jSynced, job, userWants>>
memVars == <<mIdx, wk, waived, headIO, todo, saved, prep, recov>>
vars    == <<durVars, up, memVars, budget>>

-----------------------------------------------------------------------------
(* Rows                                                                    *)

\* The part of DownloadStore.Row this model follows.
\*   legacy      pendingValidatedPromotionStatus is set (written by old builds)
\*   delPending  deletionPending with its captured cleanup intents (the capsule)
\*   queue       pendingArtifactIntents
\*   jobRef      the metadata still names a server job
RowRec(st, legacy, jobRef) ==
    [present |-> TRUE, st |-> st, legacy |-> legacy, delPending |-> FALSE,
     queue |-> <<>>, jobRef |-> jobRef]
AbsentRow ==
    [present |-> FALSE, st |-> InitialState("planned"), legacy |-> FALSE,
     delPending |-> FALSE, queue |-> <<>>, jobRef |-> FALSE]

HasDel(row) == \E i \in DOMAIN row.queue : row.queue[i] = "del"
\* Row.pendingArtifactIntents.first
HeadOf(row) == IF row.queue = <<>> THEN "none" ELSE Head(row.queue)
WaitState(head) == IF head = "promo" THEN "promoWait" ELSE "delWait"

KindRow(k) ==
    CASE k = "complete"    -> RowRec(InitialState("complete"), FALSE, FALSE)
      [] k = "completeJob" -> RowRec(InitialState("complete"), FALSE, TRUE)
      [] k = "prep"        -> RowRec(InitialState("serverPrep"), FALSE, TRUE)
      [] k = "failedJob"   -> RowRec(St("failed", "none", "server", "none", "none",
                                        FALSE, FALSE, 0, "none", {}), FALSE, TRUE)
      [] k = "finalizing"  -> RowRec(InitialState("finalizing"), FALSE, FALSE)
      [] k = "legacy"      -> RowRec(InitialState("transferring"), TRUE, FALSE)
KindFiles(k, legacyFiles) ==
    CASE k \in {"complete", "completeJob"} -> {"stable"}
      [] k = "finalizing" -> {"working"}
      [] k = "legacy" -> legacyFiles
      [] OTHER -> {}

\* Every revision that touched this row is committed.
Durable(r) == dIdx[r] = mIdx[r]

\* A Delete is under way for this row (what FixB30's reserve may be spent on).
DeleteInFlight(r) ==
    \/ mIdx[r].delPending \/ HasDel(mIdx[r])
    \/ wk[r] = "delCommit" \/ prep[r] # "idle"
\* An index commit can succeed.
CanCommit == ~full \/ (FixB30 /\ \E r \in Rows : DeleteInFlight(r))
\* The journal write that Delete makes can succeed.
CanJournalDelete == ~full \/ FixB30

\* Environment steps.  Liveness runs bound them.
Spend == IF BoundEnvironment
            THEN budget > 0 /\ budget' = budget - 1
            ELSE UNCHANGED budget

RowOK(row) ==
    /\ DOMAIN row = {"present", "st", "legacy", "delPending", "queue", "jobRef"}
    /\ row.present \in BOOLEAN /\ row.legacy \in BOOLEAN
    /\ row.delPending \in BOOLEAN /\ row.jobRef \in BOOLEAN
    /\ row.st.lifecycle \in Lifecycles
    /\ row.st.lastFailure \in FailureReasons
    /\ row.queue \in Seq(IntentKinds) /\ Len(row.queue) <= 2

TypeOK ==
    /\ \A r \in Rows : RowOK(dIdx[r]) /\ RowOK(mIdx[r]) /\ RowOK(saved[r])
    /\ files \in [Rows -> SUBSET FileNames]
    /\ full \in BOOLEAN
    /\ jrnl \in [Rows -> JournalEntries]
    /\ jSynced \in [Rows -> BOOLEAN]
    /\ job \in [Rows -> {"none", "running", "cancelled"}]
    /\ userWants \in [Rows -> BOOLEAN]
    /\ up \in BOOLEAN
    /\ wk \in [Rows -> WorkerStates]
    /\ waived \in [Rows -> BOOLEAN]
    /\ headIO \in [Rows -> BOOLEAN]
    /\ todo \in [Rows -> SUBSET FileNames]
    /\ prep \in [Rows -> PrepStates]
    /\ recov \in [Rows -> RecovStates]
    /\ budget \in 0..EnvBudget

Init ==
    \E kinds \in [Rows -> InitKinds] :
    \E lf \in [Rows -> LegacyFiles] :
        /\ dIdx = [r \in Rows |-> KindRow(kinds[r])]
        /\ mIdx = dIdx
        /\ files = [r \in Rows |-> KindFiles(kinds[r], lf[r])]
        /\ full = FALSE
        /\ jrnl = Const(Rows, "none")
        /\ jSynced = Const(Rows, TRUE)
        /\ job = [r \in Rows |-> IF KindRow(kinds[r]).jobRef THEN "running" ELSE "none"]
        /\ userWants = Const(Rows, FALSE)
        /\ up = TRUE
        /\ wk = Const(Rows, "idle")
        /\ waived = Const(Rows, FALSE)
        /\ headIO = Const(Rows, FALSE)
        /\ todo = Const(Rows, {})
        /\ saved = Const(Rows, AbsentRow)
        /\ prep = Const(Rows, "idle")
        \* The process has just launched: the legacy recovery pass is scheduled.
        /\ recov = [r \in Rows |-> IF dIdx[r].legacy THEN "pending" ELSE "idle"]
        /\ budget = IF BoundEnvironment THEN EnvBudget ELSE 0

-----------------------------------------------------------------------------
(* The index writer                                                        *)

\* RevisionedPersistenceWriter: the newest full snapshot reaches the disk.
Commit ==
    /\ up /\ mIdx # dIdx /\ CanCommit
    /\ dIdx' = mIdx
    /\ UNCHANGED <<files, full, jrnl, jSynced, job, userWants, up, memVars, budget>>

-----------------------------------------------------------------------------
(* Delete (DownloadManager.delete(record:), DownloadCleanupOrdering)       *)

\* DownloadStore.submitRemove / stageRowDeletionLocked for `row`: stage the
\* row-deletion intent (or find the one already staged) and start the queue
\* head if nothing is running.  A head other than the intent this call owns
\* is registered with preparedRevision 0 (activateArtifactHeadLocked).
StageDel(r, row) ==
    LET q == IF HasDel(row) THEN row.queue ELSE Append(row.queue, "del")
        head == Head(q)
    IN /\ mIdx' = Upd(mIdx, r, [row EXCEPT !.queue = q])
       /\ IF wk[r] = "idle"
             THEN /\ wk' = Upd(wk, r, WaitState(head))
                  /\ waived' = Upd(waived, r, head # "del" /\ ~FixC1)
                  /\ headIO' = Upd(headIO, r, FALSE)
             ELSE UNCHANGED <<wk, waived, headIO>>

\* submitRemove and submitDeletionPending both refuse a row whose legacy
\* promotion flag is set (B27).
DeleteRefused(r) ==
    /\ mIdx[r].legacy
    /\ ~(FixB27 /\ (FixB27Fence => recov[r] = "idle"))

DeleteBody(r) ==
    LET row == mIdx[r] IN
    /\ up /\ row.present /\ prep[r] = "idle"
    /\ wk[r] \notin {"delWait", "delUnlink", "delCommit"}
    /\ userWants' = Upd(userWants, r, TRUE)
    /\ IF DeleteRefused(r) THEN
            \* `.stale`: "delete_owner_changed".  Nothing happens.
            UNCHANGED <<dIdx, files, full, jrnl, jSynced, job, up, memVars>>
       ELSE IF ~FixB28 /\ row.jobRef THEN
            \* B28 off: cancel the server job now, without a journal entry
            \* and before the row's removal is proven.
            /\ job' = Upd(job, r, IF job[r] = "running" THEN "cancelled" ELSE job[r])
            /\ StageDel(r, row)
            /\ UNCHANGED <<dIdx, files, full, jrnl, jSynced, up, todo, saved, prep, recov>>
       ELSE IF row.jobRef \/ row.delPending THEN
            \* submitDeletionPending: reserve the row as cleanup authority.
            /\ mIdx' = Upd(mIdx, r, [row EXCEPT !.delPending = TRUE])
            /\ prep' = Upd(prep, r, "reserving")
            /\ UNCHANGED <<dIdx, files, full, jrnl, jSynced, job, up, wk, waived,
                           headIO, todo, saved, recov>>
       ELSE
            /\ StageDel(r, row)
            /\ UNCHANGED <<dIdx, files, full, jrnl, jSynced, job, up, todo, saved,
                           prep, recov>>

UserFirstDelete(r) == ~userWants[r] /\ Spend /\ DeleteBody(r)
\* "Tap Delete to retry."  The user keeps asking until the row is gone.
UserRetap(r) == userWants[r] /\ UNCHANGED budget /\ DeleteBody(r)

\* journal.ensure, running beside the reservation's commit.  An entry for the
\* same operation is reused with the provenance it already has.
PrepJournal(r) ==
    /\ up /\ prep[r] = "reserving"
    /\ IF CanJournalDelete
          THEN /\ jrnl' = Upd(jrnl, r, IF jrnl[r] = "none" THEN "rowDeletion" ELSE jrnl[r])
               /\ jSynced' = Upd(jSynced, r, FixB18 \/ (jrnl[r] # "none" /\ jSynced[r]))
               /\ prep' = Upd(prep, r, "journaled")
          ELSE /\ prep' = Upd(prep, r, "journalFailed")
               /\ UNCHANGED <<jrnl, jSynced>>
    /\ UNCHANGED <<dIdx, files, full, job, userWants, up, mIdx, wk, waived, headIO,
                   todo, saved, recov, budget>>

\* The reservation's proof and the journal's result together.
PrepProof(r) ==
    /\ up /\ prep[r] \in {"journaled", "journalFailed"}
    /\ prep' = Upd(prep, r, "idle")
    /\ \/ \* `.ready`: finishDeletion -> submitCompletePendingDeletion
          /\ mIdx[r].delPending /\ Durable(r) /\ prep[r] = "journaled"
          /\ StageDel(r, mIdx[r])
       \/ \* `.deletionPending`: the capsule stays as the only authority
          /\ mIdx[r].delPending /\ Durable(r) /\ prep[r] = "journalFailed"
          /\ UNCHANGED <<mIdx, wk, waived, headIO>>
       \/ \* `.indexPersistenceFailed`
          /\ mIdx[r].delPending /\ ~Durable(r) /\ ~CanCommit
          /\ UNCHANGED <<mIdx, wk, waived, headIO>>
       \/ \* `.staleOrMissing`: the worker already removed the row
          /\ ~mIdx[r].delPending
          /\ UNCHANGED <<mIdx, wk, waived, headIO>>
    /\ UNCHANGED <<durVars, up, todo, saved, recov, budget>>

\* Retry of a failed row resumes its server job (convertResume).
UserRetry(r) ==
    LET row == mIdx[r]
        t == Reduce(row.st, EvRetry("convertResume"), NoFacts)
    IN /\ up /\ Spend
       /\ row.present /\ row.st.lifecycle = "failed" /\ row.jobRef
       /\ ~row.delPending /\ row.queue = <<>> /\ ~row.legacy
       /\ IsApplied(t)
       /\ mIdx' = Upd(mIdx, r, [row EXCEPT !.st = t.state])
       /\ UNCHANGED <<durVars, up, wk, waived, headIO, todo, saved, prep, recov>>

-----------------------------------------------------------------------------
(* The artifact worker: row deletion (executeRowDeletion)                  *)

\* waitForPersistence(through: ticket.preparedRevision).  A ticket with
\* preparedRevision 0 passes at once, whatever the disk holds.
DelPrepared(r) ==
    /\ up /\ wk[r] = "delWait"
    /\ Durable(r) \/ waived[r]
    /\ wk' = Upd(wk, r, "delUnlink")
    /\ todo' = Upd(todo, r, FileNames)
    /\ UNCHANGED <<durVars, up, mIdx, waived, headIO, saved, prep, recov, budget>>

\* failArtifactLifecycle(ticket, failure): the intent stays queued in memory.
DelPreparedFails(r) ==
    /\ up /\ wk[r] = "delWait"
    /\ ~Durable(r) /\ ~waived[r] /\ ~CanCommit
    /\ wk' = Upd(wk, r, "idle")
    /\ UNCHANGED <<durVars, up, mIdx, waived, headIO, todo, saved, prep, recov, budget>>

\* One path of the recipe.  Unlinking a file that exists makes room.
DelUnlinkOne(r, f) ==
    /\ up /\ wk[r] = "delUnlink" /\ f \in todo[r]
    /\ todo' = Upd(todo, r, todo[r] \ {f})
    /\ files' = Upd(files, r, files[r] \ {f})
    /\ full' = IF f \in files[r] THEN FALSE ELSE full
    /\ UNCHANGED <<dIdx, jrnl, jSynced, job, userWants, up, mIdx, wk, waived, headIO,
                   saved, prep, recov, budget>>

\* rows.removeValue, then the terminal snapshot is submitted.
DelRemoveRow(r) ==
    /\ up /\ wk[r] = "delUnlink" /\ todo[r] = {}
    /\ saved' = Upd(saved, r, mIdx[r])
    /\ mIdx' = Upd(mIdx, r, AbsentRow)
    /\ wk' = Upd(wk, r, "delCommit")
    /\ UNCHANGED <<durVars, up, waived, headIO, todo, prep, recov, budget>>

DelCommitted(r) ==
    /\ up /\ wk[r] = "delCommit" /\ Durable(r)
    /\ wk' = Upd(wk, r, "idle")
    /\ waived' = Upd(waived, r, FALSE)
    /\ saved' = Upd(saved, r, AbsentRow)
    /\ UNCHANGED <<durVars, up, mIdx, headIO, todo, prep, recov, budget>>

\* The terminal commit failed: the row, with its intent, goes back.
DelCommitFails(r) ==
    /\ up /\ wk[r] = "delCommit" /\ ~Durable(r) /\ ~CanCommit
    /\ mIdx' = Upd(mIdx, r, saved[r])
    /\ saved' = Upd(saved, r, AbsentRow)
    /\ wk' = Upd(wk, r, "idle")
    /\ waived' = Upd(waived, r, FALSE)
    /\ UNCHANGED <<durVars, up, headIO, todo, prep, recov, budget>>

-----------------------------------------------------------------------------
(* The artifact worker: validated promotion (executeValidatedPromotion)    *)

\* The finalizer publishes a validated body (submitValidatedPromotion).
SubmitPromotion(r) ==
    LET row == mIdx[r] IN
    /\ up /\ row.present /\ row.st.lifecycle = "finalizing"
    /\ ~row.delPending /\ ~row.legacy /\ row.queue = <<>> /\ wk[r] = "idle"
    /\ "working" \in files[r]
    /\ mIdx' = Upd(mIdx, r, [row EXCEPT !.queue = <<"promo">>])
    /\ wk' = Upd(wk, r, "promoWait")
    /\ waived' = Upd(waived, r, FALSE)
    /\ UNCHANGED <<durVars, up, headIO, todo, saved, prep, recov, budget>>

\* The promotion commits its captured source before it renames, so it never
\* runs ahead of the disk, whatever its ticket says.  With no body left it
\* abandons the intent (abandonUnrecoverablePromotion).
PromoRename(r) ==
    LET row == mIdx[r]
        committed == Reduce(row.st, EvPromotion("promotionCommitted", "complete"), NoFacts)
        recovered == Reduce(row.st, EvPromotion("promotionRecovered", "complete"), NoFacts)
        abandoned == Reduce(row.st,
                            IF row.st.lifecycle = "finalizing"
                               THEN Ev("promotionAbandoned")
                               ELSE EvReason("transferFailed", "internalError"), NoFacts)
        \* applyPromotionTerminal
        published == IF IsApplied(committed) THEN committed.state ELSE recovered.state
        next == IF files[r] = {}
                   THEN (IF IsApplied(abandoned) THEN abandoned.state ELSE row.st)
                   ELSE published
    IN /\ up /\ wk[r] = "promoWait" /\ Durable(r)
       /\ files' = Upd(files, r, IF files[r] = {} THEN {} ELSE {"stable"})
       /\ mIdx' = Upd(mIdx, r, [row EXCEPT !.st = next, !.queue = Tail(row.queue)])
       /\ wk' = Upd(wk, r, "promoCommit")
       /\ UNCHANGED <<dIdx, full, jrnl, jSynced, job, userWants, up, waived, headIO,
                      todo, saved, prep, recov, budget>>

\* After the commit the worker starts the next head.  Its ticket was made
\* when it was staged, and that revision is now on disk.
PromoCommitted(r) ==
    /\ up /\ wk[r] = "promoCommit" /\ Durable(r)
    /\ wk' = Upd(wk, r, IF mIdx[r].queue = <<>> THEN "idle"
                                               ELSE WaitState(Head(mIdx[r].queue)))
    /\ waived' = Upd(waived, r, FALSE)
    /\ UNCHANGED <<durVars, up, mIdx, headIO, todo, saved, prep, recov, budget>>

\* The terminal commit failed: the intent goes back to the head.
PromoCommitFails(r) ==
    /\ up /\ wk[r] = "promoCommit" /\ ~Durable(r) /\ ~CanCommit
    /\ mIdx' = Upd(mIdx, r, [mIdx[r] EXCEPT !.queue = <<"promo">> \o @])
    /\ wk' = Upd(wk, r, "idle")
    /\ waived' = Upd(waived, r, FALSE)
    /\ UNCHANGED <<durVars, up, headIO, todo, saved, prep, recov, budget>>

\* failArtifactLifecycle before the rename, for a commit that cannot land.
PromoPreparedFails(r) ==
    /\ up /\ wk[r] = "promoWait" /\ ~Durable(r) /\ ~CanCommit
    /\ wk' = Upd(wk, r, "idle")
    /\ waived' = Upd(waived, r, FALSE)
    /\ UNCHANGED <<durVars, up, mIdx, headIO, todo, saved, prep, recov, budget>>

\* The rename fails.  With a row deletion queued behind it the failed head is
\* retired first (retireFailedHeadBeforeQueuedRowDeletion); otherwise it
\* stays, and only an explicit recovery restarts it.
PromoIOFails(r) ==
    LET row == mIdx[r] IN
    /\ PromoFails /\ Spend
    /\ up /\ wk[r] = "promoWait" /\ Durable(r) /\ files[r] # {}
    /\ IF HasDel(row)
          THEN /\ saved' = Upd(saved, r, row)
               /\ mIdx' = Upd(mIdx, r, [row EXCEPT !.queue = Tail(row.queue)])
               /\ wk' = Upd(wk, r, "retireCommit")
               /\ UNCHANGED headIO
          ELSE /\ wk' = Upd(wk, r, "idle")
               /\ headIO' = Upd(headIO, r, TRUE)
               /\ UNCHANGED <<mIdx, saved>>
    /\ waived' = Upd(waived, r, FALSE)
    /\ UNCHANGED <<durVars, up, todo, prep, recov>>

RetireCommitted(r) ==
    /\ up /\ wk[r] = "retireCommit" /\ Durable(r)
    /\ wk' = Upd(wk, r, "delWait")
    /\ saved' = Upd(saved, r, AbsentRow)
    /\ UNCHANGED <<durVars, up, mIdx, waived, headIO, todo, prep, recov, budget>>

RetireCommitFails(r) ==
    /\ up /\ wk[r] = "retireCommit" /\ ~Durable(r) /\ ~CanCommit
    /\ mIdx' = Upd(mIdx, r, saved[r])
    /\ saved' = Upd(saved, r, AbsentRow)
    /\ wk' = Upd(wk, r, "idle")
    /\ headIO' = Upd(headIO, r, TRUE)
    /\ UNCHANGED <<durVars, up, waived, todo, prep, recov, budget>>

-----------------------------------------------------------------------------
(* Restarting a failed head (recoverPendingArtifactIntents)                *)

\* explicit: false, after any successful commit.  Only a head whose prepared
\* revision failed and has since landed is retried (B17).
AutoRetryHead(r) ==
    /\ up /\ wk[r] = "idle" /\ mIdx[r].present /\ mIdx[r].queue # <<>>
    /\ ~headIO[r] /\ Durable(r)
    /\ wk' = Upd(wk, r, WaitState(Head(mIdx[r].queue)))
    /\ waived' = Upd(waived, r, FALSE)
    /\ UNCHANGED <<durVars, up, mIdx, headIO, todo, saved, prep, recov, budget>>

\* explicit: true.  resumeAfterPersistence and the background-completion flush
\* call it for every row through currentArtifactLifecycleWatermark, and so
\* does another row's failed head.  The head's ticket is gone, so a new one
\* is registered with preparedRevision 0.
ExplicitRecover(r) ==
    /\ ExplicitRecovery /\ Spend
    /\ up /\ wk[r] = "idle" /\ mIdx[r].present /\ mIdx[r].queue # <<>>
    /\ wk' = Upd(wk, r, WaitState(Head(mIdx[r].queue)))
    /\ waived' = Upd(waived, r, ~FixC1)
    /\ headIO' = Upd(headIO, r, FALSE)
    /\ UNCHANGED <<durVars, up, mIdx, todo, saved, prep, recov>>

-----------------------------------------------------------------------------
(* The legacy promotion recovery (recoverPendingValidatedPromotion)        *)

\* The launch pass skips a deletion-pending row.  FixB27Fence also makes it
\* skip a row with a staged row deletion.
RecoverSkips(r) ==
    \/ ~mIdx[r].present \/ ~mIdx[r].legacy \/ mIdx[r].delPending
    \/ FixB27Fence /\ HasDel(mIdx[r])

\* Rename the working body over the stable path, outside the store lock.
\* With neither body the pass returns `.sourceMissing` and the flag stays.
RecoverRename(r) ==
    /\ up /\ recov[r] = "pending"
    /\ IF RecoverSkips(r) \/ files[r] = {}
          THEN recov' = Upd(recov, r, "idle") /\ UNCHANGED files
          ELSE /\ files' = Upd(files, r, {"stable"})
               /\ recov' = Upd(recov, r, "renamed")
    /\ UNCHANGED <<dIdx, full, jrnl, jSynced, job, userWants, up, mIdx, wk, waived,
                   headIO, todo, saved, prep, budget>>

\* Back under the lock: the row must still carry the flag.
RecoverCommit(r) ==
    LET row == mIdx[r]
        t == Reduce(row.st, EvPromotion("promotionRecovered", "complete"), NoFacts)
    IN /\ up /\ recov[r] = "renamed"
       /\ recov' = Upd(recov, r, "idle")
       /\ IF row.present /\ row.legacy /\ "stable" \in files[r] /\ IsApplied(t)
             THEN mIdx' = Upd(mIdx, r, [row EXCEPT !.st = t.state, !.legacy = FALSE])
             ELSE UNCHANGED mIdx
       /\ UNCHANGED <<durVars, up, wk, waived, headIO, todo, saved, prep, budget>>

-----------------------------------------------------------------------------
(* The cleanup runner (DownloadCleanupIntentRunner, CleanupIntentEligibilityPolicy) *)

\* DownloadStore.cleanupDisposition, read from memory.
RowStateOf(r) ==
    IF wk[r] \in Retiring THEN "retiring"
    ELSE IF ~mIdx[r].present THEN "committedAbsent"
    ELSE IF mIdx[r].delPending \/ HasDel(mIdx[r]) THEN "retiring"
    ELSE "present"

\* shouldKeepEmbyConvertAuthorityForRetry: a failed row's Retry resumes the job.
Protects(r) == FixB44 /\ mIdx[r].st.lifecycle = "failed"

\* CleanupIntentEligibilityPolicy.decision = .run
MayRun(r) ==
    CASE RowStateOf(r) = "retiring" -> FALSE
      [] RowStateOf(r) = "committedAbsent" -> jrnl[r] # "none"
      [] OTHER -> /\ jrnl[r] = "terminalRelease"
                  /\ mIdx[r].st.lifecycle \in Terminal
                  /\ ~Protects(r)

\* A terminal row still names a server job: journal a terminal release.  The
\* launch sweep skips a protected failed row, but the one-time classification
\* of an entry written before provenance existed does not, so this producer
\* is unconditional and the runner's check is what protects the job.
JournalTerminalRelease(r) ==
    LET row == mIdx[r] IN
    /\ up /\ row.present /\ row.st.lifecycle \in Terminal /\ row.jobRef
    /\ ~row.delPending /\ ~HasDel(row)
    /\ jrnl[r] = "none" /\ job[r] = "running" /\ ~full
    /\ jrnl' = Upd(jrnl, r, "terminalRelease")
    /\ jSynced' = Upd(jSynced, r, FixB18)
    /\ UNCHANGED <<dIdx, files, full, job, userWants, up, memVars, budget>>

\* The server call.
RunnerCancel(r) ==
    /\ up /\ jrnl[r] # "none" /\ MayRun(r) /\ job[r] = "running"
    /\ job' = Upd(job, r, "cancelled")
    /\ UNCHANGED <<dIdx, files, full, jrnl, jSynced, userWants, up, memVars, budget>>

\* clearEmbyConvertMetadataIfExact on a row that is still there.
RunnerClearRef(r) ==
    /\ up /\ jrnl[r] # "none" /\ MayRun(r) /\ job[r] # "running"
    /\ mIdx[r].present /\ mIdx[r].jobRef
    /\ mIdx' = Upd(mIdx, r, [mIdx[r] EXCEPT !.jobRef = FALSE])
    /\ UNCHANGED <<durVars, up, wk, waived, headIO, todo, saved, prep, recov, budget>>

\* journal.remove, once the clear is proven.
RunnerRetire(r) ==
    /\ up /\ jrnl[r] # "none" /\ MayRun(r) /\ job[r] # "running"
    /\ ~mIdx[r].present \/ (~mIdx[r].jobRef /\ Durable(r))
    /\ ~full
    /\ jrnl' = Upd(jrnl, r, "none")
    /\ jSynced' = Upd(jSynced, r, TRUE)
    /\ UNCHANGED <<dIdx, files, full, job, userWants, up, memVars, budget>>

-----------------------------------------------------------------------------
(* The volume                                                              *)

FillDisk ==
    /\ DiskFills /\ ~full /\ Spend
    /\ full' = TRUE
    /\ UNCHANGED <<dIdx, files, jrnl, jSynced, job, userWants, up, memVars>>

FreeDisk ==
    /\ DiskFrees /\ full /\ Spend
    /\ full' = FALSE
    /\ UNCHANGED <<dIdx, files, jrnl, jSynced, job, userWants, up, memVars>>

\* The OS writes a visible journal entry through to the device.
OsFlush(r) ==
    /\ ~jSynced[r]
    /\ jSynced' = Upd(jSynced, r, TRUE)
    /\ UNCHANGED <<dIdx, files, full, jrnl, job, userWants, up, memVars, budget>>

-----------------------------------------------------------------------------
(* Crash and recovery                                                      *)

\* Process death.  The in-memory image is gone; what a relaunch will load is
\* the durable index, so mIdx is reset to it.
Crash ==
    /\ up /\ Spend
    /\ up' = FALSE
    /\ mIdx' = dIdx
    /\ wk' = Const(Rows, "idle")
    /\ waived' = Const(Rows, FALSE)
    /\ headIO' = Const(Rows, FALSE)
    /\ todo' = Const(Rows, {})
    /\ saved' = Const(Rows, AbsentRow)
    /\ prep' = Const(Rows, "idle")
    /\ recov' = Const(Rows, "idle")
    /\ UNCHANGED durVars

\* The device dies: a journal entry that was visible but not synced is lost.
PowerLoss ==
    /\ up /\ Spend
    /\ \E r \in Rows : ~jSynced[r]
    /\ up' = FALSE
    /\ jrnl' = [r \in Rows |-> IF jSynced[r] THEN jrnl[r] ELSE "none"]
    /\ jSynced' = Const(Rows, TRUE)
    /\ mIdx' = dIdx
    /\ wk' = Const(Rows, "idle")
    /\ waived' = Const(Rows, FALSE)
    /\ headIO' = Const(Rows, FALSE)
    /\ todo' = Const(Rows, {})
    /\ saved' = Const(Rows, AbsentRow)
    /\ prep' = Const(Rows, "idle")
    /\ recov' = Const(Rows, "idle")
    /\ UNCHANGED <<dIdx, files, full, job, userWants>>

\* Launch: every durable queue head is rescheduled (its intent is on disk),
\* a deletion-pending capsule is re-driven from its captured intents
\* (migrateAndRetryActiveEncodingCleanupOnLaunch), beside a row deletion that
\* is already queued, and the legacy promotion pass runs.
Relaunch ==
    /\ ~up
    /\ up' = TRUE
    /\ wk' = [r \in Rows |-> IF dIdx[r].present /\ dIdx[r].queue # <<>>
                                THEN WaitState(Head(dIdx[r].queue)) ELSE "idle"]
    /\ prep' = [r \in Rows |-> IF dIdx[r].present /\ dIdx[r].delPending
                                  THEN "reserving" ELSE "idle"]
    /\ recov' = [r \in Rows |-> IF dIdx[r].present /\ dIdx[r].legacy
                                   THEN "pending" ELSE "idle"]
    /\ UNCHANGED <<durVars, mIdx, waived, headIO, todo, saved, budget>>

-----------------------------------------------------------------------------

Next ==
    \/ Commit \/ FillDisk \/ FreeDisk \/ Crash \/ PowerLoss \/ Relaunch
    \/ \E r \in Rows :
          \/ UserFirstDelete(r) \/ UserRetap(r) \/ UserRetry(r)
          \/ PrepJournal(r) \/ PrepProof(r)
          \/ DelPrepared(r) \/ DelPreparedFails(r) \/ DelRemoveRow(r)
          \/ DelCommitted(r) \/ DelCommitFails(r)
          \/ \E f \in FileNames : DelUnlinkOne(r, f)
          \/ SubmitPromotion(r) \/ PromoRename(r) \/ PromoCommitted(r)
          \/ PromoCommitFails(r) \/ PromoPreparedFails(r) \/ PromoIOFails(r)
          \/ RetireCommitted(r) \/ RetireCommitFails(r)
          \/ AutoRetryHead(r) \/ ExplicitRecover(r)
          \/ RecoverRename(r) \/ RecoverCommit(r)
          \/ JournalTerminalRelease(r) \/ RunnerCancel(r) \/ RunnerClearRef(r)
          \/ RunnerRetire(r)
          \/ OsFlush(r)

Spec == Init /\ [][Next]_vars

\* The app's own steps run when they can, the user keeps tapping Delete, and
\* the app is relaunched.  Environment faults (crashes, a full volume, a
\* failing rename, explicit recovery from other work) are never forced.
Fairness ==
    /\ WF_vars(Commit) /\ WF_vars(Relaunch)
    /\ \A r \in Rows :
          /\ WF_vars(UserRetap(r))
          /\ WF_vars(PrepJournal(r)) /\ WF_vars(PrepProof(r))
          /\ WF_vars(DelPrepared(r)) /\ WF_vars(DelPreparedFails(r))
          /\ WF_vars(\E f \in FileNames : DelUnlinkOne(r, f))
          /\ WF_vars(DelRemoveRow(r)) /\ WF_vars(DelCommitted(r))
          /\ WF_vars(DelCommitFails(r))
          /\ WF_vars(SubmitPromotion(r)) /\ WF_vars(PromoRename(r))
          /\ WF_vars(PromoCommitted(r)) /\ WF_vars(PromoCommitFails(r))
          /\ WF_vars(PromoPreparedFails(r))
          /\ WF_vars(RetireCommitted(r)) /\ WF_vars(RetireCommitFails(r))
          /\ WF_vars(AutoRetryHead(r))
          /\ WF_vars(RecoverRename(r)) /\ WF_vars(RecoverCommit(r))
          /\ WF_vars(RunnerCancel(r)) /\ WF_vars(RunnerClearRef(r))
          /\ WF_vars(RunnerRetire(r))

FairSpec == Spec /\ Fairness

-----------------------------------------------------------------------------
(* Properties                                                              *)

\* Every byte on disk belongs to a row the index still holds.
NoOrphanFile == \A r \in Rows : files[r] # {} => dIdx[r].present

\* A running server job is always owed to something durable: a row that
\* still names it, or a journal entry.  Otherwise nothing will ever cancel it.
JobAccountable ==
    \A r \in Rows :
        job[r] = "running" => \/ dIdx[r].present /\ dIdx[r].jobRef
                              \/ jrnl[r] # "none"

\* A durable row that is not being deleted and has not finished still needs
\* the server job it names.
NeedsJob(row) ==
    /\ row.present /\ row.jobRef /\ ~row.delPending /\ ~HasDel(row)
    /\ row.st.lifecycle \notin Playable
\* A job is cancelled only when no durable row needs it.
JobKeptWhileNeeded == \A r \in Rows : job[r] = "cancelled" => ~NeedsJob(dIdx[r])

\* The worker unlinks a row's files only when the disk already says the row
\* is being deleted.
DeletionIntentDurableBeforeUnlink ==
    \A r \in Rows :
        wk[r] = "delUnlink" =>
            dIdx[r].present /\ (HasDel(dIdx[r]) \/ dIdx[r].delPending)

\* What a relaunch would load: a playable row that is not marked for deletion
\* still has its published body.
DurablePlayableHasBody ==
    \A r \in Rows :
        (/\ dIdx[r].present /\ dIdx[r].st.lifecycle \in Playable
         /\ ~dIdx[r].delPending /\ ~HasDel(dIdx[r]))
            => "stable" \in files[r]

Gone(r) == ~dIdx[r].present /\ files[r] = {}

\* A Delete the user keeps asking for ends with the row and its bytes gone.
DeleteReclaims == \A r \in Rows : userWants[r] ~> Gone(r)
\* The same property under the names of the open issues it is checked for.
DeleteNotWedgedBehindPromotion == DeleteReclaims
DeleteReclaimsOnFullVolume == DeleteReclaims

\* A deleted row's server job is eventually cancelled.
DeletedRowJobCancelled == \A r \in Rows : userWants[r] ~> job[r] # "running"
=============================================================================
