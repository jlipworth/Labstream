------------------------- MODULE DownloadsServerPrep -------------------------
(***************************************************************************)
(* Server preparation: the Plex optimize and Emby Convert runners, from    *)
(* the first poll to the hand-off to the static transfer.                  *)
(*                                                                         *)
(* One row is one download whose bytes do not exist yet: the server has to *)
(* render them first.  The model follows the row until the render is       *)
(* handed to the static lane (DownloadsSessionCore takes over there), the  *)
(* row fails, or it is deleted.  Actors:                                   *)
(*                                                                         *)
(*   Poller   one chain per attached poller ID: Attach, PlexPoll,          *)
(*            EmbyPreflight, EmbyRecover, EmbyPrepoll, EmbyPoll, Dispatch, *)
(*            Send, Respond, Handoff, HandoffRefused, PollFails, StaleExit *)
(*   Server   ServerAccepts, ServerRejects, RequestLost, ResponseLost,     *)
(*            JobFinishes, JobFails, JobVanishes, StrayFinishes            *)
(*   Clocks   GraceElapses (Plex create visibility), RecoveryExpires (Emby *)
(*            adoption deadline)                                           *)
(*   User     UserPause, UserResume, UserRetry, UserDelete                 *)
(*   Cleanup  RunnerRuns, StrayRunnerRuns: the journaled cancels           *)
(*   Crash    Crash, Relaunch                                              *)
(*                                                                         *)
(* A chain is the async function a poller task runs.  Pause, Delete and a  *)
(* failure detach the poller; the chain that was running keeps its place   *)
(* and finds out at its next currency check (StaleExit).  With two chain   *)
(* slots per row, one stale chain runs next to the current one.            *)
(*                                                                         *)
(* The two backends differ where the Swift differs:                        *)
(*  - A Plex prep row is persisted `admitted` (shown queued); an Emby one  *)
(*    is `serverPrep` (shown preparing) once its seed is written.          *)
(*  - Plex records that a create was dispatched (`disp`) and later that it *)
(*    was confirmed (`ident`).  Emby records an ambiguous dispatch         *)
(*    (`disp`) and replaces it with the job ID (`ident`) on adoption.      *)
(*  - Retry of a failed Plex prep row replaces the attempt and its queue   *)
(*    title.  Retry of a failed Emby row that still names a job polls or   *)
(*    recovers that job.                                                   *)
(*                                                                         *)
(* Abstractions (README.md lists what is not covered):                     *)
(*  - The server holds at most one job for the row's current identity      *)
(*    (`job`) and at most one unfinished job of a replaced identity        *)
(*    (`stray`).  A finished job makes the render visible in the same      *)
(*    step: Plex's metadata indexing gap and Emby's source indexing lag    *)
(*    are not modelled.                                                    *)
(*  - A render exists from the start (InitialRender) or comes from one of  *)
(*    the row's own jobs.  Other clients do not create renders.            *)
(*  - Time is four facts.  The Plex create-visibility grace and the Emby   *)
(*    adoption deadline elapse only once no create request is in flight    *)
(*    (180 s and 24 h against a request timeout), and the cleanup runner   *)
(*    keeps an intent whose create may still land.  The 24 h Plex render   *)
(*    deadline (`dayOut`, PlexOptimizeDeadlinePolicy) comes after the      *)
(*    grace, and does not pass while a poll that would act is pending:     *)
(*    the poll interval is seconds, so a current poller that has           *)
(*    something to do does it within the day.  A poll with nothing to do   *)
(*    lets the day run out, and then fails the row.                        *)
(*  - The hand-off waits for a static transfer slot                        *)
(*    (awaitStaticHandoffRoom, #414).  `slotFree` is the environment's:    *)
(*    other downloads take and release the slot.  A start-time Emby reuse  *)
(*    does not wait (waitsForTransferSlot: false).  The wait checks only   *)
(*    currency, so a waiting row is unaffected by the render deadline.     *)
(*  - Index and journal writes are atomic per action.  Journal failure,    *)
(*    the deletion barrier and admission caps belong to other modules.     *)
(*  - A replacement attempt starts only after the old attempt's chains     *)
(*    have ended and no create request or response is outstanding.         *)
(*  - Rows do not interact: the prep-lane cap and the shared Emby Convert  *)
(*    coordinator are not modelled.                                        *)
(*                                                                         *)
(* Lifecycle and history change only through Reduce (DownloadsReducer).    *)
(* The exceptions are a replacement attempt, which is a new row built with *)
(* InitialState, and the mutant hand-off, which is marked.                 *)
(***************************************************************************)
\* MODELS: Labstream/Capabilities/Downloads/Core/DownloadManager+PlexOptimize.swift
\* MODELS: Labstream/Capabilities/Downloads/Core/DownloadManager.swift
\* MODELS: Labstream/Capabilities/Downloads/Core/DownloadManager+EmbyConvert.swift
\* MODELS: PMSKit/Sources/PMSKit/Downloads/ServerPrepAttemptTracker.swift
\* MODELS: PMSKit/Sources/PMSKit/Downloads/ServerPrepRefreshPolicy.swift
\* MODELS: PMSKit/Sources/PMSKit/Downloads/PlexOptimizePrepPolicy.swift
\* MODELS: PMSKit/Sources/PMSKit/Downloads/PlexOptimizePollHealthPolicy.swift
\* MODELS: PMSKit/Sources/PMSKit/Downloads/EmbyConvertPollHealthPolicy.swift
\* MODELS: PMSKit/Sources/PMSKit/Downloads/EmbyConvertedSourcePolicy.swift
\* MODELS: PMSKit/Sources/PMSKit/Downloads/DownloadDeletePolicy.swift
\* MODELS: PMSKit/Sources/PMSKit/Downloads/DownloadRetryPreparationPolicy.swift
\* MODELS: PMSKit/Sources/PMSKit/DownloadRetryPolicy.swift
\* MODELS: PMSKit/Sources/PMSKit/Emby/EmbyConvertRequest.swift
EXTENDS DownloadsReducer, TLC

CONSTANTS
    Rows,               \* download keys
    PlexRows,           \* the rows on the Plex optimize route; the rest are Emby Convert
    Pollers,            \* poller IDs (model values); one chain slot each
    NoPoller,           \* model value: no poller attached
    InitialRender,      \* SUBSET BOOLEAN: may a matching render exist before the row starts
    FixB28,             \* Delete journals the cancel of unfinished prep, paused prep included
    FixB35,             \* Plex adopts a matching render before it creates a job
    FixB37,             \* a failed or missing Plex create fails the row (no silent wait)
    FixB47,             \* a create that lands on a parked Emby row is adopted, not cancelled
    MutantHandoffUnchecked,
                        \* MUTANT: the hand-off skips its currency check
    AbandonJournalsCancel,
                        \* PROPOSED: a Plex attempt that abandons an unfinished job (Retry
                        \* replaces it, or the hand-off adopts another render) journals
                        \* the cancel (finding S1)
    SlotReturns,        \* a static slot another download took is released again (FALSE:
                        \* the static lane never drains; for Mutant-SlotNeverReturns)
    BoundEnvironment,   \* cap the environment for the liveness check
    EnvBudget           \* environment steps allowed when BoundEnvironment

ASSUME /\ PlexRows \subseteq Rows
       /\ InitialRender \subseteq BOOLEAN /\ InitialRender # {}
       /\ NoPoller \notin Pollers

\* Poller IDs are fresh UUIDs: the spec never tells two of them apart.
PollerSymmetry == Permutations(Pollers)

VARIABLES
    \* ---- durable: the index row (survives Crash) ----
    exists,      \* [Rows -> BOOLEAN]        the row is in the index
    rs,          \* [Rows -> reducer state]  DownloadLifecycleState
    mode,        \* [Rows -> {"prep","static"}]  resumeMode: serverPrepThenStatic or
                 \*                          staticByteRange (the hand-off committed)
    disp,        \* [Rows -> BOOLEAN]        a create was dispatched: Plex
                 \*                          plexOptimizeCreateDispatchedAtEpochSeconds,
                 \*                          Emby recovery phase dispatchAmbiguous
    ident,       \* [Rows -> BOOLEAN]        the job is known: Plex
                 \*                          plexOptimizeCreateConfirmed, Emby embyConvertJobID
    \* ---- durable: the cleanup intent journal (survives Crash) ----
    intent,      \* [Rows -> {"none","pending"}]  cancel the job of the current identity
    strayIntent, \* [Rows -> {"none","pending"}]  cancel the job of a replaced identity
    \* ---- durable: wall-clock facts measured from persisted timestamps ----
    grace,       \* [Rows -> BOOLEAN]        Plex createVisibilityGraceSeconds has passed
    expired,     \* [Rows -> BOOLEAN]        Emby recoveryExpirySeconds has passed
    dayOut,      \* [Rows -> BOOLEAN]        Plex: 24 h since plexOptimizeStartedAtEpochSeconds
    \* ---- durable: the server and the network (outlive the app) ----
    job,         \* [Rows -> JobStates]      the job of the row's current identity
    stray,       \* [Rows -> {"none","active"}]  an unfinished job of a replaced identity
    render,      \* [Rows -> BOOLEAN]        a matching rendered version is visible
    post,        \* [Rows -> PostStates]     the create request and its response
    \* ---- environment: the static transfer lane (other downloads) ----
    slotFree,    \* BOOLEAN                  a static transfer slot is free
    \* ---- in memory (lost on Crash) ----
    up,          \* BOOLEAN                  the app process is alive
    poller,      \* [Rows -> Pollers \cup {NoPoller}]  ServerPrepAttemptTracker
    pc,          \* [Rows -> [Pollers -> ChainStates]]  where each poller's chain is
    \* ---- ghost (never read by a guard) ----
    handoffs,    \* [Rows -> 0..2]           hand-offs committed for the row
    posts,       \* [Rows -> 0..2]           create requests sent for the current identity
    \* ---- model bound ----
    env          \* environment steps taken (only when BoundEnvironment)

rowVars == <<exists, rs, mode, disp, ident>>
journalVars == <<intent, strayIntent>>
clockVars == <<grace, expired, dayOut>>
serverVars == <<job, stray, render, post>>
memVars == <<poller, pc>>
ghostVars == <<handoffs, posts>>
vars == <<rowVars, journalVars, clockVars, serverVars, slotFree, up, memVars, ghostVars, env>>

\* "cancelled" is a job the app removed; "none" is a job that never existed or
\* that someone else removed.  Both read as absent.
JobStates == {"none", "active", "done", "failed", "cancelled"}
\* "sent": on its way to the server.  "ok": accepted, the response is on its way
\* back.  "rejected": a definitive refusal (HTTP 4xx).  "failed": no usable
\* response, whether or not the server accepted.
PostStates == {"none", "sent", "ok", "rejected", "failed"}
ChainStates ==
    {"idle", "poll", "dispatch", "send", "awaitPost", "found", "reuse",
     "preflight", "recover", "prepoll"}
\* A chain that holds a render to hand off.  "found" waits for a static slot;
\* "reuse" is the Emby start-time reuse, which does not.
HandoffStates == {"found", "reuse"}

IsPlex(r) == r \in PlexRows
Route(r) == IF IsPlex(r) THEN "plexPrep" ELSE "embyConvert"
Life(r) == rs[r].lifecycle
JobAbsent(r) == job[r] \in {"none", "cancelled"}

\* The lifecycle a row has while the server prepares it.
PrepLifecycle(r) == IF IsPlex(r) THEN "admitted" ELSE "serverPrep"
PrepActive(r) == exists[r] /\ mode[r] = "prep" /\ Life(r) = PrepLifecycle(r)

\* assertCurrentOptimizeAttempt with isCurrentPlexPoller, and
\* embyConvertAttemptIsCurrent: the chain is still the row's attached poller
\* and the row is still in prep.
Current(r, p) == PrepActive(r) /\ poller[r] = p

\* A live row still names the job: its queue title (Plex), or its job ID or
\* dispatch identity (Emby).  The cleanup runner waits for the claim to go
\* (plexClaimedTitles, claimingRecords).
Claims(r) == exists[r] /\ mode[r] = "prep" /\ (IsPlex(r) \/ ident[r] \/ disp[r])

EnvOK == ~BoundEnvironment \/ env < EnvBudget
EnvStep == env' = IF BoundEnvironment THEN env + 1 ELSE env

SetPc(r, p, v) == pc' = [pc EXCEPT ![r][p] = v]
Bump(f, r) == [f EXCEPT ![r] = IF @ < 2 THEN @ + 1 ELSE @]

\* Submit one reducer event for the row.
Apply(r, event) ==
    LET t == Reduce(rs[r], event, NoFacts)
    IN /\ IsApplied(t)
       /\ rs' = Upd(rs, r, t.state)

\* applyServerPrepFailure for a prep row, then the release of its poller.
FailRow(r, p, reason) ==
    /\ Apply(r, EvReason("prepFailed", reason))
    /\ poller' = Upd(poller, r, NoPoller)
    /\ SetPc(r, p, "idle")

-----------------------------------------------------------------------------
Init ==
    /\ exists = Const(Rows, TRUE)
    /\ rs = Const(Rows, InitialState("admitted"))
    /\ mode = Const(Rows, "prep")
    /\ disp = Const(Rows, FALSE)
    /\ ident = Const(Rows, FALSE)
    /\ intent = Const(Rows, "none")
    /\ strayIntent = Const(Rows, "none")
    /\ grace = Const(Rows, FALSE)
    /\ expired = Const(Rows, FALSE)
    /\ dayOut = Const(Rows, FALSE)
    /\ slotFree = TRUE
    /\ job = Const(Rows, "none")
    /\ stray = Const(Rows, "none")
    /\ render \in [Rows -> InitialRender]
    /\ post = Const(Rows, "none")
    /\ up = TRUE
    /\ poller = Const(Rows, NoPoller)
    /\ pc = Const(Rows, Const(Pollers, "idle"))
    /\ handoffs = Const(Rows, 0)
    /\ posts = Const(Rows, 0)
    /\ env = 0

-----------------------------------------------------------------------------
(* Attaching a poller                                                      *)

\* The start chain (triggerOptimizeAndDownload, triggerConvertAndDownload) and
\* the prep scanner (resumePendingServerPrepDownloads,
\* resumePendingEmbyConvertDownloadsAsync).  Both begin a poller only when
\* none is attached.
Attach(r, p) ==
    /\ up /\ exists[r] /\ mode[r] = "prep"
    /\ poller[r] = NoPoller /\ pc[r][p] = "idle"
    /\ IF IsPlex(r) THEN
          \* isPlexServerPrepResumeCandidate: a queued prep row.
          /\ Life(r) = "admitted"
          /\ poller' = Upd(poller, r, p)
          /\ SetPc(r, p, "poll")
          /\ UNCHANGED <<rowVars, journalVars>>
       ELSE
          \/ \* The start chain writes the `.preparing` seed, then looks for a
             \* version it can reuse.
             /\ Life(r) = "admitted"
             /\ Apply(r, Ev("prepReattached"))
             /\ poller' = Upd(poller, r, p)
             /\ SetPc(r, p, "preflight")
             /\ UNCHANGED <<exists, mode, disp, ident, journalVars>>
          \/ \* EmbyConvertRecoveryPolicy.relaunchAction: poll the known job.
             /\ Life(r) = "serverPrep" /\ ident[r]
             /\ poller' = Upd(poller, r, p)
             /\ SetPc(r, p, "prepoll")
             /\ UNCHANGED <<rowVars, journalVars>>
          \/ \* recover: a dispatched create with no job ID.  A row that an
             \* earlier recovery failed is reattached without a Retry.
             /\ Life(r) \in {"serverPrep", "failed"}
             /\ ~ident[r] /\ disp[r] /\ ~expired[r]
             /\ Apply(r, Ev("prepReattached"))
             /\ poller' = Upd(poller, r, p)
             /\ SetPc(r, p, "recover")
             /\ UNCHANGED <<exists, mode, disp, ident, journalVars>>
          \/ \* expireRecovery: journal the abandonment, then give up the
             \* identity and fail.  The job, if one exists, is no longer the
             \* row's.
             /\ Life(r) \in {"serverPrep", "failed"}
             /\ ~ident[r] /\ disp[r] /\ expired[r] /\ post[r] = "none"
             /\ Apply(r, EvReason("prepFailed", "server"))
             /\ disp' = Upd(disp, r, FALSE)
             /\ strayIntent' = Upd(strayIntent, r,
                                   IF job[r] = "active" THEN "pending" ELSE strayIntent[r])
             /\ UNCHANGED <<exists, mode, ident, intent, memVars>>
          \/ \* failMissingIdentity: the process died before any create was
             \* dispatched.
             /\ Life(r) = "serverPrep" /\ ~ident[r] /\ ~disp[r]
             /\ Apply(r, EvReason("prepFailed", "internalError"))
             /\ UNCHANGED <<exists, mode, disp, ident, journalVars, memVars>>
    /\ \* expireRecovery hands an unfinished job to the stray slot.
       IF ~IsPlex(r) /\ Life(r) \in {"serverPrep", "failed"}
          /\ ~ident[r] /\ disp[r] /\ expired[r] /\ post[r] = "none"
          THEN /\ job' = Upd(job, r, "none")
               /\ stray' = Upd(stray, r, IF job[r] = "active" THEN "active" ELSE stray[r])
               /\ expired' = Upd(expired, r, FALSE)
               /\ posts' = Upd(posts, r, 0)
               /\ UNCHANGED <<render, post, grace, dayOut, handoffs>>
          ELSE UNCHANGED <<serverVars, clockVars, ghostVars>>
    /\ UNCHANGED <<slotFree, up, env>>

\* A chain whose poller was detached (Pause, Delete, a failure, a newer
\* poller) ends at its next currency check.  A chain waiting for the create
\* response hears it first.
StaleExit(r, p) ==
    /\ up
    /\ pc[r][p] \notin {"idle", "awaitPost"}
    /\ ~Current(r, p)
    /\ ~(MutantHandoffUnchecked /\ pc[r][p] \in HandoffStates)
    /\ SetPc(r, p, "idle")
    /\ UNCHANGED <<rowVars, journalVars, clockVars, serverVars, slotFree, up, poller, ghostVars, env>>

-----------------------------------------------------------------------------
(* Plex optimize: pollForOptimizedPart                                     *)

\* The poll's decisions, as guards.
PlexAdopts(r) == render[r] /\ (FixB35 \/ disp[r])
PlexCreates(r) == (FixB35 => ~render[r]) /\ JobAbsent(r) /\ ~disp[r]
\* PlexOptimizePrepPolicy.action = failMissingCreate
ProvenMissing(r) == ~render[r] /\ JobAbsent(r) /\ disp[r] /\ grace[r]
PlexSeesFailedJob(r) == ~render[r] /\ job[r] = "failed"
\* A current poll has something to do other than wait.
PlexPollActs(r) ==
    PlexAdopts(r) \/ PlexCreates(r) \/ (FixB37 /\ ProvenMissing(r)) \/ PlexSeesFailedJob(r)
PlexPollDue(r) ==
    up /\ PlexPollActs(r) /\ \E p \in Pollers : pc[r][p] = "poll" /\ Current(r, p)

PlexPoll(r, p) ==
    /\ up /\ IsPlex(r) /\ pc[r][p] = "poll" /\ Current(r, p)
    /\ \/ \* A matching render is visible: adopt it, even past the render
          \* deadline.  B35 off: a fresh attempt creates first and looks only
          \* afterwards.
          /\ PlexAdopts(r)
          /\ SetPc(r, p, "found")
          /\ UNCHANGED <<rowVars, poller>>
       \/ \* PlexOptimizePrepPolicy.action = create: the queue item is proven
          \* absent and no create was ever dispatched.
          /\ PlexCreates(r)
          /\ SetPc(r, p, "dispatch")
          /\ UNCHANGED <<rowVars, poller>>
       \/ \* failMissingCreate: dispatched, still absent after the grace (B37).
          /\ FixB37
          /\ ProvenMissing(r)
          /\ FailRow(r, p, "server")
          /\ UNCHANGED <<exists, mode, disp, ident>>
       \/ \* The queue item reports a failed render.
          /\ PlexSeesFailedJob(r)
          /\ FailRow(r, p, "server")
          /\ UNCHANGED <<exists, mode, disp, ident>>
       \/ \* optimizeTimedOut: nothing is rendered and the 24 h deadline passed.
          /\ ~render[r] /\ dayOut[r]
          /\ FailRow(r, p, "server")
          /\ UNCHANGED <<exists, mode, disp, ident>>
    /\ UNCHANGED <<journalVars, clockVars, serverVars, slotFree, up, ghostVars, env>>

-----------------------------------------------------------------------------
(* Emby Convert: runConvertAndDownload, recoverAndResumeEmbyConvertJob,     *)
(* pollAndDownloadEmbyConvertJob                                            *)

EmbyPreflight(r, p) ==
    /\ up /\ ~IsPlex(r) /\ pc[r][p] = "preflight" /\ Current(r, p)
    /\ \/ \* A converted version already exists: hand it off, no job, and
          \* without waiting for a static slot.
          /\ render[r]
          /\ SetPc(r, p, "reuse")
       \/ \* Persist the baseline and go on to create.
          /\ ~render[r]
          /\ SetPc(r, p, "dispatch")
    /\ UNCHANGED <<rowVars, journalVars, clockVars, serverVars, slotFree, up, poller, ghostVars, env>>

EmbyRecover(r, p) ==
    /\ up /\ ~IsPlex(r) /\ pc[r][p] = "recover" /\ Current(r, p)
    /\ \/ \* Exactly one new job matches: adopt it.  adoptEmbyConvertJobID
          \* clears the dispatch identity in the same write.
          /\ ~JobAbsent(r)
          /\ ident' = Upd(ident, r, TRUE)
          /\ disp' = Upd(disp, r, FALSE)
          /\ SetPc(r, p, "prepoll")
          /\ UNCHANGED <<exists, rs, mode, poller>>
       \/ \* No match: fail and keep the identity, so Retry recovers again.
          /\ JobAbsent(r)
          /\ FailRow(r, p, "network")
          /\ UNCHANGED <<exists, mode, disp, ident>>
    /\ UNCHANGED <<journalVars, clockVars, serverVars, slotFree, up, ghostVars, env>>

\* Before the status loop: a converted version may already be visible.  The
\* attempt then abandons its own job for it, with a journaled cancel (B50).
EmbyPrepoll(r, p) ==
    /\ up /\ ~IsPlex(r) /\ pc[r][p] = "prepoll" /\ Current(r, p)
    /\ \/ /\ render[r]
          /\ intent' = Upd(intent, r, "pending")
          /\ SetPc(r, p, "found")
       \/ /\ SetPc(r, p, "poll")
          /\ UNCHANGED intent
    /\ UNCHANGED <<rowVars, strayIntent, clockVars, serverVars, slotFree, up, poller, ghostVars, env>>

EmbyPoll(r, p) ==
    /\ up /\ ~IsPlex(r) /\ pc[r][p] = "poll" /\ Current(r, p)
    /\ \/ \* Completed, and finishEmbyConvert finds the new source.
          /\ job[r] = "done" /\ render[r]
          /\ SetPc(r, p, "found")
          /\ UNCHANGED <<rowVars, poller, intent>>
       \/ \* Failed, cancelled or gone (404, 410): clear the job ID so Retry
          \* creates a fresh job, then fail.  An intent that names the dead
          \* job has nothing left to cancel.
          /\ job[r] = "failed" \/ JobAbsent(r)
          /\ ident' = Upd(ident, r, FALSE)
          /\ intent' = Upd(intent, r, "none")
          /\ FailRow(r, p, "server")
          /\ UNCHANGED <<exists, mode, disp>>
    /\ UNCHANGED <<strayIntent, clockVars, serverVars, slotFree, up, ghostVars, env>>

-----------------------------------------------------------------------------
(* The create request                                                      *)

\* Persist that a create is about to be dispatched: Plex
\* persistPlexOptimizeDispatch, Emby the dispatchAmbiguous write.  Plex runs
\* its stale-job sweep first (cleanStaleOptimizeJobs), which may journal the
\* cancel of a replaced attempt's job; the sweep is best effort.
Dispatch(r, p) ==
    /\ up /\ pc[r][p] = "dispatch" /\ Current(r, p)
    /\ disp' = Upd(disp, r, TRUE)
    /\ SetPc(r, p, "send")
    /\ \/ UNCHANGED strayIntent
       \/ /\ IsPlex(r) /\ stray[r] = "active"
          /\ strayIntent' = Upd(strayIntent, r, "pending")
    /\ UNCHANGED <<exists, rs, mode, ident, intent, clockVars, serverVars, slotFree, up, poller,
                   ghostVars, env>>

\* Hand the request to the network.  Both runners check currency after the
\* dispatch write returns (triggerOptimize's isStillCurrent; the action fence
\* in persistEmbyAttemptRecord) and send without suspending again.
Send(r, p) ==
    /\ up /\ pc[r][p] = "send" /\ Current(r, p)
    /\ post[r] = "none"
    /\ post' = Upd(post, r, "sent")
    /\ posts' = Bump(posts, r)
    /\ SetPc(r, p, "awaitPost")
    /\ UNCHANGED <<rowVars, journalVars, clockVars, job, stray, render, slotFree, up, poller,
                   handoffs, env>>

\* The create response reaches the chain that sent it.
Respond(r, p) ==
    /\ up /\ pc[r][p] = "awaitPost"
    /\ post[r] \in {"ok", "rejected", "failed"}
    /\ post' = Upd(post, r, "none")
    /\ IF Current(r, p) THEN
          IF post[r] = "ok" THEN
             \* markPlexOptimizeCreateConfirmed; Emby adopts the job ID.
             /\ ident' = Upd(ident, r, TRUE)
             /\ disp' = Upd(disp, r, IF IsPlex(r) THEN disp[r] ELSE FALSE)
             /\ SetPc(r, p, IF IsPlex(r) THEN "poll" ELSE "prepoll")
             /\ UNCHANGED <<exists, rs, mode, poller, job, intent>>
          ELSE IF IsPlex(r) /\ ~FixB37 THEN
             \* B37 off: the create error is swallowed and the poll goes on.
             /\ SetPc(r, p, "poll")
             /\ UNCHANGED <<rowVars, poller, job, intent>>
          ELSE
             \* The failure is surfaced.  Emby clears the dispatch identity
             \* only for a definitive refusal (createFailureDisposition).
             /\ FailRow(r, p, "server")
             /\ disp' = Upd(disp, r, IF ~IsPlex(r) /\ post[r] = "rejected" THEN FALSE ELSE disp[r])
             /\ UNCHANGED <<exists, mode, ident, job, intent>>
       ELSE
          /\ SetPc(r, p, "idle")
          /\ IF post[r] # "ok" \/ IsPlex(r) THEN
                \* A stale chain drops an error.  A stale Plex chain may still
                \* record that its create landed.
                /\ \E v \in {ident[r]} \cup
                            (IF IsPlex(r) /\ post[r] = "ok" /\ exists[r] /\ mode[r] = "prep"
                                THEN {TRUE} ELSE {}) :
                      ident' = Upd(ident, r, v)
                /\ UNCHANGED <<exists, rs, mode, disp, poller, job, intent>>
             \* EmbyConvertRecoveryPolicy.staleCreateDisposition
             ELSE IF ~exists[r] \/ mode[r] = "static" THEN
                \* cancel: the row is gone; journal the cancel of the new job.
                /\ intent' = Upd(intent, r, "pending")
                /\ UNCHANGED <<rowVars, poller, job>>
             ELSE IF ~ident[r] /\ Life(r) \in {"paused", "failed"} THEN
                IF FixB47 THEN
                   \* adoptOntoParkedRow
                   /\ ident' = Upd(ident, r, TRUE)
                   /\ disp' = Upd(disp, r, FALSE)
                   /\ UNCHANGED <<exists, rs, mode, poller, job, intent>>
                ELSE
                   \* B47 off: the job is cancelled and the parked row keeps
                   \* a dispatch identity that nothing can match any more.
                   /\ job' = Upd(job, r, "cancelled")
                   /\ UNCHANGED <<rowVars, poller, intent>>
             ELSE
                \* leaveToCurrentOwner: a newer poller is recovering the job,
                \* or the row already names it.
                UNCHANGED <<rowVars, poller, job, intent>>
    /\ UNCHANGED <<strayIntent, clockVars, stray, render, slotFree, up, ghostVars, env>>

-----------------------------------------------------------------------------
(* The hand-off to the static transfer                                     *)

\* startOptimizedPartDownload (Plex) and handoffEmbyConvertedSource (Emby):
\* one durable write turns the prep row into a static-range row.  Plex keeps
\* the attempt and starts its transfer; Emby replaces the attempt, and the
\* replacement names no job.
Handoff(r, p) ==
    /\ up /\ pc[r][p] \in HandoffStates
    \* awaitStaticHandoffRoom: a finished render keeps its prep slot until a
    \* static transfer slot is free.  The hand-off's own transfer then holds it.
    /\ pc[r][p] = "found" => slotFree
    /\ exists[r] /\ mode[r] = "prep"
    /\ MutantHandoffUnchecked \/ Current(r, p)
    /\ mode' = Upd(mode, r, "static")
    /\ handoffs' = Bump(handoffs, r)
    /\ poller' = Upd(poller, r, NoPoller)
    /\ SetPc(r, p, "idle")
    /\ IF ~Current(r, p) THEN
          \* MUTANT: an unchecked hand-off writes over whatever the row is.
          UNCHANGED <<rs, disp, ident>>
       ELSE IF IsPlex(r) THEN
          /\ Apply(r, Ev("transferStarted"))
          /\ UNCHANGED <<disp, ident>>
       ELSE
          /\ rs' = Upd(rs, r, InitialState("admitted"))
          /\ disp' = Upd(disp, r, FALSE)
          /\ ident' = Upd(ident, r, FALSE)
    /\ intent' = Upd(intent, r,
                     \* PROPOSED: Plex adopted a render that is not its own
                     \* finished job; journal the cancel of the create it
                     \* dispatched, as Emby does (B50).
                     IF AbandonJournalsCancel /\ IsPlex(r) /\ disp[r] /\ job[r] # "done"
                        THEN "pending" ELSE intent[r])
    /\ UNCHANGED <<exists, strayIntent, clockVars, serverVars, slotFree, up, posts, env>>

\* The hand-off is refused before it commits (the storage cap).
HandoffRefused(r, p) ==
    /\ up /\ pc[r][p] \in HandoffStates /\ Current(r, p)
    /\ EnvOK /\ EnvStep
    /\ FailRow(r, p, "storage")
    /\ UNCHANGED <<exists, mode, disp, ident, journalVars, clockVars, serverVars, slotFree, up, ghostVars>>

\* The poll gives up while the job may still be running: Plex after three
\* rejected credentials, Emby after its unreachable budget or a failed fetch.
\* The row keeps its identity.
PollFails(r, p) ==
    /\ up /\ pc[r][p] \in {"poll", "prepoll", "recover", "preflight"} /\ Current(r, p)
    /\ EnvOK /\ EnvStep
    /\ FailRow(r, p, "auth")
    /\ UNCHANGED <<exists, mode, disp, ident, journalVars, clockVars, serverVars, slotFree, up, ghostVars>>

-----------------------------------------------------------------------------
(* The server, the network and the clocks                                  *)

ServerAccepts(r) ==
    /\ post[r] = "sent"
    /\ post' = Upd(post, r, "ok")
    /\ job' = Upd(job, r, "active")
    /\ UNCHANGED <<rowVars, journalVars, clockVars, stray, render, slotFree, up, memVars, ghostVars, env>>

ServerRejects(r) ==
    /\ post[r] = "sent"
    /\ post' = Upd(post, r, "rejected")
    /\ UNCHANGED <<rowVars, journalVars, clockVars, job, stray, render, slotFree, up, memVars,
                   ghostVars, env>>

\* The request never arrives, or its response never comes back.
RequestLost(r) ==
    /\ post[r] = "sent"
    /\ post' = Upd(post, r, "failed")
    /\ UNCHANGED <<rowVars, journalVars, clockVars, job, stray, render, slotFree, up, memVars,
                   ghostVars, env>>

ResponseLost(r) ==
    /\ post[r] = "ok"
    /\ EnvOK /\ EnvStep
    /\ post' = Upd(post, r, "failed")
    /\ UNCHANGED <<rowVars, journalVars, clockVars, job, stray, render, slotFree, up, memVars, ghostVars>>

\* A response nobody waits for (the chain died with the process) is dropped.
DropResponse(r) ==
    /\ post[r] \in {"ok", "rejected", "failed"}
    /\ \A p \in Pollers : pc[r][p] # "awaitPost"
    /\ post' = Upd(post, r, "none")
    /\ UNCHANGED <<rowVars, journalVars, clockVars, job, stray, render, slotFree, up, memVars,
                   ghostVars, env>>

JobFinishes(r) ==
    /\ job[r] = "active"
    /\ job' = Upd(job, r, "done")
    /\ render' = Upd(render, r, TRUE)
    /\ UNCHANGED <<rowVars, journalVars, clockVars, stray, post, slotFree, up, memVars, ghostVars, env>>

JobFails(r) ==
    /\ job[r] = "active"
    /\ job' = Upd(job, r, "failed")
    /\ UNCHANGED <<rowVars, journalVars, clockVars, stray, render, post, slotFree, up, memVars,
                   ghostVars, env>>

\* Someone else removes the job (another client, a server restart).
JobVanishes(r) ==
    /\ job[r] \in {"active", "done", "failed"}
    /\ EnvOK /\ EnvStep
    /\ job' = Upd(job, r, "none")
    /\ UNCHANGED <<rowVars, journalVars, clockVars, stray, render, post, slotFree, up, memVars, ghostVars>>

StrayFinishes(r) ==
    /\ stray[r] = "active"
    /\ stray' = Upd(stray, r, "none")
    /\ render' = Upd(render, r, TRUE)
    /\ UNCHANGED <<rowVars, journalVars, clockVars, job, post, slotFree, up, memVars, ghostVars, env>>

GraceElapses(r) ==
    /\ IsPlex(r) /\ disp[r] /\ ~grace[r] /\ post[r] # "sent"
    /\ grace' = Upd(grace, r, TRUE)
    /\ UNCHANGED <<rowVars, journalVars, expired, dayOut, serverVars, slotFree, up, memVars, ghostVars, env>>

\* The Plex render deadline: a day after the prep began.  It does not pass
\* while a current poll has something to do.
DayElapses(r) ==
    /\ IsPlex(r) /\ exists[r] /\ mode[r] = "prep" /\ ~dayOut[r]
    /\ disp[r] => grace[r]
    /\ post[r] # "sent"
    /\ ~PlexPollDue(r)
    /\ dayOut' = Upd(dayOut, r, TRUE)
    /\ UNCHANGED <<rowVars, journalVars, grace, expired, serverVars, slotFree, up, memVars,
                   ghostVars, env>>

\* Other downloads take and release the static transfer slot.
SlotTaken ==
    /\ slotFree /\ EnvOK /\ EnvStep
    /\ slotFree' = FALSE
    /\ UNCHANGED <<rowVars, journalVars, clockVars, serverVars, up, memVars, ghostVars>>

SlotFrees ==
    /\ ~slotFree /\ SlotReturns
    /\ slotFree' = TRUE
    /\ UNCHANGED <<rowVars, journalVars, clockVars, serverVars, up, memVars, ghostVars, env>>

RecoveryExpires(r) ==
    /\ ~IsPlex(r) /\ disp[r] /\ ~ident[r] /\ ~expired[r] /\ post[r] # "sent"
    /\ expired' = Upd(expired, r, TRUE)
    /\ UNCHANGED <<rowVars, journalVars, grace, dayOut, serverVars, slotFree, up, memVars, ghostVars, env>>

-----------------------------------------------------------------------------
(* The user                                                                *)

\* DownloadPausePolicy.parkPreparing: park the row, release its poller.  The
\* server job keeps running.
UserPause(r) ==
    /\ up /\ PrepActive(r)
    /\ EnvOK /\ EnvStep
    /\ Apply(r, EvPause("user"))
    /\ poller' = Upd(poller, r, NoPoller)
    /\ UNCHANGED <<exists, mode, disp, ident, journalVars, clockVars, serverVars, slotFree, up, pc,
                   ghostVars>>

\* A replacement attempt: a new row with no server identity.  Any unfinished
\* job of the old identity stays on the server as a stray.
NewAttempt(r) ==
    /\ \A p \in Pollers : pc[r][p] = "idle"
    /\ post[r] = "none"
    /\ ~(stray[r] = "active" /\ job[r] = "active")
    /\ rs' = Upd(rs, r, InitialState("admitted"))
    /\ disp' = Upd(disp, r, FALSE)
    /\ ident' = Upd(ident, r, FALSE)
    /\ grace' = Upd(grace, r, FALSE)
    /\ expired' = Upd(expired, r, FALSE)
    /\ dayOut' = Upd(dayOut, r, FALSE)
    /\ posts' = Upd(posts, r, 0)
    /\ job' = Upd(job, r, "none")
    /\ stray' = Upd(stray, r, IF job[r] = "active" THEN "active" ELSE stray[r])
    /\ UNCHANGED <<exists, mode, intent, render, post, handoffs>>

\* resumePausedPlexServerPrep, and retry() for a paused Emby Convert row.
UserResume(r) ==
    /\ up /\ exists[r] /\ mode[r] = "prep" /\ Life(r) = "paused"
    /\ EnvOK /\ EnvStep
    /\ IF IsPlex(r) THEN
          /\ Apply(r, EvRetry("prepReattach"))
          /\ UNCHANGED <<exists, mode, disp, ident, journalVars, clockVars, serverVars,
                         ghostVars>>
       ELSE IF ident[r] \/ disp[r] THEN
          \* shouldResumePausedEmbyConvert
          /\ Apply(r, EvRetry("convertResume"))
          /\ UNCHANGED <<exists, mode, disp, ident, journalVars, clockVars, serverVars,
                         ghostVars>>
       ELSE
          /\ NewAttempt(r)
          /\ UNCHANGED strayIntent
    /\ UNCHANGED <<slotFree, up, memVars>>

\* retry() for a failed prep row.  Emby resumes the job the row still names.
\* Plex removes the row ("retry_replace") and starts over under a new queue
\* title; nothing is journaled for the old title (finding S1).
UserRetry(r) ==
    /\ up /\ exists[r] /\ mode[r] = "prep" /\ Life(r) = "failed"
    /\ EnvOK /\ EnvStep
    /\ IF ~IsPlex(r) /\ (ident[r] \/ disp[r]) THEN
          /\ Apply(r, EvRetry("convertResume"))
          /\ UNCHANGED <<exists, mode, disp, ident, journalVars, clockVars, serverVars,
                         ghostVars>>
       ELSE
          /\ NewAttempt(r)
          /\ strayIntent' = Upd(strayIntent, r,
                                \* PROPOSED: journal the cancel of the abandoned job.
                                IF AbandonJournalsCancel /\ job[r] = "active"
                                   THEN "pending" ELSE strayIntent[r])
    /\ UNCHANGED <<slotFree, up, memVars>>

\* delete(record:): the cancel of unfinished prep is journaled before the row
\* goes (D2).  A handed-off row owes nothing: its render is the download.
UserDelete(r) ==
    /\ up /\ exists[r]
    /\ EnvOK /\ EnvStep
    /\ exists' = Upd(exists, r, FALSE)
    /\ poller' = Upd(poller, r, NoPoller)
    /\ IF mode[r] = "static" THEN UNCHANGED <<intent, job>>
       ELSE IF FixB28 THEN
          \* plexOptimizeCleanupQueueTitle; hasEmbyConvertCleanupAuthority
          /\ intent' = Upd(intent, r,
                           IF IsPlex(r) \/ ident[r] \/ disp[r] THEN "pending" ELSE intent[r])
          /\ UNCHANGED job
       ELSE
          \* B28 off: a best-effort cancel, sent only for a row that is being
          \* prepared right now, and nothing journaled.
          /\ UNCHANGED intent
          /\ \/ UNCHANGED job
             \/ /\ PrepActive(r) /\ job[r] = "active"
                /\ job' = Upd(job, r, "cancelled")
    /\ UNCHANGED <<rs, mode, disp, ident, strayIntent, clockVars, stray, render, post, slotFree, up, pc,
                   ghostVars>>

-----------------------------------------------------------------------------
(* The cleanup runner                                                      *)

\* Execute the journaled cancel once no live row claims the job.  An
\* unfinished job is removed; a finished render stays (D2).  An intent whose
\* create may still land is kept.
RunnerRuns(r) ==
    /\ up /\ intent[r] = "pending" /\ ~Claims(r)
    /\ ~(JobAbsent(r) /\ post[r] = "sent")
    /\ intent' = Upd(intent, r, "none")
    /\ job' = Upd(job, r, IF job[r] = "active" THEN "cancelled" ELSE job[r])
    /\ UNCHANGED <<rowVars, strayIntent, clockVars, stray, render, post, slotFree, up, memVars,
                   ghostVars, env>>

StrayRunnerRuns(r) ==
    /\ up /\ strayIntent[r] = "pending"
    /\ strayIntent' = Upd(strayIntent, r, "none")
    /\ stray' = Upd(stray, r, "none")
    /\ UNCHANGED <<rowVars, intent, clockVars, job, render, post, slotFree, up, memVars, ghostVars, env>>

-----------------------------------------------------------------------------
(* Process death                                                           *)

Crash ==
    /\ up
    /\ EnvOK /\ EnvStep
    /\ up' = FALSE
    /\ poller' = Const(Rows, NoPoller)
    /\ pc' = Const(Rows, Const(Pollers, "idle"))
    /\ UNCHANGED <<rowVars, journalVars, clockVars, serverVars, slotFree, ghostVars>>

\* Relaunch runs reconcile (relaunchObserved) for every prep row; the scanner
\* (Attach) then reattaches.
Relaunch ==
    /\ ~up
    /\ up' = TRUE
    /\ rs' = [r \in Rows |->
                IF exists[r] /\ mode[r] = "prep"
                   THEN LET t == Reduce(rs[r], Ev("relaunchObserved"),
                                        Fx(Route(r), ident[r] \/ disp[r], "none", "none",
                                           FALSE, FALSE, FALSE, TRUE))
                        IN IF IsApplied(t) THEN t.state ELSE rs[r]
                   ELSE rs[r]]
    /\ UNCHANGED <<exists, mode, disp, ident, journalVars, clockVars, serverVars, slotFree,
                   memVars, ghostVars, env>>

