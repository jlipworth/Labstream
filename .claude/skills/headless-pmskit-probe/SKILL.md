---
name: headless-pmskit-probe
description: Run PMSKit networking code against a REAL Plex server purely from the macOS CLI (no simulator) — dump raw responses and TDD decoders against the real wire shape. Use when debugging any PMSKit request/response (transcode decision, library, auth, timeline) instead of the build→install→tap→read-log simulator loop.
---

# Headless PMSKit probe (macOS CLI, no simulator)

Exercise PMSKit's networking against the user's live PMS from a `swift test` on the Mac —
no simulator boot, no app install, no tapping. This closes the test loop for anything that
is **pure Foundation/URLSession**: transcode-decision calls, library/children queries, auth,
timeline, optimize. It does **NOT** cover AVPlayer/AVKit playback (see *Hard limits*).

## Why it faithfully reproduces the app

The app's only HTTP executor is `PlexClient.send`, which is a bare
`URLSession.shared.data(for: request.urlRequest())` — no custom session, no retries, no
header injection. So building a PMSKit request (e.g. `TranscodeRequest.decisionRequest()`)
and sending it through `URLSession.shared` on macOS produces a **byte-identical** wire
request to what the visionOS app sends — token in both the query string and the
`X-Plex-Token` header, plus the full `X-Plex-*` identity set. (Hand-written `curl` 401s here
because it omits that header set; PMSKit builds it for you. Don't go down the curl path.)

## Run it

```sh
cp scripts/plex-live.env.example scripts/plex-live.env   # gitignored — holds token + real host
$EDITOR scripts/plex-live.env                            # PLEX_LIVE_SERVER / _TOKEN / _METADATA_KEY
./scripts/live-decision-probe.sh                         # sources env, runs the gated test, greps >>> LIVE
```

The existing probe is `PMSKit/Tests/PMSKitTests/LiveDecisionProbeTests.swift`. It is **opt-in**:
absent the env vars it returns immediately, so plain `swift test` and CI stay hermetic and no
secret is ever committed.

## Capture the RAW body (Plex JSON is minified → one giant line)

The runner's grep keeps only `>>> LIVE` lines and drops the body. To see the full body, run
the test directly and capture, then slice the JSON lines with `jq`:

```sh
set -a; source scripts/plex-live.env; set +a
cd PMSKit && swift test --filter LiveDecisionProbe 2>/dev/null > /tmp/vp-probe-raw.txt
grep -E '^\{' /tmp/vp-probe-raw.txt > /tmp/vp-bodies.txt        # each body = one line
sed -n '1p' /tmp/vp-bodies.txt | jq '.MediaContainer | {generalDecisionCode, mdeDecisionCode}'
sed -n '2p' /tmp/vp-bodies.txt | jq '.MediaContainer.Metadata[0].Media[0].Part[0] | {decision, streams:[.Stream[]|{streamType,decision}]}'
```

This is exactly how we discovered PMS expresses a direct-play verdict via `mdeDecisionCode=1000`
+ Part-level `decision="directplay"` (per-stream decisions nil) — the bug that kept
`DecisionResponse.savesVideoEncode` false. Capture real shape → write a `@Test` with that exact
JSON → fix the decoder → re-run the live probe to confirm.

## Extend to any other PMSKit request

Add a gated `@Test` (or a new probe file) that:
1. reads config from `ProcessInfo.processInfo.environment["PLEX_LIVE_*"]`, returning early if absent;
2. builds the PMSKit request you want to debug;
3. sends it with `try await URLSession.shared.data(for: req.urlRequest())`;
4. prints `>>> LIVE [label]` + HTTP status + raw body, then optionally decodes and prints fields.

Prefer the https `*.plex.direct` hostname for `PLEX_LIVE_SERVER` (publicly-trusted cert →
`URLSession.shared` validates without a custom trust delegate). A bare-IP `https://…` needs
the self-signed cert accepted, which the app doesn't do by default.

## Secret hygiene (repo goes public)

- `scripts/plex-live.env` is gitignored; the runner refuses to run if it's ever tracked.
- `scripts/ci-hygiene.sh` fails the build if the literal `PLEX_TOKEN` + `=` or the real host/IP
  fingerprint appears in any tracked file — so name probe env vars `PLEX_LIVE_*` (that
  `PLEX_TOKEN` + `=` substring must not appear) and never paste the real host/token into
  committed files.
- Probe output may contain media titles/library paths — read it, don't commit it.

## Hard limits — what this canNOT do

Covers pure Foundation/URLSession only. It does **not** exercise AVPlayer/AVKit: real HLS
playback, buffering depth, stall watchdog firing, seek-restart-during-play. Headless AVPlayer
(even on macOS) fetches segments, fills the buffer, and populates `AVPlayerItemAccessLog`, but
the **playhead does not advance without an on-screen render surface** (verified empirically).
For the playback half, see the next section. UI-tap automation is shelved (see the
`sim-driving` skill).

## The playback half — in-process simulator probe (real AVPlayer, hands-free)

The simulator **is** an on-screen render surface, so AVPlayer's playhead **does** advance
there — the headless limitation above is macOS-CLI only. To exercise real playback (start,
playhead advance, seek-restart, stall) without UI tapping, use the launch-arg-driven
**in-process debug probes** that already exist per backend:

- `VisionPlay/DebugJellyfinPlaybackProbe.swift` → `--vp-probe-jellyfin-playback`
- `VisionPlay/DebugEmbyPlaybackProbe.swift` → `--vp-probe-emby-playback`
- `VisionPlay/DebugPlexDownloadProbe.swift` (downloads, not playback)

Each is `#if DEBUG`, inert unless its flag is passed, runs **inside the signed-in app
process** (so it reuses the app's Keychain session + the *same* `EmbyBrowseService` /
`JellyfinBrowseService` → `PlaybackController` → AVPlayer path as the UI), and is invoked
from `ContentView`'s startup task. It resolves an item by search query, opens playback,
waits for `readyToPlay` + `rate > 0`, performs a seek, then asserts the playhead actually
advanced during a hold — failing loudly if it stalls. All events go to `os.Logger`
(subsystem `com.jlipworth.VisionPlay`, category e.g. `EmbyProbe`) and `AppDiagnostics`.

Run loop (Claude self-serves; the USER must sign in to that backend **once** first, since
the probe does not authenticate):

```sh
# 1. Guarded build + install (see CLAUDE.md link-skip / stale-process traps)
APP=$(/bin/ls -td $HOME/Library/Developer/Xcode/DerivedData/VisionPlay-*/Build/Products/Debug-xrsimulator/VisionPlay.app | head -1)
xcrun simctl install booted "$APP"
# 2. Launch with the probe flag (launch args go AFTER the bundle id). Optional overrides:
#    --vp-probe-query "<title>"  --vp-probe-bitrate-kbps N  --vp-probe-seek-ms N
xcrun simctl terminate booted com.jlipworth.VisionPlay 2>/dev/null
xcrun simctl launch booted com.jlipworth.VisionPlay --vp-probe-emby-playback --vp-probe-query "Some Movie"
# 3. Read the probe's own log lines (probe.start / probe.item_resolved / probe.progress / probe.pass|fail)
xcrun simctl spawn booted log show --last 2m --predicate 'process == "VisionPlay"' | grep -iE 'EmbyProbe|probe\.'
```

To add a probe for a new backend, mirror `DebugEmbyPlaybackProbe.swift` (swap the browse
service, the `--vp-probe-…` flag, and the `activeBackend ==` guard) and add one
`runIfRequested` call in `ContentView`. The xcode MCP (`mcp__xcode__BuildProject`, etc.)
can drive the build instead of `xcodebuild` if preferred, but the install/launch/log loop
above is `simctl`.
