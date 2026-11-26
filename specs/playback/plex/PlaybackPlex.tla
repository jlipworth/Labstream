---------------------------- MODULE PlaybackPlex ----------------------------
\* MODELS: Labstream/Shared/Player/PlaybackController.swift
\* MODELS: Labstream/Shared/Networking/PlexClient.swift
\* MODELS: PMSKit/Sources/PMSKit/PlexSessionConfiguration.swift
\* MODELS: PMSKit/Sources/PMSKit/Transcode/TranscodeRequest.swift
(***************************************************************************)
(* The Plex replacement order.  A PlaybackController mints one sessionID   *)
(* and every transcode it starts runs under it.  An in-place restart       *)
(* (startStreaming with stoppingPreviousTranscode) is, in this order:      *)
(*                                                                         *)
(*   1. send /video/:/transcode/universal/stop?session=<id> and wait for   *)
(*      the answer, for at most two seconds (stopPreviousTranscode);       *)
(*   2. detach the old item, which stayed attached through the wait;       *)
(*   3. request the replacement under the same id;                         *)
(*   4. attach the new item (load).                                        *)
(*                                                                         *)
(* stop() and surfaceFailure send the same stop, detached and unawaited    *)
(* (sendTranscodeStop), behind the one-shot latch sentTranscodeStop.       *)
(* That request is a pendingStopTasks entry, which ends when the request   *)
(* is answered or its URLSession request timeout passes (5 s on the        *)
(* recovery client Retry switches to); a request that timed out stays on   *)
(* the wire.                                                               *)
(*                                                                         *)
(* Each MainActor run between two awaits is one action.                    *)
(*                                                                         *)
(*   User      UserQuality, Retry, Close, Approve, Decline                 *)
(*   Player    Fail, WarmRetry (the startup-deadline retry, which sends    *)
(*             no stop), PlayerNeedsConsent (the copy lane fails and the   *)
(*             rebuild asks for consent to encode)                         *)
(*   Timers    RetryProceeds (failureRetryTask after                       *)
(*             waitForPendingStopRequests)                                 *)
(*   Task      the playbackTask of one start or restart:                   *)
(*               begin       created, not yet run                          *)
(*               awaitStop   inside stopPreviousTranscode                  *)
(*               consentStop inside the stopPreviousTranscode of           *)
(*                           requestVideoTranscodeConsent                  *)
(*               negotiate   its start request is on the wire              *)
(*               negotiated  the server acted on it; the answer is on its  *)
(*                           way back                                      *)
(*             A cancelled task returns at its next check.                 *)
(*   Server    StartLands, ServerResolves (a stop is applied or fails),    *)
(*             ClockTicks (two seconds pass for a stop a task awaits, or   *)
(*             the request timeout for a detached stop)                    *)
(*                                                                         *)
(* What the restart core (specs/playback/restart) already covers is left   *)
(* out: seeks and their budget, pause intent, the loopback proxy and       *)
(* attach fencing.  The restart core leaves the consent boundary out too;  *)
(* this module models Plex's (ConsentPossible).  seekHold, budget,         *)
(* paused, proxy and jellyfinWindow never change here.                     *)
(***************************************************************************)
EXTENDS PlaybackControllerOps, TLC

CONSTANTS
    \* Bound.
    MaxUserActions,   \* quality changes and Retry taps

    \* What the run includes.
    EnvFails,         \* a start request or the player may fail
    RestartFromFailure,
        \* the user changes quality or track while a failure shows
    WarmRetries,      \* the startup-deadline retry
    StopsCanFail,     \* a stop may end unacknowledged
    StopsCanBeLate,   \* a stop may go unanswered for two seconds
    LateStarts,
        \* a start request may be overtaken by a stop sent after it, or
        \* land after its task was cancelled or its item detached
    ConsentPossible,
        \* the copy lane may fail on a playing item, and the rebuild ask
        \* for the user's consent to encode

    \* What the server does.  Not established for PMS; see the README.
    CancelledStopCanLand,
        \* a stop whose URLSession request the client cancelled may still
        \* be applied
    WarmStartJoinsJob,
        \* the startup-deadline retry's start is served by the job already
        \* running under the id (the premise of that retry)

    \* Shipping behaviour.  TRUE is the code as it stands.
    StopsPreviousFirst,     \* #27: stop the old job before a restart
    WaitsForPreviousStop,   \* the stop is awaited
    BoundedStopWait,        \* for at most two seconds
    DetachesBeforeStart,    \* #196: detach the old item after the wait
    RetryJoinsPendingStops,
    FailureRestartJoinsPendingStops,
        \* #530: a quality or track change while a failure shows joins
        \* pendingStopTasks first, as retry() does
    CloseSendsFinalStop,

    \* Proposed fixes.  FALSE is the code as it stands.
    FixStartAfterOwnStops,
        \* no start request goes out while a stop of this controller's is
        \* unanswered
    FixRestartResetsStopLatch
        \* every restart clears sentTranscodeStop, not only retry().
        \* Shipping since #527 (beginStreaming clears it): TRUE is the
        \* code as it stands; FALSE is the old latch.

ASSUME /\ MaxUserActions \in Nat
       /\ MaxGeneration >= 3
       /\ Cardinality(SessionIds) >= Cardinality(Controllers)
       /\ \A b \in {EnvFails, RestartFromFailure, WarmRetries, StopsCanFail,
                    StopsCanBeLate, LateStarts, CancelledStopCanLand,
                    WarmStartJoinsJob, StopsPreviousFirst,
                    WaitsForPreviousStop, BoundedStopWait,
                    DetachesBeforeStart, RetryJoinsPendingStops,
                    FailureRestartJoinsPendingStops,
                    CloseSendsFinalStop, FixStartAfterOwnStops,
                    FixRestartResetsStopLatch} :
              b \in BOOLEAN
       /\ ConsentPossible \in BOOLEAN

VARIABLES
    st,     \* in memory, per controller: what PlaybackController holds
    wire,   \* remote: start requests sent and not yet acted on
    ghost   \* per controller: bookkeeping for the properties.  No client
            \* action decides anything from it; `issued` also bounds the
            \* model.

ownVars == <<st, wire, ghost>>
\* Controller state this module never changes.
idleVars == <<seekHold, budget, paused, proxy, jellyfinWindow>>
vars == <<serverVars, ctlVars, ownVars>>

-----------------------------------------------------------------------------
(* Vocabulary                                                              *)

\* PlaybackController.sessionID: one per controller, minted by the client.
SidOf ==
    CHOOSE f \in [Controllers -> SessionIds] :
        \A a, b \in Controllers : a # b => f[a] # f[b]
Sid(c) == SidOf[c]

\* A start request is numbered in the order the client sent it.  The top
\* incarnation is never started (see Aim), so there is one start fewer
\* than incarnations.
Seqs == 0..(MaxGeneration - 1)

\* A stop is named by the incarnation it is aimed at and its count among
\* the stops aimed there, as in the base's request records.
StopIds == Incarnations \X Nat
NoStop == <<0, 0>>

TaskPcs == {"begin", "awaitStop", "consentStop", "negotiate", "negotiated"}
\* The places where a task awaits a stop in stopPreviousTranscode.
StopWaits == {"awaitStop", "consentStop"}

\* A playbackTask.  `gen` is the generation it captured.  `stopping` is
\* stoppingPreviousTranscode, `warm` marks the startup-deadline retry,
\* `ask` the copy-lane rebuild that asks for consent instead of starting,
\* `stop` is the stop it awaits and `seq` its start request.
PTask(g, stopping, warm, ask) ==
    [gen |-> g, pc |-> "begin", sid |-> NoSession, seq |-> 0,
     stop |-> NoStop, stopping |-> stopping, warm |-> warm, ask |-> ask]

IsPTask(t) ==
    /\ DOMAIN t = {"gen", "pc", "sid", "seq", "stop", "stopping", "warm",
                   "ask"}
    /\ t.ask \in BOOLEAN
    /\ t.gen \in 1..MaxGeneration
    /\ t.pc \in TaskPcs
    /\ t.sid = NoSession
    /\ t.seq \in Seqs
    /\ t.stop \in StopIds \cup {NoStop}
    /\ t.stopping \in BOOLEAN /\ t.warm \in BOOLEAN

\* st[c].  `latch` is sentTranscodeStop; `retryGen` the generation
\* failureRetryTask captured (0 for nil); `retryKind` what that task
\* restarts with: "retry" (retry()) or "restart" (a quality or track
\* change while a failure shows, FailureRestartJoinsPendingStops); `warmArmed` is
\* ~startupDeadlineRetryAttempted; `consent` is
\* videoTranscodeConsent.generation (0 for nil); `approved` is
\* videoTranscodeApprovedForCurrentItem.
StRecords ==
    [life : {"new", "open", "closed"}, failed : BOOLEAN, latch : BOOLEAN,
     retryGen : Gens, retryKind : {"retry", "restart"},
     warmArmed : BOOLEAN, userLeft : 0..MaxUserActions,
     consent : Gens, approved : BOOLEAN]

\* ghost[c].
\*   issued      start requests sent so far
\*   landed      the newest incarnation a start of this controller created
\*   itemSeq     the start request the attached item plays from
\*   jobSeq[g]   the start request that created incarnation g
\*   build       the newest start request that was not the
\*               startup-deadline retry's.  That retry asks again for
\*               what the request before it asked for.
\*   jobBuild[g] the `build` of the request that created incarnation g
\*   stopLog     every stop sent: its id and `at`, the value of `issued`
\*               when it went out.  A stop covers the starts sent before
\*               it and no start sent after it.
\*   cancelled   stops whose request the client cancelled: the bounded
\*               wait gave up, or the task awaiting it was cancelled
\*   wrongKills  how a stop that ended a job it does not cover had been
\*               left: "cancelled" or "live"
\*   finalStop   the stop Close sent
KillKinds == {"cancelled", "live"}

IsGhost(g) ==
    /\ DOMAIN g = {"issued", "landed", "itemSeq", "jobSeq", "build",
                   "jobBuild", "stopLog", "cancelled", "wrongKills",
                   "finalStop"}
    /\ g.issued \in Seqs /\ g.landed \in Seqs /\ g.itemSeq \in Seqs
    /\ g.jobSeq \in [Incarnations -> Seqs]
    /\ g.build \in Seqs
    /\ g.jobBuild \in [Incarnations -> Seqs]
    /\ \A e \in g.stopLog :
          /\ DOMAIN e = {"id", "at"}
          /\ e.id \in StopIds /\ e.at \in Seqs
    /\ g.cancelled \subseteq StopIds
    /\ g.wrongKills \subseteq KillKinds
    /\ g.finalStop \in StopIds \cup {NoStop}

\* A start request on the wire: its number, and the `build` it asks for.
WireRecords == [seq : Seqs \ {0}, build : Seqs \ {0}]

TypeOK ==
    /\ BaseTypeOK
    /\ st \in [Controllers -> StRecords]
    /\ wire \in [Controllers -> SUBSET WireRecords]
    /\ DOMAIN ghost = Controllers
    /\ \A c \in Controllers :
          /\ IsGhost(ghost[c])
          /\ task[c] = NoTask \/ IsPTask(task[c])
          /\ \A t \in unwinding[c] : IsPTask(t)

Init ==
    /\ ServerInit
    /\ ControllerInit(0)
    /\ st = [c \in Controllers |->
                [life |-> "new", failed |-> FALSE, latch |-> FALSE,
                 retryGen |-> 0, retryKind |-> "retry", warmArmed |-> TRUE,
                 userLeft |-> MaxUserActions, consent |-> 0,
                 approved |-> FALSE]]
    /\ wire = [c \in Controllers |-> {}]
    /\ ghost = [c \in Controllers |->
                   [issued |-> 0, landed |-> 0, itemSeq |-> 0,
                    jobSeq |-> [g \in Incarnations |-> 0], build |-> 0,
                    jobBuild |-> [g \in Incarnations |-> 0],
                    stopLog |-> {},
                    cancelled |-> {}, wrongKills |-> {},
                    finalStop |-> NoStop]]

-----------------------------------------------------------------------------
(* Reading the controller                                                  *)

Detached(c) == IF item[c] = "attached" THEN "detached" ELSE item[c]

\* The incarnation a stop sent now is recorded as aimed at.  A Plex stop
\* carries the session id and nothing else (TranscodeRequest.stop), so
\* this is bookkeeping for the base's judgements and not something the
\* client chooses: the newest job a start of this controller created, or,
\* when none has, the top incarnation, which no start ever reaches (Seqs).
\* A stop sent before any job exists therefore never counts as a stop for
\* a job that arrives later.
Blank == MaxGeneration
Aim(c) == IF ghost[c].landed = 0 THEN Blank ELSE ghost[c].landed

\* The stop a controller would send now, its id and its ticket.
NewStop(c) == NextStopReq(c, Sid(c), Aim(c))
NewStopId(c) == <<NewStop(c).gen, NewStop(c).n>>
SendStop(c) == SendStopFor(c, Sid(c), Aim(c))
LoggedStop(c) == [id |-> NewStopId(c), at |-> ghost[c].issued]

\* The request behind a stop id.
StopReq(c, id) ==
    {r \in StopsFor(c, Sid(c), id[1]) : r.n = id[2]}

\* stopPreviousTranscode returns: the stop was answered, or two seconds
\* passed.
StopWaitOver(c, id) ==
    \/ ~WaitsForPreviousStop
    \/ \A r \in StopReq(c, id) :
          r.status # "inFlight" \/ (BoundedStopWait /\ r.late)

\* A detached stop (a pendingStopTasks entry) ends when its request is
\* answered or its URLSession request timeout passes: `late` on such a
\* request is that timeout, and `try?` drops the error.
DetachedStop(r) == ServerStopTicket(r) \in pendingStops[r.c]
TimedOut(r) == r.late /\ DetachedStop(r)

\* waitForPendingStopRequests would return now.
Joined(c) ==
    \A k \in pendingStops[c] :
        IF k.kind = "serverStop"
        THEN \A r \in StopsFor(c, k.sid, k.gen) :
                r.n = k.n => (r.status # "inFlight" \/ r.late)
        ELSE TicketDone(c, k)

\* The stop a task awaits when it stops waiting with no answer: the wait
\* gave up, or the task was cancelled.  Either way the task group cancels
\* the request (group.cancelAll, or structured cancellation), and
\* PlexClient.send maps that to CancellationError.
\* With FixStartAfterOwnStops the stop is a tracked request that nothing
\* cancels, so its answer is one the client hears.
AbandonedStop(c, t) ==
    IF t # NoTask /\ t.pc \in StopWaits /\ WaitsForPreviousStop
       /\ ~FixStartAfterOwnStops
       /\ \E r \in StopReq(c, t.stop) : r.status = "inFlight"
    THEN {t.stop} ELSE {}

\* The start requests still on the wire after the current task is
\* cancelled.  Without LateStarts a cancelled request never reaches the
\* server, and the only request on the wire is the current task's.
WireAfterCancel(c) == IF LateStarts THEN wire[c] ELSE {}

-----------------------------------------------------------------------------
(* Pieces shared by several actions                                        *)

\* beginStreaming: playbackTask?.cancel(), playbackGeneration += 1 and the
\* new task.  The item stays attached and nothing is sent: the stop goes
\* out when the task first runs.  The startup-deadline retry detaches the
\* item itself before it calls beginStreaming.  The caller sets st.
RestartCore(c, stopping, warm, ask) ==
    /\ gen[c] + 2 <= MaxGeneration
    /\ ghost[c].issued + 1 < MaxGeneration
    /\ gen' = Upd(gen, c, gen[c] + 1)
    /\ unwinding' = Upd(unwinding, c, UnwindingAfterCancel(c))
    /\ task' = Upd(task, c, PTask(gen[c] + 1, stopping, warm, ask))
    /\ wire' = Upd(wire, c, WireAfterCancel(c))
    /\ item' = Upd(item, c, IF warm THEN Detached(c) ELSE item[c])
    /\ ghost' = [ghost EXCEPT ![c].cancelled = @ \cup AbandonedStop(c, task[c])]
    /\ UNCHANGED <<serverVars, itemGen, pendingStops, idleVars>>

\* What stop() and surfaceFailure share: the generation bump, the
\* cancelled task, the detach and sendTranscodeStop.  `inTask`: the
\* failure is raised by the current task, which then returns.  `join`:
\* the cancelled task is appended to pendingStopTasks.  `send`:
\* sendTranscodeStop is reached.  The caller sets st.
Terminal(c, inTask, join, send) ==
    LET sends == send /\ ~st[c].latch IN
    /\ gen[c] < MaxGeneration
    /\ gen' = Upd(gen, c, gen[c] + 1)
    /\ unwinding' =
           IF inTask THEN unwinding
           ELSE Upd(unwinding, c, UnwindingAfterCancel(c))
    /\ task' = Upd(task, c, NoTask)
    /\ wire' = Upd(wire, c, WireAfterCancel(c))
    /\ item' = Upd(item, c, Detached(c))
    /\ pendingStops' = Upd(pendingStops, c,
           pendingStops[c]
           \cup (IF join /\ ~inTask /\ task[c] # NoTask
                 THEN {TaskJoinTicket(task[c].gen)} ELSE {})
           \cup (IF sends THEN {ServerStopTicket(NewStop(c))} ELSE {}))
    /\ IF sends THEN SendStop(c) ELSE UNCHANGED serverVars
    /\ ghost' = [ghost EXCEPT
           ![c].cancelled =
               @ \cup (IF inTask THEN {} ELSE AbandonedStop(c, task[c])),
           ![c].stopLog = IF sends THEN @ \cup {LoggedStop(c)} ELSE @,
           ![c].finalStop =
               IF sends /\ ~join THEN NewStopId(c) ELSE @]
    /\ UNCHANGED <<itemGen, idleVars>>

