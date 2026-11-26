-------------------------- MODULE PlaybackBaseSmoke --------------------------
(***************************************************************************)
(* A smoke test of the base vocabulary, not a model of the app.  A toy     *)
(* client starts and stops sessions against the abstract server so that    *)
(* TLC type-checks every variable, takes every server action and shows     *)
(* that each shared judgement can fail.  It carries no MODELS line: none   *)
(* of its steps is PlaybackController's.                                   *)
(*                                                                         *)
(* The toy client follows the guard rule of the contract: it decides from  *)
(* `started` (the jobs it started, with the incarnation each start gave    *)
(* it) and from what it heard of its stops, never from the server's state  *)
(* or from Owned.  It keeps two rules.  It starts a job only when it       *)
(* holds none: every job it started has a stop that was acknowledged or    *)
(* failed.  And it never starts twice under one session id.  An            *)
(* acknowledged stop ends the job it was meant for only when no other job  *)
(* runs under that id, and the client cannot know that: an earlier job     *)
(* whose stop was lost, or that the server recreated, still runs there.    *)
(* SmokeReusesIds relaxes the second rule to the most careful reuse the    *)
(* client can manage (no stop of its own for the id in flight, and stops   *)
(* only for the newest job it started under the id); the Mutant config     *)
(* that sets it shows OneEncoder fail all the same.                        *)
(* With SmokeReplaces the client may also replace first and clean up       *)
(* after, as Jellyfin does, inside the window flag.  Every piece of        *)
(* cleanup it starts gets a ticket in pendingStops.  Each rule has a       *)
(* constant that turns it off; the Mutant configs flip them one at a time. *)
(***************************************************************************)
EXTENDS PlaybackControllerOps, TLC

CONSTANTS
    MaxStopSends,       \* stop requests each controller may send
    SmokeWaitsForStop,  \* TRUE: the two rules above
    SmokeReusesIds,     \* TRUE: careful reuse of an id replaces rule two
    SmokeReplaces,      \* TRUE: the replace-then-clean-up order is allowed
    SmokeFlagsWindow,   \* TRUE: a replacement opens jellyfinWindow
    SmokeTicketsCleanup \* TRUE: cleanup is recorded in pendingStops

ASSUME /\ MaxStopSends \in Nat
       /\ {SmokeWaitsForStop, SmokeReusesIds, SmokeReplaces, SmokeFlagsWindow,
           SmokeTicketsCleanup} \subseteq BOOLEAN

VARIABLE started  \* in memory: started[c], the jobs c started

vars == <<serverVars, ctlVars, started>>

Init ==
    /\ ServerInit
    /\ ControllerInit(1)
    /\ started = [c \in Controllers |-> {}]

\* The jobs c started and has not heard a stop outcome for.
Holding(c) ==
    {j \in started[c] :
        ~StopAckedFor(c, j[1], j[2]) /\ ~StopFailedFor(c, j[1], j[2])}

\* c may start under s as far as reuse of the id goes.
MayUse(c, s) ==
    IF SmokeReusesIds THEN InFlightFrom(c, s) = {}
    ELSE \A j \in started[c] : j[1] # s

\* The newest incarnation c started under s, 0 for none.
NewestStarted(c, s) ==
    LET G == {g \in Incarnations : <<s, g>> \in started[c]} IN
    IF G = {} THEN 0 ELSE CHOOSE g \in G : \A h \in G : h <= g

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
    /\ SmokeWaitsForStop => Holding(c) = {} /\ MayUse(c, s)
    /\ StartJob(c, s)
    /\ started' = Upd(started, c, started[c] \cup {<<s, NextIncarnation(s)>>})
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
                   pendingStops, jellyfinWindow, started>>

\* A seek takes the hold and spends budget; the user may pause or resume.
SmokeSeek(c) ==
    /\ seekHold[c].gen < MaxGeneration
    /\ budget[c] > 0
    /\ seekHold' = Upd(seekHold, c, [gen |-> seekHold[c].gen + 1,
                                     held |-> TRUE])
    /\ budget' = Upd(budget, c, budget[c] - 1)
    /\ \E p \in BOOLEAN : paused' = Upd(paused, c, p)
    /\ UNCHANGED <<serverVars, gen, itemGen, item, task, unwinding, proxy,
                   pendingStops, jellyfinWindow, started>>

