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
(*              RebuildFires, StallDetected                                *)
(*   Finalizer  BodyAtWorking, FinalizeOutcome, FinalizeOutcomeReplayed,   *)
(*              PublishBody, PromotionCommitted, PromotionAbandoned        *)
(*   Sweeper    the stash sweep inside Reattach; CleanupRuns for Delete    *)
(*   Recovery   Reattach and RelaunchObserved (reconcile), after a         *)
(*              relaunch or a return to the foreground; AutoResume         *)
(*   Crash      Crash drops every in-memory variable; Relaunch restarts    *)
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
(*    when it ends.                                                        *)
(*  - Index persistence is atomic per action; the persistence writer and   *)
(*    path leases are not modelled.                                        *)
(*  - Delete is one durable flag and one cleanup step; the cleanup intent  *)
(*    journal is not modelled.                                             *)
(*                                                                         *)
(* Lifecycle and history change only through Reduce (DownloadsReducer.tla).*)
(* The hand-written exceptions are the "fix off" branches, which restore   *)
(* a historical bug, and the two PROPOSED fixes.                           *)
(***************************************************************************)
\* MODELS: Labstream/Capabilities/Downloads/Core/BackgroundDownloadSession.swift
\* MODELS: Labstream/Capabilities/Downloads/Core/DownloadStore.swift
\* MODELS: PMSKit/Sources/PMSKit/Downloads/BackgroundTempFileCleanupPolicy.swift
\* MODELS: PMSKit/Sources/PMSKit/Downloads/StaticRangeFinishedBodyPolicy.swift
\* MODELS: PMSKit/Sources/PMSKit/Downloads/BackgroundFinalizationResultPolicy.swift
EXTENDS DownloadsReducer, TLC

CONSTANTS
    Rows,               \* download keys
    ForwardRows,        \* the rows on the forward-only route; the rest are static-range
    MaxAttempt,         \* attempt IDs are 1..MaxAttempt
    Outcomes,           \* finalize verdicts the finalizer may return
    FixB02,             \* Pause invalidates queued rebuilds; reattach never adopts a paused row
    FixB03,             \* the stash sweep rechecks the claim of a queued append/publication
    FixB09,             \* transferProgress never promotes a paused row
    FixB10,             \* relaunch re-finalizes a finished forward-only body
    FixB12,             \* callbacks act only for the exact attempt that owns the row
    FixReplay,          \* a replayed finalize outcome ID is rejected
    FixPauseReconcile,  \* PROPOSED (not in the code): reconcile never promotes a paused row
    DurableCapture,     \* PROPOSED (not in the code): bodyCaptured is persisted with the stash
    ForegroundReattach, \* allow reattach + reconcile while the process stays alive
    BoundEnvironment,   \* TRUE: at most EnvBudget user/crash/foreground steps (liveness runs)
    EnvBudget

ASSUME /\ ForwardRows \subseteq Rows
       /\ MaxAttempt \in Nat \ {0}
       /\ Outcomes \subseteq FinalizeOutcomes /\ Outcomes # {}
       /\ EnvBudget \in Nat

