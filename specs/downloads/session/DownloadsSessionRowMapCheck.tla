-------------------- MODULE DownloadsSessionRowMapCheck --------------------
(***************************************************************************)
(* Checks the session model's row mapping (DownloadsSessionRowMap.tla)     *)
(* against the reducer, over the generated table's inputs.                 *)
(*                                                                         *)
(* The session stores SessionStored(s) and reduces SessionRow(stored).     *)
(* That is sound when, for every reducer state s, every event the session  *)
(* sends and every fact record,                                            *)
(*                                                                         *)
(*     Reduce(s, e, f)   and   Reduce(SessionRow(SessionStored(s)), e, f)  *)
(*                                                                         *)
(* are both accepted or both rejected the same way, carry the same         *)
(* effects, and store the same row.  By induction the stored row of the    *)
(* model then equals the stored projection of the real row along any       *)
(* sequence of those events.  Unlike Projection-SessionCore.cfg, which     *)
(* resets fields named in a config, this runs the operators the model      *)
(* itself uses, so an error in Row or ApplyRow fails here.                 *)
(*                                                                         *)
(* The table has two source keys and the session one: states and events    *)
(* of the table's second source are left out, and its first is renamed     *)
(* to the session's.                                                       *)
(***************************************************************************)
EXTENDS DownloadsReducerTable, DownloadsSessionRowMap, TLC

CONSTANTS
    UsedEventTypes,  \* the event types DownloadsSessionCore sends
    DropFromRow      \* "none", or a field SessionRow forgets (Mutant configs)

ASSUME /\ UsedEventTypes \subseteq EventTypes
       /\ DropFromRow \in StateFields \cup {"none"}

VARIABLE report

StateIx == 1..TableInputCount
EventIx == 1..Len(TableEvents)
FactIx == 1..Len(TableFacts)
RelaunchEvent == Ev("relaunchObserved")

Renamed(x) == IF x = "s1" THEN SessionSource ELSE x
OneSource(s) == s.source # "s2"
StateOf(s) == [TableStates[s] EXCEPT !.source = Renamed(@)]
EventOf(e) ==
    IF TableEvents[e].type = "finalizeOutcome"
       THEN [TableEvents[e] EXCEPT !.source = Renamed(@)] ELSE TableEvents[e]
UsedEvent(e) ==
    /\ TableEvents[e].type \in UsedEventTypes
    /\ TableEvents[e].type = "finalizeOutcome" => TableEvents[e].source # "s2"

\* The mapping under test: SessionRow, or SessionRow with one field dropped.
RowUnderTest(x) ==
    LET built == SessionRow(x)
    IN IF DropFromRow = "none" THEN built
       ELSE [built EXCEPT ![DropFromRow] = InitialState(built.lifecycle)[DropFromRow]]

Commutes(s, e, f) ==
    LET real == Reduce(s, e, f)
        model == Reduce(RowUnderTest(SessionStored(s)), e, f)
    IN /\ real.kind = model.kind
       /\ IsApplied(real) =>
            /\ real.effects = model.effects
            /\ SessionStored(real.state) = SessionStored(model.state)

EventFails(s, e) ==
    /\ OneSource(TableStates[s]) /\ UsedEvent(e)
    /\ ~Commutes(StateOf(s), EventOf(e), TableFacts[1])
RelaunchFails(s, f) ==
    /\ OneSource(TableStates[s]) /\ "relaunchObserved" \in UsedEventTypes
    /\ ~Commutes(StateOf(s), RelaunchEvent, TableFacts[f])

\* The first <<state, event>> and the first <<state, fact>> that do not
\* commute, if any: a wrong mapping fails on a large part of the table, and
\* one witness of each kind is enough to read.
Witness(A, B, Fails(_, _)) ==
    IF \E a \in A : \E b \in B : Fails(a, b)
       THEN LET a == CHOOSE x \in A : \E b \in B : Fails(x, b)
            IN {<<a, CHOOSE b \in B : Fails(a, b)>>}
       ELSE {}

Init == report = [events |-> Witness(StateIx, EventIx, EventFails),
                  relaunch |-> Witness(StateIx, FactIx, RelaunchFails)]
Next == UNCHANGED report
Spec == Init /\ [][Next]_report

\* The session's stored row follows the reducer.
RowMapSound == report.events = {} /\ report.relaunch = {}

\* The check is not vacuous: the table has states that set every field the
\* session keeps and every field it drops.
RowMapCovers ==
    /\ \E s \in StateIx : OneSource(TableStates[s]) /\ TableStates[s].strikes > 0
    /\ \E s \in StateIx : TableStates[s].bodyCondemned
    /\ \E s \in StateIx : TableStates[s].lastFailure # "none"
    /\ \E s \in StateIx : TableStates[s].unverifiedReason # "none"
    /\ \E e \in EventIx : UsedEvent(e) /\ TableEvents[e].type = "finalizeOutcome"
=============================================================================
