# 10 — Apple Media API Inventory (visionOS 26)

Scope: the exact Apple frameworks/classes to implement each feature of a personal-use
visionOS Plex client, with the bulk of the analysis on **offline download of a
bitrate-capped transcode**. Assumes **visionOS 26 SDK (June 2026)**. Playback/theater
(AVPlayerViewController + Cinema Environments + AVExperienceController) is already
established elsewhere and is not re-derived here. Plex-side endpoint mechanics live in
`01-plex-api-transcoding.md`; this doc is the Apple-API counterpart and cross-references
it rather than repeating it.

> API-name discipline: every class/method below is a real Apple symbol. Where a claim is
> a community pattern (not an Apple/Plex guarantee), it is flagged **[risk]**.

---

## 1. OFFLINE HLS DOWNLOAD — the crux

### 1.1 The two Apple offline-media APIs

| API | Symbol | Notes / visionOS |
|---|---|---|
| Modern (preferred) | `AVAssetDownloadURLSession.makeAssetDownloadTask(downloadConfiguration:)` taking an `AVAssetDownloadConfiguration` (with `primaryContentConfiguration` / `auxiliaryContentConfigurations` of type `AVAssetDownloadContentConfiguration`, qualified by `AVAssetVariantQualifier` + `AVAssetDownloadStorageManagementPolicy`) | Introduced iOS 15 / aligned-year visionOS 1+; present in visionOS 26. This is the API to use for **bitrate selection** — you pick the ~8 Mbps variant with an `AVAssetVariantQualifier` predicate on `AVAssetVariant.peakBitRate`/`averageBitRate`. |
| Legacy | `makeAssetDownloadTask(asset:assetTitle:assetArtworkData:options:)` with `AVAssetDownloadTaskMinimumRequiredMediaBitrateKey` / `...PresentationSizeKey` | Still available; coarser bitrate control. |
| Multi-rendition | `AVAggregateAssetDownloadTask` | Lets you enumerate specific audio/subtitle `AVMediaSelection`s to bundle. |

Common scaffolding regardless of variant:
- Create the session once: `AVAssetDownloadURLSession(configuration: .background(withIdentifier:), assetDownloadDelegate:, delegateQueue:)`. **The configuration must be a background configuration** — `AVAssetDownloadURLSession` rejects non-background configs.
- Delegate: `AVAssetDownloadDelegate` —
  - `urlSession(_:assetDownloadTask:didFinishDownloadingTo:)` gives the **local file URL** (a `.movpkg` bundle). **Persist a security-scoped bookmark to that URL**, not the path — the container-relative location is what survives, but the absolute path can change across app updates.
  - `urlSession(_:assetDownloadTask:didLoad:totalTimeRangesLoaded:timeRangeExpectedToLoad:)` → progress.
  - `urlSession(_:task:didCompleteWithError:)` → completion/failure.
- Play offline by constructing `AVURLAsset(url: <.movpkg URL>)` → `AVPlayerItem` → `AVPlayer`. Offline playback works **without network** only if the asset is a fully-downloaded VOD package.

### 1.2 The hard requirement that breaks the naive approach

`AVAssetDownloadTask` **only downloads VOD HLS**. Confirmed by Apple staff on the dev
forums: *"AVAssetDownloadTask is indeed only for VODs. Apple does not have a download API
for LIVE streams."* Concretely the media playlist must:
- carry `#EXT-X-PLAYLIST-TYPE:VOD`, **and**
- be terminated by `#EXT-X-ENDLIST` (a finite, fully-enumerated segment list).

If the playlist is `EVENT` / live-style (no `ENDLIST`, segments appended over time), the
download task throws / never completes.

### 1.3 Why Plex's on-the-fly `start.m3u8` is the wrong input

Plex's **Universal Transcoder** (`/video/:/transcode/universal/start.m3u8`, see
`01-plex-api-transcoding.md` §3) produces a **session-scoped, on-the-fly** stream:
- segments are transcoded lazily as the client requests them (1–8 s `.ts` pieces),
- the session requires **keep-alive pings** and is torn down when you `stop` or when it
  times out,