\* surfaceFailure, past its `guard !playbackError.isFailed`.
SurfaceFailure(c, inTask) ==
    /\ Terminal(c, inTask, TRUE, TRUE)
    /\ st' = [st EXCEPT ![c].failed = TRUE, ![c].latch = TRUE]

-----------------------------------------------------------------------------
(* User, player and timers                                                 *)

\* start(): beginStreaming with stoppingPreviousTranscode false.
Start(c) ==
    /\ st[c].life = "new"
    /\ st' = [st EXCEPT ![c].life = "open"]
    /\ gen' = Upd(gen, c, 1)
    /\ task' = Upd(task, c, PTask(1, FALSE, FALSE, FALSE))
    /\ UNCHANGED <<serverVars, itemGen, item, unwinding, pendingStops,
                   idleVars, wire, ghost>>

\* reload(bitrateKbps:) and the audio and subtitle track changes:
\* restartAtCurrentPosition with an intent other than explicitRetry.
\* beginStreaming clears sentTranscodeStop (#527; before it only retry()
\* did).  reload clears
\* videoTranscodeApprovedForCurrentItem; a track change keeps it
\* (`isReload` picks which one the step is).  While a failure shows,
\* FailureRestartJoinsPendingStops (#530) makes the restart a
\* failureRetryTask that joins pendingStopTasks first (RetryProceeds);
\* without it the restart begins at once.
UserQuality(c) ==
    /\ st[c].life = "open"
    /\ st[c].userLeft > 0
    /\ st[c].failed => RestartFromFailure
    /\ \E isReload \in BOOLEAN :
        IF st[c].failed /\ FailureRestartJoinsPendingStops
        THEN /\ st' = [st EXCEPT
                   ![c].userLeft = @ - 1, ![c].retryGen = gen[c],
                   ![c].retryKind = "restart",
                   ![c].consent = 0, ![c].approved = @ /\ ~isReload]
             /\ UNCHANGED <<serverVars, ctlVars, wire, ghost>>
        ELSE /\ RestartCore(c, TRUE, FALSE, FALSE)
             /\ st' = [st EXCEPT
                   ![c].userLeft = @ - 1, ![c].retryGen = 0,
                   ![c].warmArmed = TRUE,
                   ![c].latch = IF FixRestartResetsStopLatch THEN FALSE ELSE @,
                   ![c].consent = 0, ![c].approved = @ /\ ~isReload]

