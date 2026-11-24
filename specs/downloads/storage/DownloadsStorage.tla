-------------------------- MODULE DownloadsStorage --------------------------
(***************************************************************************)
(* Storage accounting for downloads: what each row holds on disk, the      *)
(* storage cap, the free-space preflights, storage-full parking and the    *)
(* automatic redrive gate, and the storage audit.                          *)
(*                                                                         *)
(* Bytes are small integers.  A static-range row downloads Size segments   *)
(* of one byte each, one at a time: the daemon writes a segment into an    *)
(* OS temporary file, the app stashes it as a hidden held body, and        *)
(* appending copies it onto the hidden working file (the copy is the       *)
(* duplication peak) before the held body is deleted.  A forward-only row  *)
(* downloads one opaque body of Size bytes and moves it to the working     *)
(* path.  Publication renames the working file to the stable path.         *)
(*                                                                         *)
(* Lifecycle and history change only through Reduce.  The hand-written     *)
(* transitions are the fix-off branches, each marked with its bug ID.      *)
(*                                                                         *)
(* Not modelled: several segments in flight (DownloadsRangeTrain), resume  *)
(* blobs, server preparation, admission lanes (DownloadsAdmission), an     *)
(* unavailable free-space measurement (the code fails open), estimates     *)
(* that differ from the real size, and a Limit that changes.               *)
(***************************************************************************)
\* MODELS: PMSKit/Sources/PMSKit/Downloads/DownloadStorageAdmissionPolicy.swift
\* MODELS: PMSKit/Sources/PMSKit/Downloads/DownloadDiskSpacePolicy.swift
\* MODELS: PMSKit/Sources/PMSKit/Downloads/BackgroundOpaqueCompletionPolicy.swift
\* MODELS: PMSKit/Sources/PMSKit/Downloads/OfflineDownloadFileInventory.swift
\* MODELS: PMSKit/Sources/PMSKit/Downloads/DownloadStorageSnapshot.swift
\* MODELS: PMSKit/Sources/PMSKit/Downloads/StaticRangeRecoveryPolicy.swift
\* MODELS: Labstream/Capabilities/Downloads/Core/DownloadVolumeFreeSpace.swift
EXTENDS DownloadsReducer, TLC

CONSTANTS
    Rows,           \* model values
    ForwardRows,    \* rows on the forward-only route; the rest are static-range
    UnknownRows,    \* rows whose size estimate is unknown (nil)
    Size,           \* real media bytes of every row; the estimate of a known row
    SideMax,        \* side-asset bytes a row caches at most
    Disk,           \* volume capacity
    MaxForeign,     \* bytes other apps may take
    Limit,          \* the user's storage cap; 0 is Unlimited
    Headroom,       \* DownloadDiskSpacePolicy.startHeadroomBytes
    FixB01,         \* preflights charge the remaining work, not the whole file (B01, B23)
    FixB24,         \* a retry replaces its own row in the cap projection (B24)
    FixB24R,        \* active rows reserve their known remaining bytes in the cap (B24)
    FixB26,         \* a forward-only ENOSPC is classified storage-full (B26)
    FixB31,         \* a storage-full failure is written to the durable row (B31)
    FixB19,         \* the audit references hidden working and held files (B19)
    FixB86,         \* the startup sweep reclaims hard-killed checkpoint-copy temps (B86)
    FixParkGate,    \* PROPOSED (not in the code): the redrive gate reads the durable
                    \* storage failure, before the backend check (finding S1)
    BackendFlaps,   \* the backend session may go away and come back
    CrashEnabled    \* the process may die

ASSUME /\ ForwardRows \subseteq Rows /\ UnknownRows \subseteq Rows
       /\ Size \in Nat \ {0} /\ SideMax \in Nat /\ Disk \in Nat
       /\ MaxForeign \in Nat /\ Limit \in Nat /\ Headroom \in Nat

\* SYMMETRY for configs whose rows are all on one route and all known or all
\* unknown: nothing then tells two rows apart.
RowSymmetry == Permutations(Rows)

VARIABLES
    \* Durable: the index and the files.
    exists,     \* [Rows -> BOOLEAN]: the key has a row
    row,        \* [Rows -> reducer state]
    ckpt,       \* bytes of the hidden working file (the durable checkpoint)
    held,       \* bytes of a hidden held segment body waiting to be appended
    side,       \* cached side-asset bytes
    pubB,       \* bytes of the published file at the stable path
    temp,       \* bytes of a checkpoint-copy temporary (attempt handoff)
    \* Durable: the URLSession daemon and the rest of the volume.
    task,       \* [Rows -> TaskStates]; "failed" is always an ENOSPC here
    osTemp,     \* bytes of the daemon's temporary body, outside the app directory
    foreign,    \* bytes other apps hold
    backend,    \* the backend session is available (environment)
    \* In memory.
    up,
    latch,      \* lastError[row] is .storageFull
    pending,    \* the pending-resume marker
    cands,      \* launch_interrupted candidates captured at launch
    phase,      \* a start in flight: "idle", "clone" (checkpoint handoff), "start"
    \* Ghosts: never read by a guard.
    parked,     \* a storage-full failure parked the row and nothing re-measured since
    late,       \* bytes appended to a known-size row while it was not active
    blind,      \* an automatic redrive ran for a parked row without measuring, and it cannot fit
    capUnjust,  \* the cap refused a start that fits
    diskUnjust  \* a free-space preflight refused a start that fits

