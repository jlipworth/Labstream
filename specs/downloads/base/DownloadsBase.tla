--------------------------- MODULE DownloadsBase ---------------------------
(***************************************************************************)
(* Shared vocabulary and conventions for the downloads specs.  Every       *)
(* downloads module EXTENDS this one (directly, or through                 *)
(* DownloadsReducer), so the names below stay identical across models.     *)
(*                                                                         *)
(* Source of truth: the Swift files named on the MODELS lines.  Change     *)
(* those first, then this.                                                 *)
(*                                                                         *)
(* HOW TO WRITE A DOWNLOADS MODULE                                         *)
(*                                                                         *)
(*  1. Name.  One subsystem is one folder, specs/downloads/<folder>/       *)
(*     (admission/, side-assets/, ...), holding Downloads<Name>.tla, any   *)
(*     helper module, its configs and its notes (README.md).  The modules  *)
(*     in this folder (base/) are shared: scripts/check-tla-specs.sh puts  *)
(*     it on the TLA+ library path, so EXTENDS resolves from any module    *)
(*     folder.  Do not edit DownloadsBase, DownloadsReducer,               *)
(*     DownloadsReducerTable, DownloadsReducerConformance or another       *)
(*     subsystem's module: a base change is its own commit that every      *)
(*     module rebases onto.                                                *)
(*                                                                         *)
(*  2. Header.  Directly under the MODULE line, one line per Swift file    *)
(*     the module models, repository-relative, as a line comment:          *)
(*         \* MODELS: PMSKit/Sources/PMSKit/Downloads/Foo.swift            *)
(*     scripts/check-tla-drift.py reads these lines: a change to a listed  *)
(*     file must come with a change to this module, or with a commit       *)
(*     trailer "Spec-Unaffected: <reason>".                                *)
(*                                                                         *)
(*  3. Imports.  `EXTENDS DownloadsReducer, TLC`.  DownloadsReducer        *)
(*     extends this module.  Lifecycle and history change only through     *)
(*     Reduce(state, event, facts): take `t == Reduce(...)`, guard on      *)
(*     IsApplied(t), store t.state and act on Has(t, effect).  Never       *)
(*     restate a transition by hand.  The one exception is a "fix off"     *)
(*     branch that restores a historical bug; mark it with the bug ID.     *)
(*     Either keep a whole reducer state per row (InitialState(...)), or   *)
(*     track a subset of its fields.  A module that tracks a subset puts   *)
(*     its two mapping operators (stored row -> reducer state and back)    *)
(*     in a helper module, uses them for every Reduce, and checks them     *)
(*     against the generated table: see session/DownloadsSessionRowMap     *)
(*     and DownloadsSessionRowMapCheck.  A Projection-<Name>.cfg (see      *)
(*     Projection-SessionCore.cfg) proves the weaker statement that the    *)
(*     untracked fields never influence the tracked ones; it checks field  *)
(*     names from a config, not the operators the module runs.             *)
(*     Every name this module, DownloadsReducer and the standard modules   *)
(*     they extend (Naturals, FiniteSets, Sequences: Append, Head, Tail,   *)
(*     Len, ...) define is taken; redefining one is a SANY error.          *)
(*                                                                         *)
(*  4. Variables.  Group them as the pilot does and say which group each   *)
(*     belongs to: durable (the index row, files, the URLSession daemon,   *)
(*     server-side jobs) and in memory.  Model process death as            *)
(*         Crash    == /\ up /\ up' = FALSE                                *)
(*                     /\ every in-memory variable returns to its Init     *)
(*                        value (Const(Rows, v) below)                     *)
(*                     /\ UNCHANGED every durable variable                 *)
(*         Relaunch == /\ ~up /\ up' = TRUE /\ recovery is scheduled       *)
(*     Every app action has `up` as a conjunct; daemon and server actions  *)
(*     do not.  Ghost variables only observe: no guard reads them.         *)
(*     Each fix under test is a BOOLEAN constant named Fix<BugID>; TRUE    *)
(*     is the shipping behaviour.  Proposed fixes that are not in the      *)
(*     code are constants too, and say PROPOSED where they are declared.   *)
(*                                                                         *)
(*  5. Configs.  specs/downloads/<folder>/<Kind>-<What>.cfg, beside the    *)
(*     module, where <Kind> is one of                                      *)
(*         Current    the code as it stands; must pass                     *)
(*         Liveness   a fairness run; must pass; never uses SYMMETRY       *)
(*         Faithful   Faithful-<BugID>-off: one shipped fix off; must      *)
(*                    violate the named property                           *)
(*         Mutant     Mutant-<What>: a deliberately injected bug, when     *)
(*                    the subsystem has no historical one, or to keep a    *)
(*                    property's strength tested (a check that was once    *)
(*                    too weak gets the mutation that slipped past it)     *)
(*         Finding    Finding-<ID>-<What>: an open defect; must violate    *)
(*                    until it is fixed                                    *)
(*         Proposed   proposed fixes on; must pass                         *)
(*         Deep       larger bounds; carries `TIER: deep`                  *)
(*     A config for a helper module in the same folder carries that        *)
(*     module's name first (WakeLaunchGate-Current-Gate.cfg).  A           *)
(*     Projection-<Name>.cfg sits in its module's folder although it       *)
(*     runs DownloadsReducerConformance from base/.                        *)
(*     Each config starts with header comments:                            *)
(*         \* SPEC: Downloads<Name>                                        *)
(*         \* EXPECT: pass            or   EXPECT: violation <Property>    *)
(*         \* TIER: deep              (only for runs over about 3 minutes  *)
(*                                     at TLC_WORKERS=2 TLC_HEAP=2g)       *)
(*     followed by one comment line that says what the run shows.  Use     *)
(*     SYMMETRY only over a set of model values whose members the spec     *)
(*     never tells apart, and never in a Liveness config.                  *)
(*     TLC does not name a violated liveness property and the runner       *)
(*     reports it as TEMPORAL.  A config with one PROPERTY declares        *)
(*     `EXPECT: violation TEMPORAL` and names the property in its comment  *)
(*     line.  A config with several must name the one that fails,          *)
(*     `EXPECT: violation TEMPORAL <Property>`: the runner then checks     *)
(*     that property alone (it must be violated) and the others without    *)
(*     it (they must hold).  An unnamed TEMPORAL expectation over several  *)
(*     properties fails without running.  A run counts only when TLC's     *)
(*     exit status, banner and clean finish agree, for violation configs   *)
(*     too.                                                                *)
(*                                                                         *)
(*  6. Findings.  Read the Swift before calling a counterexample a         *)
(*     finding.  A real one gets a Finding config and a withKnownIssue     *)
(*     test in PMSKit/Tests/PMSKitTests/DownloadsFormalModel<Name>Tests    *)
(*     .swift.  A modelling artefact is fixed in the model.                *)
(*                                                                         *)
(*  7. Run.  TLC_WORKERS=2 TLC_HEAP=2g scripts/check-tla-specs.sh          *)
(*     specs/downloads/<folder>                                            *)
(***************************************************************************)
\* MODELS: PMSKit/Sources/PMSKit/Downloads/DownloadLifecycle.swift
EXTENDS Naturals, FiniteSets, Sequences

-----------------------------------------------------------------------------
(* The row: lifecycle and history (DownloadLifecycle.swift)                *)

\* DownloadLifecycle cases, plus "absent" for a key that has no row.
Lifecycles ==
    {"planned", "admitted", "serverPrep", "transferring", "finalizing",
     "complete", "unverified", "paused", "failed"}
RowStates == Lifecycles \cup {"absent"}

\* DownloadLifecycle.isTerminal
Terminal == {"complete", "unverified", "failed"}
\* The reducer's `active` set.
Active == {"admitted", "serverPrep", "transferring"}
\* Rows whose published body the user can play.
Playable == {"complete", "unverified"}

\* Optional Swift values are modelled with the string "none" for nil.

\* DownloadPauseCause, plus "none" for a row that is not paused.
PauseCauses ==
    {"none", "user", "queuePaused", "systemInterrupted", "awaitingSession",
     "storage", "deferredResume"}

\* DownloadFailureReason, plus "none".
FailureReasons ==
    {"none", "storage", "auth", "network", "server", "validation", "truncated",
     "sourceMissing", "cancelledBySystem", "aborted", "stalled", "internalError"}

\* DownloadUnverifiedReason without the probe-miss detail text, plus "none".
UnverifiedReasons ==
    {"none", "probeMiss", "truncatedRepeated", "backgroundProbeDeferred",
     "migratedUnknown"}

\* DownloadAdmissionIntent, plus "none".
AdmissionIntents == {"none", "seasonPlanned", "retryRequested"}

\* BackgroundFinalizationResultPolicy.maxConsecutiveTruncationFailures
MaxTruncationStrikes == 2

-----------------------------------------------------------------------------
(* The attempt, its body and its checkpoint (DownloadRowFacts)             *)

\* DownloadRowFacts.Route.  embyConvert's hasJobOrIdentity is a separate fact.
Routes == {"staticRange", "plexPrep", "embyConvert", "forwardOnly"}

\* DownloadRowFacts.Checkpoint.  durablePartial(bytes: 0) is "partialEmpty".
Checkpoints == {"none", "partialEmpty", "partial", "resumeBlob"}

\* DownloadRowFacts.Body
BodyFacts == {"none", "captured", "workingComplete", "published"}

\* The states of a working file at an attempt's working path.
WorkingStates == {"none", "partial", "complete"}

\* DownloadFinalizeOutcome.  FinalizeOutcomes are the verdicts that change
\* control flow in the session model; AllFinalizeOutcomes is the whole enum.
FinalizeOutcomes == {"complete", "truncated"}
AllFinalizeOutcomes ==
    {"complete", "unverified", "truncated", "incompleteBytes", "emptyFile"}

\* A pending validated-publication intent (DownloadLifecycleEffect.publish).
PublishIntents == {"none", "complete", "unverified"}

-----------------------------------------------------------------------------
(* Tasks and in-memory session state                                       *)

\* A URLSession background task as the transfer daemon sees it.  The daemon
\* outlives the app process: "finished" and "failed" are completions the app
\* has not yet been told about.
TaskStates == {"none", "running", "finished", "failed"}

\* In-memory halt installed by Pause ("pause") or Delete/cancel ("cancel").
HaltKinds == {"none", "pause", "cancel"}

-----------------------------------------------------------------------------
(* Helpers                                                                 *)

Upd(f, k, v) == [f EXCEPT ![k] = v]
\* The function that maps every member of S to v: an Init or post-Crash value.
Const(S, v) == [x \in S |-> v]
=============================================================================
