---------------------------- MODULE PlaybackBase ----------------------------
(***************************************************************************)
(* Shared vocabulary for the playback specs: the constants every module    *)
(* declares, the abstract server that holds encoding sessions, and the     *)
(* judgements about what a client still owns.  Every playback module       *)
(* EXTENDS PlaybackControllerOps, which extends this one, so the names     *)
(* below stay identical across models.                                     *)
(*                                                                         *)
(* This module carries no MODELS line.  The server is an abstraction of    *)
(* Plex, Jellyfin and Emby, not of a Swift file, and nothing here encodes  *)
(* controller behaviour.  The module that encodes a Swift file's           *)
(* behaviour names it (see 2 below).                                       *)
(*                                                                         *)
(* HOW TO WRITE A PLAYBACK MODULE                                          *)
(*                                                                         *)
(*  1. Name.  One subsystem is one folder, specs/playback/<folder>/,       *)
(*     holding Playback<Name>.tla, any helper module, its configs and its  *)
(*     notes (README.md).  This folder (base/) is shared:                  *)
(*     scripts/check-tla-specs.sh puts it on the TLA+ library path.  Do    *)
(*     not edit PlaybackBase, PlaybackControllerOps or another             *)
(*     subsystem's module: a base change is its own commit that every      *)
(*     module rebases onto.                                                *)
(*                                                                         *)
(*  2. Header.  Directly under the MODULE line, one line per Swift file    *)
(*     whose behaviour the module encodes, repository-relative:            *)
(*         \* MODELS: Labstream/Shared/Player/PlaybackController.swift     *)
(*     scripts/check-tla-drift.py reads these lines.                       *)
(*                                                                         *)
(*  3. Imports.  `EXTENDS PlaybackControllerOps, TLC`.  Every name these   *)
(*     two modules and Naturals and FiniteSets define is taken.            *)
(*                                                                         *)
(*  4. Constants.  Controllers (a set: one member by default, two in a     *)
(*     Deep-BackToBack config sharing the server), SessionIds,             *)
(*     MaxGeneration, RecreateCountsAgainstServer and IdsNeverShared are   *)
(*     declared here and every config assigns them: that line per config   *)
(*     is the cost of keeping both in one place.                           *)
(*     IdsNeverShared says whether two controllers can hold one session    *)
(*     id.  TRUE for Plex: the id is minted by the client, once per        *)
(*     controller (PlaybackController.sessionID).  For Jellyfin and Emby   *)
(*     the server mints the id and can return one it has used before,      *)
(*     which is why RemoteStreamLifecyclePolicy.priorSessionStopDecision   *)
(*     exists; whether it does so across two controllers is not            *)
(*     established.  A MediaBrowser config with two controllers chooses    *)
(*     the value and states its evidence in its comment line; FALSE is     *)
(*     the choice that hides nothing.  Each fix or ordering under test is  *)
(*     a BOOLEAN constant; TRUE is the shipping behaviour, so Faithful     *)
(*     and Mutant configs only flip constants.                             *)
(*                                                                         *)
(*  5. Variables.  There are two groups, and nothing is durable.           *)
(*       Remote    `server` and `stopReqs`, declared here.  They belong    *)
(*                 to the backend and the network.  They outlive every     *)
(*                 controller, which is why a session can be orphaned.     *)
(*       In memory every variable PlaybackControllerOps declares, and      *)
(*                 any a module adds.  They belong to one                  *)
(*                 PlaybackController and are gone when it is.  Playback   *)
(*                 has no state on disk in these models, so there is no    *)
(*                 Crash or Relaunch action.                               *)
(*     A module's Next is its own client actions (each with                *)
(*     UNCHANGED serverVars or one of the client requests below) and the   *)
(*     server actions, each with UNCHANGED ctlVars and the module's own    *)
(*     variables.                                                          *)
(*                                                                         *)
(*  6. What a guard may read.  A client guard reads only what the client   *)
(*     has: its own variables, and the stops it sent and what it heard of  *)
(*     them (SentStopFor, StopAckedFor, StopFailedFor, StopInFlightFor,    *)
(*     InFlightFrom, a `late` flag).  It never reads `server`, Live,       *)
(*     Owned, SentStop, WrongKill or a ghost field: those are judgements   *)
(*     for properties.  The one thing a client learns from the server      *)
(*     besides a stop's outcome is the job a start gave it: the step that  *)
(*     conjoins StartJob(c, s) stores NextIncarnation(s) in the module's   *)
(*     own state.  Every later stop, ticket and question about that job    *)
(*     uses the stored incarnation, never the current one: after the id    *)
(*     is reused, "the job under s" is a different job.                    *)
(*                                                                         *)
(*  7. What each action abstracts.                                         *)
(*       StartJob(c, s)       A start or negotiate request the server      *)
(*                            accepted: a universal-transcode start, or a  *)
(*                            PlaybackInfo answer with a transcoding URL.  *)
(*                            It adds a job: incarnation g of session id   *)
(*                            s, server[s][g].  A start under an id that   *)
(*                            still has a running job does not replace     *)
(*                            that job; both run until something stops     *)
(*                            them (the Plex pile-up of #27).              *)
(*                            With IdsNeverShared, it is disabled for an   *)
(*                            id another controller has used (4 above).    *)
(*       SendStopFor(c, s, g) The client puts a stop on the wire: a Plex   *)
(*                            transcode stop, or a MediaBrowser            *)
(*                            active-encoding cleanup.  g is the           *)
(*                            incarnation the client means, captured when  *)
(*                            it started that job.  "Receives a stop" in   *)
(*                            every property means this step happened.     *)
(*       ServerAck(s)         The server applies one stop for s and the    *)
(*                            client hears the acknowledgement.  A stop    *)
(*                            names a session id only, whatever job the    *)
(*                            client meant.  When several jobs run under   *)
(*                            the id, the model lets it end any non-empty  *)
(*                            set of them: which ones a backend ends was   *)
(*                            not established.  So an acknowledged stop    *)
(*                            ends the job the client meant only if no     *)
(*                            other job runs under that id, and a client   *)
(*                            cannot know that: a job whose stop was lost  *)
(*                            or that the server recreated still runs.     *)
(*       ServerFail(s)        One stop for s ends without an               *)
(*                            acknowledgement: lost on the way (the jobs   *)
(*                            run on), or applied with the answer lost.    *)
(*       ServerDelay          One stop becomes late: the client's bounded  *)
(*                            wait for it may now give up.  It can still   *)
(*                            be applied or fail afterwards.               *)
(*       ServerRecreate(s)    The server restarts a stopped job from a     *)
(*                            media request it had already accepted (the   *)
(*                            Jellyfin 2026-09-17 audit).  No client       *)
(*                            request causes it, so the job is flagged     *)
(*                            `serverRecreated` and judged against the     *)
(*                            server.                                      *)
(*     Not modelled: the encoder process (an acknowledgement does not      *)
(*     prove it exited), the server ending a job by itself, and requests   *)
(*     other than start and stop.                                          *)
(*                                                                         *)
(*  8. Ownership.  Live(c) is what the server runs for c.  Owned(c) is     *)
(*     the part of it the properties hold the client to: a job the client  *)
(*     started, still running, that the server did not recreate and whose  *)
(*     stop did not fail.  A stop in flight does not end ownership, so     *)
(*     starting a second job before the first stop resolves is two owned   *)
(*     jobs, under one id or two.  A failed stop does: the client sent     *)
(*     it, and what the server does after that counts against the server.  *)
(*     A module that must forbid a new encoder after an unconfirmed stop   *)
(*     states that over Live(c).  Both are sets of <<s, g>> pairs.         *)
(*                                                                         *)
(*  9. Configs.  specs/playback/<folder>/<Kind>-<What>.cfg, with the       *)
(*     kinds, the `\* SPEC:`, `\* EXPECT:` and `\* TIER: deep` headers     *)
(*     and the liveness rules of specs/README.md.  A config in base/       *)
(*     carries `Base-` in front and names its module on the SPEC line.     *)
(*     Every safety property has a Mutant config that violates it.         *)
(*                                                                         *)
(* 10. Findings.  Read the Swift before calling a counterexample a         *)
(*     finding.  A real one gets a Finding config; a modelling artefact    *)
(*     is fixed in the model.                                              *)
(*                                                                         *)
(* 11. Run.  scripts/check-tla-specs.sh specs/playback/<folder>, one run   *)
(*     at a time in a worktree.                                            *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    Controllers,    \* PlaybackController instances that share the server
    SessionIds,     \* session ids the server keys encoding jobs by
    MaxGeneration,  \* bound on every generation counter
    RecreateCountsAgainstServer,
        \* TRUE: a job the server recreated is the server's, not the
        \* client's (the judgement the design uses).  FALSE counts it as
        \* client-owned; Base-Mutant-RecreateCountsAgainstClient shows
        \* that judgement violates OneEncoder.
    IdsNeverShared
        \* TRUE: a session id belongs to the controller that first used it
        \* (contract, 4).  FALSE lets a second controller start under it.

ASSUME /\ IsFiniteSet(Controllers) /\ Controllers # {}
       /\ IsFiniteSet(SessionIds) /\ SessionIds # {}
       /\ MaxGeneration \in Nat \ {0}
       /\ RecreateCountsAgainstServer \in BOOLEAN
       /\ IdsNeverShared \in BOOLEAN

VARIABLES
    server,    \* remote: server[s][g], incarnation g of session id s
    stopReqs   \* remote: every stop request a client has sent

serverVars == <<server, stopReqs>>

-----------------------------------------------------------------------------
(* Vocabulary                                                              *)

\* Optional values are modelled with the string "none" for nil.
NoController == "none"
NoSession == "none"

Gens == 0..MaxGeneration
\* Incarnations of a job under one session id: 1 for the first start under
\* the id, one more for each later start.
Incarnations == 1..MaxGeneration
\* A job is a session id and an incarnation.
Jobs == SessionIds \X Incarnations

\* "stopRequested" is an encoding job with a stop in flight that means it.
ServerJobStates == {"none", "encoding", "stopRequested", "stopped"}
LiveStates == {"encoding", "stopRequested"}

\* server[s][g].  `gen` is g once the job exists, 0 before.
\* `serverRecreated` and `endedBy` are ghost fields: `endedBy` is the
\* incarnation the stop that ended this job was meant for, 0 while no stop
\* has ended it.
JobRecords ==
    [state : ServerJobStates, owner : Controllers \cup {NoController},
     gen : Gens, serverRecreated : BOOLEAN, endedBy : Gens]

NoJob ==
    [state |-> "none", owner |-> NoController, gen |-> 0,
     serverRecreated |-> FALSE, endedBy |-> 0]

\* A stop request.  `gen` is the incarnation the client meant; `n` tells
\* apart repeated stops for one incarnation; `late` is set by ServerDelay.
StopStatuses == {"inFlight", "acked", "failed"}

IsStopReq(r) ==
    /\ r.c \in Controllers
    /\ r.sid \in SessionIds
    /\ r.gen \in Incarnations
    /\ r.n \in Nat
    /\ r.status \in StopStatuses
    /\ r.late \in BOOLEAN

ServerTypeOK ==
    /\ server \in [SessionIds -> [Incarnations -> JobRecords]]
    /\ \A r \in stopReqs : IsStopReq(r)

ServerInit ==
    /\ server = [s \in SessionIds |-> [g \in Incarnations |-> NoJob]]
    /\ stopReqs = {}

-----------------------------------------------------------------------------
(* What a client has: the stops it sent and what it heard of them.         *)
(* Guards may read these (contract, 6).                                    *)

\* Stops c sent that mean incarnation g of s.
StopsFor(c, s, g) == {r \in stopReqs : r.c = c /\ r.sid = s /\ r.gen = g}

\* c sent a stop meant for incarnation g of s, whatever became of it.
SentStopFor(c, s, g) == StopsFor(c, s, g) # {}
StopAckedFor(c, s, g) == \E r \in StopsFor(c, s, g) : r.status = "acked"
StopFailedFor(c, s, g) == \E r \in StopsFor(c, s, g) : r.status = "failed"
StopInFlightFor(c, s, g) ==
    \E r \in StopsFor(c, s, g) : r.status = "inFlight"

\* Stops c sent under session id s that have not resolved, whichever
\* incarnation they meant.
InFlightFrom(c, s) ==
    {r \in stopReqs : r.c = c /\ r.sid = s /\ r.status = "inFlight"}

-----------------------------------------------------------------------------
(* Judgements.  For properties only: no guard reads them (contract, 6).    *)

InFlight(s) == {r \in stopReqs : r.sid = s /\ r.status = "inFlight"}

\* Incarnations started under s, and the newest of them (0 for none).
\* They are started in order, so the count is the newest.
Started(s) == {g \in Incarnations : server[s][g].state # "none"}
Latest(s) == Cardinality(Started(s))
\* The controller that first used the id.
IdOwner(s) == server[s][1].owner
\* Every job under an id has one owner.  Holds by construction with
\* IdsNeverShared; Base-Mutant-SharedId shows it fail without.
OneOwnerPerId ==
    \A s \in SessionIds, g \in Incarnations :
        server[s][g].owner \in {NoController, IdOwner(s)}

\* c sent a stop meant for the newest job under s.
SentStop(c, s) == SentStopFor(c, s, Latest(s))

\* The jobs the server is running that c started, recreated ones included.
Live(c) ==
    {j \in Jobs :
        /\ server[j[1]][j[2]].owner = c
        /\ server[j[1]][j[2]].state \in LiveStates}

\* The live jobs the properties hold c to (contract, 8).
Owned(c) ==
    {j \in Live(c) :
        /\ RecreateCountsAgainstServer
               => ~server[j[1]][j[2]].serverRecreated
        /\ ~StopFailedFor(c, j[1], j[2])}

\* A stop meant for an older incarnation ended job g of s: the successor
\* under a reused id.  A stop that also ends an older job is not one, and
\* a job the server recreated is judged as it is in Owned.
WrongKill(s, g) ==
    /\ server[s][g].endedBy # 0 /\ server[s][g].endedBy < g
    /\ RecreateCountsAgainstServer => ~server[s][g].serverRecreated
NoWrongKill == \A j \in Jobs : ~WrongKill(j[1], j[2])

-----------------------------------------------------------------------------
(* Client requests.  A client action conjoins one of these, or             *)
(* UNCHANGED serverVars.                                                   *)

\* `srv` with every running job marked by whether a stop in `reqs` that
\* means it is in flight.
Settled(srv, reqs) ==
    [s \in SessionIds |-> [g \in Incarnations |->
        IF srv[s][g].state \notin LiveStates THEN srv[s][g]
        ELSE [srv[s][g] EXCEPT !.state =
                 IF \E r \in reqs :
                        r.sid = s /\ r.gen = g /\ r.status = "inFlight"
                 THEN "stopRequested"
                 ELSE "encoding"]]]

\* The incarnation StartJob(c, s) creates: the step that starts a job
\* stores it (contract, 6).
NextIncarnation(s) == Latest(s) + 1

StartJob(c, s) ==
    /\ Latest(s) < MaxGeneration
    /\ IdsNeverShared => IdOwner(s) \in {NoController, c}
    /\ server' = Settled(
           [server EXCEPT ![s][NextIncarnation(s)] =
               [state |-> "encoding", owner |-> c,
                gen |-> NextIncarnation(s), serverRecreated |-> FALSE,
                endedBy |-> 0]],
           stopReqs)
    /\ UNCHANGED stopReqs

\* The request SendStopFor(c, s, g) adds: the handle a controller keeps.
NextStopReq(c, s, g) ==
    [c |-> c, sid |-> s, gen |-> g, n |-> Cardinality(StopsFor(c, s, g)),
     status |-> "inFlight", late |-> FALSE]

SendStopFor(c, s, g) ==
    /\ g \in Incarnations
    /\ stopReqs' = stopReqs \cup {NextStopReq(c, s, g)}
    /\ server' = Settled(server, stopReqs')

-----------------------------------------------------------------------------
(* Server actions.  Each is conjoined with UNCHANGED ctlVars and the       *)
(* module's own variables.                                                 *)

Resolved(r, status) ==
    (stopReqs \ {r}) \cup {[r EXCEPT !.status = status]}

LiveUnder(s) == {g \in Incarnations : server[s][g].state \in LiveStates}

\* What a stop for s may end: any non-empty set of the running jobs under
\* the id (contract, 7).
StopReach(s) ==
    IF LiveUnder(s) = {} THEN {{}} ELSE SUBSET LiveUnder(s) \ {{}}

\* `server` after stop r ended the incarnations in G under s.
EndedBy(s, G, r) ==
    [server EXCEPT ![s] = [g \in Incarnations |->
        IF g \in G
        THEN [server[s][g] EXCEPT !.state = "stopped", !.endedBy = r.gen]
        ELSE server[s][g]]]

ServerAck(s) ==
    \E r \in InFlight(s), G \in StopReach(s) :
        /\ stopReqs' = Resolved(r, "acked")
        /\ server' = Settled(EndedBy(s, G, r), stopReqs')

ServerFail(s) ==
    \E r \in InFlight(s), G \in StopReach(s) \cup {{}} :
        /\ stopReqs' = Resolved(r, "failed")
        /\ server' = Settled(EndedBy(s, G, r), stopReqs')

ServerDelay ==
    \E r \in stopReqs :
        /\ r.status = "inFlight" /\ ~r.late
        /\ stopReqs' = (stopReqs \ {r}) \cup {[r EXCEPT !.late = TRUE]}
        /\ UNCHANGED server

\* At most once per job, which keeps the model finite.
ServerRecreate(s) ==
    \E g \in Incarnations :
        /\ server[s][g].state = "stopped"
        /\ ~server[s][g].serverRecreated
        /\ server' = Settled(
               [server EXCEPT ![s][g].state = "encoding",
                              ![s][g].serverRecreated = TRUE],
               stopReqs)
        /\ UNCHANGED stopReqs
=============================================================================