- the playlist behaves like a session/EVENT playlist, not a self-contained VOD with a
  guaranteed `#EXT-X-ENDLIST` up front.

Handing that URL to `AVAssetDownloadTask` is **[risk] — not reliable**: at best the task
fights the keep-alive/session model; at worst AVFoundation treats it as non-VOD and
refuses or stalls. This is the central trap of the whole feature.

### 1.4 The four candidate strategies

**(a) Force a complete VOD transcode playlist, then `AVAssetDownloadTask`.**
You would need Plex to emit a finite `#EXT-X-PLAYLIST-TYPE:VOD` + `#EXT-X-ENDLIST`
playlist at a capped bitrate. The Universal Transcoder doesn't give you that contract on
demand, and `protocol=hls&maxVideoBitrate=8000` still yields a session stream. **[risk]**
There is no documented Plex parameter that guarantees a VOD-typed, fully-enumerated
playlist from the universal transcoder. **Not recommended as primary.**

**(b) Download the original `Part.key` file.**
`GET <Part.key>?download=1&X-Plex-Token=…` with a plain **`URLSession` background
download task** + HTTP range requests. Dead simple, official, no Plex Pass. **But it
defeats the requirement** — it's the 80 GB original, not an 8 Mbps copy. Good *fallback*
when the source is already small / direct-playable.

**(c) Media Optimizer or official Mobile Sync (server-side conversion to a finished file).**
Do not conflate these. **Media Optimizer** pre-converts the title into a complete MP4 version on the server, including the built-in **"Optimized for TV – 8 Mbps 1080p"** preset, and the app then pulls the resulting `Part` as a normal file download. Plex's support docs list a server-version requirement for Optimizer, not a Plex Pass requirement. **Official Downloads/Mobile Sync** is the polished Plex product: the client advertises `X-Plex-Provides: sync-target` + `X-Plex-Sync-Version: 2`, creates a `SyncItem` with `MediaSettings`, pulls the converted media, and marks it downloaded; that protocol is Plex-Pass-gated and more surface to implement. Both produce the Apple-side result we want: a finished file fetched with plain `URLSession`, not `AVAssetDownloadTask`.

**(d) Roll your own segment downloader.**
Mimic the kmark "Universal Transcoder Downloader": request `start.m3u8`, pull each `.ts`
sequentially with `URLSession`, ping to keep the session alive, `stop` at the end, and
concatenate/remux to a local file (e.g. via `AVAssetExportSession` /
`AVAssetWriter` if you need an `.mp4`, or just keep the `.ts` concat). Gives you the
capped bitrate without Plex Pass, but it's **[risk] community pattern**: you own retry,
session expiry, ordering, and remux correctness; AVFoundation gives you none of its
download machinery.

### 1.5 RECOMMENDATION

**Primary: strategy (c) Media Optimizer** — it is the best path that yields a real bitrate-capped offline copy through a *finished file* without relying on Plex's official Downloads/Sync entitlement, so the Apple side collapses to a boring, robust **`URLSession` background download
task** (`URLSessionConfiguration.background(withIdentifier:)`,
`sessionSendsLaunchEvents = true`, `urlSessionDidFinishEvents(forBackgroundURLSession:)`),
not the fragile `AVAssetDownloadTask`-against-live-playlist path.

**If Media Optimizer is not acceptable** because the user does not want persistent optimized copies on the server, use strategy (d) self-rolled segment download of a capped-bitrate universal-transcode session, remuxed locally. Accept the maintenance cost. If the user explicitly wants official Plex Downloads/Sync and has Plex Pass, implement that later as a separate sync engine.

**Do NOT** point `AVAssetDownloadTask` / `AVAssetDownloadConfiguration` at Plex's
`start.m3u8` and expect it to work — its VOD-only requirement collides with Plex's
session/live-style transcode playlist. Reserve `AVAssetDownloadTask` for the case where
you genuinely have a static, VOD-typed HLS playlist (you generally won't, from the
universal transcoder).

**Fallback for already-small/direct-play titles: strategy (b)** original-file download —
trivial and official.

