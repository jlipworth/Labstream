--------------------------- MODULE PlaybackProxy ---------------------------
\* MODELS: PMSKit/Sources/PMSKit/MediaSession/MediaSessionProxy.swift
\* MODELS: PMSKit/Sources/PMSKit/MediaSession/LoopbackOrigin.swift
\* MODELS: PMSKit/Sources/PMSKit/MediaSession/UpstreamConnection.swift
(***************************************************************************)
(* The PMSKit side of the loopback HLS proxy: one MediaSessionProxy actor, *)
(* its LoopbackOrigin (an NWListener on a serial dispatch queue), the      *)
(* untracked per-connection handler Tasks, and the UpstreamConnection and  *)
(* SessionBox that fetch upstream.  The controller side (the               *)
(* remoteHLSProxy slot) is specs/playback/restart; here the caller is      *)
(* abstract.                                                               *)
(*                                                                         *)
(* Each run of an actor between two awaits is one action, and so is each  *)
(* block on the origin's serial queue.                                     *)
(*                                                                         *)
(*   Caller   CallStandUp (standUpLoopback up to `await origin.start`),    *)
(*            Resume (the rest of standUpLoopback, plus the caller's       *)
(*            re-check), Teardown, CallerStop                              *)
(*   Proxy    DeliverStop (stop(generation:), called from a Task)          *)
(*   Queue    QueueStep: a `build` block (the body of origin.start's       *)
(*            queue.async) or a `cancel` block (origin.stop() and the      *)
(*            start's onCancel); ListenerReady, ListenerFails (the         *)
(*            listener's state handler), Accept (newConnectionHandler)     *)
(*   Handler  HeadArrives, HeadAbort (readHead), FetchStart (serve calls   *)
(*            UpstreamConnection.send), FetchOk, FetchFail (send's catch,  *)
(*            on the connection actor), Rotate (SessionBox.rotate and the  *)
(*            retry), FetchFail2                                           *)
(*                                                                         *)
(* A standUpLoopback call is an attempt o in 1..MaxOpens.  Its listener,   *)
(* its UpstreamConnection and the handlers that listener accepts are       *)
(* indexed by o; the generation the proxy hands out for it is genOf[o].    *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS
    \* Bounds.
    Controllers,       \* callers of the one proxy (the app: one, once)
    MaxOpens,          \* standUpLoopback calls, all callers together
    MaxConns,          \* connections the listeners accept, all together
    RotateBudget,      \* SeekRestartBudget.burstLimit per UpstreamConnection

    \* What the run includes.
    AllowReopen,       \* a caller may call standUpLoopback again on the same proxy
    EnvFails,          \* a listener may fail to bind or start

    \* Shipping behaviour; TRUE is the code.
    StopChecksGeneration,  \* stop(generation:)'s guard
    ReopenStopsPrior,      \* standUpLoopback stops the prior listener first
    RotateFenced,          \* adada9d3: stale-generation retry, compare-and-swap
                           \* rotate, draining (not cancelling) the old session
    RotateCAS,             \* SessionBox.rotate(ifCurrent:)'s compare

    \* The caller.  TRUE is what PlaybackController does.
    CallerCancels,     \* teardown cancels the task awaiting standUpLoopback
    CallerRechecks,    \* after standUpLoopback returns, a torn-down caller stops it

    \* Proposed fixes; FALSE is the code.
    FixCancelHandlers,     \* stop cancels the session's handler Tasks and refuses
                           \* new connections, synchronously
    FixInvalidateOnStop    \* stop invalidates the upstream URLSession

ASSUME MaxOpens \in Nat \ {0} /\ MaxConns \in Nat /\ RotateBudget \in Nat

Attempts == 1..MaxOpens
HandlerPcs == {"head", "pre", "fetch", "rotate", "fetch2", "done"}
CallerPcs == {"idle", "awaitStart", "open", "done"}

VARIABLES
    \* Callers.
    cpc,        \* where the caller is
    catt,       \* the attempt it is awaiting or holds
    chgen,      \* the generation of the handle it holds
    cwant,      \* it has torn down (Close, failure, superseded)
    ccx,        \* its task was cancelled while awaiting standUpLoopback
    copens,     \* standUpLoopback calls it made

    \* MediaSessionProxy.
    current,    \* current?.generation, 0 for nil
    genCounter, \* generationCounter
    nAtt,       \* attempts made
    owner,      \* the caller of each attempt
    genOf,      \* the generation each attempt was handed, 0 until it succeeds

    \* LoopbackOrigin.
    lref,       \* the listener `self.listener` refers to, 0 for nil
    lstate,     \* each attempt's listener: none starting ready failed cancelled
    sres,       \* each ListenerStartState result: none ok fail cancel
    queue,      \* blocks waiting on the origin's serial queue

    stops,      \* stop(generation:) calls in flight

    hs,         \* handlers: [o, pc, g (session generation of its fetch), cx (Task
                \* cancelled, the fix), late (accepted after its session was torn
                \* down), lf (started a fetch after that)]

    \* SessionBox and UpstreamConnection.
    boxGen,     \* SessionBox.generation
    boxValid,   \* the current URLSession is not invalidated
    deadGens,   \* generations whose session was cancelled
    budget,     \* rotates each attempt's UpstreamConnection still allows
    busy,       \* the handler inside a connection actor's catch, 0 for none

    \* Ghosts.
    down,         \* the proxy has torn the attempt's session down
    stopKill,     \* the generation of the stop that tore it down, 0 for none
    crossCancel,  \* a cancel block issued for one attempt cancelled another's listener
    lateFetch,    \* a handler started an upstream fetch after its session was torn down
    lateAccept,   \* a connection was served after its session was torn down
    badRotate,    \* a rotate retired a generation the rotating fetch did not use
    staleIgnored, \* a stop for another live generation was ignored
    stopSawNil,   \* a stop arrived while no session was current
    casRejected,  \* SessionBox.rotate refused a stale generation
    staleRetry,   \* send's catch took the stale-generation retry
    reopenTore    \* a re-open tore down a live session

callerVars == <<cpc, catt, chgen, cwant, ccx, copens>>
proxyVars == <<current, genCounter, nAtt, owner, genOf>>
originVars == <<lref, lstate, sres, queue>>
upVars == <<boxGen, boxValid, deadGens, budget, busy>>
ghostVars == <<down, stopKill, crossCancel, lateFetch, lateAccept, badRotate,
               staleIgnored, stopSawNil, casRejected, staleRetry, reopenTore>>
vars == <<callerVars, proxyVars, originVars, stops, hs, upVars, ghostVars>>

-----------------------------------------------------------------------------
\* Helpers.

Live(o) == lstate[o] \in {"starting", "ready"}

AttOf(g) == CHOOSE o \in Attempts : genOf[o] = g

CurAtt == IF current = 0 THEN 0 ELSE AttOf(current)

Cancel(o) == [k |-> "cancel", o |-> o]
Build(o) == [k |-> "build", o |-> o]

\* What tearing sessions S down does beyond the proxy's own fields.
DownAfter(S) == [o \in Attempts |-> down[o] \/ o \in S]

HsAfterTeardown(S) ==
    IF FixCancelHandlers
    THEN [i \in 1..Len(hs) |-> IF hs[i].o \in S THEN [hs[i] EXCEPT !.cx = TRUE] ELSE hs[i]]
    ELSE hs

\* A handler about to call makeAttempt() and fetch on the current session: with a cancelled
\* Task (the fix) or an invalidated session (the fix) no request goes out.
CanFetch(h) == ~h.cx /\ boxValid

FetchOn(h, nxt, gen) ==
    IF CanFetch(h) THEN [h EXCEPT !.pc = nxt, !.g = gen, !.lf = (h.lf \/ down[h.o])]
                   ELSE [h EXCEPT !.pc = "done"]

LateIf(h) == lateFetch \/ (CanFetch(h) /\ down[h.o])

-----------------------------------------------------------------------------
Init ==
    /\ cpc = [c \in Controllers |-> "idle"]
    /\ catt = [c \in Controllers |-> 0]
    /\ chgen = [c \in Controllers |-> 0]
    /\ cwant = [c \in Controllers |-> FALSE]
    /\ ccx = [c \in Controllers |-> FALSE]
    /\ copens = [c \in Controllers |-> 0]
    /\ current = 0
    /\ genCounter = 0
    /\ nAtt = 0
    /\ owner = [o \in Attempts |-> CHOOSE c \in Controllers : TRUE]
    /\ genOf = [o \in Attempts |-> 0]
    /\ lref = 0
    /\ lstate = [o \in Attempts |-> "none"]
    /\ sres = [o \in Attempts |-> "none"]
    /\ queue = <<>>
    /\ stops = {}
    /\ hs = <<>>
    /\ boxGen = 0
    /\ boxValid = TRUE
    /\ deadGens = {}
    /\ budget = [o \in Attempts |-> RotateBudget]
    /\ busy = [o \in Attempts |-> 0]
    /\ down = [o \in Attempts |-> FALSE]
    /\ stopKill = [o \in Attempts |-> 0]
    /\ crossCancel = FALSE
    /\ lateFetch = FALSE
    /\ lateAccept = FALSE
    /\ badRotate = FALSE
    /\ staleIgnored = FALSE
    /\ stopSawNil = FALSE
    /\ casRejected = FALSE
    /\ staleRetry = FALSE
    /\ reopenTore = FALSE

-----------------------------------------------------------------------------
\* Callers and the proxy actor.

\* standUpLoopback up to `await origin.start`: tear down a current session (re-open), make the
\* UpstreamConnection, and run start's continuation body (install, queue.async the build).
CallStandUp(c) ==
    /\ nAtt < MaxOpens
    /\ ~cwant[c]
    /\ \/ cpc[c] = "idle" /\ (AllowReopen \/ copens[c] = 0)
       \/ cpc[c] = "open" /\ AllowReopen
    /\ LET o == nAtt + 1
           prior == CurAtt
           tear == current # 0
           S == IF tear THEN {prior} ELSE {}
           inval == tear /\ FixInvalidateOnStop
           fresh == inval \/ ~boxValid
       IN /\ nAtt' = o
          /\ owner' = [owner EXCEPT ![o] = c]
          /\ queue' = queue \o (IF tear /\ ReopenStopsPrior THEN <<Cancel(prior)>> ELSE <<>>)
                            \o <<Build(o)>>
          /\ current' = 0
          /\ down' = DownAfter(S)
          /\ hs' = HsAfterTeardown(S)
          /\ deadGens' = IF inval THEN deadGens \cup {boxGen} ELSE deadGens
          /\ boxGen' = IF fresh THEN boxGen + 1 ELSE boxGen
          /\ boxValid' = TRUE
          /\ reopenTore' = (reopenTore \/ tear)
          /\ cpc' = [cpc EXCEPT ![c] = "awaitStart"]
          /\ catt' = [catt EXCEPT ![c] = o]
          /\ copens' = [copens EXCEPT ![c] = @ + 1]
          /\ ccx' = [ccx EXCEPT ![c] = FALSE]
    /\ UNCHANGED <<chgen, cwant, genCounter, genOf, lref, lstate, sres, stops,
                   budget, busy, stopKill, crossCancel, lateFetch, lateAccept, badRotate,
                   staleIgnored, stopSawNil, casRejected, staleRetry>>

\* The rest of standUpLoopback once start's continuation has resumed, and the caller's own
\* step after it returns.  Success hands out the next generation and sets `current`; the
\* PlaybackController caller then re-checks `!Task.isCancelled, generation ==
\* playbackGeneration` and stops the handle it was just given.  Failure runs the catch:
\* origin.stop(), connection = nil, current = nil.
Resume(c) ==
    /\ cpc[c] = "awaitStart"
    /\ LET o == catt[c] IN
       /\ sres[o] # "none"
       /\ IF sres[o] = "ok"
          THEN LET g == genCounter + 1 IN
               /\ genCounter' = g
               /\ genOf' = [genOf EXCEPT ![o] = g]
               /\ current' = g
               /\ IF cwant[c]
                  THEN /\ stops' = IF CallerRechecks THEN stops \cup {g} ELSE stops
                       /\ cpc' = [cpc EXCEPT ![c] = "done"]
                       /\ chgen' = chgen
                  ELSE /\ stops' = stops
                       /\ cpc' = [cpc EXCEPT ![c] = "open"]
                       /\ chgen' = [chgen EXCEPT ![c] = g]
               /\ UNCHANGED <<queue, down, hs, boxValid, deadGens, boxGen>>
          ELSE LET S == {o} \cup (IF current # 0 THEN {CurAtt} ELSE {}) IN
               /\ queue' = Append(queue, Cancel(o))
               /\ current' = 0
               /\ down' = DownAfter(S)
               /\ hs' = HsAfterTeardown(S)
               /\ boxValid' = IF FixInvalidateOnStop THEN FALSE ELSE boxValid
               /\ deadGens' = IF FixInvalidateOnStop THEN deadGens \cup {boxGen} ELSE deadGens
               /\ cpc' = [cpc EXCEPT ![c] = IF cwant[c] THEN "done" ELSE "idle"]
               /\ UNCHANGED <<genCounter, genOf, stops, chgen, boxGen>>
    /\ UNCHANGED <<catt, cwant, ccx, copens, nAtt, owner, lref, lstate, sres,
                   budget, busy, stopKill, crossCancel, lateFetch, lateAccept, badRotate,
                   staleIgnored, stopSawNil, casRejected, staleRetry, reopenTore>>

\* The caller tears down (Close, a surfaced failure, a superseding restart).  While it awaits
\* standUpLoopback that is playbackTask.cancel(): start's onCancel completes the start
\* with CancellationError if nothing else has, and queues a listener cancel.  An open caller
\* sends stop(generation:) from a Task (pendingStopTasks).
Teardown(c) ==
    /\ ~cwant[c]
    /\ cpc[c] \in {"idle", "awaitStart", "open"}
    /\ cwant' = [cwant EXCEPT ![c] = TRUE]
    /\ CASE cpc[c] = "awaitStart" ->
              /\ ccx' = [ccx EXCEPT ![c] = CallerCancels]
              /\ sres' = IF CallerCancels /\ sres[catt[c]] = "none"
                         THEN [sres EXCEPT ![catt[c]] = "cancel"] ELSE sres
              /\ queue' = IF CallerCancels THEN Append(queue, Cancel(catt[c])) ELSE queue
              /\ UNCHANGED <<cpc, stops>>
         [] cpc[c] = "open" ->
              /\ stops' = stops \cup {chgen[c]}
              /\ cpc' = [cpc EXCEPT ![c] = "done"]
              /\ UNCHANGED <<ccx, sres, queue>>
         [] OTHER ->
              /\ cpc' = [cpc EXCEPT ![c] = "done"]
              /\ UNCHANGED <<ccx, sres, queue, stops>>
    /\ UNCHANGED <<catt, chgen, copens, proxyVars, lref, lstate, hs, upVars, ghostVars>>

\* A caller that reuses the proxy stops its session and may later re-open (the API allows it;
\* PlaybackController builds a new proxy per stand-up).
CallerStop(c) ==
    /\ AllowReopen
    /\ ~cwant[c]
    /\ cpc[c] = "open"
    /\ stops' = stops \cup {chgen[c]}
    /\ cpc' = [cpc EXCEPT ![c] = "idle"]
    /\ UNCHANGED <<catt, chgen, cwant, ccx, copens, proxyVars, originVars, hs, upVars, ghostVars>>

\* stop(generation:): guard current?.generation == generation, then origin.stop(),
\* connection = nil, current = nil.  origin.stop() only queues the listener cancel.
DeliverStop(g) ==
    /\ g \in stops
    /\ stops' = stops \ {g}
    /\ IF current # 0 /\ (~StopChecksGeneration \/ current = g)
       THEN LET o == CurAtt IN
            /\ queue' = Append(queue, Cancel(AttOf(g)))
            /\ current' = 0
            /\ down' = DownAfter({o})
            /\ hs' = HsAfterTeardown({o})
            /\ boxValid' = IF FixInvalidateOnStop THEN FALSE ELSE boxValid
            /\ deadGens' = IF FixInvalidateOnStop THEN deadGens \cup {boxGen} ELSE deadGens
            /\ stopKill' = [stopKill EXCEPT ![o] = g]
            /\ UNCHANGED <<staleIgnored, stopSawNil>>
       ELSE /\ staleIgnored' = (staleIgnored \/ current # 0)
            /\ stopSawNil' = (stopSawNil \/ current = 0)
            /\ UNCHANGED <<queue, current, down, hs, boxValid, deadGens, stopKill>>
    /\ UNCHANGED <<callerVars, genCounter, nAtt, owner, genOf, lref, lstate, sres,
                   boxGen, budget, busy, crossCancel, lateFetch, lateAccept, badRotate,
                   casRejected, staleRetry, reopenTore>>

-----------------------------------------------------------------------------
\* The origin's serial queue and the listener.

\* One block.  `build` is start's queue.async body: skip if the start already completed,
\* else make the listener and assign self.listener (overwriting whatever it held), or fail
\* to make it.  `cancel` is `self.listener?.cancel(); self.listener = nil`, whichever
\* listener that is when the block runs.
QueueStep ==
    /\ queue # <<>>
    /\ queue' = Tail(queue)
    /\ LET it == Head(queue) IN
       IF it.k = "build"
       THEN IF sres[it.o] # "none"
            THEN UNCHANGED <<lref, lstate, sres, crossCancel>>
            ELSE \/ /\ lref' = it.o
                    /\ lstate' = [lstate EXCEPT ![it.o] = "starting"]
                    /\ UNCHANGED <<sres, crossCancel>>
                 \/ /\ EnvFails
                    /\ sres' = [sres EXCEPT ![it.o] = "fail"]
                    /\ UNCHANGED <<lref, lstate, crossCancel>>
       ELSE IF lref # 0
            THEN /\ lstate' = [lstate EXCEPT ![lref] = IF Live(lref) THEN "cancelled" ELSE @]
                 /\ crossCancel' = (crossCancel \/ (Live(lref) /\ lref # it.o))
                 /\ lref' = 0
                 /\ UNCHANGED sres
            ELSE UNCHANGED <<lref, lstate, sres, crossCancel>>
    /\ UNCHANGED <<callerVars, proxyVars, stops, hs, upVars, down, stopKill, lateFetch,
                   lateAccept, badRotate, staleIgnored, stopSawNil, casRejected, staleRetry,
                   reopenTore>>

ListenerReady(o) ==
    /\ lstate[o] = "starting"
    /\ lstate' = [lstate EXCEPT ![o] = "ready"]
    /\ sres' = IF sres[o] = "none" THEN [sres EXCEPT ![o] = "ok"] ELSE sres
    /\ UNCHANGED <<callerVars, proxyVars, lref, queue, stops, hs, upVars, ghostVars>>

ListenerFails(o) ==
    /\ EnvFails
    /\ lstate[o] = "starting"
    /\ lstate' = [lstate EXCEPT ![o] = "failed"]
    /\ sres' = IF sres[o] = "none" THEN [sres EXCEPT ![o] = "fail"] ELSE sres
    /\ UNCHANGED <<callerVars, proxyVars, lref, queue, stops, hs, upVars, ghostVars>>

\* newConnectionHandler -> handle(conn): start the connection and read its head.  The fix
\* refuses connections once the session is torn down.
Accept(o) ==
    /\ lstate[o] = "ready"
    /\ Len(hs) < MaxConns
    /\ ~(FixCancelHandlers /\ down[o])
    /\ hs' = Append(hs, [o |-> o, pc |-> "head", g |-> 0, cx |-> FALSE,
                          late |-> down[o], lf |-> FALSE])
    /\ lateAccept' = (lateAccept \/ down[o])
    /\ UNCHANGED <<callerVars, proxyVars, originVars, stops, upVars, down, stopKill,
                   crossCancel, lateFetch, badRotate, staleIgnored, stopSawNil, casRejected,
                   staleRetry, reopenTore>>

-----------------------------------------------------------------------------
\* Handlers: readHead, the untracked Task, serve and UpstreamConnection.send.

HandlerStep(i, newH) ==
    /\ hs' = [hs EXCEPT ![i] = newH]

HUnchanged == UNCHANGED <<callerVars, proxyVars, originVars, stops>>

\* readHead delivers the head and the Task starts (serve's P7 resource await folded in).
HeadArrives(i) ==
    /\ hs[i].pc = "head"
    /\ HandlerStep(i, [hs[i] EXCEPT !.pc = IF hs[i].cx THEN "done" ELSE "pre"])
    /\ HUnchanged /\ UNCHANGED <<upVars, ghostVars>>

\* The client closes or the read fails: done(nil), conn.cancel().
HeadAbort(i) ==
    /\ hs[i].pc = "head"
    /\ HandlerStep(i, [hs[i] EXCEPT !.pc = "done"])
    /\ HUnchanged /\ UNCHANGED <<upVars, ghostVars>>

\* connection.send: makeAttempt() captures the current session and generation and the
\* request goes out.  An actor step of the attempt's UpstreamConnection.
FetchStart(i) ==
    /\ hs[i].pc = "pre"
    /\ busy[hs[i].o] = 0
    /\ HandlerStep(i, FetchOn(hs[i], "fetch", boxGen))
    /\ lateFetch' = LateIf(hs[i])
    /\ HUnchanged
    /\ UNCHANGED <<upVars, down, stopKill, crossCancel, lateAccept, badRotate, staleIgnored,
                   stopSawNil, casRejected, staleRetry, reopenTore>>

\* A fetch returns a response; the handler sends it and closes.  A cancelled session's
\* fetches only fail.
FetchOk(i) ==
    /\ hs[i].pc \in {"fetch", "fetch2"}
    /\ hs[i].g \notin deadGens
    /\ HandlerStep(i, [hs[i] EXCEPT !.pc = "done"])
    /\ HUnchanged /\ UNCHANGED <<upVars, ghostVars>>

\* The single retry fails: the error surfaces as a 502.
FetchFail2(i) ==
    /\ hs[i].pc = "fetch2"
    /\ HandlerStep(i, [hs[i] EXCEPT !.pc = "done"])
    /\ HUnchanged /\ UNCHANGED <<upVars, ghostVars>>

\* The first fetch throws; send's catch on the connection actor.  If the session generation
\* moved on, retry once on the current session (Task.checkCancellation first).  Otherwise a
\* cancellation is not a wedge, a non-wedge error surfaces, and a wedge with budget left
\* takes the budget and goes on to rotate in the same actor step (busy holds the actor).
FetchFail(i) ==
    /\ hs[i].pc = "fetch"
    /\ LET h == hs[i]
           o == h.o
       IN
       /\ busy[o] = 0
       /\ IF RotateFenced /\ boxGen # h.g
          THEN /\ HandlerStep(i, FetchOn(h, "fetch2", boxGen))
               /\ lateFetch' = LateIf(h)
               /\ staleRetry' = TRUE
               /\ UNCHANGED <<budget, busy>>
          ELSE IF h.cx \/ h.g \in deadGens
          THEN /\ HandlerStep(i, [h EXCEPT !.pc = "done"])
               /\ UNCHANGED <<budget, busy, lateFetch, staleRetry>>
          ELSE \E wedge \in BOOLEAN :
               IF wedge /\ budget[o] > 0
               THEN /\ budget' = [budget EXCEPT ![o] = @ - 1]
                    /\ busy' = [busy EXCEPT ![o] = i]
                    /\ HandlerStep(i, [h EXCEPT !.pc = "rotate"])
                    /\ UNCHANGED <<lateFetch, staleRetry>>
               ELSE /\ HandlerStep(i, [h EXCEPT !.pc = "done"])
                    /\ UNCHANGED <<budget, busy, lateFetch, staleRetry>>
    /\ HUnchanged
    /\ UNCHANGED <<boxGen, boxValid, deadGens, down, stopKill, crossCancel, lateAccept,
                   badRotate, staleIgnored, stopSawNil, casRejected, reopenTore>>

\* rotate(attempt.generation), then `makeAttempt().response`: the retry on whatever session
\* is current.  SessionBox's lock makes the compare-and-swap atomic, but another
\* UpstreamConnection actor (another session's handlers) can run between the catch's check
\* and this step.  Before adada9d3 the rebuild was unconditional and invalidateAndCancel()
\* killed the old session's in-flight fetches.
Rotate(i) ==
    /\ hs[i].pc = "rotate"
    /\ LET h == hs[i]
           o == h.o
           doIt == /\ boxValid
                   /\ ~(FixCancelHandlers /\ h.cx)
                   /\ (~(RotateFenced /\ RotateCAS) \/ boxGen = h.g)
           ng == IF doIt THEN boxGen + 1 ELSE boxGen
       IN
       /\ boxGen' = ng
       /\ badRotate' = (badRotate \/ (doIt /\ boxGen # h.g))
       /\ casRejected' = (casRejected \/ (boxValid /\ ~doIt))
       /\ deadGens' = IF doIt /\ ~RotateFenced THEN deadGens \cup {boxGen} ELSE deadGens
       /\ busy' = [busy EXCEPT ![o] = 0]
       /\ HandlerStep(i, FetchOn(h, "fetch2", ng))
       /\ lateFetch' = LateIf(h)
    /\ HUnchanged
    /\ UNCHANGED <<boxValid, budget, down, stopKill, crossCancel, lateAccept, staleIgnored,
                   stopSawNil, staleRetry, reopenTore>>

-----------------------------------------------------------------------------
HandlerProgress(i) ==
    \/ HeadArrives(i) \/ HeadAbort(i) \/ FetchStart(i) \/ FetchOk(i)
    \/ FetchFail(i) \/ FetchFail2(i) \/ Rotate(i)

Next ==
    \/ \E c \in Controllers : CallStandUp(c) \/ Resume(c) \/ Teardown(c) \/ CallerStop(c)
    \/ \E g \in stops : DeliverStop(g)
    \/ QueueStep
    \/ \E o \in Attempts : ListenerReady(o) \/ ListenerFails(o) \/ Accept(o)
    \/ \E i \in 1..Len(hs) : HandlerProgress(i)

Spec == Init /\ [][Next]_vars

\* Weak fairness on everything the proxy, the queue, the network and the client do once they
\* have started; none on the caller's choices (stand up, tear down, stop) or on a client
\* connecting.  The head read is fair: readHead has no deadline, so this assumes the client
\* eventually sends its head or closes (AVPlayer releases its sockets).  A fetch is fair
\* because the upstream URLSession bounds it (20 s idle, 300 s per resource).
Fairness ==
    /\ WF_vars(QueueStep)
    /\ \A o \in Attempts : WF_vars(ListenerReady(o))
    /\ \A c \in Controllers : WF_vars(Resume(c))
    /\ \A g \in 1..MaxOpens : WF_vars(DeliverStop(g))
    /\ \A i \in 1..MaxConns : WF_vars(i <= Len(hs) /\ HandlerProgress(i))

FairSpec == Spec /\ Fairness

-----------------------------------------------------------------------------
\* Properties.

TypeOK ==
    /\ cpc \in [Controllers -> CallerPcs]
    /\ catt \in [Controllers -> 0..MaxOpens]
    /\ chgen \in [Controllers -> 0..MaxOpens]
    /\ cwant \in [Controllers -> BOOLEAN]
    /\ ccx \in [Controllers -> BOOLEAN]
    /\ copens \in [Controllers -> 0..MaxOpens]
    /\ current \in 0..MaxOpens
    /\ genCounter \in 0..MaxOpens
    /\ nAtt \in 0..MaxOpens
    /\ owner \in [Attempts -> Controllers]
    /\ genOf \in [Attempts -> 0..MaxOpens]
    /\ lref \in 0..MaxOpens
    /\ lstate \in [Attempts -> {"none", "starting", "ready", "failed", "cancelled"}]
    /\ sres \in [Attempts -> {"none", "ok", "fail", "cancel"}]
    /\ \A k \in 1..Len(queue) : queue[k].k \in {"build", "cancel"} /\ queue[k].o \in Attempts
    /\ stops \subseteq 1..MaxOpens
    /\ Len(hs) <= MaxConns
    /\ \A i \in 1..Len(hs) : /\ hs[i].o \in Attempts /\ hs[i].pc \in HandlerPcs
                             /\ hs[i].g \in Nat /\ hs[i].cx \in BOOLEAN
                             /\ hs[i].late \in BOOLEAN /\ hs[i].lf \in BOOLEAN
    /\ boxGen \in Nat /\ boxValid \in BOOLEAN /\ deadGens \subseteq 0..boxGen
    /\ budget \in [Attempts -> 0..RotateBudget]
    /\ busy \in [Attempts -> 0..MaxConns]

\* The queue has run and every stop call has arrived.
Drained == queue = <<>> /\ stops = {}

\* Suspect 5.  Once the proxy has torn a session down (stop, re-open or a failed start), no
\* handler of that session starts another upstream fetch.  Violated by the code.
NoFetchAfterStop == ~lateFetch

\* Once the proxy has torn a session down, its listener serves no new connection.  Violated
\* by the code: origin.stop() only queues the cancel.
NoAcceptAfterStop == ~lateAccept

\* A stop for an older generation never tears down a newer session.
StaleStopIgnored == \A o \in Attempts : stopKill[o] \in {0, genOf[o]}

\* A listener cancel only ever cancels the listener of the attempt it was issued for (or the
\* prior session a re-open meant to replace).
CancelHitsOwnListener == ~crossCancel

\* Every live listener is the one `self.listener` refers to, so some origin.stop() can still
\* reach it: no listener leaks.
SingleReachableListener == \A o \in Attempts : Live(o) => lref = o

\* A caller's teardown is not lost: once it is done and the queue and its stop calls have
\* run, none of its listeners is live.  Covers a teardown during standUpLoopback's await.
TeardownNotLost ==
    Drained =>
        \A c \in Controllers :
            (cwant[c] /\ cpc[c] = "done") =>
                \A o \in 1..nAtt : owner[o] = c => ~Live(o)

\* A rotate retires exactly the session generation the failed fetch used.
RotateRetiresFailedGeneration == ~badRotate

\* Once everything has settled with no session current, the upstream URLSession is
\* invalidated.  Violated by the code: stop never invalidates SessionBox's session.
UpstreamSessionReleased ==
    (/\ Drained /\ nAtt > 0 /\ current = 0
     /\ \A c \in Controllers : cpc[c] = "done"
     /\ \A i \in 1..Len(hs) : hs[i].pc = "done") => ~boxValid

\* Liveness.

\* Every accepted connection's handler finishes.
HandlersFinish ==
    \A i \in 1..MaxConns : (Len(hs) >= i) ~> (Len(hs) >= i /\ hs[i].pc = "done")

\* A torn-down session's listener stops listening.
StoppedListenerDies == \A o \in Attempts : down[o] ~> ~Live(o)

\* A caller's teardown completes: it is done and none of its listeners is live.
TeardownCompletes ==
    \A c \in Controllers :
        cwant[c] ~> (cpc[c] = "done" /\ \A o \in Attempts : (o <= nAtt /\ owner[o] = c) => ~Live(o))

-----------------------------------------------------------------------------
\* Witnesses: each is the negation of a state one branch reaches.  Checked as the only
\* invariant with the named config's constants, each is violated (see README).

NeverLateFetch == ~lateFetch
\* Suspect 5 in its review form: a handler accepted while its session was live starts a
\* fetch after the session was torn down.
NeverEarlyHandlerLateFetch == ~\E i \in 1..Len(hs) : ~hs[i].late /\ hs[i].lf
\* The same with the session torn down by stop(generation:) after it opened.
NeverStopKilledEarly ==
    ~\E i \in 1..Len(hs) : ~hs[i].late /\ hs[i].lf /\ stopKill[hs[i].o] # 0
NeverStaleStop == ~staleIgnored
NeverStopSawNil == ~stopSawNil
NeverTeardownDuringAwait == \A c \in Controllers : ~(cwant[c] /\ cpc[c] = "awaitStart")
NeverDeadHandle == ~(current # 0 /\ lstate[CurAtt] = "cancelled")
NeverCasRejected == ~casRejected
NeverStaleRetry == ~staleRetry
NeverReopenTeardown == ~reopenTore
NeverOrphanFetchInFlight ==
    ~\E i \in 1..Len(hs) : hs[i].pc \in {"fetch", "fetch2"} /\ down[hs[i].o]
NeverListenerFails == \A o \in Attempts : sres[o] # "fail"
NeverRotate == boxGen = 0
=============================================================================