durable == <<exists, row, ckpt, held, side, pubB, temp, task, osTemp, foreign, backend>>
memory == <<up, latch, pending, cands, phase>>
ghosts == <<parked, late, blind, capUnjust, diskUnjust>>
vars == <<durable, memory, ghosts>>

Phases == {"idle", "clone", "start"}

-----------------------------------------------------------------------------
(* Helpers                                                                 *)

RECURSIVE SumOver(_, _)
SumOver(S, f) ==
    IF S = {} THEN 0
    ELSE LET x == CHOOSE y \in S : TRUE IN f[x] + SumOver(S \ {x}, f)

Max(a, b) == IF a >= b THEN a ELSE b
Monus(a, b) == IF a >= b THEN a - b ELSE 0

Static(r) == r \notin ForwardRows
\* The size estimate; 0 is unknown (nil).
Est(r) == IF r \in UnknownRows THEN 0 ELSE Size
\* The body one daemon task delivers.
Target(r) == IF Static(r) THEN 1 ELSE Size
L(r) == row[r].lifecycle

\* The reducer's verdict for a submission; a rejected event changes nothing.
Step(s, e) == LET t == Reduce(s, e, NoFacts) IN IF IsApplied(t) THEN t.state ELSE s

\* Bytes in the app's downloads directory, per row and in total.
AppBytes(r) == ckpt[r] + held[r] + side[r] + pubB[r] + temp[r]
Used == foreign + SumOver(Rows, [r \in Rows |-> AppBytes(r) + osTemp[r]])
\* DownloadVolumeFreeSpace.measure: always available in this model.
Free == Disk - Used

-----------------------------------------------------------------------------
(* DownloadStorageAdmissionPolicy: physical admission                      *)

\* requiredAdditionalFreeBytes
RequiredAdditional(expected, checkpoint, heldBytes, peak, sideFuture) ==
    IF expected = 0 THEN peak + sideFuture + Headroom
    ELSE LET onDisk == (IF checkpoint > expected THEN 0 ELSE checkpoint) + heldBytes
         IN Monus(expected, onDisk) + peak + sideFuture + Headroom

\* The largest body still to be appended: one segment for a static row with
\* work left; a forward-only body is moved, not copied.
Peak(r, c, h) == IF Static(r) /\ (c + h < Size \/ h > 0) THEN 1 ELSE 0

\* What the physical timeline needs, for a row at checkpoint c holding h.
TrueNeed(r, c, h) ==
    RequiredAdditional(Est(r), c, h, Peak(r, c, h), SideMax - side[r])

\* The preflight's requirement.
RequiredOf(r, c, h) ==
    IF FixB01 THEN TrueNeed(r, c, h)
    \* B01, B23 (fix off): the whole file is charged again, whatever is on disk.
    ELSE RequiredAdditional(Est(r), 0, 0, Peak(r, c, h), SideMax - side[r])
Required(r) == RequiredOf(r, ckpt[r], held[r])

-----------------------------------------------------------------------------
(* DownloadStorageAdmissionPolicy: the cap                                 *)

CapRows == {r \in Rows : exists[r]}
\* CapRow.reservesRemaining
Reserves(r) == L(r) \in Active
\* retainedCapBytes: the published bytes, or the durable checkpoint.  Held
\* bodies are not in it (DownloadStorageSnapshot reports them as unknown).
Retained(r) == IF L(r) \in Playable THEN pubB[r] ELSE ckpt[r]

\* CapRow.contribution, with the reservation on or off.
ContributionWith(r, reserve) ==
    Retained(r) + side[r]
        + (IF reserve /\ Reserves(r) /\ Est(r) > 0 THEN Monus(Est(r), Retained(r)) ELSE 0)
\* B24 (fix off): active rows' remaining reservations are omitted.
Contribution(r) == ContributionWith(r, FixB24R)

\* capUsage
Usage(S) == SumOver(S, [r \in Rows |-> Contribution(r)])
TrueUsage(S) == SumOver(S, [r \in Rows |-> ContributionWith(r, TRUE)])
OwnSide(r) == IF exists[r] THEN side[r] ELSE 0

