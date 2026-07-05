# Development setup

This page is the shortest path from a clean checkout to a running Labstream build.

## Requirements

- macOS with Xcode and the visionOS SDK installed.
- An Apple Vision Pro simulator runtime compatible with the project deployment target.
- Swift Package Manager for `PMSKit` tests.
- `uv` for the repo's Python tooling checks.

## Build and run in the simulator

Each worktree owns a simulator ID through `scripts/worktree-sim.sh`; use that ID instead of `booted`.

```sh
SIMID=$(scripts/worktree-sim.sh id)
xcrun simctl boot "$SIMID" 2>/dev/null || true

scripts/xcodebuild-versioned.sh \
  -project Labstream.xcodeproj \
  -scheme Labstream \
  -destination "platform=visionOS Simulator,id=$SIMID" \
  -configuration Debug \
  build CODE_SIGNING_ALLOWED=NO

APP=$(/bin/ls -td "$HOME"/Library/Developer/Xcode/DerivedData/Labstream-*/Build/Products/Debug-xrsimulator/Labstream.app | head -1)
xcrun simctl install "$SIMID" "$APP"
xcrun simctl terminate "$SIMID" com.jlipworth.VisionPlay 2>/dev/null || true
xcrun simctl launch "$SIMID" com.jlipworth.VisionPlay
```

The bundle identifier remains `com.jlipworth.VisionPlay` for compatibility with existing app identity, stored credentials, downloads, and simulator/device state.

## Core validation commands

```sh
# Pure Swift package tests
cd PMSKit && swift test

# Repository hygiene, redaction, and tooling tests
cd ..
scripts/ci-hygiene.sh

# Documentation build
uv run --with-requirements requirements.txt mkdocs build --strict
```

## Physical Apple Vision Pro install

Use the wrapper script rather than re-deriving signing details:

```sh
scripts/deploy-to-device.sh            # build + install
scripts/deploy-to-device.sh --launch   # install and launch while the headset is awake/worn
scripts/deploy-to-device.sh --no-build # reinstall the last build
```

The development build uses the same bundle identifier as the App Store identity, so installing a local build can replace another installed build and its app state.

## Logs

```sh
SIMID=$(scripts/worktree-sim.sh id)
xcrun simctl spawn "$SIMID" log show --last 10m --info --debug \
  --predicate 'subsystem == "com.jlipworth.Labstream" OR subsystem == "com.jlipworth.VisionPlay"'
```

Some compatibility subsystems still log under `com.jlipworth.VisionPlay`; new diagnostics use `com.jlipworth.Labstream`.

## Documentation workflow

```sh
uv run --with-requirements requirements.txt mkdocs serve
uv run --with-requirements requirements.txt mkdocs build --strict
```

Keep public docs focused on the current release. Put research notes, implementation plans, old issue investigations, and one-off validation logs under `docs/archive/` or `docs/research/` instead of publishing them in the MkDocs navigation.
