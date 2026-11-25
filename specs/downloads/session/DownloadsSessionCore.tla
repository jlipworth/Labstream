------------------------ MODULE DownloadsSessionCore ------------------------
(***************************************************************************)
(* The session + finalize + sweep core of the downloads manager, with      *)
(* process death.                                                          *)
(*                                                                         *)
(* One row is one download.  The model follows a row from `admitted` to a  *)
(* terminal lifecycle through these actors:                                *)
(*                                                                         *)
(*   User       UserPause, UserResume, UserRetry, UserDelete               *)
(*   Daemon     the URLSession background daemon, which outlives the app:  *)
(*              DaemonFinishes, DaemonFails                                *)
(*   Session    delegate callbacks carrying the attempt that started the   *)
(*              task: TransferStarted, TransferProgress,                   *)
(*              DidFinishDownloading, DidCompleteWithError, RangeIO,       *)
(*              RebuildFires, StallDetected, PauseSweep, HaltedProgress    *)
(*   Finalizer  BodyAtWorking, FinalizeOutcome, FinalizeOutcomeReplayed,   *)
(*              PublishBody, PromotionCommitted, PromotionAbandoned        *)
(*   Sweeper    the stash sweep inside Reattach; CleanupRuns for Delete    *)
(*   Recovery   Reattach and RelaunchObserved (reconcile), after a         *)
(*              relaunch or a return to the foreground; AutoResume;        *)
(*              AdmissionGranted (a requeued row granted again, A1)        *)
(*   Crash      Crash drops every in-memory variable; Relaunch restarts;   *)
(*              FinalizeTruncatedCrash is a crash inside one finalizer     *)
(*              step                                                       *)
(*                                                                         *)
(* Action names are the reducer's event names where one corresponds        *)
(* (DownloadLifecycleEvent in DownloadLifecycleReducer.swift).             *)
(*                                                                         *)
(* Durable state survives Crash; in-memory state does not.  See the        *)
(* VARIABLES block.  Each fix under test is a BOOLEAN constant: TRUE is    *)
(* the shipping behaviour, FALSE restores the bug so TLC can show that     *)
(* the model sees it.                                                      *)
(*                                                                         *)
(* Abstractions (docs/DOWNLOADS-OFFLINE.md lists what is not covered):     *)
(*  - A static-range file is two segments fetched one after the other; a   *)
(*    forward-only file is one opaque body.  Parallel segment trains and   *)
(*    held out-of-order bodies are not modelled.                           *)
(*  - A queued delegate-to-IO hop and its stash claim are one variable     *)
(*    (`ioq`): the claim is taken when the hop is queued and released      *)
(*    when it ends.  DownloadsCapturePublication opens that hop up for a   *)
(*    forward-only body: the claim before the capture, two publications   *)
(*    of one body, and a publication that waits for the working path.     *)
(*  - Index persistence is atomic per action; the persistence writer and   *)
(*    path leases are not modelled.  The one place where the code moves a  *)
(*    file before the row that explains it is durable (a failing           *)
(*    truncation verdict renames the body away, then waits for its         *)
(*    commit) is the action FinalizeTruncatedCrash: the rename, then a     *)
(*    crash, with the row as it was (F4).                                  *)
(*  - Delete is one durable flag and one cleanup step; the cleanup intent  *)
(*    journal is not modelled.                                             *)
(*                                                                         *)
(* Lifecycle and history change only through Reduce (DownloadsReducer.tla).*)
(* The hand-written exceptions are the "fix off" branches, which restore   *)
(* a historical bug, and the PROPOSED fixes.                               *)
(***************************************************************************)
\* MODELS: Labstream/Capabilities/Downloads/Core/BackgroundDownloadSession.swift
\* MODELS: Labstream/Capabilities/Downloads/Core/DownloadStore.swift
\* MODELS: PMSKit/Sources/PMSKit/Downloads/BackgroundTempFileCleanupPolicy.swift
\* MODELS: PMSKit/Sources/PMSKit/Downloads/StaticRangeFinishedBodyPolicy.swift
\* MODELS: PMSKit/Sources/PMSKit/Downloads/ForwardOnlyFinishedBodyPolicy.swift
\* MODELS: PMSKit/Sources/PMSKit/Downloads/BackgroundFinalizationResultPolicy.swift
EXTENDS DownloadsSessionRowMap, TLC

CONSTANTS
    Rows,               \* download keys
    ForwardRows,        \* the rows on the forward-only route; the rest are static-range
    MaxAttempt,         \* attempt IDs are 1..MaxAttempt
    Outcomes,           \* finalize verdicts the finalizer may return
    FixB02,             \* Pause invalidates queued rebuilds; reattach never adopts a paused row
    FixB03,             \* the stash sweep rechecks the claim of a queued append/publication
    FixB09,             \* transferProgress never promotes a paused row
    FixB10,             \* relaunch re-finalizes a finished forward-only body
    FixB12,             \* the manager's side of a transfer-error handoff acts only for the
                        \* exact attempt that raised it
    FixReplay,          \* truncation strikes are counted per outcome ID (R2-5); FALSE is the
                        \* counter before it: one strike per finalizer run, no IDs anywhere
    FixPauseReconcile,  \* reconcile never promotes a paused row from a live-task fact (F2)
    DurableCapture,     \* F1 (#472): a finished forward-only body is moved to the attempt's
                        \* capture path, which the row references, and bodyCaptured is
                        \* recorded with it; relaunch publishes it
    FixPauseKeepsBody,  \* F3 (#474): a pause never drops a finished body, on either lane
                        \* (ForwardOnlyFinishedBodyPolicy.publication, the reducer's relaunch
                        \* of a paused row, StaticRangeFinishedBodyPolicy.pauseSweepDisposition)
    FixProgressKeepsFinished, \* review of #474: a progress callback under a pause halt
                        \* leaves a finished task tracked too
                        \* (StaticRangeFinishedBodyPolicy.haltedProgressDisposition)
    FixVerdictBeforeRename, \* PROPOSED (not in the code): a failing truncation verdict is
                        \* durable before its body leaves the working path (F4)
    ForegroundReattach, \* allow reattach + reconcile while the process stays alive
    BoundEnvironment,   \* TRUE: at most EnvBudget user/crash/foreground steps (liveness runs)
    EnvBudget

ASSUME /\ ForwardRows \subseteq Rows
       /\ MaxAttempt \in Nat \ {0}
       /\ Outcomes \subseteq FinalizeOutcomes /\ Outcomes # {}
       /\ EnvBudget \in Nat

Attempts == 1..MaxAttempt

\* SYMMETRY for safety configs whose rows are model values on one route (all
\* in ForwardRows or none): nothing then tells two rows apart.  Not sound for
\* a mixed-route config, and never used in a Liveness config.
RowSymmetry == Permutations(Rows)

VARIABLES
    \* ---- durable: the index row (survives Crash) ----
    life,        \* [Rows -> RowStates]            DownloadLifecycle
    cause,       \* [Rows -> PauseCauses]          history.pauseCause
    owner,       \* [Rows -> 0..MaxAttempt]        the row's current attempt ID
    strikes,     \* [Rows -> 0..3]                 history.truncation.strikes
    counted,     \* [Rows -> SUBSET Attempts]      history.truncation.countedOutcomeIDs
    condemned,   \* [Rows -> BOOLEAN]              history.bodyCondemned
    intent,      \* [Rows -> PublishIntents]       pending validated-publication intent
    deleting,    \* [Rows -> BOOLEAN]              deletion pending
    \* ---- durable: files (survive Crash) ----
    working,     \* [Rows -> WorkingStates]        the owner's attempt working file
    published,   \* [Rows -> BOOLEAN]              the published, playable body
    stash,       \* [Rows -> SUBSET Attempts]      finished bodies not yet appended or
                 \*                                published, by task: a tmp/ stash, or
                 \*                                (DurableCapture, forward-only) the
                 \*                                attempt's capture path
    \* ---- the transfer daemon (survives Crash) ----
    task,        \* [Rows -> [Attempts -> TaskStates]]
    \* ---- in memory (lost at Crash) ----
    up,          \* BOOLEAN                        the app process is alive
    tracked,     \* [Rows -> SUBSET Attempts]      tasks in the session's inflight maps
    ioq,         \* [Rows -> SUBSET Attempts]      queued append/publication hops (= claims)
    halt,        \* [Rows -> HaltKinds]
    rebuild,     \* [Rows -> 0..MaxAttempt]        a delayed retry/rebuild, by scheduling attempt
    fin,         \* [Rows -> 0..MaxAttempt]        finalizer work in flight, by attempt
    recon,       \* [Rows -> {"idle","needReattach","needReconcile"}]
    liveSnap,    \* [Rows -> BOOLEAN]              reattach's live-task snapshot for reconcile
    superseded,  \* [Rows -> SUBSET Attempts]      tasks whose callbacks the session ignores
    \* ---- ghosts (observe only; never read by an action's guard) ----
    bodyDone,    \* [Rows -> 0..MaxAttempt]        attempt whose finished body the app holds
    staleEffect, \* BOOLEAN                        a stale-attempt callback changed something
    budget       \* 0..EnvBudget

\* The part of the row the reducer owns.
redVars  == <<life, cause, strikes, counted, condemned>>
rowVars  == <<life, cause, owner, strikes, counted, condemned, intent, deleting>>
fileVars == <<working, published, stash>>
memVars  == <<tracked, ioq, halt, rebuild, fin, recon, liveSnap, superseded>>
vars     == <<rowVars, fileVars, task, up, memVars, bodyDone, staleEffect, budget>>

Route(r) == IF r \in ForwardRows THEN "forwardOnly" ELSE "staticRange"
Forward(r) == r \in ForwardRows
Exists(r) == life[r] # "absent"
UserPaused(r) == life[r] = "paused" /\ cause[r] = "user"

\* DownloadStore.attemptAdmitsWork / BackgroundDownloadSession.stillOwnsAttempt
Owns(r, a) == Exists(r) /\ owner[r] = a /\ ~deleting[r]
\* What a session callback accepts: its exact attempt.  B12 is about the hop
\* after it: the manager's side of an error handoff (RebuildFires) was matched
\* by row only.
Accepts(r, a) == Owns(r, a)
Stale(r, a) == owner[r] # a

-----------------------------------------------------------------------------
(* The reducer's view of a row                                             *)

\* The row is stored as five fields and rebuilt for every Reduce.  Both
\* directions are DownloadsSessionRowMap's (SessionRow, SessionStored), and
\* SessionRowMapCheck-Current-RowMap.cfg checks that they commute with the
\* reducer for the events this model sends.  Projection-SessionCore.cfg
\* checks the weaker statement that the dropped fields (lastFailure,
\* unverifiedReason, admissionIntent, storagePark) never influence the kept
\* ones.  There is one source, "src".
Row(r) ==
    SessionRow([life |-> life[r], cause |-> cause[r], condemned |-> condemned[r],
                strikes |-> strikes[r], counted |-> counted[r]])

\* Store a reducer state as row r.
ApplyRow(r, s) ==
    LET x == SessionStored(s)
    IN /\ life' = Upd(life, r, x.life)
       /\ cause' = Upd(cause, r, x.cause)
       /\ strikes' = Upd(strikes, r, x.strikes)
       /\ counted' = Upd(counted, r, x.counted)
       /\ condemned' = Upd(condemned, r, x.condemned)

\* Send an event that does not read facts.
Send(r, event) == Reduce(Row(r), event, NoFacts)

\* Send it and store the result; a rejected event leaves the row alone.
Submit(r, event) ==
    LET t == Send(r, event)
    IN IF IsApplied(t) THEN ApplyRow(r, t.state) ELSE UNCHANGED redVars

\* User, crash and foreground steps are the environment.  Liveness runs bound them.
Spend == IF BoundEnvironment
            THEN budget > 0 /\ budget' = budget - 1
            ELSE UNCHANGED budget

TypeOK ==
    /\ life \in [Rows -> RowStates]
    /\ cause \in [Rows -> PauseCauses]
    /\ owner \in [Rows -> 0..MaxAttempt]
    /\ strikes \in [Rows -> 0..(MaxTruncationStrikes + 1)]
    /\ counted \in [Rows -> SUBSET Attempts]
    /\ condemned \in [Rows -> BOOLEAN]
    /\ intent \in [Rows -> PublishIntents]
    /\ deleting \in [Rows -> BOOLEAN]
    /\ working \in [Rows -> WorkingStates]
    /\ published \in [Rows -> BOOLEAN]
    /\ stash \in [Rows -> SUBSET Attempts]
    /\ task \in [Rows -> [Attempts -> TaskStates]]
    /\ up \in BOOLEAN
    /\ tracked \in [Rows -> SUBSET Attempts]
    /\ ioq \in [Rows -> SUBSET Attempts]
    /\ halt \in [Rows -> HaltKinds]
    /\ rebuild \in [Rows -> 0..MaxAttempt]
    /\ fin \in [Rows -> 0..MaxAttempt]
    /\ recon \in [Rows -> {"idle", "needReattach", "needReconcile"}]
    /\ liveSnap \in [Rows -> BOOLEAN]
    /\ superseded \in [Rows -> SUBSET Attempts]
    /\ bodyDone \in [Rows -> 0..MaxAttempt]
    /\ staleEffect \in BOOLEAN
    /\ budget \in 0..EnvBudget

Init ==
    /\ life = [r \in Rows |-> "admitted"]
    /\ cause = [r \in Rows |-> "none"]
    /\ owner = [r \in Rows |-> 1]
    /\ strikes = [r \in Rows |-> 0]
    /\ counted = [r \in Rows |-> {}]
    /\ condemned = [r \in Rows |-> FALSE]
    /\ intent = [r \in Rows |-> "none"]
    /\ deleting = [r \in Rows |-> FALSE]
    /\ working = [r \in Rows |-> "none"]
    /\ published = [r \in Rows |-> FALSE]
    /\ stash = [r \in Rows |-> {}]
    /\ task = [r \in Rows |-> [a \in Attempts |-> "none"]]
    /\ up = TRUE
    /\ tracked = [r \in Rows |-> {}]
    /\ ioq = [r \in Rows |-> {}]
    /\ halt = [r \in Rows |-> "none"]
    /\ rebuild = [r \in Rows |-> 0]
    /\ fin = [r \in Rows |-> 0]
    /\ recon = [r \in Rows |-> "idle"]
    /\ liveSnap = [r \in Rows |-> FALSE]
    /\ superseded = [r \in Rows |-> {}]
    /\ bodyDone = [r \in Rows |-> 0]
    /\ staleEffect = FALSE
    /\ budget = IF BoundEnvironment THEN EnvBudget ELSE 0

-----------------------------------------------------------------------------
(* Session: starting and progressing a transfer                            *)

\* reducer: transferStarted.  A static row whose checkpoint is already complete
\* finalizes instead of fetching (finalizeCompletedStaticRangeFile).
TransferStarted(r) ==
    /\ up /\ life[r] = "admitted" /\ ~deleting[r] /\ halt[r] = "none"
    /\ task[r][owner[r]] = "none" /\ owner[r] \notin ioq[r] /\ fin[r] = 0
    /\ IF ~Forward(r) /\ working[r] = "complete"
          THEN /\ fin' = Upd(fin, r, owner[r])
               /\ UNCHANGED <<task, tracked, redVars>>
          ELSE /\ task' = [task EXCEPT ![r][owner[r]] = "running"]
               /\ tracked' = Upd(tracked, r, tracked[r] \cup {owner[r]})
               /\ Submit(r, Ev("transferStarted"))
               /\ UNCHANGED fin
    /\ UNCHANGED <<owner, intent, deleting,
                   fileVars, up, superseded, ioq, halt, rebuild, recon, liveSnap,
                   bodyDone, staleEffect, budget>>

\* reducer: transferProgress.  Only steps that change the row are modelled.
\* B09: progress must not promote a paused row.
TransferProgress(r, a) ==
    /\ up /\ a \in tracked[r] /\ task[r][a] = "running" /\ Accepts(r, a)
    /\ \/ /\ life[r] = "admitted"
          /\ Submit(r, Ev("transferProgress"))
       \/ \* Before B09 progress promoted a paused row.
          /\ ~FixB09 /\ life[r] = "paused"
          /\ life' = Upd(life, r, "transferring")
          /\ cause' = Upd(cause, r, "none")
          /\ UNCHANGED <<strikes, counted, condemned>>
    /\ staleEffect' = (staleEffect \/ Stale(r, a))
    /\ UNCHANGED <<owner, intent, deleting,
                   fileVars, task, up, superseded, memVars, bodyDone, budget>>

-----------------------------------------------------------------------------
(* Daemon: runs whether or not the app is alive                            *)

DaemonFinishes(r, a) ==
    /\ task[r][a] = "running"
    /\ task' = [task EXCEPT ![r][a] = "finished"]
    /\ UNCHANGED <<rowVars, fileVars, up, superseded, memVars, bodyDone, staleEffect, budget>>

\* A transport error or a cancellation.
DaemonFails(r, a) ==
    /\ task[r][a] = "running"
    /\ task' = [task EXCEPT ![r][a] = "failed"]
    /\ UNCHANGED <<rowVars, fileVars, up, superseded, memVars, bodyDone, staleEffect, budget>>

-----------------------------------------------------------------------------
(* Session: completion callbacks                                           *)

\* urlSession(_:downloadTask:didFinishDownloadingTo:).  The body leaves the OS
\* temp for a tmp/ stash, the stash is claimed, and the append (static) or
\* publication to the working path (forward-only) is queued on the IO queue.
\* An untracked task is a redelivery after relaunch and is adopted only for a
\* non-terminal row.  A cancel halt discards a static body; a pause halt keeps it.
\* A superseded task's finish is ignored and its body is gone with the OS temp.
\* DurableCapture: a forward-only body goes to the attempt's capture path
\* instead, and the row records it (reducer: bodyCaptured), so it is
\* `finalizing` before the queued publication runs.  (A response that fails
\* the HTTP checks is not captured; the model has no such response.)
DidFinishDownloading(r, a) ==
    /\ up /\ task[r][a] = "finished"
    /\ task' = [task EXCEPT ![r][a] = "none"]
    /\ tracked' = Upd(tracked, r, tracked[r] \ {a})
    /\ superseded' = Upd(superseded, r, superseded[r] \ {a})
    /\ LET keep == /\ a \notin superseded[r]
                   /\ Accepts(r, a)
                   /\ (a \notin tracked[r] => life[r] \notin Terminal)
                   /\ ~(~Forward(r) /\ halt[r] = "cancel")
           mine == owner[r] = a
           captured == Send(r, Ev("bodyCaptured"))
           capture == /\ DurableCapture /\ keep /\ mine /\ Forward(r)
                      /\ IsApplied(captured)
       IN /\ stash' = IF keep THEN Upd(stash, r, stash[r] \cup {a}) ELSE stash
          /\ ioq' = IF keep THEN Upd(ioq, r, ioq[r] \cup {a}) ELSE ioq
          \* reducer event bodyCaptured, persisted with the capture.
          /\ IF capture THEN ApplyRow(r, captured.state) ELSE UNCHANGED redVars
          \* A forward-only body is finished here.  Before F3 the code dropped
          \* it when the row was user-paused.  This ghost leaves that case out,
          \* so that FinishedBodyNotLost stays the crash property (F1);
          \* FinishedBodySurvivesPause is the pause property.
          /\ bodyDone' = IF /\ keep /\ mine /\ Forward(r)
                            /\ (capture \/ FixPauseKeepsBody \/ ~UserPaused(r))
                            THEN Upd(bodyDone, r, a) ELSE bodyDone
    /\ UNCHANGED <<owner, intent, deleting,
                   working, published, up, halt, rebuild, fin, recon, liveSnap,
                   staleEffect, budget>>

\* urlSession(_:task:didCompleteWithError:) with an error.  A halted row
\* expects its cancellation.  Otherwise the session hands the error to the
\* manager on the main actor: a static transfer schedules a delayed retry
\* (onRangeRequestNeeded) or fails; a forward-only transfer's failure is
\* decided there too (onRangeAuthHTTPFailure and its like).  `rebuild` is that
\* queued handoff, by the attempt that raised it; RebuildFires is its arrival.
\* reducer: transferFailed.
DidCompleteWithError(r, a) ==
    /\ up /\ task[r][a] = "failed"
    /\ task' = [task EXCEPT ![r][a] = "none"]
    /\ tracked' = Upd(tracked, r, tracked[r] \ {a})
    /\ IF /\ a \in tracked[r] /\ Accepts(r, a) /\ halt[r] = "none"
          /\ life[r] \in {"admitted", "transferring"}
          THEN \/ /\ rebuild' = Upd(rebuild, r, a)
                  /\ UNCHANGED redVars
               \/ /\ ~Forward(r)
                  /\ Submit(r, EvReason("transferFailed", "network"))
                  /\ UNCHANGED rebuild
          ELSE UNCHANGED <<redVars, rebuild>>
    /\ UNCHANGED <<owner, intent, deleting,
                   fileVars, up, superseded, ioq, halt, fin, recon, liveSnap, bodyDone,
                   staleEffect, budget>>

\* The queued hop on rangeIOQueue: applyFinishedRangeBody (static) or
\* finishOpaqueBody (forward-only).  It rechecks that its attempt is current,
\* consumes the stash, and releases the claim when it ends.
RangeIO(r, a) ==
    /\ up /\ a \in ioq[r]
    /\ ioq' = Upd(ioq, r, ioq[r] \ {a})
    /\ LET current == /\ Accepts(r, a) /\ halt[r] # "cancel"
                      \* finishOpaqueBody: ForwardOnlyFinishedBodyPolicy.publication.
                      \* A pause halt publishes; before F3 it required no halt at all
                      \* (checkpointIsCurrent(currency, halt: nil)) and dropped a paused
                      \* row's finished body here.  The static lane writes it
                      \* (writeThenPause).
                      /\ (Forward(r) /\ ~DurableCapture /\ ~FixPauseKeepsBody
                            => halt[r] = "none")
           present == a \in stash[r]
           fresh   == owner[r] = a
       IN
       /\ staleEffect' = (staleEffect \/ (current /\ ~fresh))
       \* F3: a published forward-only body finalizes, so finishOpaqueBody drops the
       \* pause halt that raced it (the finalizer stands down for any halt).
       /\ halt' = IF /\ current /\ present /\ Forward(r) /\ halt[r] = "pause"
                     /\ (DurableCapture \/ FixPauseKeepsBody)
                     THEN Upd(halt, r, "none") ELSE halt
       /\ IF ~current THEN
              UNCHANGED <<redVars, working, stash, task, tracked, fin, bodyDone>>
          ELSE IF ~present THEN
              \* The stash is gone: the move fails.  A forward-only row fails;
              \* a static row re-fetches the segment from its checkpoint.
              /\ IF Forward(r)
                    THEN Submit(r, EvReason("transferFailed", "internalError"))
                    ELSE UNCHANGED redVars
              /\ UNCHANGED <<working, stash, task, tracked, fin, bodyDone>>
          ELSE IF Forward(r) THEN
              /\ stash' = Upd(stash, r, stash[r] \ {a})
              /\ working' = Upd(working, r, "complete")
              /\ fin' = Upd(fin, r, owner[r])
              /\ UNCHANGED <<redVars, task, tracked, bodyDone>>
          ELSE
              /\ stash' = Upd(stash, r, stash[r] \ {a})
              \* A finalizing row's file is whole, or (F4's residue) gone: either
              \* way a late segment body is not appended (the append needs the
              \* partial it was planned for).
              /\ CASE working[r] = "none" /\ life[r] # "finalizing" ->
                        /\ working' = Upd(working, r, "partial")
                        \* continueRangeAfterBody: fetch the next segment unless halted.
                        /\ IF halt[r] = "none" /\ life[r] \in {"admitted", "transferring"}
                              THEN /\ task' = [task EXCEPT ![r][owner[r]] = "running"]
                                   /\ tracked' = Upd(tracked, r, tracked[r] \cup {owner[r]})
                              ELSE UNCHANGED <<task, tracked>>
                        /\ UNCHANGED <<fin, bodyDone>>
                   [] working[r] = "partial" ->
                        /\ working' = Upd(working, r, "complete")
                        /\ fin' = Upd(fin, r, owner[r])
                        /\ bodyDone' = IF fresh THEN Upd(bodyDone, r, a) ELSE bodyDone
                        /\ UNCHANGED <<task, tracked>>
                   [] OTHER -> UNCHANGED <<working, task, tracked, fin, bodyDone>>
              /\ UNCHANGED redVars
    /\ UNCHANGED <<owner, intent, deleting,
                   published, up, superseded, rebuild, recon, liveSnap, budget>>

\* The manager's side of an error handoff runs, a main-actor hop after the
\* callback that queued it.
\*  - Static: a delayed retry / range-request rebuild.  B02: its currency
\*    (attempt, halt, generation) must still be current, so a Pause in between
\*    stops it.
\*  - Forward-only: the failure is written.  B12: only while the attempt that
\*    raised it still owns the row.  Before B12 the manager looked the row up
\*    by key, so a handoff from a replaced attempt failed its replacement.
RebuildFires(r) ==
    /\ up /\ rebuild[r] # 0
    /\ rebuild' = Upd(rebuild, r, 0)
    /\ LET a == rebuild[r]
           current == /\ Owns(r, a) /\ halt[r] = "none"
                      /\ life[r] \in {"admitted", "transferring"}
           start == IF FixB02
                       THEN current /\ task[r][a] = "none"
                       ELSE /\ Exists(r) /\ ~deleting[r] /\ owner[r] = a
                            /\ task[r][a] = "none"
                            /\ life[r] \in {"admitted", "transferring", "paused"}
           fails == /\ IF FixB12 THEN Owns(r, a) ELSE Exists(r) /\ ~deleting[r]
                    /\ halt[r] = "none" /\ life[r] \in {"admitted", "transferring"}
       IN IF Forward(r) THEN
              /\ IF fails THEN Submit(r, EvReason("transferFailed", "network"))
                           ELSE UNCHANGED redVars
              /\ staleEffect' = (staleEffect \/ (fails /\ Stale(r, a)))
              /\ UNCHANGED <<task, tracked>>
          ELSE
              /\ UNCHANGED staleEffect
              /\ IF start
                    THEN /\ task' = [task EXCEPT ![r][a] = "running"]
                         /\ tracked' = Upd(tracked, r, tracked[r] \cup {a})
                         /\ IF life[r] = "paused"
                               \* Only before B02: the rebuild restarted a paused row.
                               THEN /\ life' = Upd(life, r, "transferring")
                                    /\ cause' = Upd(cause, r, "none")
                                    /\ UNCHANGED <<strikes, counted, condemned>>
                               ELSE Submit(r, Ev("transferRebuilding"))
                    ELSE UNCHANGED <<task, tracked, redVars>>
    /\ UNCHANGED <<owner, intent, deleting,
                   fileVars, up, superseded, ioq, halt, fin, recon, liveSnap,
                   bodyDone, budget>>

\* reducer: stallDetected.  A transferring row with no task and no queued work.
\* In the code only the forward-only lane has this watchdog
\* (DownloadManager.detectForwardOnlyStreamStalls).  On the static lane it
\* stands in for the manager's stale-row recovery, which this model does not
\* have: without it a static row that a stale reconcile left `transferring`
\* would have no next step here, because the model has no pending-start
\* state (TransferStarted needs `admitted`).  Static liveness is
\* DownloadsRangeTrain's subject; Liveness-Static only shows that nothing
\* else in this model traps a static row.
StallDetected(r) ==
    /\ up /\ life[r] = "transferring" /\ ~deleting[r]
    /\ tracked[r] = {} /\ ioq[r] = {} /\ fin[r] = 0 /\ rebuild[r] = 0
    /\ recon[r] = "idle" /\ task[r][owner[r]] = "none"
    /\ Submit(r, Ev("stallDetected"))
    /\ UNCHANGED <<owner, intent, deleting,
                   fileVars, task, up, superseded, memVars, bodyDone, staleEffect, budget>>

-----------------------------------------------------------------------------
(* Finalizer: capture -> validate -> publish                               *)

\* reducer: bodyAtWorking (publishTransferFinalizing).  The complete body is
\* at the attempt working path; `finalizing` is persisted before validation.
BodyAtWorking(r) ==
    /\ up /\ fin[r] # 0 /\ life[r] # "finalizing"
    /\ LET t == Send(r, Ev("bodyAtWorking"))
       IN IF /\ fin[r] = owner[r] /\ Exists(r) /\ ~deleting[r]
             /\ working[r] = "complete"
             \* Rejected for a condemned body and for a playable row.
             /\ IsApplied(t)
             THEN /\ ApplyRow(r, t.state)
                  /\ UNCHANGED fin
             ELSE /\ fin' = Upd(fin, r, 0)
                  /\ UNCHANGED redVars
    /\ UNCHANGED <<owner, intent, deleting,
                   fileVars, task, up, superseded, tracked, ioq, halt, rebuild, recon, liveSnap,
                   bodyDone, staleEffect, budget>>

\* reducer: finalizeOutcome.  The outcome ID is the attempt (one body per
\* attempt).  `complete` and repeated truncation record a publish intent in
\* the same revision (effect: publish); a first truncation condemns the body
\* and deletes it (effect: deleteWorkingBody).
FinalizeOutcome(r, o) ==
    /\ up /\ fin[r] # 0 /\ fin[r] = owner[r] /\ life[r] = "finalizing"
    /\ ~deleting[r] /\ working[r] = "complete" /\ intent[r] = "none"
    /\ o \in Outcomes
    /\ LET t == Send(r, EvFinalize(owner[r], o, "src"))
       IN \* A replayed outcome ID is FinalizeOutcomeReplayed.
          /\ IsApplied(t)
          /\ ApplyRow(r, t.state)
          /\ intent' = IF Has(t, "publishComplete") THEN Upd(intent, r, "complete")
                        ELSE IF Has(t, "publishUnverified")
                            THEN Upd(intent, r, "unverified") ELSE intent
          /\ IF Has(t, "deleteWorkingBody")
                THEN /\ working' = Upd(working, r, "none")
                     /\ fin' = Upd(fin, r, 0)
                     /\ bodyDone' = Upd(bodyDone, r, 0)
                ELSE UNCHANGED <<working, fin, bodyDone>>
    /\ UNCHANGED <<owner, deleting, published, stash, task, up, superseded,
                   tracked, ioq, halt, rebuild, recon, liveSnap, staleEffect, budget>>

\* The finalizer delivers the truncation verdict it already delivered (same
\* outcome ID) while the row still waits to publish.  R2-5: rejected(.replayed)
\* by the reducer, and DownloadAttemptHistory.recordingTruncation ignores a
\* counted ID by itself.  Before R2-5 neither existed: the session kept one
\* counter per row and added to it on every truncated finalizer run
\* (truncationFailureCounts), which is the FixReplay = FALSE branch.
FinalizeOutcomeReplayed(r) ==
    /\ up /\ fin[r] # 0 /\ fin[r] = owner[r] /\ life[r] = "finalizing"
    /\ ~deleting[r] /\ intent[r] = "unverified" /\ owner[r] \in counted[r]
    /\ IF FixReplay
          THEN /\ Send(r, EvFinalize(owner[r], "truncated", "src")) = Replayed
               /\ UNCHANGED strikes
          ELSE /\ strikes[r] <= MaxTruncationStrikes
               /\ strikes' = Upd(strikes, r, strikes[r] + 1)
    /\ UNCHANGED <<life, cause, owner, counted, condemned, intent, deleting,
                   fileVars, task, up, superseded, memVars, bodyDone, staleEffect, budget>>

\* The validated-promotion recipe.  It is driven by the durable intent, so it
\* replays after a relaunch without the in-memory finalizer.
PublishBody(r) ==
    /\ up /\ intent[r] # "none" /\ life[r] = "finalizing" /\ ~deleting[r]
    /\ working[r] = "complete" /\ ~published[r]
    /\ published' = Upd(published, r, TRUE)
    /\ working' = Upd(working, r, "none")
    /\ UNCHANGED <<rowVars, stash, task, up, superseded, memVars, bodyDone, staleEffect, budget>>

\* reducer: promotionCommitted
PromotionCommitted(r) ==
    /\ up /\ intent[r] # "none" /\ life[r] = "finalizing" /\ ~deleting[r]
    /\ published[r]
    /\ Submit(r, EvPromotion("promotionCommitted", intent[r]))
    /\ intent' = Upd(intent, r, "none")
    /\ fin' = Upd(fin, r, 0)
    /\ UNCHANGED <<owner, deleting,
                   fileVars, task, up, superseded, tracked, ioq, halt, rebuild, recon, liveSnap,
                   bodyDone, staleEffect, budget>>

\* reducer: promotionAbandoned.  The intent's body is gone.
PromotionAbandoned(r) ==
    /\ up /\ intent[r] # "none" /\ life[r] = "finalizing" /\ ~deleting[r]
    /\ working[r] # "complete" /\ ~published[r]
    /\ Submit(r, Ev("promotionAbandoned"))
    /\ intent' = Upd(intent, r, "none")
    /\ fin' = Upd(fin, r, 0)
    /\ UNCHANGED <<owner, deleting,
                   fileVars, task, up, superseded, tracked, ioq, halt, rebuild, recon, liveSnap,
                   bodyDone, staleEffect, budget>>

-----------------------------------------------------------------------------
(* User                                                                    *)

\* reducer: pause(.user), plus BackgroundDownloadSession.pause: the halt is
\* installed at once; cancellation of the tasks lands later (DaemonFails), or
\* the task finishes first.  Opaque tracking is dropped synchronously; range
\* tracking stays until its callback.  Pausing a finalizing row changes nothing.
UserPause(r) ==
    /\ up /\ life[r] \in {"admitted", "transferring"} /\ ~deleting[r]
    /\ Spend
    /\ Submit(r, EvPause("user"))
    /\ halt' = Upd(halt, r, "pause")
    /\ tracked' = IF Forward(r) THEN Upd(tracked, r, {}) ELSE tracked
    \* B02 invalidates a static row's queued rebuild.  A forward-only row's
    \* queued error handoff is not a rebuild and stays queued.
    /\ rebuild' = IF FixB02 /\ ~Forward(r) THEN Upd(rebuild, r, 0) ELSE rebuild
    \* Before F3 the code dropped a finished forward-only body that had not
    \* reached `finalizing` when the user paused (see DidFinishDownloading).
    /\ bodyDone' = IF Forward(r) /\ ~FixPauseKeepsBody
                      THEN Upd(bodyDone, r, 0) ELSE bodyDone
    /\ UNCHANGED <<owner, intent, deleting,
                   fileVars, task, up, superseded, ioq, fin, recon, liveSnap, staleEffect>>

\* The pause's getAllTasks completion on the static lane (pauseRangeTask):
\* every listed task of the row leaves tracking, is marked superseded and is
\* cancelled.  A task whose finish callback ran first is not tracked any
\* more, and its body is written behind the pause (writeThenPause).  A task
\* that finished in the daemon while its callback is still queued behind
\* this completion is still listed.  Before F3 it was superseded too, and its
\* finish then ignored.  Now a finished task stays tracked
\* (StaticRangeFinishedBodyPolicy.pauseSweepDisposition).  A cancelled task's
\* error callback is superseded and inert.
PauseSwept(r) ==
    {a \in tracked[r] : \/ task[r][a] = "running"
                         \/ (~FixPauseKeepsBody /\ task[r][a] = "finished")}
PauseSweep(r) ==
    /\ up /\ ~Forward(r) /\ halt[r] = "pause" /\ PauseSwept(r) # {}
    /\ tracked' = Upd(tracked, r, tracked[r] \ PauseSwept(r))
    /\ superseded' = Upd(superseded, r, superseded[r] \cup
                         {a \in PauseSwept(r) : task[r][a] = "finished"})
    /\ task' = Upd(task, r, [a \in Attempts |->
                   IF a \in PauseSwept(r) /\ task[r][a] = "running" THEN "none"
                   ELSE task[r][a]])
    /\ UNCHANGED <<rowVars, fileVars, up, ioq, halt, rebuild, fin, recon, liveSnap,
                   bodyDone, staleEffect, budget>>

\* urlSession(_:downloadTask:didWriteData:...) for a static task of a halted
\* attempt: the handler drops the task's tracking, marks it superseded and
\* cancels it.  For a running task that is PauseSweep's step.  The last
\* progress of a task that has already finished can be delivered here too:
\* after the pause installed its halt and before the finish callback, and
\* before or after PauseSweep.  Superseding it made the finish callback
\* ignore the body, which undid the F3 fix in the sweep.  Now the handler
\* asks the sweep's question (haltedProgressDisposition) and leaves a
\* finished task tracked.  With the fix this step changes nothing, so it
\* exists only with the fix off.
HaltedProgress(r, a) ==
    /\ ~FixProgressKeepsFinished
    /\ up /\ ~Forward(r) /\ halt[r] = "pause"
    /\ a \in tracked[r] /\ task[r][a] = "finished"
    /\ tracked' = Upd(tracked, r, tracked[r] \ {a})
    /\ superseded' = Upd(superseded, r, superseded[r] \cup {a})
    /\ UNCHANGED <<rowVars, fileVars, task, up, ioq, halt, rebuild, fin, recon, liveSnap,
                   bodyDone, staleEffect, budget>>

\* A fresh attempt: new attempt ID, new (empty) working path.
\* reducer: retry(.freshAttempt).  The replacement attempt does not inherit
\* `bodyCondemned` (DownloadAttemptHistory.inherited).
FreshAttempt(r) ==
    /\ owner[r] < MaxAttempt
    /\ owner' = Upd(owner, r, owner[r] + 1)
    /\ LET t == Send(r, EvRetry("freshAttempt"))
       IN /\ IsApplied(t)
          /\ ApplyRow(r, [t.state EXCEPT !.bodyCondemned = FALSE])
    /\ working' = Upd(working, r, "none")
    /\ fin' = Upd(fin, r, 0)
    /\ bodyDone' = Upd(bodyDone, r, 0)

\* reducer: retry(.staticCheckpoint) keeps the attempt and its checkpoint;
\* retry(.freshAttempt) for a forward-only row.  Resume is a new generation,
\* so queued rebuilds of the old one are dead.
UserResume(r) ==
    /\ up /\ life[r] = "paused" /\ ~deleting[r]
    /\ Spend
    /\ halt' = Upd(halt, r, "none")
    /\ rebuild' = IF FixB02 /\ ~Forward(r) THEN Upd(rebuild, r, 0) ELSE rebuild
    /\ IF Forward(r)
          THEN FreshAttempt(r)
          ELSE /\ Submit(r, EvRetry("staticCheckpoint"))
               /\ UNCHANGED <<owner, working, fin, bodyDone>>
    /\ UNCHANGED <<intent, deleting, published, stash, task, up, superseded,
                   tracked, ioq, recon, liveSnap, staleEffect>>

\* reducer: retry(.freshAttempt) from failed.
UserRetry(r) ==
    /\ up /\ life[r] = "failed" /\ ~deleting[r]
    /\ Spend
    /\ FreshAttempt(r)
    /\ halt' = Upd(halt, r, "none")
    /\ rebuild' = Upd(rebuild, r, 0)
    /\ UNCHANGED <<intent, deleting, published, stash, task, up, superseded,
                   tracked, ioq, recon, liveSnap, staleEffect>>

\* Delete: a durable deletion-pending flag and a cancel halt.
UserDelete(r) ==
    /\ up /\ Exists(r) /\ ~deleting[r]
    /\ Spend
    /\ deleting' = Upd(deleting, r, TRUE)
    /\ halt' = Upd(halt, r, "cancel")
    /\ rebuild' = Upd(rebuild, r, 0)
    /\ UNCHANGED <<life, cause, owner, strikes, counted, condemned, intent,
                   fileVars, task, up, superseded, tracked, ioq, fin, recon, liveSnap,
                   bodyDone, staleEffect>>

\* The cleanup runner executes the deletion.  It replays after a relaunch.
CleanupRuns(r) ==
    /\ up /\ deleting[r]
    /\ life' = Upd(life, r, "absent")
    /\ cause' = Upd(cause, r, "none")
    /\ deleting' = Upd(deleting, r, FALSE)
    /\ intent' = Upd(intent, r, "none")
    /\ condemned' = Upd(condemned, r, FALSE)
    /\ working' = Upd(working, r, "none")
    /\ published' = Upd(published, r, FALSE)
    /\ stash' = Upd(stash, r, {})
    /\ task' = Upd(task, r, [a \in Attempts |-> "none"])
    /\ tracked' = Upd(tracked, r, {})
    /\ fin' = Upd(fin, r, 0)
    /\ bodyDone' = Upd(bodyDone, r, 0)
    /\ UNCHANGED <<owner, strikes, counted, up, superseded, ioq, halt, rebuild, recon, liveSnap,
                   staleEffect, budget>>

-----------------------------------------------------------------------------
(* Crash and recovery                                                      *)

CrashEffects ==
    /\ up' = FALSE
    /\ tracked' = [r \in Rows |-> {}]
    /\ ioq' = [r \in Rows |-> {}]
    /\ halt' = [r \in Rows |-> "none"]
    /\ rebuild' = [r \in Rows |-> 0]
    /\ fin' = [r \in Rows |-> 0]
    /\ recon' = [r \in Rows |-> "idle"]
    /\ liveSnap' = [r \in Rows |-> FALSE]
    /\ superseded' = [r \in Rows |-> {}]

Crash ==
    /\ up
    /\ Spend
    /\ CrashEffects
    /\ UNCHANGED <<rowVars, fileVars, task, bodyDone, staleEffect>>

\* F4.  A failing truncation verdict (FinalizeOutcome's branch with
\* deleteWorkingBody) is three steps in the code: the verdict is applied to
\* the row in memory and gets a persistence ticket; the condemned body is
\* renamed off the working path at once (condemnBody); the finalizer then
\* waits for the ticket.  FinalizeOutcome is all three.  This action is the
\* first two and a crash: the body is gone from the working path and the
\* durable row is the old `finalizing` one, with no strike and no
\* `bodyCondemned`.  Reconcile then fails that row (internalError).
\* PROPOSED: the verdict is durable before the rename, so the window is gone.
FinalizeTruncatedCrash(r) ==
    /\ ~FixVerdictBeforeRename
    /\ up /\ fin[r] # 0 /\ fin[r] = owner[r] /\ life[r] = "finalizing"
    /\ ~deleting[r] /\ working[r] = "complete" /\ intent[r] = "none"
    /\ "truncated" \in Outcomes
    /\ Has(Send(r, EvFinalize(owner[r], "truncated", "src")), "deleteWorkingBody")
    /\ Spend
    /\ working' = Upd(working, r, "none")
    \* The verdict condemned the body: it is not a finished body any more.
    /\ bodyDone' = Upd(bodyDone, r, 0)
    /\ CrashEffects
    /\ UNCHANGED <<rowVars, published, stash, task, staleEffect>>

Relaunch ==
    /\ ~up
    /\ up' = TRUE
    /\ recon' = [r \in Rows |-> "needReattach"]
    /\ UNCHANGED <<rowVars, fileVars, task, tracked, ioq, halt, rebuild, fin, liveSnap,
                   superseded, bodyDone, staleEffect, budget>>

\* Returning to the foreground runs the same reattach + reconcile in-process
\* (recoverStaticRangeTransfersAfterForeground).  This step is the getAllTasks
\* request; Reattach is its completion.
ForegroundReattachBegins ==
    /\ ForegroundReattach /\ up
    /\ \A r \in Rows : recon[r] = "idle"
    /\ Spend
    /\ recon' = [r \in Rows |-> "needReattach"]
    \* getAllTasks completions run in request order.  A Pause that came first has
    \* its own completion (PauseSweep) ahead of this one, and that drops the
    \* row's range tracking before Reattach takes its live snapshot.
    /\ tracked' = [r \in Rows |-> IF halt[r] = "pause" /\ ~Forward(r)
                                     THEN tracked[r] \ PauseSwept(r) ELSE
                                  IF halt[r] = "pause" THEN {} ELSE tracked[r]]
    /\ superseded' = [r \in Rows |-> IF halt[r] = "pause" /\ ~Forward(r)
                                        THEN superseded[r] \cup
                                             {a \in PauseSwept(r) : task[r][a] = "finished"}
                                        ELSE superseded[r]]
    /\ task' = [r \in Rows |-> [a \in Attempts |->
                   IF /\ halt[r] = "pause" /\ ~Forward(r)
                      /\ a \in PauseSwept(r) /\ task[r][a] = "running"
                      THEN "none" ELSE task[r][a]]]
    /\ UNCHANGED <<rowVars, fileVars, up, ioq, halt, rebuild, fin, liveSnap,
                   bodyDone, staleEffect>>

