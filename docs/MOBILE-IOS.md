# iOS and iPadOS target

Labstream has two native Apple app targets:

| Target / scheme | Platforms | Product name | Bundle identifier |
| --- | --- | --- | --- |
| `Labstream` | visionOS / visionOS Simulator | `Labstream` | `com.jlipworth.Labstream` |
| `LabstreamMobile` | iOS, iPadOS, and iOS Simulator | `Labstream` | `com.jlipworth.Labstream` |

`LabstreamMobile` is the first native iPhone/iPad implementation slice. It shares the app source tree and `PMSKit` package with the visionOS target, but uses a mobile app entry point and a mobile shell:

- One adaptive shell for iPhone and iPad: a `TabView` with `.tabViewStyle(.sidebarAdaptable)` renders the Liquid Glass floating tab bar in compact widths and a real sidebar on iPad. Search uses the system `.search` tab role, the tab bar minimizes on scroll, and the music mini player rides `.tabViewBottomAccessory` (the iOS 26 transport idiom).
- Controls that float over media (player chrome platters and free-floating buttons) use Liquid Glass on iOS via the `labstream*` helpers in `Labstream/UI/DesignSystem.swift`; visionOS keeps its proven `glassBackgroundEffect`/material look.
- The app icon set is seeded from the existing Labstream artwork as `MobileAppIcon`.
- The Plex client identity reports `X-Plex-Platform=iOS` and `X-Plex-Device` as `iPad` or `iPhone`; visionOS continues to report `visionOS` / `Apple Vision Pro`.

## Build and smoke on an iPad simulator

Use a platform-specific worktree simulator so the iPad build does not clone or mutate the visionOS golden simulator:

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

A compatible installed iOS Simulator runtime is required. If Xcode reports that the installed iOS platform/runtime is missing or incompatible, install the matching iOS simulator runtime in Xcode Settings before treating the mobile build as failed.

## Known remaining mobile work

The first milestone is a buildable native iPhone/iPad target with a real app shell. These product behaviors still need dedicated follow-up validation/implementation before calling the mobile app feature-complete:

- Picture in Picture, AirPlay, Now Playing / lock-screen controls, and other mobile media-background expectations.
- Final iOS/iPadOS background-download and cellular-download policy UX. Default cellular downloads should stay conservative until explicitly implemented and tested.
- Mobile-specific Spotlight/Siri/App Intents behavior. System entry routing remains scoped to the active backend/session, matching the no-offline-sync decision.
- Detailed iPhone layout polish beyond the compact tab shell, plus complete iPad interaction QA.
- App Store metadata/release work for the intended unified universal-purchase product.
