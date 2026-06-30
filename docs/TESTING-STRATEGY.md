# Testing strategy

> **Companion docs (issue #75):** [`TESTING-LIVE-MATRIX.md`](TESTING-LIVE-MATRIX.md) is the
> row-by-row coverage map (screens, menus, playback, downloads, profiles, subtitles) showing where
> each flow is exercised across the mocked-unit / live-probe / device layers;
> [`TESTING-LIVE-REQUIREMENTS.md`](TESTING-LIVE-REQUIREMENTS.md) documents the live-server fixtures,
> the env-var/secret gate, cleanup expectations, and CI enablement. This doc remains the high-level
> strategy (what may/may not become a required CI assertion; device-only gates).

## CI / portable checks

Portable CI should run the Woodpecker gates:

```sh
# Linux SwiftPM gate (see .woodpecker/pmskit.yml). Keep XCTest and Swift Testing
# separate on Linux; the combined runner can deadlock under swift-corelibs-foundation.
cd PMSKit
swift test --no-parallel --disable-swift-testing
swift test --no-parallel --disable-xctest

# Repo hygiene / Python tooling gate (see .woodpecker/hygiene.yml).
cd ..
./scripts/ci-hygiene.sh
```

On macOS, a plain `(cd PMSKit && swift test)` remains a valid local convenience run.

`PMSKit` tests cover pure request builders, models, decision helpers, routing helpers, and policy state machines. Repo hygiene covers redaction/signing guardrails, project churn, Python tooling tests, and other cheap checks.

## Local simulator checks

Run an unsigned simulator build locally on macOS/Xcode against this worktree's simulator:

```sh
SIMID=$(scripts/worktree-sim.sh id)
xcrun simctl boot "$SIMID" 2>/dev/null || true
scripts/xcodebuild-versioned.sh -project VisionPlay.xcodeproj -scheme VisionPlay \
  -destination "platform=visionOS Simulator,id=$SIMID" \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO
```

The simulator is useful for compile/runtime smoke, browse flows, settings, downloads request shape, and many UI regressions. It is not a replacement for headset playback validation.

## Live probes

`PMSKit` live probe tests are opt-in discovery/log probes. They should not become required CI assertions because they depend on a real media server, credentials, library contents, network, and server version.

Use live probes to confirm wire shape and server behavior before documenting a behavior as “proven.”

For downloads there are two live layers:

- **PMSKit live probes** (`scripts/live-*.sh`, `Live*ProbeTests`) prove request builders, server wire shape, response decoding, and server-side route behavior.
- **App-driven simulator probes** (`scripts/probe-plex-range-drop.sh`, `scripts/probe-jellyfin-download.sh`, `scripts/probe-emby-download.sh`) launch the DEBUG app in the signed-in worktree simulator and prove app glue: backend session restore, route handoff, `DownloadManager`, `BackgroundDownloadSession`, static byte-range checkpointing, row cleanup, and diagnostics. They are still simulator proof, not headset/off-head proof.

When running app-driven probes during a refactor, target `SIMID=$(scripts/worktree-sim.sh id)`, use `--keep-app-running` to preserve the single signed-in worktree simulator, and keep probe artifacts under `build/probes/**` private.

### LiveEmbyProbe gate

The Emby wire shape was promoted to "proven" through `LiveEmbyProbeTests.liveEmbyProbe` (`PMSKit/Tests/PMSKitTests/`), driven by [`scripts/live-emby-probe.sh`](https://github.com/jlipworth/VisionPlay/blob/main/scripts/live-emby-probe.sh). The probe sends the real Emby request builders (`EmbyAuth`, `EmbyLibrary`, `EmbyPlayback`) through `URLSession.shared` — the exact wire shape the app produces — and asserts the PMSKit decoders (`EmbyServerInfo`, `EmbyBaseItemDto`, `EmbyPlaybackInfoResponse`) parse the live bodies and that `resolveStream` yields a playable URL.

It is opt-in and a no-op unless `EMBY_LIVE_SERVER`, `EMBY_LIVE_TOKEN`, `EMBY_LIVE_USER_ID`, and `EMBY_LIVE_ITEM_ID` are set, so plain macOS `swift test` and the split Linux CI test invocations stay hermetic. Credentials live ONLY in the gitignored `scripts/emby-live.env`; the script refuses to run if that file is somehow tracked by git. The probe redacts the token, `api_key`, `X-Emby-Token`, and the live scheme/host before printing any URL or header.

```sh
# fill scripts/emby-live.env (gitignored) once, then:
./scripts/live-emby-probe.sh
# or directly:
set -a; source scripts/emby-live.env; set +a
cd PMSKit && swift test --filter LiveEmbyProbe
```

The probe confirmed against a real Emby server: `GET /System/Info/Public` is unauthenticated (used for pre-login validation), authenticated `/Users/{UserId}/Items` browse + DTO mapping, and `POST /Items/{Id}/PlaybackInfo` → `resolveStream` producing a token-bearing HLS URL.

## Device-only gates

Keep these as manual Apple Vision Pro checks:

- headset playback behavior and failures
- expanded Cinema/theater behavior
- audio interruptions and route changes
- Spotlight and Shortcuts/App Intents end-to-end behavior
- background downloads and headset sleep/off-head transfer behavior
- headset/off-head download scheduling and long-running background behavior
- final user-facing download UX across Plex/Jellyfin/Emby after the simulator probes pass
- Emby headset playback validation (the PMSKit wire shape is proven via `LiveEmbyProbe`, but in-headset playback/progress/cleanup behavior is still a device-only gate)

## Current validation boundaries

- Plex playback and download paths have the most live/headset validation.
- Plex raw original download is intentionally offered only for compatible local containers.
- Plex compatible original-quality copies use the server optimizer/rendered-part route.
- Jellyfin browse/playback/download request paths are implemented and unit-tested. The app-driven simulator download probe has also proven Jellyfin static byte-range recovery against a live signed-in backend; headset/off-head behavior remains device-only before calling it headset-proven.
- Emby sign-in, browse/DTO mapping, PlaybackInfo stream resolution, progress, active-encoding cleanup, and download route/request paths are implemented and unit-tested. The core playback wire shape is live-proven via `LiveEmbyProbe`, Emby Connect PIN request/exchange shape is live-verified, Emby downloads have `LiveEmbyDownloadProbe` coverage, and the app-driven simulator probe has proven existing-converted-source reuse plus static byte-range recovery. In-headset PIN UX, playback/progress/cleanup, and download/off-head behavior remain device-only gates before calling those flows headset-proven.

The manual checklist remains in [`TESTING-CHECKLIST.md`](https://github.com/jlipworth/VisionPlay/blob/main/TESTING-CHECKLIST.md). Treat it as a checklist and issue trail, not the canonical architecture doc.

## Remaining Emby validation gates

The PMSKit wire shape is proven via `LiveEmbyProbe`. Still device-only before Emby playback is called headset-proven: Emby Connect PIN UX, HTTP `8096` vs HTTPS `8920` where available, in-headset Direct Play / Direct Stream-remux / HLS transcode playback, HLS child-resource auth holding in AVPlayer, subtitle/audio selection, progress/resume round-tripping, and `DELETE /Videos/ActiveEncodings` actually stopping server-side work on a live transcode.