-----------------------------------------------------------------------------
ChainStep(r, p) ==
    \/ Attach(r, p) \/ StaleExit(r, p) \/ PlexPoll(r, p)
    \/ EmbyPreflight(r, p) \/ EmbyRecover(r, p) \/ EmbyPrepoll(r, p) \/ EmbyPoll(r, p)
    \/ Dispatch(r, p) \/ Send(r, p) \/ Respond(r, p) \/ Handoff(r, p)

CreateResolves(r) == ServerAccepts(r) \/ ServerRejects(r) \/ RequestLost(r)
JobResolves(r) == JobFinishes(r) \/ JobFails(r)

Next ==
    \/ Crash \/ Relaunch \/ SlotTaken \/ SlotFrees
    \/ \E r \in Rows :
          \/ \E p \in Pollers : ChainStep(r, p) \/ HandoffRefused(r, p) \/ PollFails(r, p)
          \/ CreateResolves(r) \/ ResponseLost(r) \/ DropResponse(r)
          \/ JobResolves(r) \/ JobVanishes(r) \/ StrayFinishes(r)
          \/ GraceElapses(r) \/ RecoveryExpires(r) \/ DayElapses(r)
          \/ UserPause(r) \/ UserResume(r) \/ UserRetry(r) \/ UserDelete(r)
          \/ RunnerRuns(r) \/ StrayRunnerRuns(r)