\* retry(): failureRetryTask, which first joins pendingStopTasks.
Retry(c) ==
    /\ st[c].life = "open"
    /\ st[c].failed
    /\ st[c].retryGen = 0
    /\ st[c].userLeft > 0
    /\ st' = [st EXCEPT ![c].retryGen = gen[c], ![c].retryKind = "retry",
                        ![c].userLeft = @ - 1]
    /\ UNCHANGED <<serverVars, ctlVars, wire, ghost>>

\* failureRetryTask after `await waitForPendingStopRequests()`.  A task
\* that wakes to another generation returns and leaves failureRetryTask
\* set (the restart core's Finding-RetryWedgedByAttach); that is no step.
\* A "restart" task that wakes to another generation also takes no step,
\* where the Swift clears the slot; no action bumps the generation during
\* the wait without cancelling the task, so nothing is lost.
\* The join returns when every detached stop is answered or its request
\* timed out (Joined).  A "restart" task (a quality or track change while
\* the failure showed) restarts with that change's plan: it clears neither
\* the error nor, unless FixRestartResetsStopLatch (#527), sentTranscodeStop.
RetryProceeds(c) ==
    LET isRetry == st[c].retryKind = "retry" IN
    /\ st[c].retryGen # 0
    /\ st[c].retryGen = gen[c]
    /\ IF isRetry THEN RetryJoinsPendingStops => Joined(c)
                  ELSE Joined(c)
    /\ RestartCore(c, TRUE, FALSE, FALSE)
    /\ st' = [st EXCEPT
           ![c].retryGen = 0,
           ![c].latch = IF isRetry \/ FixRestartResetsStopLatch THEN FALSE
                        ELSE @,
           ![c].failed = IF isRetry THEN FALSE ELSE @,
           ![c].warmArmed = TRUE]

\* stop().
Close(c) ==
    /\ st[c].life = "open"
    /\ Terminal(c, FALSE, FALSE, CloseSendsFinalStop)
    /\ st' = [st EXCEPT
           ![c].life = "closed", ![c].retryGen = 0,
           ![c].latch = CloseSendsFinalStop \/ @, ![c].consent = 0]