\* Stop the newest job started under s, again if no acknowledgement was
\* heard: cancel the task, detach, clear the proxy slot and send the stop.
SmokeStop(c, s) ==
    /\ NewestStarted(c, s) # 0
    /\ ~StopAckedFor(c, s, NewestStarted(c, s))
    /\ Cardinality({r \in stopReqs : r.c = c}) < MaxStopSends
    /\ SendStopFor(c, s, NewestStarted(c, s))
    /\ item' = Upd(item, c, IF item[c] = "none" THEN "none" ELSE "detached")
    /\ task' = Upd(task, c, NoTask)
    /\ unwinding' = Upd(unwinding, c, UnwindingAfterCancel(c))
    /\ proxy' = Upd(proxy, c, [proxy[c] EXCEPT !.slot = 0])
    /\ pendingStops' =
           Tickets(c, {ServerStopTicket(
                          NextStopReq(c, s, NewestStarted(c, s)))}
                          \cup TaskTicket(c) \cup ProxyTicket(c))
    /\ UNCHANGED <<gen, itemGen, seekHold, budget, paused, jellyfinWindow,
                   started>>

\* Replace before cleaning up: a second job, under another id, while one
\* is still held.
SmokeReplace(c, s) ==
    /\ SmokeReplaces
    /\ ~jellyfinWindow[c]
    /\ Cardinality(Holding(c)) = 1
    /\ \A j \in Holding(c) : j[1] # s
    /\ MayUse(c, s)
    /\ StartJob(c, s)
    /\ started' = Upd(started, c, started[c] \cup {<<s, NextIncarnation(s)>>})
    /\ jellyfinWindow' = Upd(jellyfinWindow, c, SmokeFlagsWindow)
    /\ UNCHANGED <<gen, itemGen, item, task, unwinding, seekHold, budget,
                   paused, proxy, pendingStops>>

SmokeWindowCloses(c) ==
    /\ jellyfinWindow[c]
    /\ Cardinality(Holding(c)) <= 1
    /\ jellyfinWindow' = Upd(jellyfinWindow, c, FALSE)
    /\ UNCHANGED <<serverVars, gen, itemGen, item, task, unwinding, seekHold,
                   budget, paused, proxy, pendingStops, started>>

\* A cancelled task returns.
SmokeUnwinds(c) ==
    /\ \E t \in unwinding[c] :
           unwinding' = Upd(unwinding, c, unwinding[c] \ {t})
    /\ UNCHANGED <<serverVars, gen, itemGen, item, task, seekHold, budget,
                   paused, proxy, pendingStops, jellyfinWindow,
                   started>>

\* A listener that left the slot stops listening.
SmokeListenerStops(c) ==
    /\ \E g \in UnslottedListeners(c) :
           proxy' = Upd(proxy, c, [proxy[c] EXCEPT !.live = @ \ {g}])
    /\ UNCHANGED <<serverVars, gen, itemGen, item, task, unwinding, seekHold,
                   budget, paused, pendingStops, jellyfinWindow,
                   started>>

Client(c) ==
    \/ \E s \in SessionIds :
           SmokeStart(c, s) \/ SmokeStop(c, s) \/ SmokeReplace(c, s)
    \/ SmokeAttach(c) \/ SmokeSeek(c) \/ SmokeWindowCloses(c)
    \/ SmokeUnwinds(c) \/ SmokeListenerStops(c)

Server ==
    /\ \/ \E s \in SessionIds :
              ServerAck(s) \/ ServerFail(s) \/ ServerRecreate(s)
       \/ ServerDelay
    /\ UNCHANGED <<ctlVars, started>>

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
\* server action, or one branch of it, was taken.  Checked as invariants
\* they must be violated (see README.md); no config lists them.
JobOf(r) == server[r.sid][r.gen]
NeverAcked == \A r \in stopReqs : r.status # "acked"
NeverFailedLost ==
    \A r \in stopReqs : r.status = "failed" => JobOf(r).state # "encoding"
NeverFailedApplied ==
    \A r \in stopReqs :
        r.status = "failed" =>
            ~(JobOf(r).state = "stopped"
              /\ \A q \in stopReqs : q.status # "acked")
NeverLate == \A r \in stopReqs : ~r.late
NeverLateThenAcked == \A r \in stopReqs : ~(r.late /\ r.status = "acked")
NeverRecreated == \A j \in Jobs : ~server[j[1]][j[2]].serverRecreated
NeverInWindow == \A c \in Controllers : ~jellyfinWindow[c]
\* Two jobs run under one id; a stop ends only the newest of them; a stop
\* meant for the newest ends only an older one.
NeverTwoUnderOneId == \A s \in SessionIds : Cardinality(LiveUnder(s)) < 2
NeverEndsNewestOnly ==
    \A s \in SessionIds, g \in Incarnations :
        ~(server[s][g].state \in LiveStates
          /\ \E h \in Incarnations : h > g /\ server[s][h].endedBy = h)
NeverEndsOlderOnly ==
    \A s \in SessionIds, g \in Incarnations, h \in Incarnations :
        ~(g < h /\ server[s][g].endedBy = h
          /\ server[s][h].state \in LiveStates /\ server[s][h].endedBy = 0)
=============================================================================
