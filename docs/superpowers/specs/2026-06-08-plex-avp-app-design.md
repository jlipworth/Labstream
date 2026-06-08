# Design Spec — plex-avp-app

**Date:** 2026-06-08
**Status:** Draft for review (pre-implementation)
**Scope:** v1 of a personal-use native visionOS Plex client

---

## 1. Problem & goal

The official Plex "visionOS app" is the iPad build in compatibility mode — **no theater mode**. Third-party visionOS clients each cover *some* of the user's needs but none cleanly covers all three. The user's Plex server already transcodes reliably (validated, Plex Pass active, HW transcode).

**Goal:** one native visionOS app that does all of:
1. **Reliable server-side transcoding** — request a bitrate-capped HLS stream, not direct-play-only.
2. **Theater playback** — flat 2D movies/TV on a giant virtual screen in a cinema environment.
3. **Offline downloads** — capped-bitrate (~8 Mbps) copies for slow/no connection, so no second app is needed.

Full supporting research: [`../../../research/01`–`13`](../../../research/). This spec consolidates findings + locked decisions; it does not repeat every endpoint detail (see `research/09`, `11`, `13` for those).

## 2. Locked decisions

| Decision | Choice | Rationale |
|---|---|---|
| v1 scope | **Core + downloads** | Covers the full "avoid two apps" goal in v1 (browse → transcoded theater playback → resume → offline downloads). |
| Min deployment target | **visionOS 26** | Latest playback APIs (`AVExperienceController`, current Cinema Environments / docking, `immersiveEnvironmentPicker`); only the user's own headset must run it. |
| Project layout | **Single app target, 6 folder groups** | Simplest for a solo personal app; refactor to SPM later if it grows. |
| Starting point | **Adapt Apple's `Destination Video` sample** | Sample already pairs a 2D browse window with a player that docks into a custom cinema environment — our exact shape, permissive license. |
| Distribution | **Sideload** (free Apple ID to start; $99 Developer Program later) | No App Store intent; $99 only needed to escape the 7-day re-sign. |

**Explicitly deferred (NOT in v1):** 3D SBS/TAB rendering (hard, no system support — `research/02`); true 180/360/MV-HEVC immersive playback (no such content in the library — out of scope entirely); music/photos; multi-user; casting; Live TV / Discover.

## 3. Architecture

Single visionOS SwiftUI app target. A `WindowGroup` hosts the 2D browse UI; the player presents fullscreen and docks into a Cinema Environment (no persistent `ImmersiveSpace` needed in v1). State is coordinated by a shared `@Observable` app model, mirroring the Destination Video pattern.

### Modules (folder groups)

| Module | Purpose | Depends on |
|---|---|---|
| **AppState** | Observable app/session state; selected server; navigation. Leaf. | — |
| **PlexAuth** | PIN-OAuth flow, persist `X-Plex-Token` + stable `X-Plex-Client-Identifier` in Keychain; server discovery via `clients.plex.tv/api/v2/resources`. | AppState |
| **PlexAPI** | Hand-rolled REST: library browse, `/hubs`, media metadata, the **transcode-decision → `start.m3u8`** flow with a DeviceProfile, timeline/scrobble, playQueues, and the **Media Optimizer** trigger + status. Reference: `python-plexapi` `getStreamURL()` (BSD, safe to port). | PlexAuth, AppState |
| **Player** | `AVPlayerViewController` wrapper; feeds it the transcode HLS URL or a local file (same code path); Cinema Environment docking; audio/subtitle selection; periodic time observer → timeline reporting. | PlexAPI, AppState |
| **DownloadManager** | Trigger `Video.optimize(...)` ("Optimized for TV – 8 Mbps 1080p"), poll conversion status, fetch the optimized MP4 via `?download=1` with a background `URLSession`, store in Application Support, manage/delete. | PlexAPI, AppState |
| **LibraryUI** | SwiftUI views: Home (hubs), Libraries (poster grid + sort/filter, TV season/episode nav), Search, Detail (artwork/synopsis/cast, Play/Resume, Download, mark-watched), Settings, server picker. | all above |

### Navigation (from `research/05`)
Floating browse window with a slim tab strip: **Home · Libraries · Search**, plus a gear (Settings) and server picker. The headline experience is the big-screen player.

## 4. Key data flows

**Auth (once):** PIN-OAuth → token in Keychain → discover servers → pick server + per-server access token. Token layer is abstracted (the JWT migration is a medium-risk future — `research/07`).

