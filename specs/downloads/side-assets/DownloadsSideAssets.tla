------------------------ MODULE DownloadsSideAssets ------------------------
(***************************************************************************)
(* Optional side assets of a download: the poster, chapter images, the     *)
(* trick-play index (Plex BIF, Emby BIF, Jellyfin trickplay) and external  *)
(* text subtitles.  The question the model answers is whether an asset     *)
(* can be forgotten: missing, with nothing left that will fetch it and     *)
(* nothing that records why.                                               *)
(*                                                                         *)
(* Actors:                                                                 *)
(*   User       UserPause, PauseAll, ResumeAll, ResumeSameAttempt,         *)
(*              ResumeFreshAttempt, ResumeRefused, UserDelete, UserAdd     *)
(*   Transfer   the main download, abstract: StartTransfer, BodyFinished,  *)
(*              Finalized, TransferFails, StorageInterrupt,                *)
(*              ReleaseKeepingRow                                          *)
(*   Passes     what offers side-asset work: the initial pass inside       *)
(*              StartTransfer, EarlyPoster, the pass inside                *)
(*              ResumeSameAttempt, and Repair (the completed-row scan      *)
(*              that runs on every foreground, backend-ready and           *)
(*              Resume All edge)                                           *)
(*   Workers    one registered task per row and work kind: LoopNext,       *)
(*              Promote, TaskFinish, RefreshDone                           *)
(*   Fetches    SideAssetFetchCoordinator: Deliver (a park, unpark or      *)
(*              cancel command reaching the coordinator), Admit            *)
(*   Server     Respond; ServerDown and ServerUp; SessionLost and          *)
(*              SessionBack (sign-out, or another backend selected)        *)
(*   Crash      Crash, Relaunch                                            *)
(*                                                                         *)
(* A work kind is one registry entry (DownloadWorkRegistry.startIfAbsent): *)
(*   poster     one request, under its own coordinator owner that Pause    *)
(*              never parks                                                *)
(*   chapters   NChapters requests, all entered at once (a task group),    *)
(*              prepared one at a time, recorded in one batch              *)
(*   bif        one request; on a completed row its availability is only   *)
(*              known after a source-metadata refresh (Plex BIF)           *)
(*   subs       NSubs requests entered one after the other, recorded in    *)
(*              one batch; a completed row always offers a refresh for     *)
(*              them                                                       *)
(*   refresh    the source-metadata request that rediscovers bif and subs  *)
(*                                                                         *)
(* Abstractions (DownloadsSideAssets.md lists what is not covered):        *)
(*  - One server origin.  The coordinator's one-start-per-second pacing    *)
(*    is not modelled; its concurrency cap and the retry budget are.       *)
(*  - A fetch-entry command and the fetch that follows it are two steps:   *)
(*    the command is issued (req "entering"), then Deliver applies it and  *)
(*    queues the request.  Commands issued in one step share a version.    *)
(*  - Versions are kept as ranks (NormPending), which preserves their      *)
(*    order and keeps the state finite.                                    *)
(*  - Cancelling a registered task resets its requests in the same step,   *)
(*    after recording what it had already promoted.  The exact-attempt     *)
(*    and source fences of the store, which stop a lagging task of an old  *)
(*    attempt from publishing, are assumed.                                *)
(*  - A replacement attempt is a new coordinator owner and a new registry  *)
(*    key, so the row's in-memory side-asset state restarts empty.         *)
(*  - Delete is one step (the cleanup journal is DownloadsCleanup's).      *)
(*  - The main transfer is the reducer's lifecycle and nothing else.       *)
(*                                                                         *)
(* Lifecycle changes only through Reduce (DownloadsReducer.tla); each row  *)
(* keeps a whole reducer state.                                            *)
(***************************************************************************)
\* MODELS: Labstream/Capabilities/Downloads/Core/DownloadManager+SideCache.swift
\* MODELS: Labstream/Capabilities/Downloads/Core/DownloadSideAssetService.swift
\* MODELS: Labstream/Capabilities/Downloads/Core/CompletedSideAssetInventory.swift
\* MODELS: Labstream/Capabilities/Downloads/Core/DownloadWorkRegistry.swift
\* MODELS: Labstream/Shared/Player/SideAssetFetchCoordinator.swift
\* MODELS: PMSKit/Sources/PMSKit/Downloads/DownloadSideAssetPolicy.swift
EXTENDS DownloadsReducer, TLC

CONSTANTS
    Rows,                 \* download keys
    Kinds,                \* the side-asset kinds a row is eligible for
    NChapters,            \* chapter images per row
    NSubs,                \* compatible text subtitle streams per row
    ServerHas,            \* the kinds the server can produce
    MaxAttempt,           \* attempt IDs are 1..MaxAttempt
    MaxConcurrent,        \* SideAssetRequestPolicy.maximumConcurrentRequests
    MaxDispatch,          \* DownloadSideAssetRetryBudget.defaultMaximumDispatches
    MaxPending,           \* bound on undelivered user commands per row
    PayloadLimit,         \* PayloadsBounded: chapter payloads allowed to wait for preparation
    FixB25,               \* the source-metadata refresh goes through the coordinator and the budget
    FixB32,               \* the coordinator drops a command older than one it has applied
    FixPublicationOwners, \* Delete also removes a file that is renamed but not yet recorded
    FixPosterReregisters, \* PROPOSED (not in the code): a poster fetch reopens its cancelled owner (S1)
    FixResumeAllUnparks,  \* PROPOSED (not in the code): Resume All unparks every row that is not paused (S2)
    FixUnparkOnAccept,    \* PROPOSED (not in the code): Resume unparks only once the resume is accepted (S4)
    PayloadWindow,        \* PROPOSED (#394): chapter payloads fetched but not yet promoted; 0 = no window
    AllowCrash,           \* environment switches: what the user, the transfer and the server may do
    AllowPauseAll,
    AllowCancelKeepingAttempt,
    AllowRefusedResume,
    AllowStoragePark,
    AllowSessionLoss,
    AllowServerOutage,
    BoundEnvironment,     \* TRUE: at most EnvBudget environment steps
    EnvBudget

AllKinds == {"poster", "chapters", "bif", "subs"}
\* Kinds whose availability a completed row can only learn from the server.
Discovered == {"bif", "subs"}

ASSUME /\ Kinds \subseteq AllKinds /\ Kinds # {}
       /\ ServerHas \subseteq AllKinds
       /\ NChapters \in Nat \ {0} /\ NSubs \in Nat \ {0}
       /\ MaxAttempt \in Nat \ {0} /\ MaxConcurrent \in Nat \ {0}
       /\ MaxDispatch \in Nat \ {0} /\ MaxPending \in Nat \ {0}
       /\ PayloadLimit \in Nat /\ PayloadWindow \in Nat /\ EnvBudget \in Nat

\* SYMMETRY for safety configs: nothing tells two rows apart.
RowSymmetry == Permutations(Rows)

\* A request is <<kind, index>>.
RefreshItem == <<"refresh", 1>>
NoItem == <<"none", 0>>
ItemsOf(k) ==
    CASE k = "chapters" -> {<<"chapters", i>> : i \in 1..NChapters}
      [] k = "subs" -> {<<"subs", i>> : i \in 1..NSubs}
      [] OTHER -> {<<k, 1>>}
AssetItems == UNION {ItemsOf(k) : k \in Kinds}
HasDiscovery == Kinds \cap Discovered # {}
WorkKinds == Kinds \cup (IF HasDiscovery THEN {"refresh"} ELSE {})
Items == AssetItems \cup (IF HasDiscovery THEN {RefreshItem} ELSE {})
KindOf(it) == it[1]

\* DownloadManager.sideAssetOwner and posterSideAssetOwner.
Owners == {"attempt", "poster"}
OwnerOf(it) == IF KindOf(it) = "poster" THEN "poster" ELSE "attempt"

\* idle      not part of a running task, or a later step of the subs loop
\* entering  its fetch-entry command is issued and not yet delivered
\* queued    waiting in the coordinator
\* inflight  admitted; the transport is running
\* ready     the payload is in memory, waiting for validation and promotion
\* promoted  renamed to its stable path; the metadata record is still to come
\* resolved  finished with nothing to record (failed, cancelled, or reused)
ReqStates == {"idle", "entering", "queued", "inflight", "ready", "promoted", "resolved"}

VARIABLES
    \* ---- durable: the index row (survives Crash) ----
    present,      \* [Rows -> BOOLEAN]              the row exists
    st,           \* [Rows -> reducer state]        DownloadLifecycleState
    attempt,      \* [Rows -> 0..MaxAttempt]        the row's attempt ID
    recorded,     \* [Rows -> SUBSET AssetItems]    paths recorded in OfflineMetadata
    \* ---- durable: files and defaults (survive Crash) ----
    file,         \* [Rows -> SUBSET AssetItems]    files at their stable paths
    queuePaused,  \* BOOLEAN                        the Pause All gate (UserDefaults)
    \* ---- outside the process (survive Crash) ----
    serverUp,     \* BOOLEAN                        the server answers
    session,      \* BOOLEAN                        a session for the row's own server exists
    \* ---- in memory (lost at Crash) ----
    up,           \* BOOLEAN                        the app process is alive
    reg,          \* [Rows -> SUBSET WorkKinds]     DownloadWorkRegistry side-cache entries
    req,          \* [Rows -> [Items -> ReqStates]]
    parked,       \* [Rows -> [Owners -> BOOLEAN]]  SideAssetFetchCoordinator.parkedOwners
    cancelled,    \* [Rows -> [Owners -> BOOLEAN]]  cancelledDownloadOwners
    applied,      \* [Rows -> [Owners -> Nat]]      downloadControlVersions
    pending,      \* commands reserved on the main actor and not yet delivered
    budget,       \* [Rows -> [Items -> 0..MaxDispatch]]  completedRowSideAssetRetryBudget
    pub,          \* [Rows -> SUBSET AssetItems]    sideAssetPublicationOwners
    earlyOffer,   \* [Rows -> BOOLEAN]              earlyPosterOffers
    exempt,       \* [Rows -> BOOLEAN]              manual-resume exemption from Pause All
    \* ---- ghosts (observe only; never read by an action's guard) ----
    sent,         \* [Rows -> [Items -> 0..MaxDispatch+1]]  transports started this launch
    ctlReordered, \* BOOLEAN   a command took effect after a later-requested one
    env           \* 0..EnvBudget

rowVars == <<present, st, attempt, recorded>>
ctlVars == <<parked, cancelled, applied, pending>>
vars == <<rowVars, file, queuePaused, serverUp, session, up, reg, req, ctlVars,
          budget, pub, earlyOffer, exempt, sent, ctlReordered, env>>

Life(r) == st[r].lifecycle
\* The asset is cached: the file exists and the metadata names it.
Have(r, it) == it \in recorded[r] /\ it \in file[r]
Missing(r, k) == {it \in ItemsOf(k) : ~Have(r, it)}
IdleReqs == [it \in Items |-> "idle"]
BothOwners(v) == [o \in Owners |-> v]
ZeroItems == [it \in Items |-> 0]
Upd2(f, r, k, v) == [f EXCEPT ![r][k] = v]

-----------------------------------------------------------------------------
(* Commands and their versions (OptionalSideAssetControlOrder)             *)

Ctl(r, o, cmd, ver, registers, it) ==
    [r |-> r, o |-> o, cmd |-> cmd, ver |-> ver, registers |-> registers, item |-> it]

VersIn(P, r, o, a) == {d.ver : d \in {x \in P : x.r = r /\ x.o = o}} \cup {a}
MaxOf(S) == CHOOSE m \in S : \A x \in S : x <= m
NextVer(r, o) == MaxOf(VersIn(pending, r, o, applied[r][o])) + 1
\* Versions as ranks among the versions still in play for the owner.
RankIn(V, v) == Cardinality({u \in V : u < v})
NormPending(P, A) ==
    {[d EXCEPT !.ver = RankIn(VersIn(P, d.r, d.o, A[d.r][d.o]), d.ver)] : d \in P}
NormApplied(P, A) ==
    [r \in Rows |-> [o \in Owners |-> RankIn(VersIn(P, r, o, A[r][o]), A[r][o])]]
SetCtl(P, A) == pending' = NormPending(P, A) /\ applied' = NormApplied(P, A)

\* A model bound: the user does not queue more than MaxPending commands.
UserCtlRoom(r) == Cardinality({d \in pending : d.r = r /\ d.item = NoItem}) < MaxPending

\* What fetchOptionalSideAsset computes at the entry of a non-poster fetch.
EntryParks(r, lifecycle, isExempt) ==
    lifecycle = "paused" \/ (queuePaused /\ ~isExempt)

Spend == IF BoundEnvironment THEN env > 0 /\ env' = env - 1 ELSE UNCHANGED env

-----------------------------------------------------------------------------
(* Starting work (startIfAbsent, then the task's first fetch entries)      *)

Startable(r, k) == k \notin reg[r] /\ Missing(r, k) # {}

\* The requests a new task enters at once.
EnterNow(r, w) ==
    CASE w = "refresh" -> {RefreshItem}
      [] w = "subs" ->
            LET missing == {it[2] : it \in Missing(r, "subs")}
            IN IF missing = {} THEN {}
               ELSE {<<"subs", CHOOSE i \in missing : \A j \in missing : i <= j>>}
      [] OTHER -> Missing(r, w)
Entering(r, W) == UNION {EnterNow(r, w) : w \in W}

EntryState(r, it) ==
    \* B25 off: the refresh used the shared client, outside the coordinator.
    IF it = RefreshItem /\ ~FixB25 THEN "inflight"
    \* The poster fetch delivers no command; a cancelled owner throws at once.
    ELSE IF KindOf(it) = "poster" /\ ~FixPosterReregisters
        THEN (IF cancelled[r]["poster"] THEN "resolved" ELSE "queued")
    ELSE "entering"

ReqAfterStart(r, W) ==
    [it \in Items |->
        IF KindOf(it) \notin W THEN req[r][it]
        ELSE IF it \in Entering(r, W) THEN EntryState(r, it)
        \* A file the attempt already owns is reused, not fetched.
        ELSE IF it # RefreshItem /\ Have(r, it) THEN "resolved"
        ELSE "idle"]

\* The fetch-entry commands of the requests entered now.  `bump` is 1 when
\* the same step already issued a command for the attempt owner.
EntryCtls(r, its, parks, bump) ==
    {Ctl(r, OwnerOf(it),
         IF OwnerOf(it) = "attempt" /\ parks THEN "park" ELSE "unpark",
         NextVer(r, OwnerOf(it)) + (IF OwnerOf(it) = "attempt" THEN bump ELSE 0),
         TRUE, it) : it \in {x \in its : EntryState(r, x) = "entering"}}

SentAfterStart(r, W) ==
    IF "refresh" \in W /\ ~FixB25 /\ sent[r][RefreshItem] <= MaxDispatch
        THEN Upd2(sent, r, RefreshItem, sent[r][RefreshItem] + 1)
        ELSE sent

\* Cancel every registered side-cache task of the row.  A fetch-entry command
\* already reserved is still delivered; it no longer carries a request.
StripItems(P, r) == {IF d.r = r THEN [d EXCEPT !.item = NoItem] ELSE d : d \in P}
\* A cancelled task still records what it has promoted: nothing checks for
\* cancellation between the rename and the metadata update.  The subtitle
\* loop is the exception; it returns at its next cancellation check and
\* drops the tracks it has collected.
RecordedAfterCancel(r) ==
    recorded[r] \cup {it \in AssetItems : req[r][it] = "promoted" /\ KindOf(it) # "subs"}

-----------------------------------------------------------------------------
Init ==
    /\ present = Const(Rows, TRUE)
    /\ st = Const(Rows, InitialState("admitted"))
    /\ attempt = Const(Rows, 1)
    /\ recorded = Const(Rows, {})
    /\ file = Const(Rows, {})
    /\ queuePaused = FALSE
    /\ serverUp = TRUE
    /\ session = TRUE
    /\ up = TRUE
    /\ reg = Const(Rows, {})
    /\ req = Const(Rows, IdleReqs)
    /\ parked = Const(Rows, BothOwners(FALSE))
    /\ cancelled = Const(Rows, BothOwners(FALSE))
    /\ applied = Const(Rows, BothOwners(0))
    /\ pending = {}
    /\ budget = Const(Rows, ZeroItems)
    /\ pub = Const(Rows, {})
    /\ earlyOffer = Const(Rows, FALSE)
    /\ exempt = Const(Rows, FALSE)
    /\ sent = Const(Rows, ZeroItems)
    /\ ctlReordered = FALSE
    /\ env = EnvBudget

-----------------------------------------------------------------------------
(* The main transfer, abstract                                             *)

\* A backend entry point starts the transfer and enqueues every side asset
\* from the item it just fetched, so no refresh is needed here.
StartTransfer(r) ==
    /\ up /\ present[r] /\ Life(r) = "admitted" /\ session
    /\ ~queuePaused \/ exempt[r]
    /\ LET t == Reduce(st[r], Ev("transferStarted"), NoFacts)
           W == {k \in Kinds : Startable(r, k) /\ (k \in Discovered => k \in ServerHas)}
       IN /\ IsApplied(t)
          /\ st' = Upd(st, r, t.state)
          /\ reg' = Upd(reg, r, reg[r] \cup W)
          /\ req' = Upd(req, r, ReqAfterStart(r, W))
          /\ SetCtl(pending \cup EntryCtls(r, Entering(r, W),
                                           EntryParks(r, "transferring", exempt[r]), 0),
                    applied)
    /\ UNCHANGED <<present, attempt, recorded, file, queuePaused, serverUp, session, up,
                   parked, cancelled, budget, pub, earlyOffer, exempt, sent,
                   ctlReordered, env>>

BodyFinished(r) ==
    /\ up /\ present[r] /\ Life(r) = "transferring"
    /\ LET t == Reduce(st[r], Ev("bodyAtWorking"), NoFacts)
       IN IsApplied(t) /\ st' = Upd(st, r, t.state)
    /\ UNCHANGED <<present, attempt, recorded, file, queuePaused, serverUp, session, up,
                   reg, req, ctlVars, budget, pub, earlyOffer, exempt, sent,
                   ctlReordered, env>>

\* The terminal refresh releases the attempt with
\* .preservingFinalizerAndSideCache: side-asset work carries on.
Finalized(r) ==
    /\ up /\ present[r] /\ Life(r) = "finalizing"
    /\ LET t1 == Reduce(st[r], EvFinalize(1, "complete", "src"), NoFacts)
           t2 == Reduce(t1.state, EvPromotion("promotionCommitted", "complete"), NoFacts)
       IN IsApplied(t1) /\ IsApplied(t2) /\ st' = Upd(st, r, t2.state)
    /\ UNCHANGED <<present, attempt, recorded, file, queuePaused, serverUp, session, up,
                   reg, req, ctlVars, budget, pub, earlyOffer, exempt, sent,
                   ctlReordered, env>>

\* A failed row is released with .preservingFinalizer: its side-cache tasks
\* are cancelled, the coordinator owners are not.
TransferFails(r) ==
    /\ up /\ present[r] /\ Life(r) = "transferring" /\ Spend
    /\ LET t == Reduce(st[r], EvReason("transferFailed", "network"), NoFacts)
       IN IsApplied(t) /\ st' = Upd(st, r, t.state)
    /\ recorded' = Upd(recorded, r, RecordedAfterCancel(r))
    /\ reg' = Upd(reg, r, {})
    /\ req' = Upd(req, r, IdleReqs)
    /\ SetCtl(StripItems(pending, r), applied)
    /\ UNCHANGED <<present, attempt, file, queuePaused, serverUp, session, up,
                   parked, cancelled, budget, pub, earlyOffer, exempt, sent, ctlReordered>>

\* A storage-parked row: paused by the reducer, no command to the coordinator.
StorageInterrupt(r) ==
    /\ AllowStoragePark /\ up /\ present[r] /\ Life(r) = "transferring" /\ Spend
    /\ LET t == Reduce(st[r], EvReason("transferInterrupted", "storage"), NoFacts)
       IN IsApplied(t) /\ st' = Upd(st, r, t.state)
    /\ UNCHANGED <<present, attempt, recorded, file, queuePaused, serverUp, session, up,
                   reg, req, ctlVars, budget, pub, earlyOffer, exempt, sent, ctlReordered>>

\* releaseInFlight with the default .allCancellable mode for a row that
\* keeps its attempt: a Plex prep poller that finds no session, for one.
\* It cancels the tasks and both coordinator owners.
ReleaseKeepingRow(r) ==
    /\ AllowCancelKeepingAttempt /\ up /\ present[r] /\ Life(r) = "admitted"
    /\ UserCtlRoom(r) /\ Spend
    /\ recorded' = Upd(recorded, r, RecordedAfterCancel(r))
    /\ reg' = Upd(reg, r, {})
    /\ req' = Upd(req, r, IdleReqs)
    /\ SetCtl(StripItems(pending, r)
                \cup {Ctl(r, o, "cancel", NextVer(r, o), FALSE, NoItem) : o \in Owners},
              applied)
    /\ UNCHANGED <<present, st, attempt, file, queuePaused, serverUp, session, up, parked,
                   cancelled, budget, pub, earlyOffer, exempt, sent, ctlReordered>>

-----------------------------------------------------------------------------
(* The user                                                                *)

PauseCtl(r) == Ctl(r, "attempt", "park", NextVer(r, "attempt"), FALSE, NoItem)
UnparkCtl(r) == Ctl(r, "attempt", "unpark", NextVer(r, "attempt"), FALSE, NoItem)
PausedState(r) == Reduce(st[r], EvPause("user"), NoFacts).state

\* pause(record:): a finalizing row ignores it.  The side-cache tasks stay
\* registered (.preservingSideCache); the attempt owner is parked.
UserPause(r) ==
    /\ up /\ present[r] /\ Life(r) \in Active /\ UserCtlRoom(r) /\ Spend
    /\ st' = Upd(st, r, PausedState(r))
    /\ SetCtl(pending \cup {PauseCtl(r)}, applied)
    /\ UNCHANGED <<present, attempt, recorded, file, queuePaused, serverUp, session, up,
                   reg, req, parked, cancelled, budget, pub, earlyOffer, exempt, sent,
                   ctlReordered>>

\* pauseQueue: pauses the active rows.  A finalizing or completed row gets
\* no command.
PauseAll ==
    /\ AllowPauseAll /\ up /\ ~queuePaused /\ Spend
    /\ LET hit == {r \in Rows : present[r] /\ Life(r) \in Active}
       IN /\ \A r \in hit : UserCtlRoom(r)
          /\ st' = [r \in Rows |-> IF r \in hit THEN PausedState(r) ELSE st[r]]
          /\ SetCtl(pending \cup {PauseCtl(r) : r \in hit}, applied)
    /\ queuePaused' = TRUE
    /\ exempt' = Const(Rows, FALSE)
    /\ UNCHANGED <<present, attempt, recorded, file, serverUp, session, up, reg, req,
                   parked, cancelled, budget, pub, earlyOffer, sent, ctlReordered>>

\* resumeQueue: clears the gate.  Paused rows are re-admitted one by one
\* (the Resume actions below); completed rows get the Repair pass and, in the
\* code as it stands, no unpark.
ResumeAll ==
    /\ up /\ queuePaused /\ Spend
    /\ queuePaused' = FALSE
    /\ exempt' = Const(Rows, FALSE)
    /\ IF FixResumeAllUnparks
          THEN LET hit == {r \in Rows : present[r] /\ Life(r) # "paused"}
               IN /\ \A r \in hit : UserCtlRoom(r)
                  /\ SetCtl(pending \cup {UnparkCtl(r) : r \in hit}, applied)
          ELSE UNCHANGED <<pending, applied>>
    /\ UNCHANGED <<rowVars, file, serverUp, session, up, reg, req, parked, cancelled,
                   budget, pub, earlyOffer, sent, ctlReordered>>

\* retryRecordAsync continuing the same attempt (a resume blob).  It unparks
\* first, then restarts the URLSession task and offers every missing asset
\* ("transfer_resume").  The discovered kinds go through a refresh.
ResumeSameAttempt(r) ==
    /\ up /\ present[r] /\ Life(r) \in {"paused", "failed"} /\ UserCtlRoom(r) /\ Spend
    /\ LET t == Reduce(st[r], EvRetry("resumeBlob"), NoFacts)
           isExempt == exempt[r] \/ queuePaused
           W == IF session
                   THEN {k \in Kinds \ Discovered : Startable(r, k)}
                        \cup (IF HasDiscovery /\ "refresh" \notin reg[r]
                                 THEN {"refresh"} ELSE {})
                   ELSE {}
       IN /\ IsApplied(t)
          /\ st' = Upd(st, r, t.state)
          /\ exempt' = Upd(exempt, r, isExempt)
          /\ reg' = Upd(reg, r, reg[r] \cup W)
          /\ req' = Upd(req, r, ReqAfterStart(r, W))
          /\ sent' = SentAfterStart(r, W)
          /\ SetCtl(pending \cup {UnparkCtl(r)}
                      \cup EntryCtls(r, Entering(r, W),
                                     EntryParks(r, t.state.lifecycle, isExempt), 1),
                    applied)
    /\ UNCHANGED <<present, attempt, recorded, file, queuePaused, serverUp, session, up,
                   parked, cancelled, budget, pub, earlyOffer, ctlReordered>>

\* The memory of a row whose attempt is replaced or deleted: the registry
\* key and both coordinator owners belong to the old attempt.
ForgetRowMemory(r) ==
    /\ reg' = Upd(reg, r, {})
    /\ req' = Upd(req, r, IdleReqs)
    /\ parked' = Upd(parked, r, BothOwners(FALSE))
    /\ cancelled' = Upd(cancelled, r, BothOwners(FALSE))
    /\ SetCtl({d \in pending : d.r # r}, Upd(applied, r, BothOwners(0)))
    /\ budget' = Upd(budget, r, ZeroItems)
    /\ sent' = Upd(sent, r, ZeroItems)
    /\ pub' = Upd(pub, r, {})
    /\ earlyOffer' = Upd(earlyOffer, r, FALSE)

\* A retry that seeds a replacement attempt.  The cached bundle is fenced to
\* the old attempt: the store clears the recorded paths and retires those
\* files.  A file that was renamed but not yet recorded is not among them.
ResumeFreshAttempt(r) ==
    /\ up /\ present[r] /\ Life(r) \in {"paused", "failed"}
    /\ attempt[r] < MaxAttempt /\ Spend
    /\ LET t == Reduce(st[r], EvRetry("freshAttempt"), NoFacts)
       IN IsApplied(t) /\ st' = Upd(st, r, t.state)
    /\ attempt' = Upd(attempt, r, attempt[r] + 1)
    /\ file' = Upd(file, r, file[r] \ recorded[r])
    /\ recorded' = Upd(recorded, r, {})
    /\ exempt' = Upd(exempt, r, exempt[r] \/ queuePaused)
    /\ ForgetRowMemory(r)
    /\ UNCHANGED <<present, queuePaused, serverUp, session, up, ctlReordered>>

\* retryRecordAsync unparks before its own guards.  A resume the storage cap
\* or a missing backend then refuses leaves the row paused and unparked.
ResumeRefused(r) ==
    /\ AllowRefusedResume /\ up /\ present[r] /\ Life(r) = "paused"
    /\ UserCtlRoom(r) /\ Spend
    /\ IF FixUnparkOnAccept THEN UNCHANGED <<pending, applied>>
                            ELSE SetCtl(pending \cup {UnparkCtl(r)}, applied)
    /\ UNCHANGED <<rowVars, file, queuePaused, serverUp, session, up, reg, req, parked,
                   cancelled, budget, pub, earlyOffer, exempt, sent, ctlReordered>>

\* Row deletion removes the paths the row references: the recorded ones and
\* the ones a rename has published but metadata has not recorded yet.
UserDelete(r) ==
    /\ up /\ present[r] /\ Spend
    /\ present' = Upd(present, r, FALSE)
    /\ st' = Upd(st, r, InitialState("admitted"))
    /\ file' = Upd(file, r, file[r] \ (recorded[r] \cup
                                        (IF FixPublicationOwners THEN pub[r] ELSE {})))
    /\ recorded' = Upd(recorded, r, {})
    /\ exempt' = Upd(exempt, r, FALSE)
    /\ ForgetRowMemory(r)
    /\ UNCHANGED <<attempt, queuePaused, serverUp, session, up, ctlReordered>>

\* The same item is downloaded again under a new attempt.
UserAdd(r) ==
    /\ up /\ ~present[r] /\ attempt[r] < MaxAttempt /\ Spend
    /\ present' = Upd(present, r, TRUE)
    /\ attempt' = Upd(attempt, r, attempt[r] + 1)
    /\ UNCHANGED <<st, recorded, file, queuePaused, serverUp, session, up, reg, req,
                   ctlVars, budget, pub, earlyOffer, exempt, sent, ctlReordered>>

-----------------------------------------------------------------------------
(* Passes that offer work                                                  *)

\* scheduleEarlyPosters: once per launch and attempt, also for a paused row
\* and a row waiting behind Pause All.  A missing session does not consume
\* the offer.
EarlyPoster(r) ==
    /\ up /\ present[r] /\ "poster" \in Kinds /\ session /\ ~earlyOffer[r]
    /\ Life(r) \in {"admitted", "transferring", "finalizing", "paused"}
    /\ Startable(r, "poster")
    /\ earlyOffer' = Upd(earlyOffer, r, TRUE)
    /\ reg' = Upd(reg, r, reg[r] \cup {"poster"})
    /\ req' = Upd(req, r, ReqAfterStart(r, {"poster"}))
    /\ SetCtl(pending \cup EntryCtls(r, Entering(r, {"poster"}), FALSE, 0), applied)
    /\ UNCHANGED <<rowVars, file, queuePaused, serverUp, session, up, parked, cancelled,
                   budget, pub, exempt, sent, ctlReordered, env>>

\* rehydrateMissingOptionalSideAssetsForCompletedRows, for one row.  It does
\* not run behind Pause All.  The inventory offers a kind only while some
\* resource of it has budget left; text subtitles are always offered, because
\* persisted metadata cannot enumerate streams that were never cached.
RepairOffers(r) ==
    LET posterOffer ==
            IF "poster" \in Kinds /\ Missing(r, "poster") # {}
               /\ budget[r][<<"poster", 1>>] < MaxDispatch
               THEN {"poster"} ELSE {}
        chapterOffer ==
            IF "chapters" \in Kinds
               /\ \E it \in Missing(r, "chapters") : budget[r][it] < MaxDispatch
               THEN {"chapters"} ELSE {}
        refreshOffer ==
            IF HasDiscovery /\ budget[r][RefreshItem] < MaxDispatch
               /\ ("subs" \in Kinds \/ Missing(r, "bif") # {})
               THEN {"refresh"} ELSE {}
    IN (posterOffer \cup chapterOffer \cup refreshOffer) \ reg[r]

Repair(r) ==
    /\ up /\ ~queuePaused /\ present[r] /\ Life(r) \in Playable /\ session
    /\ LET W == RepairOffers(r)
       IN /\ W # {}
          /\ reg' = Upd(reg, r, reg[r] \cup W)
          /\ req' = Upd(req, r, ReqAfterStart(r, W))
          /\ sent' = SentAfterStart(r, W)
          /\ SetCtl(pending \cup EntryCtls(r, Entering(r, W),
                                           EntryParks(r, Life(r), exempt[r]), 0),
                    applied)
    /\ UNCHANGED <<rowVars, file, queuePaused, serverUp, session, up, parked, cancelled,
                   budget, pub, earlyOffer, exempt, ctlReordered, env>>

-----------------------------------------------------------------------------
(* The coordinator                                                         *)

\* applyDownloadControl.
Deliver(d) ==
    /\ up /\ d \in pending
    /\ LET r == d.r
           o == d.o
           fresh == IF FixB32 THEN d.ver > applied[r][o] ELSE TRUE
           \* A fetch entry reopens a cancelled owner; nothing else does.
           wasCancelled == IF fresh /\ d.registers THEN FALSE ELSE cancelled[r][o]
           acts == fresh /\ ~wasCancelled
           nowCancelled == (acts /\ d.cmd = "cancel") \/ wasCancelled
           nowParked == IF acts THEN d.cmd = "park" ELSE parked[r][o]
           afterCmd ==
               [it \in Items |->
                   IF OwnerOf(it) # o THEN req[r][it]
                   \* Parked in-flight work is cancelled and keeps its place.
                   ELSE IF acts /\ d.cmd = "park" /\ req[r][it] = "inflight" THEN "queued"
                   ELSE IF acts /\ d.cmd = "cancel" /\ req[r][it] \in {"queued", "inflight"}
                       THEN "resolved"
                   ELSE req[r][it]]
           \* The fetch that reserved this command now enters the coordinator.
           afterEntry ==
               IF d.item # NoItem /\ afterCmd[d.item] = "entering"
                  THEN [afterCmd EXCEPT ![d.item] =
                            IF nowCancelled THEN "resolved" ELSE "queued"]
                  ELSE afterCmd
       IN /\ req' = Upd(req, r, afterEntry)
          /\ parked' = Upd2(parked, r, o, nowParked)
          /\ cancelled' = Upd2(cancelled, r, o, nowCancelled)
          /\ SetCtl(pending \ {d},
                    IF fresh /\ d.ver > applied[r][o] THEN Upd2(applied, r, o, d.ver)
                                                      ELSE applied)
          /\ ctlReordered' = (ctlReordered \/ (fresh /\ d.ver < applied[r][o]))
    /\ UNCHANGED <<rowVars, file, queuePaused, serverUp, session, up, reg, budget, pub,
                   earlyOffer, exempt, sent, env>>

ActiveCount == Cardinality({x \in Rows \X Items : req[x[1]][x[2]] = "inflight"})

\* schedule + admitEligibleWaiter: the concurrency cap, then the budget
\* charge at transport admission.
Admit(r, it) ==
    /\ up /\ req[r][it] = "queued" /\ ~parked[r][OwnerOf(it)]
    /\ ActiveCount < MaxConcurrent
    /\ (PayloadWindow > 0 /\ KindOf(it) = "chapters") =>
          Cardinality({c \in ItemsOf("chapters") : req[r][c] \in {"inflight", "ready"}})
              < PayloadWindow
    /\ IF budget[r][it] < MaxDispatch
          THEN /\ req' = Upd2(req, r, it, "inflight")
               /\ budget' = Upd2(budget, r, it, budget[r][it] + 1)
               /\ sent' = Upd2(sent, r, it, sent[r][it] + 1)
          ELSE /\ req' = Upd2(req, r, it, "resolved")
               /\ UNCHANGED <<budget, sent>>
    /\ UNCHANGED <<rowVars, file, queuePaused, serverUp, session, up, reg, ctlVars, pub,
                   earlyOffer, exempt, ctlReordered, env>>

\* The transport ends: a payload, or an error (an outage, or an asset the
\* server does not have).  Either way the dispatch stays charged.
Respond(r, it) ==
    /\ up /\ req[r][it] = "inflight"
    /\ req' = Upd2(req, r, it,
                   IF serverUp /\ (it = RefreshItem \/ KindOf(it) \in ServerHas)
                      THEN "ready" ELSE "resolved")
    /\ UNCHANGED <<rowVars, file, queuePaused, serverUp, session, up, reg, ctlVars,
                   budget, pub, earlyOffer, exempt, sent, ctlReordered, env>>

-----------------------------------------------------------------------------
(* Workers                                                                 *)

\* prepareSideAsset + promoteSideAsset: the file reaches its stable path and
\* the store remembers the publication in memory.
Promote(r, it) ==
    /\ up /\ present[r] /\ it # RefreshItem /\ req[r][it] = "ready"
    /\ file' = Upd(file, r, file[r] \cup {it})
    /\ pub' = Upd(pub, r, pub[r] \cup {it})
    /\ req' = Upd2(req, r, it, "promoted")
    /\ UNCHANGED <<rowVars, queuePaused, serverUp, session, up, reg, ctlVars, budget,
                   earlyOffer, exempt, sent, ctlReordered, env>>

\* The subtitle task fetches its streams one after the other; each is a new
\* fetch entry.
LoopNext(r, i) ==
    /\ up /\ "subs" \in Kinds /\ "subs" \in reg[r] /\ i \in 1..NSubs
    /\ req[r][<<"subs", i>>] = "idle"
    /\ \A j \in 1..(i - 1) : req[r][<<"subs", j>>] \in {"promoted", "resolved"}
    /\ req' = Upd2(req, r, <<"subs", i>>, "entering")
    /\ SetCtl(pending \cup EntryCtls(r, {<<"subs", i>>},
                                     EntryParks(r, Life(r), exempt[r]), 0),
              applied)
    /\ UNCHANGED <<rowVars, file, queuePaused, serverUp, session, up, reg, parked,
                   cancelled, budget, pub, earlyOffer, exempt, sent, ctlReordered, env>>

\* The task's one metadata update, and the end of its registry entry.
TaskFinish(r, k) ==
    /\ up /\ present[r] /\ k \in Kinds /\ k \in reg[r]
    /\ \A it \in ItemsOf(k) : req[r][it] \in {"promoted", "resolved"}
    /\ recorded' = Upd(recorded, r,
                       recorded[r] \cup {it \in ItemsOf(k) : req[r][it] = "promoted"})
    /\ reg' = Upd(reg, r, reg[r] \ {k})
    /\ req' = Upd(req, r, [it \in Items |-> IF KindOf(it) = k THEN "idle" ELSE req[r][it]])
    /\ UNCHANGED <<present, st, attempt, file, queuePaused, serverUp, session, up,
                   ctlVars, budget, pub, earlyOffer, exempt, sent, ctlReordered, env>>

\* The refresh ends.  With the current item it starts the discovered kinds
\* the server has, unless the row is failed or paused by then.
RefreshDone(r) ==
    /\ up /\ present[r] /\ "refresh" \in reg[r]
    /\ req[r][RefreshItem] \in {"ready", "resolved"}
    /\ LET W == IF req[r][RefreshItem] = "ready" /\ Life(r) \notin {"failed", "paused"}
                   THEN {k \in Kinds \cap Discovered \cap ServerHas : Startable(r, k)}
                   ELSE {}
           started == [ReqAfterStart(r, W) EXCEPT ![RefreshItem] = "idle"]
       IN /\ reg' = Upd(reg, r, (reg[r] \ {"refresh"}) \cup W)
          /\ req' = Upd(req, r, started)
          /\ SetCtl(pending \cup EntryCtls(r, Entering(r, W),
                                           EntryParks(r, Life(r), exempt[r]), 0),
                    applied)
    /\ UNCHANGED <<rowVars, file, queuePaused, serverUp, session, up, parked, cancelled,
                   budget, pub, earlyOffer, exempt, sent, ctlReordered, env>>

-----------------------------------------------------------------------------
(* The server, the session and the process                                 *)

ServerDown ==
    /\ AllowServerOutage /\ serverUp /\ Spend /\ serverUp' = FALSE
    /\ UNCHANGED <<rowVars, file, queuePaused, session, up, reg, req, ctlVars, budget,
                   pub, earlyOffer, exempt, sent, ctlReordered>>

ServerUp ==
    /\ ~serverUp /\ Spend /\ serverUp' = TRUE
    /\ UNCHANGED <<rowVars, file, queuePaused, session, up, reg, req, ctlVars, budget,
                   pub, earlyOffer, exempt, sent, ctlReordered>>

\* Sign-out, or the user selects another backend: the row's own session is
\* gone.  pauseDownloadsForBackendSignOut pauses the active rows first.
SessionLost ==
    /\ AllowSessionLoss /\ up /\ session /\ Spend
    /\ session' = FALSE
    /\ LET hit == {r \in Rows : present[r] /\ Life(r) \in Active}
       IN /\ \A r \in hit : UserCtlRoom(r)
          /\ st' = [r \in Rows |-> IF r \in hit THEN PausedState(r) ELSE st[r]]
          /\ SetCtl(pending \cup {PauseCtl(r) : r \in hit}, applied)
    /\ UNCHANGED <<present, attempt, recorded, file, queuePaused, serverUp, up, reg, req,
                   parked, cancelled, budget, pub, earlyOffer, exempt, sent, ctlReordered>>

SessionBack ==
    /\ ~session /\ Spend /\ session' = TRUE
    /\ UNCHANGED <<rowVars, file, queuePaused, serverUp, up, reg, req, ctlVars, budget,
                   pub, earlyOffer, exempt, sent, ctlReordered>>

\* Process death: every in-memory variable returns to its Init value.
Crash ==
    /\ AllowCrash /\ up /\ Spend
    /\ up' = FALSE
    /\ reg' = Const(Rows, {})
    /\ req' = Const(Rows, IdleReqs)
    /\ parked' = Const(Rows, BothOwners(FALSE))
    /\ cancelled' = Const(Rows, BothOwners(FALSE))
    /\ applied' = Const(Rows, BothOwners(0))
    /\ pending' = {}
    /\ budget' = Const(Rows, ZeroItems)
    /\ pub' = Const(Rows, {})
    /\ earlyOffer' = Const(Rows, FALSE)
    /\ exempt' = Const(Rows, FALSE)
    /\ sent' = Const(Rows, ZeroItems)
    /\ UNCHANGED <<rowVars, file, queuePaused, serverUp, session, ctlReordered>>

\* Nothing is scheduled here: EarlyPoster and Repair are enabled again.
Relaunch ==
    /\ ~up /\ up' = TRUE
    /\ UNCHANGED <<rowVars, file, queuePaused, serverUp, session, reg, req, ctlVars,
                   budget, pub, earlyOffer, exempt, sent, ctlReordered, env>>

-----------------------------------------------------------------------------
EnvironmentNext ==
    \/ PauseAll \/ ResumeAll \/ ServerDown \/ ServerUp \/ SessionLost \/ SessionBack
    \/ Crash
    \/ \E r \in Rows :
          \/ UserPause(r) \/ ResumeSameAttempt(r) \/ ResumeFreshAttempt(r)
          \/ ResumeRefused(r) \/ UserDelete(r) \/ UserAdd(r)
          \/ TransferFails(r) \/ StorageInterrupt(r) \/ ReleaseKeepingRow(r)

TransferNext == \E r \in Rows : StartTransfer(r) \/ BodyFinished(r) \/ Finalized(r)
DeliverNext == \E d \in pending : Deliver(d)
AdmitNext == \E r \in Rows, it \in Items : Admit(r, it)
RespondNext == \E r \in Rows, it \in Items : Respond(r, it)
WorkerNext ==
    \E r \in Rows :
        \/ \E it \in AssetItems : Promote(r, it)
        \/ \E i \in 1..NSubs : LoopNext(r, i)
        \/ \E k \in Kinds : TaskFinish(r, k)
        \/ RefreshDone(r)

Next ==
    \/ EnvironmentNext \/ Relaunch \/ TransferNext \/ DeliverNext \/ AdmitNext
    \/ RespondNext \/ WorkerNext
    \/ \E r \in Rows : EarlyPoster(r) \/ Repair(r)

Spec == Init /\ [][Next]_vars

\* Fairness for the liveness checks.  The transfer, the coordinator, the
\* server and the workers keep going; Repair keeps coming back, because the
\* foreground and backend-ready edges that run it recur; a dead process is
\* relaunched.  The environment is not fair and is bounded by EnvBudget.
FairSpec ==
    /\ Spec
    /\ WF_vars(Relaunch)
    /\ WF_vars(TransferNext)
    /\ WF_vars(DeliverNext)
    /\ WF_vars(AdmitNext)
    /\ WF_vars(RespondNext)
    /\ WF_vars(WorkerNext)
    /\ \A r \in Rows : WF_vars(Repair(r))

-----------------------------------------------------------------------------
(* Properties                                                              *)

TypeOK ==
    /\ present \in [Rows -> BOOLEAN]
    /\ \A r \in Rows : st[r].lifecycle \in Lifecycles /\ st[r].pauseCause \in PauseCauses
    /\ attempt \in [Rows -> 0..MaxAttempt]
    /\ recorded \in [Rows -> SUBSET AssetItems]
    /\ file \in [Rows -> SUBSET AssetItems]
    /\ queuePaused \in BOOLEAN /\ serverUp \in BOOLEAN /\ session \in BOOLEAN
    /\ up \in BOOLEAN
    /\ reg \in [Rows -> SUBSET WorkKinds]
    /\ req \in [Rows -> [Items -> ReqStates]]
    /\ parked \in [Rows -> [Owners -> BOOLEAN]]
    /\ cancelled \in [Rows -> [Owners -> BOOLEAN]]
    /\ \A r \in Rows, o \in Owners : applied[r][o] \in Nat
    /\ \A d \in pending :
          /\ d.r \in Rows /\ d.o \in Owners /\ d.cmd \in {"park", "unpark", "cancel"}
          /\ d.ver \in Nat /\ d.registers \in BOOLEAN /\ d.item \in Items \cup {NoItem}
    /\ budget \in [Rows -> [Items -> 0..MaxDispatch]]
    /\ pub \in [Rows -> SUBSET AssetItems]
    /\ earlyOffer \in [Rows -> BOOLEAN]
    /\ exempt \in [Rows -> BOOLEAN]
    /\ sent \in [Rows -> [Items -> 0..(MaxDispatch + 1)]]
    /\ ctlReordered \in BOOLEAN
    /\ env \in 0..EnvBudget

\* A request that is not idle belongs to a registered task, and a row that
\* does not exist has no work.
WorkIsRegistered ==
    \A r \in Rows :
        /\ \A it \in Items : req[r][it] # "idle" => KindOf(it) \in reg[r]
        /\ ~present[r] => reg[r] = {}

\* B25.  Every side-asset request, the source-metadata refresh included, is
\* inside the coordinator's concurrency cap and the per-launch budget.
RepairWithinRateLimit ==
    /\ ActiveCount <= MaxConcurrent
    /\ \A r \in Rows, it \in Items : sent[r][it] <= MaxDispatch

\* B32.  No park, unpark or cancel takes effect after a later-requested one.
ControlsApplyInRequestOrder == ~ctlReordered

\* Once every command for a user-paused row has landed, none of its parked
\* payloads is on the network.  The poster is exempt by design.
PausedRowNotFetching ==
    \A r \in Rows :
        (/\ present[r] /\ Life(r) = "paused" /\ st[r].pauseCause = "user"
         /\ \A d \in pending : ~(d.r = r /\ d.o = "attempt"))
        => \A it \in Items : OwnerOf(it) = "attempt" => req[r][it] # "inflight"

\* Delete leaves no side-asset file behind.
NoOrphanAfterDelete == \A r \in Rows : ~present[r] => file[r] = {}

\* #394.  Chapter payloads waiting for preparation are bounded.
PayloadsBounded ==
    "chapters" \in Kinds =>
        \A r \in Rows :
            Cardinality({c \in ItemsOf("chapters") : req[r][c] = "ready"}) <= PayloadLimit

\* The environment has stopped and nothing stands in the way of a fetch.
Calm ==
    /\ up /\ serverUp /\ session /\ ~queuePaused
    /\ BoundEnvironment /\ env = 0

\* The asset is cached, or this launch's budget records that it was tried.
\* The budget is the only record there is; the next launch starts it afresh,
\* and the inventory re-derives what is missing from metadata and files.
Accounted(r, it) ==
    \/ Have(r, it)
    \/ budget[r][it] >= MaxDispatch
    \/ KindOf(it) \in Discovered /\ budget[r][RefreshItem] >= MaxDispatch

AllAccounted ==
    \A r \in Rows :
        (present[r] /\ Life(r) \in Playable) => \A it \in AssetItems : Accounted(r, it)

\* Never forgotten.  For a complete or unverified row, every eligible asset
\* ends cached or accounted for by the retry budget.
NeverForgotten == Calm ~> (AllAccounted \/ ~Calm)

AllAvailableCached ==
    \A r \in Rows :
        (present[r] /\ Life(r) \in Playable) =>
            \A it \in AssetItems : KindOf(it) \in ServerHas => Have(r, it)

\* The stronger reading: an asset the server has is cached without a
\* relaunch, once the server is reachable.
AvailableEventuallyCached == Calm ~> (AllAvailableCached \/ ~Calm)
=============================================================================
