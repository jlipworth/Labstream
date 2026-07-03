# DV Profile 5 Guard + Gated True-DV Spikes (#196) — Design

**Goal:** DV Profile 5 titles never render garbage or fail mysteriously on any backend, and the
app gains default-off, device-verifiable machinery for true Dolby Vision signalling.

**Context (live-verified, 2026-07-03):** A DV P5 (IPTPQc2, BL-compat 0) MP4 at Original quality
fails on all three backends, each differently: Plex → client decoder-not-found (`VT-DS -12906`,
surfaced as -11833); Jellyfin → progressive lane rejects samples (-12864), HLS transcode fallback
stalls server-side (SEGPUMP -12889, no segments); Emby → silent black screen, no error at all.
P7/P8 titles on copy lanes play correctly as their HDR10 fallback. Full evidence in issue #196.

## Scope

- **In:** P5 safety guard (default-on), first-frame watchdog with DV-specific error, Stats
  "rendered vs source" clarity, experimental DV-signalling setting gating two spikes
  (dvh1 MP4 direct-play advertising; HLS playlist DV injection via the existing rewriter).
- **Out (later session):** physical-device DV rendering matrix; enabling any Goal-1 behavior by
  default. Nothing from the spikes ships default-on without headset verification.

## 1. P5 guard (default-on)

New pure policy in PMSKit: `DolbyVisionPlaybackPolicy`.

- Input: the stream's `VideoHDRMetadata` (already decoded for all three backends since #195).
- Verdict: `.allowCopyLanes` or `.forceToneMapTranscode(reason: String)`.
- Rule: Dolby Vision present AND (`blCompatibilityID == 0`, or `profile == 5` with nil compat).
  P7/P8 with HDR10/SDR/HLG-compatible base layers stay on copy lanes (proven correct).
- Bypass: only when the experimental DV-signalling setting (§3) is enabled — an opted-in DV
  lane may make P5 playable; the guard defers rather than forcing a transcode it would
  immediately contradict.

Enforcement points (one per backend, each consulting the same policy):

- **Plex:** the transcode-decision path requests a video transcode instead of allowing
  Direct Play / Direct Stream when the verdict is `forceToneMapTranscode`.
- **Jellyfin / Emby:** the PlaybackInfo request disables direct play and direct stream for the
  item (`EnableDirectPlay=false`, `EnableDirectStream=false`) so the server mints a tone-mapped
  video transcode.

The decision surface (Stats "Decision" row + diagnostic fields) carries the reason,
e.g. `video transcode · DV P5 guard`.

## 2. First-frame watchdog + specific error

Forcing a transcode is not sufficient: Jellyfin's own P5 tone-map stalled live, and Emby's is
unverified. When (and only when) the guard has forced a transcode, `PlaybackController` arms a
~20 s first-frame watchdog reusing the existing stall-watchdog machinery. If no video has
rendered when it fires, playback fails with a DV-specific message:

> This title uses Dolby Vision Profile 5, which this server could not convert.

This replaces the generic media-code alert (Plex/Jellyfin today) and the silent black screen
(Emby today) for the guarded lane.

## 3. Experimental setting + spike (a): dvh1 MP4 direct-play

New Settings toggle **"Dolby Vision signalling (experimental)"**, default off.

When on, the device profiles additionally advertise Dolby Vision in MP4-family containers:

- Plex: `X-Plex-Client-Profile-Extra` gains DV profile 5/8 HEVC entries (the base
  `Generic` profile name is untouched — hard constraint).
- Jellyfin/Emby: the client DeviceProfile adds `dvh1`/`dvhe` (profiles 5, 8) MP4 direct-play
  entries and DV codec-profile conditions.

Effects to validate: DV MP4s with real `dvh1` sample entries direct-play with signalling intact;
Jellyfin/Emby stop stripping `dvcC`/RPUs on remux when the client advertises DV (Swiftfin
finding). Simulator validates "accepts and plays"; only the headset validates "renders true DV"
(deferred). Default-off means the conservative shipping profile is unchanged — acceptance
criterion of #196.

## 4. Spike (b): HLS playlist DV injection (debug-gated, verification-first)

The app already routes remote HLS through a loopback proxy with a `PlaylistRewriter`
(`PMSKit/Sources/PMSKit/MediaSession/MediaSessionProxy.swift`, `PlaylistRewriter.swift`).
Extend the rewriter with an optional DV-injection step:

- On master-playlist `EXT-X-STREAM-INF` lines: add `SUPPLEMENTAL-CODECS` (value derived from the
  source's DV profile/compat, e.g. `dvh1.08.06/db1p` shapes) and `VIDEO-RANGE=PQ`.
- Routing: when the experimental setting is on and the source is DV, Plex `start.m3u8` sessions
  go through the loopback proxy (they currently go direct).

**Honesty check (built into the spike):** signalling DV that the segments do not contain would
*cause* the exact garbage this issue exists to prevent. Before trusting injection, verify via
server-side ffprobe (kubectl into the media containers) whether Plex's remux segments retain DV
RPUs. If they do not, the documented finding is "not viable for Plex-remuxed MKV" and the
injection stays a dead-end behind its debug gate. That is an acceptable spike outcome.

## 5. Stats: rendered vs source

Since #195 the Stats panel shows the *source* HDR classification. Add the actual-rendering
dimension:

Add a conditional **"Rendered"** row (wraps: true), shown whenever the source is DV or HDR:

- Guarded/forced transcode → `SDR (server tone-map)` — replaces guessing from the Output hint.
- Copy lane, DV source, no DV signalling → `HDR10 fallback (base layer)` for P7/P8.
- DV-signalled lane (experimental on) → `Dolby Vision (signalled — unverified)` until the
  device pass upgrades our confidence; derived from the runtime probe plus lane knowledge.
- Non-DV HDR source on a copy lane → `HDR10` / `HLG` per the runtime probe.

## 6. Error handling summary

| Situation | Behavior |
|---|---|
| P5 detected, guard on | Forced tone-map transcode, decision reason visible |
| Forced transcode produces no frame in ~20 s | DV-specific error alert |
| P5 detected, experimental DV signalling on | Guard defers to DV lane |
| DV injection enabled but segments lack RPUs (spike finding) | Injection not enabled for that lane; documented |

## 7. Testing

- **PMSKit unit tests:** policy verdicts across real per-backend metadata shapes (#195 live
  fixtures: Jellyfin numeric DV fields, Plex DOVI fields, Emby `DoviProfile50/76/81`);
  playlist-rewriter DV injection against fixture master playlists; profile additions present
  only when the experimental flag is set.
- **Sim smoke (all three backends, P5 title):** guard forces transcode; Jellyfin's stall now
  surfaces the specific error within ~20 s; Emby either plays tone-mapped SDR or errors —
  never a silent black screen.
- **Server-side verification:** kubectl/ffprobe of Plex remux session output for RPU retention
  (spike b gate).
- **Deferred to device session:** {P5, P7.6, P8.1} × {Plex, Jellyfin, Emby} × {direct-ish,
  forced transcode} on-screen matrix, recorded in #196.

## Constraints

- `X-Plex-Client-Profile-Name=Generic` stays (hard constraint; DV additions go in the Extra).
- No broad DV whitelisting in shipping profiles; everything from Goal 1 is default-off.
- No tokens/hostnames/titles in committed artifacts or issue comments.
