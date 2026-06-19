# Player & Downloads Audit and Roadmap (visionOS Plex Client)

> **SUPERSEDED (2026-06).** This roadmap spawned the GitHub issue tracker and every
> Executive Summary bug below has since been fixed on `main` (in-player Close via
> `contextualActions`; quality-reload keeps the playhead; failure overlay + stall
> watchdog + retry; download body validation + failed-state machine). Kept only as a
> dated historical synthesis — current state lives in
> [GitHub Issues](https://github.com/jlipworth/VisionPlay/issues) and
> `docs/DEVELOPMENT.md`.

Synthesis of 10 research agents: core-code audits (playback / downloads / PMSKit), competitive feature inventories (Plex, Emby/Infuse/Plexi/Aurora/VidHub/MrMC, Swiftfin, jellyfin-web), and Apple visionOS/AVFoundation platform briefs. Drives implementation. File:line locations are from the live tree.

---

## 1. Executive Summary

**State of the core.** The playback pipeline is well-structured: resume-via-offset-priming is the correct approach, transcode decision + start.m3u8 streaming works, timeline reporting has a sane 10s + transition cadence, subtitle selection via the legible AVMediaSelectionGroup is wired, and a quality-reload path exists. The downloads subsystem made a sound architectural choice (progressive MP4 over a background URLSession with relative-path persistence, atomic move, backup exclusion) that is the right fit for a self-hosted Plex server.

**But the core has real, shippable bugs.** Several are user-blocking: (1) there is **no working in-player close/Done button** — the comment claiming the system provides one is wrong for an AVPlayerViewController inside a `.fullScreenCover`; (2) the **Quality reload can drop the playhead to 0** because it snapshots the position but passes `resumeOffsetMs: nil` to `load()`; (3) **failed playback is never surfaced or retried** — a bad start.m3u8 leaves a black screen forever; (4) downloads **save Plex error/HTML pages as "complete," unplayable files** (no body validation), and **background failures silently delete the row** with no error shown.

**The single biggest architectural finding** (confirmed by Apple Forums 762008 + WWDC25): our custom controls are cinema-only because **we never enter the Expanded experience** and the player lives in a `.fullScreenCover` (embedded mode). `customInfoViewControllers` tabs only render in Expanded. The two strategic fixes are: present the player as **exclusive window content** and/or call `experienceController.transition(to: .expanded)`, OR build a **custom SwiftUI control overlay** over the player. Swiftfin and jellyfin-web both prove the custom-overlay path is what unlocks inline controls, on-video stats, trick-play, language pickers, and a Done button in one move — it resolves tasks #1, #2, #3, #5, #6, #7 simultaneously.

**Biggest opportunities, in order:** (a) fix the core bugs above; (b) custom SwiftUI control overlay (the keystone); (c) PMSKit data-layer gaps that block features — decode `Part.Stream` (audio/subtitle languages), request `includeChapters`/`includeMarkers` (chapters + Skip Intro/Credits), wire the existing-but-unused PlayQueue (next-episode/autoplay); (d) an accurate AVP DeviceProfile so PMS direct-plays more and transcodes less (improves quality, preserves tracks); (e) trick-play (server-side: emit an HLS I-frame playlist).

**Key platform truths that reframe several "tasks":**
- Audio collapsing to one track and generic "CC" labels are **PMS transcode / HLS-manifest problems**, not AVKit limitations. AVKit labels tracks from `EXT-X-MEDIA` `LANGUAGE`/`NAME`. The real fix is server-side (request multi-rendition / direct-play) plus a client-side `locale`/`extendedLanguageTag` fallback for labels.
- Trick-play thumbnails are **automatic** in AVKit when the master playlist contains `EXT-X-I-FRAME-STREAM-INF` (~145px). No client thumbnail code is needed for the system player — but our custom scrubber (if we build one) would need to fetch Plex BIF tiles itself.
- Native chapter scrubber ticks (`AVNavigationMarkersGroup`) are **tvOS-only**; our custom Chapters tab is the correct pattern on visionOS.
- Keep **progressive-MP4 downloads** as the default; AVAssetDownloadTask is only worth it later for multi-track offline, and only if PMS can serve a stable multi-rendition VOD playlist (it generally can't).

---

## 2. Core Spec Gaps & Bugs (fix first)

Deduped across audits. Severity: bug (incorrect/blocking) / risk (latent) / gap (missing baseline) / polish.

### Playback

| # | Title | Sev | Location | Fix | Effort |
|---|-------|-----|----------|-----|--------|
| P1 | **No working in-player close/Done affordance** — user can get stuck. AVPlayerViewController in a fullScreenCover has no system Close on visionOS. | bug | `UI/DetailView.swift:273-290` (comment is wrong), `Player/PlayerView.swift:81-86` | Thread `@Environment(\.dismiss)`/onDismiss into PlayerView; add a SwiftUI Done button (ZStack overlay top-leading, or `.ornament`) above the AVKit transport that flips `presentingPlayer=false`. Verify inline + expanded. | M |
| P2 | **Quality reload can reset playhead to 0** — snapshot captured but `load()` called with `resumeOffsetMs: nil`; resume depends entirely on PMS honoring `#EXT-X-START`. | bug | `Player/PlaybackController.swift:214-222, 228-283` (esp. 282) | On the reload path pass `resumeOffsetMs: resumeMs` to `load()`; after `readyToPlay`, if `currentTime()≈0` while `resumeMs>0`, client-seek as fallback. Keep offset-priming as fast path. | M |
| P3 | **Failed playback never surfaced or retried** — status observer only watches `.readyToPlay`; `.failed` ignored. Black screen forever. | bug | `Player/PlaybackController.swift:228-283, 326-338` | Handle `.failed` in the status observer: read `playerItem.error`, show user error + Retry (re-run `startStreaming`); observe `failedToPlayToEndTimeNotification`; one auto-retry on transient start.m3u8 failures. | M |
| P4 | **statusObservation self-nils inside its own callback** — a later `unknown→ready→failed` transition is missed (compounds P3). | polish | `Player/PlaybackController.swift:328-338` | Keep the observation alive for the item lifetime; use a `didSeek` Bool for one-shot resume; handle `.failed` in the same observer. | S |
| P5 | **Diagnostics Timer + observers never paused on background/headset-off** — keeps sampling, firing timeline POSTs, and AVPlayer keeps playing while occluded. | risk | `Player/PlaybackController.swift:314-324` | Observe `scenePhase` (or `willResignActive`); pause player + invalidate timer on background, resume on foreground; report paused/stopped timeline. | M |
| P6 | **KVO/notification Tasks can fire after stop()/reload()** during async teardown → duplicate/out-of-order timelines. | risk | `Player/PlaybackController.swift:328-368, 371-384, 135-139` | Add a session token (or `isTorn` flag) set in stop()/reload(); bail at the top of observer Tasks whose token ≠ current. | S |
| P7 | **No AVAudioSession config / interruption handling** — default ambient/solo behavior; no Siri/other-audio pause/resume. | gap | `Player/PlaybackController.swift` (none), `Player/PlayerView.swift:102-109` | Set category `.playback`, mode `.moviePlayback`, activate before play(); observe `interruptionNotification` (pause on `.began`, resume on `.ended` + `.shouldResume`). | S |
| P8 | **Timeline can send duration=0 / time≈0 heartbeats** during readyToPlay churn → confuses PMS Continue Watching. | polish | `Player/PlaybackController.swift:390-417, 349-355` | Skip timeline until `readyToPlay && durationMs>0`; debounce the first rate transition. | S |
| P9 | **Scrobble only fires on didPlayToEnd** — capped-HLS users stop short of EOF, so finished items stay unwatched; no ~90% threshold; no viewOffset refresh. | bug | `Player/PlaybackController.swift:357-368, 420-428` | Add progress-based scrobble at `currentMs/durationMs ≥ ~0.9`; keep didEnd as backstop; on stop() report a final `stopped` timeline with true offset; refresh item metadata (or clear viewOffset) on dismiss. | M |
| P10 | **Transcode forces `directPlay=0` with `directStream=1` but advertises only transcode targets** — over-transcodes compatible files; `.unsupported` decision proceeds silently; per-stream decision never decoded. | risk | `TranscodeRequest.swift:67-101`, `DeviceProfile.swift:24-32`, `DecisionResponse.swift:47-49, 261-265` | Build an accurate AVP DeviceProfile (HEVC/H.264/AAC/AC3/HDR/DoVi), allow `directPlay=1` within cap, decode `videoDecision`/`audioDecision`, surface `.unsupported` as a real failure. | L |

### Downloads

| # | Title | Sev | Location | Fix | Effort |
|---|-------|-----|----------|-----|--------|
| D1 | **`didFinishDownloadingTo` accepts any 2xx body** — saves Plex HTML/error pages and truncated transcodes as "complete," unplayable files. | bug | `Downloads/DownloadManager.swift:461-483` | Validate MIME is a video container (reject text/html, json); enforce min file size; if expected size known, check within tolerance; optionally probe `AVURLAsset.isPlayable`/`.duration`. On failure record `.transferFailed` and delete file. | M |
| D2 | **No persisted `complete` flag** — relaunch can't tell finished from stalled; completion inferred from `progress>=1.0`; lost tasks spin forever. | bug | `DownloadStore.swift:11-31, 45-51`; `OfflineLibraryView.swift:55`; `DownloadOptionsSheet.swift:113` | Add explicit status enum (`queued/downloading/complete/failed`) set in delegate callbacks; drive UI off it; reconcile rows with no live task + no file as `.failed` (offer retry) on launch. | M |
| D3 | **Background-delegate failures don't set `lastError`** — store.remove() erases the row with no surfaced reason; error UI never fires for the common case. | bug | `DownloadManager.swift:468, 480, 492`; `OfflineLibraryView.swift:73, 114-123` | Add `onError(ratingKey, DownloadError)` callback from each delegate failure path → manager records into `lastError`; keep a `.failed` row instead of deleting. | M |
| D4 | **`reattach()` hardcodes ext "mp4" and reconstructs the destination** instead of reading the persisted Row → wrong path / vanished downloads (esp. legacy mkv/avi optimize path). | bug | `DownloadManager.swift:388, 401-407, 144-145` | Resolve destination from the existing store Row (has ratingKey + relativePath); keep URL-derived ratingKey only as fallback. | S |
| D5 | **Offline playback loses all metadata** — duration, audio/subtitle tracks, resume offset, episode type, artwork all gone (only a stub `MediaItem` is rebuilt). | gap | `OfflineLibraryView.swift:110-112, 60-69`; `DownloadStore.swift:45-51`; `PlaybackController.swift:298` | Persist a snapshot of the source MediaItem (+ cached poster) per download (mirror Swiftfin's `Item.json`); rehydrate for PlayerView so offline keeps type/duration/chapters/resume. | M |
| D6 | **Progress bar permanently 0 when transcode response has unknown Content-Length** (chunked transcode → `totalBytesExpectedToWrite == -1`); "Optimizing on server…" mislabels active downloads. | gap | `DownloadManager.swift:452-454`; `OfflineLibraryView.swift:83-84` | Switch to an indeterminate ProgressView + transferred bytes/rate when expected size unknown; base "optimizing" label on an explicit pre-transfer state, not `progress==0`. | S |
| D7 | **No codec decision before download** — unsupported source → 4xx/HTML, row silently vanishes. | gap | `DownloadManager.swift:178-221, 467-470` | Run/inspect the decision endpoint before transfer; wire delegate→manager error channel (see D3) so failures surface. | M |
| D8 | **No resume-after-kill** — `resumeData` never captured; interrupted multi-GB downloads restart from zero. | gap | `DownloadManager.swift:485-495` | Stash `NSURLSessionDownloadTaskResumeData` on recoverable failures; offer retry via `downloadTask(withResumeData:)`; distinguish recoverable vs terminal (4xx). | M |
| D9 | **Progressive MP4 bakes in single audio + auto/burned subs** — offline has no language choice by construction. | risk | `TranscodeRequest.swift:148-161`; `DownloadManager.swift:200-207` | Document as a known offline limitation; surface "downloads are single-audio" in UI. Multi-track offline requires direct part download or AVAssetDownloadTask (see §4). | L |
| D10 | **Storage pre-check is a fixed 500MB floor**, ignores actual size → mid-transfer ENOSPC. | polish | `DownloadManager.swift:417-422` | Estimate target size (decision endpoint or bitrate×duration), require `free > estimate + margin`; show total offline storage used; handle ENOSPC as `.storageFull`. | S |
| D11 | **Dead/unverified optimize-queue path still shipped** as public API with unreachable error states/labels. | polish | `DownloadManager.swift:121-161, 265-318, 324`; `OptimizeRequest.swift:83-134` | Delete the optimize-queue path + its now-dead error cases/labels (or finish it properly). | M |
| D12 | **No concurrency cap; `isDiscretionary=false` + cellular** — many large transcodes can run at once over cellular, hammering PMS. | polish | `DownloadManager.swift:352-356, 416-428` | Bound concurrent transcoded downloads (1–2) via an app-level queue; reconsider cellular default. | S |

### PMSKit data layer (blocks feature work)

| # | Title | Sev | Location | Fix | Effort |
|---|-------|-----|----------|-----|--------|
| K1 | **No `Stream` model on `Part`** — audio/subtitle language pickers have no data source (root blocker for #3 and #5). | gap | `Models/Library.swift:240-270`; `PlayerControlSurface.swift:202-204` | Add a `Stream` struct (streamType, id, index, language, languageTag/Code, displayTitle, extendedDisplayTitle, codec, channels, selected, default, forced, key); decode `Part.Stream`. | M |
| K2 | **Metadata never requests `includeChapters`/`includeMarkers`** — Chapter model is dead; no intro/credit markers (blocks Skip Intro/Credits + Chapters tab). | gap | `UI/RootView.swift:86-92`; `Models/Library.swift:165-194` | Add `includeChapters=1&includeMarkers=1&includeExtras=1` to metadata; add a `Marker` model (intro/credits/commercial, start/endTimeOffset, final). | M |
| K3 | **PlayQueue built but never used** — no next-episode/autoplay; timelines carry no `playQueueItemID`. | gap | `Playback/PlayQueue.swift:8`; `PlaybackController.swift:228` | Create a play queue at playback start (pass show/season context for episodes); thread `playQueueID`/`playQueueItemID` into player + TimelineRequest; add GET `/playQueues/<id>` to read next item. | L |
| K4 | **Only one Media version surfaced** — no multi-version/edition selection. | gap | `Models/Library.swift:67, 196-238` | When `media.count>1`, expose a version picker; pass chosen Media/Part to the decision (mediaIndex/partIndex). | M |
| K5 | **Timeline lacks `X-Plex-Session-Identifier`** — PMS can't correlate timeline with the transcode session or dedupe concurrent sessions. | polish | `TimelineRequest.swift:11-122`; `PlaybackController.swift:405-416` | Add a stable per-playback `X-Plex-Session-Identifier` to timeline/scrobble + decision; skip heartbeats when `durationMs==0`. | S |
| K6 | **ResourceDiscovery drops fields useful for server selection** (owned, presence, publicAddressMatches, connection address/port/protocol). | polish | `Auth/ResourceDiscovery.swift:64-124` | Decode those fields; prefer owned+present servers; skip clearly-unroutable local addresses before probing. | S |
| K7 | **Missing API surfaces** for feature work: GET/create playQueue wired in; includeChapters/markers/extras + Marker; Part.Stream + audioStreamID/subtitleStreamID on decision; PUT default-stream; BIF/trick-play endpoint; section `/all` sort/filter + container paging. | gap | `PMSKit/Sources/PMSKit` | Add builders/params (see §3 per-area). | L |

---

## 3. Feature Buildout by Area

For each: best clients / do-we-have-it / visionOS recommendation / priority / effort. Cross-refs to Swiftfin & jellyfin-web paths and Apple APIs.

### 3.1 Player menu / control surface (KEYSTONE)
- **Best clients:** Swiftfin renders a **fully custom SwiftUI overlay** over AVPlayer — top toolbar (close + title + action buttons + overflow menu), center transport, bottom capsule scrubber with chapter masking and trick-play bubble, poke-timer auto-hide. (`Shared/Views/VideoPlayer/PlaybackControls.swift`, `VideoPlayerContainerView`, `VideoPlayer+Toolbar.swift`, `VideoPlayer+ActionButtons.swift`.) jellyfin-web: single bottom OSD bar with subs/audio/settings/PiP/AirPlay (`controllers/playback/video/index.html`).
- **We have it:** partial — controls live in `customInfoViewControllers` which render **only in Expanded** on visionOS (Apple Forums 762008; `PlayerControlSurface.swift:52-96`).
- **Recommendation:** Build a custom SwiftUI control overlay in a ZStack above the AVPlayer surface (set `showsPlaybackControls=false`, or use `contentOverlayView`). Hosts Done, transport, Quality, Audio, Subtitles, Stats, scrubber. This one change resolves #1, #2, #3, #5, #6, #7. Auto-filter buttons (hide audio/subtitle when no tracks — Swiftfin `adjustedTrackIndexes`), but **skip** user-customizable bar/overflow layout (over-engineered for single-user).
- **Apple APIs:** `AVPlayerViewController.showsPlaybackControls`, `.contentOverlayView`, `.contextualActions`; SwiftUI `.ornament`; UIViewControllerRepresentable. **Priority: high. Effort: L.**

### 3.2 Quality / bitrate
- **Best clients:** Plex ladder with resolution-tagged labels (20/12/10/8 Mbps 1080p, 4/3/2 Mbps 720p, 1.5 Mbps 480p, audio-only steps, "Original," "Convert Automatically"). jellyfin-web 14 tiers + Auto showing resolved bitrate / "Auto - Direct," filters above source bitrate, ×1.5 ref bump for HEVC/AV1/VP9 (`components/qualityOptions.js`, `playersettingsmenu.js`). Swiftfin 16-step `PlaybackBitrate.swift` with auto speed-test, rebuilds item at new bitrate and resumes (`PlaybackQualityActionButton`).
- **We have it:** partial — coarse 2/4/8/12/20 + "Maximum," no resolution labels, springy scroll (List-in-info-panel sizing artifact).
- **Recommendation (#6):** Adopt Plex's exact ladder + labels (`"8 Mbps · 1080p"`); rename "Maximum" → "Maximum (Original, no cap)"; add an Auto option; filter tiers above source bitrate; show current selection as a subtitle on the Quality row. The springy scroll disappears once Quality lives in the custom overlay (not a fixed-size info-panel tab). Keep resume-on-change (fix P2 makes it reliable).
- **Priority: high. Effort: M.**

### 3.3 Audio + language
- **Best clients:** Plex/Infuse/Plexi/MrMC in-player audio picker with language+codec+channel labels from server metadata. Swiftfin `AudioActionButton.swift` Picker over `audioStreams` keyed by `stream.index`, labeled by server `displayTitle` ("English - AC3 5.1"). jellyfin-web `showAudioTrackSelection`.
- **We have it:** no. Root cause: PMS universal transcode **collapses audio to one track**; Swiftfin hits the same on its transcode path.
- **Recommendation (#3):** Two prongs. (a) **Data:** decode `Part.Stream` (K1) to show real language names. (b) **Multi-track:** the only ways to get selectable audio are **Direct Play** (when source codec is AVPlayer-compatible — preserves all `AVMediaSelectionGroup` audio renditions, surfaced by AVKit for free) or requesting a new transcode decision with a specific `audioStreamID` and reloading at offset (Swiftfin's playNewItem pattern). Prefer Direct Play via an accurate DeviceProfile (P10). Don't hand-build an audio picker if Direct Play exposes the native one.
- **Apple APIs:** `AVMediaSelectionGroup(.audible)`, `AVMediaSelectionOption.displayName/.locale/.extendedLanguageTag`, `AVPlayerItem.select(_:in:)`; HLS `EXT-X-MEDIA TYPE=AUDIO LANGUAGE`. **Priority: high. Effort: L** (M if Direct Play only).

### 3.4 Subtitles + language + styling
- **Best clients:** Swiftfin `SubtitleActionButton.swift` (Picker over `subtitleStreams` + ".none Off", server `displayTitle`). jellyfin-web full appearance engine (size/font/color/shadow/position/mode) + named tracks (`components/subtitlesettings`, `subtitleappearancehelper.js`). Plex: named tracks, 50ms offset, search/download, styling.
- **We have it:** partial — generic "CC", no language names.
- **Recommendation (#5):** Label from `AVMediaSelectionOption.displayName`, falling back to `locale`/`extendedLanguageTag` when generic; append "(Forced)"/"(SDH)" via `hasMediaCharacteristic(.containsOnlyForcedSubtitles / .transcribesSpokenDialogForAccessibility)`; prepend an explicit "Off". This is a pure client change — do it first. For richer names, also decode Plex `Stream(streamType=3)` (K1). Burned-in subs (PGS/VOBSUB) need `subtitles=burn` on PMS; expose subtitle size (we hardcode 100). **Skip** offset/search/full styling (AVKit honors system caption styling for legible renditions; offset has no per-track API).
- **Apple APIs:** `AVMediaSelectionOption.displayName(with:)`, `.locale`, `.extendedLanguageTag`, `.hasMediaCharacteristic`. Code site: `PlaybackController.loadSubtitleTracks() :166`. **Priority: high. Effort: S** (client labels) **/ M** (server-named + Off).

### 3.5 Trick-play scrubbing thumbnails
- **Best clients:** Swiftfin `TrickplayPreviewImageProvider.swift` (tile sprite extraction + adjacent-tile prefetch, rendered above scrubber while scrubbing in `PlaybackProgress.swift`; chapter-image fallback). jellyfin-web `updateTrickplayBubbleHtml`.
- **We have it:** no.
- **Recommendation (#4):** **Two paths.** (a) **System player (zero client code):** ensure PMS start.m3u8 master includes an `EXT-X-I-FRAME-STREAM-INF` (~145px) — AVKit then renders scrubbing thumbnails automatically (WWDC23 10070). First, **fetch and inspect our start.m3u8** for an I-frame variant; PMS live transcode usually doesn't emit one. (b) **Custom scrubber:** if we adopt the overlay (3.1), port Swiftfin's provider against Plex BIF index (`/library/parts/<id>/indexes/sd`) — fetch tile, crop, prefetch neighbors, render above the custom scrubber.
- **Apple APIs:** HLS `EXT-X-I-FRAME-STREAM-INF` (no AVKit toggle). **Priority: high. Effort: M.**

### 3.6 Chapters / markers / Skip Intro / Skip Credits
- **Best clients:** Swiftfin `MediaChaptersSupplement.swift` (poster grid + seek + active-chapter tracking) + scrubber chapter notches. jellyfin-web/Plex Skip Intro/Credits via media segments / markers (`mediaSegmentManager.ts`, `skipsegment.ts`); Disabled/Manual/Auto.
- **We have it:** partial (custom Chapters tab; no markers).
- **Recommendation:** Request `includeChapters`/`includeMarkers` (K2) + add `Marker` model. Show a transient "Skip Intro"/"Skip Credits" button when the playhead enters a marker range (seek to `endTimeOffset`); add Disabled/Manual/Auto setting (ignore <1s segments and seek-backs). Add chapter notches to the custom scrubber. Native scrubber ticks (`AVNavigationMarkersGroup`) are tvOS-only — keep the custom tab.
- **Priority: medium. Effort: M.**

### 3.7 Stats overlay (Emby-style)
- **Best clients:** jellyfin-web `playerstats.js`/`.scss` — absolutely-positioned translucent panel top-left **over the video** (not modal), category→rows data model, refreshed on `timeupdate` throttled 700ms; categories: Playback Info (play method), Player media/video/audio (size, dropped/corrupted frames), Transcoding Info (target codecs, completion %, **transcode reasons**, fps multiplier), Original Media (HDR/DoVi/color/audio). Swiftfin `PlaybackInformationSupplement.swift` polls `/Sessions`. Emby/Infuse HUD overlay.
- **We have it:** partial — `StatsForNerdsView` exists (supports free-floating via `onClose`) but wired only as a modal info tab.
- **Recommendation (#7):** Render as a toggleable translucent SwiftUI overlay anchored `.topLeading` in `contentOverlayView` (or the custom overlay). Model `PlaybackDiagnostics` as `[StatCategory{name, subText, rows}]`, refresh via `addPeriodicTimeObserver`. Add fields from `AVPlayerItemAccessLogEvent` (`indicatedAverageBitrate`, `numberOfBytesTransferred`/`transferDuration` for throughput, `startupTime`, `numberOfDroppedVideoFrames`, `observedBitrate`, `serverAddress`) and Plex session (`videoDecision`/`audioDecision`, transcode reasons, `transcodeSpeed`/progress, HW accel).
- **Apple APIs:** `AVPlayerItem.accessLog()/errorLog()`, `AVPlayerItemAccessLogEvent`, `contentOverlayView`. **Priority: high. Effort: M.**

### 3.8 Continue Watching / autoplay-next / Up Next
- **Best clients:** Plex Up Next card + auto-play next (2-hr idle cutoff, minimize during credits). Swiftfin `AutoPlayActionButton`/`PlayNextItem` over `manager.queue`. jellyfin-web `upNextContainer`.
- **We have it:** partial (resume via viewOffset + timeline; no Up Next UI; PlayQueue unused).
- **Recommendation:** Wire PlayQueue (K3); show an Up Next card near credits; auto-advance on didPlayToEnd with an autoplay-next toggle + 2-hr idle cutoff. Ensure a Continue Watching browse row (Plex `/hubs`/onDeck). Refresh item metadata on dismiss so finished items leave the rail (ties to P9).
- **Priority: medium. Effort: M–L.**

### 3.9 Downloads
- **Best clients:** Swiftfin per-item folder + persisted `Item.json` + images, parse-on-launch rebuild, explicit `DownloadTask.State` (`Shared/Services/Download*`). Plex: quality presets + storage limit, sync watched state.
- **We have it:** yes (progressive MP4 + OfflineLibraryView) but with the bugs in §2 (D1–D12).
- **Recommendation:** Fix D1–D8 first (correctness). Then borrow: persist source metadata + poster (D5), explicit state machine (D2), parse-on-launch rebuild as a corruption fallback, storage budget + total accounting (D10). Add an "Original" quality option. Keep progressive MP4 as default (see §4).
- **Priority:** correctness = high; polish = low. **Effort: see §2.**

### 3.10 Theater / immersive
- **Best clients:** Infuse (Cinema/Room/Space/Sunset/Void + screen size/angle/seating); Plexi (Monolith/Crimson + positioning); Apple TV (floor/balcony seating, Digital Crown immersion); visionOS 26 docked mode with light spill. 3D/MV-HEVC + 180/360 immersive (Plexi, Apple TV).
- **We have it:** partial (`CinemaEnvironment` sets `allowedExperiences = .recommended()`).
- **Recommendation:** Near-term, **enter Expanded explicitly** (see §4) so docking works. Later: custom RealityKit theater via ImmersiveSpace + Reality Composer Pro **Docking Region** (WWDC24 10115), with reflections/environment probe/`surroundingsEffect`/`immersiveContentBrightness`/Reverb, registered via `.immersiveEnvironmentPicker`; add user screen-size/angle/seating controls. 3D/MV-HEVC and 180/360 via RealityKit `VideoPlayerComponent` (WWDC25 296) — niche for a Plex library.
- **Priority:** Expanded transition = high; custom theater + 3D = low. **Effort: S** (transition) **/ L** (custom theater).

### 3.11 Browse / library
- **Best clients:** Home rows (Resume, Next Up, latest, recommendations), watched/progress indicators, spoiler-safe blurred unwatched thumbnails (Aurora). jellyfin-web `components/homesections`, `indicators/useIndicator.tsx`.
- **We have it:** partial.
- **Recommendation:** Ensure Continue Watching + Next Up rows (Plex `/hubs`). Add progress bar + watched badge on posters (viewOffset/viewCount/lastViewedAt). Optional: blur unwatched episode thumbs. Add section `/all` sort/filter + container paging for large libraries (K7).
- **Priority: medium. Effort: M.**

### 3.12 Settings
- **Best clients:** Swiftfin `VideoPlayerSettingsView.swift` (preferred audio/subtitle language, play-default-track, remember-selection, subtitle mode/styling). Plex account preferred languages.
- **We have it:** no (player settings).
- **Recommendation:** Slimmed version: preferred audio/subtitle language passed to the decision so the right default track is chosen; autoplay-next toggle; Skip Intro/Credits mode (Disabled/Manual/Auto); download storage budget + default quality. **Skip** full subtitle styling (system-handled).
- **Priority: medium. Effort: M.**

**Explicitly out of scope:** SyncPlay/Watch Together (deprecated, single-user); OpenSubtitles download; subtitle offset/auto-sync (AVKit/server); FairPlay (no DRM); brightness/volume/scrub touch gestures (no touch surface on visionOS); VLC fallback (impractical on visionOS).

---

## 4. Platform-Recommended Refactors

### R1 — Player presentation: fix cinema-only controls + missing close (root cause)
- **Why:** `customInfoViewControllers` tabs render **only in Expanded**; we present in a `.fullScreenCover` (embedded) and never call `transition(to: .expanded)`, so tabs are unreachable and there's no Done button (Apple Forums 762008; WWDC25 296).
- **Two viable directions:**
  1. **Commit to system Expanded:** present the AVPlayerViewController as **exclusive content of its own window scene** (`openWindow`/`dismissWindow`) and/or call `experienceController.transition(to: .expanded)` after play. Window chrome handles dismissal; keep info tabs. Matches the `PlayerView.swift` header comment ("Present as exclusive content of its window scene").
  2. **Custom SwiftUI overlay** (recommended, see 3.1): `showsPlaybackControls=false`, draw our own controls in a ZStack / `contentOverlayView`. Unlocks inline controls + Done + on-video stats + trick-play + language pickers in one move.
- **Apple APIs:** `AVPlayerViewController.experienceController`, `AVExperienceController.allowedExperiences/.transition(to:)/.Experience{.embedded,.expanded,.immersive,.multiView}`, `WindowGroup`/`openWindow`/`dismissWindow`, `.contextualActions`, `.contentOverlayView`. **Refs:** Forums 762008; WWDC23 10070; WWDC25 296; "Adopting the system player interface in visionOS"; Destination Video ("Building an immersive media viewing experience").

### R2 — Languages via AVMediaSelection + manifest fix
- **Why:** Generic "CC" and single audio are **HLS-manifest/PMS artifacts**, not AVKit limits. AVKit labels from `EXT-X-MEDIA LANGUAGE/NAME`.
- **Do:** (client) label from `displayName` → `locale`/`extendedLanguageTag` fallback + forced/SDH characteristics; (server) audit `TranscodeRequest.sharedQueryItems()` and `DeviceProfile.clientProfileExtra`, and **fetch/inspect the live start.m3u8** to see what `EXT-X-MEDIA` it actually carries; pursue Direct Play / multi-rendition so multiple named audio/subtitle groups exist.
- **Apple APIs:** `AVMediaSelectionGroup`, `AVMediaSelectionOption.displayName(with:)/.locale/.extendedLanguageTag/.hasMediaCharacteristic`. **Ref:** WWDC23 10070.

### R3 — Trick-play = server-side I-frame playlist (verify before building)
- **Why:** AVKit auto-renders thumbnails when the master has `EXT-X-I-FRAME-STREAM-INF` (~145px); no client API.
- **Do:** Inspect start.m3u8 for an I-frame variant. If PMS can't emit one for live transcode, the system-player path is server-limited → use a custom-scrubber BIF overlay instead (3.5). **Ref:** WWDC23 10070.

### R4 — Offline: keep progressive MP4; AVAssetDownloadTask only for multi-track later
- **Why:** AVAssetDownloadTask crawls a **static VOD** `.m3u8` to a `.movpkg`; Plex's start.m3u8 is a **live single-session** transcode that tears down — wrong fit. Progressive MP4 over one background `URLSession.downloadTask` is the verified, correct default.
- **Do later (capability-gated):** AVAssetDownloadTask is the **only** Apple-blessed way to persist multiple audio/subtitle renditions offline — and only worth it if PMS can serve a stable multi-rendition VOD playlist (spike: inspect start.m3u8 for multiple `EXT-X-MEDIA` groups; expected: it can't). If pursued, use modern `AVAssetDownloadConfiguration` + `AVAssetVariantQualifier(predicate:)` (peakBitRate cap), not the legacy options dict; progress is time-ranges, not bytes.
- **Also adopt now (independent of movpkg):** persist download location as a **bookmark** (not absolute path) so playback survives container moves; app-side storage budget/eviction (AVAssetDownloadStorageManager only manages `.movpkg`); keep the background-session relaunch/completion-handler lifecycle (already mostly correct). **Refs:** WWDC20 10655; WWDC21 10143; `AVAssetDownloadConfiguration` docs.

### R5 — externalMetadata + audio session + speeds (cheap polish)
- Set `AVPlayerItem.externalMetadata` (title/subtitle/artwork/description) so the system player shows a proper title (`PlaybackController.startStreaming()/loadLocalFile() :228,287`). Configure AVAudioSession (P7). Confirm/enable `AVPlayerViewController.speeds` for playback speed. **Refs:** `AVPlayerItem.externalMetadata`, `AVPlaybackSpeed.systemDefaultSpeeds`.

---

## 5. Recommended Sequencing

### Phase 0 — Correctness bugs (ship before any features)
- **P1** Done/close button (#1, quick interim: a SwiftUI overlay button; full fix folds into R1).
- **P2** Quality-reload playhead fix.
- **P3 + P4** Failed-playback surfacing + retry; keep observation alive.
- **D1** Download body validation; **D3** delegate→manager error channel; **D2** explicit download state.
- **P9** progress-based scrobble + final stopped timeline.
- Effort: mostly S–M. Highest user impact per hour.

### Phase 1 — Quick wins (client-only, high visibility)
- **#5** Subtitle language labels via AVMediaSelection fallback (S) — R2 client half.
- **R5** externalMetadata title/art (S), AVAudioSession + interruptions (P7, S), playback speed (S).
- **P5/P6/P8** background pause + teardown token + timeline debounce.
- **D4/D6/D10** download reattach-from-row, indeterminate progress, size-aware storage check.
- **K5** session identifier.

### Phase 2 — Data layer (unblocks the big features)
- **K1** `Part.Stream` model. **K2** includeChapters/includeMarkers + `Marker`. **K3** wire PlayQueue. **K4** version picker. **K6** richer discovery. **D5** persist offline metadata + poster.
- **P10** accurate AVP DeviceProfile + decode video/audio decision + allow Direct Play within cap (enables real multi-audio).

### Phase 3 — Keystone refactor: custom control overlay (R1)
- Build the SwiftUI overlay → resolves **#1 close, #2 inline controls**, hosts **#6 quality menu** (resolution labels + Auto, no springy scroll), **#3 audio picker**, **#5 named subtitles + Off**, **#7 stats overlay** (translucent, anchored, category/rows, access-log fields), custom scrubber with chapter notches.

### Phase 4 — Feature buildout on the overlay
- **#4 trick-play** (R3 verify I-frame → else BIF overlay). **Skip Intro/Credits** (markers from K2). **Up Next / autoplay-next** (K3) + Continue Watching browse row. Settings (preferred languages, autoplay, skip mode, download budget).

### Phase 5 — Larger / optional
- Custom RealityKit theater (Docking Region, reflections, seating controls) + visionOS 26 docked light-spill.
- 3D/MV-HEVC + 180/360 via RealityKit `VideoPlayerComponent`.
- AVAssetDownloadTask multi-track offline (only if PMS multi-rendition VOD confirmed) + bookmark-based storage + eviction.

### Mapping to existing task list
- **#1 close button** → P1 (Phase 0 interim) → R1 (Phase 3 full).
- **#2 inline controls** → R1 custom overlay (Phase 3).
- **#3 audio languages** → K1 + P10 Direct Play (Phase 2) → picker in overlay (Phase 3).
- **#4 thumbnails** → R3 verify (Phase 1 check) → trick-play (Phase 4).
- **#5 subtitle languages** → client labels (Phase 1) → named + Off in overlay (Phase 3).
- **#6 quality menu** → quality menu in overlay (Phase 3).
- **#7 stats overlay** → stats overlay in overlay (Phase 3).

### New tasks beyond #1–#7
- **#8** Failed-playback error UI + retry (P3).
- **#9** Quality-reload resume fix (P2).
- **#10** Download integrity: body validation + error surfacing + state machine (D1/D2/D3).
- **#11** Progress-based scrobble + Continue-Watching refresh (P9).
- **#12** PMSKit `Part.Stream` + markers + PlayQueue wiring (K1/K2/K3).
- **#13** Accurate AVP DeviceProfile + Direct Play within cap (P10).
- **#14** Skip Intro / Skip Credits.
- **#15** Up Next / autoplay-next episode.
- **#16** Persist offline metadata + poster (D5); download resume-after-kill (D8).
- **#17** Background-aware playback (pause on headset-off) + AVAudioSession/interruptions (P5/P7).
- **#18** externalMetadata + playback speed + session identifier (R5/K5).
- **#19** (optional) Custom RealityKit theater + seating/screen controls.
- **#20** (optional) Multi-track offline via AVAssetDownloadTask (gated on PMS multi-rendition VOD).
