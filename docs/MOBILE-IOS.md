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
root, plus the shared `PMSKit` package. The public mobile support floor is iOS/iPadOS 26.1+.

## Current mobile behavior

- One adaptive shell for iPhone and iPad: compact widths use the tab-first iPhone shape;
  regular widths on iPadOS use the sidebar shape from `TabView` with `.sidebarAdaptable`
  (with the phone idiom, such as an unfolded iPhone Duo, it stays a tab bar).
  Search keeps the system `.search` tab role, the tab bar minimizes on scroll, and the
  music mini player rides `.tabViewBottomAccessory`. Settings is a tab in regular width and a
  toolbar sheet in compact width; a size-class change in either direction hands off between
  the two, so a resize or fold never strands the selection or leaves a duplicate sheet open.
- iPhone Duo (built with the iOS 27.1 SDK): the app fills either display and the system moves
  the tab bar and toolbars to a vertical bar on the trailing edge. The folded outer display is
  466×678 pt (compact width) and the inner display is 669×951 pt (regular width); both are about
  1.45:1. Layout keys on measured geometry and size classes, never on the device idiom. The
  detail page picks its composition from `MobileDetailLayoutPolicy` in PMSKit: the phone
  hierarchy below a 500-pt width (or a compact-width viewport whose short side is under 500 pt),
  the poster stacked over the metadata below 700 pt (the inner display), and side by side
  above. The compact key art and the Now Playing hero are bounded by the measured viewport
  height. The A–Z rail reserves its strip in regular width as well as compact width, and stays
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
  The iOS chrome keeps AirPlay/PiP in top-trailing system-style glass buttons, keeps
  Quality/Chapters/Speed/Stats as labeled glass pills, and lets the pill strip scroll
  horizontally when the row is too narrow instead of hiding controls behind an ellipsis
  menu. It also registers hardware-keyboard shortcuts (Space play/pause, ←/→ skip
  30s, Shift-←/Shift-→ skip 10s, Esc close). `UIBackgroundModes = audio`
  is set on `LabstreamMobile`; playback still pauses when the app backgrounds unless it is
  continuing through PiP or an external AirPlay route.
- Player layout contract (#258): `CustomPlayerView` owns its safe-area policy. The black backdrop
  and `AVPlayerLayer` fill the whole display (Fit/Fill only change `videoGravity`), while the
  chrome is laid out inside the leading, trailing, and bottom safe-area insets, so in iPhone
  landscape it clears the rounded corners, Dynamic Island, and home indicator. The top edge stays
  on the full-screen origin, because the chrome shows and hides the status bar with itself and
  that would otherwise move the envelope by the status-bar height on every reveal/hide on iPad.
  The top chrome's own inset clears the status bar on regular-width iPad; iPhone playback is
  landscape-only, where the top inset is already zero. Presenters must not add
  `.ignoresSafeArea()` to the player on iOS, because that would erase the chrome's insets. The
  Detail streaming/local covers use `customPlayerPresentationSafeArea()`, which keeps their
  previous full-bounds presentation on visionOS, tvOS, and macOS and is a no-op on iOS. The
  iOS/visionOS Downloads cover adds no safe-area modifier. For a fixed device, orientation, and
  source/menu set, the close/utility buttons, center play/pause, skips, menu pills, and bottom
  platter keep the same frames, and hiding the chrome does not move the envelope. The
  phone-landscape transport row never grows wider than its platter. If the item's menu set does
  not fit beside the four skips, the row drops to the -10/+30 pair and then scrolls the pills. PiP
  leads the top-trailing group, so its per-item availability never moves the display-mode or
  AirPlay buttons. A hairline outline keeps the glass platter legible over letterbox/pillarbox
  black.
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

## Build and smoke on an iPhone or iPad simulator

Use the canonical [iPhone/iPad simulator build](DEVELOPMENT.md#build-for-an-iphone-or-ipad-simulator)
and [observable smoke](DEVELOPMENT.md#install-and-observe-a-simulator-smoke) procedures. Select
`PLATFORM=iphone` for the compact-width path or `PLATFORM=ipad` for the regular-width path. The
simulator helper creates independent mobile simulators, so neither path clones or mutates the
visionOS golden simulator.

A compatible installed iOS Simulator runtime is required. The mobile target is iOS/iPadOS 26.1+,
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
- iPhone Duo: physical-device fold/unfold, a real Device Hub fold in the simulator, the
  `tabViewBottomAccessory` mini player and minimize-on-scroll behaviour beside the vertical
  bar (not yet observed with music playing), and Duo App Store screenshots. See
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
