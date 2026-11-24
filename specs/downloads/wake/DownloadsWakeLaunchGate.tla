----------------------- MODULE DownloadsWakeLaunchGate -----------------------
(***************************************************************************)
(* The launch-only download recovery pass (hydrate inactive backends that  *)
(* own active work, sweep orphaned server encoders) and the gate that      *)
(* decides when it runs: LaunchDownloadRecoveryGate, driven by the root    *)
(* view's launch task and its browse-ready observer.                       *)
(*                                                                         *)
(* The pass needs a reachable server.  On an offline launch it runs while  *)
(* nothing is reachable, so the first browse-ready edge afterwards must    *)
(* run it again (B77), once, and never on top of a pass still running.     *)
(*                                                                         *)
(* Everything here is in memory and belongs to one process: a crash        *)
(* resets it and the next launch starts a new gate.                        *)
(*                                                                         *)
(* Abstractions:                                                           *)
(*  - The rerun that follows a ready edge starts in the same step as the   *)
(*    edge.  In the app it starts in a MainActor Task, so browse can in    *)
(*    principle stop being ready before the rerun begins.                  *)
(*  - This module has no download rows and never calls Reduce.             *)
(***************************************************************************)
\* MODELS: PMSKit/Sources/PMSKit/Downloads/LaunchDownloadRecoveryGate.swift
EXTENDS DownloadsReducer, TLC

CONSTANTS
    MaxFlips,   \* how often browse readiness may change
    MaxCrash,
    FixB77      \* a reconnect after an offline launch reruns the pass

VARIABLES
    \* Durable or outside the process.
    env,        \* [flips, crash] left
    \* In memory.
    up,
    ready,      \* appModel.isBrowseReady
    phase,      \* "notStarted" | "running" | "finished"
    readyAtStart,
    awaiting,   \* finished(awaitingReadyEdge:)
    reruns,     \* rerun passes in flight
    \* Ghosts.
    sawReady,   \* a pass of this process started while browse was ready
    rerunCount  \* rerun passes this process has started

durable == <<env>>
memory == <<up, ready, phase, readyAtStart, awaiting, reruns>>
ghosts == <<sawReady, rerunCount>>
vars == <<durable, memory, ghosts>>

StartRerun ==
    /\ reruns' = reruns + 1
    /\ rerunCount' = rerunCount + 1
    /\ sawReady' = TRUE

\* beginLaunchPass(browseReady:), and the launch pass starts.
BeginLaunchPass ==
    /\ up /\ phase = "notStarted"
    /\ phase' = "running" /\ readyAtStart' = ready
    /\ sawReady' = ready
    /\ UNCHANGED <<env, up, ready, awaiting, reruns, rerunCount>>

\* The launch pass returns: finishLaunchPass(browseReady:), and the rerun it asks for.
FinishLaunchPass ==
    /\ up /\ phase = "running"
    /\ phase' = "finished"
    /\ IF readyAtStart
       THEN awaiting' = FALSE /\ UNCHANGED <<reruns, ghosts>>
       ELSE IF ready /\ FixB77
       THEN awaiting' = FALSE /\ StartRerun
       ELSE awaiting' = TRUE /\ UNCHANGED <<reruns, ghosts>>
    /\ UNCHANGED <<env, up, ready, readyAtStart>>

\* isBrowseReady becomes true: browseBecameReady().
ReadyEdge ==
    /\ up /\ ~ready /\ env.flips > 0
    /\ env' = [env EXCEPT !.flips = @ - 1]
    /\ ready' = TRUE
    /\ IF phase = "finished" /\ awaiting /\ FixB77
       THEN awaiting' = FALSE /\ StartRerun
       ELSE UNCHANGED <<awaiting, reruns, ghosts>>
    /\ UNCHANGED <<up, phase, readyAtStart>>

\* Sign-out or a lost connection.
ReadyLost ==
    /\ up /\ ready /\ env.flips > 0
    /\ env' = [env EXCEPT !.flips = @ - 1]
    /\ ready' = FALSE
    /\ UNCHANGED <<up, phase, readyAtStart, awaiting, reruns, ghosts>>

RerunEnds ==
    /\ up /\ reruns > 0
    /\ reruns' = reruns - 1
    /\ UNCHANGED <<env, up, ready, phase, readyAtStart, awaiting, ghosts>>

Crash ==
    /\ up /\ env.crash > 0
    /\ env' = [env EXCEPT !.crash = @ - 1]
    /\ up' = FALSE
    /\ ready' = FALSE /\ phase' = "notStarted" /\ readyAtStart' = FALSE
    /\ awaiting' = FALSE /\ reruns' = 0
    /\ sawReady' = FALSE /\ rerunCount' = 0

\* Recovery is BeginLaunchPass, which the relaunched root view schedules.
Relaunch ==
    /\ ~up /\ up' = TRUE
    /\ UNCHANGED <<env, ready, phase, readyAtStart, awaiting, reruns, ghosts>>

Init ==
    /\ env = [flips |-> MaxFlips, crash |-> MaxCrash]
    /\ up = TRUE /\ ready \in BOOLEAN
    /\ phase = "notStarted" /\ readyAtStart = FALSE /\ awaiting = FALSE /\ reruns = 0
    /\ sawReady = FALSE /\ rerunCount = 0

Next ==
    \/ BeginLaunchPass \/ FinishLaunchPass \/ ReadyEdge \/ ReadyLost \/ RerunEnds
    \/ Crash \/ Relaunch

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------

TypeOK ==
    /\ up \in BOOLEAN /\ ready \in BOOLEAN
    /\ phase \in {"notStarted", "running", "finished"}
    /\ readyAtStart \in BOOLEAN /\ awaiting \in BOOLEAN
    /\ reruns \in 0..2 /\ rerunCount \in 0..3
    /\ sawReady \in BOOLEAN

\* B77: once the launch pass is over and browse is ready, some pass has started with
\* browse ready.
LaunchPassSawServers == (phase = "finished" /\ ready) => sawReady

\* The launch pass and a rerun never run together, and reruns never overlap.
NoOverlappingPasses == (IF phase = "running" THEN 1 ELSE 0) + reruns <= 1

\* The rerun happens at most once per process.
RerunAtMostOnce == rerunCount <= 1

\* A normal launch (browse ready before the pass) never repeats the pass.
NormalLaunchRunsOnce == (phase # "notStarted" /\ readyAtStart) => rerunCount = 0
=============================================================================