\* reattachToResumedTasks, one row's share of the getAllTasks completion: it
\* runs on the delegate queue, so it is atomic against delegate callbacks.
\*  - A running, untracked task is adopted (reducer: taskAdopted) when it
\*    carries the row's exact attempt and the row may be active; B02: a paused
\*    row's task is cancelled instead; a halted attempt's task is left alone.
\*    Any other untracked task is cancelled.  The task is tracked either way,
\*    but a finalizing row rejects taskAdopted and stays finalizing.
\*  - sweepOrphanedRangeBodyStashes: a stash whose task is no longer live is
\*    deleted.  B03: unless a queued append/publication still claims it.
\*    DurableCapture: a forward-only body at its capture path is referenced by
\*    its row while that row is not terminal (DownloadStore
\*    .artifactPathsReferenced), so the staging sweep leaves it.
\*  - The live-key snapshot handed to reconcile is every tracked task.
Reattach(r) ==
    /\ up /\ recon[r] = "needReattach"
    /\ LET Untracked(a) == task[r][a] = "running" /\ a \notin tracked[r]
           Adopt(a) == /\ Untracked(a) /\ Owns(r, a) /\ life[r] \notin Terminal
                       /\ halt[r] = "none" /\ (FixB02 => life[r] # "paused")
           Cancel(a) == Untracked(a) /\ halt[r] = "none" /\ ~Adopt(a)
           adopted == {a \in Attempts : Adopt(a)}
           Claimed(a) == \/ FixB03 /\ a \in ioq[r]
                         \/ DurableCapture /\ Forward(r) /\ life[r] \notin Terminal
                            /\ owner[r] = a
       IN /\ task' = Upd(task, r, [a \in Attempts |->
                         IF Cancel(a) THEN "none" ELSE task[r][a]])
          /\ tracked' = Upd(tracked, r, tracked[r] \cup adopted)
          /\ IF adopted # {} THEN Submit(r, Ev("taskAdopted")) ELSE UNCHANGED redVars
          /\ liveSnap' = Upd(liveSnap, r, (tracked[r] \cup adopted) # {})
          /\ stash' = Upd(stash, r, {a \in stash[r] :
                         task[r][a] = "running" \/ Claimed(a)})
    /\ recon' = Upd(recon, r, "needReconcile")
    /\ UNCHANGED <<owner, intent, deleting,
                   working, published, up, superseded, ioq, halt, rebuild, fin,
                   bodyDone, staleEffect, budget>>

