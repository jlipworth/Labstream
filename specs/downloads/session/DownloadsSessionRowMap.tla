----------------------- MODULE DownloadsSessionRowMap -----------------------
(***************************************************************************)
(* How DownloadsSessionCore stores a reducer state.  The session keeps     *)
(* five fields of a row and rebuilds a whole reducer state from them       *)
(* before every Reduce.  Both directions are defined here, so that         *)
(* DownloadsSessionCore (Row, ApplyRow) and DownloadsSessionRowMapCheck    *)
(* use the same operators: the check is of the mapping the model runs,     *)
(* not of a copy of it.                                                    *)
(***************************************************************************)
EXTENDS DownloadsReducer

\* The one source key the session model has.
SessionSource == "src"

\* What ApplyRow keeps of a reducer state.
SessionStored(s) ==
    [life |-> s.lifecycle, cause |-> s.pauseCause, condemned |-> s.bodyCondemned,
     strikes |-> s.strikes, counted |-> s.counted]

\* The reducer state Row hands to Reduce.  lastFailure, unverifiedReason,
\* admissionIntent and storagePark are not kept and read as empty; the
\* truncation source is the one source whenever a truncation is recorded.
SessionRow(x) ==
    St(x.life, x.cause, "none", "none", "none", FALSE, x.condemned, x.strikes,
       IF x.strikes = 0 /\ x.counted = {} THEN "none" ELSE SessionSource, x.counted)
=============================================================================
