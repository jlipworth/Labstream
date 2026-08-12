# tvOS development target

`LabstreamTV` is Labstream's native streaming-only Apple TV target. It is an active development
target, not a released or supported App Store product. Simulator builds and deterministic TV tests
are available; physical-device, complete backend parity, accessibility, system-integration,
performance, TestFlight, and release acceptance remain open.

## Current product boundary

The target provides a five-tab ten-foot shell for Home, Libraries, Search, Music, and Settings.
It reuses the app-owned `PlaybackController` and custom AVFoundation player rather than introducing
an `AVPlayerViewController` playback stack. TV-specific focus and Siri Remote behavior adapts that
player for couch-distance use while preserving the shared playback, progress, retry, and server
cleanup authorities.

Downloads and offline playback are an explicit platform exception. The tvOS product contains no
Offline tab, download actions, download-storage settings, background download session, migration,
or recovery startup. This is enforced structurally rather than by constructing disabled download
objects.

## Source and capability ownership

The tvOS app compiles:

- `Labstream/Shared/` for the universal app core, backend facades, player, music, and shared UI;
- `Labstream/Platforms/tvOS/` for the app entry point and production-isolated Debug fixtures; and
- `PMSKit` for reusable Plex, Jellyfin, and Emby requests, models, and policies.

It does **not** compile `Labstream/Capabilities/Downloads/` or another platform's owner root.
visionOS Cinema and SharePlay are likewise absent from the TV product. Shared files may still use
small inline platform branches for genuine presentation or framework differences; whole-platform
ownership belongs in the matching platform root.

## Build and test

Install a compatible tvOS simulator runtime, then use the worktree-owned Apple TV simulator. Never
target an arbitrary `booted` simulator:

```sh
scripts/worktree-sim.sh --platform tvos setup
SIMID=$(scripts/worktree-sim.sh --platform tvos id)
xcrun simctl boot "$SIMID" 2>/dev/null || true
DD="$PWD/build/DerivedData-tvos"
rm -rf "$DD"

scripts/xcodebuild-versioned.sh \
  -project Labstream.xcodeproj \
  -scheme LabstreamTV \
  -destination "platform=tvOS Simulator,id=$SIMID" \
  -configuration Debug \
  -derivedDataPath "$DD" \
  build CODE_SIGNING_ALLOWED=NO
```

The native matrix driver is the source of truth for the affected and full test lanes:

```sh
scripts/native-test-matrix.py affected --base main --include-working-tree
scripts/native-test-matrix.py full
```

Execution is lane-at-a-time and requires the repository's one-simulator lease. The driver reports
the focused hosted and UI lanes, while [Development setup](DEVELOPMENT.md#build-for-an-apple-tv-simulator)
contains the direct build, install, launch, fixture, test, and shutdown commands.

For complete agent-readable evidence, use the named wrapper after acquiring that lease:

```sh
scripts/agent-tvos-run.sh fixture-home-semantic --allow-simulator
scripts/agent-tvos-run.sh fixture-player-basic --allow-simulator
```

The first scenario uses semantic XCTest targets and `XCUIRemote` for Home-to-detail navigation.
The second uses the deterministic local-file player fixture, so it reveals playback chrome and then
closes the media session within one test without backend credentials. Both preserve video,
screenshots, bounded logs, an
`.xcresult`, exported XCTest attachments, `test-summary.json`, and `run.json`, then shut down their
worktree simulator by default.

On Xcode 27, the local-player XCTest assertions can complete successfully while
`xcodebuild` remains stuck finalizing the test log. The wrapper caps that phase at 90 seconds and
reports `blocked` with `xcodebuild-test-log-finalization-timeout` rather than misclassifying the
completed assertions as a product failure or claiming an incomplete result bundle as a pass.

## Deterministic fixtures

Debug-only launch arguments provide production-isolated signed-out and synthetic browse fixtures.
They do not read or persist production credentials:

```sh
xcrun simctl launch "$SIMID" com.jlipworth.Labstream \
  --ui-testing --ui-testing-backend plex --ui-testing-fixture browse
```

`LabstreamTVUITests.xctestplan` isolates the UI target from hosted test sources that may not belong
to tvOS's streaming-only compile boundary. The small UI smoke tier covers launch and the
fixture-backed remote Home-to-detail journey.
Exhaustive focus, keyboard, player auto-hide/scrubbing, and menu traversal belong to the full TV
lane. Raw input evidence swizzling remains explicit opt-in and is never part of an ordinary launch
or Release build.

## What simulator evidence cannot prove

A green simulator build or UI suite does not establish physical Siri Remote behavior, native
keyboard/dictation, HDR or Dolby Vision rendering, HDMI/audio routing, interruptions, lifecycle,
long-play memory/energy/thermal behavior, accessibility, signing, TestFlight, or App Store readiness.
Run and record those cells on physical Apple TV hardware before making a product or release claim.

Use the repository [manual validation checklist](https://github.com/jlipworth/Labstream/blob/main/TESTING-CHECKLIST.md)
for current platform gates and [Testing strategy](TESTING-STRATEGY.md) for evidence tiers.