\* The facts reconcile reports for row r (DownloadStore.observeLifecycleFacts)
\* with reattach's live-task snapshot.
RelaunchFacts(r) ==
    Fx(Route(r), FALSE,
       \* A static working file is the durable checkpoint, unless condemned.
       IF ~condemned[r] /\ ~Forward(r) /\ working[r] # "none" THEN "partial" ELSE "none",
       \* A finished row is asked about its published file only.  A working
       \* file counts as a whole body for a finalizing row, and for a
       \* forward-only row (it reaches the working path only when finished).
       IF life[r] \in Terminal THEN (IF published[r] THEN "published" ELSE "none")
       ELSE IF working[r] # "none" /\ (life[r] = "finalizing" \/ Forward(r))
           THEN "workingComplete"
       \* A forward-only body at its capture path is Body.captured.
       ELSE IF DurableCapture /\ Forward(r) /\ ~condemned[r] /\ owner[r] \in stash[r]
           THEN "captured"
       ELSE "none",
       intent[r] # "none", deleting[r], liveSnap[r], TRUE)

\* reducer: relaunchObserved.  Effects: requestFinalization restarts the
\* finalizer for a body at the working path, or requeues the publication of a
\* captured one (requeueCapturedForwardOnlyBody); deleteWorkingBody deletes
\* the working file.
RelaunchObserved(r) ==
    /\ up /\ recon[r] = "needReconcile"
    /\ recon' = Upd(recon, r, "idle")
    /\ LET L == life[r]
           facts == RelaunchFacts(r)
           \* Before B10 nothing recorded that a forward-only body was finished.
           preB10 == Forward(r) /\ ~FixB10
           preF3 == Forward(r) /\ ~FixPauseKeepsBody /\ L = "paused"
           t == Reduce(Row(r), Ev("relaunchObserved"),
                       IF preB10 /\ facts.body = "workingComplete"
                          THEN [facts EXCEPT !.body = "none"] ELSE facts)
           Keep == UNCHANGED <<redVars, working, fin, ioq>>
       IN
       IF ~Exists(r) THEN Keep
       ELSE IF /\ preB10 /\ L = "finalizing"
               /\ ~deleting[r] /\ intent[r] = "none" THEN
           \* Before B10 a finalizing row was a transferring one.
           IF liveSnap[r] THEN Keep
           ELSE /\ life' = Upd(life, r, "failed")
                /\ cause' = Upd(cause, r, "none")
                /\ working' = Upd(working, r, "none")
                /\ UNCHANGED <<strikes, counted, condemned, fin, ioq>>
       ELSE IF /\ ~FixPauseReconcile /\ L = "paused" /\ liveSnap[r]
               /\ ~deleting[r] /\ intent[r] = "none" THEN
           \* Fix off (F2): before #473 the reducer promoted a paused row that the
           \* live-task snapshot listed ("a paused row a live task proves active").
           /\ life' = Upd(life, r, "transferring")
           /\ cause' = Upd(cause, r, "none")
           /\ UNCHANGED <<strikes, counted, condemned, working, fin, ioq>>
       ELSE IF /\ preF3 /\ facts.body = "workingComplete" /\ ~liveSnap[r]
               /\ ~deleting[r] /\ intent[r] = "none" THEN
           \* Fix off (F3): before #474 the reducer kept a finished forward-only
           \* body only for a row that was not paused.  A paused one was failed
           \* and its working body deleted.
           /\ life' = Upd(life, r, "failed")
           /\ cause' = Upd(cause, r, "none")
           /\ working' = Upd(working, r, "none")
           /\ UNCHANGED <<strikes, counted, condemned, fin, ioq>>
       ELSE
           \* F3: the reducer finalizes a paused forward-only row whose whole
           \* body is at the working path (B10 for a paused row), like any other.
           /\ ApplyRow(r, t.state)
           /\ working' = IF Has(t, "deleteWorkingBody")
                             THEN Upd(working, r, "none") ELSE working
           /\ fin' = IF Has(t, "requestFinalization") /\ facts.body = "workingComplete"
                         THEN Upd(fin, r, owner[r]) ELSE fin
           /\ ioq' = IF Has(t, "requestFinalization") /\ facts.body = "captured"
                         THEN Upd(ioq, r, ioq[r] \cup {owner[r]}) ELSE ioq
    /\ UNCHANGED <<owner, intent, deleting,
                   published, stash, task, up, superseded, tracked, halt, rebuild, liveSnap,
                   bodyDone, staleEffect, budget>>

\* Admission-A1 (#475): reconcile sends a forward-only row with no task, body or
\* checkpoint back to `planned`.  DownloadsAdmission models the window that
\* grants it again; here the grant is one step once reconcile is done.
\* (Foreground reconcile in the code skips forward-only rows a granted start
\* may own; this model reconciles them too, which only adds behaviours.)
\* reducer: admissionGranted
AdmissionGranted(r) ==
    /\ up /\ life[r] = "planned" /\ recon[r] = "idle"
    /\ ~deleting[r] /\ halt[r] = "none"
    /\ Submit(r, Ev("admissionGranted"))
    /\ UNCHANGED <<owner, intent, deleting,
                   fileVars, task, up, superseded, memVars, bodyDone, staleEffect, budget>>

\* A row parked `deferredResume` restarts by itself from its checkpoint.
\* reducer: retry(.staticCheckpoint)
AutoResume(r) ==
    /\ up /\ life[r] = "paused" /\ cause[r] = "deferredResume"
    /\ ~deleting[r] /\ halt[r] = "none" /\ ~Forward(r)
    /\ Submit(r, EvRetry("staticCheckpoint"))
    /\ UNCHANGED <<owner, intent, deleting,
                   fileVars, task, up, superseded, memVars, bodyDone, staleEffect, budget>>

-----------------------------------------------------------------------------

AppStep(r) ==
    \/ TransferStarted(r) \/ RebuildFires(r) \/ StallDetected(r)
    \/ BodyAtWorking(r) \/ FinalizeOutcomeReplayed(r)
    \/ PublishBody(r) \/ PromotionCommitted(r) \/ PromotionAbandoned(r)
    \/ CleanupRuns(r) \/ Reattach(r) \/ RelaunchObserved(r) \/ AutoResume(r)
    \/ PauseSweep(r) \/ AdmissionGranted(r)
    \/ \E o \in Outcomes : FinalizeOutcome(r, o)
    \/ \E a \in Attempts :
          \/ TransferProgress(r, a) \/ DidFinishDownloading(r, a)
          \/ DidCompleteWithError(r, a) \/ RangeIO(r, a)
          \/ HaltedProgress(r, a)

UserStep(r) == UserPause(r) \/ UserResume(r) \/ UserRetry(r) \/ UserDelete(r)

Next ==
    \/ \E r \in Rows : AppStep(r) \/ UserStep(r)
    \/ \E r \in Rows, a \in Attempts : DaemonFinishes(r, a) \/ DaemonFails(r, a)
    \/ Crash \/ Relaunch \/ ForegroundReattachBegins
    \/ \E r \in Rows : FinalizeTruncatedCrash(r)

Spec == Init /\ [][Next]_vars

\* Liveness assumptions, each one a thing the code cannot promise by itself:
\*  - Every step of the session, its queues and the finalizer is weakly fair,
\*    and the daemon resolves every task.  True while the process runs or
\*    the daemon can wake it.
\*  - Network: a task that keeps being retried eventually finishes (the
\*    strong fairness on DaemonFinishes).  The code has retry budgets
\*    instead, and spending one fails the row, which is a stable end; the
\*    model does not count them, so without this assumption a static segment
\*    could fail and be rebuilt for ever.
\*  - Admission: a planned row is eventually granted (DownloadsAdmission
\*    proves WaitingRowIsServed under its own fairness).
\*  - Foreground: RebuildFires, StallDetected and AutoResume are the
\*    manager's steps on the main actor (the error handoff, the stall
\*    watchdog, the deferred-resume pass).  They are weakly fair here.  A
\*    suspended background app runs none of them until it is next in the
\*    foreground; specs/downloads/range-train/Mutant-NoForegroundRefresh.cfg
\*    shows a train that then never moves.
\* The environment (user, crashes, foreground reattach) is not fair;
\* BoundEnvironment makes it finite.
Fairness ==
    /\ WF_vars(Relaunch)
    /\ \A r \in Rows :
          /\ WF_vars(TransferStarted(r)) /\ WF_vars(RebuildFires(r))
          /\ WF_vars(StallDetected(r)) /\ WF_vars(BodyAtWorking(r))
          /\ WF_vars(PublishBody(r)) /\ WF_vars(PromotionCommitted(r))
          /\ WF_vars(PromotionAbandoned(r)) /\ WF_vars(CleanupRuns(r))
          /\ WF_vars(Reattach(r)) /\ WF_vars(RelaunchObserved(r))
          /\ WF_vars(AutoResume(r)) /\ WF_vars(PauseSweep(r))
          /\ WF_vars(AdmissionGranted(r))
          /\ WF_vars(\E o \in Outcomes : FinalizeOutcome(r, o))
          /\ \A a \in Attempts :
                /\ WF_vars(TransferProgress(r, a))
                /\ WF_vars(DidFinishDownloading(r, a))
                /\ WF_vars(DidCompleteWithError(r, a))
                /\ WF_vars(RangeIO(r, a))
                /\ WF_vars(DaemonFinishes(r, a) \/ DaemonFails(r, a))
                /\ SF_vars(DaemonFinishes(r, a))

FairSpec == Spec /\ Fairness

-----------------------------------------------------------------------------
(* Properties                                                              *)

\* A complete (or unverified) row always has its published body: no sweep,
\* reconcile or cleanup removes it while the row stands.
CompleteHasPublishedBody ==
    \A r \in Rows : life[r] \in Playable /\ ~deleting[r] => published[r]

\* A finalizing row has the body it is finalizing.  The one exception is the
\* residue of F4: a crash after a failing truncation verdict renamed the body
\* away and before the verdict was durable leaves a `finalizing` row with no
\* body and no finalizer.  It lasts until reconcile, which fails the row.
\* With the proposed fix there is no exception.
VerdictCrashResidue(r) ==
    /\ ~FixVerdictBeforeRename
    /\ intent[r] = "none" /\ fin[r] = 0
    /\ (~up \/ recon[r] # "idle")
FinalizingHasBody ==
    \A r \in Rows :
        life[r] = "finalizing" /\ ~deleting[r] =>
            \/ working[r] = "complete" \/ published[r]
            \/ DurableCapture /\ owner[r] \in stash[r]
            \/ VerdictCrashResidue(r)

\* The same with no exception.  It fails today (F4) and holds with the fix.
FinalizingAlwaysHasBody ==
    \A r \in Rows :
        life[r] = "finalizing" /\ ~deleting[r] =>
            \/ working[r] = "complete" \/ published[r]
            \/ DurableCapture /\ owner[r] \in stash[r]

\* B03: a body whose append/publication is still queued is never unlinked.
QueuedBodyNotSwept ==
    \A r \in Rows : \A a \in ioq[r] :
        Owns(r, a) /\ halt[r] # "cancel" => a \in stash[r]

\* B12: nothing a stale attempt raised changes the row or its files, neither
\* its callbacks nor the manager's side of its error handoff.
StaleCallbackInert == ~staleEffect

\* B10: a finished body survives a crash at any step.  Once the app holds the
\* whole body of the row's current attempt, it exists in the stash, at the
\* working path or published, until a verdict condemns it, the user deletes
\* the row, or (forward-only, before finalizing, before the F3 fix) the user
\* pauses it.
FinishedBodyNotLost ==
    \A r \in Rows :
        /\ bodyDone[r] # 0 /\ bodyDone[r] = owner[r]
        /\ Exists(r) /\ ~deleting[r]
        => \/ owner[r] \in stash[r] \/ working[r] = "complete" \/ published[r]

\* B02 / B09: nothing but the user moves a user-paused row back to
\* transferring, and no task starts for it.
UserPauseSticky ==
    [][\A r \in Rows : UserPaused(r) => life'[r] # "transferring"]_vars

NoStartWhileUserPaused ==
    [][\A r \in Rows : \A a \in Attempts :
          UserPaused(r) /\ task[r][a] # "running" => task'[r][a] # "running"]_vars

\* B10: a complete body at the working path is only ever published, condemned
\* by a verdict, deleted with its row, or replaced by a fresh attempt the user
\* asked for.  Relaunch recovery never deletes it.  (Before the F3 fix the code
\* deleted it for a user-paused forward-only row; that case is left out here.
\* A crash inside a failing truncation verdict removes it without recording
\* the verdict.  That case is F4: VerdictSurvivesCrash.)
WorkingBodyKept ==
    [][\A r \in Rows :
          /\ working[r] = "complete" /\ working'[r] # "complete"
          /\ ~(Forward(r) /\ UserPaused(r) /\ ~FixPauseKeepsBody)
          /\ up'
          => \/ published'[r] \/ condemned'[r] \/ life'[r] = "absent"
             \/ owner'[r] # owner[r]]_vars

\* F4: a truncation verdict that took a body off the working path is on the
\* row.  No crash leaves the body gone and the row without `bodyCondemned`.
VerdictSurvivesCrash ==
    [][\A r \in Rows :
          working[r] = "complete" /\ working'[r] # "complete" /\ ~up'
          => condemned'[r]]_vars

\* F3: a finished body survives a user pause, on either lane.  The app holds
\* the whole body of the row's current attempt where it can still use it:
\*  - at the working path;
\*  - forward-only: in a stash that a queued publication claims or a durable
\*    capture references;
\*  - static: the first segment is durable and the last one is finished,
\*    either still with the daemon for a task the session tracks, or stashed
\*    under a queued append.
HoldsWholeBody(r) ==
    /\ Exists(r) /\ ~deleting[r]
    /\ \/ working[r] = "complete"
       \/ /\ Forward(r) /\ owner[r] \in stash[r]
          /\ \/ owner[r] \in ioq[r]
             \/ DurableCapture /\ life[r] = "finalizing"
       \/ /\ ~Forward(r) /\ working[r] = "partial"
          /\ \/ (task[r][owner[r]] = "finished" /\ owner[r] \in tracked[r])
             \/ (owner[r] \in stash[r] /\ owner[r] \in ioq[r])

\* While the row is paused by the user (the durable pause, or the in-memory
\* halt that precedes it), no step of a live process gives that body up,
\* unless it is published, condemned by a verdict, deleted with its row, or
\* replaced by a fresh attempt the user asked for.  A crash is F1's subject.
FinishedBodySurvivesPause ==
    [][\A r \in Rows :
          HoldsWholeBody(r) /\ (UserPaused(r) \/ halt[r] = "pause") /\ up'
          => \/ HoldsWholeBody(r)' \/ published'[r] \/ condemned'[r]
             \/ deleting'[r] \/ life'[r] = "absent" \/ owner'[r] # owner[r]]_vars

\* R2-5: a replayed finalize outcome is a no-op.
ReplayedOutcomeIsNoOp ==
    [][\A r \in Rows : FinalizeOutcomeReplayed(r) =>
          UNCHANGED <<rowVars, fileVars>>]_vars

\* Liveness: an admitted row eventually reaches a stable state.
Stable(r) ==
    \/ life[r] \in Terminal \/ life[r] = "absent"
    \/ UserPaused(r)

AdmittedEventuallyStable ==
    \A r \in Rows : (life[r] = "admitted") ~> Stable(r)
=============================================================================
