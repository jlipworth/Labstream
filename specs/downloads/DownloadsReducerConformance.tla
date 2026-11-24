--------------------- MODULE DownloadsReducerConformance ---------------------
(***************************************************************************)
(* Checks DownloadsReducer.tla against the table generated from the Swift  *)
(* reducer (DownloadsReducerTable.tla).  There is no behaviour to explore: *)
(* the one state holds the rows that disagree, so a failing run prints     *)
(* them.                                                                   *)
(*                                                                         *)
(* Reducer-Conformance.cfg      TableMatches and TableCovers.              *)
(* Projection-<Module>.cfg      ProjectionSound, for a module that tracks  *)
(*                              only TrackedFields of the reducer state    *)
(*                              and sends only UsedEventTypes.             *)
(*                                                                         *)
(* Reading a failure: `events` holds <<s, e>> pairs and `relaunch` holds   *)
(* <<s, f>> pairs.  s, e and f are the line indices of TableStates,        *)
(* TableEvents and TableFacts in DownloadsReducerTable.tla.                *)
(***************************************************************************)
EXTENDS DownloadsReducerTable, TLC

CONSTANTS
    TrackedFields,   \* the reducer state fields a module keeps (ProjectionSound)
    UsedEventTypes   \* the event types that module sends (ProjectionSound)

ASSUME /\ TrackedFields \subseteq StateFields
       /\ UsedEventTypes \subseteq EventTypes

VARIABLE report

StateIx == 1..TableInputCount
EventIx == 1..Len(TableEvents)
FactIx == 1..Len(TableFacts)
RelaunchEvent == Ev("relaunchObserved")

\* The rows where Reduce and the Swift reducer disagree.
EventMismatches ==
    {<<s, e>> \in StateIx \X EventIx :
        Reduce(TableStates[s], TableEvents[e], TableFacts[1])
            # TableResults[TableEventGrid[s][e]]}

RelaunchMismatches ==
    {<<s, f>> \in StateIx \X FactIx :
        Reduce(TableStates[s], RelaunchEvent, TableFacts[f])
            # TableResults[TableRelaunchGrid[s][f]]}

\* Two transitions agree on the tracked fields.
SameProjected(a, b) ==
    /\ a.kind = b.kind
    /\ IsApplied(a) =>
        /\ a.effects = b.effects
        /\ Project(a.state, TrackedFields) = Project(b.state, TrackedFields)

\* The rows where resetting the untracked fields changes the outcome.
ProjectionFailures ==
    {<<s, e>> \in StateIx \X EventIx :
        /\ TableEvents[e].type \in UsedEventTypes
        /\ ~SameProjected(
              Reduce(TableStates[s], TableEvents[e], TableFacts[1]),
              Reduce(Project(TableStates[s], TrackedFields), TableEvents[e],
                     TableFacts[1]))}
    \cup
    {<<s, f>> \in StateIx \X FactIx :
        /\ "relaunchObserved" \in UsedEventTypes
        /\ ~SameProjected(
              Reduce(TableStates[s], RelaunchEvent, TableFacts[f]),
              Reduce(Project(TableStates[s], TrackedFields), RelaunchEvent,
                     TableFacts[f]))}

Init ==
    report = [events |-> EventMismatches, relaunch |-> RelaunchMismatches,
              projection |-> ProjectionFailures]
Next == UNCHANGED report
Spec == Init /\ [][Next]_report

\* Reduce returns exactly the generated table.
TableMatches == report.events = {} /\ report.relaunch = {}

\* The table exercises the whole vocabulary this module defines, so a new
\* Swift case cannot be left out of the spec.
TableCovers ==
    /\ {TableStates[s].lifecycle : s \in StateIx} = Lifecycles
    /\ {TableEvents[e].type : e \in EventIx} \cup {"relaunchObserved"} = EventTypes
    /\ {TableFacts[f].route : f \in FactIx} = Routes
    /\ {TableFacts[f].checkpoint : f \in FactIx} = Checkpoints
    /\ {TableFacts[f].body : f \in FactIx} = BodyFacts
    /\ \A i \in 1..Len(TableStates) :
          /\ TableStates[i].pauseCause \in PauseCauses
          /\ TableStates[i].lastFailure \in FailureReasons
          /\ TableStates[i].unverifiedReason \in UnverifiedReasons
          /\ TableStates[i].admissionIntent \in AdmissionIntents
    /\ \A i \in 1..Len(TableResults) :
          IsApplied(TableResults[i]) =>
              \A k \in DOMAIN TableResults[i].effects :
                  TableResults[i].effects[k] \in EffectNames

\* The untracked fields never influence the tracked ones, the effects or
\* whether an event is accepted, for the events the module sends.
ProjectionSound == report.projection = {}
=============================================================================