\* The item fails or a watchdog fires: handlePlaybackFailure and the
\* timeouts that end in surfaceFailure.
Fail(c) ==
    /\ EnvFails
    /\ st[c].life = "open"
    /\ ~st[c].failed
    /\ item[c] = "attached" \/ task[c] # NoTask
    /\ SurfaceFailure(c, FALSE)

\* attemptStartupDeadlineRetry on the Plex lane: detach the abandoned
\* item and rebuild against the same session with no stop, once per armed
\* allowance.  Its triggers are item observers, which a restart removes,
\* so it fires only with an item and no restart under way.
WarmRetry(c) ==
    /\ WarmRetries
    /\ st[c].life = "open"
    /\ ~st[c].failed
    /\ st[c].warmArmed
    /\ item[c] = "attached"
    /\ task[c] = NoTask
    /\ RestartCore(c, FALSE, TRUE, FALSE)
    /\ st' = [st EXCEPT ![c].warmArmed = FALSE]

\* handlePlaybackFailure on a failed copy lane (directPlayFallbackArmed):
\* removeObservers and beginStreaming, whose startStreaming stops the
\* job, then finds the copy lane failed (suppressDirectPlayProbe) and
\* calls requestVideoTranscodeConsent instead of starting.  Not once the
\* user approved encoding for the item; the Original-quality condition
\* is not modelled.
PlayerNeedsConsent(c) ==
    /\ ConsentPossible
    /\ st[c].life = "open"
    /\ ~st[c].failed
    /\ ~st[c].approved
    /\ st[c].consent = 0
    /\ item[c] = "attached"
    /\ task[c] = NoTask
    /\ RestartCore(c, TRUE, FALSE, TRUE)
    /\ UNCHANGED st

