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
- `scripts/ci-hygiene.sh` fails the build if the literal `PLEX_TOKEN=` or the real host/IP
  fingerprint appears in any tracked file — so name probe env vars `PLEX_LIVE_*` (the substring
  `PLEX_TOKEN=` must not appear) and never paste the real host/token into committed files.
- Probe output may contain media titles/library paths — read it, don't commit it.

## Hard limits — what this canNOT do

Covers pure Foundation/URLSession only. It does **not** exercise AVPlayer/AVKit: real HLS
playback, buffering depth, stall watchdog firing, seek-restart-during-play. Headless AVPlayer
(even on macOS) fetches segments, fills the buffer, and populates `AVPlayerItemAccessLog`, but
the **playhead does not advance without an on-screen render surface** (verified empirically).
For the playback half, the path is a `-VPAutoPlay <ratingKey>` launch-arg hook that drives the
real app on the booted sim hands-free (then read logs via `simctl spawn booted log show`) —
see `docs/DEVELOPMENT.md`. UI-tap automation is shelved (see the `sim-driving` skill).