FairPlay note: a personal self-hosted Plex server is **not** FairPlay-encrypted, so the
`AVContentKeySession` / `AVAssetResourceLoaderDelegate` offline-key dance is **not
required**. (It would be, for commercial DRM HLS.)

---

## 2. FEATURE → API MAP

| Feature | Apple API (precise symbols) | Notes |
|---|---|---|
| Auth-token storage | **Keychain Services** — `SecItemAdd` / `SecItemCopyMatching` / `SecItemUpdate` with `kSecClass: kSecClassGenericPassword`, `kSecAttrAccessibleAfterFirstUnlock` (so background download tasks can read it while locked). | Store the Plex `X-Plex-Token`. |
| Networking | **`URLSession`** with `async`/`await` (`data(for:)`, `bytes(for:)`), `URLRequest`, `URLComponents`/`URLQueryItem` to build the transcode query string. | Use a shared session; a separate **background** session for downloads. |
| Image loading (posters) | SwiftUI **`AsyncImage`** for simple cases; **Nuke** (`LazyImage`, `ImagePipeline`) **[3rd party]** for disk-cache + prefetch in grids. | Plex `…/photo/:/transcode` thumb URLs. |
| Library browse UI | SwiftUI **`LazyVGrid`** / `LazyVStack` in `ScrollView`, **`NavigationStack`** + `navigationDestination`, `Grid` for fixed layouts. | visionOS hover/ornaments come free. |
| Video playback | **`AVPlayer`**, **`AVPlayerItem`**, **`AVURLAsset`**, surfaced via **`AVPlayerViewController`** (already established). | Offline item = `AVURLAsset(url: localURL)`. |
| Theater / environment | **`AVExperienceController`**, SwiftUI **`.immersiveEnvironmentPicker`**, system **Cinema Environments**; custom env via **RealityKit** (`ImmersiveSpace`, `Entity`, `ImageBasedLightComponent`). | Already established. |
| Subtitle / audio track selection | **`AVMediaSelectionGroup`** + **`AVMediaSelectionOption`**; read via `asset.loadMediaSelectionGroup(for: .audible / .legible)`, apply with `playerItem.select(_:in:)`; characteristics via `AVMediaCharacteristic`. | For offline, bundle desired options at download time (`AVAssetDownloadConfiguration.auxiliaryContentConfigurations` or `AVAggregateAssetDownloadTask`). |
| Background downloads | **`URLSession`** with `URLSessionConfiguration.background(withIdentifier:)`, `sessionSendsLaunchEvents = true`, `isDiscretionary` as desired; relaunch via `urlSessionDidFinishEvents(forBackgroundURLSession:)` + the app-delegate `handleEventsForBackgroundURLSession` completion handler. For HLS specifically: **`AVAssetDownloadURLSession`** (which *is* a background session under the hood). | Plex sync-file fetch uses the plain background `URLSession`. |
| Offline file storage | **`FileManager`** → `url(for: .applicationSupportDirectory, …)` (or `.cachesDirectory` if evictable is OK); set **`URLFileProtection`** / `.completeUntilFirstUserAuthentication` via `FileProtectionType`; persist locations as **security-scoped bookmarks** (`url.bookmarkData()` / `URL(resolvingBookmarkData:)`). Mark large files **`isExcludedFromBackup`** (`URLResourceValues`). | `.movpkg` bundles from `AVAssetDownloadTask` must be referenced by bookmark, never reconstructed path. |
| Resume / progress reporting | Local position via **`AVPlayer.addPeriodicTimeObserver(forInterval:queue:using:)`** (and `addBoundaryTimeObserver`); report back to Plex via `/:/timeline` / `/:/progress`. Current official Redoc labels timeline as POST, while reference clients use legacy-compatible GET query calls; live-test and encapsulate the method choice. Observe `AVPlayerItem.status` / `timeControlStatus` with KVO or `AVPlayerItem` notifications (`.AVPlayerItemDidPlayToEndTime`). | Throttle timeline reports (~every 10 s + on pause/seek/stop). |

