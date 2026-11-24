------------------------ MODULE DownloadsSideAssets ------------------------
(***************************************************************************)
(* Optional side assets of a download: the poster, chapter images, the     *)
(* trick-play index (Plex BIF, Emby BIF), Jellyfin trickplay (a playlist   *)
(* and its tiles) and external text subtitles.  The question the model     *)
(* answers is whether an asset can be forgotten: missing, the server has   *)
(* it, and nothing durable leads to a fetch that asks for it.              *)
(*                                                                         *)
(* Actors:                                                                 *)
(*   User       UserPause, PauseAll, ResumeAll, ResumeSameAttempt,         *)
(*              ResumeFreshAttempt, ResumeRefused, UserDelete, UserAdd,    *)
(*              SwitchBackend                                              *)
(*   Transfer   the main download, abstract: StartTransfer, BodyFinished,  *)
(*              Finalized, TransferFails, StorageInterrupt,                *)
(*              ReleaseKeepingRow                                          *)
(*   Passes     what offers side-asset work: the initial pass inside       *)
(*              StartTransfer, EarlyPoster, the pass inside                *)
(*              ResumeSameAttempt, and the completed-row scan.  The scan   *)
(*              is an edge (launch, foreground, backend ready or           *)
(*              switched, Resume All) that starts one inventory pass:      *)
(*              Edge, PassApply, PassTimeout, PassRerun                    *)
(*   Workers    one registered task per row and work kind: LoopNext,       *)
(*              TilesEnter, PlaylistDrop, Promote (or PromoteCheck,        *)
(*              PromoteRename, PromoteConfirm), ZombieConfirm,             *)
(*              TaskFinish, RefreshDone                                    *)
(*   Fetches    SideAssetFetchCoordinator: Deliver (a park, unpark or      *)
(*              cancel command reaching the coordinator), Admit            *)
(*   Store      DeleteFinish (the row-deletion worker)                     *)
(*   Server     Respond; ServerDown and ServerUp; SessionLost and          *)
(*              SessionBack (sign-out and sign-in of one backend)          *)
(*   Process    Crash, Quit, Relaunch                                      *)
(*                                                                         *)
(* A work kind is one registry entry (DownloadWorkRegistry.startIfAbsent): *)
(*   poster     one request, under its own coordinator owner that Pause    *)
(*              never parks                                                *)
(*   chapters   NChapters requests, all entered at once (a task group),    *)
(*              prepared one at a time, recorded in one batch              *)
(*   bif        one request for the BIF of one Plex part; on a completed   *)
(*              row its availability is only known after a                 *)
(*              source-metadata refresh                                    *)
(*   subs       NSubs requests entered one after the other, recorded in    *)
(*              one batch; a completed row always offers a refresh for     *)
(*              them                                                       *)
(*   tiles      Jellyfin trickplay: the playlist request, then NTiles      *)
(*              tile requests entered at once (a task group) and prepared  *)
(*              one at a time, then the local playlist; tiles and          *)
(*              playlist are recorded in one batch, and only when the      *)
(*              playlist was written                                       *)
(*   refresh    the source-metadata request that rediscovers bif and subs  *)
(*                                                                         *)
(* Abstractions (README.md lists what is not covered):                     *)
(*  - One server origin per backend.  The coordinator's                    *)
(*    one-start-per-second pacing is not modelled; its concurrency cap     *)
(*    and the retry budget are.                                            *)
(*  - A fetch-entry command and the fetch that follows it are two steps:   *)
(*    the command is issued (req "entering"), then Deliver applies it and  *)
(*    queues the request.  Commands issued in one step share a version.    *)
(*  - Versions are kept as ranks (NormPending), which preserves their      *)
(*    order and keeps the state finite.                                    *)
(*  - Cancelling a registered task resets its requests in the same step,   *)
(*    after recording what it had already promoted.                        *)
(*  - A replacement attempt is a new coordinator owner and a new registry  *)
(*    key, so the row's in-memory side-asset state restarts empty.  A      *)
(*    rename the old attempt had in flight is kept as a "zombie" and runs  *)
(*    into the store's fence.                                              *)
(*  - Delete is two steps: UserDelete stages the deletion (the durable     *)
(*    barrier and the list of paths), DeleteFinish removes the files and   *)
(*    the row.  The server-cleanup journal is DownloadsCleanup's.          *)
(*  - With FinePromotion a promotion is the store's three steps: the       *)
(*    snapshot, the rename (after the generation check) and the            *)
(*    confirmation under the lock.  Without it a promotion is one step.    *)
(*  - A session means a hydrated session for the row's own backend that    *)
(*    matches the server and user the row was downloaded from              *)
(*    (BackendSession.matchesPersistedServer).  A session for another      *)
(*    server or user of the same backend is no session.                    *)
(*  - The main transfer is the reducer's lifecycle and nothing else.       *)
(*                                                                         *)
(* Lifecycle changes only through Reduce (DownloadsReducer.tla); each row  *)
(* keeps a whole reducer state.                                            *)
(***************************************************************************)
\* MODELS: Labstream/Capabilities/Downloads/Core/DownloadManager+SideCache.swift
\* MODELS: Labstream/Capabilities/Downloads/Core/DownloadManager+Jellyfin.swift
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
    NTiles,               \* Jellyfin trickplay tiles per row
    ServerHas,            \* the kinds the server can produce for the row's chosen source
    UnownedRows,          \* rows that start complete with no attempt ID (a malformed index)
    OtherBackendRows,     \* rows on the backend that is not selected at the start
    ChosenPartIsFirst,    \* Plex: the downloaded part is the media's first part
    BifOnFirstPart,       \* Plex: the first part advertises a BIF (only read when the chosen part is not first)
    MaxAttempt,           \* attempt IDs are 1..MaxAttempt
    MaxConcurrent,        \* SideAssetRequestPolicy.maximumConcurrentRequests
    MaxDispatch,          \* DownloadSideAssetRetryBudget.defaultMaximumDispatches
    MaxPending,           \* bound on undelivered user commands per row
    PayloadLimit,         \* PayloadsBounded: payloads of one task group allowed to wait for preparation
    FinePromotion,        \* TRUE: a promotion is three steps (snapshot, rename, confirm)
    TrackEdges,           \* TRUE: record repair edges for NoEdgeLost, and let an edge arrive while a pass runs
    FixB25,               \* the source-metadata refresh goes through the coordinator and the budget
    FixB32,               \* the coordinator drops a command older than one it has applied
    FixPublicationOwners, \* Delete also removes a file that is renamed but not yet recorded
    FixPosterReregisters, \* PROPOSED (not in the code): a poster fetch reopens its cancelled owner (S1)
    FixResumeAllUnparks,  \* PROPOSED (not in the code): Resume All unparks every row that is not paused (S2)
    FixUnparkOnAccept,    \* PROPOSED (not in the code): Resume unparks only once the resume is accepted (S4)
    FixPassReruns,        \* PROPOSED (not in the code): a dropped, timed-out or stale repair pass runs again (S5)
    FixHydrateCompleted,  \* PROPOSED (not in the code): launch restores the session of a backend whose completed rows miss assets (S6)
    FixBifChosenPart,     \* PROPOSED (not in the code): the BIF request names the downloaded part (S7)
    PayloadWindow,        \* PROPOSED (#394): payloads of one task group fetched but not yet promoted; 0 = no window
    Mutation,             \* an injected bug for a Mutant config; "none" otherwise
    AllowCrash,           \* environment switches: what the user, the transfer and the server may do
    AllowQuit,
    AllowPauseAll,
    AllowCancelKeepingAttempt,
    AllowRefusedResume,
    AllowStoragePark,
    AllowSessionLoss,
    AllowServerOutage,
    AllowPassTimeout,
    AllowBackendSwitch,
    BoundEnvironment,     \* TRUE: at most EnvBudget environment steps
    EnvBudget

AllKinds == {"poster", "chapters", "bif", "subs", "tiles"}
\* Kinds whose availability a completed row can only learn from the server.
Discovered == {"bif", "subs"}
\* Kinds fetched as a task group whose payloads wait for one serial preparation.
Grouped == {"chapters", "tiles"}
\* Injected bugs:
\*   noDiscovery          the refresh never starts the kinds it discovers
\*   payloadsFail         no asset request ever returns a payload
\*   windowChaptersOnly   the #394 window covers chapter images and not tiles
\*   confirmUnfenced      a rename that lost its row keeps its file
Mutations == {"none", "noDiscovery", "payloadsFail", "windowChaptersOnly", "confirmUnfenced"}

ASSUME /\ Kinds \subseteq AllKinds /\ Kinds # {}
       /\ ServerHas \subseteq AllKinds
       /\ UnownedRows \subseteq Rows /\ OtherBackendRows \subseteq Rows
       /\ NChapters \in Nat \ {0} /\ NSubs \in Nat \ {0} /\ NTiles \in Nat \ {0}
       /\ MaxAttempt \in Nat \ {0} /\ MaxConcurrent \in Nat \ {0}
       /\ MaxDispatch \in Nat \ {0} /\ MaxPending \in Nat \ {0}
       /\ PayloadLimit \in Nat /\ PayloadWindow \in Nat /\ EnvBudget \in Nat
       /\ Mutation \in Mutations

\* SYMMETRY for safety configs: nothing tells two rows apart, unless
\* UnownedRows or OtherBackendRows does.
RowSymmetry == Permutations(Rows)

\* A request is <<kind, index>>.
RefreshItem == <<"refresh", 1>>
NoItem == <<"none", 0>>
\* The trickplay playlist: the request for the server's playlist, and the
\* local playlist the task writes once its tiles are in.
PlaylistItem == <<"tiles", 0>>
TileItems == {<<"tiles", i>> : i \in 1..NTiles}
ItemsOf(k) ==
    CASE k = "chapters" -> {<<"chapters", i>> : i \in 1..NChapters}
      [] k = "subs" -> {<<"subs", i>> : i \in 1..NSubs}
      [] k = "tiles" -> {PlaylistItem} \cup TileItems
      [] OTHER -> {<<k, 1>>}
AssetItems == UNION {ItemsOf(k) : k \in Kinds}
HasDiscovery == Kinds \cap Discovered # {}
WorkKinds == Kinds \cup (IF HasDiscovery THEN {"refresh"} ELSE {})
Items == AssetItems \cup (IF HasDiscovery THEN {RefreshItem} ELSE {})
KindOf(it) == it[1]
\* The members of a task group: the requests whose payloads queue for preparation.
GroupItems(k) == IF k = "tiles" THEN TileItems ELSE ItemsOf(k)

\* DownloadManager.sideAssetOwner and posterSideAssetOwner.
Owners == {"attempt", "poster"}
OwnerOf(it) == IF KindOf(it) = "poster" THEN "poster" ELSE "attempt"

\* The two backends a config can tell apart.  "a" is selected at the start.
Backends == IF OtherBackendRows = {} THEN {"a"} ELSE {"a", "b"}
BackendOf(r) == IF r \in OtherBackendRows THEN "b" ELSE "a"

\* Plex BIF.  DownloadSideAssetPolicy.selectedPlexBIFPart looks at the
\* media's first part; the transfer downloads the chosen part.  "bif" in
\* ServerHas means the chosen part has a BIF.
AsksChosenPart == ChosenPartIsFirst \/ FixBifChosenPart
BifAdvertised == IF AsksChosenPart THEN "bif" \in ServerHas ELSE BifOnFirstPart
\* What the item the code looks at advertises for a discovered kind.
Advertised(k) == IF k = "bif" THEN BifAdvertised ELSE k \in ServerHas
\* The request, as the code builds it, returns a payload.
Produces(it) ==
    CASE it = RefreshItem -> TRUE
      [] Mutation = "payloadsFail" -> FALSE
      [] KindOf(it) = "bif" -> BifAdvertised
      [] OTHER -> KindOf(it) \in ServerHas
\* The server holds this asset for the source the row downloaded.
Served(it) == KindOf(it) \in ServerHas

\* idle      not part of a running task, or a later step of a task
\* entering  its fetch-entry command is issued and not yet delivered
\* queued    waiting in the coordinator
\* inflight  admitted; the transport is running
\* ready     the payload is in memory, waiting for validation and promotion
\* checked   FinePromotion: the store took its snapshot of the row
\* renamed   FinePromotion: the file is at its stable path, unconfirmed
\* promoted  at its stable path and owned; the metadata record is still to come
\* resolved  finished with nothing to record (failed, cancelled, or reused)
ReqStates == {"idle", "entering", "queued", "inflight", "ready", "checked", "renamed",
              "promoted", "resolved"}

VARIABLES
    \* ---- durable: the index row (survives Crash) ----
    present,      \* [Rows -> BOOLEAN]              the row exists
    st,           \* [Rows -> reducer state]        DownloadLifecycleState
    attempt,      \* [Rows -> 0..MaxAttempt]        the row's attempt ID; 0 = none
    recorded,     \* [Rows -> SUBSET AssetItems]    paths recorded in OfflineMetadata
    deleting,     \* [Rows -> BOOLEAN]              a row-deletion intent is pending
    delPaths,     \* [Rows -> SUBSET AssetItems]    the paths that intent lists
    \* ---- durable: files and defaults (survive Crash) ----
    file,         \* [Rows -> SUBSET AssetItems]    files at their stable paths
    queuePaused,  \* BOOLEAN                        the Pause All gate (UserDefaults)
    selected,     \* Backends                       the selected browse backend
    creds,        \* [Backends -> BOOLEAN]          a saved session for the rows' own server and user
    \* ---- outside the process (survives Crash) ----
    serverUp,     \* BOOLEAN                        the server answers
    \* ---- in memory (lost at Crash) ----
    up,           \* BOOLEAN                        the app process is alive
    session,      \* [Backends -> BOOLEAN]          that saved session is hydrated
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
    pass,         \* "idle" or "running"            completedSideAssetInventoryWorker
    passRows,     \* SUBSET Rows                    the rows the running pass observed
    passStale,    \* SUBSET Rows                    of those, the rows mutated since
    rerun,        \* BOOLEAN                        FixPassReruns: run the pass again
    stale,        \* [Rows -> SUBSET AssetItems]    promotions whose snapshot is out of date
    zombie,       \* [Rows -> SUBSET AssetItems]    renames in flight for an attempt that lost the row
    \* ---- ghosts (observe only; never read by an action's guard) ----
    sent,         \* [Rows -> [Items -> 0..MaxDispatch+1]]  transports started this launch
    ctlReordered, \* BOOLEAN   a command took effect after a later-requested one
    env,          \* 0..EnvBudget
    owedEdge,     \* SUBSET Rows   TrackEdges: rows an edge arrived for that no pass has scanned since
    raceDropped   \* BOOLEAN   a promotion of a live row was dropped by a concurrent row mutation

rowVars == <<present, st, attempt, recorded, deleting, delPaths>>
authVars == <<selected, creds, session>>
ctlVars == <<parked, cancelled, applied, pending>>
passVars == <<pass, passRows, passStale, rerun, owedEdge>>
promoVars == <<stale, zombie, raceDropped>>
vars == <<rowVars, file, queuePaused, authVars, serverUp, up, reg, req, ctlVars,
          budget, pub, earlyOffer, exempt, passVars, promoVars, sent, ctlReordered, env>>

Life(r) == st[r].lifecycle
\* The row exists and no deletion is staged: what every store fence checks.
Live(r) == present[r] /\ ~deleting[r]
\* The row has an attempt ID.  Every side-asset entry point needs one.
Owned(r) == attempt[r] > 0
Sess(r) == session[BackendOf(r)]
\* The asset is cached: the file exists and the metadata names it.
Have(r, it) == it \in recorded[r] /\ it \in file[r]
Missing(r, k) == {it \in ItemsOf(k) : ~Have(r, it)}
IdleReqs == [it \in Items |-> "idle"]
BothOwners(v) == [o \in Owners |-> v]
ZeroItems == [it \in Items |-> 0]
Upd2(f, r, k, v) == [f EXCEPT ![r][k] = v]
\* The reducer's lifecycles that DownloadStatus.isActiveWork covers.
ActiveWork == {"planned", "admitted", "serverPrep", "transferring", "finalizing"}

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
(* Row mutations seen by optimistic readers                                *)

\* DownloadStore.setRowLocked advances the row's mutation generation.  The
\* inventory pass drops a row whose generation moved since it was observed
\* (CompletedSideAssetInventory.matches), and a promotion that has taken
\* its snapshot gives up at its pre-rename check.
TouchPass(R) == passStale' = IF pass = "running" THEN passStale \cup (R \cap passRows) ELSE passStale
TouchPromo(R) ==
    stale' = [r \in Rows |->
                 IF r \in R THEN stale[r] \cup {it \in AssetItems : req[r][it] = "checked"}
                            ELSE stale[r]]
Touch(R) == TouchPass(R) /\ TouchPromo(R)

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
      \* The trickplay task always fetches the server's playlist first.
      [] w = "tiles" -> {PlaylistItem}
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
        \* Tiles are decided once the playlist is parsed (TilesEnter).
        ELSE IF KindOf(it) = "tiles" THEN "idle"
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

\* The row's transport counts after W starts (B25 off: the refresh goes out at once).
SentAfterStart(r, W) ==
    IF "refresh" \in W /\ ~FixB25 /\ sent[r][RefreshItem] <= MaxDispatch
        THEN [sent[r] EXCEPT ![RefreshItem] = @ + 1]
        ELSE sent[r]

\* Cancel every registered side-cache task of the row.  A fetch-entry command
\* already reserved is still delivered; it no longer carries a request.
StripItems(P, r) == {IF d.r = r THEN [d EXCEPT !.item = NoItem] ELSE d : d \in P}
\* A cancelled task still records what it has promoted: nothing checks for
\* cancellation between the rename and the metadata update.  The subtitle
\* loop is the exception; it returns at its next cancellation check and
\* drops the tracks it has collected.  The trickplay task records its batch
\* only once its local playlist is promoted.
RecordsWhenDone(r, it) ==
    /\ req[r][it] = "promoted"
    /\ KindOf(it) = "tiles" => req[r][PlaylistItem] = "promoted"
RecordedAfterCancel(r) ==
    recorded[r] \cup {it \in AssetItems : RecordsWhenDone(r, it) /\ KindOf(it) # "subs"}
\* A rename the cancelled task or the old attempt still has in flight.
Renaming(r) == {it \in AssetItems : req[r][it] = "renamed"}

-----------------------------------------------------------------------------
(* The completed-row inventory                                             *)

\* CompletedSideAssetInventory.observe and the offer filter of
\* rehydrateMissingOptionalSideAssetsForCompletedRows, for one row, given a
\* retry budget and a registry.  The inventory offers a kind only while some
\* resource of it has budget left; text subtitles are always offered, because
\* persisted metadata cannot enumerate streams that were never cached; the
\* trickplay offer is gated by the playlist's budget alone.
OffersWith(r, b, g) ==
    LET posterOffer ==
            IF "poster" \in Kinds /\ Missing(r, "poster") # {}
               /\ b[<<"poster", 1>>] < MaxDispatch
               THEN {"poster"} ELSE {}
        chapterOffer ==
            IF "chapters" \in Kinds
               /\ \E it \in Missing(r, "chapters") : b[it] < MaxDispatch
               THEN {"chapters"} ELSE {}
        tilesOffer ==
            IF "tiles" \in Kinds /\ Missing(r, "tiles") # {}
               /\ b[PlaylistItem] < MaxDispatch
               THEN {"tiles"} ELSE {}
        refreshOffer ==
            IF HasDiscovery /\ b[RefreshItem] < MaxDispatch
               /\ ("subs" \in Kinds \/ Missing(r, "bif") # {})
               THEN {"refresh"} ELSE {}
    IN (posterOffer \cup chapterOffer \cup tilesOffer \cup refreshOffer) \ g
RepairOffers(r) == OffersWith(r, budget[r], reg[r])

\* The rows a pass observes: complete or unverified, with an attempt ID.
Candidates == {r \in Rows : Live(r) /\ Owned(r) /\ Life(r) \in Playable}
\* A pass started now would start something.
EdgeUseful == \E r \in Candidates : Sess(r) /\ RepairOffers(r) # {}

\* An edge reaches rehydrateMissingOptionalSideAssetsForCompletedRows.  It
\* starts a pass, or is dropped because one is running.  The caller has
\* checked the Pause All gate.
EdgeArrives ==
    /\ IF pass = "idle" /\ Candidates # {}
          THEN /\ pass' = "running" /\ passRows' = Candidates /\ passStale' = {}
               /\ UNCHANGED rerun
          ELSE /\ UNCHANGED <<pass, passRows, passStale>>
               /\ rerun' = (rerun \/ (FixPassReruns /\ pass = "running"))
    /\ owedEdge' = IF TrackEdges THEN owedEdge \cup Candidates ELSE owedEdge

-----------------------------------------------------------------------------
Init ==
    /\ present = Const(Rows, TRUE)
    /\ st = [r \in Rows |-> IF r \in UnownedRows THEN InitialState("complete")
                                                 ELSE InitialState("admitted")]
    /\ attempt = [r \in Rows |-> IF r \in UnownedRows THEN 0 ELSE 1]
    \* An unowned row's cached bundle was retired when the index was loaded.
    /\ recorded = Const(Rows, {})
    /\ deleting = Const(Rows, FALSE)
    /\ delPaths = Const(Rows, {})
    /\ file = Const(Rows, {})
    /\ queuePaused = FALSE
    /\ selected = "a"
    /\ creds = Const(Backends, TRUE)
    /\ serverUp = TRUE
    /\ up = TRUE
    /\ session = Const(Backends, TRUE)
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
    /\ pass = "idle"
    /\ passRows = {}
    /\ passStale = {}
    /\ rerun = FALSE
    /\ stale = Const(Rows, {})
    /\ zombie = Const(Rows, {})
    /\ sent = Const(Rows, ZeroItems)
    /\ ctlReordered = FALSE
    /\ env = EnvBudget
    /\ owedEdge = {}
    /\ raceDropped = FALSE

-----------------------------------------------------------------------------
(* The main transfer, abstract                                             *)

\* A backend entry point starts the transfer and enqueues every side asset
\* from the item it just fetched, so no refresh is needed here.
StartTransfer(r) ==
    /\ up /\ Live(r) /\ Life(r) = "admitted" /\ Sess(r)
    /\ ~queuePaused \/ exempt[r]
    /\ LET t == Reduce(st[r], Ev("transferStarted"), NoFacts)
           W == {k \in Kinds : Startable(r, k) /\ (k \in Discovered => Advertised(k))}
       IN /\ IsApplied(t)
          /\ st' = Upd(st, r, t.state)
          /\ reg' = Upd(reg, r, reg[r] \cup W)
          /\ req' = Upd(req, r, ReqAfterStart(r, W))
          /\ SetCtl(pending \cup EntryCtls(r, Entering(r, W),
                                           EntryParks(r, "transferring", exempt[r]), 0),
                    applied)
    /\ Touch({r})
    /\ UNCHANGED <<present, attempt, recorded, deleting, delPaths, file, queuePaused,
                   authVars, serverUp, up, parked, cancelled, budget, pub, earlyOffer,
                   exempt, pass, passRows, rerun, owedEdge, zombie, raceDropped, sent,
                   ctlReordered, env>>

BodyFinished(r) ==
    /\ up /\ Live(r) /\ Life(r) = "transferring"
    /\ LET t == Reduce(st[r], Ev("bodyAtWorking"), NoFacts)
       IN IsApplied(t) /\ st' = Upd(st, r, t.state)
    /\ Touch({r})
    /\ UNCHANGED <<present, attempt, recorded, deleting, delPaths, file, queuePaused,
                   authVars, serverUp, up, reg, req, ctlVars, budget, pub, earlyOffer,
                   exempt, pass, passRows, rerun, owedEdge, zombie, raceDropped, sent,
                   ctlReordered, env>>

\* The terminal refresh releases the attempt with
\* .preservingFinalizerAndSideCache: side-asset work carries on.
Finalized(r) ==
    /\ up /\ Live(r) /\ Life(r) = "finalizing"
    /\ LET t1 == Reduce(st[r], EvFinalize(1, "complete", "src"), NoFacts)
           t2 == Reduce(t1.state, EvPromotion("promotionCommitted", "complete"), NoFacts)
       IN IsApplied(t1) /\ IsApplied(t2) /\ st' = Upd(st, r, t2.state)
    /\ Touch({r})
    /\ UNCHANGED <<present, attempt, recorded, deleting, delPaths, file, queuePaused,
                   authVars, serverUp, up, reg, req, ctlVars, budget, pub, earlyOffer,
                   exempt, pass, passRows, rerun, owedEdge, zombie, raceDropped, sent,
                   ctlReordered, env>>

\* Cancel the row's side-cache tasks and keep its attempt.  A rename already
\* in flight still runs into the store's confirmation.
CancelTasks(r) ==
    /\ recorded' = Upd(recorded, r, RecordedAfterCancel(r))
    /\ reg' = Upd(reg, r, {})
    /\ req' = Upd(req, r, IdleReqs)
    /\ zombie' = Upd(zombie, r, zombie[r] \cup Renaming(r))
    /\ stale' = Upd(stale, r, {})

\* A failed row is released with .preservingFinalizer: its side-cache tasks
\* are cancelled, the coordinator owners are not.
TransferFails(r) ==
    /\ up /\ Live(r) /\ Life(r) = "transferring" /\ Spend
    /\ LET t == Reduce(st[r], EvReason("transferFailed", "network"), NoFacts)
       IN IsApplied(t) /\ st' = Upd(st, r, t.state)
    /\ CancelTasks(r)
    /\ SetCtl(StripItems(pending, r), applied)
    /\ TouchPass({r})
    /\ UNCHANGED <<present, attempt, deleting, delPaths, file, queuePaused, authVars,
                   serverUp, up, parked, cancelled, budget, pub, earlyOffer, exempt,
                   pass, passRows, rerun, owedEdge, raceDropped, sent, ctlReordered>>

\* A storage-parked row: paused by the reducer, no command to the coordinator.
StorageInterrupt(r) ==
    /\ AllowStoragePark /\ up /\ Live(r) /\ Life(r) = "transferring" /\ Spend
    /\ LET t == Reduce(st[r], EvReason("transferInterrupted", "storage"), NoFacts)
       IN IsApplied(t) /\ st' = Upd(st, r, t.state)
    /\ Touch({r})
    /\ UNCHANGED <<present, attempt, recorded, deleting, delPaths, file, queuePaused,
                   authVars, serverUp, up, reg, req, ctlVars, budget, pub, earlyOffer,
                   exempt, pass, passRows, rerun, owedEdge, zombie, raceDropped, sent,
                   ctlReordered>>

\* releaseInFlight with the default .allCancellable mode for a row that
\* keeps its attempt: a Plex prep poller that finds no session, for one.
\* It cancels the tasks and both coordinator owners.
ReleaseKeepingRow(r) ==
    /\ AllowCancelKeepingAttempt /\ up /\ Live(r) /\ Life(r) = "admitted"
    /\ UserCtlRoom(r) /\ Spend
    /\ CancelTasks(r)
    /\ SetCtl(StripItems(pending, r)
                \cup {Ctl(r, o, "cancel", NextVer(r, o), FALSE, NoItem) : o \in Owners},
              applied)
    /\ TouchPass({r})
    /\ UNCHANGED <<present, st, attempt, deleting, delPaths, file, queuePaused, authVars,
                   serverUp, up, parked, cancelled, budget, pub, earlyOffer, exempt,
                   pass, passRows, rerun, owedEdge, raceDropped, sent, ctlReordered>>

-----------------------------------------------------------------------------
(* The user                                                                *)

PauseCtl(r) == Ctl(r, "attempt", "park", NextVer(r, "attempt"), FALSE, NoItem)
UnparkCtl(r) == Ctl(r, "attempt", "unpark", NextVer(r, "attempt"), FALSE, NoItem)
PausedState(r) == Reduce(st[r], EvPause("user"), NoFacts).state

\* pause(record:): a finalizing row ignores it.  The side-cache tasks stay
\* registered (.preservingSideCache); the attempt owner is parked.
UserPause(r) ==
    /\ up /\ Live(r) /\ Life(r) \in Active /\ UserCtlRoom(r) /\ Spend
    /\ st' = Upd(st, r, PausedState(r))
    /\ SetCtl(pending \cup {PauseCtl(r)}, applied)
    /\ Touch({r})
    /\ UNCHANGED <<present, attempt, recorded, deleting, delPaths, file, queuePaused,
                   authVars, serverUp, up, reg, req, parked, cancelled, budget, pub,
                   earlyOffer, exempt, pass, passRows, rerun, owedEdge, zombie,
                   raceDropped, sent, ctlReordered>>

\* pauseQueue: pauses the active rows.  A finalizing or completed row gets
\* no command.  A pass that is running starts nothing once the gate is set.
PauseAll ==
    /\ AllowPauseAll /\ up /\ ~queuePaused /\ Spend
    /\ LET hit == {r \in Rows : Live(r) /\ Life(r) \in Active}
       IN /\ \A r \in hit : UserCtlRoom(r)
          /\ st' = [r \in Rows |-> IF r \in hit THEN PausedState(r) ELSE st[r]]
          /\ SetCtl(pending \cup {PauseCtl(r) : r \in hit}, applied)
          /\ Touch(hit)
    /\ queuePaused' = TRUE
    /\ exempt' = Const(Rows, FALSE)
    /\ owedEdge' = {}
    /\ UNCHANGED <<present, attempt, recorded, deleting, delPaths, file, authVars,
                   serverUp, up, reg, req, parked, cancelled, budget, pub, earlyOffer,
                   pass, passRows, rerun, zombie, raceDropped, sent, ctlReordered>>

\* resumeQueue: clears the gate.  Paused rows are re-admitted one by one
\* (the Resume actions below); completed rows get a repair edge
\* ("queue_resumed") and, in the code as it stands, no unpark.
ResumeAll ==
    /\ up /\ queuePaused /\ Spend
    /\ queuePaused' = FALSE
    /\ exempt' = Const(Rows, FALSE)
    /\ IF FixResumeAllUnparks
          THEN LET hit == {r \in Rows : Live(r) /\ Life(r) # "paused"}
               IN /\ \A r \in hit : UserCtlRoom(r)
                  /\ SetCtl(pending \cup {UnparkCtl(r) : r \in hit}, applied)
          ELSE UNCHANGED <<pending, applied>>
    /\ EdgeArrives
    /\ UNCHANGED <<rowVars, file, authVars, serverUp, up, reg, req, parked, cancelled,
                   budget, pub, earlyOffer, promoVars, sent, ctlReordered>>

\* retryRecordAsync continuing the same attempt (a resume blob).  It unparks
\* first, then restarts the URLSession task and offers every missing asset
\* ("transfer_resume").  The discovered kinds go through a refresh.
ResumeSameAttempt(r) ==
    /\ up /\ Live(r) /\ Life(r) \in {"paused", "failed"} /\ UserCtlRoom(r) /\ Spend
    /\ LET t == Reduce(st[r], EvRetry("resumeBlob"), NoFacts)
           isExempt == exempt[r] \/ queuePaused
           W == IF Sess(r)
                   THEN {k \in Kinds \ Discovered : Startable(r, k)}
                        \cup (IF HasDiscovery /\ "refresh" \notin reg[r]
                                 THEN {"refresh"} ELSE {})
                   ELSE {}
       IN /\ IsApplied(t)
          /\ st' = Upd(st, r, t.state)
          /\ exempt' = Upd(exempt, r, isExempt)
          /\ reg' = Upd(reg, r, reg[r] \cup W)
          /\ req' = Upd(req, r, ReqAfterStart(r, W))
          /\ sent' = Upd(sent, r, SentAfterStart(r, W))
          /\ SetCtl(pending \cup {UnparkCtl(r)}
                      \cup EntryCtls(r, Entering(r, W),
                                     EntryParks(r, t.state.lifecycle, isExempt), 1),
                    applied)
    /\ Touch({r})
    /\ UNCHANGED <<present, attempt, recorded, deleting, delPaths, file, queuePaused,
                   authVars, serverUp, up, parked, cancelled, budget, pub, earlyOffer,
                   pass, passRows, rerun, owedEdge, zombie, raceDropped, ctlReordered>>

\* The memory of a row whose attempt is replaced or deleted: the registry
\* key and both coordinator owners belong to the old attempt.  The store's
\* publication owners stay until the row or the attempt is gone for good.
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
    /\ zombie' = Upd(zombie, r, zombie[r] \cup Renaming(r))
    /\ stale' = Upd(stale, r, {})

\* A retry that seeds a replacement attempt.  The cached bundle is fenced to
\* the old attempt: the store clears the recorded paths and retires those
\* files.  A file that was renamed but not yet recorded is not among them.
ResumeFreshAttempt(r) ==
    /\ up /\ Live(r) /\ Life(r) \in {"paused", "failed"}
    /\ attempt[r] < MaxAttempt /\ Spend
    /\ LET t == Reduce(st[r], EvRetry("freshAttempt"), NoFacts)
       IN IsApplied(t) /\ st' = Upd(st, r, t.state)
    /\ attempt' = Upd(attempt, r, attempt[r] + 1)
    /\ file' = Upd(file, r, file[r] \ recorded[r])
    /\ recorded' = Upd(recorded, r, {})
    /\ exempt' = Upd(exempt, r, exempt[r] \/ queuePaused)
    /\ ForgetRowMemory(r)
    /\ TouchPass({r})
    /\ UNCHANGED <<present, deleting, delPaths, queuePaused, authVars, serverUp, up,
                   pass, passRows, rerun, owedEdge, raceDropped, ctlReordered>>

\* retryRecordAsync unparks before its own guards.  A resume the storage cap
\* or a missing backend then refuses leaves the row paused and unparked.
ResumeRefused(r) ==
    /\ AllowRefusedResume /\ up /\ Live(r) /\ Life(r) = "paused"
    /\ UserCtlRoom(r) /\ Spend
    /\ IF FixUnparkOnAccept THEN UNCHANGED <<pending, applied>>
                            ELSE SetCtl(pending \cup {UnparkCtl(r)}, applied)
    /\ UNCHANGED <<rowVars, file, queuePaused, authVars, serverUp, up, reg, req, parked,
                   cancelled, budget, pub, earlyOffer, exempt, passVars, promoVars, sent,
                   ctlReordered>>

\* delete(record:) submits the row deletion: the store appends a durable
\* rowDeletion intent that lists the paths the row references (the recorded
\* ones and the ones a rename has published but metadata has not recorded
\* yet).  From here every store fence rejects the row's side-asset work, and
\* the manager cancels its tasks.
UserDelete(r) ==
    /\ up /\ Live(r) /\ Spend
    /\ deleting' = Upd(deleting, r, TRUE)
    /\ delPaths' = Upd(delPaths, r, recorded[r] \cup
                                    (IF FixPublicationOwners THEN pub[r] ELSE {}))
    /\ exempt' = Upd(exempt, r, FALSE)
    /\ ForgetRowMemory(r)
    /\ TouchPass({r})
    /\ owedEdge' = owedEdge \ {r}
    /\ UNCHANGED <<present, st, attempt, recorded, file, queuePaused, authVars, serverUp,
                   up, pass, passRows, rerun, raceDropped, ctlReordered>>

\* executeRowDeletion: the artifact worker removes the listed files and then
\* the row.  A prepared intent is replayed after a relaunch.
DeleteFinish(r) ==
    /\ up /\ present[r] /\ deleting[r]
    /\ present' = Upd(present, r, FALSE)
    /\ deleting' = Upd(deleting, r, FALSE)
    /\ delPaths' = Upd(delPaths, r, {})
    /\ st' = Upd(st, r, InitialState("admitted"))
    /\ file' = Upd(file, r, file[r] \ delPaths[r])
    /\ recorded' = Upd(recorded, r, {})
    /\ UNCHANGED <<attempt, queuePaused, authVars, serverUp, up, reg, req, ctlVars,
                   budget, pub, earlyOffer, exempt, passVars, promoVars, sent,
                   ctlReordered, env>>

\* The same item is downloaded again under a new attempt.
UserAdd(r) ==
    /\ up /\ ~present[r] /\ attempt[r] < MaxAttempt /\ Spend
    /\ present' = Upd(present, r, TRUE)
    /\ attempt' = Upd(attempt, r, attempt[r] + 1)
    /\ UNCHANGED <<st, recorded, deleting, delPaths, file, queuePaused, authVars,
                   serverUp, up, reg, req, ctlVars, budget, pub, earlyOffer, exempt,
                   passVars, promoVars, sent, ctlReordered>>

-----------------------------------------------------------------------------
(* Passes that offer work                                                  *)

\* scheduleEarlyPosters: once per launch and attempt, also for a paused row
\* and a row waiting behind Pause All.  A missing session does not consume
\* the offer.
EarlyPoster(r) ==
    /\ up /\ Live(r) /\ Owned(r) /\ "poster" \in Kinds /\ Sess(r) /\ ~earlyOffer[r]
    /\ Life(r) \in {"admitted", "transferring", "finalizing", "paused"}
    /\ Startable(r, "poster")
    /\ earlyOffer' = Upd(earlyOffer, r, TRUE)
    /\ reg' = Upd(reg, r, reg[r] \cup {"poster"})
    /\ req' = Upd(req, r, ReqAfterStart(r, {"poster"}))
    /\ SetCtl(pending \cup EntryCtls(r, Entering(r, {"poster"}), FALSE, 0), applied)
    /\ UNCHANGED <<rowVars, file, queuePaused, authVars, serverUp, up, parked, cancelled,
                   budget, pub, exempt, passVars, promoVars, sent, ctlReordered, env>>

\* A foreground edge ("scene_active").  It is not a step when it would
\* change nothing.  While a pass runs it is dropped: the code keeps no note
\* of it.
Edge ==
    /\ up /\ ~queuePaused
    /\ \/ pass = "idle" /\ (EdgeUseful \/ (TrackEdges /\ Candidates # {}))
       \/ /\ pass = "running"
          /\ \/ TrackEdges /\ ~(Candidates \subseteq owedEdge)
             \/ FixPassReruns /\ ~rerun
    /\ EdgeArrives
    /\ UNCHANGED <<rowVars, file, queuePaused, authVars, serverUp, up, reg, req, ctlVars,
                   budget, pub, earlyOffer, exempt, promoVars, sent, ctlReordered, env>>

\* The inventory worker returns and the pass dispatches.  A row whose
\* generation moved, that left the playable states or that is being deleted
\* is skipped; a row with no matching session starts nothing.
PassApply ==
    /\ up /\ pass = "running"
    /\ LET scanned == {r \in passRows \ passStale : Live(r) /\ Life(r) \in Playable}
           W(r) == IF r \in scanned /\ ~queuePaused /\ Sess(r) THEN RepairOffers(r) ELSE {}
       IN /\ reg' = [r \in Rows |-> reg[r] \cup W(r)]
          /\ req' = [r \in Rows |-> ReqAfterStart(r, W(r))]
          /\ sent' = [r \in Rows |-> SentAfterStart(r, W(r))]
          /\ SetCtl(pending \cup UNION {EntryCtls(r, Entering(r, W(r)),
                                                  EntryParks(r, Life(r), exempt[r]), 0)
                                        : r \in Rows},
                    applied)
          /\ rerun' = (FixPassReruns /\ (rerun \/ passRows # scanned))
          /\ owedEdge' = owedEdge \ scanned
    /\ pass' = "idle" /\ passRows' = {} /\ passStale' = {}
    /\ UNCHANGED <<rowVars, file, queuePaused, authVars, serverUp, up, parked, cancelled,
                   budget, pub, earlyOffer, exempt, promoVars, ctlReordered, env>>

\* The worker misses its 30 s deadline: the pass ends and starts nothing.
PassTimeout ==
    /\ AllowPassTimeout /\ up /\ pass = "running" /\ Spend
    /\ pass' = "idle" /\ passRows' = {} /\ passStale' = {}
    /\ rerun' = FixPassReruns
    /\ UNCHANGED <<rowVars, file, queuePaused, authVars, serverUp, up, reg, req, ctlVars,
                   budget, pub, earlyOffer, exempt, owedEdge, promoVars, sent,
                   ctlReordered>>

\* PROPOSED (FixPassReruns): the pass that was asked for while one ran, or
\* that could not scan every row, runs again.
PassRerun ==
    /\ up /\ pass = "idle" /\ rerun
    /\ rerun' = FALSE
    /\ IF ~queuePaused /\ Candidates # {}
          THEN pass' = "running" /\ passRows' = Candidates /\ passStale' = {}
          ELSE UNCHANGED <<pass, passRows, passStale>>
    /\ UNCHANGED <<rowVars, file, queuePaused, authVars, serverUp, up, reg, req, ctlVars,
                   budget, pub, earlyOffer, exempt, owedEdge, promoVars, sent,
                   ctlReordered, env>>

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
    /\ UNCHANGED <<rowVars, file, queuePaused, authVars, serverUp, up, reg, budget, pub,
                   earlyOffer, exempt, passVars, promoVars, sent, env>>

ActiveCount == Cardinality({x \in Rows \X Items : req[x[1]][x[2]] = "inflight"})

\* Payloads of the task group that are fetched, or being fetched, and not
\* yet promoted.
InWindow(r, k) ==
    {c \in GroupItems(k) : req[r][c] \in {"inflight", "ready", "checked", "renamed"}}
Windowed(it) ==
    /\ PayloadWindow > 0 /\ KindOf(it) \in Grouped /\ it # PlaylistItem
    /\ Mutation = "windowChaptersOnly" => KindOf(it) = "chapters"

\* schedule + admitEligibleWaiter: the concurrency cap, then the budget
\* charge at transport admission.
Admit(r, it) ==
    /\ up /\ req[r][it] = "queued" /\ ~parked[r][OwnerOf(it)]
    /\ ActiveCount < MaxConcurrent
    /\ Windowed(it) => Cardinality(InWindow(r, KindOf(it))) < PayloadWindow
    /\ IF budget[r][it] < MaxDispatch
          THEN /\ req' = Upd2(req, r, it, "inflight")
               /\ budget' = Upd2(budget, r, it, budget[r][it] + 1)
               /\ sent' = Upd2(sent, r, it, sent[r][it] + 1)
          ELSE /\ req' = Upd2(req, r, it, "resolved")
               /\ UNCHANGED <<budget, sent>>
    /\ UNCHANGED <<rowVars, file, queuePaused, authVars, serverUp, up, reg, ctlVars, pub,
                   earlyOffer, exempt, passVars, promoVars, ctlReordered, env>>

\* The transport ends: a payload, or an error (an outage, or an asset the
\* server does not have).  Either way the dispatch stays charged.
Respond(r, it) ==
    /\ up /\ req[r][it] = "inflight"
    /\ req' = Upd2(req, r, it, IF serverUp /\ Produces(it) THEN "ready" ELSE "resolved")
    /\ UNCHANGED <<rowVars, file, queuePaused, authVars, serverUp, up, reg, ctlVars,
                   budget, pub, earlyOffer, exempt, passVars, promoVars, sent,
                   ctlReordered, env>>

-----------------------------------------------------------------------------
(* Workers                                                                 *)

\* The trickplay task's tiles are all in, and whether any is usable.
TilesDone(r) == \A t \in TileItems : req[r][t] \in {"promoted", "resolved"}
AnyTile(r) == \E t \in TileItems : req[r][t] = "promoted" \/ Have(r, t)
\* The local playlist is written only after the tiles, and only with one.
Promotable(r, it) ==
    /\ it # RefreshItem /\ req[r][it] = "ready"
    /\ it = PlaylistItem => TilesDone(r) /\ AnyTile(r)

\* prepareSideAsset + promoteSideAsset in one step: the file reaches its
\* stable path and the store remembers the publication in memory.  The
\* store refuses a row that is gone or being deleted.
Promote(r, it) ==
    /\ ~FinePromotion /\ up /\ Promotable(r, it)
    /\ IF Live(r)
          THEN /\ file' = Upd(file, r, file[r] \cup {it})
               /\ pub' = Upd(pub, r, pub[r] \cup {it})
               /\ req' = Upd2(req, r, it, "promoted")
               /\ TouchPass({r})
          ELSE /\ req' = Upd2(req, r, it, "resolved")
               /\ UNCHANGED <<file, pub, passStale>>
    /\ UNCHANGED <<rowVars, queuePaused, authVars, serverUp, up, reg, ctlVars, budget,
                   earlyOffer, exempt, pass, passRows, rerun, owedEdge, promoVars, sent,
                   ctlReordered, env>>

\* promoteSideAssetStagingFile, first part: the path lease and the snapshot
\* of the row's generations.  A lease another promotion of the same path
\* holds, or a row that is gone or being deleted, ends the promotion.
PromoteCheck(r, it) ==
    /\ FinePromotion /\ up /\ Promotable(r, it)
    /\ req' = Upd2(req, r, it, IF Live(r) /\ it \notin zombie[r] THEN "checked"
                                                                 ELSE "resolved")
    /\ stale' = Upd(stale, r, stale[r] \ {it})
    /\ UNCHANGED <<rowVars, file, queuePaused, authVars, serverUp, up, reg, ctlVars,
                   budget, pub, earlyOffer, exempt, passVars, zombie, raceDropped, sent,
                   ctlReordered, env>>

\* Second part: the generation check, then the rename.  Any mutation of the
\* row since the snapshot ends the promotion; the caller does not retry.
PromoteRename(r, it) ==
    /\ FinePromotion /\ up /\ req[r][it] = "checked"
    /\ IF it \in stale[r]
          THEN /\ req' = Upd2(req, r, it, "resolved")
               /\ stale' = Upd(stale, r, stale[r] \ {it})
               /\ raceDropped' = (raceDropped \/ Live(r))
               /\ UNCHANGED file
          ELSE /\ req' = Upd2(req, r, it, "renamed")
               /\ file' = Upd(file, r, file[r] \cup {it})
               /\ UNCHANGED <<stale, raceDropped>>
    /\ UNCHANGED <<rowVars, queuePaused, authVars, serverUp, up, reg, ctlVars, budget,
                   pub, earlyOffer, exempt, passVars, zombie, sent, ctlReordered, env>>

\* The paths a row still references: recorded, published in memory, or
\* listed by its pending deletion.
Referenced(r) == recorded[r] \cup pub[r] \cup delPaths[r]

\* Third part, under the lock: the row must still be the snapshot's, with no
\* other promotion confirmed in between.  Otherwise the file is removed,
\* unless some row references the path.
PromoteConfirm(r, it) ==
    /\ FinePromotion /\ up /\ req[r][it] = "renamed"
    /\ IF Live(r) /\ it \notin stale[r]
          THEN /\ pub' = Upd(pub, r, pub[r] \cup {it})
               /\ req' = Upd2(req, r, it, "promoted")
               \* The confirmation advances both generations.
               /\ stale' = Upd(stale, r, {x \in AssetItems \ {it} :
                                             req[r][x] \in {"checked", "renamed"}})
               /\ TouchPass({r})
               /\ UNCHANGED <<file, raceDropped>>
          ELSE /\ req' = Upd2(req, r, it, "resolved")
               /\ file' = Upd(file, r, IF it \in Referenced(r) THEN file[r]
                                                               ELSE file[r] \ {it})
               /\ stale' = Upd(stale, r, stale[r] \ {it})
               /\ raceDropped' = (raceDropped \/ Live(r))
               /\ UNCHANGED <<pub, passStale>>
    /\ UNCHANGED <<rowVars, queuePaused, authVars, serverUp, up, reg, ctlVars, budget,
                   earlyOffer, exempt, pass, passRows, rerun, owedEdge, zombie, sent,
                   ctlReordered, env>>

\* The confirmation of a rename whose task was cancelled, or whose attempt
\* was replaced or deleted: the store finds no owner and removes the file,
\* unless a row references the path.
ZombieConfirm(r, it) ==
    /\ up /\ it \in zombie[r]
    /\ zombie' = Upd(zombie, r, zombie[r] \ {it})
    /\ file' = Upd(file, r, IF it \in Referenced(r) \/ Mutation = "confirmUnfenced"
                               THEN file[r] ELSE file[r] \ {it})
    /\ UNCHANGED <<rowVars, queuePaused, authVars, serverUp, up, reg, req, ctlVars,
                   budget, pub, earlyOffer, exempt, passVars, stale, raceDropped, sent,
                   ctlReordered, env>>

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
    /\ UNCHANGED <<rowVars, file, queuePaused, authVars, serverUp, up, reg, parked,
                   cancelled, budget, pub, earlyOffer, exempt, passVars, promoVars, sent,
                   ctlReordered, env>>

\* The trickplay playlist is parsed: every tile the row does not already
\* own enters its fetch at once (a task group).
TilesEnter(r) ==
    /\ up /\ "tiles" \in Kinds /\ "tiles" \in reg[r]
    /\ req[r][PlaylistItem] = "ready"
    /\ \A t \in TileItems : req[r][t] = "idle"
    /\ LET fetch == {t \in TileItems : ~Have(r, t)}
       IN /\ req' = Upd(req, r, [it \in Items |->
                                    IF it \in fetch THEN "entering"
                                    ELSE IF it \in TileItems THEN "resolved"
                                    ELSE req[r][it]])
          /\ SetCtl(pending \cup EntryCtls(r, fetch, EntryParks(r, Life(r), exempt[r]), 0),
                    applied)
    /\ UNCHANGED <<rowVars, file, queuePaused, authVars, serverUp, up, reg, parked,
                   cancelled, budget, pub, earlyOffer, exempt, passVars, promoVars, sent,
                   ctlReordered, env>>

\* No tile was cached or reused: the task ends without a local playlist.
PlaylistDrop(r) ==
    /\ up /\ "tiles" \in Kinds /\ "tiles" \in reg[r]
    /\ req[r][PlaylistItem] = "ready" /\ TilesDone(r) /\ ~AnyTile(r)
    /\ req' = Upd2(req, r, PlaylistItem, "resolved")
    /\ UNCHANGED <<rowVars, file, queuePaused, authVars, serverUp, up, reg, ctlVars,
                   budget, pub, earlyOffer, exempt, passVars, promoVars, sent,
                   ctlReordered, env>>

\* The task has nothing left to do.
TaskDone(r, k) ==
    IF k = "tiles"
       THEN /\ req[r][PlaylistItem] \in {"promoted", "resolved"}
            /\ \A t \in TileItems : req[r][t] \in {"idle", "promoted", "resolved"}
       ELSE \A it \in ItemsOf(k) : req[r][it] \in {"promoted", "resolved"}

\* The task's one metadata update, and the end of its registry entry.  The
\* store refuses the update for a row that is gone or being deleted.
TaskFinish(r, k) ==
    /\ up /\ k \in Kinds /\ k \in reg[r] /\ TaskDone(r, k)
    /\ LET adds == {it \in ItemsOf(k) : RecordsWhenDone(r, it)}
       IN IF Live(r) /\ adds # {}
             THEN recorded' = Upd(recorded, r, recorded[r] \cup adds) /\ Touch({r})
             ELSE UNCHANGED <<recorded, passStale, stale>>
    /\ reg' = Upd(reg, r, reg[r] \ {k})
    /\ req' = Upd(req, r, [it \in Items |-> IF KindOf(it) = k THEN "idle" ELSE req[r][it]])
    /\ UNCHANGED <<present, st, attempt, deleting, delPaths, file, queuePaused, authVars,
                   serverUp, up, ctlVars, budget, pub, earlyOffer, exempt, pass, passRows,
                   rerun, owedEdge, zombie, raceDropped, sent, ctlReordered, env>>

\* The refresh ends.  With the current item it starts the discovered kinds
\* that item advertises, unless the row is failed or paused by then.
RefreshDone(r) ==
    /\ up /\ Live(r) /\ "refresh" \in reg[r]
    /\ req[r][RefreshItem] \in {"ready", "resolved"}
    /\ LET W == IF /\ req[r][RefreshItem] = "ready" /\ Life(r) \notin {"failed", "paused"}
                   /\ Mutation # "noDiscovery"
                   THEN {k \in Kinds \cap Discovered : Startable(r, k) /\ Advertised(k)}
                   ELSE {}
           started == [ReqAfterStart(r, W) EXCEPT ![RefreshItem] = "idle"]
       IN /\ reg' = Upd(reg, r, (reg[r] \ {"refresh"}) \cup W)
          /\ req' = Upd(req, r, started)
          /\ SetCtl(pending \cup EntryCtls(r, Entering(r, W),
                                           EntryParks(r, Life(r), exempt[r]), 0),
                    applied)
    /\ UNCHANGED <<rowVars, file, queuePaused, authVars, serverUp, up, parked, cancelled,
                   budget, pub, earlyOffer, exempt, passVars, promoVars, sent,
                   ctlReordered, env>>

-----------------------------------------------------------------------------
(* The server, the sessions and the process                                *)

ServerDown ==
    /\ AllowServerOutage /\ serverUp /\ Spend /\ serverUp' = FALSE
    /\ UNCHANGED <<rowVars, file, queuePaused, authVars, up, reg, req, ctlVars, budget,
                   pub, earlyOffer, exempt, passVars, promoVars, sent, ctlReordered>>

ServerUp ==
    /\ ~serverUp /\ Spend /\ serverUp' = TRUE
    /\ UNCHANGED <<rowVars, file, queuePaused, authVars, up, reg, req, ctlVars, budget,
                   pub, earlyOffer, exempt, passVars, promoVars, sent, ctlReordered>>

\* Sign-out of one backend, or sign-in to it as another user or on another
\* server: the rows' own session is gone, in memory and in the keychain.
\* pauseDownloadsForBackendSignOut pauses the active rows first.
SessionLost(b) ==
    /\ AllowSessionLoss /\ up /\ creds[b] /\ Spend
    /\ creds' = Upd(creds, b, FALSE)
    /\ session' = Upd(session, b, FALSE)
    /\ LET hit == {r \in Rows : BackendOf(r) = b /\ Live(r) /\ Life(r) \in Active}
       IN /\ \A r \in hit : UserCtlRoom(r)
          /\ st' = [r \in Rows |-> IF r \in hit THEN PausedState(r) ELSE st[r]]
          /\ SetCtl(pending \cup {PauseCtl(r) : r \in hit}, applied)
          /\ Touch(hit)
    /\ UNCHANGED <<present, attempt, recorded, deleting, delPaths, file, queuePaused,
                   selected, serverUp, up, reg, req, parked, cancelled, budget, pub,
                   earlyOffer, exempt, pass, passRows, rerun, owedEdge, zombie,
                   raceDropped, sent, ctlReordered>>

\* The user signs back in to the rows' own server and user.  The backend
\* becomes the selected one, and browse-ready fires a repair edge.
SessionBack(b) ==
    /\ up /\ ~creds[b] /\ Spend
    /\ creds' = Upd(creds, b, TRUE)
    /\ session' = Upd(session, b, TRUE)
    /\ selected' = b
    /\ IF queuePaused THEN UNCHANGED passVars ELSE EdgeArrives
    /\ UNCHANGED <<rowVars, file, queuePaused, serverUp, up, reg, req, ctlVars, budget,
                   pub, earlyOffer, exempt, promoVars, sent, ctlReordered>>

\* The user selects the other backend: its saved session is restored, and
\* the switch fires a repair edge ("backend_switched").
SwitchBackend(b) ==
    /\ AllowBackendSwitch /\ up /\ b # selected /\ creds[b] /\ Spend
    /\ selected' = b
    /\ session' = Upd(session, b, TRUE)
    /\ IF queuePaused THEN UNCHANGED passVars ELSE EdgeArrives
    /\ UNCHANGED <<rowVars, file, queuePaused, creds, serverUp, up, reg, req, ctlVars,
                   budget, pub, earlyOffer, exempt, promoVars, sent, ctlReordered>>

\* Process death: every in-memory variable returns to its Init value.
ProcessEnds ==
    /\ up' = FALSE
    /\ session' = Const(Backends, FALSE)
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
    /\ pass' = "idle" /\ passRows' = {} /\ passStale' = {} /\ rerun' = FALSE
    /\ stale' = Const(Rows, {})
    /\ zombie' = Const(Rows, {})
    /\ sent' = Const(Rows, ZeroItems)
    /\ owedEdge' = {}
    /\ UNCHANGED <<rowVars, file, queuePaused, selected, creds, serverUp, ctlReordered,
                   raceDropped>>

Crash == AllowCrash /\ up /\ Spend /\ ProcessEnds

\* runLaunchDownloadRecovery restores the selected backend, then hydrates
\* only the other backends that own active work (pending server cleanup is
\* DownloadsCleanup's), then fires the launch repair edge.
HydratedAtLaunch(b) ==
    /\ creds[b]
    /\ \/ b = selected
       \/ \E r \in Rows : BackendOf(r) = b /\ Live(r) /\ Life(r) \in ActiveWork
       \/ /\ FixHydrateCompleted
          /\ \E r \in Candidates : BackendOf(r) = b /\ OffersWith(r, ZeroItems, {}) # {}

Relaunch ==
    /\ ~up /\ up' = TRUE
    /\ session' = [b \in Backends |-> HydratedAtLaunch(b)]
    /\ IF queuePaused THEN UNCHANGED passVars ELSE EdgeArrives
    /\ UNCHANGED <<rowVars, file, queuePaused, selected, creds, serverUp, reg, req,
                   ctlVars, budget, pub, earlyOffer, exempt, promoVars, sent,
                   ctlReordered, env>>

-----------------------------------------------------------------------------
EnvironmentNext ==
    \/ PauseAll \/ ResumeAll \/ ServerDown \/ ServerUp \/ Crash \/ PassTimeout
    \/ \E b \in Backends : SessionLost(b) \/ SessionBack(b) \/ SwitchBackend(b)
    \/ \E r \in Rows :
          \/ UserPause(r) \/ ResumeSameAttempt(r) \/ ResumeFreshAttempt(r)
          \/ ResumeRefused(r) \/ UserDelete(r) \/ UserAdd(r)
          \/ TransferFails(r) \/ StorageInterrupt(r) \/ ReleaseKeepingRow(r)

TransferNext == \E r \in Rows : StartTransfer(r) \/ BodyFinished(r) \/ Finalized(r)
DeliverNext == \E d \in pending : Deliver(d)
AdmitNext == \E r \in Rows, it \in Items : Admit(r, it)
RespondNext == \E r \in Rows, it \in Items : Respond(r, it)
\* One asset's promotion, and one task's own steps.
PromotionStep(r, it) ==
    \/ Promote(r, it) \/ PromoteCheck(r, it) \/ PromoteRename(r, it)
    \/ PromoteConfirm(r, it) \/ ZombieConfirm(r, it)
TaskStep(r, w) ==
    \/ w \in Kinds /\ TaskFinish(r, w)
    \/ w = "subs" /\ \E i \in 1..NSubs : LoopNext(r, i)
    \/ w = "tiles" /\ (TilesEnter(r) \/ PlaylistDrop(r))
    \/ w = "refresh" /\ RefreshDone(r)
WorkerNext ==
    \E r \in Rows :
        \/ \E it \in AssetItems : PromotionStep(r, it)
        \/ \E w \in WorkKinds : TaskStep(r, w)
PassNext == PassApply \/ PassRerun
DeleteNext == \E r \in Rows : DeleteFinish(r)
EarlyPosterNext == \E r \in Rows : EarlyPoster(r)

\* Everything the app does without a new event from outside.
SystemNext ==
    \/ TransferNext \/ DeliverNext \/ AdmitNext \/ RespondNext \/ WorkerNext
    \/ PassNext \/ DeleteNext \/ EarlyPosterNext

\* The app is terminated while it has nothing left to do, as the system
\* does to a suspended app.  A death in the middle of work is Crash.
Quit == AllowQuit /\ up /\ ~ENABLED SystemNext /\ ProcessEnds /\ UNCHANGED env

Next == EnvironmentNext \/ Relaunch \/ Quit \/ Edge \/ SystemNext

Spec == Init /\ [][Next]_vars

\* Fairness for the liveness checks.  The transfer, the coordinator, the
\* server, every task and every promotion, the pass and the deletion worker
\* keep going, and a dead process is relaunched.  Tasks are fair one by one:
\* a task that keeps restarting (S1's poster) must not stand in for another
\* task's progress.  The environment is not fair and is bounded by
\* EnvBudget.
SystemFair ==
    /\ WF_vars(Relaunch)
    /\ WF_vars(TransferNext)
    /\ WF_vars(DeliverNext)
    /\ WF_vars(AdmitNext)
    /\ WF_vars(RespondNext)
    /\ \A r \in Rows :
          /\ \A it \in AssetItems : WF_vars(PromotionStep(r, it))
          /\ \A w \in WorkKinds : WF_vars(TaskStep(r, w))
    /\ WF_vars(PassNext)
    /\ WF_vars(DeleteNext)
    /\ WF_vars(EarlyPosterNext)

\* For CachedThisLaunch: the app stays alive and repair edges keep coming.
FairSpec == Spec /\ SystemFair /\ WF_vars(Edge)

\* For NeverForgotten: no edge is assumed beyond the one each launch fires,
\* and launches keep coming (configs set AllowQuit).
DurableFairSpec == Spec /\ SystemFair /\ SF_vars(Quit)

-----------------------------------------------------------------------------
(* Properties                                                              *)

TypeOK ==
    /\ present \in [Rows -> BOOLEAN]
    /\ \A r \in Rows : st[r].lifecycle \in Lifecycles /\ st[r].pauseCause \in PauseCauses
    /\ attempt \in [Rows -> 0..MaxAttempt]
    /\ recorded \in [Rows -> SUBSET AssetItems]
    /\ deleting \in [Rows -> BOOLEAN]
    /\ delPaths \in [Rows -> SUBSET AssetItems]
    /\ file \in [Rows -> SUBSET AssetItems]
    /\ queuePaused \in BOOLEAN /\ serverUp \in BOOLEAN /\ up \in BOOLEAN
    /\ selected \in Backends
    /\ creds \in [Backends -> BOOLEAN] /\ session \in [Backends -> BOOLEAN]
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
    /\ pass \in {"idle", "running"}
    /\ passRows \subseteq Rows /\ passStale \subseteq passRows
    /\ rerun \in BOOLEAN
    /\ stale \in [Rows -> SUBSET AssetItems]
    /\ zombie \in [Rows -> SUBSET AssetItems]
    /\ sent \in [Rows -> [Items -> 0..(MaxDispatch + 1)]]
    /\ ctlReordered \in BOOLEAN
    /\ env \in 0..EnvBudget
    /\ owedEdge \subseteq Rows
    /\ raceDropped \in BOOLEAN

\* A request that is not idle belongs to a registered task, a row that does
\* not exist or is being deleted has no work, and a pass that is not running
\* holds no rows.
WorkIsRegistered ==
    /\ \A r \in Rows :
          /\ \A it \in Items : req[r][it] # "idle" => KindOf(it) \in reg[r]
          /\ ~Live(r) => reg[r] = {}
    /\ pass = "idle" => passRows = {}

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
        (/\ Live(r) /\ Life(r) = "paused" /\ st[r].pauseCause = "user"
         /\ \A d \in pending : ~(d.r = r /\ d.o = "attempt"))
        => \A it \in Items : OwnerOf(it) = "attempt" => req[r][it] # "inflight"

\* Delete leaves no side-asset file behind, once every rename that was in
\* flight has met the store's fence.
NoOrphanAfterDelete == \A r \in Rows : (~present[r] /\ zombie[r] = {}) => file[r] = {}

\* #394.  The payloads of one task group (chapter images, trickplay tiles)
\* that wait in memory for the serial preparation are bounded.
PayloadsBounded ==
    \A r \in Rows, k \in Kinds \cap Grouped :
        Cardinality({c \in GroupItems(k) : req[r][c] = "ready"}) <= PayloadLimit

\* S5.  Every repair edge is followed by a pass that scans the row as it is
\* after the edge, or by a note to run one.
NoEdgeLost == (up /\ pass = "idle" /\ ~rerun) => owedEdge = {}
\* The busy case on its own: a row an edge arrived for is one the running
\* pass observed, unless a rerun is noted.
NoEdgeOutsidePass == (up /\ pass = "running" /\ ~rerun) => owedEdge \subseteq passRows

\* S7.  A cached BIF is the index of the part that was downloaded.
CachedBifIsForChosenPart == \A r \in Rows : <<"bif", 1>> \in file[r] => AsksChosenPart

\* S8.  No promotion of a live row is thrown away because another mutation
\* of the same row came between its snapshot and its confirmation.
PromotionNotLostToRace == ~raceDropped

\* The durable record of a missing asset.  It is read from durable state
\* alone: the row has an attempt ID, the inventory of a fresh launch (an
\* empty budget, an empty registry) offers the work that fetches the asset,
\* and that fetch asks for the resource that holds it.
OfferFor(it) == IF KindOf(it) \in Discovered THEN "refresh" ELSE KindOf(it)
RetryReaches(it) == KindOf(it) = "bif" => AsksChosenPart
DurablyOwed(r, it) ==
    /\ Owned(r)
    /\ OfferFor(it) \in OffersWith(r, ZeroItems, {})
    /\ RetryReaches(it)

PlayableRows(S) == {r \in S : Live(r) /\ Life(r) \in Playable}
OwnedRows == {r \in Rows : Owned(r)}

\* Every asset the server holds for a playable row is cached, or durably owed.
MissingIsDurablyOwnedIn(S) ==
    \A r \in PlayableRows(S), it \in AssetItems :
        Served(it) => Have(r, it) \/ DurablyOwed(r, it)
MissingIsDurablyOwed == MissingIsDurablyOwnedIn(OwnedRows)
MissingIsDurablyOwedAnyRow == MissingIsDurablyOwnedIn(Rows)

AllServedCachedIn(S) ==
    \A r \in PlayableRows(S), it \in AssetItems : Served(it) => Have(r, it)

\* Nothing durable or outside the process stands in the way of a fetch: the
\* server answers, the queue is not paused, and every row's own server and
\* user has a saved session.  It says nothing about the process, the budget
\* or how many environment steps are left.
Quiet ==
    /\ serverUp /\ ~queuePaused
    /\ \A r \in Rows : present[r] => creds[BackendOf(r)]

\* Never forgotten.  While it stays quiet, every asset the server holds for
\* a complete or unverified row ends cached.  Checked under DurableFairSpec:
\* the retry budget is spent and restored launch by launch, so only a
\* durable record can keep an asset coming back.  An exhausted budget, a
\* cancelled or parked owner and a dropped pass do not satisfy it.
NeverForgotten == Quiet ~> (AllServedCachedIn(OwnedRows) \/ ~Quiet)
NeverForgottenAnyRow == Quiet ~> (AllServedCachedIn(Rows) \/ ~Quiet)

\* The same, and the process stays alive with every session hydrated.
Calm == up /\ Quiet /\ \A r \in Rows : present[r] => Sess(r)

\* The stronger reading, checked under FairSpec: an asset the server holds
\* is cached without a relaunch, as long as repair edges keep coming.
CachedThisLaunch == Calm ~> (AllServedCachedIn(OwnedRows) \/ ~Calm)
=============================================================================
