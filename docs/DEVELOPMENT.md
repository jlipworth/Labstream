# Development notes

Durable, easy-to-forget facts about building and working on this app. Task/bug tracking lives in
[GitHub Issues](https://github.com/jlipworth/VisionPlex/issues); see the [README](../README.md)
for the basic build/run.

## Build, test, run

```sh
# Build (visionOS 26.5 simulator, unsigned)
xcodebuild -project PlexAVPApp.xcodeproj -scheme PlexAVPApp \
  -destination 'platform=visionOS Simulator,name=Apple Vision Pro' \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO

# PlexKit unit tests
cd PlexKit && swift test

# Install + launch on a booted sim
APP="$HOME/Library/Developer/Xcode/DerivedData/PlexAVPApp-<hash>/Build/Products/Debug-xrsimulator/PlexAVPApp.app"
xcrun simctl install booted "$APP" && xcrun simctl launch booted com.personal.PlexAVPApp

# After-the-fact logs
xcrun simctl spawn booted log show --last 5m --predicate 'process == "PlexAVPApp"' --style compact
```

- App bundle id: `com.personal.PlexAVPApp` · Sim: "Apple Vision Pro" (visionOS 26.5).
- New Swift files are auto-included (Xcode file-system-synchronized groups + SPM
  `PlexKit/Sources`, `PlexKit/Tests`) — no `project.pbxproj` edits needed.

## Gotchas we don't want to re-learn

- **CRITICAL — do not revert:** `TranscodeRequest` sends `X-Plex-Client-Profile-Name="Safari"`. An
  unknown profile name (e.g. "visionOS") makes PMS return a bare **HTTP 400** and playback breaks.
  The bitrate cap is enforced by `maxVideoBitrate`.
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

## Conventions

- **Never commit** Plex tokens or client identifiers.
- Never `NSLog` a raw string containing `%` (format-string crash) — use `NSLog("%@", str)`.