\* approveVideoTranscoding: beginStreaming, an in-place restart.
Approve(c) ==
    /\ st[c].life = "open"
    /\ st[c].consent # 0 /\ st[c].consent = gen[c]
    /\ st[c].userLeft > 0
    /\ RestartCore(c, TRUE, FALSE, FALSE)
    /\ st' = [st EXCEPT
           ![c].consent = 0, ![c].approved = TRUE, ![c].userLeft = @ - 1,
           ![c].retryGen = 0, ![c].warmArmed = TRUE,
           ![c].latch = IF FixRestartResetsStopLatch THEN FALSE ELSE @]

\* declineVideoTranscoding: surfaceFailure.
Decline(c) ==
    /\ st[c].life = "open"
    /\ st[c].consent # 0 /\ st[c].consent = gen[c]
    /\ Terminal(c, FALSE, TRUE, TRUE)
    /\ st' = [st EXCEPT ![c].failed = TRUE, ![c].latch = TRUE,
                        ![c].consent = 0]

-----------------------------------------------------------------------------
(* The task                                                                *)

\* The task first runs: past its guard, an in-place restart sends the
\* stop and suspends in stopPreviousTranscode.
TaskSendsStop(c) ==
    /\ task[c] # NoTask
    /\ task[c].pc = "begin"
    /\ task[c].stopping /\ StopsPreviousFirst
    /\ SendStop(c)
    /\ task' = Upd(task, c,
           [task[c] EXCEPT !.pc = "awaitStop", !.stop = NewStopId(c)])
    /\ ghost' = [ghost EXCEPT ![c].stopLog = @ \cup {LoggedStop(c)}]
    /\ UNCHANGED <<gen, itemGen, item, unwinding, pendingStops, idleVars,
                   st, wire>>

\* The task reaches its start request: at once on the first start and on
\* the startup-deadline retry, otherwise when stopPreviousTranscode
\* returns, after which the old item is detached.  The awaits between
\* there and the request (stream selection, the decision) are folded into
\* this step.
\*
\* The request that starts a transcoder is the fetch of the session's
\* media playlist.  `early` FALSE: the task makes it and waits (the
\* Original lane's start.m3u8 fetch and prewarm).  `early` TRUE: the task
\* attaches the item and AVPlayer makes it (every capped quality).
\* Without LateStarts requests are served in the order sent, so the two
\* differ by nothing a stop could see and only the first is taken.
TaskIssuesStart(c, early) ==
    LET t == task[c]
        q == ghost[c].issued + 1
        b == IF t.warm /\ ghost[c].build # 0 THEN ghost[c].build ELSE q
        gaveUp == AbandonedStop(c, t)
        detached ==
            IF DetachesBeforeStart /\ t.stopping THEN Detached(c)
            ELSE item[c]
    IN
    /\ t # NoTask
    /\ ~t.ask
    /\ \/ t.pc = "begin" /\ ~(t.stopping /\ StopsPreviousFirst)
       \/ t.pc = "awaitStop" /\ StopWaitOver(c, t.stop)
    /\ FixStartAfterOwnStops => InFlightFrom(c, Sid(c)) = {}
    /\ q < MaxGeneration
    /\ early => LateStarts
    /\ wire' = Upd(wire, c, wire[c] \cup {[seq |-> q, build |-> b]})
    /\ IF early
       THEN \* load(): a new generation, a clean error surface.
            /\ gen[c] < MaxGeneration
            /\ gen' = Upd(gen, c, gen[c] + 1)
            /\ itemGen' = Upd(itemGen, c, gen[c] + 1)
            /\ item' = Upd(item, c, "attached")
            /\ task' = Upd(task, c, NoTask)
            /\ st' = [st EXCEPT ![c].failed = FALSE]
            /\ ghost' = [ghost EXCEPT
                   ![c].issued = q, ![c].itemSeq = q, ![c].build = b,
                   ![c].cancelled = @ \cup gaveUp]
       ELSE /\ item' = Upd(item, c, detached)
            /\ task' = Upd(task, c, [t EXCEPT !.pc = "negotiate", !.seq = q])
            /\ ghost' = [ghost EXCEPT
                   ![c].issued = q, ![c].build = b,
                   ![c].cancelled = @ \cup gaveUp]
            /\ UNCHANGED <<gen, itemGen, st>>
    /\ UNCHANGED <<serverVars, unwinding, pendingStops, idleVars>>

