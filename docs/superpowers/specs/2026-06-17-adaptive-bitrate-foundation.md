# Adaptive bitrate foundation (#29)

## Scope

This branch does **not** claim that Plex or Jellyfin currently serve VisionPlex a true
multi-rendition HLS ladder. True ABR is still the preferred end state: the server returns a master
playlist with multiple `#EXT-X-STREAM-INF` variants and AVPlayer switches among them without the app
reopening the stream.

What is implemented here is a bounded client-driven adaptation state machine for the architecture
VisionPlex has today:

- Plex: reopen the universal transcode session through `beginStreaming`.
- Jellyfin / remote backend: reopen through the existing `remoteStreamReopener` closure.
- Static remote streams with no reopener and local downloads: no automatic adaptation, because the
  player has no safe way to renegotiate bitrate.

The live segment probe now prints the number of master-playlist variants so a future session can
confirm whether PMS is serving true multi-rendition HLS for a given request shape.

## Automatic ladder behavior

Automatic changes operate only on bounded transcode rungs:

`2 Mbps → 3 → 4 → 8 → 10 → 12 → 20 → 40 Mbps`

A user's explicit quality choice remains the ceiling for the session. Automatic adaptation may move
below that ceiling and later climb back up toward it, but it does **not** write Settings/UserDefaults
or exceed the selected cap.

The feature is controlled by **Settings → Playback → Adaptive Bitrate**. It defaults off while
we continue device/fluctuating-network validation; when disabled, sustained stalls follow the
normal visible Retry/failure path instead of reopening at a lower rung, and healthy playback does
not upshift.

Sentinel qualities are treated conservatively:

- `Direct Play / Maximum` (`0`) is **not** automatically downshifted by ABR. This is an explicit
  request to keep video-copy/direct-stream behavior on fast links; silently converting it to a capped
  video transcode was the observed source of the confusing "fallback to ~20 Mbps" behavior. If this
  path truly cannot play, the app surfaces the normal visible failure/Retry state instead of
  abandoning the user's direct-play intent.
- `Maximum (HLS)` (`200 Mbps` ceiling) can downshift to `40 Mbps` first and climb back only to
  the highest bounded rung. Despite the high cap, Plex may still Direct Stream/video-copy compatible
  sources; this option means maximum-cap production HLS, not forced video re-encode.


## Direct Play / Maximum and Plex Direct Stream

For Plex, `Direct Play / Maximum` now first probes whether PMS can copy the source video. Plex may
accept the MDE/direct-play probe but reject the literal `directPlay=1` `start.m3u8`; in that case the
app falls back to the production universal HLS request using the Generic client profile. That
production path can still be a **Direct Stream** (`video copy · audio transcode`) rather than a video
transcode.

Important distinctions for debugging:

- Stats `Mode = Direct Stream` with `Decision = video copy · audio transcode` means the video is not
  being re-encoded, even if Plex's raw part decision string says `transcode` because audio is being
  converted/remuxed into HLS.
- Direct Play / Maximum uses Plex media identity headers on AVFoundation requests so the media-plane
  fetch matches the successful control-plane preflight.
- The Plex profile name is `Generic`, not `Safari`, because the Safari profile path was observed to
  force/reject 10-bit HEVC direct-stream cases and collapse back into capped video transcodes.
- A high-bitrate direct-stream can still fail in the simulator if AVFoundation/simulator networking
  cannot keep up. The app gives Direct Play / Maximum a longer stall grace and then surfaces Retry;
  it deliberately does not auto-convert that explicit choice into a capped video transcode. The live
  segment probe proves the server can serve the bytes; headset/device playback is still the decisive
  proof for very high-bitrate remuxes.

Current app-driven probe evidence on this branch:

- A ~20 Mbps 4K HEVC/MKV Plex item at `Direct Play / Maximum` plays as `Direct Stream`,
  `video copy · audio transcode`, `is_transcoding=false`, with no ABR downshift.
- A ~57 Mbps 4K HEVC/MKV Plex item is served by PMS as `video copy · audio transcode` and the
  segment probe fetches real fMP4 media at a deep offset. The simulator still did not reach playing
  within the Direct Play / Maximum grace window: observed throughput climbed to ~53 Mbps against a
  ~56.5 Mbps required/source bitrate, then the app surfaced the visible Retry failure with a
  Direct Play capacity/player-path hint, without any ABR downshift or capped video transcode. Retest
  on device before treating very high-bitrate remux playback as solved.

## Anti-oscillation policy

The deterministic policy in `AdaptiveBitratePolicy` protects medium/unstable connections from
terminal ping-pong:

- Downshift only after the existing sustained-stall watchdog fires.
- Upshift only after continuous healthy playback with enough buffered media ahead.
- Enforce a cooldown between all automatic changes.
- Require an extra cooldown after a downshift before any upshift.
- Require observed-throughput headroom for upshift when AVFoundation reports it.
- Cap automatic changes per sliding time window.
- Change only one rung at a time.

Manual Quality changes reset the automatic state machine and remain explicit user intent.

Jellyfin remote transcodes use a lower upshift buffer threshold than Plex because #43 deliberately
keeps their AVPlayer forward buffer short to avoid first-frame/deep-seek stalls. The same long
healthy-playback, post-downshift, cooldown, and frequency gates still apply; only the "enough
buffer ahead" number is adjusted so Jellyfin can recover upward instead of becoming down-only.

## Headless verification hook

Run with the existing gitignored Plex env file:

```bash
./scripts/live-segment-probe.sh
```

Look for:

```text
>>> SEG master variants: 1 adaptive=no bandwidths=...
```

or, for true server-side ABR:

```text
>>> SEG master variants: 2 adaptive=YES bandwidths=...
```

## Still open

- Live-confirm whether Plex can emit a multi-rendition master for VisionPlex's request/profile shape.
- Live-confirm whether Jellyfin returns a true ABR master for this app's playback request, or whether
  the remote reopener path remains the practical fallback.
- Device-test the client-driven up/down behavior on a real fluctuating connection. Headless tests
  prove the state machine and request plumbing, not AVPlayer's on-device timing.
