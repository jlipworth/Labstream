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
(*     MaxGeneration and RecreateCountsAgainstServer are declared here     *)
(*     and every config assigns them.  Each fix or ordering under test is  *)
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
(*     variables.  Ghost fields only observe: no guard reads them.         *)
(*                                                                         *)
(*  6. What each action abstracts.                                         *)
(*       StartJob(c, s)       A start or negotiate request the server      *)
(*                            accepted: a universal-transcode start, or a  *)
(*                            PlaybackInfo answer with a transcoding URL.  *)
(*                            The model keeps one job per session id: a    *)
(*                            start under an id that already has a job     *)
(*                            replaces it as a new incarnation.  Jobs      *)
(*                            piling up under one id are outside the       *)
(*                            model.                                       *)
(*       SendStopFor(c, s, g) The client puts a stop on the wire: a Plex   *)
(*                            transcode stop, or a MediaBrowser            *)
(*                            active-encoding cleanup.  g is the           *)
(*                            incarnation the client means, captured when  *)
(*                            it decided to stop, not when the request     *)
(*                            leaves.  "Receives a stop" in every          *)
(*                            property means this step happened.           *)
(*       ServerAck(s)         The server applies one stop for s and the    *)
(*                            client hears the acknowledgement.  A stop    *)
(*                            names a session id only, so it ends          *)
(*                            whatever job holds the id now.               *)
(*       ServerFail(s)        One stop for s ends without an               *)
(*                            acknowledgement: lost on the way (the job    *)
(*                            runs on), or applied with the answer lost.   *)
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
(*  7. Ownership.  Live(c) is what the server runs for c.  Owned(c) is     *)
(*     the part of it the properties hold the client to: a job the client  *)
(*     started, still running, that the server did not recreate and whose  *)
(*     stop did not fail.  A stop in flight does not end ownership, so     *)
(*     starting a second session before the first stop resolves is two     *)
(*     owned sessions.  A failed stop does: the client sent it, and what   *)
(*     the server does after that counts against the server.  A module     *)
(*     that must forbid a new encoder after an unconfirmed stop states     *)
(*     that over Live(c).                                                  *)
(*                                                                         *)
(*  8. Configs.  specs/playback/<folder>/<Kind>-<What>.cfg, with the       *)
(*     kinds, the `\* SPEC:`, `\* EXPECT:` and `\* TIER: deep` headers     *)
(*     and the liveness rules of specs/README.md.  A config in base/       *)
(*     carries `Base-` in front and names its module on the SPEC line.     *)
(*     Every safety property has a Mutant config that violates it.         *)
(*                                                                         *)
(*  9. Findings.  Read the Swift before calling a counterexample a         *)
(*     finding.  A real one gets a Finding config; a modelling artefact    *)
(*     is fixed in the model.                                              *)
(*                                                                         *)
(* 10. Run.  scripts/check-tla-specs.sh specs/playback/<folder>, one run   *)
(*     at a time in a worktree.                                            *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    Controllers,    \* PlaybackController instances that share the server
    SessionIds,     \* session ids the server keys encoding jobs by
    MaxGeneration,  \* bound on every generation counter
    RecreateCountsAgainstServer
        \* TRUE: a job the server recreated is the server's, not the
        \* client's (the judgement the design uses).  FALSE counts it as
        \* client-owned; Base-Mutant-RecreateCountsAgainstClient shows
        \* that judgement violates OneEncoder.

ASSUME /\ IsFiniteSet(Controllers) /\ Controllers # {}
       /\ IsFiniteSet(SessionIds) /\ SessionIds # {}
       /\ MaxGeneration \in Nat \ {0}
       /\ RecreateCountsAgainstServer \in BOOLEAN

VARIABLES
    server,    \* remote: server[s], the encoding job under session id s
    stopReqs   \* remote: every stop request a client has sent

serverVars == <<server, stopReqs>>

-----------------------------------------------------------------------------
(* Vocabulary                                                              *)

\* Optional values are modelled with the string "none" for nil.
NoController == "none"
NoSession == "none"

Gens == 0..MaxGeneration

\* "stopRequested" is an encoding job with a stop in flight that means it.
ServerJobStates == {"none", "encoding", "stopRequested", "stopped"}
LiveStates == {"encoding", "stopRequested"}

\* server[s].  `gen` is the incarnation of the job under this id: 0 before
\* the first start, one more for each start.  It tells a job from its
\* successor under a reused id.  `serverRecreated` and `endedBy` are ghost
\* fields: `endedBy` is the incarnation the stop that ended this job was
\* meant for, 0 while no stop has ended it.
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
    /\ r.gen \in Gens
    /\ r.n \in Nat
    /\ r.status \in StopStatuses
    /\ r.late \in BOOLEAN

ServerTypeOK ==
    /\ server \in [SessionIds -> JobRecords]
    /\ \A r \in stopReqs : IsStopReq(r)

ServerInit ==
    /\ server = [s \in SessionIds |-> NoJob]
    /\ stopReqs = {}

-----------------------------------------------------------------------------
(* Reading the server                                                      *)

InFlight(s) == {r \in stopReqs : r.sid = s /\ r.status = "inFlight"}

\* Stops c sent that mean incarnation g of s.
StopsFor(c, s, g) == {r \in stopReqs : r.c = c /\ r.sid = s /\ r.gen = g}

\* c sent a stop meant for incarnation g of s, whatever became of it.
SentStopFor(c, s, g) == StopsFor(c, s, g) # {}
\* c sent a stop meant for the job now under s.
SentStop(c, s) == SentStopFor(c, s, server[s].gen)

StopAcked(c, s) ==
    \E r \in StopsFor(c, s, server[s].gen) : r.status = "acked"
StopFailed(c, s) ==
    \E r \in StopsFor(c, s, server[s].gen) : r.status = "failed"
StopInFlight(c, s) ==
    \E r \in StopsFor(c, s, server[s].gen) : r.status = "inFlight"

\* The jobs the server is running that c started, recreated ones included.
Live(c) ==
    {s \in SessionIds :
        server[s].owner = c /\ server[s].state \in LiveStates}

\* The live jobs the properties hold c to (contract, 7).
Owned(c) ==
    {s \in Live(c) :
        /\ RecreateCountsAgainstServer => ~server[s].serverRecreated
        /\ ~StopFailed(c, s)}

\* A stop ended a job it was not meant for: the successor under a reused id.
WrongKill(s) == server[s].endedBy \notin {0, server[s].gen}
NoWrongKill == \A s \in SessionIds : ~WrongKill(s)

-----------------------------------------------------------------------------
(* Client requests.  A client action conjoins one of these, or             *)
(* UNCHANGED serverVars.                                                   *)

\* The state of a running job under s, given the stop requests `reqs`.
LiveStateWith(s, reqs) ==
    IF \E r \in reqs :
           r.sid = s /\ r.gen = server[s].gen /\ r.status = "inFlight"
    THEN "stopRequested"
    ELSE "encoding"

StartJob(c, s) ==
    /\ server[s].gen < MaxGeneration
    /\ server' = [server EXCEPT ![s] =
           [state |-> "encoding", owner |-> c, gen |-> server[s].gen + 1,
            serverRecreated |-> FALSE, endedBy |-> 0]]
    /\ UNCHANGED stopReqs

