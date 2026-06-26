# Live-server test matrix (issue #75)

This is the **design + coverage map** for live-server integration testing of VisionPlay against a
real media server (Plex first; Jellyfin/Emby as the parallel lanes mature). It answers three
questions:

1. **What** real user flows must be covered (the matrix below).
2. **Where** each flow is — or should be — exercised, and at which layer (mocked unit vs. live
   PMSKit probe vs. device-only).
3. **How** to wire the live tests into CI (see the companion
   [`TESTING-LIVE-REQUIREMENTS.md`](TESTING-LIVE-REQUIREMENTS.md)).

It is the automated counterpart to the manual [`TESTING-CHECKLIST.md`](../TESTING-CHECKLIST.md):
the checklist is the human headset/sim pass and issue trail; this matrix is the structure the
automated + live-probe coverage is built against. Where a row is currently a manual-only check,
that is called out so the gap is explicit rather than silent. The strategy framing
(what may/may not become a required CI assertion, device-only gates) lives in
[`TESTING-STRATEGY.md`](TESTING-STRATEGY.md); this doc is the row-by-row coverage map.

## Test layers (vocabulary used in the matrix)

| Layer | What it is | Hermetic? | Where it lives |
|---|---|---|---|
| **Unit (mocked/local)** | Pure request builders, decoders, policy state machines, routing helpers. No network. | Yes — runs in plain `swift test` and CI. | `PMSKit/Tests/PMSKitTests/*Tests.swift` (everything except `Live*ProbeTests`). |
| **Live probe (opt-in)** | Sends the *real* PMSKit request builders through `URLSession` to a real server, asserts decoders/decisions against the live wire shape. | Yes by default (no-op without env vars); exercises the network only when creds are present. | `PMSKit/Tests/PMSKitTests/Live*ProbeTests.swift` + `scripts/live-*.sh` + `scripts/*-live.env`. |
| **Sim smoke** | `xcodebuild` install → launch → log → screenshot on the worktree simulator. Proves the app *runs* and reaches the expected UI. | macOS+Xcode only; no remote server beyond the signed-in Plex account. | `docs/DEVELOPMENT.md` build/smoke block; run after any app-code change. |
| **Device-only (manual)** | Headset playback, AVPlayer media-plane behavior, audio routing, Spotlight/Intents, on-head transfer. Cannot be asserted off-device. | No. | `TESTING-CHECKLIST.md`. |

Design rule: **push every assertion as far up this table as it can faithfully live.** A nuance that
a request-builder unit test can prove (param shape) belongs in a unit test; a nuance that needs the
*server's* verdict (does PMS honor `subtitles=burn`?) belongs in a live probe; only genuinely
on-device behavior (does AVPlayer render the burned pixels?) stays device-only.

## How to read the matrix

- **Unit** = mocked/local coverage exists (file named).
- **Live probe** = an opt-in `Live*Probe` covers the server wire shape (file named), or *(gap)*.
- **Device** = remains a manual headset/sim check (→ `TESTING-CHECKLIST.md` section).
- The **representative E2E proof** added for #75 is the subtitle-burn row, marked **★**.

---

## 1. Screens & navigation