Spec == Init /\ [][Next]_vars

\* Liveness: every chain step, the cleanup runner and Relaunch are weakly
\* fair; the server answers every create and ends every job; the clocks run
\* out; a static slot another download took is released.  The hand-off is
\* weakly fair only in the sense that it happens once a slot stays free.  The user, crashes, lost responses, vanishing jobs and poll failures
\* are not fair; BoundEnvironment makes them finite.
Fairness ==
    /\ WF_vars(Relaunch) /\ WF_vars(SlotFrees)
    /\ \A r \in Rows :
          /\ WF_vars(CreateResolves(r)) /\ WF_vars(JobResolves(r))
          /\ WF_vars(DropResponse(r)) /\ WF_vars(StrayFinishes(r))
          /\ WF_vars(GraceElapses(r)) /\ WF_vars(RecoveryExpires(r))
          /\ WF_vars(DayElapses(r))
          /\ WF_vars(RunnerRuns(r)) /\ WF_vars(StrayRunnerRuns(r))
          /\ WF_vars(\E p \in Pollers : Attach(r, p))
          /\ \A p \in Pollers :
                /\ WF_vars(StaleExit(r, p)) /\ WF_vars(PlexPoll(r, p))
                /\ WF_vars(EmbyPreflight(r, p)) /\ WF_vars(EmbyRecover(r, p))
                /\ WF_vars(EmbyPrepoll(r, p)) /\ WF_vars(EmbyPoll(r, p))
                /\ WF_vars(Dispatch(r, p)) /\ WF_vars(Send(r, p))
                /\ WF_vars(Respond(r, p)) /\ WF_vars(Handoff(r, p))

