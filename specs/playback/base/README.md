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
| `server[s]` | the encoding job under session id `s`: `state` (`none`, `encoding`, `stopRequested`, `stopped`), `owner`, `gen` (the incarnation under this id, one more per start), and the ghost fields `serverRecreated` and `endedBy` |
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
| `StartJob(c, s)` | a start or negotiate request the server accepted. One job per session id: a start under a used id replaces the job as a new incarnation |
| `SendStopFor(c, s, g)`, `SendStop(c, s)` | the client puts a stop on the wire, meant for incarnation `g` (or the current one). "Receives a stop" means this step |
| `ServerAck(s)` | the server applies one stop for `s` and the client hears the acknowledgement. A stop names only a session id, so it ends whatever job holds the id |
| `ServerFail(s)` | a stop ends unacknowledged: lost (the job runs on) or applied with the answer lost |
| `ServerDelay` | a stop becomes `late`: a bounded client wait may give up. It can still be applied or fail |
| `ServerRecreate(s)` | the server restarts a stopped job from a request it had already accepted (Jellyfin, 2026-09-17 audit), at most once per incarnation |

The encoder process, the server ending a job by itself and requests other than start and stop
are not modelled.

## Judgements

- `Live(c)`: the jobs the server runs that `c` started.
- `Owned(c)`: the part of `Live(c)` the client is held to. It leaves out a job the server
  recreated and a job whose stop failed: the client sent that stop, and what the server does
  afterwards counts against the server. A stop in flight does not end ownership, so a second
  session started before the first stop resolves is two owned sessions.
- `SentStop(c, s)`, `SentStopFor(c, s, g)`: the client sent a stop meant for that job, whatever
  became of it. `StopAcked`, `StopFailed` and `StopInFlight` read its outcome.
- `OneEncoder`: `Owned(c)` has at most one member, or two while `jellyfinWindow[c]`.
- `NoWrongKill`: no stop ended a job other than the one it was meant for (`endedBy`).
- `PendingStopsJoined(c)`: `waitForPendingStopRequests` would return now.

`RecreateCountsAgainstServer` is `TRUE` in every config except the mutant that shows why.

## Configs and results

2026-11-25, tla2tools v1.7.4, `TLC_WORKERS=auto TLC_HEAP=4g`. All run `PlaybackBaseSmoke` with
one controller, two session ids, `MaxGeneration = 2` and three stop requests.

| Config | Expect | Result | Distinct states | Time |
| --- | --- | --- | --- | --- |
| `Base-Current-Smoke` | pass | pass | 3,183,534 | 11 s |
| `Base-Mutant-RecreateCountsAgainstClient` | `OneEncoder` violated | violated | 899 | 1 s |
| `Base-Mutant-WindowNotFlagged` | `OneEncoder` violated | violated | 33 | 1 s |
| `Base-Mutant-StartBeforeStopResolves` | `NoWrongKill` violated | violated | 539 | 1 s |
| `Base-Mutant-CleanupNotTicketed` | `JoinCoversCleanup` violated | violated | 21 | 1 s |

`Base-Current-Smoke` checks `TypeOK`, `OneEncoder`, `NoWrongKill` and `JoinCoversCleanup`.

- **RecreateCountsAgainstClient** (5 steps): start, stop, acknowledged, start the other session,
  the server recreates the first. Counted as the client's, that is two owned sessions.
- **WindowNotFlagged**: the client replaces before cleaning up without opening the window.
- **StartBeforeStopResolves** (4 steps): start, stop, start again under the same id, and the
  stop lands on the new job.
- **CleanupNotTicketed**: a stop is sent with no ticket, so the join returns while it is in
  flight.

### Every server action is taken

`PlaybackBaseSmoke` defines one witness per server action: the negation of a state only that
action reaches. Checked as an invariant on the `Base-Current-Smoke` constants, each is violated.
No config lists them; to repeat the check, copy the config, replace its `INVARIANTS` with one
witness and run TLC.

| Witness | Shows |
| --- | --- |
| `NeverAcked` | `ServerAck` |
| `NeverFailedLost`, `NeverFailedApplied` | both branches of `ServerFail` |
| `NeverLate`, `NeverLateThenAcked` | `ServerDelay`, and an acknowledgement after it |
| `NeverRecreated` | `ServerRecreate` |
| `NeverInWindow` | the window flag is opened |

## Found while writing the smoke

Owning no session does not make a session id safe to reuse. Of two stops sent for one job, the
first can end it while the second is still in flight; a job started under the same id is then
ended by the second. The toy client therefore also waits for `InFlight(s) = {}`. A module whose
backend reuses session ids should expect `NoWrongKill` to see this.
