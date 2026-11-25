--------------------- MODULE DownloadsReducerConformance ---------------------
(***************************************************************************)
(* Checks DownloadsReducer.tla against the table generated from the Swift  *)
(* reducer (DownloadsReducerTable.tla).  There is no behaviour to explore: *)
(* the one state holds the rows that disagree, so a failing run prints     *)
(* them.                                                                   *)
(*                                                                         *)
(* Reducer-Conformance.cfg      TableMatches, TableCovers, RelaunchLocal   *)
(*                              and EventsIgnoreFacts.                     *)
(* Projection-<Module>.cfg      ProjectionSound, for a module that tracks  *)
(*                              only TrackedFields of the reducer state    *)
(*                              and sends only UsedEventTypes.             *)
(* Mutant-<What>.cfg            a deliberately wrong Reduce (Mutation):    *)
(*                              TableMatches must fail.                    *)
(*                                                                         *)
(* What the table holds, and why that is the whole reducer:                *)
(*  - TableEventGrid: every input state with every event shape.  The       *)
(*    states are every lifecycle with the empty history, every value of    *)
(*    every history field alone and every pair of values of two fields.    *)
(*  - TableRelaunchGrid: relaunchObserved for the first                    *)
(*    TableRelaunchInputCount states (every lifecycle with every           *)
(*    pauseCause, the rest of the history empty) with every fact record    *)
(*    there is (TableCovers: TableFacts is AllFacts, 1,280 records).       *)
(*  - RelaunchLocal extends the relaunch grid to every other input state:  *)
(*    relaunch reads only lifecycle and pauseCause, and writes only those, *)
(*    lastFailure and admissionIntent (only ever "seasonPlanned").  The    *)
(*    Swift test proves the same of the Swift.                             *)
(*  - EventsIgnoreFacts: no other event reads the facts, so one column     *)
(*    per event is enough.  The Swift test tries the whole fact space.     *)
(*                                                                         *)
(* Reading a failure: `events` holds <<s, e>> pairs and `relaunch` holds   *)
(* <<s, f>> pairs.  s, e and f are the line indices of TableStates,        *)
(* TableEvents and TableFacts in DownloadsReducerTable.tla.                *)
(***************************************************************************)
EXTENDS DownloadsReducerTable, TLC

CONSTANTS
    TrackedFields,   \* the reducer state fields a module keeps (ProjectionSound)
    UsedEventTypes,  \* the event types that module sends (ProjectionSound)
    Mutation         \* "none", or the name of an injected bug in Reduce (Mutant configs)

Mutations == {"none", "deletionGuardStaticOnly", "pendingHeadIgnoredWithLiveTask",
              "ineligibleSnapshotFailsFinalizing"}

ASSUME /\ TrackedFields \subseteq StateFields
       /\ UsedEventTypes \subseteq EventTypes
       /\ Mutation \in Mutations

VARIABLE report

StateIx == 1..TableInputCount
RelaunchStateIx == 1..TableRelaunchInputCount
EventIx == 1..Len(TableEvents)
FactIx == 1..Len(TableFacts)
RelaunchEvent == Ev("relaunchObserved")

\* The reducer under test: Reduce, or Reduce with one injected bug.  Each bug
\* is a wrong reading of one relaunch guard that agrees with Reduce on the
\* default facts of every route, checkpoint and body, so only a table that
\* crosses the guards with the rest of the facts can see it.
ReduceUnderTest(s, e, f) ==
    IF e.type # "relaunchObserved" \/ Mutation = "none" THEN Reduce(s, e, f)
    ELSE IF Mutation = "deletionGuardStaticOnly" THEN
        \* Honours deletionPending on the static route only.
        Reduce(s, e, [f EXCEPT !.deletionPending = @ /\ f.route = "staticRange"])
    ELSE IF Mutation = "pendingHeadIgnoredWithLiveTask" THEN
        Reduce(s, e, [f EXCEPT !.pendingArtifactHead = @ /\ ~f.liveTask])
    ELSE
        \* An ineligible snapshot still fails a finalizing row with no body.
        Reduce(s, e, [f EXCEPT !.snapshotEligible =
                          @ \/ (s.lifecycle = "finalizing" /\ f.body = "none")])