\* The copy-lane rebuild's task, past stopPreviousTranscode, its guard
\* and the detach (#196): the copy lane failed, so startStreaming calls
\* requestVideoTranscodeConsent, which detaches again and calls
\* stopPreviousTranscode a second time.  The first stop's result was
\* discarded; a request the wait gave up on was cancelled.
TaskAsksConsent(c) ==
    LET t == task[c] IN
    /\ t # NoTask
    /\ t.ask
    /\ \/ t.pc = "begin" /\ ~(t.stopping /\ StopsPreviousFirst)
       \/ t.pc = "awaitStop" /\ StopWaitOver(c, t.stop)
    /\ item' = Upd(item, c, Detached(c))
    /\ SendStop(c)
    /\ task' = Upd(task, c,
           [t EXCEPT !.pc = "consentStop", !.stop = NewStopId(c)])
    /\ ghost' = [ghost EXCEPT ![c].stopLog = @ \cup {LoggedStop(c)},
                              ![c].cancelled = @ \cup AbandonedStop(c, t)]
    /\ UNCHANGED <<gen, itemGen, unwinding, pendingStops, idleVars, st,
                   wire>>

\* requestVideoTranscodeConsent's stopPreviousTranscode returns, answered
\* or after two seconds, its result discarded (`try?`).  For Plex
\* mediaBrowserSession is nil, so the generation check follows and the
\* choice shows.
ConsentShows(c) ==
    LET t == task[c] IN
    /\ t # NoTask
    /\ t.pc = "consentStop"
    /\ StopWaitOver(c, t.stop)
    /\ task' = Upd(task, c, NoTask)
    /\ st' = [st EXCEPT ![c].consent = gen[c]]
    /\ ghost' = [ghost EXCEPT ![c].cancelled = @ \cup AbandonedStop(c, t)]
    /\ UNCHANGED <<serverVars, gen, itemGen, item, unwinding, pendingStops,
                   idleVars, wire>>

\* The current task's request fails.  Its catch surfaces the failure,
\* which does nothing when one is already showing.
StartFails(c) ==
    /\ EnvFails
    /\ task[c] # NoTask
    /\ task[c].pc = "negotiate"
    /\ IF st[c].failed
       THEN /\ task' = Upd(task, c, NoTask)
            /\ wire' = Upd(wire, c, WireAfterCancel(c))
            /\ UNCHANGED <<serverVars, gen, itemGen, item, unwinding,
                           pendingStops, idleVars, st, ghost>>
       ELSE SurfaceFailure(c, TRUE)

\* The answer reaches the current task, which passes its last check and
\* calls load().
TaskAttaches(c) ==
    /\ task[c] # NoTask
    /\ task[c].pc = "negotiated"
    /\ gen[c] < MaxGeneration
    /\ gen' = Upd(gen, c, gen[c] + 1)
    /\ itemGen' = Upd(itemGen, c, gen[c] + 1)
    /\ item' = Upd(item, c, "attached")
    /\ task' = Upd(task, c, NoTask)
    /\ st' = [st EXCEPT ![c].failed = FALSE]
    /\ ghost' = [ghost EXCEPT ![c].itemSeq = task[c].seq]
    /\ UNCHANGED <<serverVars, unwinding, pendingStops, idleVars, wire>>

\* A cancelled task wakes at a check and returns.  Every check of
\* startStreaming is a bare return: whatever its request created stays.
TaskUnwindExit(c, t) ==
    /\ t \in unwinding[c]
    /\ unwinding' = Upd(unwinding, c, unwinding[c] \ {t})
    /\ UNCHANGED <<serverVars, gen, itemGen, item, task, pendingStops,
                   idleVars, ownVars>>

TaskStep(c) ==
    \/ TaskSendsStop(c) \/ TaskAsksConsent(c) \/ ConsentShows(c)
    \/ TaskIssuesStart(c, FALSE) \/ TaskIssuesStart(c, TRUE)
    \/ TaskAttaches(c)
    \/ \E t \in unwinding[c] : TaskUnwindExit(c, t)

-----------------------------------------------------------------------------
(* Server                                                                  *)

\* The server acts on a start request.  It adds a job under the id
\* whatever already runs there (#27).  The exception is the one the
\* startup-deadline retry is designed on: a request that asks again for
\* what a running job was started for is served by that job.
StartLands(c, w) ==
    /\ w \in wire[c]
    /\ wire' = Upd(wire, c, wire[c] \ {w})
    /\ IF /\ WarmStartJoinsJob
          /\ \E g \in LiveUnder(Sid(c)) : ghost[c].jobBuild[g] = w.build
       THEN UNCHANGED <<serverVars, ghost>>
       ELSE /\ StartJob(c, Sid(c))
            /\ ghost' = [ghost EXCEPT
                   ![c].landed = NextIncarnation(Sid(c)),
                   ![c].jobSeq[NextIncarnation(Sid(c))] = w.seq,
                   ![c].jobBuild[NextIncarnation(Sid(c))] = w.build]
    /\ IF task[c] # NoTask /\ task[c].pc = "negotiate" /\ task[c].seq = w.seq
       THEN task' = Upd(task, c, [task[c] EXCEPT !.pc = "negotiated"])
       ELSE UNCHANGED task
    /\ UNCHANGED <<gen, itemGen, item, unwinding, pendingStops, idleVars, st>>

