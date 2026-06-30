# Live-server test requirements & CI enablement (issue #75)

What a live CI media server (and its test account) must provide for the opt-in `Live*Probe` tests,
which env vars / secrets gate them, and how to wire them into CI without breaking the hermetic
default. This is the companion to the coverage map in
[`TESTING-LIVE-MATRIX.md`](TESTING-LIVE-MATRIX.md) and the strategy in
[`TESTING-STRATEGY.md`](TESTING-STRATEGY.md).

## Design invariant: hermetic by default, live by opt-in

Every live probe follows the same established contract (do not deviate when adding one):

- It reads its server/token/item from **environment variables** and **no-ops** (prints a skip line,
  returns) when they are absent. So plain macOS `swift test` and the existing `.woodpecker/pmskit.yml`
  Linux CI split (`swift test --no-parallel --disable-swift-testing` plus
  `swift test --no-parallel --disable-xctest`) stay 100% hermetic — they execute the probe
  *bodies* but exercise no network.
- **No secret is ever committed.** Credentials live only in gitignored env files
  (`scripts/plex-live.env`, `scripts/emby-live.env`); `.gitignore` carries `scripts/*-live.env`,
  and each `scripts/live-*.sh` refuses to run if its env file is somehow tracked by git.
- The probe sends the **real PMSKit request builders** through `URLSession`, so it asserts against
  the exact wire shape the app produces — not a hand-rolled approximation.

This means enabling live tests in CI is purely **"inject the secrets as env vars and add a
filtered `swift test` step"** — no code path changes between hermetic and live runs.

## Required server fixtures

A live CI server must host a stable, **non-destructive, read-only-friendly** test account with the
following. (All probes are read-only except the download/optimize probes, which may *start*
server-side jobs — see "Cleanup / reset" below.)