\* The rows where the reducer under test and the Swift reducer disagree.
EventMismatches ==
    {<<s, e>> \in StateIx \X EventIx :
        ReduceUnderTest(TableStates[s], TableEvents[e], TableFacts[1])
            # TableResults[TableEventGrid[s][e]]}

RelaunchMismatches ==
    {<<s, f>> \in RelaunchStateIx \X FactIx :
        ReduceUnderTest(TableStates[s], RelaunchEvent, TableFacts[f])
            # TableResults[TableRelaunchGrid[s][f]]}

\* The fields of a state relaunch reads, and the ones it may write.
RelaunchReads == {"lifecycle", "pauseCause"}

\* The rows where relaunch on a whole state is not relaunch on its
\* RelaunchReads projection with the other fields carried over (lastFailure
\* and admissionIntent: the one relaunch set, or else the state's own).
RelaunchLocalFailures ==
    {<<s, f>> \in StateIx \X FactIx :
        LET st == TableStates[s]
            whole == ReduceUnderTest(st, RelaunchEvent, TableFacts[f])
            core == ReduceUnderTest(Project(st, RelaunchReads), RelaunchEvent, TableFacts[f])
        IN \/ ~IsApplied(core)
           \/ whole # Applied(
                  [st EXCEPT !.lifecycle = core.state.lifecycle,
                             !.pauseCause = core.state.pauseCause,
                             !.lastFailure = IF core.state.lastFailure # "none"
                                                THEN core.state.lastFailure ELSE @,
                             !.admissionIntent = IF core.state.admissionIntent # "none"
                                                    THEN core.state.admissionIntent ELSE @],
                  core.effects)}

\* A spread of the fact space in which every value of every fact field occurs.
FactProbes == {f \in FactIx : f % 37 = 1} \cup {Len(TableFacts)}

\* The <<s, e, f>> where an event other than relaunchObserved reads the facts.
FactReadingEvents ==
    {<<s, e, f>> \in StateIx \X EventIx \X FactProbes :
        ReduceUnderTest(TableStates[s], TableEvents[e], TableFacts[f])
            # ReduceUnderTest(TableStates[s], TableEvents[e], TableFacts[1])}

\* Two transitions agree on the tracked fields.
SameProjected(a, b) ==
    /\ a.kind = b.kind
    /\ IsApplied(a) =>
        /\ a.effects = b.effects
        /\ Project(a.state, TrackedFields) = Project(b.state, TrackedFields)

\* The rows where resetting the untracked fields changes the outcome.
ProjectionFailures ==
    IF UsedEventTypes = {} THEN {} ELSE
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

\* A run computes only what its config checks: the conformance config
\* (no mutation, no projection) all of it, a Mutant config the two grids, a
\* Projection config the projection.
Conforming == UsedEventTypes = {}
Init ==
    report = [events |-> IF Conforming THEN EventMismatches ELSE {},
              relaunch |-> IF Conforming THEN RelaunchMismatches ELSE {},
              relaunchLocal |-> IF Conforming /\ Mutation = "none"
                                   THEN RelaunchLocalFailures ELSE {},
              factReading |-> IF Conforming /\ Mutation = "none"
                                 THEN FactReadingEvents ELSE {},
              projection |-> ProjectionFailures]
Next == UNCHANGED report
Spec == Init /\ [][Next]_report

\* Reduce returns exactly the generated table.
TableMatches == report.events = {} /\ report.relaunch = {}

\* Relaunch reads only lifecycle and pauseCause and writes only those,
\* lastFailure and admissionIntent, so the relaunch grid speaks for every
\* input state.
RelaunchLocal == report.relaunchLocal = {}

\* No event but relaunchObserved reads the facts.
EventsIgnoreFacts == report.factReading = {}

\* DownloadRowFacts under the table's abstraction: every record there is.
AllFacts ==
    {f \in [route : Routes, hasJob : BOOLEAN, checkpoint : Checkpoints,
            body : BodyFacts, pendingArtifactHead : BOOLEAN,
            deletionPending : BOOLEAN, liveTask : BOOLEAN,
            snapshotEligible : BOOLEAN] :
        f.hasJob => f.route = "embyConvert"}

\* The table exercises the whole vocabulary this module defines, so a new
\* Swift case cannot be left out of the spec, and its facts are the whole
\* fact space.
TableCovers ==
    /\ {TableStates[s].lifecycle : s \in StateIx} = Lifecycles
    /\ {TableEvents[e].type : e \in EventIx} \cup {"relaunchObserved"} = EventTypes
    /\ {TableFacts[f] : f \in FactIx} = AllFacts
    /\ TableFacts[1] = NoFacts
    \* The relaunch grid's states: every lifecycle with every pauseCause.
    /\ {<<TableStates[s].lifecycle, TableStates[s].pauseCause>> : s \in RelaunchStateIx}
          = Lifecycles \X PauseCauses
    /\ \A s \in RelaunchStateIx :
          TableStates[s] = Project(TableStates[s], RelaunchReads)
    /\ \A s \in StateIx :
          \E c \in RelaunchStateIx :
              TableStates[c] = Project(TableStates[s], RelaunchReads)
    /\ {TableStates[s].lastFailure : s \in StateIx} = FailureReasons
    /\ {TableStates[s].unverifiedReason : s \in StateIx} = UnverifiedReasons
    /\ {TableStates[s].admissionIntent : s \in StateIx} = AdmissionIntents
    /\ {TableStates[s].storagePark : s \in StateIx} = BOOLEAN
    /\ {TableStates[s].bodyCondemned : s \in StateIx} = BOOLEAN
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
