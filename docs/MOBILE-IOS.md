# iOS and iPadOS target

Labstream's primary platform source paths include the visionOS target and one universal mobile
target:

| Target / scheme | Platforms | Product name | Bundle identifier |
| --- | --- | --- | --- |
| `Labstream` | visionOS / visionOS Simulator | `Labstream` | `com.jlipworth.Labstream` |
| `LabstreamMobile` | iOS, iPadOS, and iOS Simulator | `Labstream` | `com.jlipworth.Labstream` |

The repository also contains `LabstreamMac` as a local-build development preview. It is documented
separately in [macOS development preview](MACOS.md) and is not part of the supported mobile product
path.

The repository also contains `LabstreamTV`, a streaming-only Apple TV development target (no
Downloads/Offline capability at compile time). It is documented separately in
[tvOS development target](TVOS.md) and is not part of the iOS/iPadOS mobile product path described
here.

`LabstreamMobile` is the universal iPhone/iPad target. It compiles `Labstream/Shared/`,
`Labstream/Capabilities/Downloads/`, and its exclusive `Labstream/Platforms/Mobile/` owner
root, plus the shared `PMSKit` package. The public mobile support floor is iOS/iPadOS 26.1+.

## Current mobile behavior

- One adaptive shell for iPhone and iPad: compact widths use the tab-first iPhone shape;
  regular widths use the iPad sidebar shape from `TabView` with `.sidebarAdaptable`.
  Search keeps the system `.search` tab role, the tab bar minimizes on scroll, and the
  music mini player rides `.tabViewBottomAccessory`.
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
  10s/30s, Esc close). `UIBackgroundModes = audio`
  is set on `LabstreamMobile`; playback still pauses when the app backgrounds unless it is
  continuing through PiP or an external AirPlay route.
- Cellular downloads default to **off**. The Settings download toggle controls the
  cellular policy stamped onto freshly created request-based transfer tasks; existing
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

## App-hosted unit tests

`LabstreamMobile` owns the `LabstreamTests` test target through `LabstreamTests.xctestplan`.
The test sources live in `LabstreamTests/` and cover app-owned deterministic behavior rather than
UI automation or live-server acceptance. Use the exact test command and simulator shutdown in
[Core validation commands](DEVELOPMENT.md#core-validation-commands). Select an iPad worktree
simulator instead for platform-specific regular-width cases. Shared app infrastructure should also
run the macOS-hosted counterpart described in [Testing strategy](TESTING-STRATEGY.md).

## Install on a physical iPhone or iPad

Simulator builds use `CODE_SIGNING_ALLOWED=NO` and cannot install on hardware. Follow the canonical
[Physical iPhone or iPad install](DEVELOPMENT.md#physical-iphone-or-ipad-install) procedure for the
signed `LabstreamMobile` `iphoneos` build, pairing/trust, Developer Mode, Xcode account setup,
multiple-device selection, install, and launch.

## Remaining validation gaps

- Physical iPhone/iPad validation for PiP, AirPlay, Control Center/lock-screen Now
  Playing, background interruption behavior, and App Intents/Spotlight invocation.
- Physical-network validation for the cellular-download toggle and OS background-transfer
  scheduling. The code path is policy-wired, but real cellular behavior cannot be proven in
  an iOS simulator.
- Continued iPhone compact-width QA across signed-in Plex/Jellyfin/Emby libraries, music,
  offline rows, and long metadata titles.
- If App Store distribution is pursued, metadata/release work for the intended
  visionOS/iPhone/iPad universal-purchase product. The Mac preview has separate unresolved release
  and licensing decisions.
