---
name: playback-frame-capture
description: Headless visual verification of playback — capture decoded AVPlayer frames as PNGs from the in-process probes (Plex/Jellyfin/Emby), pull them from the sim, and judge black-screen / DV tint without driving the UI
---

# Playback frame capture (headless visual verification)

The in-process playback probes (`--vp-probe-plex-playback` / `--vp-probe-jellyfin-playback` /
`--vp-probe-emby-playback`, see the `headless-pmskit-probe` skill) verify **transport**:
readyToPlay, playhead advance, seek, stall detection. They are blind to **what the decoder
renders** — an all-black feed or a DV P5 green/purple tint passes `probe.pass`.

Adding `--vp-probe-capture-frames` closes that gap. `DebugPlaybackFrameCapture` attaches an
`AVPlayerItemVideoOutput` to the SAME `AVPlayerItem` the probe is playing and samples decoded
frames (post-VideoToolbox, pre-display) — no simulator screen recording, no UI tapping. It is
the app's own media player storing what it decodes to files.

Each run writes, per capture point (`<backend>-initial` after first playable,
`<backend>-postseek` after the hold):

- `Documents/ProbeCaptures/<label>/frame-NN.png` in the app container (960px wide max) —
  Claude can Read these PNGs directly and *look* at the video.
- Log lines `probe.frame … avg_r=… avg_g=… avg_b=… luma=…` — greppable verdicts without
  pulling files.

The capture directory is wiped per run, so frames always belong to the latest probe.

## Run loop

```sh
SIMID=$(scripts/worktree-sim.sh id)
# build + install per CLAUDE.md (versioned script, CODE_SIGNING_ALLOWED=NO), then:
xcrun simctl terminate "$SIMID" com.jlipworth.Labstream 2>/dev/null
xcrun simctl launch "$SIMID" com.jlipworth.Labstream \
  --vp-probe-backend emby --vp-probe-emby-playback \
  --vp-probe-capture-frames --vp-probe-query "Some Movie" \
  --vp-probe-bitrate-kbps 8000        # optional quality cap

# wait for probe.pass/probe.fail, then:
xcrun simctl spawn "$SIMID" log show --last 5m --predicate 'process == "Labstream"' \
  | grep -E 'probe\.(frame|pass|fail)'

# pull the PNGs and Read them:
DATA=$(xcrun simctl get_app_container "$SIMID" com.jlipworth.Labstream data)
/bin/ls "$DATA/Documents/ProbeCaptures/"*/
```

Backends: swap `emby`→`jellyfin`→`plex` in both flags (`--vp-probe-backend`,
`--vp-probe-<backend>-playback`). The app must be signed in to that backend on the sim
(the probe never authenticates).

## Reading the numbers

- `luma < ~16` on every frame → **black screen** (decoder produced nothing visible).
- `avg_g` far above `avg_r`/`avg_b` (or strong magenta skew) sustained across frames →
  **wrong-transfer/tint rendering** (e.g. DV P5 IPTPQc2 decoded as regular YCbCr).
- `status=no_new_pixel_buffer` on all frames while the probe still passes → the player is
  "playing" without delivering video frames — treat as black screen and investigate.
- Real content varies frame to frame; one dark frame is a dark scene, four identical
  near-zero lumas are a failure.

Trust the PNGs over thresholds: pull them and Read them — a human-recognizable movie frame
is the ground truth.

## Limits

- Requires the simulator (AVPlayer playheads don't advance headless on macOS CLI — see
  `headless-pmskit-probe` "Hard limits").
- Frames are tone-mapped to SDR BGRA by the capture conversion, so this judges
  *correct vs broken rendering*, not HDR colorimetry.
- Probe output PNGs may contain recognizable movie frames — never commit them; keep them in
  the app container or the session scratchpad.
