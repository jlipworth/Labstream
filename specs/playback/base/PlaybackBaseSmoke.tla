-------------------------- MODULE PlaybackBaseSmoke --------------------------
(***************************************************************************)
(* A smoke test of the base vocabulary, not a model of the app.  A toy     *)
(* client starts and stops sessions against the abstract server so that    *)
(* TLC type-checks every variable, takes every server action and shows     *)
(* that each shared judgement can fail.  It carries no MODELS line: none   *)
(* of its steps is PlaybackController's.                                   *)
(*                                                                         *)
(* The toy client keeps two rules: it starts a session only when it owns   *)
(* none, and it reuses a session id only when no stop for that id is in    *)
(* flight.  The second is not implied by the first: of two stops sent for  *)
(* one job, the first can end it while the second is still on the wire.    *)
(* With SmokeReplaces the client may also replace first and clean up       *)
(* after, as Jellyfin does, inside the window flag.  Every piece of        *)
(* cleanup it starts gets a ticket in pendingStops.  Each rule has a       *)
(* constant that turns it off; the Mutant configs flip them one at a time. *)
(***************************************************************************)
EXTENDS PlaybackControllerOps, TLC

CONSTANTS
    MaxStopSends,       \* stop requests each controller may send
    SmokeWaitsForStop,  \* TRUE: the two start rules above
    SmokeReplaces,      \* TRUE: the replace-then-clean-up order is allowed
    SmokeFlagsWindow,   \* TRUE: a replacement opens jellyfinWindow
    SmokeTicketsCleanup \* TRUE: cleanup is recorded in pendingStops

ASSUME /\ MaxStopSends \in Nat
       /\ {SmokeWaitsForStop, SmokeReplaces, SmokeFlagsWindow,
           SmokeTicketsCleanup} \subseteq BOOLEAN

vars == <<serverVars, ctlVars>>

Init == ServerInit /\ ControllerInit(1)

Tickets(c, new) ==
    Upd(pendingStops, c,
        IF SmokeTicketsCleanup THEN pendingStops[c] \cup new
        ELSE pendingStops[c])

TaskTicket(c) ==
    IF task[c] = NoTask THEN {} ELSE {TaskJoinTicket(task[c].gen)}
ProxyTicket(c) ==
    IF proxy[c].slot = 0 THEN {} ELSE {ProxyStopTicket(proxy[c].slot)}

-----------------------------------------------------------------------------
(* The toy client                                                          *)

\* A new attempt: cancel the task, bump the generation, start a session and
\* stand up a proxy for it.  The old proxy is left to stop by itself.
SmokeStart(c, s) ==
    /\ gen[c] < MaxGeneration
    /\ ~jellyfinWindow[c]
    /\ SmokeWaitsForStop => Owned(c) = {} /\ InFlight(s) = {}
    /\ StartJob(c, s)
    /\ gen' = Upd(gen, c, gen[c] + 1)
    /\ task' = Upd(task, c, Task(gen[c] + 1, "starting", s))
    /\ unwinding' = Upd(unwinding, c, UnwindingAfterCancel(c))
    /\ proxy' = Upd(proxy, c, [slot |-> gen[c] + 1,
                               live |-> proxy[c].live \cup {gen[c] + 1}])
    /\ pendingStops' = Tickets(c, TaskTicket(c) \cup ProxyTicket(c))
    /\ UNCHANGED <<itemGen, item, seekHold, budget, paused, jellyfinWindow>>

\* The task attaches its item if nothing superseded it.
SmokeAttach(c) ==
    /\ task[c] # NoTask
    /\ IsCurrent(c, task[c].gen)
    /\ item' = Upd(item, c, "attached")
    /\ itemGen' = Upd(itemGen, c, gen[c])
    /\ task' = Upd(task, c, NoTask)
    /\ seekHold' = Upd(seekHold, c, [seekHold[c] EXCEPT !.held = FALSE])
    /\ UNCHANGED <<serverVars, gen, unwinding, budget, paused, proxy,
                   pendingStops, jellyfinWindow>>

\* A seek takes the hold and spends budget; the user may pause or resume.
SmokeSeek(c) ==
    /\ seekHold[c].gen < MaxGeneration
    /\ budget[c] > 0
    /\ seekHold' = Upd(seekHold, c, [gen |-> seekHold[c].gen + 1,
                                     held |-> TRUE])
    /\ budget' = Upd(budget, c, budget[c] - 1)
    /\ \E p \in BOOLEAN : paused' = Upd(paused, c, p)
    /\ UNCHANGED <<serverVars, gen, itemGen, item, task, unwinding, proxy,
                   pendingStops, jellyfinWindow>>