**Browse:** `GET /hubs` builds Home; library grids + metadata via standard endpoints.

**Play:**
1. (TV) `POST /playQueues` to get `playQueueItemID`; movies can skip.
2. Read `viewOffset` → resume position.
3. `GET /video/:/transcode/universal/decision?hasMDE=1...` with the DeviceProfile (`X-Plex-Client-Profile-Extra`) → inspect `generalDecisionCode` (1000≈direct play / 1001≈transcode).
4. `GET .../start.m3u8` with the same params (`protocol=hls`, `maxVideoBitrate=8000`, `directPlay=0`) → hand URL to `AVPlayer`. Token as **query param**, not header.
5. `/:/timeline` heartbeat every ~10s + on state change (resume/On Deck write path); `stop` ends the session; `/:/scrobble` marks watched. **Encapsulate the HTTP method**: official Redoc lists timeline as POST and scrobble/unscrobble as PUT, while legacy clients use GET — live-test against the server and keep the choice behind the PlexAPI layer (`research/13`).

**Download (capped offline):** three mechanisms exist (`research/06`, `11`); v1 uses #2 as the primary path:
1. **Direct `?download=1`** — fetches the *original* part (free, no transcode/cap). Fallback for already-small files only.
2. **Media Optimizer** (primary): `Video.optimize(...)` → server creates an 8 Mbps MP4 *version* ("Optimized for TV – 8 Mbps 1080p"), free on our own server (Plex Pass present anyway). Poll conversion status → background `URLSession` fetch of the optimized part via `?download=1` → Application Support → offline playback feeds the local file to the same Player path.
3. **Official Mobile Sync** (Plex-Pass-gated) — not used in v1; the Optimizer path already gives us a capped file without depending on the Sync API.

## 5. Error handling

- **Auth:** token expiry/401 → re-run PIN flow; surface server-unreachable distinctly from auth failure.
- **Transcode:** read the decision response before `start.m3u8`; if the server can't satisfy the profile, surface a clear message rather than a silent black screen. Handle HEVC-needs-fMP4 gotcha (`research/09`).
- **Network:** LAN-first connection, graceful fallback to remote (Plex Pass enables off-LAN); buffering/timeouts shown, not hung.
- **Downloads:** optimize-job failure and storage-full are explicit states; resumable/cancelable; transfers stall while headset is off the head (`research/10`) — communicate, don't appear frozen.

## 6. Testing

- **Unit:** PlexAPI URL/param builders (transcode request, DeviceProfile string, timeline params), decision-response parsing, optimize/status parsing. These are pure functions — high-value, easy to test. Port `python-plexapi` behavior, but **not** its `partIndex=mediaIndex` bug (`research/09`).
- **Integration (manual, against the real server):** auth, browse, a forced 8 Mbps transcode play, resume round-trip, an optimize+download+offline-play cycle.
- **Device:** real-headset checks for theater docking + playback; the Simulator can't fully exercise environments.

## 7. Distribution / sideload reality

Free Apple ID → 7-day provisioning expiry, Mac-tethered rebuild, 3-app limit; AltStore/SideStore don't support visionOS (`research/03`). Plan to buy the **$99/yr Developer Program** before depending on the app daily (yearly profiles, no weekly re-sign).

## 8. Risks & open items

- **3D SBS deferred** — revisit only if the library has 3D rips worth the custom ShaderGraph render.
- **Transcode endpoints are reverse-engineered/version-dependent** — now partly covered by the official spec (`research/07`), but verify against the live server.
- **JWT auth migration** — not imminent (PMS still rejects JWTs); abstract the token layer so a future switch is contained.
- **`plexswift` is archived** — we hand-roll REST and use `python-plexapi`/`plex-for-kodi` as references (don't copy GPL Kodi code; port BSD python-plexapi).

## 9. Rough build order (for the implementation plan)

1. Scaffold from Destination Video; strip to shell; wire AppState.
2. PlexAuth (PIN-OAuth + Keychain + server discovery) — verify login on device.
3. PlexAPI browse + Home hubs; LibraryUI Home/Libraries/Detail.
4. Player: transcode decision + `start.m3u8` + `AVPlayerViewController` + Cinema Environment; timeline reporting + resume.
5. DownloadManager: optimize → poll → background download → offline playback.
6. Search, settings, polish, error states.

*Detailed step-by-step plan to follow via the writing-plans flow once this spec is approved.*
