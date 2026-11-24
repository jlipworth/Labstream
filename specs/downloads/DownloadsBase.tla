--------------------------- MODULE DownloadsBase ---------------------------
(***************************************************************************)
(* Shared vocabulary for the downloads specs.  Every downloads module      *)
(* EXTENDS this one, so the names below stay identical across models.      *)
(*                                                                         *)
(* Source of truth: PMSKit/Sources/PMSKit/Downloads/DownloadLifecycle.swift*)
(* and DownloadLifecycleReducer.swift.  Change those first, then this.     *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

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

\* DownloadPauseCause, plus "none" for a row that is not paused.
PauseCauses ==
    {"none", "user", "queuePaused", "systemInterrupted", "awaitingSession",
     "storage", "deferredResume"}

\* DownloadRowFacts.Route
Routes == {"staticRange", "plexPrep", "embyConvert", "forwardOnly"}

\* The states of a working file at an attempt's working path.
WorkingStates == {"none", "partial", "complete"}

\* DownloadFinalizeOutcome, reduced to the verdicts that change control flow.
FinalizeOutcomes == {"complete", "truncated"}

\* A pending validated-publication intent (DownloadLifecycleEffect.publish).
PublishIntents == {"none", "complete", "unverified"}

\* BackgroundFinalizationResultPolicy.maxConsecutiveTruncationFailures
MaxTruncationStrikes == 2

\* A URLSession background task as the transfer daemon sees it.  The daemon
\* outlives the app process: "finished" and "failed" are completions the app
\* has not yet been told about.
TaskStates == {"none", "running", "finished", "failed"}

\* In-memory halt installed by Pause ("pause") or Delete/cancel ("cancel").
HaltKinds == {"none", "pause", "cancel"}

Upd(f, k, v) == [f EXCEPT ![k] = v]
=============================================================================
