--------------------- MODULE DownloadsCapturePublication ---------------------
(***************************************************************************)
(* The publication of one finished forward-only body in one process life:  *)
(* from the URLSession temp file, by its capture path, to the working      *)
(* path.  DownloadsSessionCore treats this as one queued hop (`ioq`) and   *)
(* does not model path leases; this module is that hop opened up.          *)
(*                                                                         *)
(*   Delegate   urlSession(_:downloadTask:didFinishDownloadingTo:), in two *)
(*              steps: DelegateFirst, DelegateSecond.  The fix decides     *)
(*              which half claims and which half moves the body.           *)
(*   Recovery   RecoveryPass: finalizeCompletedStaticRangeFile for a       *)
(*              forward-only row, which requeues the publication of a body *)
(*              it finds at the capture path (requeueCaptured...).         *)
(*   Publisher  finishOpaqueBody on the serial range IO queue:             *)
(*              PublisherRuns, WaitAcquires, WaitTimesOut, SettleTimeout,  *)
(*              RetryRuns.                                                 *)
(*   Other      another holder of the working path's lease (a reconcile    *)
(*              deletion, a Retry's copy): OtherAcquires, OtherReleases.   *)
(*   Wake       WakeRuns (the lease-release handler, on the IO queue) and  *)
(*              BackstopFires (the parked publication's timer).            *)
(*                                                                         *)
(* Three findings of the review of #472 live here:                         *)
(*  - Duplicate publication.  The delegate moved the body to the capture   *)
(*    path before it claimed it.  A recovery pass in between claimed the   *)
(*    same body and queued a publication; the delegate then overwrote the  *)
(*    claim and queued a second one.  The lease serializes them, and the   *)
(*    second cleared the working path before it noticed that the first     *)
(*    had moved the body there.  Fix: claim before the body is exposed     *)
(*    (FixClaimBeforeCapture), and a publication that finds no capture and *)
(*    a published body does nothing (FixIdempotentPublication).            *)
(*  - A stranded body.  A publication whose lease wait ran out left with   *)
(*    its claim and nothing queued, and every later recovery pass saw the  *)
(*    claim and scheduled nothing.  Fix (FixParkedRetry): the publication  *)
(*    is parked, and the release of the lease, a recovery pass or a timer  *)
(*    runs it again.                                                       *)
(*  - The wake a park can miss.  A lease released between the wait's last  *)
(*    poll and the park has already sent its wake.  RecheckBeforePark is   *)
(*    the one more try that closes that gap; Backstop is the timer.        *)
(*                                                                         *)
(* Abstractions:                                                           *)
(*  - One body, one attempt, no crash (F1 and the capture's durability are *)
(*    DownloadsSessionCore's subject).  `Start` picks how the life begins: *)
(*    a finish delivered to a live process, a body captured by a process   *)
(*    that died, or both (the daemon redelivers the finish as well).       *)
(*  - A publication holds the lease for one step.  The other holder is     *)
(*    what makes a publication wait.                                       *)
(*  - The two claim tables of the code (the file claim the sweeps read and *)
(*    the publication ledger) are the one variable `claimed`.  The row's   *)
(*    lifecycle is not modelled: `failed` is the publication failing it.   *)
(*  - This module has no reducer state and never calls Reduce.             *)
(***************************************************************************)
\* MODELS: PMSKit/Sources/PMSKit/Downloads/ForwardOnlyPublicationLedger.swift
EXTENDS Naturals, TLC

CONSTANTS
    Start,                  \* "finish" | "relaunch" | "redelivery"
    FixClaimBeforeCapture,  \* the delegate claims, then moves the body to the capture path
    FixIdempotentPublication,
                            \* ForwardOnlyFinishedBodyPolicy.publicationStep: no capture and a
                            \* published body is `alreadyPublished`
    FixParkedRetry,         \* a publication that times out on the lease is parked
                            \* (ForwardOnlyPublicationLedger.park) and run again
    RecheckBeforePark,      \* publishOpaqueBodyWithoutWaiting tries the lease before it parks
    Backstop,               \* a parked publication asks again after a delay
    MaxRecovery,            \* recovery passes in this process life
    MaxOther                \* times another holder takes the working path's lease

ASSUME /\ Start \in {"finish", "relaunch", "redelivery"}
       /\ {FixClaimBeforeCapture, FixIdempotentPublication, FixParkedRetry,
           RecheckBeforePark, Backstop} \subseteq BOOLEAN
       /\ MaxRecovery \in Nat /\ MaxOther \in Nat

VARIABLES
    \* Files.
    temp,       \* the body is in the URLSession temp file (the delegate's `location`)
    capture,    \* the body is at the attempt's capture path
    working,    \* the body is at the working path
    \* In memory.
    claimed,    \* the body's publication is claimed
    dpc,        \* the delegate callback: "none" | "pending" | "mid" | "done"
    queued,     \* publications queued on the range IO queue
    waiting,    \* publications inside awaitWorkingPathLease
    timedOut,   \* lease waits that ran out, their completion not delivered yet
    parked,     \* parked publications
    retrying,   \* parked publications a wake handed back to the IO queue
    lease,      \* the working path: "free" | "other"
    wake,       \* a lease-release wake is queued on the IO queue
    \* The row, as far as publication changes it.
    failed,     \* a publication failed the row
    fin,        \* a publication requested finalization
    \* Bounds.
    recoveries, others

fileVars == <<temp, capture, working>>
pubVars  == <<queued, waiting, timedOut, parked, retrying>>
vars == <<fileVars, claimed, dpc, pubVars, lease, wake, failed, fin, recoveries, others>>

Owners == queued + waiting + timedOut + parked + retrying

TypeOK ==
    /\ {temp, capture, working, claimed, wake, failed, fin} \subseteq BOOLEAN
    /\ dpc \in {"none", "pending", "mid", "done"}
    /\ {queued, waiting, timedOut, parked, retrying} \subseteq 0..3
    /\ lease \in {"free", "other"}
    /\ recoveries \in 0..MaxRecovery /\ others \in 0..MaxOther

Init ==
    /\ temp = (Start # "relaunch")
    /\ capture = (Start # "finish")
    /\ working = FALSE
    /\ claimed = FALSE
    /\ dpc = IF Start = "relaunch" THEN "none" ELSE "pending"
    /\ queued = 0 /\ waiting = 0 /\ timedOut = 0 /\ parked = 0 /\ retrying = 0
    /\ lease = "free" /\ wake = FALSE
    /\ failed = FALSE /\ fin = FALSE
    /\ recoveries = 0 /\ others = 0

-----------------------------------------------------------------------------
(* Delegate                                                                *)

\* The first half of didFinishDownloadingTo for a media response.
\*  - Fixed: claim the capture path.  A claim that fails means a publication
\*    of this attempt's body already exists (a recovery pass took the body a
\*    dead process captured): this finish is a second delivery and its temp
\*    file is dropped.
\*  - Before: move the body to the capture path, where recovery looks for it.
DelegateFirst ==
    /\ dpc = "pending"
    /\ IF FixClaimBeforeCapture THEN
           IF claimed
              THEN /\ temp' = FALSE /\ dpc' = "done"
                   /\ UNCHANGED <<capture, claimed>>
              ELSE /\ claimed' = TRUE /\ dpc' = "mid"
                   /\ UNCHANGED <<temp, capture>>
       ELSE /\ temp' = FALSE /\ capture' = TRUE /\ dpc' = "mid"
            /\ UNCHANGED claimed
    /\ UNCHANGED <<working, pubVars, lease, wake, failed, fin, recoveries, others>>

\* The second half: the other of the two, and the publication is queued.
\* Before the fix the claim was written without looking (claimRangeBody).
DelegateSecond ==
    /\ dpc = "mid" /\ dpc' = "done"
    /\ IF FixClaimBeforeCapture
          THEN /\ temp' = FALSE /\ capture' = TRUE /\ UNCHANGED claimed
          ELSE /\ claimed' = TRUE /\ UNCHANGED <<temp, capture>>
    /\ queued' = queued + 1
    /\ UNCHANGED <<working, waiting, timedOut, parked, retrying, lease, wake, failed, fin,
                   recoveries, others>>

-----------------------------------------------------------------------------
(* Recovery                                                                *)

\* finalizeCompletedStaticRangeFile for a forward-only row with nothing at the
\* working path: requeueCapturedForwardOnlyBody.  An unclaimed body at the
\* capture path is claimed and its publication queued.  A claimed one is
\* already owned; the pass reports success.  Fixed: it also asks a parked
\* publication again.
RecoveryPass ==
    /\ recoveries < MaxRecovery /\ recoveries' = recoveries + 1
    /\ IF ~working /\ capture THEN
           IF ~claimed
              THEN /\ claimed' = TRUE /\ queued' = queued + 1
                   /\ UNCHANGED <<parked, retrying>>
              ELSE /\ retrying' = IF FixParkedRetry THEN retrying + parked ELSE retrying
                   /\ parked' = IF FixParkedRetry THEN 0 ELSE parked
                   /\ UNCHANGED <<claimed, queued>>
       ELSE UNCHANGED <<claimed, queued, parked, retrying>>
    /\ UNCHANGED <<fileVars, dpc, waiting, timedOut, lease, wake, failed, fin, others>>

-----------------------------------------------------------------------------
(* Publisher                                                               *)

\* finishOpaqueBody once it holds the working path's lease.  It ends by
\* releasing the lease and the claim.
\*  - The body is at the capture path: it replaces the working file, and
\*    finalization is requested.
\*  - It is not.  Fixed: a body at the working path was published by another
\*    publication, and nothing is done.  Before: the working path was cleared
\*    first, then the move failed and the row was failed.
\*  - Neither path has it: the move fails and fails the row.
Publish ==
    /\ IF capture THEN
           /\ working' = TRUE /\ capture' = FALSE /\ fin' = TRUE
           /\ UNCHANGED failed
       ELSE IF FixIdempotentPublication /\ working THEN
           UNCHANGED <<working, capture, fin, failed>>
       ELSE
           /\ working' = FALSE /\ failed' = TRUE
           /\ UNCHANGED <<capture, fin>>
    /\ claimed' = FALSE
    /\ UNCHANGED temp

\* A queued publication reaches the head of the IO queue: tryAcquirePathLease,
\* and awaitWorkingPathLease when the path is busy.
PublisherRuns ==
    /\ queued > 0 /\ queued' = queued - 1
    /\ IF lease = "free"
          THEN Publish /\ UNCHANGED waiting
          ELSE /\ waiting' = waiting + 1
               /\ UNCHANGED <<fileVars, claimed, failed, fin>>
    /\ UNCHANGED <<dpc, timedOut, parked, retrying, lease, wake, recoveries, others>>

\* The wait gets the lease.
WaitAcquires ==
    /\ waiting > 0 /\ lease = "free"
    /\ waiting' = waiting - 1
    /\ Publish
    /\ UNCHANGED <<dpc, queued, timedOut, parked, retrying, lease, wake, recoveries, others>>

\* The wait runs out with the path still busy (its last poll).  Before the
\* fix the publication ended here: the claim stayed and nothing was queued.
WaitTimesOut ==
    /\ waiting > 0 /\ lease = "other"
    /\ waiting' = waiting - 1
    /\ timedOut' = IF FixParkedRetry THEN timedOut + 1 ELSE timedOut
    /\ UNCHANGED <<fileVars, claimed, dpc, queued, parked, retrying, lease, wake, failed, fin,
                   recoveries, others>>

\* The timeout's completion runs on the IO queue (publishOpaqueBodyWithoutWaiting).
\* It tries the lease once more and publishes if the path is free now;
\* otherwise it parks.  Without the recheck it parks on the stale answer.
SettleTimeout ==
    /\ timedOut > 0 /\ timedOut' = timedOut - 1
    /\ IF RecheckBeforePark /\ lease = "free"
          THEN Publish /\ UNCHANGED parked
          ELSE /\ parked' = parked + 1
               /\ UNCHANGED <<fileVars, claimed, failed, fin>>
    /\ UNCHANGED <<dpc, queued, waiting, retrying, lease, wake, recoveries, others>>

\* A parked publication that was handed back to the IO queue never waits: it
\* publishes if the path is free and parks again if it is not.
RetryRuns ==
    /\ retrying > 0 /\ retrying' = retrying - 1
    /\ IF lease = "free"
          THEN Publish /\ UNCHANGED parked
          ELSE /\ parked' = parked + 1
               /\ UNCHANGED <<fileVars, claimed, failed, fin>>
    /\ UNCHANGED <<dpc, queued, waiting, timedOut, lease, wake, recoveries, others>>

-----------------------------------------------------------------------------
(* The other lease holder, and the wakes                                   *)

OtherAcquires ==
    /\ others < MaxOther /\ lease = "free"
    /\ lease' = "other" /\ others' = others + 1
    /\ UNCHANGED <<fileVars, claimed, dpc, pubVars, wake, failed, fin, recoveries>>

\* releasePathLease: the store's release handler queues a wake on the IO queue.
OtherReleases ==
    /\ lease = "other"
    /\ lease' = "free" /\ wake' = TRUE
    /\ UNCHANGED <<fileVars, claimed, dpc, pubVars, failed, fin, recoveries, others>>

\* resumeParkedOpaquePublications: every publication parked on the released
\* path goes back to the IO queue.  Before the fix the wake only served the
\* static lane's health refills.
WakeRuns ==
    /\ wake /\ wake' = FALSE
    /\ retrying' = IF FixParkedRetry THEN retrying + parked ELSE retrying
    /\ parked' = IF FixParkedRetry THEN 0 ELSE parked
    /\ UNCHANGED <<fileVars, claimed, dpc, queued, waiting, timedOut, lease, failed, fin,
                   recoveries, others>>

\* parkedOpaquePublicationBackstop.
BackstopFires ==
    /\ Backstop /\ FixParkedRetry /\ parked > 0
    /\ retrying' = retrying + parked /\ parked' = 0
    /\ UNCHANGED <<fileVars, claimed, dpc, queued, waiting, timedOut, lease, wake, failed, fin,
                   recoveries, others>>

-----------------------------------------------------------------------------
Next ==
    \/ DelegateFirst \/ DelegateSecond \/ RecoveryPass
    \/ PublisherRuns \/ WaitAcquires \/ WaitTimesOut \/ SettleTimeout \/ RetryRuns
    \/ OtherAcquires \/ OtherReleases \/ WakeRuns \/ BackstopFires

Spec == Init /\ [][Next]_vars

\* Liveness assumptions: the delegate callback and the IO queue run, the other
\* holder releases the lease, and the timer fires.  Recovery passes, the other
\* holder taking the lease and a wait running out are not fair.
Fairness ==
    /\ WF_vars(DelegateFirst) /\ WF_vars(DelegateSecond)
    /\ WF_vars(PublisherRuns) /\ WF_vars(WaitAcquires) /\ WF_vars(SettleTimeout)
    /\ WF_vars(RetryRuns) /\ WF_vars(OtherReleases) /\ WF_vars(WakeRuns)
    /\ WF_vars(BackstopFires)

FairSpec == Spec /\ Fairness

-----------------------------------------------------------------------------
(* Properties                                                              *)

\* The body is always somewhere: no publication deletes the only copy.
BodyKept == temp \/ capture \/ working

\* Publishing a media body never fails its row.
RowNotFailed == ~failed

\* A claim always has an owner that will act: a publication that is queued,
\* waiting, timing out, parked or retrying, or the delegate between its halves.
ClaimHasOwner == claimed => (Owners > 0 \/ dpc = "mid")

\* One publication of the body at a time.
OnePublication == Owners <= 1

\* The body is published and nothing is left over.
Settled == working /\ fin /\ ~capture /\ ~temp /\ ~claimed /\ Owners = 0
EventuallyPublished == <>[]Settled
=============================================================================