\* The stop request a base server action just changed, and the jobs it
\* ended.  Read after ServerAck, ServerFail or ServerDelay in the same
\* step.
TouchedReq == CHOOSE r \in stopReqs : r \notin stopReqs'
Ended(s) ==
    {g \in Incarnations :
        /\ server[s][g].state \in LiveStates
        /\ server'[s][g].state = "stopped"}
WasCancelled(r) == <<r.gen, r.n>> \in ghost[r.c].cancelled
SentAt(r) ==
    (CHOOSE e \in ghost[r.c].stopLog : e.id = <<r.gen, r.n>>).at

\* A stop is applied, or ends unacknowledged.  A request the client
\* cancelled, or whose URLSession request timed out, is answered to
\* nobody; without CancelledStopCanLand it is also never applied.  The
\* ghost records a job ended by a stop that was sent before the job's own
\* start request: "cancelled" for a request the client's own code
\* cancelled (the excuse the weaker properties make), "live" otherwise,
\* a timed-out detached stop included.
Dropped(r) == WasCancelled(r) \/ TimedOut(r)
ServerResolves(s) ==
    /\ \/ /\ ServerAck(s)
          /\ Dropped(TouchedReq) => CancelledStopCanLand
       \/ /\ ServerFail(s)
          /\ IF Dropped(TouchedReq)
             THEN CancelledStopCanLand \/ Ended(s) = {}
             ELSE StopsCanFail
    /\ LET r == TouchedReq
           wrong == {g \in Ended(s) : ghost[r.c].jobSeq[g] > SentAt(r)}
       IN ghost' = [ghost EXCEPT ![r.c].wrongKills =
              @ \cup (IF wrong = {} THEN {}
                      ELSE {IF WasCancelled(r) THEN "cancelled" ELSE "live"})]
    /\ UNCHANGED <<ctlVars, st, wire>>

\* Two seconds pass for a stop a task is awaiting, or the request timeout
\* for a detached stop (a pendingStopTasks entry).  For a stop nobody
\* awaits, late is no different from on time.
ClockTicks ==
    /\ StopsCanBeLate
    /\ ServerDelay
    /\ LET r == TouchedReq IN
       \/ /\ task[r.c] # NoTask /\ task[r.c].pc \in StopWaits
          /\ task[r.c].stop = <<r.gen, r.n>>
       \/ DetachedStop(r)
    /\ UNCHANGED <<ctlVars, ownVars>>

ServerStarts(c) == \E w \in wire[c] : StartLands(c, w)

Next ==
    \/ \E s \in SessionIds : ServerResolves(s)
    \/ ClockTicks
    \/ \E c \in Controllers :
          \/ Start(c) \/ UserQuality(c) \/ Retry(c) \/ RetryProceeds(c)
          \/ Close(c) \/ Fail(c) \/ StartFails(c) \/ WarmRetry(c)
          \/ PlayerNeedsConsent(c) \/ Approve(c) \/ Decline(c)
          \/ TaskStep(c)
          \/ ServerStarts(c)

Spec == Init /\ [][Next]_vars

\* The current task's own request is acted on.
CurrentStartLands(c) ==
    \E w \in wire[c] :
        /\ task[c] # NoTask /\ task[c].seq = w.seq
        /\ StartLands(c, w)

ClientFairness ==
    \A c \in Controllers :
        /\ WF_vars(TaskStep(c))
        /\ WF_vars(RetryProceeds(c))
        /\ WF_vars(CurrentStartLands(c))

\* Every stop is answered or fails.  The user, failures and the watchdog
\* are never forced.
FairSpec ==
    /\ Spec
    /\ ClientFairness
    /\ \A s \in SessionIds : WF_vars(ServerResolves(s))

\* No stop is ever forced to an answer; only the clock runs.  This is the
\* dead connection the two-second bound exists for.
ClockFairSpec == Spec /\ ClientFairness /\ WF_vars(ClockTicks)

-----------------------------------------------------------------------------
(* Properties                                                              *)

\* The incarnations the server holds that c's requests created.
JobsOf(c) == {g \in Incarnations : server[Sid(c)][g].owner = c}

\* A stop that ends a job covers it: it was sent after the job's own
\* start request.  A stop sent before that request was meant for what
\* came earlier, and ending the newer job with it is the late stop of
\* proxy-review finding C.
StopNeverKillsSuccessor ==
    \A c \in Controllers : ghost[c].wrongKills = {}

\* What the code as it stands keeps: the same for every stop but those
\* whose request the client had cancelled (the bounded wait gave up, or
\* the awaiting task was cancelled).
LiveStopNeverKillsSuccessor ==
    \A c \in Controllers : "live" \notin ghost[c].wrongKills

\* The jobs a cancelled, unanswered stop is aimed at.
CancelNamed(c) ==
    {<<Sid(c), r.gen>> : r \in {x \in InFlightFrom(c, Sid(c)) : WasCancelled(x)}}

\* What the code as it stands keeps of OneEncoder: one owned job, beside
\* those a cancelled and still unanswered stop was aimed at.
OneEncoderOutsideCancelledStops ==
    \A c \in Controllers : Cardinality(Owned(c) \ CancelNamed(c)) <= 1

