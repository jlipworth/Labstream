# iOS and iPadOS target

Labstream's primary platform source paths include the visionOS target and one universal mobile
target:

| Target / scheme | Platforms | Product name | Bundle identifier |
| --- | --- | --- | --- |
| `Labstream` | visionOS / visionOS Simulator | `Labstream` | `org.labstream.Labstream` |
| `LabstreamMobile` | iOS, iPadOS, and iOS Simulator | `Labstream` | `org.labstream.Labstream` |

The repository also contains the native `LabstreamMac` release candidate. It is documented
separately in the [macOS target guide](MACOS.md) and is not part of the iOS/iPadOS binary described
here.

The repository also contains `LabstreamTV`, a streaming-only Apple TV release candidate (no
Downloads/Offline capability at compile time). It is documented separately in
[the tvOS target guide](TVOS.md) and is not part of the iOS/iPadOS binary described
here.

`LabstreamMobile` is the universal iPhone/iPad target. It compiles `Labstream/Shared/`,
`Labstream/Capabilities/Downloads/`, and its exclusive `Labstream/Platforms/Mobile/` owner
root, plus the shared `PMSKit` package. The public mobile support floor is iOS/iPadOS 26.1+
(`IPHONEOS_DEPLOYMENT_TARGET = 26.1`). It is built with Xcode 27.1 and the iOS 27.1 SDK, which
opts the app into the full iPhone Duo inner display and the vertical bars; supported devices are
iPhone, iPad and the iPhone Duo foldable.

## Current mobile behavior

