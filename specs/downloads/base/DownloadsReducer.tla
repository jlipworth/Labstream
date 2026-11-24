-------------------------- MODULE DownloadsReducer --------------------------
(***************************************************************************)
(* DownloadLifecycleReducer.reduce as pure operators:                      *)
(*                                                                         *)
(*     Reduce(state, event, facts)                                         *)
(*         = Applied(state', effects) | Illegal | Replayed                 *)
(*                                                                         *)
(* It is kept equal to the Swift by a generated table, not by review:      *)
(* DownloadsReducerTable.tla is written by the PMSKit test                 *)
(* DownloadsFormalModelReducerTests from the real reducer, and             *)
(* Reducer-Conformance.cfg checks that Reduce returns exactly that table.  *)
(* A change on either side without the other fails one of the two.         *)
(* The table holds every event shape against every lifecycle with every    *)
(* single and every pair of history-field values, and relaunchObserved     *)
(* against the whole fact space (1,280 records).  The conformance module   *)
(* (DownloadsReducerConformance.tla) says why that is the whole reducer.   *)
(*                                                                         *)
(* Abstractions (the generator applies the same ones):                     *)
(*  - A state is one flat record: the lifecycle and the history fields.    *)
(*    nil is "none"; `bodyCondemned` nil is FALSE.                         *)
(*  - history.truncation is the three fields strikes, source and counted;  *)
(*    nil is (0, "none", {}).  A source key is one token, and two keys     *)
(*    are provenDifferent exactly when their tokens differ.  The bound on  *)
(*    remembered outcome IDs (8) is not modelled.                          *)
(*  - history.storagePark is a BOOLEAN (present or not).                   *)
(*  - A probe-miss reason carries no text.                                 *)
(*  - Checkpoint.durablePartial(bytes:) is "partialEmpty" (0 bytes) or     *)
(*    "partial" (more).                                                    *)
(***************************************************************************)
\* MODELS: PMSKit/Sources/PMSKit/Downloads/DownloadLifecycleReducer.swift
EXTENDS DownloadsBase

-----------------------------------------------------------------------------
(* States                                                                  *)

\* DownloadLifecycleState.  The argument order is the generated table's.
St(lifecycle, pauseCause, lastFailure, unverifiedReason, admissionIntent,
   storagePark, bodyCondemned, strikes, source, counted) ==
    [lifecycle |-> lifecycle, pauseCause |-> pauseCause,
     lastFailure |-> lastFailure, unverifiedReason |-> unverifiedReason,
     admissionIntent |-> admissionIntent, storagePark |-> storagePark,
     bodyCondemned |-> bodyCondemned, strikes |-> strikes, source |-> source,
     counted |-> counted]

StateFields ==
    {"lifecycle", "pauseCause", "lastFailure", "unverifiedReason",
     "admissionIntent", "storagePark", "bodyCondemned", "strikes", "source",
     "counted"}

\* DownloadLifecycleState(lifecycle:) with DownloadAttemptHistory.empty.
InitialState(lifecycle) ==
    St(lifecycle, "none", "none", "none", "none", FALSE, FALSE, 0, "none", {})

\* `s` with every field outside `fields` reset to its empty value.
Project(s, fields) ==
    LET empty == InitialState(s.lifecycle)
    IN [k \in StateFields |-> IF k \in fields THEN s[k] ELSE empty[k]]

-----------------------------------------------------------------------------
(* Events (DownloadLifecycleEvent)                                         *)

EventTypes ==
    {"pause", "retry", "retryRejected", "requeued", "admissionGranted",
     "admissionRequested", "admissionWithdrawn", "admissionDeferred",
     "prepReattached", "prepHandoff", "prepFailed", "transferStarted",
     "transferProgress", "checkpointAdvanced", "transferRebuilding",
     "taskAdopted", "rebuildExpired", "resourceChanged", "transferInterrupted",
     "transferFailed", "backendUnavailable", "bodyCaptured", "bodyAtWorking",
     "finalizeOutcome", "publishedBodyRevalidated", "promotionCommitted",
     "promotionAbandoned", "promotionRecovered", "localPlaybackProgressed",
     "sizeAuditFailed", "stallDetected", "relaunchObserved"}

\* DownloadRetryMode
RetryModes ==
    {"freshAttempt", "resumeBlob", "staticCheckpoint", "prepReattach",
     "convertResume"}

\* An event without a payload: Ev("transferStarted").
Ev(type) == [type |-> type]
EvPause(cause) == [type |-> "pause", cause |-> cause]
EvBackendUnavailable(cause) == [type |-> "backendUnavailable", cause |-> cause]
EvRetry(mode) == [type |-> "retry", mode |-> mode]
\* retryRejected, prepFailed, transferInterrupted, transferFailed
EvReason(type, reason) == [type |-> type, reason |-> reason]
\* admissionRequested, admissionDeferred
EvIntent(type, intent) == [type |-> type, intent |-> intent]
EvFinalize(id, outcome, source) ==
    [type |-> "finalizeOutcome", id |-> id, outcome |-> outcome, source |-> source]
EvRevalidated(outcome) == [type |-> "publishedBodyRevalidated", outcome |-> outcome]
\* promotionCommitted, promotionRecovered
EvPromotion(type, terminal) == [type |-> type, terminal |-> terminal]

-----------------------------------------------------------------------------
(* Facts (DownloadRowFacts)                                                *)

\* The argument order is the generated table's.
Fx(route, hasJob, checkpoint, body, pendingArtifactHead, deletionPending,
   liveTask, snapshotEligible) ==
    [route |-> route, hasJob |-> hasJob, checkpoint |-> checkpoint,
     body |-> body, pendingArtifactHead |-> pendingArtifactHead,
     deletionPending |-> deletionPending, liveTask |-> liveTask,
     snapshotEligible |-> snapshotEligible]

\* DownloadRowFacts(route:) with every default.  Only relaunchObserved reads
\* facts (Reducer-Conformance.cfg: EventsIgnoreFacts), so every other event
\* may pass NoFacts.
FactsFor(route) == Fx(route, FALSE, "none", "none", FALSE, FALSE, FALSE, TRUE)
NoFacts == FactsFor("staticRange")

-----------------------------------------------------------------------------
(* Transitions and effects                                                 *)

\* DownloadLifecycleEffect.  publish(.complete) and publish(.unverified) are
\* "publishComplete" and "publishUnverified".
EffectNames ==
    {"deleteWorkingBody", "deletePublishedBody", "clearResumeBlob",
     "requestFinalization", "publishComplete", "publishUnverified",
     "resetBytesToDurableCheckpoint", "resetBytesToZero"}

Applied(s, effects) == [kind |-> "applied", state |-> s, effects |-> effects]
Illegal == [kind |-> "illegal"]
Replayed == [kind |-> "replayed"]

IsApplied(t) == t.kind = "applied"
\* The transition is applied and carries this effect.
Has(t, effect) ==
    /\ IsApplied(t)
    /\ \E i \in DOMAIN t.effects : t.effects[i] = effect

-----------------------------------------------------------------------------
(* The reducer's local helpers                                             *)

\* to(_:)
RTo(s, new) ==
    [s EXCEPT !.lifecycle = new,
              !.pauseCause = IF new # "paused" THEN "none" ELSE @,
              !.lastFailure = IF new # "failed" THEN "none" ELSE @,
              !.unverifiedReason = IF new # "unverified" THEN "none" ELSE @]

\* fail(_:)
RFail(s, reason) ==
    [RTo(s, "failed") EXCEPT !.lastFailure = reason, !.admissionIntent = "none"]

\* pause(_:)
RPause(s, cause) ==
    [RTo(s, "paused") EXCEPT !.pauseCause = cause,
                            !.storagePark = IF cause # "storage" THEN FALSE ELSE @]

RClearTruncation(s) == [s EXCEPT !.strikes = 0, !.source = "none", !.counted = {}]

\* DownloadAttemptHistory.recordingTruncation, for an outcome ID that is new.
RRecordTruncation(s, id, source) ==
    LET fresh == s.source = "none" \/ s.source # source
    IN [s EXCEPT !.strikes = (IF fresh THEN 0 ELSE @) + 1,
                 !.source = source,
                 !.counted = (IF fresh THEN {} ELSE @) \cup {id}]

-----------------------------------------------------------------------------
(* relaunch(_:facts:), in the reducer's order                              *)

\* The local `set`.  `cause` and `failure` are "none" when the Swift passes nil.
RRelaunchSet(s, lifecycle, cause, failure) ==
    [s EXCEPT !.lifecycle = lifecycle,
              !.pauseCause = IF lifecycle = "paused"
                                THEN (IF cause # "none" THEN cause ELSE @)
                                ELSE "none",
              !.lastFailure = IF lifecycle = "failed" /\ failure # "none"
                                 THEN failure ELSE @]

RRelaunch(s, f) ==
    LET L == s.lifecycle
        keptCause == IF s.pauseCause # "none" THEN s.pauseCause ELSE "deferredResume"
        Unchanged == Applied(s, <<>>)
    IN
    IF ~f.snapshotEligible \/ f.pendingArtifactHead \/ f.deletionPending THEN Unchanged
    ELSE IF L \in {"planned", "failed", "serverPrep"} THEN Unchanged
    ELSE IF L = "finalizing" THEN
        IF f.body = "none"
           THEN Applied(RRelaunchSet(s, "failed", "none", "internalError"), <<>>)
           ELSE Applied(s, <<"requestFinalization">>)
    ELSE IF L \in Playable THEN
        IF f.body = "published"
           THEN Unchanged
           ELSE Applied(RRelaunchSet(s, "failed", "none", "internalError"), <<>>)
    \* admitted, transferring, paused
    ELSE IF /\ f.route = "forwardOnly" /\ ~f.liveTask
            /\ f.body = "workingComplete" /\ L # "paused" THEN
        \* A forward-only body exists only once its transfer finished (B10).
        Applied(RRelaunchSet(s, "finalizing", "none", "none"), <<"requestFinalization">>)
    ELSE IF f.route = "plexPrep" /\ ~f.liveTask /\ L # "paused" THEN
        Applied(RRelaunchSet(s, "admitted", "none", "none"), <<"resetBytesToZero">>)
    ELSE IF f.liveTask THEN
        IF f.route = "staticRange" \/ L = "paused"
           \* "a paused row a live task proves active"
           THEN Applied(RRelaunchSet(s, "transferring", "none", "none"), <<>>)
           ELSE Unchanged
    ELSE IF f.route = "embyConvert" /\ f.hasJob /\ L = "paused" THEN
        Applied(RRelaunchSet(s, "paused", keptCause, "none"), <<>>)
    ELSE IF f.route = "plexPrep" /\ L = "paused" THEN
        Applied(RRelaunchSet(s, "paused", keptCause, "none"), <<>>)
    ELSE IF f.route = "staticRange" /\ f.checkpoint = "partial" THEN
        Applied(RRelaunchSet(s, "paused", keptCause, "none"),
                <<"resetBytesToDurableCheckpoint">>)
    ELSE IF f.route = "staticRange" /\ L = "paused" THEN
        \* A paused static row is restartable from its (possibly empty) checkpoint.
        Applied(RRelaunchSet(s, "paused", "none", "none"),
                <<"resetBytesToDurableCheckpoint">>)
    ELSE IF L = "paused" /\ f.checkpoint = "resumeBlob" THEN
        Applied(RRelaunchSet(s, "paused", "none", "none"), <<>>)
    ELSE
        Applied(RRelaunchSet(s, "failed", "none", "network"),
                <<"deleteWorkingBody", "clearResumeBlob">>)

-----------------------------------------------------------------------------
(* reduce(_:_:facts:)                                                      *)

\* Names that start with R are the reducer's own helpers; modules use Reduce.

\* `when` is the event's guard; an event that fails it is illegal.
RGuarded(when, result) == IF when THEN result ELSE Illegal

Reduce(s, e, f) ==
    LET L == s.lifecycle
        parked == L \in {"paused", "failed", "planned"}
        noIntent == [s EXCEPT !.admissionIntent = "none"]
    IN
    CASE e.type = "pause" ->
            RGuarded(L \in Active \cup {"planned", "paused", "finalizing"},
                \* A finalizing body is finished: pausing never discards it.
                IF L = "finalizing" THEN Applied(s, <<>>)
                \* A user pause withdraws a waiting retry (B65).
                ELSE IF e.cause = "user" /\ s.admissionIntent = "retryRequested"
                    THEN Applied(RPause(noIntent, e.cause), <<>>)
                    ELSE Applied(RPause(s, e.cause), <<>>))
      [] e.type = "retry" ->
            (CASE e.mode = "convertResume" ->
                    RGuarded(parked, Applied(RTo(noIntent, "serverPrep"), <<>>))
              [] e.mode = "prepReattach" ->
                    RGuarded(parked, Applied(RTo(noIntent, "admitted"), <<>>))
              [] e.mode = "resumeBlob" ->
                    RGuarded(parked, Applied(RTo(noIntent, "transferring"), <<>>))
              [] e.mode \in {"staticCheckpoint", "freshAttempt"} ->
                    RGuarded(parked \/ L \in Playable,
                        Applied(RTo([noIntent EXCEPT !.storagePark = FALSE], "admitted"),
                                <<>>)))
      [] e.type = "retryRejected" -> Applied(RFail(s, e.reason), <<>>)
      [] e.type = "requeued" ->
            RGuarded((L \notin Terminal \/ L = "failed") /\ L # "finalizing",
                Applied(RTo(s, "admitted"), <<>>))
      [] e.type = "admissionGranted" ->
            RGuarded(L = "planned", Applied(RTo(noIntent, "admitted"), <<>>))
      [] e.type = "admissionRequested" ->
            RGuarded(parked,
                LET asked == [s EXCEPT !.admissionIntent = e.intent]
                IN IF e.intent = "retryRequested" /\ L # "planned"
                      THEN Applied(asked, <<>>)
                      ELSE Applied(RTo(asked, "planned"), <<>>))
      [] e.type = "admissionWithdrawn" ->
            RGuarded(L \in {"paused", "failed"}, Applied(noIntent, <<>>))
      [] e.type = "admissionDeferred" ->
            RGuarded(L \in {"admitted", "serverPrep", "failed", "planned"},
                Applied(RTo([s EXCEPT !.admissionIntent = e.intent], "planned"), <<>>))
      [] e.type = "prepReattached" ->
            RGuarded(L \in {"serverPrep", "paused", "failed", "admitted", "planned"},
                Applied(RTo(s, "serverPrep"), <<>>))
      [] e.type = "prepHandoff" ->
            RGuarded(L = "serverPrep", Applied(RTo(s, "admitted"), <<>>))
      [] e.type = "prepFailed" ->
            RGuarded(L \in {"serverPrep", "admitted", "paused", "failed"},
                Applied(RFail(s, e.reason), <<>>))
      [] e.type = "transferStarted" ->
            RGuarded(L \in {"admitted", "transferring"},
                Applied(RTo(s, "transferring"), <<>>))
      [] e.type = "taskAdopted" ->
            RGuarded(L \in {"admitted", "transferring", "paused", "failed"},
                Applied(RTo(s, "transferring"), <<>>))
      [] e.type = "transferProgress" ->
            \* B09: progress never promotes a paused, failed or finalizing row.
            RGuarded(L \in {"admitted", "transferring"},
                Applied(RTo(s, "transferring"), <<>>))
      [] e.type = "checkpointAdvanced" -> Applied(s, <<>>)
      [] e.type \in {"transferRebuilding", "resourceChanged"} ->
            RGuarded(L \in {"admitted", "transferring", "paused"},
                IF L = "paused" THEN Applied(s, <<>>)
                                ELSE Applied(RTo(s, "transferring"), <<>>))
      [] e.type = "rebuildExpired" ->
            RGuarded(L \in {"transferring", "admitted"},
                Applied(RPause(s, "deferredResume"), <<>>))
      [] e.type = "transferInterrupted" ->
            RGuarded(L \in Active,
                CASE e.reason = "cancelledBySystem" ->
                        Applied(RPause(s, "systemInterrupted"), <<>>)
                  [] e.reason = "storage" ->
                        Applied(RPause([s EXCEPT !.storagePark = TRUE], "storage"),
                                <<>>)
                  [] OTHER -> Applied(RPause(s, "deferredResume"), <<>>))
      [] e.type = "transferFailed" ->
            RGuarded(L \notin Terminal \/ L = "failed",
                Applied(RFail([s EXCEPT !.bodyCondemned =
                                      IF e.reason = "truncated" THEN TRUE ELSE @],
                                 e.reason), <<>>))
      [] e.type = "backendUnavailable" ->
            RGuarded(L \in Active \cup {"paused", "failed", "planned"},
                Applied(RPause(s, e.cause), <<>>))
      [] e.type \in {"bodyCaptured", "bodyAtWorking"} ->
            \* A condemned body never re-enters finalization.
            RGuarded(/\ L \in {"transferring", "admitted", "finalizing", "paused", "failed"}
                    /\ ~s.bodyCondemned,
                LET effects == IF e.type = "bodyAtWorking"
                                  THEN <<"requestFinalization">> ELSE <<>>
                IN IF L = "finalizing" THEN Applied(s, effects)
                                       ELSE Applied(RTo(s, "finalizing"), effects))
      [] e.type = "finalizeOutcome" ->
            IF L # "finalizing" THEN Illegal
            \* A replayed outcome ID is a no-op (R2-5).
            ELSE IF e.id \in s.counted THEN Replayed
            ELSE (CASE e.outcome = "complete" ->
                        Applied(RTo(RClearTruncation(s), "finalizing"), <<"publishComplete">>)
                   [] e.outcome = "unverified" ->
                        Applied([s EXCEPT !.unverifiedReason = "probeMiss"],
                                <<"publishUnverified">>)
                   [] e.outcome = "incompleteBytes" ->
                        Applied(RFail(s, "validation"),
                                <<"resetBytesToDurableCheckpoint">>)
                   [] e.outcome = "emptyFile" ->
                        Applied(RFail(s, "validation"), <<"deleteWorkingBody">>)
                   [] e.outcome = "truncated" ->
                        LET struck == RRecordTruncation(s, e.id, e.source)
                        IN IF struck.strikes >= MaxTruncationStrikes
                              THEN Applied([struck EXCEPT !.unverifiedReason =
                                                "truncatedRepeated"],
                                           <<"publishUnverified">>)
                              ELSE Applied(RFail([struck EXCEPT !.bodyCondemned = TRUE],
                                                    "truncated"),
                                           <<"deleteWorkingBody">>))
      [] e.type = "publishedBodyRevalidated" ->
            RGuarded(L \in Playable,
                CASE e.outcome = "complete" ->
                        Applied(RTo(RClearTruncation(s), "complete"), <<>>)
                  [] e.outcome = "unverified" ->
                        Applied([RTo(s, "unverified") EXCEPT !.unverifiedReason = "probeMiss"],
                                <<>>)
                  [] e.outcome = "truncated" ->
                        \* B54: a published body is never failed for truncation.
                        Applied([RTo(s, "unverified") EXCEPT
                                    !.unverifiedReason = "truncatedRepeated"], <<>>)
                  [] e.outcome = "incompleteBytes" ->
                        Applied(RFail(s, "validation"), <<>>)
                  [] e.outcome = "emptyFile" ->
                        Applied(RFail(s, "validation"), <<"deletePublishedBody">>))
      [] e.type = "promotionCommitted" ->
            RGuarded(L = "finalizing" /\ e.terminal \in Playable,
                \* An unverified promotion keeps the reason its verdict stored.
                Applied([RTo(s, e.terminal) EXCEPT !.unverifiedReason =
                            IF e.terminal = "unverified" THEN s.unverifiedReason ELSE @],
                        <<>>))
      [] e.type = "promotionAbandoned" ->
            RGuarded(L = "finalizing", Applied(RFail(s, "internalError"), <<>>))
      [] e.type = "promotionRecovered" ->
            RGuarded(e.terminal \in Playable, Applied(RTo(s, e.terminal), <<>>))
      [] e.type = "localPlaybackProgressed" ->
            RGuarded(L = "unverified" /\ s.unverifiedReason # "truncatedRepeated",
                Applied(RTo(s, "complete"), <<>>))
      [] e.type = "sizeAuditFailed" ->
            RGuarded(L \in Playable, Applied(RFail(s, "validation"), <<>>))
      [] e.type = "stallDetected" ->
            RGuarded(L = "transferring", Applied(RFail(s, "stalled"), <<>>))
      [] e.type = "relaunchObserved" -> RRelaunch(s, f)
=============================================================================
