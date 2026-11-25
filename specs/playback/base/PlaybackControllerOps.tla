----------------------- MODULE PlaybackControllerOps -----------------------
(***************************************************************************)
(* The state of one PlaybackController, as every playback module names     *)
(* it, with the operators that read it and the shared property             *)
(* OneEncoder.  PlaybackBase holds the contract for writing a module.      *)
(*                                                                         *)
(* This module carries no MODELS line: it declares state and helpers and   *)
(* encodes no step of the controller.  The module that models              *)
(* PlaybackController.swift names it.                                      *)
(*                                                                         *)
(* All of this state is in memory.  It belongs to one controller, on the   *)
(* MainActor: a module models each MainActor run between two awaits as     *)
(* one atomic action.                                                      *)
(*                                                                         *)
(*   gen[c]           playbackGeneration.  Bumped by every restart, by     *)
(*                    stop() and by a surfaced failure; a continuation     *)
(*                    that captured an older value must give up.           *)
(*   itemGen[c]       the generation the player item was attached under,   *)
(*                    0 with no item yet.                                  *)
(*   item[c]          the AVPlayerItem: "none" before the first attach,    *)
(*                    "attached", or "detached" after                      *)
(*                    replaceCurrentItem(with: nil).                       *)
(*   task[c]          playbackTask, the current start or reopen task, or   *)
(*                    NoTask.                                              *)
(*   unwinding[c]     tasks that were cancelled and have not returned.     *)
(*                    Cancellation is cooperative: such a task runs on     *)
(*                    until its next check.                                *)
(*   seekHold[c]      PlaybackSeekHold: its latest generation and whether  *)
(*                    the scrubber is held.  This generation is the        *)
(*                    hold's own, not gen[c].                              *)
(*   budget[c]        restarts SeekRestartBudget still allows.             *)
(*   paused[c]        the user asked for pause.                            *)
(*   proxy[c]         the remote HLS proxy: `slot` is the generation of    *)
(*                    the proxy in remoteHLSProxy (0 for nil), `live`      *)
(*                    the generations whose loopback listener is still     *)
(*                    listening.  A listener outside the slot is one       *)
(*                    being stopped, or a leak.                            *)
(*   pendingStops[c]  pendingStopTasks: tickets for the cleanup that       *)
(*                    waitForPendingStopRequests joins.  Cleanup started   *)
(*                    without a ticket is not joined.                      *)
(*   jellyfinWindow[c] ghost: TRUE between the Jellyfin replacement        *)
(*                    request and the end of the prior session's deferred  *)
(*                    cleanup.  Only the Jellyfin module sets it.          *)
(***************************************************************************)
EXTENDS PlaybackBase

VARIABLES
    gen, itemGen, item, task, unwinding, seekHold, budget, paused, proxy,
    pendingStops, jellyfinWindow

ctlVars ==
    <<gen, itemGen, item, task, unwinding, seekHold, budget, paused, proxy,
      pendingStops, jellyfinWindow>>

-----------------------------------------------------------------------------
(* Vocabulary                                                              *)

ItemStates == {"none", "attached", "detached"}

\* A task: the generation it captured, where it is (the module's own
\* labels), and a session it negotiated and has not yet handed over.
Task(g, pc, s) == [gen |-> g, pc |-> pc, sid |-> s]
NoTask == Task(0, "none", NoSession)

IsTask(t) ==
    /\ t.gen \in Gens
    /\ t.pc \in STRING
    /\ t.sid \in SessionIds \cup {NoSession}

SeekHolds == [gen : Gens, held : BOOLEAN]
NoHold == [gen |-> 0, held |-> FALSE]

ProxyGens == 1..MaxGeneration
ProxyStates == [slot : Gens, live : SUBSET ProxyGens]
NoProxy == [slot |-> 0, live |-> {}]

\* What a pending stop task waits for.
StopKinds == {"serverStop", "proxyStop", "taskJoin"}

\* A stop request: pass NextStopReq(c, s, g) in the step that sends it.
ServerStopTicket(r) ==
    [kind |-> "serverStop", sid |-> r.sid, gen |-> r.gen, n |-> r.n]
\* proxy.stop(generation:) for the listener of generation g.
ProxyStopTicket(g) ==
    [kind |-> "proxyStop", sid |-> NoSession, gen |-> g, n |-> 0]
\* `await task.value` for the cancelled task that captured generation g.
TaskJoinTicket(g) ==
    [kind |-> "taskJoin", sid |-> NoSession, gen |-> g, n |-> 0]

IsTicket(t) ==
    /\ t.kind \in StopKinds
    /\ t.sid \in SessionIds \cup {NoSession}
    /\ t.gen \in Gens
    /\ t.n \in Nat

ControllerTypeOK ==
    /\ gen \in [Controllers -> Gens]
    /\ itemGen \in [Controllers -> Gens]
    /\ item \in [Controllers -> ItemStates]
    /\ \A c \in Controllers :
        /\ IsTask(task[c])
        /\ \A t \in unwinding[c] : IsTask(t)
        /\ \A t \in pendingStops[c] : IsTicket(t)
    /\ seekHold \in [Controllers -> SeekHolds]
    /\ budget \in [Controllers -> Gens]
    /\ paused \in [Controllers -> BOOLEAN]
    /\ proxy \in [Controllers -> ProxyStates]
    /\ jellyfinWindow \in [Controllers -> BOOLEAN]

BaseTypeOK == ServerTypeOK /\ ControllerTypeOK

\* Every controller starts idle with `restarts` in its budget.
ControllerInit(restarts) ==
    /\ gen = [c \in Controllers |-> 0]
    /\ itemGen = [c \in Controllers |-> 0]
    /\ item = [c \in Controllers |-> "none"]
    /\ task = [c \in Controllers |-> NoTask]
    /\ unwinding = [c \in Controllers |-> {}]
    /\ seekHold = [c \in Controllers |-> NoHold]
    /\ budget = [c \in Controllers |-> restarts]
    /\ paused = [c \in Controllers |-> FALSE]
    /\ proxy = [c \in Controllers |-> NoProxy]
    /\ pendingStops = [c \in Controllers |-> {}]
    /\ jellyfinWindow = [c \in Controllers |-> FALSE]

-----------------------------------------------------------------------------
(* Reading the controller                                                  *)

Upd(f, k, v) == [f EXCEPT ![k] = v]

\* isCurrentPlaybackLifecycle: a continuation that captured g may go on.
IsCurrent(c, g) == gen[c] = g

\* unwinding[c] after playbackTask?.cancel().
UnwindingAfterCancel(c) ==
    IF task[c] = NoTask THEN unwinding[c] ELSE unwinding[c] \cup {task[c]}

\* A task that captured g still runs, current or cancelled.
TaskRuns(c, g) ==
    \/ task[c] # NoTask /\ task[c].gen = g
    \/ \E t \in unwinding[c] : t.gen = g

\* Listeners that are not the proxy in the slot.
UnslottedListeners(c) == proxy[c].live \ {proxy[c].slot}

TicketDone(c, t) ==
    CASE t.kind = "serverStop" ->
            \A r \in StopsFor(c, t.sid, t.gen) :
                r.n = t.n => r.status # "inFlight"
      [] t.kind = "proxyStop" -> t.gen \notin proxy[c].live
      [] t.kind = "taskJoin" -> ~TaskRuns(c, t.gen)

\* waitForPendingStopRequests would return now.
PendingStopsJoined(c) == \A t \in pendingStops[c] : TicketDone(c, t)

-----------------------------------------------------------------------------
(* The shared property                                                     *)

\* At most one encoding session the client still owns per controller, and
\* two (the prior session and its replacement) inside Jellyfin's
\* replace-then-clean-up window.
OneEncoder ==
    \A c \in Controllers :
        Cardinality(Owned(c)) <= IF jellyfinWindow[c] THEN 2 ELSE 1
=============================================================================
