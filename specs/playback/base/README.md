# base: the playback vocabulary

The modules every playback model imports. They hold names and judgements, not a model of the
app: no `\* MODELS:` line appears in this folder, because no module here encodes the behaviour
of a Swift file. The server is an abstraction of Plex, Jellyfin and Emby, and the controller
state is declared here but stepped by the modules that model `PlaybackController`.

```sh
scripts/check-tla-specs.sh specs/playback/base
```

| Module | Holds |
| --- | --- |
| `PlaybackBase.tla` | the contract for writing a playback module, the constants, the abstract server and its actions, the client's start and stop requests, and what a client owns |
| `PlaybackControllerOps.tla` | one controller's in-memory state, the operators that read it, and `OneEncoder` |
| `PlaybackBaseSmoke.tla` | a toy client that exercises the two modules above; not a model of the app |

A playback module starts with `EXTENDS PlaybackControllerOps, TLC`.

## State

Nothing is durable. `server` and `stopReqs` are remote: they belong to the backend and the
network and outlive every controller, which is how a session comes to be orphaned. Everything
`PlaybackControllerOps` declares is in memory and belongs to one `PlaybackController`.

| Variable | Meaning |
| --- | --- |
| `server[s][g]` | incarnation `g` of the encoding job under session id `s` (1 for the first start under the id, one more per start): `state` (`none`, `encoding`, `stopRequested`, `stopped`), `owner`, `gen`, and the ghost fields `serverRecreated` and `endedBy` |
| `stopReqs` | every stop request sent: `c`, `sid`, `gen` (the incarnation the client meant), `n`, `status` (`inFlight`, `acked`, `failed`), `late` |
| `gen[c]`, `itemGen[c]`, `item[c]` | `playbackGeneration`; the generation the item was attached under; the item (`none`, `attached`, `detached`) |
| `task[c]`, `unwinding[c]` | the current `playbackTask` (`gen`, `pc`, `sid`) or `NoTask`; cancelled tasks that have not returned |
| `seekHold[c]`, `budget[c]`, `paused[c]` | `PlaybackSeekHold` (`gen`, `held`); restarts `SeekRestartBudget` still allows; the user's pause intent |
| `proxy[c]` | `slot`, the generation of the proxy in `remoteHLSProxy` (0 for none), and `live`, the generations still listening |
| `pendingStops[c]` | `pendingStopTasks`, as tickets: `ServerStopTicket(r)`, `ProxyStopTicket(g)`, `TaskJoinTicket(g)` |
| `jellyfinWindow[c]` | ghost: inside Jellyfin's replace-then-clean-up window |

## Actions