\* capProjection(addingBytes: Est(r), replacingRowID: r)
Projection(r) ==
    IF Est(r) = 0 THEN Usage(CapRows)
    ELSE IF FixB24 THEN Usage(CapRows \ {r}) + Est(r) + OwnSide(r)
    \* B24 (fix off): a retry is added on top of its own row.
    ELSE Usage(CapRows) + Est(r)
TrueProjection(r) == TrueUsage(CapRows \ {r}) + Est(r) + OwnSide(r)

\* capRejection: unlimited and unknown sizes are never refused.
CapRejects(r) == Limit > 0 /\ Est(r) > 0 /\ Projection(r) > Limit
CapRefusalIsWrong(r) == CapRejects(r) /\ TrueProjection(r) <= Limit

-----------------------------------------------------------------------------
(* OfflineDownloadFileInventory.audit, as DownloadStore.storageAudit feeds *)
(* it                                                                      *)

RowOwned(r) == ckpt[r] + held[r] + side[r] + pubB[r]
AuditReferenced(r) ==
    IF FixB19 THEN RowOwned(r)
    \* B19 (fix off): only the stable path and the side assets are referenced.
    ELSE side[r] + pubB[r]
\* A checkpoint copy in progress is protected by its path lease.
InFlight(r) == IF phase[r] = "clone" THEN temp[r] ELSE 0
AuditDirectoryBytes == SumOver(Rows, [r \in Rows |-> AppBytes(r)])
AuditReferencedBytes == SumOver(Rows, [r \in Rows |-> AuditReferenced(r)])
AuditUnreferencedBytes == AuditDirectoryBytes - AuditReferencedBytes
AuditOrphanCandidateBytes ==
    AuditUnreferencedBytes - SumOver(Rows, [r \in Rows |-> InFlight(r)])

-----------------------------------------------------------------------------
Init ==
    /\ exists = Const(Rows, FALSE)
    /\ row = Const(Rows, InitialState("planned"))
    /\ ckpt = Const(Rows, 0) /\ held = Const(Rows, 0) /\ side = Const(Rows, 0)
    /\ pubB = Const(Rows, 0) /\ temp = Const(Rows, 0)
    /\ task = Const(Rows, "none") /\ osTemp = Const(Rows, 0)
    /\ foreign = 0 /\ backend = TRUE
    /\ up = TRUE
    /\ latch = Const(Rows, FALSE) /\ pending = Const(Rows, FALSE)
    /\ cands = Const(Rows, FALSE) /\ phase = Const(Rows, "idle")
    /\ parked = Const(Rows, FALSE) /\ late = Const(Rows, 0)
    /\ blind = FALSE /\ capUnjust = FALSE /\ diskUnjust = FALSE

TypeOK ==
    /\ exists \in [Rows -> BOOLEAN]
    /\ \A r \in Rows : row[r].lifecycle \in Lifecycles
                       /\ row[r].lastFailure \in FailureReasons
                       /\ row[r].pauseCause \in PauseCauses
    /\ ckpt \in [Rows -> 0..Size] /\ held \in [Rows -> 0..1]
    /\ side \in [Rows -> 0..SideMax] /\ pubB \in [Rows -> {0, Size}]
    /\ temp \in [Rows -> 0..Size]
    /\ task \in [Rows -> TaskStates] /\ osTemp \in [Rows -> 0..Size]
    /\ foreign \in 0..MaxForeign /\ backend \in BOOLEAN /\ up \in BOOLEAN
    /\ latch \in [Rows -> BOOLEAN] /\ pending \in [Rows -> BOOLEAN]
    /\ cands \in [Rows -> BOOLEAN] /\ phase \in [Rows -> Phases]
    /\ parked \in [Rows -> BOOLEAN] /\ late \in [Rows -> 0..Size]
    /\ blind \in BOOLEAN /\ capUnjust \in BOOLEAN /\ diskUnjust \in BOOLEAN
    \* The volume never holds more than its capacity.
    /\ Used <= Disk

-----------------------------------------------------------------------------
(* Storage-full failure                                                    *)

\* setFailedPurgingHeldSegments(reason: .storage) and the manager's
\* lastError = .storageFull.  The durable checkpoint is kept.
FailedForStorage(s) ==
    IF FixB31 THEN Step(s, EvReason("transferFailed", "storage"))
    \* B31 (fix off): the park exists only in memory; the durable row is not told.
    ELSE s

\* The row-independent part of a storage-full failure of row r.
StorageFull(r) ==
    /\ row' = Upd(row, r, FailedForStorage(row[r]))
    /\ latch' = Upd(latch, r, TRUE)
    /\ pending' = Upd(pending, r, FALSE)
    /\ parked' = Upd(parked, r, TRUE)

-----------------------------------------------------------------------------
(* User                                                                    *)

