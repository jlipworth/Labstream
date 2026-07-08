# iOS and iPadOS target

Labstream has two native Apple app targets:

| Target / scheme | Platforms | Product name | Bundle identifier |
| --- | --- | --- | --- |
| `Labstream` | visionOS / visionOS Simulator | `Labstream` | `com.jlipworth.Labstream` |
| `LabstreamMobile` | iOS, iPadOS, and iOS Simulator | `Labstream` | `com.jlipworth.Labstream` |

`LabstreamMobile` is the universal iPhone/iPad target. It shares the app source tree and
`PMSKit` package with the visionOS target, but uses the mobile app entry point and an
adaptive mobile shell. The public mobile support floor is iOS/iPadOS 26.1+.

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
  `Labstream/UI/DesignSystem.swift`; visionOS keeps its proven
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

## Build and smoke on an iPhone simulator

Use a platform-specific worktree simulator so the mobile build does not clone or mutate the
visionOS golden simulator:

```sh
# One-time per linked worktree, or pass LABSTREAM_SIM_PLATFORM=iphone for one command.
printf 'iphone\n' > .simplatform
SIMID=$(scripts/worktree-sim.sh id)   # resolves to .simid-iphone in this worktree
xcrun simctl boot "$SIMID" 2>/dev/null || true

scripts/xcodebuild-versioned.sh \
  -project Labstream.xcodeproj \
  -scheme LabstreamMobile \
  -destination "platform=iOS Simulator,id=$SIMID" \
  -configuration Debug \
  build CODE_SIGNING_ALLOWED=NO

APP=$(/bin/ls -td "$HOME"/Library/Developer/Xcode/DerivedData/Labstream-*/Build/Products/Debug-iphonesimulator/Labstream.app | head -1)
xcrun simctl install "$SIMID" "$APP"
xcrun simctl terminate "$SIMID" com.jlipworth.Labstream 2>/dev/null || true
xcrun simctl launch "$SIMID" com.jlipworth.Labstream
```

## Build and smoke on an iPad simulator

```sh
# One-time per linked worktree, or pass LABSTREAM_SIM_PLATFORM=ipad for one command.
printf 'ipad\n' > .simplatform
SIMID=$(scripts/worktree-sim.sh id)   # resolves to .simid-ipad in this worktree
xcrun simctl boot "$SIMID" 2>/dev/null || true

scripts/xcodebuild-versioned.sh \
  -project Labstream.xcodeproj \
  -scheme LabstreamMobile \
  -destination "platform=iOS Simulator,id=$SIMID" \
  -configuration Debug \
  build CODE_SIGNING_ALLOWED=NO

APP=$(/bin/ls -td "$HOME"/Library/Developer/Xcode/DerivedData/Labstream-*/Build/Products/Debug-iphonesimulator/Labstream.app | head -1)
xcrun simctl install "$SIMID" "$APP"
xcrun simctl terminate "$SIMID" com.jlipworth.Labstream 2>/dev/null || true
xcrun simctl launch "$SIMID" com.jlipworth.Labstream
```

A compatible installed iOS Simulator runtime is required. The mobile target is iOS/iPadOS
26.1+, so older local Xcode/SDK installations may report deployment-target warnings or fail
before app code compiles; install the matching platform/runtime in Xcode Settings before
treating the mobile target as broken.

## Install on a physical iPhone or iPad

Simulator builds use `CODE_SIGNING_ALLOWED=NO` and cannot install on hardware. For a real iPhone or iPad, use the mobile device wrapper; it builds the `LabstreamMobile` scheme for `iphoneos`, applies normal Apple Development signing/provisioning, installs with `devicectl`, and optionally launches the app:

```sh
scripts/deploy-mobile-to-device.sh            # build + install to the single paired iPhone/iPad
scripts/deploy-mobile-to-device.sh --launch   # also launch after install
scripts/deploy-mobile-to-device.sh --no-build # reinstall the last Debug-iphoneos build
```

If more than one iPhone/iPad is paired, pass the destination explicitly:

```sh
IOS_DEVICE_ID=<device-uuid> scripts/deploy-mobile-to-device.sh --launch
```

First-time hardware deploy still requires the one-time Apple steps outside the script: connect/pair the device, trust this Mac, enable Developer Mode on the device if prompted, and make sure the matching Apple ID is signed into Xcode Settings so command-line automatic provisioning can create or refresh the development profile.

## Remaining validation gaps

- Physical iPhone/iPad validation for PiP, AirPlay, Control Center/lock-screen Now
  Playing, background interruption behavior, and App Intents/Spotlight invocation.
- Physical-network validation for the cellular-download toggle and OS background-transfer
  scheduling. The code path is policy-wired, but real cellular behavior cannot be proven in
  an iOS simulator.
- Continued iPhone compact-width QA across signed-in Plex/Jellyfin/Emby libraries, music,
  offline rows, and long metadata titles.
- If App Store distribution is pursued, metadata/release work for the intended unified universal-purchase product.