- One adaptive shell for iPhone and iPad: compact widths use the tab-first iPhone shape;
  regular widths on iPadOS use the sidebar shape from `TabView` with `.sidebarAdaptable`
  (with the phone idiom, such as an unfolded iPhone Duo, it stays a tab bar).
  Search keeps the system `.search` tab role, the tab bar minimizes on scroll, and the
  music mini player rides `.tabViewBottomAccessory` with horizontal bars and becomes a bottom
  safe-area inset beside a vertical bar (see [iPhone Duo design contract](#iphone-duo-design-contract)). Settings is a tab in regular width and a
  toolbar sheet in compact width; a size-class change in either direction hands off between
  the two, so a resize or fold never strands the selection or leaves a duplicate sheet open.
- iPhone Duo (built with the iOS 27.1 SDK): the app fills either display and the system moves
  the tab bar and toolbars to a vertical bar on the trailing edge. The folded outer display is
  466×678 pt (compact width) and the inner display is 669×951 pt (regular width); both are about
  1.45:1. Layout keys on measured geometry and size classes, never on the device idiom. The
  detail page picks its composition from `MobileDetailLayoutPolicy` in PMSKit: the phone
  hierarchy below a 500-pt width (or a compact-width viewport whose short side is under 500 pt),
  a 220-pt key-art hero over the metadata below 700 pt (the inner display), and side by side
  above (in book the poster centres before the hinge and the metadata starts after it). The
  page draws nothing until the viewport is measured, so no fallback composition flashes. The
  phone key art spans the full width as a background layer and crops to 16:9, capped at 40% of
  the viewport height; the Now Playing hero is bounded by the measured viewport height. Every
  composition has the same sections: the title once (the navigation title appears only after it
  scrolls away), a Caption context line, one Play/Resume capsule with Download and Mark Watched
  as glass circles, then Cast and More Like This rails across the content region. A show page
  has its own header with "Resume S1, E3" and "23m left" above the season posters; selecting a
  season pushes its episode list ("E1 · 38m" rows), except on a wide regular landscape region
  (the unfolded-sideways inner display), where the show page and the chosen season sit side by
  side about 50/50, with the divider on the hinge in book. The A–Z rail reserves its strip in regular width as well as compact width, and stays
  inside the safe area, so it clears the vertical bar. Shared code that uses 27.1-only SwiftUI
  API must guard it for the 27.0-SDK visionOS, tvOS and macOS targets.
- Detail, player chrome, offline/download, settings, and music surfaces are shared but are
  expected to stay readable in iPhone compact width. The video detail action stack and
  player controls collapse vertically/horizontally rather than assuming an iPad canvas;
  regular-width iPad detail keeps a readable metadata column.
- Controls that float over media use Liquid Glass on iOS via the `labstream*` helpers in
  `Labstream/Shared/UI/DesignSystem.swift`; visionOS keeps its proven
  `glassBackgroundEffect`/material look.
- The custom AVFoundation video player exposes mobile system hooks for Picture in Picture,
  AirPlay route picking, video Now Playing metadata, and remote play/pause/seek commands.
  The iOS chrome is one arrangement of glass circles (symbols with accessibility titles) in
  every pose: Close, Picture in Picture and Fit/Fill at top leading and AirPlay at top
  trailing; −10 / play-pause / +10 in the centre; the title with a 1–2 word caption ("S1, E5"
  or the year); the scrubber with elapsed and remaining times; then Subtitles, Audio, Chapters,
  Speed, Stats and More. Quality lives in More, the single overflow. It also registers hardware-keyboard shortcuts (Space play/pause, ←/→ skip
  30s, Shift-←/Shift-→ skip 10s, Esc close). `UIBackgroundModes = audio`
  is set on `LabstreamMobile`; playback still pauses when the app backgrounds unless it is
  continuing through PiP or an external AirPlay route. A resign-active pauses video only if it
  lasts 400 ms (`didBecomeActive` cancels it), so a fold, a Control Center pull or the start of
  automatic PiP does not stall playback.
- Player layout contract (#258): `CustomPlayerView` owns its safe-area policy. The black backdrop
  and `AVPlayerLayer` fill the whole display (Fit/Fill only change `videoGravity`), while the
  chrome is laid out inside the leading, trailing, and bottom safe-area insets, so in iPhone
  landscape it clears the rounded corners, Dynamic Island, and home indicator. The top edge stays
  on the full-screen origin, because the chrome shows and hides the status bar with itself and
  that would otherwise move the envelope by the status-bar height on every reveal/hide on iPad.
  The top chrome pads by the larger of its authored inset and the top safe-area inset, measured
  outside that ignore and latched per viewport size (`PlayerTopSafeInsetLatch`), so a portrait
  phone-class or iPhone Duo viewport clears its status bar without the iPad reveal/hide jump.
  Presenters must not add
  `.ignoresSafeArea()` to the player on iOS, because that would erase the chrome's insets. The
  Detail streaming/local covers use `customPlayerPresentationSafeArea()`, which keeps their
  previous full-bounds presentation on visionOS, tvOS, and macOS and is a no-op on iOS. The
  iOS/visionOS Downloads cover adds no safe-area modifier. `MobilePlayerArrangement` (PMSKit)
  places the control group: the whole safe frame; the aspect-fit video rectangle on a large
  portrait scene (unfolded Duo upright, iPad portrait; at least 300 pt tall); the trailing half
  after a book hinge (the top row stays); or a deck below a tabletop hinge, where the same layer
  shrinks to the top half and the deck never auto-hides. The pose comes only from the shell's pose
  value (the active `reservedRegions(kind: .division)` region, or the DEBUG override); the
  player's read-only hinge interaction is diagnostics-only and never synthesises a pose. The bottom group ends before an active occlusion region (the outer
  camera island). For a fixed device, orientation and source the controls keep the same frames
  whatever the item's menu set, landscape frames do not depend on the source aspect, and hiding
  the chrome does not move the envelope. The PiP slot is always present (dimmed when PiP is
  unavailable), so its availability never moves the buttons beside it. A gradient scrim, not a
  platter, keeps the controls legible.
- Player geometry (iPhone, iPad, iPhone Duo): the landscape lock comes from
  `MobilePlayerOrientationLockPolicy`, not the idiom. It applies while the player's own scene is
  phone-class (short side under 500 pt) and fills its screen, and it is re-decided on every
  scene-geometry change: unfolding a Duo releases it (the mask widens, no rotation is forced),
  folding re-applies it, and a scene that refuses the request (for example a resizable session) is
  not asked again for that display class. On close the entry orientation is restored, unless the
  display class changed in between, when only the mask is widened. The chrome branch (phone
  landscape, compact, regular) comes from `MobilePlayerChromeLayoutPolicy`: the folded Duo gets
  the phone chrome and the unfolded Duo the regular chrome. A branch change during a scrub
  cancels the scrub. Menus are clamped to the available width in every branch, and the trick-play
  hover preview follows a non-compact viewport rather than the iPad idiom. The player disables the
  iOS 27.1 vertical bar (`toolbarVerticalBehavior(.disabled)`): folded in landscape the
  status-bar strip then sits on top (82 pt) instead of beside the leading edge, which keeps the
  chrome symmetric. A fold, rotation or resize never reloads or reopens the stream; see
  [Playback architecture](PLAYBACK-ARCHITECTURE.md#ios-presentation-geometry).
- Detail and Offline share exact-attempt local launch admission after orientation, local resume
  and rewind, observed-playing verification and the combined embedded/text-sidecar subtitle menu.
  A superseded or rejected launch must restore orientation without presenting a stale player.
  Download rows share lifecycle captions, accessibility values and exact-attempt controls with Mac
  and visionOS; device rotation, narrow layouts and background continuation remain acceptance gates.
- Cellular downloads default to **off**. The Settings download toggle controls the
  cellular, Low Data Mode and expensive-network policy stamped onto freshly created
  request-based transfer tasks; existing
  active/resume-data tasks keep the policy they were created with. Labstream does not
  sync offline media between devices.
- Spotlight and App Intents route through the active backend/session only. Plex, Jellyfin,
  and Emby entries use backend/server-scoped, non-token route identifiers and do not create
  an offline catalog. Treat those identifiers as private in shared diagnostics because they
  can include a server namespace and media item id.
- The Plex client identity reports `X-Plex-Platform=iOS` and `X-Plex-Device` as `iPad` or
  `iPhone`; visionOS continues to report `visionOS` / `Apple Vision Pro`.

## iPhone Duo design contract

The full rationale, mockup sign-off and Apple sources live in the
Design section of `docs/plans/iphone-duo.md`. These are the rules current code
holds to; layout keys on size class and measured safe area, never on pose name, idiom or
`UIScreen`.

**Poses.** The inner display's hinge runs across the short side of the folded phone, so each half
of the inner display is about the size of the outer display.

| Pose | Display / orientation | Size class | Bars |
| --- | --- | --- | --- |
| Folded portrait | outer, 466×678 pt | compact width | vertical system column |
| Folded landscape (tent) | outer, 678×466 pt | compact / compact | vertical column on the outer camera's edge (trailing or leading by rotation) |
| Unfolded upright | inner, 669×951 pt | regular / regular | horizontal: top row plus floating bottom tab capsule |
| Unfolded sideways | inner, 951×669 pt | regular / regular | vertical system column |
| Tabletop | unfolded upright, partially folded (horizontal hinge) | as upright | as upright |
| Book | unfolded sideways, partially folded (vertical hinge) | as sideways | as sideways |

**Bars and safe area.**

- The content region is the screen minus the horizontal safe-area insets. A vertical bar supplies
  its inset on whichever edge carries it; handle each edge on its own and never cache, derive or
  hardcode the inset. Margins (16 pt compact, 24 pt regular, 12 pt for rails) are measured from the
  content region's edge, not the screen edge.
- Only decoration and media run under the bar (background washes, detail key art, full-screen
  video), via a background-layer `.ignoresSafeArea(edges: .horizontal)`. Text and controls stay in
  the content region, and centred elements (empty states, mini player, sheets) centre in it.
- Every action is a container toolbar item with a title and an SF Symbol so the system can move it
  into the column; no custom controls float over content.
- Horizontal shelves and rails **clip** at the content region: at rest nothing sits under the
  column, and the last card still scrolls fully into view one margin short of it. Shadows get
  vertical padding inside the rail, not `scrollClipDisabled(true)`. Card widths come from the
  measured content-region width (whole cards plus about 30% of the next as the overflow cue).
- Grids use even column counts wherever a fold can split them: 4 unfolded sideways (split 2 + 2
  around a book hinge), 3 upright, 3 folded portrait, 4 folded landscape.
- The mini player is a **bottom inset**: beside a vertical bar the shell hosts `MiniPlayerBar` with
  `safeAreaInset(edge: .bottom)`, centred in the content region; with horizontal bars it stays the
  `tabViewBottomAccessory`. Either way, scroll viewports end above it.
- Text columns (detail metadata, Settings, login, empty states) are capped and centred in the
  content region; regular-width Settings (unfolded Duo, iPad) is two columns like iPad Settings: a category list
  (the selected row is the only amber) beside the selected category's form, with the split on the
  hinge in book pose. Folded and in compact width it stays one form in the toolbar sheet; a
  fold/unfold selects the category the form was showing and back. Downloads is one list in
  every width with no detail page: a tap plays a finished download or opens an unfinished one's
  actions; long-press and swipe offer the same.
- Folding or unfolding is a resize plus a trait change, never a teardown: the selected tab,
  navigation path (including Settings sheet to tab), scroll anchors, rail offsets, open sheets and
  playback all survive. The player disables its vertical bar (`toolbarVerticalBehavior(.disabled)`).
  Sheets keep theirs: folded, the Settings sheet's neutral close button sits in the sheet's
  column under the status items, as in Apple's own single-button sheets (Settings ▸ Apple Account
  sign-in). Disabling a sheet's bar moves the status bar onto the presenter's title.
- Color has one meaning each: amber is selected (including switch on state), green is plays-as-is
  status only, red is destructive or failed, and everything else is neutral glass or label color.

**Pose source and DEBUG override.** `providesDuoPose()` on the mobile shell installs the single
`\.duoPose` value (always `.flat` on visionOS, tvOS and macOS). It comes only from the active
`reservedRegions(kind: .division)` region (iOS 27.1); `UIHingeInteraction` is diagnostics-only.
Book keeps the player overlay and moves the whole control group (transport, title, scrubber,
bottom circles) into the trailing half; tabletop shows the video in the top half and a
non-auto-hiding deck with the same controls in the bottom half. Because folding cannot be driven
headlessly, Debug builds accept `LABSTREAM_DEBUG_DUO_POSE=book|tabletop` (launch environment, or
`--labstream-debug-duo-pose <value>`): it synthesises a 20 pt hinge strip at the centre of the
current bounds, applies only while the bounds match the pose's orientation (sideways for book,
upright for tabletop), reports `flat` for unknown values, and records `duo.pose_override` in
`AppDiagnostics`. Release never compiles the override. `scripts/duo-appresize.sh launch --pose
book|tabletop` combines it with the `appResize` inner-size proxy; those captures prove layout
against the seam only, and real Device Hub and hardware fold frames remain an open gate.

## Build and smoke on an iPhone or iPad simulator

Use the canonical [iPhone/iPad simulator build](DEVELOPMENT.md#build-for-an-iphone-or-ipad-simulator)
and [observable smoke](DEVELOPMENT.md#install-and-observe-a-simulator-smoke) procedures. Select
`PLATFORM=iphone` for the compact-width path, `PLATFORM=ipad` for the regular-width path, or
`PLATFORM=duo` for the iPhone Duo foldable (`duowt-*`, `.simid-duo`; the `iPhone Duo` device type
needs the iOS 27.1 simulator runtime and never falls back to a slab iPhone). The
simulator helper creates independent mobile simulators, so neither path clones or mutates the
visionOS golden simulator.

A compatible installed iOS Simulator runtime is required (Xcode 27.1 ships the iOS 27.1 SDK; the
newest installed iOS runtime is selected). The mobile target is iOS/iPadOS 26.1+,
so older local Xcode/SDK installations may report deployment-target warnings or fail before app
code compiles; install the matching platform/runtime in Xcode Settings before treating the mobile
target as broken. Shut the selected simulator down when the smoke finishes, as described in the
canonical procedure.

For a credential-free agent loop, acquire the one-simulator lease and use the named runner rather
than driving coordinates:

```sh
scripts/agent-mobile-run.sh iphone fixture-detail-semantic --allow-simulator
scripts/agent-mobile-run.sh ipad fixture-detail-semantic --allow-simulator
```

The semantic scenario runs `LabstreamMobileFixtureUITests` against the shared synthetic browse
fixture, activates `labstream.home.fixture-resume.plex-orbit`, and asserts the detail summary. Its
artifact directory contains a screen recording, host screenshots, bounded logs, the `.xcresult`,
exported XCTest attachments, `test-summary.json`, and machine-readable `run.json`. Use
`fixture-home-passive` only when launch/render evidence is sufficient.

`LabstreamMobileFixtureUITests` also owns the player-chrome geometry regression. It launches
`--ui-testing --ui-testing-fixture player --ui-testing-player-aspect 16x9|239x100|4x3
--ui-testing-player-paused`, optionally adding `--ui-testing-player-all-menus` to show the
streaming-width menu set. The fixture plays a synthetic local clip through the real
`CustomPlayerView`, and the test asserts identical chrome frames across aspects. On iPad it checks
portrait and landscape. Adding `--ui-testing-player-geometry` writes a privacy-safe
`PlayerGeometry` log, with labels, window frames, safe-area insets, and
`AVPlayerLayer.videoRect`, under the `PlayerGeometry` category. Xcode Device Interaction is
the preferred exploratory iOS 27 driver when available, but XCUITest is the durable regression
contract. Neither path needs or may invent real backend credentials.

## App-hosted unit tests

`LabstreamMobile` owns the `LabstreamTests` and `LabstreamMobileUITests` targets through
`LabstreamTests.xctestplan`. The hosted sources live in `LabstreamTests/`; the UI target owns the
credential-free semantic fixture regression. Neither is live-server acceptance. Use the exact test
command and simulator shutdown in
[Core validation commands](DEVELOPMENT.md#core-validation-commands). Select an iPad worktree
simulator instead for platform-specific regular-width cases. Shared app infrastructure should also
run the macOS-hosted counterpart described in [Testing strategy](TESTING-STRATEGY.md).

## Install on a physical iPhone or iPad

Simulator builds use `CODE_SIGNING_ALLOWED=NO` and cannot install on hardware. Follow the canonical
[Physical iPhone or iPad install](DEVELOPMENT.md#physical-iphone-or-ipad-install) procedure for the
signed `LabstreamMobile` `iphoneos` build, pairing/trust, Developer Mode, Xcode account setup,
multiple-device selection, install, and launch.

## Remaining validation gaps

- Physical iPhone confirmation of the #258 chrome layout contract (stable envelope across source
  aspects, rounded-corner clearance) and iPad compact Split View/Stage Manager widths, which the
  simulator fixture does not drive. In compact or windowed iPad layouts, check that the top-leading
  Close button clears the status bar and the window controls.
- iPhone Duo: physical-device fold/unfold, real Device Hub inner-display, folded-landscape (both
  rotations), book, tabletop and fold frames (the DEBUG pose override proves layout against the
  seam only), the bottom-inset mini player beside the vertical bar and minimize-on-scroll with
  horizontal bars (not yet observed with music playing), and Duo App Store screenshots. See
  [#419](https://github.com/jlipworth/Labstream/issues/419).
- Physical iPhone/iPad validation for PiP, AirPlay, Control Center/lock-screen Now
  Playing, background interruption behavior, and App Intents/Spotlight invocation.
- Physical-network validation for the cellular-download toggle and OS background-transfer
  scheduling. The code path is policy-wired, but real cellular behavior cannot be proven in
  an iOS simulator.
- Continued iPhone compact-width QA across signed-in Plex/Jellyfin/Emby libraries, music,
  offline rows, and long metadata titles.
- Complete the iPhone and iPad metadata, screenshot, TestFlight, fresh-install, accessibility, and
  hardware gates for the coordinated four-platform universal-purchase release. One iOS archive
  covers both device families, but each family still needs its own acceptance evidence.
