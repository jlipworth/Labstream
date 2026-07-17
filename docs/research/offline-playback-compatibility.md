# Offline playback compatibility on Apple Vision Pro

Status: **closed implementation-research snapshot** for
[#167](https://github.com/jlipworth/Labstream/issues/167), which closed on 2026-06-30.
Last source review: 2026-06-27. The routing summary below explains the original policy
decision but is not an exhaustive description of the subsequently expanded finalization,
attempt-ownership, or revalidation machinery. Current behavior and invariants live in
[`docs/DOWNLOADS-OFFLINE.md`](../DOWNLOADS-OFFLINE.md) and the current source.

This note documents the compatibility checks Labstream applies before, during, and after an offline download. The important distinction is:

- **Source-item checks** decide which route to request from Plex/Jellyfin/Emby.
- **Final-artifact checks** decide whether the actual file that landed on disk is usable for offline AVFoundation playback.

The source checks are intentionally conservative heuristics. The final artifact is still the authority: it is fixed up if needed, opened as a local `AVURLAsset`, advanced through a muted `AVPlayerItem`, duration-checked, and then marked `.complete`, `.unverified`, or `.failed`.

## Apple compatibility baseline

Official Apple references used for this pass:

- Apple Vision Pro technical specifications list video playback support for **HEVC**, **MV-HEVC**, **H.264**, and HDR formats including **Dolby Vision**, **HDR10**, and **HLG**: <https://support.apple.com/kb/SP911?locale=en_US>.
- The same Apple Vision Pro specs list audio playback support including **AAC**, **MP3**, **Apple Lossless**, **FLAC**, **Dolby Digital**, **Dolby Digital Plus**, and **Dolby Atmos**: <https://support.apple.com/kb/SP911?locale=en_US>.
- Labstream's final-file check uses AVFoundation's `AVURLAsset` / `AVPlayerItem` local playback path, not server streaming success, as the compatibility proof for the downloaded file: `Labstream/Downloads/BackgroundDownloadSession.swift`.

What this means for Labstream:

- H.264 and HEVC are safe video targets for MP4-family offline files.
- AAC is the safest broad audio output target. AC-3/E-AC-3 can be compatible, but server/device variation means the app still treats the final AVFoundation probe as authoritative.
- MKV, raw streaming playlists, and opaque live transcode streams are not treated as durable offline artifacts. They must be remuxed/transcoded into a static local file.
- HEVC in MP4-family containers can still fail if the track uses an `hev1` sample entry where AVFoundation expects `hvc1`; Labstream runs the post-download HEVC tag fixup before playback validation.

## Current source-route decision path

### Shared PMSKit decisions

`PMSKit/Sources/PMSKit/Downloads/OfflineDownloadDecision.swift` centralizes the route-level compatibility facts:

- `isLocallyPlayableOriginal(part:)`: only `mp4`, `m4v`, and `mov` sources are eligible for byte-for-byte original offline download.
- `existingVersionPlayableOffline(container:videoCodec:)`: existing server-rendered versions fail closed unless the container is MP4-family and the video codec normalizes to `h264` or `hevc`.
- `compatibleRemuxEligibility(videoCodec:audioCodec:sourceContainer:)`: original-quality compatible remux is allowed only when the video can be copied into MP4 (`h264`/`hevc`). Audio is copied for `aac`/`ac3`/`eac3`; otherwise the server is asked to transcode audio to AAC.
- `originalEligibility(decision:part:)`: Plex original download requires both a direct-play decision and an MP4-family local container.

These functions are pure and unit-tested, so route decisions can be validated headlessly without server secrets.

### Plex

Current path:

1. `DownloadManager.directPlayProbe(for:server:token:mediaIndex:partIndex:)` sends a download-time Plex decision request with a high bitrate ceiling.
2. `OfflineDownloadDecision.originalEligibility` requires the decision to play the whole file directly and the source part to be MP4-family.
3. Byte-for-byte `.original` still runs a muted AVPlayer preflight before commit; failure falls back to a compatible optimizer route.
4. Existing Plex Versions use `existingVersionPlayableOffline` because they do not have the same preflight safety net.
5. Compatible original-quality and bitrate presets use the Plex optimizer/static rendered-part path and then download a static file.

Implication: a Plex stream that is fine through server remux/HLS may still be rejected for raw offline original if its source is MKV or another non-MP4 local container.

### Jellyfin

Current path:

1. The normal original/static lane targets a direct Jellyfin media file request only for locally playable originals.
2. Bitrate presets use a Jellyfin download `PlaybackInfo` request and a static/transcoded MP4-style output for the selected quality.
3. `Original quality (compatible)` re-probes `PlaybackInfo` at download/retry time, then uses `compatibleRemuxEligibility` to decide whether to copy H.264/HEVC video into MP4 or fall back to a safe transcode.
4. Transcoded/remuxed Jellyfin downloads are treated as live-forward server encoder outputs: they are not byte-range resumable and require active-encoding cleanup.

Implication: Jellyfin source metadata is advisory; the authoritative compatible-remux decision comes from the download-time `PlaybackInfo` response.

### Emby

Current path:

1. `DownloadManager.downloadEmby` always makes an authoritative download `PlaybackInfo` POST before choosing a transfer route.
2. `EmbyDownloadRouter` maps the negotiated verdict onto:
   - `.original` / `.existingVersion`: static `stream.{container}?static=true`, range-resumable, only when negotiated direct play plus local container/codec gates pass;
   - `.compatibleRemux`: original-quality MP4 remux when source video is copyable;
   - `.transcode`: not downloaded directly for offline; optimize requests reroute to Emby server convert-then-download, and unsafe original/existing-version transcode verdicts fail loudly.
3. Emby convert-then-download records the completed server-prepared `MediaSourceId`, then hands off to the `.existingVersion` static lane.
4. Paused static Emby existing/prepared downloads now promote durable partial files before backend-specific retry dispatch, so retry should issue an observable range/static restart instead of no-oping.

Implication: Emby is the most server-state-sensitive path. The selected `MediaSourceId` and the final unfiltered `PlaybackInfo` view must be captured when diagnosing existing/prepared version mismatches.

## Backend compatibility matrix

| Backend | User-facing route | Source gate | Transfer artifact | Resume model | Final artifact validation |
| --- | --- | --- | --- | --- | --- |
| Plex | Original | Plex direct-play decision + MP4-family source container | Source file bytes | Static/range capable | HEVC tag fixup, AVURLAsset/AVPlayer probe, duration guard |
| Plex | Existing Version | MP4-family + H.264/HEVC fail-closed gate | Server-rendered version bytes | Static/range capable | Same final validation |
| Plex | Original quality compatible | Optimizer/rendered part; source video may be copied/remuxed | Static MP4-family file | Static after server prep | Same final validation |
| Plex | Bitrate preset | Optimizer target | Static MP4-family file | Static after server prep | Same final validation |
| Jellyfin | Original | Locally playable original source | Source/static media file | Static/range capable | Same final validation |
| Jellyfin | Original quality compatible | Download-time `PlaybackInfo` + H.264/HEVC copyability | MP4 remux or fallback transcode output | Live-forward encoder output | Same final validation, then active-encoding cleanup |
| Jellyfin | Bitrate preset | Download-time `PlaybackInfo` | MP4 transcode output | Live-forward encoder output | Same final validation, then active-encoding cleanup |
| Emby | Original | Download-time `PlaybackInfo` direct play + local container/codec gate | Static `stream.{container}?static=true` | Static/range capable | Same final validation |
| Emby | Existing/prepared version | Selected `MediaSourceId` + download-time `PlaybackInfo` + local container/codec gate | Static server-prepared file | Static/range capable | Same final validation |
| Emby | Original quality compatible | Remux-profile `PlaybackInfo` + H.264/HEVC copyability | MP4 remux or safe fallback path | Live-forward if encoder-backed | Same final validation, then active-encoding cleanup |
| Emby | Bitrate preset | Server convert job then prepared `MediaSourceId` | Static converted file | Static/range capable after conversion | Same final validation |

## Final-artifact checks

The final-file gate is in `BackgroundDownloadSession.finalizeTransferredFile` and shared by both opaque `downloadTask` and app-managed byte-range/data-task transfers:

1. If the destination extension is `mp4`, `m4v`, or `mov`, run `HEVCTagFixup.rewriteFile` to rewrite `hev1` to `hvc1` when needed.
2. Load the destination as an `AVURLAsset` and require `asset.isPlayable`.
3. Create an `AVPlayerItem`, mute playback, and require it to reach `readyToPlay` and advance far enough for the validation policy.
4. Retry the probe with longer timeouts before giving up, because the local probe can transiently false-negative on busy hardware.
5. Compare decoded duration to expected source duration when both are known; delete and fail obviously truncated files.
6. Mark the row:
   - `.complete` when the local file played and is not truncated;
   - `.unverified` when the probe is inconclusive but bytes are preserved;
   - `.failed` when the file is an error body or materially truncated.

This is stronger than trusting route selection alone. A route can be correctly selected but still produce an invalid local file because of a server abort, stale metadata, an unsupported final codec combination, or an HEVC tag issue.

## Representative validation cases

Use these as the regression/live matrix for #167 and adjacent download issues:

| Case | Expected route | Headless coverage | Human / physical AVP coverage |
| --- | --- | --- | --- |
| H.264 + AAC MP4 original | Byte-for-byte original | `OfflineDownloadDecision`, final validation unit coverage, simulator smoke | Confirm normal playback, audio, seek, resume offline |
| HEVC MP4 with `hev1` sample entry | Static/remux path + tag fixup | `HEVCTagFixupTests`, completion validation tests | Confirm no black screen on physical AVP |
| MKV H.264 + AAC | Reject raw original; remux/copy video into MP4 where backend supports it | compatible-remux eligibility tests and request-shape tests | Confirm downloaded remux plays offline |
| MKV HEVC + TrueHD/DTS/FLAC/Opus | Copy HEVC video only if safe; transcode audio to AAC or use full transcode/convert | compatible-remux eligibility tests | Confirm audio is present and in sync on AVP |
| Existing server version with unknown/non-MP4 container | Hide/fail raw existing-version download | `existingVersionPlayableOffline` tests | No human check unless UI still exposes it |
| Emby prepared/existing static version with partial file | Retry should promote partial and issue a new static/range attempt | `DownloadRetryPolicyTests` | Reproduce affected title and confirm retry visibly resumes/restarts |
| Text subtitles | Sidecar text tracks available offline | `OfflineTextSubtitle*` tests | Select subtitles during offline playback |
| Image subtitles / burn-in-needed subtitles | Not represented as offline text sidecars; require server burn-in or device/live decision | route/request tests only | Confirm behavior on physical AVP with real subtitle track |
| HDR / Dolby Vision / MV-HEVC | Source may be supported by device, but route heuristics only prove broad codec/container safety | metadata/probe diagnostics only | Physical AVP visual confirmation required |

## Headless vs. physical-device proof

Headless and simulator tests can prove:

- pure route gates (`OfflineDownloadDecision`, `EmbyDownloadRouter`, retry policy);
- request shape and selected `MediaSourceId` for Plex/Jellyfin/Emby probes;
- that completed files run through HEVC tag fixup, final AVFoundation validation, truncation guard, and `.complete`/`.unverified`/`.failed` outcomes;
- that diagnostics remain privacy-safe and include codec/container/route facts without raw URLs or tokens.

Only a physical Apple Vision Pro can fully prove:

- rendered video actually appears correctly, especially HEVC/HDR/Dolby Vision/MV-HEVC cases;
- audio output is present, compatible, and in sync for AC-3/E-AC-3/Dolby Atmos or server-transcoded AAC paths;
- subtitle selection and image/burn-in subtitle behavior;
- high-bitrate/off-head/background-transfer behavior under real device scheduling;
- Emby/Jellyfin/Plex server-specific quirks for named media and prepared versions.

Therefore #167 should stay open after this research doc until the representative physical/live cases above are either tested or explicitly split into narrower follow-up issues.