| Fixture | Why | Used by |
|---|---|---|
| **A stable test account + token** | Auth for every probe. Dedicate one account; its token is the gating secret. | all |
| **A direct-play-eligible video** (e.g. H.264/AAC MP4 the visionOS profile can copy) | Proves `videoDecision=copy`/direct-play and gives the subtitle-burn probe a clean `copy → transcode` flip. | `LiveDecisionProbe`, `LiveSubtitleBurnProbe` |
| **A transcode-requiring video** at a deep duration (≥1h) | Deep-offset segment priming + cap-forced transcode. | `LiveSegmentProbe` |
| **A video with an embedded image-based subtitle track** (PGS/VOBSUB — e.g. a Blu-ray rip) | Burn-in must re-encode; image subs can't be sidecar'd, so they cleanly force `transcode`. | `LiveSubtitleBurnProbe` (★ #75 proof) |
| **A downloadable item** (compatible local container) + **a transcode-only item** | Original-vs-optimizer download route decision. | `LiveDownloadProbe`, `LiveOptimizeProbe`, `LiveDownloadStatusProbe` |
| **A video with a keyed external text subtitle** (SRT/SubRip or WebVTT) | Fetches `/library/streams/<id>` and proves the offline subtitle parser accepts the live body. | `LiveSidecarSubtitleProbe` |
| **A downloaded local fixture file for a stable PMS item** | Proves playback routing prefers a completed local copy over the server-stream branch. | `LiveOfflinePlaybackDecisionProbe` |
| **Two stable video items on a throwaway/test account** | Creates an ephemeral play queue, adds play-next, and creates a shuffled queue. | `LivePlayQueueMutationProbe` |
| **A library section key + a TV show** (show with seasons + episodes) | Sections list, item grid + paging, and the show→season→episode `/children` traversal with coherent parent/grandparent ids. | `LivePlexBrowseProbe` |
| **A progress-tracking video item on a DEDICATED test account** | `/:/timeline` progress report → `viewOffset` read-back round-trip, and a startable transcode session to stop. Writes a resume point, so it must target a throwaway account. | `LivePlexTimelineProbe` |
| **(Emby lane) an Emby server, user id, and item id** | Emby auth/browse/playback/download wire shape. | `LiveEmbyProbe`, `LiveEmbyDownloadProbe` |

**Stability matters more than realism.** Pin metadata keys / item ids that will not be re-scanned
out from under the suite. Prefer small media files so the probes (which range-fetch only the first
bytes of a segment) stay fast and cheap. Item identifiers are passed by env var precisely so no
real library path or media title is ever committed.

## Env vars / secrets (the gate)

Copy `scripts/plex-live.env.example` → `scripts/plex-live.env` (gitignored) and fill in. In CI,
inject the same names as masked secrets.

### Plex

| Var | Required by | Meaning |
|---|---|---|
| `PLEX_LIVE_SERVER` | all Plex probes | Base URL — prefer the `https://<hash>.<machineId>.plex.direct:32400` form (publicly-trusted cert; `URLSession.shared` validates it without a custom trust delegate). |
| `PLEX_LIVE_TOKEN` | all Plex probes | `X-Plex` auth token for the test account. **Secret.** |
| `PLEX_LIVE_METADATA_KEY` | decision/segment probes | Item key, e.g. `/library/metadata/12345`. |
| `PLEX_LIVE_SUBTITLE_METADATA_KEY` | `LiveSubtitleBurnProbe` | Item with an embedded image-based subtitle track. Falls back to `PLEX_LIVE_METADATA_KEY`. |
| `PLEX_LIVE_SUBTITLE_STREAM_ID` | `LiveSubtitleBurnProbe` (optional) | Pin a specific subtitle stream id; otherwise the probe auto-discovers the first image-based subtitle. |
| `PLEX_LIVE_SIDECAR_SUBTITLE_METADATA_KEY` | `LiveSidecarSubtitleProbe` | Item with an external/keyed SRT/SubRip or WebVTT subtitle stream. Falls back to `PLEX_LIVE_METADATA_KEY`. |
| `PLEX_LIVE_SIDECAR_SUBTITLE_STREAM_ID` | `LiveSidecarSubtitleProbe` (optional) | Pin a specific keyed text subtitle stream id; otherwise the probe auto-discovers the first compatible stream. |
| `PLEX_LIVE_SECTION_KEY` | `LivePlexBrowseProbe` | A library section key (from `/library/sections`, e.g. `1`). |
| `PLEX_LIVE_SHOW_METADATA_KEY` | `LivePlexBrowseProbe` | A TV show item — bare ratingKey or `/library/metadata/<id>`; the probe extracts the bare key for the `/children` traversal. |
| `PLEX_LIVE_TIMELINE_OFFSET_SECONDS` | `LivePlexTimelineProbe` (optional) | Offset (s) to report and read back; default 120. |
| `PLEX_LIVE_OFFLINE_METADATA_KEY`, `PLEX_LIVE_OFFLINE_FILE` | `LiveOfflinePlaybackDecisionProbe` | Stable item key plus a runner-local downloaded fixture path. The path is not logged and must not be committed. |
| `PLEX_LIVE_PLAYQUEUE_METADATA_KEY`, `PLEX_LIVE_PLAYQUEUE_NEXT_METADATA_KEY` | `LivePlayQueueMutationProbe` | Two stable video item keys on a throwaway/test account. The first seeds the queue; the second is added as play-next. |
| `PLEX_LIVE_MACHINE_IDENTIFIER` | `LivePlayQueueMutationProbe` (optional) | Plex machine identifier for `server://...` queue URIs; auto-discovered from server root when omitted. |
| `PLEX_LIVE_TITLE` | `LiveOptimizeProbe` | Title for the optimize discovery probe. |
| `PLEX_LIVE_MAX_KBPS`, `PLEX_LIVE_OFFSET_SECONDS`, `PLEX_LIVE_SEGMENTS`, `PLEX_LIVE_MEDIA_INDEX`, `PLEX_LIVE_PART_INDEX`, `PLEX_LIVE_CLIENT_ID`, `PLEX_LIVE_POLLS`, `PLEX_LIVE_POLL_INTERVAL_SECONDS` | various (optional) | Tunables; sensible defaults baked into each probe. |

### Emby

| Var | Required by | Meaning |
|---|---|---|
| `EMBY_LIVE_SERVER`, `EMBY_LIVE_TOKEN`, `EMBY_LIVE_USER_ID`, `EMBY_LIVE_ITEM_ID` | `LiveEmbyProbe`, `LiveEmbyDownloadProbe` | Emby server / token / user / item. **Token is secret.** |
| `EMBY_LIVE_DEVICE_ID`, `EMBY_LIVE_MAX_BITRATE` | Emby probes (optional) | Tunables. |

The probe-specific `*_LIVE_ENV` override (e.g. `PLEX_LIVE_ENV`, `EMBY_LIVE_ENV`) lets a runner
point at an alternate env file path.

## Cleanup / reset expectations

- **Read-only probes** (`LiveDecisionProbe`, `LiveSegmentProbe`, `LiveSubtitleBurnProbe`,
  `LiveSidecarSubtitleProbe`, `LiveOfflinePlaybackDecisionProbe`, `LiveDownloadStatusProbe`,
  `LivePlexBrowseProbe`, browse/metadata reads): no server-side mutation.
  Nothing to clean up. The subtitle-burn and browse probes only read/ask the **decision** or
  metadata endpoints — they do not open a `start.m3u8` transcode session — so they leave no FFmpeg
  job behind.
- **Queue-mutating probes** (`LivePlayQueueMutationProbe`): create ephemeral test-account play
  queues and add a play-next item. The probe also creates a shuffled queue with `shuffle=1` on
  `POST /playQueues`, which is the live-proven shuffle operation for this PMS version. Run only on
  a throwaway/test account; these do not open media streams or transcode sessions.
- **Job-starting probes** (`LiveDownloadProbe`, `LiveOptimizeProbe`, `LiveEmbyDownloadProbe`,
  `LivePlexTimelineProbe`, and any future probe that hits `start.m3u8`): may spawn a server-side
  transcode/optimize. The CI server should run a **periodic reaper** (or the suite a teardown step)
  that cancels orphaned optimize/transcode sessions for the test account between runs.
  `TranscodeRequest.stop(...)` and the Emby `activeEncodingStopRequest` exist for graceful
  teardown; a probe that opens a session should stop it (`LivePlexTimelineProbe` calls
  `TranscodeRequest.stop` on the session it starts, and asserts the stop returns 2xx). Treat the
  test account's active-session list as expected-empty at run start.
- **Progress writes are TEST-ACCOUNT ONLY.** `LivePlexTimelineProbe` POSTs a `/:/timeline` update,
  which **mutates the item's resume point (`viewOffset`)**. It must run only against a dedicated
  throwaway account so it never touches a real user's resume points. The probe makes this loud
  (skip-line + script banner). If a fixed pristine resume state matters, reset the test item's
  `viewOffset` between runs (re-report `time=0`, or `/:/unscrobble`).
- **No state accumulation.** Probes must not create library items, playlists, or persistent
  downloads on the live server.

## CI enablement

The hermetic gate (`.woodpecker/pmskit.yml`, Swift 6.2 on Linux) stays exactly as-is — it never
sets the live vars, so the probes no-op. Live probes are an **additive, secret-gated step**, ideally
on a macOS runner (the segment/Emby-download probes use `URLSession.bytes`, which is unavailable in
swift-corelibs-foundation and is `#if !canImport(FoundationNetworking)`-compiled-out on Linux).

Sketch of the additive step (runs only when the secrets are present):

```yaml
# .woodpecker/pmskit-live.yml  (macOS runner; runs only when live secrets are configured)
when:
  event: [manual]            # opt-in: never gate normal pushes/PRs on a live server
steps:
  - name: pmskit-live-probes
    image: macos            # needs URLSession.bytes + a reachable test server
    secrets: [plex_live_token, emby_live_token]
    environment:
      PLEX_LIVE_SERVER: https://<test-server>.plex.direct:32400
      PLEX_LIVE_TOKEN: { from_secret: plex_live_token }
      PLEX_LIVE_METADATA_KEY: /library/metadata/<id>
      PLEX_LIVE_SUBTITLE_METADATA_KEY: /library/metadata/<id-with-pgs-subs>
    commands:
      - cd PMSKit
      - swift test --filter LiveSubtitleBurnProbe   # ★ #75 representative E2E proof
      - swift test --filter LiveDecisionProbe
      - swift test --filter LivePlexBrowseProbe      # sections + grid + TV hierarchy
      - swift test --filter LivePlexTimelineProbe    # progress round-trip + session stop (TEST ACCT)
      # add other Live*Probe filters as the live fixtures are provisioned
```

Guidance:

- Keep live probes on `event: manual` (or a nightly cron), **never** as a required check on every
  PR — they depend on a real server, credentials, library contents, network, and server version
  (per `TESTING-STRATEGY.md`, live probes "should not become required CI assertions").
- Inject tokens as **masked secrets**, never as plaintext in the YAML.
- Run with `--filter Live<Name>Probe` so the live step runs *only* the probe(s) whose fixtures the
  CI server actually provides — a missing fixture should mean "don't run that filter," not a failure.
- The local equivalent of the CI step is just the runner script, e.g.
  `./scripts/live-subtitle-burn-probe.sh` — same env, same filter, same assertions.

## Adding a new live probe (checklist)

1. `PMSKit/Tests/PMSKitTests/Live<Name>ProbeTests.swift` — env-gated `Config?` initializer that
   returns nil → prints a skip line → no network. Send real PMSKit builders through `URLSession`.
   For Plex probes, build on the shared `LiveProbeConfig` helper (server/token parse + the standard
   `ClientIdentity` + `redact`).
2. `scripts/live-<name>-probe.sh` — sources the gitignored env file, refuses to run if it's
   tracked, runs `swift test --filter Live<Name>Probe`.
3. Document new env vars in `scripts/plex-live.env.example` (or `emby` equivalent) **and** in the
   table above.
4. Flip the relevant *(gap)* in `TESTING-LIVE-MATRIX.md` to the new probe name.
5. Redact secrets in any printed URL/header; log codecs/decisions, never media titles or library
   paths (this repo is going public).
6. **Proof discipline (avoid trivially-green tests).** Decode leniently (`try?` → nil → loud SKIP,
   never a false RED on a 200 with an unexpected body); never silently swallow a failed control
   leg (`Issue.record` or SKIP with a diagnostic); and don't assert an absolute value that can pass
   for unrelated reasons — assert the specific wire-shape invariant (the *flip* a change causes,
   a round-tripped value, an id that chains coherently).

### Shared live-probe config

`LiveProbeConfig` (in `PMSKit/Tests/PMSKitTests/`) is the shared Plex live-probe base for
server/token parsing, `ClientIdentity`, transport, and redaction. The older Plex probes now compose
it as well as the #75 probes (`LiveSubtitleBurnProbe`, `LivePlexBrowseProbe`,
`LivePlexTimelineProbe`). Emby probes still keep their own `EmbyClientIdentity` parsing, but route
log scrubbing through the shared `LiveProbeConfig.redact` helper so tightening the redaction key set
protects both Plex and Emby probe logs.