Attempts == 1..MaxAttempt

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
    stash,       \* [Rows -> SUBSET Attempts]      finished bodies stashed in tmp/, by task
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
    \* ---- ghosts (observe only; never read by an action's guard) ----
    bodyDone,    \* [Rows -> 0..MaxAttempt]        attempt whose finished body the app holds
    staleEffect, \* BOOLEAN                        a stale-attempt callback changed something
    budget       \* 0..EnvBudget

\* The part of the row the reducer owns.
redVars  == <<life, cause, strikes, counted, condemned>>
rowVars  == <<life, cause, owner, strikes, counted, condemned, intent, deleting>>
fileVars == <<working, published, stash>>
memVars  == <<tracked, ioq, halt, rebuild, fin, recon, liveSnap>>
vars     == <<rowVars, fileVars, task, up, memVars, bodyDone, staleEffect, budget>>

Route(r) == IF r \in ForwardRows THEN "forwardOnly" ELSE "staticRange"
Forward(r) == r \in ForwardRows
Exists(r) == life[r] # "absent"
UserPaused(r) == life[r] = "paused" /\ cause[r] = "user"

\* DownloadStore.attemptAdmitsWork / BackgroundDownloadSession.stillOwnsAttempt
Owns(r, a) == Exists(r) /\ owner[r] = a /\ ~deleting[r]
\* What a callback handler accepts.  Before B12 callbacks were matched by row only.
Accepts(r, a) == IF FixB12 THEN Owns(r, a) ELSE Exists(r) /\ ~deleting[r]
Stale(r, a) == owner[r] # a

-----------------------------------------------------------------------------
(* The reducer's view of a row                                             *)

\* The history fields this model tracks.  The others (lastFailure,
\* unverifiedReason, admissionIntent, storagePark) stay at their empty values;
\* Projection-SessionCore.cfg checks that they never influence the tracked
\* ones for the events this model sends.  There is one source, "src".
Row(r) ==
    St(life[r], cause[r], "none", "none", "none", FALSE, condemned[r], strikes[r],
       IF strikes[r] = 0 /\ counted[r] = {} THEN "none" ELSE "src", counted[r])

\* Store a reducer state as row r.
ApplyRow(r, s) ==
    /\ life' = Upd(life, r, s.lifecycle)
    /\ cause' = Upd(cause, r, s.pauseCause)
    /\ strikes' = Upd(strikes, r, s.strikes)
    /\ counted' = Upd(counted, r, s.counted)
    /\ condemned' = Upd(condemned, r, s.bodyCondemned)

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
                   fileVars, up, ioq, halt, rebuild, recon, liveSnap,
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
                   fileVars, task, up, memVars, bodyDone, budget>>

-----------------------------------------------------------------------------
(* Daemon: runs whether or not the app is alive                            *)

DaemonFinishes(r, a) ==
    /\ task[r][a] = "running"
    /\ task' = [task EXCEPT ![r][a] = "finished"]
    /\ UNCHANGED <<rowVars, fileVars, up, memVars, bodyDone, staleEffect, budget>>

\* A transport error or a cancellation.
DaemonFails(r, a) ==
    /\ task[r][a] = "running"
    /\ task' = [task EXCEPT ![r][a] = "failed"]
    /\ UNCHANGED <<rowVars, fileVars, up, memVars, bodyDone, staleEffect, budget>>

-----------------------------------------------------------------------------
(* Session: completion callbacks                                           *)

\* urlSession(_:downloadTask:didFinishDownloadingTo:).  The body leaves the OS
\* temp for a tmp/ stash, the stash is claimed, and the append (static) or
\* publication to the working path (forward-only) is queued on the IO queue.
\* An untracked task is a redelivery after relaunch and is adopted only for a
\* non-terminal row.  A cancel halt discards a static body; a pause halt keeps it.
DidFinishDownloading(r, a) ==
    /\ up /\ task[r][a] = "finished"
    /\ task' = [task EXCEPT ![r][a] = "none"]
    /\ tracked' = Upd(tracked, r, tracked[r] \ {a})
    /\ LET keep == /\ Accepts(r, a)
                   /\ (a \notin tracked[r] => life[r] \notin Terminal)
                   /\ ~(~Forward(r) /\ halt[r] = "cancel")
           mine == owner[r] = a
           captured == Send(r, Ev("bodyCaptured"))
           capture == /\ DurableCapture /\ keep /\ mine /\ Forward(r)
                      /\ IsApplied(captured)
       IN /\ stash' = IF keep THEN Upd(stash, r, stash[r] \cup {a}) ELSE stash
          /\ ioq' = IF keep THEN Upd(ioq, r, ioq[r] \cup {a}) ELSE ioq
          \* PROPOSED: reducer event bodyCaptured, persisted with the stash.
          /\ IF capture THEN ApplyRow(r, captured.state) ELSE UNCHANGED redVars
          \* A forward-only body is finished here.  A user pause is allowed to
          \* discard it (Resume restarts a forward-only stream from zero).
          /\ bodyDone' = IF keep /\ mine /\ Forward(r) /\ (capture \/ ~UserPaused(r))
                            THEN Upd(bodyDone, r, a) ELSE bodyDone
    /\ UNCHANGED <<owner, intent, deleting,
                   working, published, up, halt, rebuild, fin, recon, liveSnap,
                   staleEffect, budget>>

\* urlSession(_:task:didCompleteWithError:) with an error.  A halted row
\* expects its cancellation.  Otherwise a static transfer either schedules a
\* delayed retry (rebuild) or fails; a forward-only transfer fails.
\* reducer: transferFailed.
DidCompleteWithError(r, a) ==
    /\ up /\ task[r][a] = "failed"
    /\ task' = [task EXCEPT ![r][a] = "none"]
    /\ tracked' = Upd(tracked, r, tracked[r] \ {a})
    /\ IF /\ a \in tracked[r] /\ Accepts(r, a) /\ halt[r] = "none"
          /\ life[r] \in {"admitted", "transferring"}
          THEN /\ \/ /\ ~Forward(r)
                     /\ rebuild' = Upd(rebuild, r, a)
                     /\ UNCHANGED redVars
                  \/ /\ Submit(r, EvReason("transferFailed", "network"))
                     /\ UNCHANGED rebuild
               /\ staleEffect' = (staleEffect \/ Stale(r, a))
          ELSE UNCHANGED <<redVars, rebuild, staleEffect>>
    /\ UNCHANGED <<owner, intent, deleting,
                   fileVars, up, ioq, halt, fin, recon, liveSnap, bodyDone, budget>>

\* The queued hop on rangeIOQueue: applyFinishedRangeBody (static) or
\* finishOpaqueBody (forward-only).  It rechecks that its attempt is current,
\* consumes the stash, and releases the claim when it ends.
RangeIO(r, a) ==
    /\ up /\ a \in ioq[r]
    /\ ioq' = Upd(ioq, r, ioq[r] \ {a})
    /\ LET current == /\ Accepts(r, a) /\ halt[r] # "cancel"
                      \* finishOpaqueBody: checkpointIsCurrent(currency, halt: nil)
                      /\ (Forward(r) /\ ~DurableCapture => halt[r] = "none")
           present == a \in stash[r]
           fresh   == owner[r] = a
       IN
       /\ staleEffect' = (staleEffect \/ (current /\ ~fresh))
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
              /\ CASE working[r] = "none" ->
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
                   published, up, halt, rebuild, recon, liveSnap, budget>>

\* A delayed retry / range-request rebuild fires.  B02: its currency (attempt,
\* halt, generation) must still be current, so a Pause in between stops it.
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
       IN IF start
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
                   fileVars, up, ioq, halt, fin, recon, liveSnap,
                   bodyDone, staleEffect, budget>>

\* reducer: stallDetected.  A transferring row with no task and no queued work.
StallDetected(r) ==
    /\ up /\ life[r] = "transferring" /\ ~deleting[r]
    /\ tracked[r] = {} /\ ioq[r] = {} /\ fin[r] = 0 /\ rebuild[r] = 0
    /\ recon[r] = "idle" /\ task[r][owner[r]] = "none"
    /\ Submit(r, Ev("stallDetected"))
    /\ UNCHANGED <<owner, intent, deleting,
                   fileVars, task, up, memVars, bodyDone, staleEffect, budget>>

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
                   fileVars, task, up, tracked, ioq, halt, rebuild, recon, liveSnap,
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
    /\ UNCHANGED <<owner, deleting, published, stash, task, up,
                   tracked, ioq, halt, rebuild, recon, liveSnap, staleEffect, budget>>

\* The finalizer delivers the truncation verdict it already delivered (same
\* outcome ID) while the row still waits to publish.  R2-5: rejected(.replayed).
FinalizeOutcomeReplayed(r) ==
    /\ up /\ fin[r] # 0 /\ fin[r] = owner[r] /\ life[r] = "finalizing"
    /\ ~deleting[r] /\ intent[r] = "unverified" /\ owner[r] \in counted[r]
    /\ IF FixReplay
          THEN /\ Send(r, EvFinalize(owner[r], "truncated", "src")) = Replayed
               /\ UNCHANGED strikes
          ELSE /\ strikes[r] <= MaxTruncationStrikes
               /\ strikes' = Upd(strikes, r, strikes[r] + 1)
    /\ UNCHANGED <<life, cause, owner, counted, condemned, intent, deleting,
                   fileVars, task, up, memVars, bodyDone, staleEffect, budget>>

\* The validated-promotion recipe.  It is driven by the durable intent, so it
\* replays after a relaunch without the in-memory finalizer.
PublishBody(r) ==
    /\ up /\ intent[r] # "none" /\ life[r] = "finalizing" /\ ~deleting[r]
    /\ working[r] = "complete" /\ ~published[r]
    /\ published' = Upd(published, r, TRUE)
    /\ working' = Upd(working, r, "none")
    /\ UNCHANGED <<rowVars, stash, task, up, memVars, bodyDone, staleEffect, budget>>

\* reducer: promotionCommitted
PromotionCommitted(r) ==
    /\ up /\ intent[r] # "none" /\ life[r] = "finalizing" /\ ~deleting[r]
    /\ published[r]
    /\ Submit(r, EvPromotion("promotionCommitted", intent[r]))
    /\ intent' = Upd(intent, r, "none")
    /\ fin' = Upd(fin, r, 0)
    /\ UNCHANGED <<owner, deleting,
                   fileVars, task, up, tracked, ioq, halt, rebuild, recon, liveSnap,
                   bodyDone, staleEffect, budget>>

\* reducer: promotionAbandoned.  The intent's body is gone.
PromotionAbandoned(r) ==
    /\ up /\ intent[r] # "none" /\ life[r] = "finalizing" /\ ~deleting[r]
    /\ working[r] # "complete" /\ ~published[r]
    /\ Submit(r, Ev("promotionAbandoned"))
    /\ intent' = Upd(intent, r, "none")
    /\ fin' = Upd(fin, r, 0)
    /\ UNCHANGED <<owner, deleting,
                   fileVars, task, up, tracked, ioq, halt, rebuild, recon, liveSnap,
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
    /\ rebuild' = IF FixB02 THEN Upd(rebuild, r, 0) ELSE rebuild
    \* A user pause may discard a finished forward-only body that has not
    \* reached `finalizing` (see DidFinishDownloading).
    /\ bodyDone' = IF Forward(r) THEN Upd(bodyDone, r, 0) ELSE bodyDone
    /\ UNCHANGED <<owner, intent, deleting,
                   fileVars, task, up, ioq, fin, recon, liveSnap, staleEffect>>

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
    /\ rebuild' = IF FixB02 THEN Upd(rebuild, r, 0) ELSE rebuild
    /\ IF Forward(r)
          THEN FreshAttempt(r)
          ELSE /\ Submit(r, EvRetry("staticCheckpoint"))
               /\ UNCHANGED <<owner, working, fin, bodyDone>>
    /\ UNCHANGED <<intent, deleting, published, stash, task, up,
                   tracked, ioq, recon, liveSnap, staleEffect>>

\* reducer: retry(.freshAttempt) from failed.
UserRetry(r) ==
    /\ up /\ life[r] = "failed" /\ ~deleting[r]
    /\ Spend
    /\ FreshAttempt(r)
    /\ halt' = Upd(halt, r, "none")
    /\ rebuild' = Upd(rebuild, r, 0)
    /\ UNCHANGED <<intent, deleting, published, stash, task, up,
                   tracked, ioq, recon, liveSnap, staleEffect>>

\* Delete: a durable deletion-pending flag and a cancel halt.
UserDelete(r) ==
    /\ up /\ Exists(r) /\ ~deleting[r]
    /\ Spend
    /\ deleting' = Upd(deleting, r, TRUE)
    /\ halt' = Upd(halt, r, "cancel")
    /\ rebuild' = Upd(rebuild, r, 0)
    /\ UNCHANGED <<life, cause, owner, strikes, counted, condemned, intent,
                   fileVars, task, up, tracked, ioq, fin, recon, liveSnap,
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
    /\ UNCHANGED <<owner, strikes, counted, up, ioq, halt, rebuild, recon, liveSnap,
                   staleEffect, budget>>

-----------------------------------------------------------------------------
(* Crash and recovery                                                      *)

Crash ==
    /\ up
    /\ Spend
    /\ up' = FALSE
    /\ tracked' = [r \in Rows |-> {}]
    /\ ioq' = [r \in Rows |-> {}]
    /\ halt' = [r \in Rows |-> "none"]
    /\ rebuild' = [r \in Rows |-> 0]
    /\ fin' = [r \in Rows |-> 0]
    /\ recon' = [r \in Rows |-> "idle"]
    /\ liveSnap' = [r \in Rows |-> FALSE]
    /\ UNCHANGED <<rowVars, fileVars, task, bodyDone, staleEffect>>

Relaunch ==
    /\ ~up
    /\ up' = TRUE
    /\ recon' = [r \in Rows |-> "needReattach"]
    /\ UNCHANGED <<rowVars, fileVars, task, tracked, ioq, halt, rebuild, fin, liveSnap,
                   bodyDone, staleEffect, budget>>

\* Returning to the foreground runs the same reattach + reconcile in-process
\* (recoverStaticRangeTransfersAfterForeground).  This step is the getAllTasks
\* request; Reattach is its completion.
ForegroundReattachBegins ==
    /\ ForegroundReattach /\ up
    /\ \A r \in Rows : recon[r] = "idle"
    /\ Spend
    /\ recon' = [r \in Rows |-> "needReattach"]
    \* getAllTasks completions run in request order.  A Pause that came first has
    \* its own completion ahead of this one, and that drops the row's range
    \* tracking (pauseRangeTask) before Reattach takes its live snapshot.
    /\ tracked' = [r \in Rows |-> IF halt[r] = "pause" THEN {} ELSE tracked[r]]
    /\ UNCHANGED <<rowVars, fileVars, task, up, ioq, halt, rebuild, fin, liveSnap,
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
\*  - The live-key snapshot handed to reconcile is every tracked task.
Reattach(r) ==
    /\ up /\ recon[r] = "needReattach"
    /\ LET Untracked(a) == task[r][a] = "running" /\ a \notin tracked[r]
           Adopt(a) == /\ Untracked(a) /\ Owns(r, a) /\ life[r] \notin Terminal
                       /\ halt[r] = "none" /\ (FixB02 => life[r] # "paused")
           Cancel(a) == Untracked(a) /\ halt[r] = "none" /\ ~Adopt(a)
           adopted == {a \in Attempts : Adopt(a)}
           Claimed(a) == \/ FixB03 /\ a \in ioq[r]
                         \/ DurableCapture /\ Forward(r) /\ life[r] = "finalizing"
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
                   working, published, up, ioq, halt, rebuild, fin,
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
       \* PROPOSED: a durably captured stash is reported as Body.captured.
       ELSE IF DurableCapture /\ owner[r] \in stash[r] THEN "captured"
       ELSE "none",
       intent[r] # "none", deleting[r], liveSnap[r], TRUE)

\* reducer: relaunchObserved.  Effects: requestFinalization restarts the
\* finalizer for a body at the working path (PROPOSED: requeues the
\* publication of a captured stash); deleteWorkingBody deletes the working
\* file.
RelaunchObserved(r) ==
    /\ up /\ recon[r] = "needReconcile"
    /\ recon' = Upd(recon, r, "idle")
    /\ LET L == life[r]
           facts == RelaunchFacts(r)
           \* Before B10 nothing recorded that a forward-only body was finished.
           preB10 == Forward(r) /\ ~FixB10
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
       ELSE IF FixPauseReconcile /\ L = "paused" /\ t.state.lifecycle = "transferring" THEN
           \* PROPOSED: reconcile never promotes a paused row.
           Keep
       ELSE
           /\ ApplyRow(r, t.state)
           /\ working' = IF Has(t, "deleteWorkingBody")
                             THEN Upd(working, r, "none") ELSE working
           /\ fin' = IF Has(t, "requestFinalization") /\ facts.body = "workingComplete"
                         THEN Upd(fin, r, owner[r]) ELSE fin
           /\ ioq' = IF Has(t, "requestFinalization") /\ facts.body = "captured"
                         THEN Upd(ioq, r, ioq[r] \cup {owner[r]}) ELSE ioq
    /\ UNCHANGED <<owner, intent, deleting,
                   published, stash, task, up, tracked, halt, rebuild, liveSnap,
                   bodyDone, staleEffect, budget>>

\* A row parked `deferredResume` restarts by itself from its checkpoint.
\* reducer: retry(.staticCheckpoint)
AutoResume(r) ==
    /\ up /\ life[r] = "paused" /\ cause[r] = "deferredResume"
    /\ ~deleting[r] /\ halt[r] = "none" /\ ~Forward(r)
    /\ Submit(r, EvRetry("staticCheckpoint"))
    /\ UNCHANGED <<owner, intent, deleting,
                   fileVars, task, up, memVars, bodyDone, staleEffect, budget>>

-----------------------------------------------------------------------------

AppStep(r) ==
    \/ TransferStarted(r) \/ RebuildFires(r) \/ StallDetected(r)
    \/ BodyAtWorking(r) \/ FinalizeOutcomeReplayed(r)
    \/ PublishBody(r) \/ PromotionCommitted(r) \/ PromotionAbandoned(r)
    \/ CleanupRuns(r) \/ Reattach(r) \/ RelaunchObserved(r) \/ AutoResume(r)
    \/ \E o \in Outcomes : FinalizeOutcome(r, o)
    \/ \E a \in Attempts :
          \/ TransferProgress(r, a) \/ DidFinishDownloading(r, a)
          \/ DidCompleteWithError(r, a) \/ RangeIO(r, a)

UserStep(r) == UserPause(r) \/ UserResume(r) \/ UserRetry(r) \/ UserDelete(r)

Next ==
    \/ \E r \in Rows : AppStep(r) \/ UserStep(r)
    \/ \E r \in Rows, a \in Attempts : DaemonFinishes(r, a) \/ DaemonFails(r, a)
    \/ Crash \/ Relaunch \/ ForegroundReattachBegins

Spec == Init /\ [][Next]_vars

\* Liveness: every app step is weakly fair, the daemon resolves every task, and
\* a task that keeps being retried eventually finishes (strong fairness).  The
\* environment (user, crashes, foreground) is not fair; BoundEnvironment makes
\* it finite.
Fairness ==
    /\ WF_vars(Relaunch)
    /\ \A r \in Rows :
          /\ WF_vars(TransferStarted(r)) /\ WF_vars(RebuildFires(r))
          /\ WF_vars(StallDetected(r)) /\ WF_vars(BodyAtWorking(r))
          /\ WF_vars(PublishBody(r)) /\ WF_vars(PromotionCommitted(r))
          /\ WF_vars(PromotionAbandoned(r)) /\ WF_vars(CleanupRuns(r))
          /\ WF_vars(Reattach(r)) /\ WF_vars(RelaunchObserved(r))
          /\ WF_vars(AutoResume(r))
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

\* A finalizing row always has the body it is finalizing.
FinalizingHasBody ==
    \A r \in Rows :
        life[r] = "finalizing" /\ ~deleting[r] =>
            \/ working[r] = "complete" \/ published[r]
            \/ DurableCapture /\ owner[r] \in stash[r]

\* B03: a body whose append/publication is still queued is never unlinked.
QueuedBodyNotSwept ==
    \A r \in Rows : \A a \in ioq[r] :
        Owns(r, a) /\ halt[r] # "cancel" => a \in stash[r]

\* B12: a callback from a stale attempt never changes the row or its files.
StaleCallbackInert == ~staleEffect

\* B10: a finished body survives a crash at any step.  Once the app holds the
\* whole body of the row's current attempt, it exists in the stash, at the
\* working path or published, until a verdict condemns it, the user deletes
\* the row, or (forward-only, before finalizing) the user pauses it.
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
\* asked for.  Relaunch recovery never deletes it.  (A user-paused forward-only
\* row is exempt, as in FinishedBodyNotLost.)
WorkingBodyKept ==
    [][\A r \in Rows :
          /\ working[r] = "complete" /\ working'[r] # "complete"
          /\ ~(Forward(r) /\ UserPaused(r))
          => \/ published'[r] \/ condemned'[r] \/ life'[r] = "absent"
             \/ owner'[r] # owner[r]]_vars

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