\* A new download.  Every backend entry point runs rejectIfOverStorageLimit
\* before it creates work; a fresh enqueue that is refused leaves no row.
Enqueue(r) ==
    /\ up /\ ~exists[r]
    /\ capUnjust' = (capUnjust \/ CapRefusalIsWrong(r))
    /\ IF CapRejects(r)
          THEN UNCHANGED <<exists, row, phase>>
          ELSE /\ exists' = Upd(exists, r, TRUE)
               /\ row' = Upd(row, r, InitialState("admitted"))
               /\ phase' = Upd(phase, r, "start")
    /\ UNCHANGED <<ckpt, held, side, pubB, temp, task, osTemp, foreign, backend,
                   up, latch, pending, cands, parked, late, blind, diskUnjust>>

\* The cap gate of a retry of an existing row, shared by the user's Retry and
\* the automatic redrive.  `s` is the row after the retry event.  A refusal
\* fails the row as aborted (markStartAbortedBeforeTransfer).
GateRetry(r, s) ==
    /\ capUnjust' = (capUnjust \/ CapRefusalIsWrong(r))
    /\ IF CapRejects(r)
          THEN /\ row' = Upd(row, r, Step(s, EvReason("transferFailed", "aborted")))
               /\ phase' = Upd(phase, r, "idle")
               /\ UNCHANGED late
          ELSE /\ row' = Upd(row, r, s)
               /\ phase' = Upd(phase, r, IF Static(r) /\ ckpt[r] > 0 THEN "clone" ELSE "start")
               /\ late' = Upd(late, r, 0)

\* Retry or Resume.  It clears lastError before dispatch, so the storage gate
\* never parks it; it still passes the cap and the preflights (sd-07).  A
\* forward-only retry starts a fresh attempt from zero.
UserRetry(r) ==
    /\ up /\ exists[r] /\ L(r) \in {"failed", "paused"}
    /\ task[r] = "none" /\ phase[r] = "idle"
    /\ LET t == Reduce(row[r], EvRetry(IF Static(r) THEN "staticCheckpoint" ELSE "freshAttempt"),
                       NoFacts)
       IN /\ IsApplied(t)
          /\ GateRetry(r, t.state)
    /\ ckpt' = Upd(ckpt, r, IF Static(r) \/ CapRejects(r) THEN ckpt[r] ELSE 0)
    /\ latch' = Upd(latch, r, FALSE)
    /\ pending' = Upd(pending, r, FALSE)
    /\ cands' = Upd(cands, r, FALSE)
    /\ parked' = Upd(parked, r, FALSE)
    /\ UNCHANGED <<exists, held, side, pubB, temp, task, osTemp, foreign, backend,
                   up, blind, diskUnjust>>

\* Pause cancels the task.  A static body that already finished is kept
\* (StaticRangeFinishedBodyPolicy: writeThenPause), as one step here.
UserPause(r) ==
    /\ up /\ exists[r]
    /\ LET t == Reduce(row[r], EvPause("user"), NoFacts)
       IN /\ IsApplied(t) /\ L(r) \in Active
          /\ row' = Upd(row, r, t.state)
    /\ held' = Upd(held, r, IF Static(r) /\ task[r] = "finished" THEN osTemp[r] ELSE held[r])
    /\ task' = Upd(task, r, "none")
    /\ osTemp' = Upd(osTemp, r, 0)
    /\ temp' = Upd(temp, r, 0)
    /\ phase' = Upd(phase, r, "idle")
    /\ pending' = Upd(pending, r, FALSE)
    /\ cands' = Upd(cands, r, FALSE)
    /\ UNCHANGED <<exists, ckpt, side, pubB, foreign, backend, up, latch, ghosts>>

\* Delete removes the row and every file it owns.
UserDelete(r) ==
    /\ up /\ exists[r]
    /\ exists' = Upd(exists, r, FALSE)
    /\ row' = Upd(row, r, InitialState("planned"))
    /\ ckpt' = Upd(ckpt, r, 0) /\ held' = Upd(held, r, 0) /\ side' = Upd(side, r, 0)
    /\ pubB' = Upd(pubB, r, 0) /\ temp' = Upd(temp, r, 0)
    /\ task' = Upd(task, r, "none") /\ osTemp' = Upd(osTemp, r, 0)
    /\ latch' = Upd(latch, r, FALSE) /\ pending' = Upd(pending, r, FALSE)
    /\ cands' = Upd(cands, r, FALSE) /\ phase' = Upd(phase, r, "idle")
    /\ parked' = Upd(parked, r, FALSE) /\ late' = Upd(late, r, 0)
    /\ UNCHANGED <<foreign, backend, up, blind, capUnjust, diskUnjust>>

-----------------------------------------------------------------------------
(* Starting a transfer                                                     *)

