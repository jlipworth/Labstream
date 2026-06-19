# Development notes

Durable, easy-to-forget facts about building and working on this app. Task/bug tracking lives in
[GitHub Issues](https://github.com/jlipworth/VisionPlay/issues); see the [README](../README.md)
for the basic build/run.

## Build, test, run

```sh
# Build (visionOS 26.5 simulator, unsigned)
xcodebuild -project VisionPlay.xcodeproj -scheme VisionPlay \
  -destination 'platform=visionOS Simulator,name=Apple Vision Pro' \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO

# PMSKit unit tests
(cd PMSKit && swift test)

# Repo hygiene (redaction/signing guardrails)
./scripts/ci-hygiene.sh

# Install + launch on a booted sim
APP="$HOME/Library/Developer/Xcode/DerivedData/VisionPlay-<hash>/Build/Products/Debug-xrsimulator/VisionPlay.app"
xcrun simctl install booted "$APP" && xcrun simctl launch booted com.jlipworth.VisionPlay

# After-the-fact logs
xcrun simctl spawn booted log show --last 5m --predicate 'process == "VisionPlay"' --style compact
```

- App bundle id: `com.jlipworth.VisionPlay` · Sim: "Apple Vision Pro" (visionOS 26.5).
- Profiling workflow: see [`docs/PROFILING.md`](PROFILING.md) for Instruments baseline targets, simulator/device caveats, and finding templates.
- New Swift files are auto-included (Xcode file-system-synchronized groups + SPM
  `PMSKit/Sources`, `PMSKit/Tests`) — no `project.pbxproj` edits needed.

## Personal-device signing

Simulator builds stay unsigned. For Apple Vision Pro sideload installs, keep the Apple Developer
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

## Gotchas we don't want to re-learn

- **CRITICAL — do not revert:** `TranscodeRequest` sends `X-Plex-Client-Profile-Name="Generic"`
  (plus an explicit `X-Plex-Client-Profile-Extra`). Safari was tried and regressed high-bitrate 4K
  HEVC — it hard-limits 10-bit HEVC and forced ~20 Mbps video transcodes on 4K MKV titles even on
  Direct Play / Maximum — so `Generic` is the proven-correct value. An unknown or missing profile
  name (e.g. "visionOS") makes PMS return a bare **HTTP 400** and playback breaks, so the name must
  always resolve to a real built-in profile. The bitrate cap is enforced by `maxVideoBitrate`.
- **AVKit `contextualActions`** (`visionos(1.0)`) is the only affordance that renders over video in
  **both** inline and expanded cinema states and stays tappable — a floated SwiftUI sibling vanishes
  in the expanded experience, and the ⓘ panel is buried. (See the Close-button placement issue.)
- **Close-button placement is settled — keep the `contextualActions` "✕ Close".** Three alternatives
  were built as local branches (`close-A/B/C`, never pushed) and all lost to it: **A** (floated top-left ✕)
  vanishes in expanded cinema; **B** (`showsPlaybackControls = false` + a hand-drawn transport) works
  but *amputates the native info tabs* — Quality/Subtitles/Speed/Stats all disappear with native
  chrome; **C** (window `.ornament` ✕) is worse — **a `.ornament` on the player suppresses AVKit's
  own tap-to-reveal**, so the native transport + "…" menu never appear and you can't even reach
  Expand. The ornament ✕ itself persists across expand (floats just outside the window), but at the
  cost of all other controls. Net: `contextualActions` is the only option keeping both-state Close
  *and* the full native feature set. Its always-on rendering (the system shows contextual actions
  over the video until first interaction) is mitigated per experience — visionOS has no
  transport-bar-visibility callback (`API_UNAVAILABLE(visionos)`):
  - **Expanded:** taps NEVER enter the app process (verified with recognizers on every reachable
    window, including the private `_MRUIPlatterOrnamentBackingWindow` the player view moves
    into) — the system shell handles them. So Close joins the actions permanently ~0.5s after
    the expand transition finishes (`AVExperienceController.Delegate`), and the **system** ties
    the pill to its own chrome visibility. The 0.5s grace is empirical (3s made Close pop in
    late after an early tap).
  - **Windowed:** a non-consuming tap recognizer (the same tap that summons the chrome) shows
    Close for the chrome's ~5s auto-hide window.
  Paused/failed keep it up in both. A paused-only gate was tried first and rejected — forcing a
  pause before Close is an extra step.
- **Expanded cinema scene = system chrome only.** App-process pixels never composite there:
  floated SwiftUI siblings don't render, `contentOverlayView` is never composited (verified), and
  `customOverlayViewController` is tvOS-only. The surfaces that DO work in expanded are all
  system chrome: `contextualActions` pills, the transport, and the ⓘ info panel —
  `customInfoViewControllers` tabs render and are fully interactive there. Hence Stats for
  Nerds (#6) lives as an inline info-panel tab (`StatsTabView`), the only stats surface visible
  in expanded; a floating overlay remains possible in *windowed* mode only.
- **ⓘ Info card year:** the card shows a year after the runtime, sourced from the stream's
  creation date — for a live transcode that's *today's* year (seen as "2026" on a 2013 film).
  Override: `externalMetadata` item `.commonIdentifierCreationDate` with an **NSDate-typed
  value** (Jan 1 of the release year) — verified working. STRING values are ignored under that
  identifier and every other plausible one (`quickTimeMetadataCreationDate`,
  `id3MetadataRecordingTime`, `iTunesMetadataReleaseDate`) — all proven live. Title
  (`.commonIdentifierTitle`) and description (`.commonIdentifierDescription`) work as strings;
  cap the description ~150 chars or it pushes the title off the card.
- **Closing the ⓘ info panel programmatically:** there is no public API, and in EXPANDED the
  panel is an in-process platter ornament (`_MRUIPlatterOrnamentBackingWindow` →
  `_MRUIPlatterOrnamentRootViewController`, verified via the dismiss instrumentation) with NO
  `presentingViewController` anywhere in the tab's ancestor chain. Emptying
  `customInfoViewControllers` closes it in WINDOWED but is ignored in EXPANDED. Working
  recipe (verified): hide the tab's `view.window` + empty-then-restore the tab array; every
  tab host (`InfoTabHostingController`) un-hides its window on `viewDidAppear` so a reopened
  panel is never invisible. Re-assigning the SAME tabs array does nothing.
- **Play-vs-metadata race:** listing payloads omit chapters/markers; `DetailView` backfills
  them asynchronously and tapping Play can win that race (seen live as a missing Chapters
  tab). The player no longer depends on the caller's copy — `loadChaptersIfNeeded()` fetches
  full metadata and the control surface re-installs the tab strip when chapters arrive.
- **The platter ✕ under the expanded screen cannot quit the app** — the cinema scene is
  system-owned and its ✕ only collapses the player back into the host window (AVKit docks it).
  `AVExperienceController.TransitionContext` carries no initiator (checked the XROS 26.5
  swiftinterface: just `status`/`fromExperience`/`toExperience`), so a system collapse is
  detected as "completed expanded→embedded we didn't flag" (`appInitiatedCollapse`) and treated
  as Close. Trade-off (accepted): the chrome's shrink-to-window control also closes the player.
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
  docs/PLEX_AVP_TRANSCODE_OOM_REPORT.md). Each start.m3u8 for a non-direct-playable file
  forks a full software HEVC→H.264 encode (no HW decode in the pod); during starved
  scrubbing one session stacked 21 transcoder jobs in ~60s (8 within 1.1s) and OOM-killed
  the 8Gi pod — twice. Two independent drivers, both needed taming: (a) client-initiated
  restarts (stop-before-restart above + the budget below); (b) **PMS itself relocates
  ffmpeg** when AVPlayer requests a segment outside the produced window — AVPlayer fetches
  HLS segments autonomously during a scrub (seen: 536 404s, 140 concurrent GETs), so client
  restraint alone is insufficient; the fix for (b) is not seeking into far-unproduced
  territory on a session that can't keep up. Guard rails: `FinalTargetRebuildPolicy` +
  `SeekRestartBudget` (PMSKit, unit-tested spam scenarios) debounce noisy seek jumps to the
  final target, allow only one rebuild pipeline at a time, and enforce a rolling 3-per-60s burst
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
- **Reinstall wipes the app container** (keychain + Application Support) → **re-login required after
  every reinstall.** The token persists across plain relaunches via a file fallback in
  `KeychainStore` (the unsigned-sim keychain fails with `errSecMissingEntitlement -34018`).
- **Single-window constraint:** no `openWindow` / second `WindowGroup` — the player is a
  `.fullScreenCover`, like other native players.
- **Server:** configured per-user at sign-in (a Cloudflare-fronted PMS over `:443`). The real
  hostname/LAN IP are intentionally kept out of the repo.
- **No volume control in the MiniPlayerBar (deliberate, MUSIC-DESIGN scope fence):** visionOS
  Digital Crown + system volume own loudness; an AVPlayer-level slider would diverge from the
  system volume. The bar's 3-pt progress hairline is likewise **passive** — a 3-pt drag target
  violates the 60-pt gaze rule; scrubbing lives in the Now Playing sheet (a hover-growing thin
  scrubber is a possible v2 trial).

## Conventions

- **Never commit** Plex tokens or client identifiers.
- Never `NSLog` a raw string containing `%` (format-string crash) — use `NSLog("%@", str)`.