| Action | Abstracts |
| --- | --- |
| `StartJob(c, s)` | a start or negotiate request the server accepted. It adds a job, `server[s][NextIncarnation(s)]`. A start under an id that still has a running job does not replace it: both run (the Plex pile-up of #27). Disabled for an id another controller has used |
| `SendStopFor(c, s, g)` | the client puts a stop on the wire, meant for the incarnation `g` it stored when it started the job. "Receives a stop" means this step |
| `ServerAck(s)` | the server applies one stop for `s` and the client hears the acknowledgement. A stop names only a session id: it ends either every running job under the id or only the newest |
| `ServerFail(s)` | a stop ends unacknowledged: lost (the jobs run on) or applied with the answer lost |
| `ServerDelay` | a stop becomes `late`: a bounded client wait may give up. It can still be applied or fail |
| `ServerRecreate(s)` | the server restarts a stopped job from a request it had already accepted (Jellyfin, 2026-09-17 audit), at most once per job |

The encoder process, the server ending a job by itself and requests other than start and stop
are not modelled. Which jobs a stop ends when several run under one id was not established for
any backend, so the model allows both answers; a client that keeps one job per id cannot tell.

Session ids are never shared between controllers. Plex ids are minted by the client, one per
controller; Jellyfin and Emby ids are minted by the server for one negotiation. `StartJob`
enforces this, so a two-controller config needs no partition of `SessionIds`.

## What a guard may read

A client guard reads only what the client has: its own variables, and the stops it sent with
what it heard of them (`SentStopFor`, `StopAckedFor`, `StopFailedFor`, `StopInFlightFor`,
`InFlightFrom(c, s)`, a request's `late`). It never reads `server` or a judgement below.

The one thing a client learns from the server besides a stop's outcome is the job a start gave
it: the step that conjoins `StartJob(c, s)` stores `NextIncarnation(s)` in the module's own
state. Every later stop, ticket and question about that job uses the stored incarnation. After
the id is reused, "the job under `s`" is a different job, which is why only `SentStop(c, s)`
(a judgement about the newest job) has a form without an incarnation.

## Judgements

For properties only.

- `Live(c)`: the jobs, as `<<s, g>>` pairs, the server runs that `c` started.
- `Owned(c)`: the part of `Live(c)` the client is held to. It leaves out a job the server
  recreated and a job whose stop failed: the client sent that stop, and what the server does
  afterwards counts against the server. A stop in flight does not end ownership, so a second
  job started before the first stop resolves is two owned jobs, under one id or two.
- `SentStop(c, s)`: the client sent a stop meant for the newest job under `s`.
- `OneEncoder`: `Owned(c)` has at most one member, or two while `jellyfinWindow[c]`.
- `NoWrongKill`: no stop meant for an older incarnation ended a newer job (`endedBy`). A stop
  that also ends an older job under the id is not a wrong kill.
- `PendingStopsJoined(c)`: `waitForPendingStopRequests` would return now. A module may guard
  on this one: it reads the controller's tickets and what the client heard.

`RecreateCountsAgainstServer` is `TRUE` in every config except the mutant that shows why.

## Configs and results

2026-11-25, tla2tools v1.7.4, `TLC_WORKERS=auto TLC_HEAP=4g`. All run `PlaybackBaseSmoke`.
Unless noted: one controller, two session ids, `MaxGeneration = 2`, three stop requests.

| Config | Expect | Result | Distinct states | Time |
| --- | --- | --- | --- | --- |
| `Base-Current-Smoke` | pass | pass | 10,391,494 | 34 s |
| `Base-Current-TwoControllers` | pass | pass | 158,699 | 1 s |
| `Base-Mutant-RecreateCountsAgainstClient` | `OneEncoder` violated | violated | stops at first error | 1 s |
| `Base-Mutant-StartUnderLiveId` | `OneEncoder` violated | violated | stops at first error | 1 s |
| `Base-Mutant-WindowNotFlagged` | `OneEncoder` violated | violated | stops at first error | 1 s |
| `Base-Mutant-StartBeforeStopResolves` | `NoWrongKill` violated | violated | stops at first error | 1 s |
| `Base-Mutant-CleanupNotTicketed` | `JoinCoversCleanup` violated | violated | stops at first error | 1 s |

The two `Current` configs check `TypeOK`, `OneEncoder`, `NoWrongKill`, `JoinCoversCleanup` and
`OneOwnerPerId`. `Base-Current-TwoControllers` uses two controllers, `MaxGeneration = 1` and
one stop request. `OneOwnerPerId` has no mutant: it restates the owner guard inside `StartJob`,
which no constant turns off.

- **RecreateCountsAgainstClient** (5 steps): start, stop, acknowledged, start the other session,
  the server recreates the first. Counted as the client's, that is two owned jobs.
- **StartUnderLiveId** (2 steps, one session id): start, then start again under the same id
  with no stop. Both jobs run.
- **WindowNotFlagged**: the client replaces before cleaning up without opening the window.
- **StartBeforeStopResolves** (4 steps): start, stop, start again under the same id, and the
  stop lands on the new job.
- **CleanupNotTicketed**: a stop is sent with no ticket, so the join returns while it is in
  flight.

### Every server action is taken

`PlaybackBaseSmoke` defines witnesses: each is the negation of a state only one server action,
or one branch of it, reaches. Checked as an invariant on the `Base-Current-Smoke` constants,
each is violated. No config lists them; to repeat the check, copy the config, replace its
`INVARIANTS` with one witness and run TLC.

| Witness | Shows |
| --- | --- |
| `NeverAcked` | `ServerAck` |
| `NeverFailedLost`, `NeverFailedApplied` | both branches of `ServerFail` |
| `NeverLate`, `NeverLateThenAcked` | `ServerDelay`, and an acknowledgement after it |
| `NeverRecreated` | `ServerRecreate` |
| `NeverInWindow` | the window flag is opened |
| `NeverTwoUnderOneId`, `NeverEndsNewestOnly` | two jobs run under one id, and a stop ends only the newest |

## The toy client's rules

`PlaybackBaseSmoke` follows the guard rule: it keeps `started[c]`, the jobs it started with the
incarnation each start gave it, and decides from that and from its stops. Three rules keep the
judgements true. TLC found the second: the first smoke run failed without it.

1. Start only when holding no job: every job started has a stop that was acknowledged or failed.
2. Reuse a session id only when none of its own stops for that id is in flight. Holding nothing
   is not enough: of two stops sent for one job, the first can end it while the second is
   still on the wire, and the second then ends the job started next under the id.
3. Send a stop only for the newest job started under an id. A stop meant for an older one
   names the same id and ends the successor.

A module whose backend reuses session ids should expect `NoWrongKill` to see the last two.