FairSpec == Spec /\ Fairness

-----------------------------------------------------------------------------
(* Properties                                                              *)

TypeOK ==
    /\ exists \in [Rows -> BOOLEAN]
    /\ \A r \in Rows : /\ DOMAIN rs[r] = StateFields
                       /\ rs[r].lifecycle \in Lifecycles
                       /\ rs[r].pauseCause \in PauseCauses
                       /\ rs[r].lastFailure \in FailureReasons
    /\ mode \in [Rows -> {"prep", "static"}]
    /\ disp \in [Rows -> BOOLEAN] /\ ident \in [Rows -> BOOLEAN]
    /\ intent \in [Rows -> {"none", "pending"}]
    /\ strayIntent \in [Rows -> {"none", "pending"}]
    /\ grace \in [Rows -> BOOLEAN] /\ expired \in [Rows -> BOOLEAN]
    /\ dayOut \in [Rows -> BOOLEAN] /\ slotFree \in BOOLEAN
    /\ job \in [Rows -> JobStates]
    /\ stray \in [Rows -> {"none", "active"}]
    /\ render \in [Rows -> BOOLEAN]
    /\ post \in [Rows -> PostStates]
    /\ up \in BOOLEAN
    /\ poller \in [Rows -> Pollers \cup {NoPoller}]
    /\ pc \in [Rows -> [Pollers -> ChainStates]]
    /\ handoffs \in [Rows -> 0..2] /\ posts \in [Rows -> 0..2]
    /\ env \in Nat