\* The checkpoint handoff to the new attempt copies the old working file
\* (B87): the whole checkpoint is the duplication peak.  A refusal keeps the
\* predecessor's bytes and fails it for storage.
CloneBegin(r) ==
    /\ up /\ exists[r] /\ phase[r] = "clone" /\ temp[r] = 0 /\ L(r) = "admitted"
    /\ IF Free >= RequiredAdditional(0, 0, 0, ckpt[r], 0)
          THEN /\ temp' = Upd(temp, r, ckpt[r])
               /\ UNCHANGED <<row, latch, pending, parked, phase>>
          ELSE /\ StorageFull(r)
               /\ phase' = Upd(phase, r, "idle")
               /\ UNCHANGED temp
    /\ UNCHANGED <<exists, ckpt, held, side, pubB, task, osTemp, foreign, backend,
                   up, cands, late, blind, capUnjust, diskUnjust>>

\* The new attempt owns the copy and the old working file is removed.
CloneCommit(r) ==
    /\ up /\ phase[r] = "clone" /\ temp[r] > 0
    /\ temp' = Upd(temp, r, 0)
    /\ phase' = Upd(phase, r, "start")
    /\ UNCHANGED <<exists, row, ckpt, held, side, pubB, task, osTemp, foreign, backend,
                   up, latch, pending, cands, ghosts>>

\* session.start: the free-space preflight, then the task.  A row whose
\* working file is already whole goes to finalization instead.
Start(r) ==
    /\ up /\ exists[r] /\ phase[r] = "start" /\ L(r) = "admitted"
    /\ task[r] = "none" /\ backend
    /\ phase' = Upd(phase, r, "idle")
    /\ IF Static(r) /\ ckpt[r] = Size
          THEN /\ row' = Upd(row, r, Step(row[r], Ev("bodyAtWorking")))
               /\ pending' = Upd(pending, r, FALSE)
               /\ UNCHANGED <<task, latch, parked, diskUnjust>>
       ELSE IF Static(r) /\ held[r] > 0
          \* A held body is appended first; AppendHeld plans the next segment.
          THEN /\ row' = Upd(row, r, Step(row[r], Ev("transferStarted")))
               /\ pending' = Upd(pending, r, FALSE)
               /\ UNCHANGED <<task, latch, parked, diskUnjust>>
       ELSE IF Free >= Required(r)
          THEN /\ row' = Upd(row, r, Step(row[r], Ev("transferStarted")))
               /\ task' = Upd(task, r, "running")
               /\ pending' = Upd(pending, r, FALSE)
               /\ UNCHANGED <<latch, parked, diskUnjust>>
          ELSE /\ StorageFull(r)
               /\ diskUnjust' = (diskUnjust \/ Free >= TrueNeed(r, ckpt[r], held[r]))
               /\ UNCHANGED task
    /\ UNCHANGED <<exists, ckpt, held, side, pubB, temp, osTemp, foreign, backend,
                   up, cands, late, blind, capUnjust>>

-----------------------------------------------------------------------------
(* The URLSession daemon: runs whether or not the app is alive             *)

DaemonWrites(r) ==
    /\ task[r] = "running" /\ osTemp[r] < Target(r) /\ Free >= 1
    /\ osTemp' = Upd(osTemp, r, osTemp[r] + 1)
    /\ UNCHANGED <<exists, row, ckpt, held, side, pubB, temp, task, foreign, backend,
                   memory, ghosts>>

\* The disk is full: the task fails with ENOSPC and its temporary is gone.
DaemonOutOfSpace(r) ==
    /\ task[r] = "running" /\ osTemp[r] < Target(r) /\ Free = 0
    /\ task' = Upd(task, r, "failed")
    /\ osTemp' = Upd(osTemp, r, 0)
    /\ UNCHANGED <<exists, row, ckpt, held, side, pubB, temp, foreign, backend,
                   memory, ghosts>>

DaemonFinishes(r) ==
    /\ task[r] = "running" /\ osTemp[r] = Target(r)
    /\ task' = Upd(task, r, "finished")
    /\ UNCHANGED <<exists, row, ckpt, held, side, pubB, temp, osTemp, foreign, backend,
                   memory, ghosts>>

-----------------------------------------------------------------------------
(* The session                                                             *)

\* didFinishDownloadingTo: a static segment becomes a held body; a
\* forward-only body moves to the working path.  A row that is no longer
\* transferring drops the body.
DidFinish(r) ==
    /\ up /\ task[r] = "finished"
    /\ task' = Upd(task, r, "none")
    /\ osTemp' = Upd(osTemp, r, 0)
    /\ IF exists[r] /\ L(r) = "transferring" /\ Static(r) /\ held[r] = 0
          THEN /\ held' = Upd(held, r, osTemp[r])
               /\ UNCHANGED <<row, ckpt>>
       ELSE IF exists[r] /\ L(r) = "transferring" /\ ~Static(r)
          THEN /\ ckpt' = Upd(ckpt, r, osTemp[r])
               /\ row' = Upd(row, r, Step(row[r], Ev("bodyAtWorking")))
               /\ UNCHANGED held
          ELSE UNCHANGED <<row, ckpt, held>>
    /\ UNCHANGED <<exists, side, pubB, temp, foreign, backend, memory, ghosts>>