| Flow | Unit (mocked/local) | Live probe | Device / manual |
|---|---|---|---|
| Server/backend selection & sign-in (Plex link code, Jellyfin, Emby Connect PIN) | `PinAuthTests`, `EmbyAuthTests`, `EmbyConnectTests`, `JellyfinAuthTests`, `PlexAccountTests` | `LiveEmbyProbe` (auth + `System/Info/Public`) | Checklist A (link code, Emby PIN UX) |
| Resource/server discovery | `ResourceDiscoveryTests`, `UpstreamConnectionTests` | *(gap — covered indirectly by every Plex probe's connect)* | Checklist A |
| Home rails / hubs load | `HomeRailsLoadTests`, `HubsResponse` decode in `DecodingTests` | *(gap)* | Checklist A/B |
| Library grid browse + paging | `MediaBrowserLibraryGridPolicyTests`, `PagingPageWindowTests`, `BrowseUIGateTests`, `LibraryVisibilityTests`, `AlphabetBucketTests` | `LiveEmbyProbe` (browse + DTO mapping); **`LivePlexBrowseProbe`** (sections + grid + paging) | Checklist B |
| TV hierarchy (show → season → episode) | `TVHierarchyTests`, `EpisodeOrderingTests`, `ChildrenRequest` | **`LivePlexBrowseProbe`** (`/children` traversal; parent/grandparent ids chain coherently) | Checklist B |
| Movie version collapse | `MovieVersionCollapseTests` | *(gap)* | Checklist B |
| Detail page (extended metadata: cast/rating/logo) | `ArtworkMetadataTests`, `DecodingTests` | *(gap)* | Checklist B |
| Music browse/filter/playlists | `MusicFilterTests`, `MusicRequestTests`, `PlaylistRequestTests` | *(gap)* | Checklist C |

## 2. Menus & settings

| Flow | Unit (mocked/local) | Live probe | Device / manual |
|---|---|---|---|
| Streaming-quality ladder (Mbps cap → resolution/audio caps) | `StreamingQualityTests`, `TranscodeRequestTests`, `AdaptiveBitratePolicyTests` | `LiveDecisionProbe`, `LiveSegmentProbe` (cap honored on the wire) | Checklist B (quality reload) |
| Library visibility toggles | `LibraryVisibilityTests` | *(gap)* | Checklist B |
| Diagnostics / privacy redaction | `DiagnosticLoggingTests` | n/a (redaction is hermetic by design) | Checklist B |
| Backend switch (Plex ↔ Jellyfin ↔ Emby) | `MediaBackendSwitchTests` | *(gap)* | Checklist A |

## 3. Playback startup & in-player controls

| Flow | Unit (mocked/local) | Live probe | Device / manual |
|---|---|---|---|
| Transcode decision (MDE verdict, `savesVideoEncode`) | `TranscodeRequestTests`, `DecodingTests`, `CompatibleRemuxEligibilityTests` | **`LiveDecisionProbe`** (raw decision JSON, direct-play probe) | — |
| start.m3u8 + HLS segment priming (deep-seek/resume) | `HLSPlaylistSummaryTests`, `OptimizePlaylistTests`, `SeekRestartBudgetTests` | **`LiveSegmentProbe`** (primed segments at a deep offset) | Checklist B (headset media plane) |
| Direct-play / compatible-remux routing | `CompatibleRemuxEligibilityTests`, `CompatibleRemuxRequestTests`, `FinalTargetRebuildPolicyTests` | `LiveDecisionProbe` (direct-play probe path) | Checklist B |
| Playback failure / fallback policy | `PlaybackFailurePolicyTests`, `PlaybackStateTests` | *(gap — failure injection)* | Checklist B |
| Scrub / seek / chapter controls | `PlaybackScrubStateTests`, `PlaybackSeekControlTests`, `ChapterSelectionTests` | *(gap)* | Checklist B |
| Timeline / progress reporting & resume | `PlaybackStateTests`, `QueueMutationTests` | `LiveEmbyProbe` (Emby progress); **`LivePlexTimelineProbe`** (`/:/timeline` report → `viewOffset` read-back round-trip) | Checklist B |
| Queue mutation (play next / shuffle) | `QueueMutationTests`, `PlaybackStateTests` | **`LivePlayQueueMutationProbe`** (create queue → play-next → shuffled create) | Checklist B/C |
| Session stop / transcode cleanup | `MediaSessionProxyTests` | `LiveEmbyProbe` (active-encoding stop); **`LivePlexTimelineProbe`** (`TranscodeRequest.stop` ends a started session) | Checklist B |
| Cinema/expanded routing | `CinemaExitRoutingTests`, `SystemEntryRoutingTests` | n/a (immersive space) | Checklist B (device-only) |

## 4. Subtitles

| Flow | Unit (mocked/local) | Live probe | Device / manual |
|---|---|---|---|
| Subtitle track discovery (per-part streams) | `DecodingTests` (Stream decode), `StreamSelectionTests` | discovery in **`LiveSubtitleBurnProbe`** | Checklist B |
| **Subtitle burn-in honored by server ★** | `TranscodeRequestTests` (the `subtitles=burn` param shape) | **`LiveSubtitleBurnProbe`** — asserts PMS flips `videoDecision` to `transcode` for a burned image-based subtitle | Checklist B (does AVPlayer render the pixels) |
| Offline / sidecar text subtitle parsing (SRT/VTT) | `OfflineTextSubtitleParserTests`, `OfflineTextSubtitles` | **`LiveSidecarSubtitleProbe`** (`/library/streams/<id>` fetch + parser decode) | Checklist B |
| Subtitle stream selection passthrough | `StreamSelectionTests` | *(gap)* | Checklist B |

The **★ row is the representative end-to-end proof for #75**: a real nuance — "does the server
actually apply a burned subtitle?" — that no mock can catch, asserted at the live-wire layer. See
[`LiveSubtitleBurnProbeTests.swift`](../PMSKit/Tests/PMSKitTests/LiveSubtitleBurnProbeTests.swift)
and [`scripts/live-subtitle-burn-probe.sh`](../scripts/live-subtitle-burn-probe.sh).

## 5. Profiles (device profile / quality-profile application)

| Flow | Unit (mocked/local) | Live probe | Device / manual |
|---|---|---|---|
| Device profile (`X-Plex-Client-Profile-*`) built correctly | `TranscodeRequestTests`, `PlexHeadersTests` | `LiveDecisionProbe`/`LiveSegmentProbe` (the live request carries the real profile) | — |
| Quality profile → decision (cap actually applied server-side) | `TranscodeRequestTests`, `AdaptiveBitratePolicyTests` | `LiveSegmentProbe` (segment size shrinks when cap forces transcode) | Checklist B |
| Direct-play probe profile vs. production profile | `CompatibleRemuxEligibilityTests` | `LiveDecisionProbe` (both profiles, same item) | Checklist B |
| HEVC tag fixup / remux eligibility | `HEVCTagFixupTests`, `CompatibleRemuxEligibilityTests` | `LiveSegmentProbe` (fMP4 vs TS sniff) | Checklist B |

> **Note on "profiles".** VisionPlay has no *user account* profile switcher (it is a single-user
> client); "profile" here means the **device/quality profile** advertised to the server, which is
> what determines whether a title direct-plays, remuxes, or transcodes. The #75 "profiles not
> loading/switching/applying" nuance maps onto *quality-profile application*, covered by the
> decision/segment probes. If multi-user account profiles are ever added, add a row here and a
> dedicated probe.

## 6. Downloads & offline

| Flow | Unit (mocked/local) | Live probe | Device / manual |
|---|---|---|---|
| Download route decision (original vs. optimizer vs. remux) | `OfflineDownloadDecisionTests`, `DecisionResponseDownloadTests`, `CompatibleRemuxRequestTests` | **`LiveDownloadProbe`** (original-vs-optimizer route), **`LiveOptimizeProbe`** (optimize discovery) | Checklist B |
| Optimize playlist / rendered-part route | `OptimizePlaylistTests`, `OptimizeTests` | `LiveOptimizeProbe`, `LiveSegmentProbe` | Checklist B |
| Download queue & progress | `DownloadProgressDisplayTests`, `BackgroundQueueTests`, `OfflineDownloadModelsTests` | **`LiveDownloadStatusProbe`** (read-only queue/progress snapshot) | Checklist B (background/off-head) |
| Emby download path | `EmbyDownloadTests` | **`LiveEmbyDownloadProbe`** | Checklist B (device-only) |
| Offline playback decision (use local copy) | `OfflineDownloadDecisionTests` | **`LiveOfflinePlaybackDecisionProbe`** (real PMS item + completed local fixture routes to `.localFile`) | Checklist B |
| Activities polling (server-side optimize jobs) | `ActivitiesTests` | `LiveOptimizeProbe` | Checklist B |

---

## Coverage gaps and future additions

The matrix names every *(gap)* explicitly so the backlog is visible rather than implied. The
highest-value Plex gaps are now built: **`LivePlexBrowseProbe`** (sections + grid + TV hierarchy),
**`LivePlexTimelineProbe`** (progress round-trip + session stop), **`LiveSidecarSubtitleProbe`**
(live `/library/streams/...` text-subtitle fetch + parse), **`LiveOfflinePlaybackDecisionProbe`**
(downloaded local fixture wins over remote routing), and **`LivePlayQueueMutationProbe`**
(play-next + shuffled-queue wire operations).

New gaps should follow the exact same opt-in, env-gated, no-secret pattern as the existing probes:
a `Live<Name>ProbeTests.swift`, a `scripts/live-<name>-probe.sh`, any new env vars documented in
`plex-live.env.example` + `TESTING-LIVE-REQUIREMENTS.md`, and a matrix row flipped from *(gap)* to
the new probe name.
