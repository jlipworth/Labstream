# Development notes

Durable, easy-to-forget facts about building and working on this app. Task/bug tracking lives in
[GitHub Issues](https://github.com/jlipworth/VisionPlay/issues); see the [README](https://github.com/jlipworth/VisionPlay/blob/main/README.md)
for the basic build/run.

## Build, test, run

```sh
# Build (visionOS 26.x simulator, unsigned)
SIMID=$(scripts/worktree-sim.sh id)
xcrun simctl boot "$SIMID" 2>/dev/null || true
scripts/xcodebuild-versioned.sh -project VisionPlay.xcodeproj -scheme VisionPlay \
  -destination "platform=visionOS Simulator,id=$SIMID" \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO

# PMSKit unit tests
(cd PMSKit && swift test)

# Repo hygiene (redaction/signing guardrails)
./scripts/ci-hygiene.sh

# Install + launch on this worktree's simulator
scripts/worktree-sim.sh setup
SIMID=$(scripts/worktree-sim.sh id)
xcrun simctl boot "$SIMID" 2>/dev/null || true
APP="$HOME/Library/Developer/Xcode/DerivedData/VisionPlay-<hash>/Build/Products/Debug-xrsimulator/VisionPlay.app"
xcrun simctl install "$SIMID" "$APP" && xcrun simctl launch "$SIMID" com.jlipworth.VisionPlay

# After-the-fact logs
xcrun simctl spawn "$SIMID" log show --last 5m --predicate 'process == "VisionPlay"' --style compact
```

- App bundle id: `com.jlipworth.VisionPlay` · project deployment target: visionOS 26.0 · normal local sim runtime: the installed Apple Vision Pro visionOS 26.x runtime. Use `scripts/worktree-sim.sh id` and target `"$SIMID"`, not `booted`, because multiple worktree simulators can be running.
- Docs map: [`ARCHITECTURE.md`](ARCHITECTURE.md), [`PLAYBACK-ARCHITECTURE.md`](PLAYBACK-ARCHITECTURE.md), [`BACKENDS.md`](BACKENDS.md), [`DOWNLOADS-OFFLINE.md`](DOWNLOADS-OFFLINE.md), [`PERSISTENCE.md`](PERSISTENCE.md), [`DIAGNOSTICS-PRIVACY.md`](DIAGNOSTICS-PRIVACY.md), [`SYSTEM-INTEGRATION.md`](SYSTEM-INTEGRATION.md), and [`TESTING-STRATEGY.md`](TESTING-STRATEGY.md). Active-but-not-implemented research lives under [`research/`](https://github.com/jlipworth/VisionPlay/blob/main/docs/research/); historical research lives under [`archive/research/`](https://github.com/jlipworth/VisionPlay/blob/main/docs/archive/research/).
- Profiling workflow: see [`docs/PROFILING.md`](PROFILING.md) for Instruments baseline targets, simulator/device caveats, and finding templates.
- New Swift files are auto-included (Xcode file-system-synchronized groups + SPM
  `PMSKit/Sources`, `PMSKit/Tests`) — no `project.pbxproj` edits needed.

## Personal-device signing

Simulator builds stay unsigned. For Apple Vision Pro sideload installs, prefer `scripts/deploy-to-device.sh` (or `--launch` / `--no-build`) so device signing stays consistent. Keep the Apple Developer
Team ID local and out of git by creating `Signing.local.xcconfig`. The bundle ID and signing style
are committed project settings; the local file should contain only:

```xcconfig
DEVELOPMENT_TEAM = YOUR_TEAM_ID
```

Do not commit:

- `Signing.local.xcconfig` or other personal signing overrides
- provisioning profiles, certificates, or exported archives
- Plex tokens, client secrets, real server hostnames, or LAN IPs

Developer Mode and the first-launch trust prompt on device are Apple's normal security gate for
personal development builds. App Store/TestFlight distribution signing, entitlement cleanup, store
metadata, and review-specific release automation can be handled in a later publication pass.

## Docs site

Public docs are built with MkDocs and should stay strict-clean:

```sh
uv run --with-requirements requirements.txt mkdocs build --strict
```

CI installs `requirements.txt` and runs `mkdocs build --strict` before deploying the site from `.woodpecker/docs.yml`. Use root-relative GitHub links for files outside `docs/` because the published site only includes the MkDocs document tree.

## Gotchas we don't want to re-learn

- **CRITICAL — do not revert:** `TranscodeRequest` sends `X-Plex-Client-Profile-Name="Generic"`
  (plus an explicit `X-Plex-Client-Profile-Extra`). Safari was tried and regressed high-bitrate 4K
  HEVC — it hard-limits 10-bit HEVC and forced ~20 Mbps video transcodes on 4K MKV titles even on
  Direct Play / Maximum — so `Generic` is the proven-correct value. An unknown or missing profile
  name (e.g. "visionOS") makes PMS return a bare **HTTP 400** and playback breaks, so the name must
  always resolve to a real built-in profile. The bitrate cap is enforced by `maxVideoBitrate`.
- **To test AVFoundation playback behavior on the simulator, run it INSIDE the app process — a
  bare `simctl spawn` binary cannot host `AVPlayer`.** A standalone Swift binary compiled for
  `xrsimulator` and run via `xcrun simctl spawn <sim> ./probe file.mp4` will load the asset
  (`AVURLAsset.load(.isPlayable)`/`.duration` succeed) but the `AVPlayerItem` never reaches
  `.readyToPlay` — it lacks the render/playback environment — so *every* file falsely reports
  `timeout_not_ready`, making good and bad files indistinguishable. Instead add a `#if DEBUG`,
  launch-argument-gated probe (mirror `DebugPlexDownloadProbe`/`DebugJellyfinPlaybackProbe`), drop
  the test files into the app's Documents container
  (`xcrun simctl get_app_container <sim> com.jlipworth.VisionPlay data`), launch with the arg, and
  read results from the log. This was how GH #98's post-download playability probe was reproduced:
  a fragmented MP4 (`empty_moov+delay_moov+mfra`, up to 1.9 GB / 120 fragments) plays fine in-app,
  confirming the probe failure is an intermittent timing false-negative, not an fMP4/container issue.
- **RealityView attachments DO render in the full `.ultraDark` Cinema immersive space — the
  "attachments don't appear reliably" belief was a scale bug, not a platform limitation.** An
  attachment is NOT authored at 1 pt = 1 m: RealityKit renders the SwiftUI view into a mesh at a
  system density (~1360 pt/m), so a 1920-pt-wide attachment is already ~1.4 m wide at scale 1.0.
  Scaling it by `widthMeters / widthPoints` (the original Cinema code — and still the hidden #12
  prototype's `RealityTheaterEntityFactory.placePlayerSurface`, `width / 1280`) is therefore ~1360×
  too small and collapses the whole screen to a few millimeters: present and hit-testable, but
  invisible at cinema distance. The symptom is **audio plays, pure black, no controls even on tap**
  (the tap target is a sub-millimeter speck). Fix: never hard-code the density — measure the
  attachment's intrinsic size and scale THAT to the target meters:
  `entity.scale = .init(repeating: targetWidthMeters / entity.visualBounds(relativeTo: entity).extents.x)`.
  `relativeTo: entity` excludes the entity's own scale, so it's stable to call repeatedly; re-run
  placement from a timer/`update` until `visualBounds` is non-zero (the attachment lays out a frame
  or two after it's added to `content`). Co-locating the video (`AVPlayerLayer` via `PlayerLayerView`)
  and the real `CustomPlayerChrome` in ONE attachment gives full windowed-player parity for free —
  same scrubber, trick-play, and Quality/Subtitles/Audio/Speed/Chapters/Stats menus.
- **Cinema is app-owned, not AVKit system expanded playback.** The shipping video path is the
  custom `AVPlayerLayer` player. Its Cinema button opens `CustomCinemaMode.immersiveSpaceID`,
  hosts the same `PlayerLayerView` + `CustomPlayerChrome` in one `RealityView` attachment, then
  dismisses/reopens the main window around that immersive session. Do not reintroduce AVKit
  `AVPlayerViewController` or system expanded-player assumptions when working on this path.
- **Cinema exit is routed, not restored as a hidden player.** The immersive session owns playback.
  On Exit/Crown/EOF/Up Next it stops the active controller, reopens the main browse window only
  while the scene is active, and posts a `SystemEntryRouter` route back to the current or next item.
  This avoids duplicate hidden audio and avoids re-running sign-in/server discovery because the
  long-lived app objects are owned by `VisionPlay.App`, not by the main window view.
- **ⓘ Info card year:** the card shows a year after the runtime, sourced from the stream's
  creation date — for a live transcode that's *today's* year (seen as "2026" on a 2013 film).
  Override: `externalMetadata` item `.commonIdentifierCreationDate` with an **NSDate-typed
  value** (Jan 1 of the release year) — verified working. STRING values are ignored under that
  identifier and every other plausible one (`quickTimeMetadataCreationDate`,
  `id3MetadataRecordingTime`, `iTunesMetadataReleaseDate`) — all proven live. Title
  (`.commonIdentifierTitle`) and description (`.commonIdentifierDescription`) work as strings;
  cap the description ~150 chars or it pushes the title off the card.
- **Cinema menus are SwiftUI chrome.** Quality/Subtitles/Audio/Chapters/Speed/Stats live in
  `CustomPlayerChrome` and render inside the same RealityView attachment as the video. Do not add
  new playback controls through retired AVKit surfaces; those notes now belong only to archived
  research.
- **Play-vs-metadata race:** listing payloads omit chapters/markers; `DetailView` backfills
  them asynchronously and tapping Play can win that race (seen live as a missing Chapters
  tab). The player no longer depends on the caller's copy — `loadChaptersIfNeeded()` fetches
  full metadata and the control surface re-installs the tab strip when chapters arrive.
- **Exit Cinema is explicit app chrome.** The visible Exit control lives in `CustomPlayerChrome`
  inside the immersive attachment. It dismisses the immersive space; `CustomCinemaScaffoldView`
  then stops the controller, reopens the main window when active, and routes back to content.
- **Never put a CUSTOM `ButtonStyle` on a poster/card link — use `.cardLink()`
  (built-in `.plain`).** On visionOS, ANY custom `ButtonStyle` gets the link's
  gaze/hover hit region REGISTERED DISPLACED — measured ≈1.35× scaled about the
  window center, so edge cards drift the most and clicks on rail card N open card
  N+1 (first reported as "the leftmost poster clicks the wrong item"; center cards
  worked, which hid the pattern). Proven by live bisection: structure changes
  (lazy→plain stacks, padding→`contentMargins`, dropping `scrollClipDisabled`/hover
  lift) changed nothing; removing the style fixed it; restoring it regressed it.
  NOT fixable inside the style: adding `contentShape(.hoverEffect, …)` +
  `hoverEffect(.highlight)` and/or removing the press `scaleEffect` still misroutes.
  Built-in styles (`.plain`, default) register through a correct path; `.cardLink()`
  wraps `.plain` + a `contentShape(.hoverEffect, …)` to shape its automatic
  highlight. Related: gaze hover is rendered OUT-OF-PROCESS — `.onHover` never
  fires for gaze, so the app cannot observe or debug hover; diagnose routing with
  `.simultaneousGesture(SpatialTapGesture(coordinateSpace: .global))` logging
  instead. (A second, simulator-only effect can stack on top: sweeping in from the
  left expands the leading TabView ornament, whose region can eat the first
  click — `MRUIFeedbackTypeCircularButtonTouchDown` in logs. Also still prefer
  `.contentMargins(..., for: .scrollContent)` over padding lazy rail content; it
  keeps insets out of card geometry.)
- **Transcode sessions must be stopped explicitly — including before same-session
  restarts.** HLS gives PMS no end-of-playback signal, so a closed/rebuilt player orphans
  a live FFmpeg job until the server's inactivity reaper runs (seen live: open-session
  pile-up on the PMS pod). Teardown fires `GET /video/:/transcode/universal/stop?session=`
  (`TranscodeRequest.stop`) from `PlaybackController.stop()`. We originally assumed
  same-session reloads didn't need it ("PMS replaces the job in place") — **disproven by
  the server OOM** (next bullet): under rapid re-requests the whack-and-replace loses
  races and jobs stack. Every intentional in-place restart (quality/audio reload, explicit Retry,
  final-target deep-seek rebuild) now AWAITS a stop (bounded to 2s) before requesting the new
  start.m3u8. Progressive downloads still just end with the HTTP connection.
- **A transcode restart is a server-side fork bomb if unthrottled** (#27,
  the archived Plex transcode OOM research notes). Each start.m3u8 for a non-direct-playable file
  forks a full software HEVC→H.264 encode (no HW decode in the pod); during starved
  scrubbing one session stacked 21 transcoder jobs in ~60s (8 within 1.1s) and OOM-killed
  the 8Gi pod — twice. Two independent drivers, both needed taming: (a) client-initiated
  restarts (stop-before-restart above + the budget below); (b) **PMS itself relocates
  ffmpeg** when AVPlayer requests a segment outside the produced window — AVPlayer fetches
  HLS segments autonomously during a scrub (seen: 536 404s, 140 concurrent GETs), so client
  restraint alone is insufficient; the fix for (b) is not seeking into far-unproduced
  territory on a session that can't keep up. Guard rails: `FinalTargetRebuildPolicy` +
  `SeekRestartBudget` (PMSKit, unit-tested spam scenarios) debounce noisy seek jumps to the
  final target, allow only one rebuild pipeline at a time, and enforce a rolling 5-per-60s burst
  limit. Past that, the player stops background recovery and surfaces the failure overlay;
  explicit user intent (Retry / quality/audio reload) resets the budget. Silent auto-retry has
  been removed so a failing PMS stream cannot become a hidden retry loop. Direct Stream (#7)
  shrinks the whole cost class: `video_decision=copy` makes a stacked job a ~50MB remux instead
  of a ~400MB encode.
- **PMS transcode is NOT just-in-time one-segment-at-a-time — it races AHEAD then
  throttles.** Earlier code comments assumed PMS produces segments at ~real-time and a deep
  client buffer is impossible; that is wrong. The universal transcoder runs flat-out (HW
  ~2-10x real-time; even our software HEVC→H.264 pod runs faster than playback) and builds a
  forward window, then PAUSES encoding once it is `TranscoderThrottleBuffer` seconds ahead of
  the playhead (PMS advanced-setting, default **60s**; "throttled" in logs is the GOOD state).
  It resumes as the player consumes those ranges, and prunes spent ones behind
  `TranscoderPruneBuffer` (default **300s**). So a 60s lead of real, already-encoded segments
  normally exists server-side. (Sources: Plex `TranscoderThrottleBuffer`/`TranscoderPruneBuffer`
  advanced settings; "If a transcode is throttled, is that bad?" support article; throttle-buffer
  forum thread — "tells the transcoder how far ahead of where you are to stay … recovers as the
  player consumes previously transcoded ranges".)
- **The forward-buffer ceiling is the CLIENT, not the server.** Given the ~60s server lead,
  the binding limit is AVPlayer: on HLS it caps the realized forward buffer at roughly
  **2-3 min (~100s)** and may buffer LESS to manage resources, and it largely ignores
  `preferredForwardBufferDuration` UNLESS `automaticallyWaitsToMinimizeStalling = false`
  (Apple dev-forum thread 63435; `AVPlayerItem.h`). PMS does not gate/withhold already-produced
  segments inside the window — the player can pull the whole produced lead immediately. Practical
  implication: raising `preferredForwardBufferDuration` past ~the server's throttle lead buys
  nothing on a live transcode (segments past the lead don't exist yet); the lever that matters is
  the server-side throttle buffer, which we don't control. Direct Stream (`video_decision=copy`)
  is far cheaper per segment so the lead fills/refills faster (the throttle target is in seconds,
  not work, so the *depth* is the same — but it recovers from a blip quicker).
- **Seeking PAST the produced window relocates ffmpeg — this is the (b) fork-bomb driver.**
  When the player requests a segment outside the produced/throttled window, PMS re-spawns the
  encoder at that offset (`-ss <offset>`) rather than fast-forwarding the existing job. Seen live
  in the OOM trace: one session's `Asked for segment 2267…2403` paired with transcode starts at
  `-ss` 1501/1560/1650/1765/1071/1820/1841/1741 — i.e. AVPlayer's autonomous segment fetches
  during a scrub each triggered a fresh encode. Hence: do not seek into far-unproduced territory on
  a session that can't keep up (see `SeekRestartBudget`), and a deeper client buffer does NOT help
  here — it cannot pre-fetch segments the server hasn't produced.
- **PMS HLS is a FULL-TIMELINE playlist with ABSOLUTE-TIME segment URIs and ABSOLUTE PTS, but
  VisionPlay no longer relies on no-reload segment splicing.** The universal-transcoder media
  playlist lists EVERY segment from t=0 to the end (e.g. **10548 one-second segments** for a ~2.9h
  film; master is a tiny one-variant `#EXT-X-STREAM-INF`), each named **`0NNNNN.ts` where NNNNN is
  the absolute second offset** — `02600.ts` is t=2600s in *every* session regardless of prime
  offset. A session primed at offset X serves real MPEG-TS only from X forward (within the ~60s
  throttle window); every segment before X is a **188-byte PAT-only stub** (the deep-seek stall).
  Earlier Stage-3 work proved segment PTS is absolute, but manual double-drag testing showed the
  proxy-owned no-reload splice design can still drive AVKit/local HTTP retry storms and PMS
  pressure. That design is removed from the app path. Deep out-of-buffer seeks now use a visible,
  bounded final-target player-item rebuild: one stop/decision/start at the settled target, or a
  surfaced failure overlay.
- **HLS network loss is a stall, not a failure** — `timeControlStatus == .waitingToPlayAtSpecifiedRate`
  with an empty buffer; `AVPlayerItem.status` never flips to `.failed`. Hence the 15s stall watchdog.
- **Wedge recovery requires a brand-new view controller** — an in-place `retry()` (item swap)
  inherits the wedged control layer + dimmed cinema room. Rebuilding via a SwiftUI `.id()` bump is
  the only thing that clears both, resuming at the captured live playhead.
- **Install source matters for app state.** A same-bundle-id simulator/device upgrade install usually
  preserves the app container. Deleting the app, erasing the simulator, or replacing the App Store
  build with a development build starts with fresh app state and requires sign-in again. The token
  persists across plain relaunches via a file fallback in `KeychainStore` (the unsigned-sim keychain
  fails with `errSecMissingEntitlement -34018`).
- **Primary-window plus Cinema constraint:** normal browsing/playback uses one main `WindowGroup`
  and the player presents as a `.fullScreenCover`. Cinema is the exception: it uses an
  `ImmersiveSpace` and may reopen the main window on exit. Do not add unrelated secondary windows.
- **Server:** configured per-user at sign-in (a Cloudflare-fronted PMS over `:443`). The real
  hostname/LAN IP are intentionally kept out of the repo.
- **Emby `Stopped` is NOT encoder cleanup.** `POST /Sessions/Playing/Stopped` reports session/progress
  state only; it does not terminate a server-side encoder. Any Emby source that used server-side encoding
  (the transcode/HLS path — `EmbyPlaybackOpenResult.usesServerEncoding == true`) MUST also be torn down with
  `DELETE /Videos/ActiveEncodings?DeviceId=&PlaySessionId=` (`EmbyBrowseService.stopActiveEncoding`). Same
  failure class as the Plex stacked-FFmpeg/OOM problem — do not collapse the two calls.
- **Jellyfin/Emby video progress is its own reporting lane.** Resolved remote-stream playback is not a
  Plex timeline session, but it still must emit MediaBrowser `Sessions/Playing`, `Sessions/Playing/Progress`,
  and `Sessions/Playing/Stopped` requests with the current `PlaySessionId`, `MediaSourceId`, play method, and
  absolute position ticks. This is separate from the local HLS proxy and from active-encoding cleanup; a stream
  reopen that mints a new play session must update this progress context too.
- **Emby tokens leak through URLs, not just headers — redact `api_key`.** The Emby auth token rides three
  ways: the `Authorization: Emby … Token="…"` header, the `X-Emby-Token` header, AND the server-generated
  HLS/direct-stream URL as an `api_key=` query value. That last one is why diagnostics/log output must scrub
  `api_key=` (and `X-Emby-Token`) — a logged stream URL otherwise prints the live token. The repo is going
  public; `LiveEmbyProbe`/`live-emby-probe.sh` already redact token, `api_key`, and the live scheme/host, and
  the same discipline applies anywhere an Emby URL or header set is logged. (Per the general rule, also never
  `NSLog` a raw `%`.)
- **Emby is its own auth scheme — `Emby `, not `MediaBrowser `.** `EmbyAuth.authorizationHeader` emits
  `Authorization: Emby UserId="…", Client, Device, DeviceId, Version, Token="…"` and authenticated calls also
  set `X-Emby-Token`. Do not reuse Jellyfin's `MediaBrowser` builder. (The live server happens to accept the
  `MediaBrowser` header too, but the current shared MediaBrowser helpers still keep the auth scheme
  explicit and the Emby lane sends the canonical `Emby` scheme.) Two more Emby divergences from Jellyfin that bite silently:
  PlaybackInfo needs `UserId` in BOTH the query and the body and uses `AutoOpenLiveStream:false`; and the
  user-entered base path (e.g. `/emby`) must be PRESERVED, because PlaybackInfo returns relative stream URLs
  joined back onto `server.path`.
- **No volume control in the MiniPlayerBar (deliberate, MUSIC-DESIGN scope fence):** visionOS
  Digital Crown + system volume own loudness; an AVPlayer-level slider would diverge from the
  system volume. The bar's 3-pt progress hairline is likewise **passive** — a 3-pt drag target
  violates the 60-pt gaze rule; scrubbing lives in the Now Playing sheet (a hover-growing thin
  scrubber is a possible v2 trial).
- **Emby "existing versions" / Convert Media (#126), verified live against Emby 4.9.3:** Emby's
  parity for Plex's pre-rendered "Version" download (#112) is **Convert Media** — a *Sync job* to
  the target `originalmediafolder` ("Original media folder, next to original files"). It adds the
  converted copy as a **second `File` MediaSource on the same item** with its own distinct
  `Id` (e.g. `mediasource_<n>`), enumerated by `PlaybackInfo` alongside the original. Hard-won
  facts that gate the implementation:
  - **PlaybackInfo FILTERS by `MediaSourceId`.** Supply an id (query or body) → the response
    contains ONLY that source; omit it → ALL sources. So existing-version enumeration MUST use a
    dedicated PlaybackInfo call with NO `MediaSourceId` — the normal probe (which passes one, since
    the Emby `Media.part.key` is `emby://item/{id}/media/{sourceId}` and `selectedMediaSourceID`
    extracts it) can never see the alternates.
  - The converted source reports `Protocol:File`, `SupportsDirectPlay:true`, real `Size`, and is
    byte-for-byte downloadable via `/Videos/{itemId}/stream.{ext}?static=true&MediaSourceId=…`
    (HTTP 206, total == `Size`, no remux) — exactly `EmbyLibrary.downloadOriginalRequest`. The
    download lane reuses the existing `.original` Emby path via `downloadEmby(mediaSourceIDOverride:)`.
  - `originalmediafolderreplace` is the DESTRUCTIVE convert target (replaces the original) — never
    use it. The device-target sync jobs (iPad/iPhone/Android) are a different feature.
  - Jellyfin core has no persistent server-side conversion, so this lane is Emby-only.
- **Emby convert-then-download (creating the Convert Media job on demand), verified live against
  Emby 4.9.3.** The default lane for a non-direct-play Emby download triggers the Sync job itself
  (`triggerConvertAndDownload`), then polls it to completion and downloads the rendered file via the
  resumable `.original` lane. Three facts bite:
  - **`POST /Sync/Jobs` returns a `SyncJobCreationResult` envelope, NOT a bare job.** The created job
    is nested under `"Job"`: `{ "Job": { "Id", "Status", "Progress", … }, "JobItems": [] }`. Decode it
    with `EmbyConvertRequest.decodeCreatedJob` (unwraps `"Job"`). The single-job poll
    `GET /Sync/Jobs/{id}` is different — it returns the job at the TOP level (`"Id"` present), decoded
    by `decodeJob`. Decoding the create response as a bare job throws `keyNotFound("Id")` (this was a
    shipped crash: "Download failed: DecodingError.keyNotFound Key 'Id'").
  - **Emby IGNORES the submitted job `name`** and stores the item's own title instead (a
    `"<title> [VisionPlay <hex>]"` submission comes back stored as just `"<title>"`). So unlike Plex's
    `[VisionPlay …]` queue-title marker discipline, an Emby convert job CANNOT be tagged/identified by
    name — it is identified and cancelled solely by the **persisted `embyConvertJobID`** (a row delete
    fires `DELETE /Sync/Jobs/{id}`). NOTE: a create whose response decode fails leaves the job orphaned
    server-side (the id is never persisted, so nothing can cancel it) — another reason the decode above
    must be correct.
  - **Emby does NOT report transcode progress.** The Sync job's `Progress` stays pinned at `0`
    throughout `Converting` (the job record's `DateLastModified` never advances mid-convert) and only
    jumps to `100` at completion; `JobItems` carry no progress field at all. So there is no incremental
    signal to surface — unlike Plex optimize, which reports a real moving %. The UI must therefore show
    an indeterminate "Preparing on server…" for `.preparing` rows (never "0%", which is misleading);
    `OfflineLibraryView` suppresses the percentage when the polled value is ≤ 0.
  - **The `tv` profile scales output resolution to the chosen bitrate, capped at 1080p.** Live-verified
    on a 3840×2160 HEVC source: `profile:"tv"` @ 20 Mbps → 1920×1080, @ 4 Mbps → 1280×720. So the
    picker's resolution tiers are REAL (720p preset → 720p, 480p → 480p); only the top "4K 40 Mbps"
    tier is clamped down to 1080p (the profile ceiling — true 4K needs `profile:"custom"`, tracked in
    #128). Consequence for the UI: a server-prepared download must be labelled by the CONVERTED
    source's height (carried on `EmbyDownloadPlaybackDecision.height`), not the item's primary 4K
    source — else a 720p convert reads "4K". A genuine `.original` download keeps its source label.
  - **A `POST /Sync/Jobs` has NO per-source selector — Emby picks which MediaSource of the item to
    convert.** This bites on REPEAT downloads: the kept converted file lands in the library folder as a
    `<title> - tv [(N)].mp4` sibling and Emby indexes it as a SECOND `File` source on the same item. A
    fresh convert job for that item can then transcode the DERIVED `- tv` source (a convert-of-a-
    convert), and a job whose derived input has since been removed fails in ffmpeg with `No such file or
    directory` → the Sync job goes `Failed` (surfaced client-side as "Server conversion failed").
    **Fix: never re-convert when a usable converted version already exists.** `triggerConvertAndDownload`
    runs a REUSE PREFLIGHT (`reusableConvertedSource`): enumerate the item's `File` sources and, if a
    non-primary h264-AND-mp4 source whose resolution tier matches the requested preset's capped-1080p
    output height (`convertPresetOutputHeight`) already exists, hand off to the resumable
    `.existingVersion` lane (#126) instead of creating a new job. This is what stops duplicate `- tv (N)`
    pile-up and keeps Emby from ever having a derived source to mis-convert.
  - **`profile:"custom"` is the true-4K path (#128), and the criteria that make it work are CODEC +
    CONTAINER — NOT a resolution field.** Reverse-engineered from the server's own web client
    (`/web/modules/sync/sync.js` `setJobValues`, zero-side-effect source read) and confirmed live
    (Emby 4.9.3, create→`Queued`→immediate `DELETE 204`, nothing transcoded): the "Convert → Custom"
    dialog sends exactly `Container` (`mkv`/`mp4`/`ts`), `VideoCodec` (`h264`/`hevc`), `AudioCodec`
    (`aac`/`mp3`/`ac3`) — all marked `required` — plus `Quality`/`Bitrate`. There is **no** resolution /
    MaxHeight / BitDepth / Framerate field anywhere in the dialog. `custom` preserves source 4K simply
    by lacking `tv`'s downscale-to-1080p rule; supplying the codec criteria is what creates work items.
    Verified shapes against the test 4K HEVC source (`originalmediafolder` target):
    - `profile:"custom"` + `container:"mp4"` + `videoCodec:"h264"` + `audioCodec:"aac"` → `ItemCount=1`
      (work item created). camelCase keys bind fine (PMSKit's existing convention — `videoCodec` etc.).
    - `profile:"custom"` WITHOUT the codec criteria → **HTTP 400** (rejected; the required fields are
      genuinely required).
    - `profile:"tv"` control → `ItemCount=1` (downscales, per the bullet above).
    So `convertQuality(forPresetLabel:)` routes the `4K …` and `Original …` presets through
    `profile:"custom"` + `mp4`/`h264`/`aac`; the 1080p/720p/480p presets keep `profile:"tv"` (those
    explicitly request a downscale the `tv` ceiling already gives). h264 is chosen over hevc for the
    target because the convert lane only ever runs for sources that CAN'T direct-play, so a universally
    playable codec is the safe pick. (Caveat per #128: 4K→4K H264 files are large and slow to transcode
    server-side — the picker preset IS the explicit user opt-in.)
- **#169 off-head downloads: the static byte-range lane must be a true background `downloadTask`, and
  resume-corruption protection on Plex CANNOT rely on `If-Range`.** visionOS suspends the app ~1–2 min
  after the headset comes off; only `nsurlsessiond`-managed background `URLSessionDownloadTask`/
  `uploadTask` transfers survive — a `dataTask` (the old in-process byte-append lane) does not, which is
  the whole of #169. A background task only hands back its temp file on *completion*, so it can't
  byte-append mid-flight. While the app is active, the lane therefore downloads bounded
  `Range: bytes=<off>-<off+N-1>` checkpoint chunks and appends each finished chunk into the durable
  partial (the checkpoint that survives force-quit/relaunch). When SwiftUI scene phase becomes
  `.inactive`/`.background`, future range starts switch to background-owned bounded checkpoint
  chunks: `nsurlsessiond` owns each transfer segment, and finished segments are appended into the
  durable partial periodically instead of leaving all remaining bytes in one long-lived temp file.
  If an in-flight background segment later fails, the retry/checkpoint is still the durable partial
  size from before that segment, not the optimistic bytes URLSession had only in its temp file.
  In-flight bytes reported by `didWriteData` may be shown as live progress, but they are **not
  durable checkpoint bytes**.
  Pause/error/reconcile paths must reset row bytes/progress from the actual partial-file size, not
  from optimistic row counters.
  Also do not fire the URLSession background completion handler until a finished chunk has been appended,
  finalized, or safely parked for manager rehydration; otherwise the OS may suspend the app after the temp
  stash move but before the durable checkpoint/next chunk is scheduled. If a relaunched task is adopted
  with no in-memory authenticated request (`request == nil`), `BackgroundDownloadSession` only parks the
  row and calls back for rehydration; `DownloadManager` owns rebuilding Plex/Jellyfin/Emby auth and defers
  retry until the matching backend session is restored. To stop a resource that *changes* mid-download
  from being spliced in after a stale prefix, each resume must be pinned to the resource version.
  #180/#181 follow-on invariants: shared finalization keeps the row `.downloading` at 100% and the UI says
  "Verifying download…" until `BackgroundDownloadSession.finalizeTransferredFile` writes a terminal status;
  URLSession background completion is held behind both range append/finalize work and opaque finalization
  status writes. Plex optimize/server-prep relaunch recovery is a separate lifecycle from the final static
  rendered-Part transfer: only rows still persisted as `.serverPrepThenStatic` may reattach Plex prep
  pollers, and those pollers must use the same persisted server identity rather than whichever Plex
  session is currently active.
  **Verified live (read-only, headers-only probe of all three real backends):**
  - **Plex IGNORES `If-Range`.** A `Range` GET with a deliberately non-matching `If-Range` (tried BOTH
    etag-form and date-form) returns **206 from the same offset**, not a whole-file 200 — deterministic
    over repeats — even though Plex emits a perfectly good **strong ETag** *and* `Last-Modified`. So
    sending `If-Range` alone is a no-op on the primary backend. The load-bearing defense is a per-chunk
    **validator-equality** check (compare the response ETag/Last-Modified against the one pinned on the
    first chunk; a definite mismatch ⇒ discard the stale partial and restart from offset 0). That restart
    MUST be bounded — an unstable validator (a PlexOptimize Part still being written; a load-balanced /
    proxied ETag) would otherwise livelock re-downloading from 0 forever, and `retryCounts` can't bound it
    (it's zeroed on every chunk's first progress in `didWriteData`).
  - **Emby HONORS `If-Range`** (strong ETag → 200 on a non-matching validator) and **Jellyfin HONORS the
    date form** (no ETag; `Last-Modified` only → 200 on a non-matching date). Both are protected by
    `If-Range` as shipped; the validator-equality check is belt-and-suspenders for them. Caveat:
    `Last-Modified` is 1-second-resolution, so a change within the same second as the original is
    undetectable (minor). Plex/Emby ETags are strong and Jellyfin emits none, so the weak-`W/`-ETag guard
    in `rangeValidator(from:)` is defensive-only — no real backend triggers it today.

## Conventions

- **Never commit** Plex tokens or client identifiers.
- Never `NSLog` a raw string containing `%` (format-string crash) — use `NSLog("%@", str)`.

## Stats for Nerds bitrate semantics

Stats for Nerds uses decimal network units throughout: AVFoundation bit/s values are divided by
`1000` to kbps and by another `1000` to Mbps. Do not mix these labels with KiB/MiB-style binary
file-size math.

- **Target** is the app-requested streaming cap. For capped HLS transcodes this is the selected
  rung in kbps. `Direct Play / Maximum` means no app cap, not a measured bitrate.
- **Source** is the backend media bitrate when available. Plex media rows expose kbps. Jellyfin
  `Bitrate` values arrive as bit/s and are normalized to kbps in `JellyfinPlaybackSourceMetadata`.
  These are usually whole-media/container rates, not necessarily video-only rates.
- **Observed** is AVFoundation `observedBitrate`: empirical transfer throughput while the player is
  actively downloading bytes. It is not encoded stream bitrate or sustained internet capacity. When
  access-log byte/transfer progress stops advancing because the buffer is full, the UI labels the
  value idle/stale instead of treating it as live bandwidth. Local HLS proxy playback hides Observed
  because it would measure localhost/proxy burst rate.
- **Indicated** is AVFoundation `indicatedBitrate`: the server-advertised throughput required for
  the selected variant, commonly the HLS `BANDWIDTH`/peak-style value.
- **Indicated avg** is AVFoundation `indicatedAverageBitrate` when the playlist advertises an
  average variant bitrate.
- **Avg video** is AVFoundation `averageVideoBitrate`, which may be video-only for unmuxed tracks or
  combined content for muxed streams. It is closer to encoded-content rate than Observed, but it is
  still whatever AVFoundation reports for the current access-log event.

Adaptive upshift logic may use Observed as an extra headroom check only while the access-log event is
actively advancing. Stale/idle Observed samples are treated as missing so a healthy full buffer does
not block an upshift or produce a false bandwidth warning.

## Plex HLS sessions are live-ish: paused pre-buffering and the buffer "staircase"

Verified live (2026-07-03, during #195 testing on a 62.7 Mbps Direct Stream over a ~10 Mbps
link):

- **Every Plex playback lane — Direct Play / Direct Stream included — is a `start.m3u8`
  transcode-session playlist**, and while the server session runs the playlist has no
  `EXT-X-ENDLIST`. AVPlayer therefore classifies it as live-ish and **stops loading entirely
  while paused** unless `AVPlayerItem.canUseNetworkResourcesForLiveStreamingWhilePaused` is
  set. `PlaybackBufferingPolicy` originally set that flag only for Jellyfin/Emby transcodes
  (`isRemoteTranscode`), so on Plex, pause-to-buffer loaded nothing and Stats showed Buffer
  ahead pinned at 0.0 s forever. Fixed by classifying the loaded URL itself
  (`PlaybackBufferingPolicy.isServerEncodedHLSPlaylist`): any `.m3u8` item gets the flag.
  Jellyfin/Emby direct play/stream are progressive `/Videos/{id}/stream.{container}` URLs —
  true VOD, unaffected.
- **Buffer ahead climbs as a staircase, not a ramp.** `loadedTimeRanges` only advances when a
  whole HLS segment completes, and a ~6 s segment of a 62.7 Mbps stream is ~40–47 MB — tens of
  seconds per segment on a slow link. Expect a long initial 0.0 s stretch, then +6 s jumps.
  This is inherent segment granularity, not a stall; the Observed row showing active
  throughput is the "it's actually downloading" tell.
- **A single-variant playlist cannot adapt.** Plex Direct Stream copies the video, so the
  session playlist has exactly one rendition; MediaToolbox logs "Try to switch down …
  currentAlternateBitrate 62723000/62723000/62723000" with nowhere to go. When the link is
  slower than the source bitrate, only a capped-quality transcode can play smoothly, and the
  app deliberately never converts an explicit "Direct Play / Maximum" choice into a capped
  transcode (see the stall-watchdog rationale in `PlaybackController`).

## Plex copy-lane startup deadlines: why Original quality "never loaded" (GH #196)

Root-caused live (2026-07-03) with a bare-AVPlayer raw-URL probe against a real PMS over
Cloudflare (~50–57 Mbps link, 62.7 Mbps 4K HEVC video-copy stream):

- **AVFoundation enforces hard per-media-file startup deadlines**: `-12889` "No response
  for media file in 10s" and `-16830` "Media file not received in 20s". On a miss it
  *removes the variant*. The Plex video-copy session playlist has exactly ONE variant
  (10 s / 67–80 MB fMP4 segments, `EXT-X-MAP` init header), so a miss is terminal:
  `-12880` "Can not proceed after removing variants". Playback dies permanently instead of
  buffering — this, not bandwidth or DV signalling, was the #196 "never loads".
- **The failure never flips `item.status`.** The item sits at `.unknown` with `rate=1`
  forever; the truth lands only in `AVPlayerItem.errorLog()`. Symptom in app logs is the
  looping MediaToolbox `err=-12174` at `AVAssetInspectorLoader`. The app's old surface was
  the misleading "capacity hint" from the stall watchdog. Multiple error-log entries can be
  appended before ONE `newErrorLogEntryNotification` posts (seen live: `-12880` + `-15628`
  in a single batch), so handlers must scan the log, not read `events.last`.
- **Cold sessions lose the race under server load.** PMS starts the session transcoder only
  when the *child* playlist is fetched, and session files 404 until written (idle server:
  header + seg0 at ~+3 s). `PlexHLSPrewarmer` therefore fetches master+child and polls the
  init header + first segment byte BEFORE attaching AVPlayer; a one-shot auto-retry on
  `-12880` (same session, transcoder NOT stopped — the failed attempt's segments are the
  retry's head start) is the backstop, and the MediaBrowser lanes reuse the backend
  reopener for the same one-shot.
- **`offset=` is actively harmful on the copy lane.** PMS emits
  `#EXT-X-START:TIME-OFFSET`; AVPlayer was observed decoding a single frame at the offset
  and then abandoning the sole variant. The copy lane now starts sessions at 0 and resumes
  via the client-side seek fallback — PMS jumps the session transcoder to whichever segment
  the player requests (proven live, both directions).
- **Never rebuild the copy-lane session for a seek.** Killing and immediately re-minting
  the same `session` id left the fresh session header-less for 20 s+ and then HTTP-400'd
  the restart; worse, the not-yet-detached old item's pending media request landed on the
  restarted session and yanked its transcoder to the stale playhead (fixed by detaching the
  item whenever its transcode session is stopped). Out-of-buffer seeks on the copy lane are
  now NATIVE (`RemoteSeekModePolicy.plexStreamingCopyHLS`): the session playlist is full
  VOD, so AVPlayer just requests the target segment and PMS jumps. Deep seeks still
  re-download 2–3 huge segments (~10 s each at link speed) before playback resumes — that
  is buffering, not failure; the deadline auto-retry covers the case where AVFoundation
  gives up mid-jump.

## HDR / Dolby Vision facts and Stats rows (GH #195)

Verified visionOS/AVFoundation findings (simulator probe on visionOS 26.5, 2026-07-03; see
issue #195 for source links):

- `AVPlayer.eligibleForHDRPlayback` is the supported capability check on visionOS 26; the
  older `AVPlayer.availableHDRModes` is deprecated there and its bitset only distinguishes
  HLG / HDR10 / Dolby Vision. **There is no HDR10+ AVPlayer mode bit** — HDR10+ can only be
  identified from backend/source metadata, so Stats labels it as a *source* format and never
  claims AVPlayer renders the dynamic metadata.
- Apple documents automatic DV 8.4 handling via AVPlayer/AVPlayerLayer on HDR-capable
  devices, and AVP specs list Dolby Vision, HDR10, HLG. Per-profile/container combinations
  (DV5, DV7, MKV remuxes) still need sample-specific validation before any direct-play
  policy change — `DeviceProfile` deliberately stays conservative.
- Runtime detection: `asset.loadTracks(withMediaCharacteristic: .containsHDRVideo)` plus the
  video track's `CMFormatDescription` transfer-function extension (PQ / HLG). For HLS,
  format descriptions are empty until segments load, so `PlaybackHDRProbe` is retried from
  the diagnostics tick until it sees real format descriptions.

Backend signalling capabilities, verified against live servers with ffprobe ground truth on
the shared media volume (server-side survey, 2026-07-03; all three backends indexed the same
files, so one ffprobe per file arbitrated all three):

- **Jellyfin is the authoritative server-side classifier.** Its `VideoRangeType` enum
  matched ffprobe on every sample, including combined types (`DOVIWithEL`,
  `DOVIWithHDR10Plus`, `DOVIWithELHDR10Plus`, `HDR10Plus`), and it exposes numeric
  DV profile/level/compat plus `Hdr10PlusPresentFlag`.
- **Plex exposes full DOVI fields but has NO HDR10+ indicator at all** — an HDR10+ file is
  indistinguishable from plain HDR10 in PMS metadata, and a DV+HDR10+ file reports only DV.
- **Emby exposes no numeric DV fields and no HDR10+ flag** — only `VideoRange`
  ("SDR"/"HDR 10"/"DolbyVision") and `ExtendedVideoType/SubType`, where the subtype string
  `DoviProfileNN` encodes profile+compat as two digits (`DoviProfile50` = P5 compat 0,
  `DoviProfile76` = P7 compat 6, `DoviProfile81` = P8 compat 1). HDR10+ files collapse to
  "HDR 10" / plain DolbyVision.
- **DV Profile 5 files may carry no `color_transfer` tag at all** (IPTPQc2 is signalled via
  the DOVI config record), so DV detection must never require a PQ transfer tag.
- Consequence for Stats: an "HDR10" label on Plex/Emby may really be HDR10+ — only Jellyfin
  (or bitstream inspection) can tell. The classifier deliberately does not guess.

Stats rows added for #195: **Video**/**Audio** show friendly format names
(`AVFormatLabels`: "HEVC", "Dolby Digital Plus (E-AC-3) Atmos 5.1", "DTS-HD MA 7.1"),
**HDR** shows the backend-classified source format (`VideoHDRMetadata.displayLabel`, e.g.
"Dolby Vision P8 (HDR10 fallback)", "HDR10 · PQ · BT.2020 · 10-bit"), **Runtime HDR** shows
the AVFoundation probe ("HDR · PQ · eligible"), and **Output** shows an SDR tone-map
*inference* when the server is transcoding an HDR source (worded as "likely" — none of the
three backends state tone-mapping per-session explicitly). Classification precedence lives
in `VideoHDRMetadata.classify`: DV > HDR10+ > PQ > HLG > coarse "HDR" range > positive SDR
evidence > nil (row hidden). Bit depth alone is never treated as HDR evidence.

## DV Profile 5 guard and experimental DV signalling (GH #196)

Live failure matrix that motivated the guard (DV P5 / IPTPQc2 / BL-compat 0 sample at
Original quality, video-copy lanes, 2026-07): **Plex** → client decoder-not-found
(`VT-DS -12906`, surfaced as -11833); **Jellyfin** → progressive lane rejects the samples
(-12864), then the server's own HLS transcode fallback stalls (SEGPUMP -12889 retry loop,
no segments); **Emby** → *silent black screen*, no error at all. P5 has no
backwards-compatible base layer, so once a remux strips DV signalling nothing recoverable
reaches the decoder. P7/P8 on the same lanes render their HDR10 base layer correctly.

**The guard (default-on):** `DolbyVisionPlaybackPolicy` (PMSKit) forces a server tone-map
transcode when DV is present with `blCompatibilityID == 0` (or profile 5 with unknown
compat). Enforcement is per backend: Plex sends `directStream=0` (`TranscodeRequest
.forceTranscode`); Jellyfin PlaybackInfo sends `EnableDirectPlay/EnableDirectStream/
AllowVideoStreamCopy = false` (audio copy stays allowed). **Emby blocks P5 outright**
(`serverToneMapsUntaggedDV: false` → `.blockPlayback`, surfaced as the DV error before
PlaybackInfo is even sent): kubectl-verified, Emby's ffmpeg graph applies no tonemap
filter to an untagged P5 input — the "successful" forced transcode decodes IPTPQc2 as
YCbCr and bakes green/purple tint into the H.264 output, undetectable client-side. P5 is
untagged by nature, so this is structural, not a server-config issue. Jellyfin, by
contrast, tone-maps untagged P5 correctly (`setparams=…smpte2084…,tonemap_cuda=…bt2390`).
Because Jellyfin's own P5 tone-map stalled live, the guard pairs with a **first-frame
watchdog** (20 s, transport-progress-deferred like the stall watchdog — Emby re-priming a
deep-seek transcode legitimately exceeds 20 s) that surfaces a DV-specific error instead
of a spinner. Stats: the Decision row gains "· DV P5 guard (no fallback layer)", and a
**Rendered** row distinguishes "SDR (server tone-map)" / "HDR10 fallback (base layer)" /
"Dolby Vision (signalled — unverified)" from the source classification.

**Experimental DV signalling (default-OFF Settings toggle):** two gated spikes, both
device-UNVERIFIED (no headset pass yet — do not enable by default):
- *dvh1 advertising*: Plex profile-Extra gains a DV MP4 direct-play directive (base name
  stays `Generic` — hard constraint); Jellyfin/Emby DeviceProfiles gain a `VideoRangeType`
  CodecProfile including the DOVI* values (the signal that stops Jellyfin stripping
  `dvcC`/RPUs on remux — Swiftfin finding).
- *HLS playlist injection*: `PlaylistRewriter` can append `SUPPLEMENTAL-CODECS`/
  `VIDEO-RANGE` to master-playlist variant lines
  (`MediaSessionDolbyVisionInjection.forDolbyVision`, deliberately narrow: DV **P8 only**,
  compat 1/6 → `db1p`+PQ, compat 4 → `db4h`+HLG; P5/P7/unknown never inject). With the
  toggle on and a DV P8 Plex source, `PlaybackController` routes `start.m3u8` through the
  loopback proxy (with X-Plex identity headers on upstream fetches) to apply it.
- The toggle also **defers the P5 guard** (an opted-in DV lane may make P5 playable).
- **Advertising is per-item, not per-session** (live regression, 2026-07-03): with the
  toggle on, advertising DV on *every* play broke an unrelated DV P7 MKV on Plex — the
  decision said "Direct play OK" but `start.m3u8` 400'd with the DV direct-play directive
  present, derailing a previously-working direct-stream title into a GPU-less CPU
  transcode. `DolbyVisionGuard.shouldAdvertiseDolbyVision(for:)` therefore gates the
  advertising to items whose stream is actually injection-eligible (DV P8, compat 1/4/6).

**MKV HEVC remux lane (same retest):** the Jellyfin/Emby *streaming* TranscodingProfile
now advertises `VideoCodec: "h264,hevc"` — h264 first so it stays the encode target, hevc
so the server may VIDEO-COPY HEVC sources whose container blocks direct play (4K MKV
remuxes). Without it every such title re-encoded to h264 at source bitrate; live, both
servers encoded fine (JF 8.5x, Emby 5.2x) but the ~20 MB/3 s segments starved AVPlayer
through the proxied ingress into -12889 before the first byte arrived.

**Open verification gates (tracked in #196):** (1) whether Plex remux segments actually
retain in-band RPU NALs — signalling DV that segments don't carry would itself cause broken
rendering, so injection stays debug-gated until a kubectl/ffprobe check of a live session
confirms it; (2) the physical-headset matrix ({P5, P7.6, P8.1} × backends) for true-DV
rendering. Emby forced-transcode note: an out-of-buffer deep seek re-primes the server
transcode and can hold `waitingToPlayAtSpecifiedRate` well past 20 s before resuming —
that is server prime latency, not a client bug.
