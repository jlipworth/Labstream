# Development setup

This page is the shortest path from a clean checkout to a running Labstream build.

## Requirements

- macOS with Xcode and the visionOS SDK installed for the `Labstream` target.
- The iOS/iPadOS 26.1+ SDK/runtime for the `LabstreamMobile` target.
- macOS 26 on an Apple-silicon host when testing the optional `LabstreamMac` development preview.
- An Apple Vision Pro simulator runtime compatible with the project deployment target.
- Swift Package Manager for `PMSKit` tests.
- `uv` for the repo's Python tooling checks.

## Build and run in the visionOS simulator

Each worktree owns simulator IDs through `scripts/worktree-sim.sh`; use a concrete ID instead of `booted`. The visionOS path remains the default and uses a linked-worktree clone of the main worktree's golden simulator.

Provision the worktree's simulator once before resolving its ID. The command is idempotent:

```sh
scripts/worktree-sim.sh setup
```

```sh
SIMID=$(scripts/worktree-sim.sh --platform visionos id)
xcrun simctl boot "$SIMID" 2>/dev/null || true
DD="$PWD/build/DerivedData-visionos"
rm -rf "$DD/Build/Products/Debug-xrsimulator/Labstream.app"

scripts/xcodebuild-versioned.sh \
  -project Labstream.xcodeproj \
  -scheme Labstream \
  -destination "platform=visionOS Simulator,id=$SIMID" \
  -configuration Debug \
  -derivedDataPath "$DD" \
  build CODE_SIGNING_ALLOWED=NO

APP="$DD/Build/Products/Debug-xrsimulator/Labstream.app"
xcrun simctl install "$SIMID" "$APP"
xcrun simctl terminate "$SIMID" com.jlipworth.Labstream 2>/dev/null || true
xcrun simctl launch "$SIMID" com.jlipworth.Labstream
```

## Build and run on an iPhone simulator

The mobile target is named/schemed `LabstreamMobile` and builds a universal iPhone/iPad app whose displayed product name is still `Labstream`. Opt into an iPhone simulator for the current linked worktree with either `LABSTREAM_SIM_PLATFORM=iphone`, `scripts/worktree-sim.sh --platform iphone ...`, or a gitignored `.simplatform` file. Use `ipad` instead when you need the iPad variant.

```sh
printf 'iphone\n' > .simplatform
scripts/worktree-sim.sh setup
SIMID=$(scripts/worktree-sim.sh id)   # reads .simid-iphone for this worktree
xcrun simctl boot "$SIMID" 2>/dev/null || true
DD="$PWD/build/DerivedData-ios"
rm -rf "$DD/Build/Products/Debug-iphonesimulator/Labstream.app"

scripts/xcodebuild-versioned.sh \
  -project Labstream.xcodeproj \
  -scheme LabstreamMobile \
  -destination "platform=iOS Simulator,id=$SIMID" \
  -configuration Debug \
  -derivedDataPath "$DD" \
  build CODE_SIGNING_ALLOWED=NO

APP="$DD/Build/Products/Debug-iphonesimulator/Labstream.app"
xcrun simctl install "$SIMID" "$APP"
xcrun simctl terminate "$SIMID" com.jlipworth.Labstream 2>/dev/null || true
xcrun simctl launch "$SIMID" com.jlipworth.Labstream
```

For an iPad smoke, switch the worktree platform before resolving `$SIMID`:

```sh
printf 'ipad\n' > .simplatform
SIMID=$(scripts/worktree-sim.sh id)   # reads .simid-ipad for this worktree
```

If Xcode says the iOS platform/runtime is missing or warns that the mobile deployment target is newer than the installed SDK, install the matching iOS Simulator runtime/platform in Xcode Settings. A newer beta simulator runtime may not be usable with an older installed iOS SDK.

The visionOS and mobile targets use `com.jlipworth.Labstream` for the intended unified product
identity. Local installs with that bundle identifier can replace an existing install and its app
state.

## Build and run the macOS development preview

The `LabstreamMac` target runs directly on the Apple-silicon host; there is no Mac simulator lane.
Use the host helper so builds are staged under a per-worktree development identity:

```sh
scripts/deploy-macos-to-host.sh --launch
```

The Mac target is a local-build development preview, not a released or supported App Store
product. See [macOS development preview](MACOS.md) for identity isolation, cleanup, validation,
and deferred licensing/release decisions.

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

The development build uses the same bundle identifier as the intended App Store identity, so installing a local build can replace another installed build and its app state. If App Store/TestFlight distribution is used later, installing a development build over that build can clear the app container as a normal same-bundle-id replacement.

## Physical iPhone or iPad install

Use the mobile wrapper for a signed `iphoneos` build:

```sh
scripts/deploy-mobile-to-device.sh
scripts/deploy-mobile-to-device.sh --launch
scripts/deploy-mobile-to-device.sh --no-build
```

If more than one phone or tablet is paired, set `IOS_DEVICE_ID=<device-uuid>` explicitly. First
use still requires pairing/trust, Developer Mode, and the matching Apple ID in Xcode Settings.

## Credentials and iCloud Keychain sync

The app persists its long-lived secrets in the Keychain (`Labstream/Auth/KeychainStore.swift`).
Exactly one item is stored as an iCloud-synchronizable Keychain item: the **Plex account token**.
Because the supported visionOS, iPhone, and iPad variants share the
`com.jlipworth.Labstream` bundle id and Keychain service string, a Plex sign-in on any one device
signs the others in on their next launch. A canonical production-style Mac build uses that same
policy, but the normal per-worktree Mac development preview deliberately uses isolated,
backup-excluded credential storage instead; see [macOS development preview](MACOS.md).

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

## Verified platform findings

- **visionOS wake silently restarts custom-`Range` request bodies, and resume data cannot
  see it.** When a headset is re-worn, the network path re-evaluates and `nsurlsessiond`
  transparently retries the in-flight background task; because Labstream's static-range
  downloads carry a custom `Range` header, the retried body restarts from the range start
  with no error and no resume-data callback — the failure is invisible to the resume-data
  recovery path entirely. Observed signature: an app-diagnostics `reset_body_bytes` on the
  order of ~1 KB (i.e. the retried body barely got going again) even though gigabytes had
  already been buffered un-appended for that task. Contrast with an app-alive network switch
  on iPad, which surfaces as a normal task error WITH resume data and is recoverable through
  the existing resume-data path. Consequence: off-head durability for static-range downloads
  cannot rely on resume data alone, and per-chunk background wakes to checkpoint more often
  are not viable either — the OS background-relaunch rate limiter (exponential backoff, #212)
  stops granting wakes once a design needs one wake per bounded transfer, stalling overnight.
  The fix is a pre-queued train of closed-range segment tasks that `nsurlsessiond` executes
  without app involvement, bounding what a silent wake-time retry can destroy to one segment;
  see `docs/DOWNLOADS-OFFLINE.md` for the design.

## Documentation workflow

```sh
uv run --with-requirements requirements.txt mkdocs serve
uv run --with-requirements requirements.txt mkdocs build --strict
```

Keep public docs focused on the current release. Put research notes, implementation plans, old issue investigations, and one-off validation logs under `docs/archive/` or `docs/research/` instead of publishing them in the MkDocs navigation.