\* Append a held body to the working file: one more copy of it must fit.
\* Then the continuation preflight plans the next segment.  A paused row
\* keeps the bytes of a body that finished (issue 401) and starts nothing.
AppendHeld(r) ==
    /\ up /\ exists[r] /\ Static(r) /\ held[r] > 0
    /\ L(r) \in {"transferring", "paused"} /\ task[r] = "none"
    /\ held' = Upd(held, r, 0)
    /\ IF Free < held[r]
          \* ENOSPC on the append: held bodies are purged, the checkpoint stays.
          THEN /\ StorageFull(r)
               /\ UNCHANGED <<ckpt, task, late>>
       ELSE LET c == ckpt[r] + held[r] IN
            /\ ckpt' = Upd(ckpt, r, c)
            /\ IF L(r) = "paused"
                  THEN /\ late' = Upd(late, r, IF Est(r) > 0 /\ late[r] < Size
                                                  THEN late[r] + 1 ELSE late[r])
                       /\ UNCHANGED <<row, task, latch, pending, parked>>
               ELSE IF c = Size
                  THEN /\ row' = Upd(row, r, Step(row[r], Ev("bodyAtWorking")))
                       /\ UNCHANGED <<task, latch, pending, parked, late>>
               ELSE IF Free >= RequiredOf(r, c, 0)
                  THEN /\ task' = Upd(task, r, "running")
                       /\ UNCHANGED <<row, latch, pending, parked, late>>
                  \* handleRangeStartStorageFull
                  ELSE /\ StorageFull(r)
                       /\ UNCHANGED <<task, late>>
    /\ UNCHANGED <<exists, side, pubB, temp, osTemp, foreign, backend,
                   up, cands, phase, blind, capUnjust, diskUnjust>>

\* didCompleteWithError for an ENOSPC task.
HandleOutOfSpace(r) ==
    /\ up /\ task[r] = "failed"
    /\ task' = Upd(task, r, "none")
    /\ held' = Upd(held, r, IF exists[r] THEN 0 ELSE held[r])
    /\ IF ~exists[r] THEN UNCHANGED <<row, latch, pending, parked>>
       ELSE IF Static(r) \/ FixB26 THEN StorageFull(r)
       \* B26 (fix off): the forward-only lane reports a generic transfer failure.
       ELSE /\ row' = Upd(row, r, Step(row[r], EvReason("transferFailed", "network")))
            /\ parked' = Upd(parked, r, TRUE)
            /\ UNCHANGED <<latch, pending>>
    /\ UNCHANGED <<exists, ckpt, side, pubB, temp, osTemp, foreign, backend,
                   up, cands, phase, late, blind, capUnjust, diskUnjust>>

\* Validation, the publish intent and the promotion commit, as one step.
\* Publication renames the working file: it needs no extra space.
Finalize(r) ==
    /\ up /\ exists[r] /\ L(r) = "finalizing" /\ ckpt[r] = Size
    /\ LET verdict == Reduce(row[r], EvFinalize("o1", "complete", "s1"), NoFacts)
       IN /\ Has(verdict, "publishComplete")
          /\ row' = Upd(row, r, Step(verdict.state, EvPromotion("promotionCommitted", "complete")))
    /\ pubB' = Upd(pubB, r, Size)
    /\ ckpt' = Upd(ckpt, r, 0)
    /\ parked' = Upd(parked, r, FALSE)
    /\ UNCHANGED <<exists, held, side, temp, task, osTemp, foreign, backend,
                   memory, late, blind, capUnjust, diskUnjust>>

\* A side asset is cached.  The cap does not gate it.
SideAsset(r) ==
    /\ up /\ exists[r] /\ side[r] < SideMax /\ Free >= 1
    /\ L(r) \in Active \cup Playable \cup {"finalizing"}
    /\ side' = Upd(side, r, side[r] + 1)
    /\ UNCHANGED <<exists, row, ckpt, held, pubB, temp, task, osTemp, foreign, backend,
                   memory, ghosts>>

-----------------------------------------------------------------------------
(* Automatic redrive: resumeStaticRangeWhenReady                           *)

DurableStorageFailure(r) == L(r) = "failed" /\ row[r].lastFailure = "storage"