\* #196: no start request goes out while an older item is still attached.
\* Requests are routed by session id alone, so that item's pending media
\* request would land on the replacement.
NoZombieItem ==
    \A c \in Controllers :
        item[c] = "attached" => ghost[c].itemSeq = ghost[c].issued

\* After Close, and while a failure shows with nothing under way, a stop
\* has been sent that covers every job this controller's requests
\* created.  "Sent" is the design's judgement: a stop that fails counts.
Covered(c, g) ==
    \E e \in ghost[c].stopLog : e.at >= ghost[c].jobSeq[g]
NoOrphans ==
    \A c \in Controllers :
        (\/ st[c].life = "closed"
         \/ st[c].failed /\ task[c] = NoTask /\ st[c].retryGen = 0)
        => \A g \in JobsOf(c) : Covered(c, g)

\* The same question asked of the server: once Close's stop is
\* acknowledged and nothing of this controller's is on the wire, the
\* server runs nothing for it.
FinalStopAcked(c) ==
    /\ ghost[c].finalStop # NoStop
    /\ \A r \in StopReq(c, ghost[c].finalStop) : r.status = "acked"
CleanAfterAckedClose ==
    \A c \in Controllers :
        (/\ st[c].life = "closed"
         /\ FinalStopAcked(c)
         /\ wire[c] = {}
         /\ InFlightFrom(c, Sid(c)) = {})
        => Live(c) = {}

\* While the consent choice shows, nothing is attached and no job the
\* client owns runs: "Stop any copy/audio-conversion job before
\* presenting the choice" (requestVideoTranscodeConsent).  A stop still
\* unanswered, cancelled or not, leaves its job owned.
ConsentShowing(c) == st[c].consent # 0 /\ st[c].consent = gen[c]
ConsentBoundary ==
    \A c \in Controllers :
        ConsentShowing(c) => item[c] # "attached" /\ Owned(c) = {}

-----------------------------------------------------------------------------
(* Route constraints.  A Finding config that must show one route to a      *)
(* violation, where a shorter route exists, names one as its CONSTRAINT.   *)

\* The consent route: the only user action is Approve (no quality change,
\* no Retry), and the Approve restart's own stop is answered within its
\* wait, so a stale stop that ends the encode is one the consent request
\* sent.
ConsentRoute ==
    \A c \in Controllers :
        /\ st[c].userLeft = MaxUserActions \/ st[c].approved
        /\ (st[c].approved /\ task[c] # NoTask /\ task[c].pc \in StopWaits)
           => \A r \in StopReq(c, task[c].stop) : ~r.late

-----------------------------------------------------------------------------
(* Liveness                                                                *)

\* A start or restart ends: it attaches, fails or is closed.  Under
\* ClockFairSpec this is what the two-second bound buys.
RestartSettles ==
    \A c \in Controllers : task[c] # NoTask ~> task[c] = NoTask

\* After Close every task returns and the joined cleanup ends.
CloseCleansUp ==
    \A c \in Controllers :
        st[c].life = "closed" ~> unwinding[c] = {} /\ Joined(c)

-----------------------------------------------------------------------------
(* Witnesses.  Each is the negation of a state one branch of the model     *)
(* reaches, so each is violated when checked as an invariant.  No config   *)
(* lists them; the README says how to repeat the check.                    *)

\* The restart core's DetachBeforeStop does not hold for a Plex restart:
\* a stop is on the wire while the item is attached.
NeverStopWhileAttached ==
    \A c \in Controllers :
        ~(item[c] = "attached" /\ InFlightFrom(c, Sid(c)) # {})
\* Nor does the second half of its GenerationFencing: an attached item
\* has a restart behind it.
NeverRestartBehindItem ==
    \A c \in Controllers : ~(item[c] = "attached" /\ task[c] # NoTask)
NeverTwoUnderOneId ==
    \A s \in SessionIds : Cardinality(LiveUnder(s)) < 2
\* A stop went out before any job existed.
NeverBlankStop ==
    \A r \in stopReqs : r.gen # Blank
NeverGaveUp ==
    \A c \in Controllers :
        ~(/\ task[c] # NoTask /\ task[c].pc = "negotiate"
          /\ task[c].stop \in ghost[c].cancelled)
NeverCancelledWait ==
    \A c \in Controllers :
        \A t \in unwinding[c] : t.stop \notin ghost[c].cancelled
NeverCancelledStopLands ==
    \A r \in stopReqs : ~(WasCancelled(r) /\ r.status = "acked")
NeverStopFailed ==
    \A r \in stopReqs : ~(~WasCancelled(r) /\ r.status = "failed")
\* The startup-deadline retry was served by the running job.
NeverWarmJoin ==
    \A c \in Controllers :
        ~(/\ item[c] = "attached"
          /\ \A g \in Incarnations : ghost[c].jobSeq[g] # ghost[c].itemSeq
          /\ \A w \in wire[c] : w.seq # ghost[c].itemSeq)
NeverRetryWaits ==
    \A c \in Controllers :
        ~(st[c].retryGen # 0 /\ ~Joined(c))
NeverRestartFromFailure ==
    \A c \in Controllers : ~(st[c].failed /\ task[c] # NoTask)
NeverConsentShown == \A c \in Controllers : ~ConsentShowing(c)
NeverDetachedTimedOut ==
    \A r \in stopReqs : ~(TimedOut(r) /\ r.status = "inFlight")
NeverLateStart ==
    \A c \in Controllers :
        \A w \in wire[c] : task[c] # NoTask /\ task[c].seq = w.seq
=============================================================================
