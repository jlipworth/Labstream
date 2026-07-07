# Development setup

This page is the shortest path from a clean checkout to a running Labstream build.

## Requirements

- macOS with Xcode and the visionOS SDK installed for the `Labstream` target.
- The iOS SDK and a compatible iOS/iPadOS Simulator runtime for the `LabstreamMobile` target.
- An Apple Vision Pro simulator runtime compatible with the project deployment target.
- Swift Package Manager for `PMSKit` tests.
- `uv` for the repo's Python tooling checks.

## Build and run in the visionOS simulator

Each worktree owns simulator IDs through `scripts/worktree-sim.sh`; use a concrete ID instead of `booted`. The visionOS path remains the default and uses a linked-worktree clone of the main worktree's golden simulator.

```sh
SIMID=$(scripts/worktree-sim.sh --platform visionos id)
xcrun simctl boot "$SIMID" 2>/dev/null || true

scripts/xcodebuild-versioned.sh \
  -project Labstream.xcodeproj \
  -scheme Labstream \
  -destination "platform=visionOS Simulator,id=$SIMID" \
  -configuration Debug \
  build CODE_SIGNING_ALLOWED=NO

APP=$(/bin/ls -td "$HOME"/Library/Developer/Xcode/DerivedData/Labstream-*/Build/Products/Debug-xrsimulator/Labstream.app | head -1)
xcrun simctl install "$SIMID" "$APP"
xcrun simctl terminate "$SIMID" com.jlipworth.Labstream 2>/dev/null || true
xcrun simctl launch "$SIMID" com.jlipworth.Labstream
```

## Build and run on an iPad simulator

The mobile target is named/schemed `LabstreamMobile` and builds a universal iPhone/iPad app whose displayed product name is still `Labstream`. Opt into an iPad simulator for the current linked worktree with either `LABSTREAM_SIM_PLATFORM=ipad`, `scripts/worktree-sim.sh --platform ipad ...`, or a gitignored `.simplatform` file.

```sh
printf 'ipad\n' > .simplatform
SIMID=$(scripts/worktree-sim.sh id)   # reads .simid-ipad for this worktree
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

If Xcode says the iOS platform/runtime is missing, install the matching iOS Simulator runtime in Xcode Settings. A newer beta simulator runtime may not be usable with an older installed iOS SDK.

Both app targets use `com.jlipworth.Labstream` for the intended unified product identity. Local installs with that bundle identifier can replace an existing install and its app state.

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

## Credentials and iCloud Keychain sync

The app persists its long-lived secrets in the Keychain (`Labstream/Auth/KeychainStore.swift`).
Exactly one item is stored as an iCloud-synchronizable Keychain item: the **Plex account token**.
Because all three variants (visionOS, iPhone, iPad) share the `com.jlipworth.Labstream` bundle id and
Keychain service string, a Plex sign-in on any one device signs the others in on their next launch.

Everything else is deliberately device-local:

- **Plex `clientIdentifier`** — generated once per install and never synced. Combined with a distinct
  `X-Plex-Device-Name` (see `Labstream/App/PlatformClientIdentity.swift`), every device presents a
  unique `X-Plex-Client-Identifier`, so the server still sees truly independent, per-device-identifiable
  sessions even though the token is shared. Syncing it would merge all devices into one server-side
  client identity, breaking per-device session listings and transcode bookkeeping.
- **Jellyfin/Emby access tokens** — those servers mint the access token bound to the device id
  presented at authentication (token and device are one server-side record). Syncing the token would
  make every physical device impersonate a single server-side device, causing session collisions,
  merged played-on attribution, and broken remote-control targeting. Jellyfin/Emby therefore still
  require a per-device sign-in; Quick Connect / Emby Connect keeps that to a short-code step.
- **Backend/server selection** — a per-device preference, not a credential.

Because the Plex token is the shared item, deleting it — a manual sign-out or a 401-triggered wipe —
propagates sign-out to **all** devices, which matches how an account-level token actually dies.
When a synced Plex token is successfully read, the app deletes any pre-sync device-local Plex token
so a later synced/global sign-out cannot re-promote stale local credentials.

Caveat for the simulator: simulator builds use `CODE_SIGNING_ALLOWED=NO` and cannot access the real
Keychain, so `KeychainStore` falls back to a file store. iCloud sync therefore only manifests on real
devices with iCloud Keychain enabled; you cannot observe cross-device sign-in in the simulator.

The type doc comment at the top of `KeychainStore.swift` is the source of truth for this behavior; keep
it and this section in agreement.

## Logs

```sh
SIMID=$(scripts/worktree-sim.sh --platform visionos id)
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