\* Every automatic edge (the launch candidates, a pending-resume drain)
\* funnels through here.  The shipped order is: backend check, then the
\* storage gate on the in-memory lastError, then retry.
AutoRedrive(r) ==
    /\ up /\ exists[r] /\ Static(r) /\ task[r] = "none" /\ phase[r] = "idle"
    /\ pending[r] \/ cands[r]
    /\ L(r) \in {"failed", "admitted"} \/ (L(r) = "paused" /\ row[r].pauseCause # "user")
    /\ cands' = Upd(cands, r, FALSE)
    /\ LET short == Free < Required(r)
           \* What the storage gate knows.
           known == IF FixParkGate THEN DurableStorageFailure(r) ELSE latch[r]
           park == known /\ short /\ (FixParkGate \/ backend)
           defer == ~park /\ ~backend
       IN
       IF park
          \* Parked: keep the intent so that a later edge re-checks.
          THEN /\ pending' = Upd(pending, r, TRUE)
               /\ UNCHANGED <<row, latch, phase, parked, late, blind, capUnjust>>
       ELSE IF defer
          \* deferStaticRangeResume(preserveActiveIntent: true): the row is
          \* requeued and lastError is overwritten.
          THEN /\ row' = Upd(row, r, Step(row[r], Ev("requeued")))
               /\ latch' = Upd(latch, r, FALSE)
               /\ pending' = Upd(pending, r, TRUE)
               \* Only the proposed order measured before it got here.
               /\ parked' = Upd(parked, r, IF FixParkGate /\ known THEN FALSE ELSE parked[r])
               /\ UNCHANGED <<phase, late, blind, capUnjust>>
       ELSE /\ GateRetry(r, IF L(r) = "admitted" THEN row[r]
                            ELSE Step(row[r], EvRetry("staticCheckpoint")))
            /\ latch' = Upd(latch, r, FALSE)
            /\ pending' = Upd(pending, r, ~CapRejects(r))
            /\ blind' = (blind \/ (parked[r] /\ ~known /\ short))
            /\ parked' = Upd(parked, r, IF short THEN parked[r] ELSE FALSE)
    /\ UNCHANGED <<exists, ckpt, held, side, pubB, temp, task, osTemp, foreign, backend,
                   up, diskUnjust>>

-----------------------------------------------------------------------------
(* Disk, backend, crash                                                    *)

ForeignGrows ==
    /\ foreign < MaxForeign /\ Free >= 1
    /\ foreign' = foreign + 1
    /\ UNCHANGED <<exists, row, ckpt, held, side, pubB, temp, task, osTemp, backend,
                   memory, ghosts>>

ForeignShrinks ==
    /\ foreign > 0
    /\ foreign' = foreign - 1
    /\ UNCHANGED <<exists, row, ckpt, held, side, pubB, temp, task, osTemp, backend,
                   memory, ghosts>>

BackendFlips ==
    /\ BackendFlaps
    /\ backend' = ~backend
    /\ UNCHANGED <<exists, row, ckpt, held, side, pubB, temp, task, osTemp, foreign,
                   memory, ghosts>>

Crash ==
    /\ CrashEnabled /\ up /\ up' = FALSE
    /\ latch' = Const(Rows, FALSE) /\ pending' = Const(Rows, FALSE)
    /\ cands' = Const(Rows, FALSE) /\ phase' = Const(Rows, "idle")
    /\ UNCHANGED <<durable, ghosts>>

RelaunchFacts(r) ==
    Fx(IF Static(r) THEN "staticRange" ELSE "forwardOnly", FALSE,
       IF ~Static(r) THEN "none" ELSE IF ckpt[r] > 0 THEN "partial" ELSE "partialEmpty",
       IF pubB[r] > 0 THEN "published" ELSE IF ckpt[r] = Size THEN "workingComplete" ELSE "none",
       FALSE, FALSE, task[r] # "none", TRUE)

\* Launch: the candidates are captured before reconcile, the startup sweep
\* reclaims checkpoint-copy temps no process owns, and reconcile runs
\* relaunchObserved for every row.
Relaunch ==
    /\ ~up /\ up' = TRUE
    /\ cands' = [r \in Rows |-> exists[r] /\ Static(r) /\ L(r) \in {"admitted", "transferring"}]
    \* B86 (fix off): the sweep does not recognise a hard-killed copy.
    /\ temp' = IF FixB86 THEN Const(Rows, 0) ELSE temp
    /\ LET t(r) == Reduce(row[r], Ev("relaunchObserved"), RelaunchFacts(r))
           drops(r) == exists[r] /\ Has(t(r), "deleteWorkingBody")
       IN /\ row' = [r \in Rows |-> IF exists[r] /\ IsApplied(t(r)) THEN t(r).state ELSE row[r]]
          /\ ckpt' = [r \in Rows |-> IF drops(r) THEN 0 ELSE ckpt[r]]
          /\ held' = [r \in Rows |-> IF drops(r) THEN 0 ELSE held[r]]
    /\ UNCHANGED <<exists, side, pubB, task, osTemp, foreign, backend,
                   latch, pending, phase, ghosts>>

Next ==
    \/ \E r \in Rows :
          \/ Enqueue(r) \/ UserRetry(r) \/ UserPause(r) \/ UserDelete(r)
          \/ CloneBegin(r) \/ CloneCommit(r) \/ Start(r)
          \/ DaemonWrites(r) \/ DaemonOutOfSpace(r) \/ DaemonFinishes(r)
          \/ DidFinish(r) \/ AppendHeld(r) \/ HandleOutOfSpace(r)
          \/ Finalize(r) \/ SideAsset(r) \/ AutoRedrive(r)
    \/ ForeignGrows \/ ForeignShrinks \/ BackendFlips
    \/ Crash \/ Relaunch

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Properties                                                              *)

\* Each row counts once (B24): what it holds plus its side assets, and for an
\* active row of known size its remaining bytes, never more than the larger
\* of its estimate and what it already holds.
CountedOnce ==
    \A r \in CapRows :
        /\ Contribution(r) >= Retained(r) + side[r]
        /\ Contribution(r) <= Max(Est(r), Retained(r)) + side[r]

\* A retry replaces its own row in the projection instead of adding to it (B24).
RetryCountedOnce ==
    \A r \in CapRows :
        Est(r) > 0 =>
            Projection(r) <= Usage(CapRows \ {r}) + Max(Est(r), Retained(r)) + side[r]

\* The cap never refuses a start that fits (B24).
CapRefusalJustified == ~capUnjust

\* The durable media of known-size rows stays inside the cap (B24: active
\* rows reserve their remaining bytes).  The one slack is a body that
\* finished while its row was paused: held bodies are unknown to the cap.
CapHonoured ==
    Limit > 0 =>
        SumOver({r \in CapRows : Est(r) > 0}, [r \in Rows |-> ckpt[r] + pubB[r]])
            <= Limit + SumOver(Rows, late)

\* A free-space preflight never refuses a start that fits (B01, B23).
PreflightRefusalJustified == ~diskUnjust

\* An unknown size stays unknown: it reserves nothing, is never refused by
\* the cap, and the preflight charges only the peak, side assets and headroom.
UnknownStaysUnknown ==
    \A r \in UnknownRows :
        /\ ~CapRejects(r)
        /\ exists[r] => Contribution(r) = Retained(r) + side[r]
        /\ Required(r) = Peak(r, ckpt[r], held[r]) + (SideMax - side[r]) + Headroom

\* The audit references every byte a row owns, hidden staging included (B19).
AuditCountsHiddenStaging == \A r \in Rows : AuditReferenced(r) = RowOwned(r)

\* The audit accounts for the whole directory, and its orphan candidates
\* are exactly the checkpoint copies that no running copy owns.
AuditBalances ==
    /\ AuditReferencedBytes + AuditUnreferencedBytes = AuditDirectoryBytes
    /\ AuditOrphanCandidateBytes
         = SumOver(Rows, [r \in Rows |-> IF phase[r] = "clone" THEN 0 ELSE temp[r]])

\* While the app runs, a checkpoint copy belongs to a handoff in progress:
\* the startup sweep reclaimed whatever a hard kill left (B86).
NoOrphanAfterStartup == up => \A r \in Rows : temp[r] > 0 => phase[r] = "clone"

\* A storage-parked row says so durably until something re-measures (B31).
ParkIsDurable == \A r \in Rows : parked[r] => DurableStorageFailure(r)

\* No automatic redrive of a storage-parked row against a disk that still
\* cannot hold it, unless the gate measured first (B31, sd-06).
NoBlindRedrive == ~blind

\* An ENOSPC completion fails the row with the storage reason (B26).
StorageFullClassified ==
    [][\A r \in Rows :
          (up /\ up' /\ task[r] = "failed" /\ task'[r] = "none" /\ exists'[r]
              /\ row'[r].lifecycle # "paused")
              => DurableStorageFailure(r)']_vars

\* A storage-full failure keeps the durable checkpoint of a static row (an
\* append may land in the same step as the refusal of the next segment).
StorageFailureKeepsCheckpoint ==
    [][\A r \in Rows :
          (Static(r) /\ exists[r] /\ exists'[r] /\ parked'[r] /\ ~parked[r])
              => ckpt'[r] >= ckpt[r]]_vars

\* A paused row keeps its bytes (issue 401): nothing takes them while it
\* stays paused, and a body that finishes is added, not dropped.
PausedRowKeepsBytes ==
    [][\A r \in Rows :
          (exists[r] /\ exists'[r] /\ L(r) = "paused" /\ row'[r].lifecycle = "paused")
              => ckpt'[r] + held'[r] >= ckpt[r] + held[r]]_vars

\* The audit is report-only (issue 401): while the app runs, a checkpoint
\* copy is removed only by its own handoff, a pause, or Delete.
OrphansOnlyReclaimedAtStartup ==
    [][\A r \in Rows :
          (up /\ up' /\ temp[r] > 0 /\ temp'[r] = 0)
              => phase[r] = "clone" \/ ~exists'[r]]_vars
=============================================================================