\* Stop one running session: cancel the task, detach, clear the proxy slot
\* and send the stop.
SmokeStop(c, s) ==
    /\ s \in Live(c)
    /\ Cardinality({r \in stopReqs : r.c = c}) < MaxStopSends
    /\ SendStop(c, s)
    /\ item' = Upd(item, c, IF item[c] = "none" THEN "none" ELSE "detached")
    /\ task' = Upd(task, c, NoTask)
    /\ unwinding' = Upd(unwinding, c, UnwindingAfterCancel(c))
    /\ proxy' = Upd(proxy, c, [proxy[c] EXCEPT !.slot = 0])
    /\ pendingStops' =
           Tickets(c, {ServerStopTicket(NextStopReq(c, s, server[s].gen))}
                          \cup TaskTicket(c) \cup ProxyTicket(c))
    /\ UNCHANGED <<gen, itemGen, seekHold, budget, paused, jellyfinWindow>>

\* Replace before cleaning up: a second session while one is still owned.
SmokeReplace(c, s) ==
    /\ SmokeReplaces
    /\ ~jellyfinWindow[c]
    /\ Cardinality(Owned(c)) = 1
    /\ s \notin Live(c)
    /\ InFlight(s) = {}
    /\ StartJob(c, s)
    /\ jellyfinWindow' = Upd(jellyfinWindow, c, SmokeFlagsWindow)
    /\ UNCHANGED <<gen, itemGen, item, task, unwinding, seekHold, budget,
                   paused, proxy, pendingStops>>

SmokeWindowCloses(c) ==
    /\ jellyfinWindow[c]
    /\ Cardinality(Owned(c)) <= 1
    /\ jellyfinWindow' = Upd(jellyfinWindow, c, FALSE)
    /\ UNCHANGED <<serverVars, gen, itemGen, item, task, unwinding, seekHold,
                   budget, paused, proxy, pendingStops>>

\* A cancelled task returns.
SmokeUnwinds(c) ==
    /\ \E t \in unwinding[c] :
           unwinding' = Upd(unwinding, c, unwinding[c] \ {t})
    /\ UNCHANGED <<serverVars, gen, itemGen, item, task, seekHold, budget,
                   paused, proxy, pendingStops, jellyfinWindow>>

\* A listener that left the slot stops listening.
SmokeListenerStops(c) ==
    /\ \E g \in UnslottedListeners(c) :
           proxy' = Upd(proxy, c, [proxy[c] EXCEPT !.live = @ \ {g}])
    /\ UNCHANGED <<serverVars, gen, itemGen, item, task, unwinding, seekHold,
                   budget, paused, pendingStops, jellyfinWindow>>

Client(c) ==
    \/ \E s \in SessionIds :
           SmokeStart(c, s) \/ SmokeStop(c, s) \/ SmokeReplace(c, s)
    \/ SmokeAttach(c) \/ SmokeSeek(c) \/ SmokeWindowCloses(c)
    \/ SmokeUnwinds(c) \/ SmokeListenerStops(c)

Server ==
    /\ \/ \E s \in SessionIds :
              ServerAck(s) \/ ServerFail(s) \/ ServerRecreate(s)
       \/ ServerDelay
    /\ UNCHANGED ctlVars

Next == (\E c \in Controllers : Client(c)) \/ Server

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Properties                                                              *)

TypeOK == BaseTypeOK

\* When the pending stops are joined, no cleanup this controller started is
\* still running.  It holds only because every cleanup has a ticket.
JoinCoversCleanup ==
    \A c \in Controllers :
        PendingStopsJoined(c) =>
            /\ \A r \in stopReqs : r.c = c => r.status # "inFlight"
            /\ UnslottedListeners(c) = {}
            /\ unwinding[c] = {}

\* Reachability witnesses: each is the negation of a state that shows one
\* server action was taken.  Checked as invariants they must be violated
\* (see README.md); no config lists them.
NeverAcked == \A r \in stopReqs : r.status # "acked"
NeverFailedLost ==
    \A r \in stopReqs :
        r.status = "failed" =>
            ~(server[r.sid].gen = r.gen /\ server[r.sid].state = "encoding")
NeverFailedApplied ==
    \A r \in stopReqs :
        r.status = "failed" =>
            ~(server[r.sid].gen = r.gen /\ server[r.sid].state = "stopped"
              /\ \A q \in stopReqs : q.status # "acked")
NeverLate == \A r \in stopReqs : ~r.late
NeverLateThenAcked == \A r \in stopReqs : ~(r.late /\ r.status = "acked")
NeverRecreated == \A s \in SessionIds : ~server[s].serverRecreated
NeverInWindow == \A c \in Controllers : ~jellyfinWindow[c]
=============================================================================