---

## 3. visionOS-26-SPECIFIC CONSTRAINTS

- **Headset-off halts transfers.** On Vision Pro, removing the headset suspends the
  session; background `URLSession`/`AVAssetDownloadURLSession` transfers do **not** make
  meaningful progress while the device is off the user's head (no "download overnight on
  the charger with the headset on the desk" the way an iPhone downloads in your pocket).
  Design the UX around: download *while worn*, surface progress, and resume on next wear.
  `isDiscretionary = false` and `sessionSendsLaunchEvents = true` help the session resume
  promptly, but cannot override the off-head suspension.
- **Storage.** Vision Pro is fixed-capacity (no SD expansion); an 8 Mbps × 2 hr title is
  ~7 GB, so capped-bitrate copies are the right call. Use `.applicationSupportDirectory`,
  exclude from iCloud backup, and consider `AVAssetDownloadStorageManagementPolicy`
  (`.allowed` priority) so the system can evict under pressure if you store in a managed
  location. Query free space via `URLResourceValues.volumeAvailableCapacityForImportantUsage`.
- **Background execution.** Same background-session model as iOS, but expect longer wall
  times because of the off-head gating. Don't rely on `BGProcessingTask` for the actual
  byte transfer — drive it through the background `URLSession`, which the system relaunches
  you to finish.

---

## 4. 3D SBS RENDERING PATH (names only — covered elsewhere)

For per-eye / side-by-side → stereo on visionOS:
- **`AVPlayerItemVideoOutput`** (`copyPixelBuffer(forItemTime:itemTimeForDisplay:)`) to pull
  decoded frames, **or** native MV-HEVC via `AVPlayer` + `VideoPlayerComponent`.
- **RealityKit** **`TextureResource.DrawableQueue`** (a.k.a. `LowLevelTexture` on 26) to
  push the frame into a texture each vsync.
- **`ShaderGraphMaterial`** with the **Camera Index Switch (RealityKit)** node to emit a
  different region/texture per eye in the stereoscopic render (the SBS split happens in
  the shader by selecting left/right halves of the source texture per `cameraIndex`).
- MV-HEVC encode/segmentation references: WWDC25 immersive-video sessions.

---

## 5. SOURCES

- [AVAssetDownloadConfiguration — Apple Developer Documentation](https://developer.apple.com/documentation/avfoundation/avassetdownloadconfiguration)
- [makeAssetDownloadTask(downloadConfiguration:) — Apple](https://developer.apple.com/documentation/avfoundation/avassetdownloadurlsession/makeassetdownloadtask(downloadconfiguration:))
- [AVAssetDownloadTask — Apple](https://developer.apple.com/documentation/avfoundation/avassetdownloadtask)
- [Apple Developer Forums — "Can I download HLS Live stream" (VOD-only confirmation)](https://developer.apple.com/forums/thread/670986)
- [WWDC20 — Discover how to download and play HLS offline](https://developer.apple.com/videos/play/wwdc2020/10655/)
- [Plex Universal Transcoder Downloader (kmark gist — start.m3u8, segments, ping/stop)](https://gist.github.com/kmark/6028758)
- [Plex Downloads Overview](https://support.plex.tv/articles/downloads-overview/)
- [Plex Media Optimizer Overview](https://support.plex.tv/articles/214079318-media-optimizer-overview/)
- [python-plexapi sync module (Mobile Sync / sync-target)](https://python-plexapi.readthedocs.io/en/latest/modules/sync.html)
- [Camera Index Switch (RealityKit) — Apple ShaderGraph docs](https://developer.apple.com/documentation/ShaderGraph/realitykit/Camera-Index-Switch-(RealityKit))
- [What's new in RealityKit — WWDC25](https://developer.apple.com/videos/play/wwdc2025/287/)
- [URLSession background download pitfalls (SwiftLee)](https://www.avanderlee.com/swift/urlsession-common-pitfalls-with-background-download-upload-tasks/)
- Cross-ref: `research/01-plex-api-transcoding.md` (Plex endpoint mechanics, sync vs. download).