\* B35.  The app never decides to create a job in a poll that saw a matching
\* render.
CreateDecisionSeesNoRender ==
    [][\A r \in Rows, p \in Pollers :
          pc'[r][p] = "dispatch" /\ pc[r][p] # "dispatch" => ~render[r]]_vars

\* One identity, one create: a dispatched create is never sent again, across
\* relaunch, Pause and Resume, and repeated absent reads.
OneCreatePerIdentity == \A r \in Rows : posts[r] <= 1

\* The row is handed to the static lane at most once.
HandoffAtMostOnce == \A r \in Rows : handoffs[r] <= 1

\* A hand-off commits only for a row that is still being prepared: never for
\* a paused, failed or deleted one.
HandoffOnlyWhenActive ==
    [][\A r \in Rows : handoffs'[r] # handoffs[r] => PrepActive(r)]_vars

\* A parked, failed, handed-off or deleted row has no poller attached.
ParkedRowHasNoPoller ==
    \A r \in Rows : poller[r] # NoPoller => PrepActive(r)

\* B28, D2.  Once a prep row is deleted, an unfinished job of its identity, or
\* a create that may still produce one, is covered by a durable cancel intent.
DeletedPrepHasCancelIntent ==
    \A r \in Rows :
        ~exists[r] /\ mode[r] = "prep" /\ (job[r] = "active" \/ post[r] = "sent")
            => intent[r] = "pending"

\* S1.  An unfinished job the app has stopped addressing (its attempt was
\* replaced) is covered by a durable cancel intent.
ReplacedPrepHasCancelIntent ==
    \A r \in Rows : stray[r] = "active" => strayIntent[r] = "pending"

\* S1, the other half.  A row that was handed off leaves no unfinished job of
\* its own behind, and no create that may still produce one, without a
\* durable cancel intent.
HandedOffJobHasCancelIntent ==
    \A r \in Rows :
        mode[r] = "static" /\ (job[r] = "active" \/ post[r] = "sent")
            => intent[r] = "pending"

\* B47.  The app never cancels a job that a live prep row still names.
ClaimedJobNotCancelled ==
    [][\A r \in Rows :
          job'[r] = "cancelled" /\ job[r] # "cancelled" => ~Claims(r)]_vars

\* B37.  A create that is proven missing (dispatched, absent after the grace,
\* nothing rendered) fails the row then.  The render deadline never runs out
\* on a current poller that is watching such a row: before the fix it did,
\* a day later.
MissingCreateFailsBeforeDeadline ==
    [][\A r \in Rows :
          (dayOut'[r] /\ ~dayOut[r])
             => ~(up /\ ProvenMissing(r) /\ post[r] = "none"
                  /\ \E p \in Pollers : pc[r][p] = "poll" /\ Current(r, p))]_vars

\* A row that holds a render and waits for a static slot is not failed by
\* anything but the hand-off's own storage refusal: the render deadline, the
\* missing-create check and poll failures do not reach it.
WaitingForSlotFailsOnlyForStorage ==
    [][\A r \in Rows :
          (/\ up /\ up'
           /\ \E p \in Pollers : pc[r][p] = "found" /\ Current(r, p)
           /\ rs'[r].lifecycle = "failed")
             => rs'[r].lastFailure = "storage"]_vars

\* Preparation does not stay pending forever: once the environment stops,
\* every row is handed off, failed, paused or deleted.  With the fix off this
\* still holds, a day late: the render deadline fails the row.
PrepPending(r) ==
    exists[r] /\ mode[r] = "prep" /\ Life(r) \in {"admitted", "serverPrep"}
PrepSettles == \A r \in Rows : <>[](~PrepPending(r))
=============================================================================