\* The request SendStopFor(c, s, g) adds: the handle a controller keeps.
NextStopReq(c, s, g) ==
    [c |-> c, sid |-> s, gen |-> g, n |-> Cardinality(StopsFor(c, s, g)),
     status |-> "inFlight", late |-> FALSE]

SendStopFor(c, s, g) ==
    /\ stopReqs' = stopReqs \cup {NextStopReq(c, s, g)}
    /\ server' =
           IF server[s].state = "encoding" /\ server[s].gen = g
           THEN [server EXCEPT ![s].state = "stopRequested"]
           ELSE server

\* A stop sent at once for the job now under s.
SendStop(c, s) == SendStopFor(c, s, server[s].gen)

-----------------------------------------------------------------------------
(* Server actions.  Each is conjoined with UNCHANGED ctlVars and the       *)
(* module's own variables.                                                 *)

Resolved(r, status) ==
    (stopReqs \ {r}) \cup {[r EXCEPT !.status = status]}

EndedBy(s, r) ==
    [server EXCEPT ![s].state = "stopped", ![s].endedBy = r.gen]

ServerAck(s) ==
    \E r \in InFlight(s) :
        /\ stopReqs' = Resolved(r, "acked")
        /\ server' =
               IF server[s].state \in LiveStates THEN EndedBy(s, r)
               ELSE server

ServerFail(s) ==
    \E r \in InFlight(s), applied \in BOOLEAN :
        LET reqs == Resolved(r, "failed") IN
        /\ stopReqs' = reqs
        /\ server' =
               IF server[s].state \notin LiveStates THEN server
               ELSE IF applied THEN EndedBy(s, r)
               ELSE [server EXCEPT ![s].state = LiveStateWith(s, reqs)]

ServerDelay ==
    \E r \in stopReqs :
        /\ r.status = "inFlight" /\ ~r.late
        /\ stopReqs' = (stopReqs \ {r}) \cup {[r EXCEPT !.late = TRUE]}
        /\ UNCHANGED server

\* At most once per incarnation, which keeps the model finite.
ServerRecreate(s) ==
    /\ server[s].state = "stopped"
    /\ ~server[s].serverRecreated
    /\ server' = [server EXCEPT ![s].state = LiveStateWith(s, stopReqs),
                                ![s].serverRecreated = TRUE]
    /\ UNCHANGED stopReqs
=============================================================================
