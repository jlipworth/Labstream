# Development setup

This page is the shortest path from a clean checkout to a running Labstream build.

## Requirements

- macOS with Xcode and the visionOS SDK installed for the `Labstream` target.
- The iOS/iPadOS 26.1+ SDK/runtime for the `LabstreamMobile` target.
- The tvOS 26+ SDK and an installed tvOS simulator runtime for the in-progress `LabstreamTV` target.
- macOS 26 on an Apple-silicon host when testing the optional `LabstreamMac` development preview.
- A visionOS 26 or newer Apple Vision Pro simulator runtime compatible with the active Xcode.
- Swift Package Manager for `PMSKit` tests (included with Xcode).
- Python 3 and [`uv`](https://docs.astral.sh/uv/getting-started/installation/) for the repository's
  documentation and Python tooling checks.

## Bootstrap the first visionOS simulator

Simulator IDs are machine-local and gitignored. A brand-new main checkout therefore has no `.simid`,
and `scripts/worktree-sim.sh setup` cannot create the main worktree's initial visionOS simulator by
itself. From the repository root, run this bootstrap once. It selects a usable existing simulator,
preferring the newest compatible installed visionOS runtime, or creates a dedicated
`Labstream Golden` simulator on the newest compatible runtime when none is available. It then
validates the selected UDID and records it as the main worktree's golden simulator:

```sh
if [ ! -s .simid ]; then
  SIMID=$(xcrun simctl list devices available -j | python3 -c '
import json, re, sys
data = json.load(sys.stdin).get("devices", {})
def version(runtime):
    return tuple(int(n) for n in re.findall(r"\d+", runtime))
for runtime in sorted(data, key=version, reverse=True):
    if ".SimRuntime.xrOS-" not in runtime or version(runtime) < (26, 0):
        continue
    devices = data[runtime]
    preferred = [d for d in devices if d.get("name") == "Labstream Golden"]
    standard = [d for d in devices if d.get("name", "").startswith("Apple Vision Pro")]
    other = [d for d in devices if not d.get("name", "").startswith("vpwt-")]
    for device in preferred + standard + other:
        if device.get("isAvailable", True):
            print(device["udid"])
            raise SystemExit(0)
')

  if [ -z "$SIMID" ]; then
    RUNTIME=$(xcrun simctl list runtimes -j | python3 -c '
import json, re, sys
def version(runtime):
    return tuple(int(n) for n in re.findall(r"\d+", runtime.get("version", runtime.get("name", ""))))
runtimes = [r for r in json.load(sys.stdin).get("runtimes", [])
            if r.get("isAvailable", True)
            and ".SimRuntime.xrOS-" in r.get("identifier", "")
            and version(r) >= (26, 0)]
runtimes.sort(key=version, reverse=True)
if runtimes:
    print(runtimes[0]["identifier"])
')
    [ -n "$RUNTIME" ] || { printf '%s\n' "No compatible visionOS 26+ simulator runtime is installed." >&2; exit 1; }
    DEVICE_TYPES_FILE=$(mktemp "${TMPDIR:-/tmp}/labstream-device-types.XXXXXX") || exit 1
    xcrun simctl list devicetypes -j | python3 -c '
import json, sys
for device in json.load(sys.stdin).get("devicetypes", []):
    if device.get("isAvailable", True) and device.get("name", "").startswith("Apple Vision Pro"):
        print(device["identifier"])
' > "$DEVICE_TYPES_FILE"
    [ -s "$DEVICE_TYPES_FILE" ] || {
      rm -f "$DEVICE_TYPES_FILE"
      printf '%s\n' "No Apple Vision Pro simulator device type is installed." >&2
      exit 1
    }
    SIMID=""
    while IFS= read -r DEVICE_TYPE; do
      if SIMID=$(xcrun simctl create "Labstream Golden" "$DEVICE_TYPE" "$RUNTIME" 2>/dev/null); then
        break
      fi
      SIMID=""
    done < "$DEVICE_TYPES_FILE"
    rm -f "$DEVICE_TYPES_FILE"
    [ -n "$SIMID" ] || { printf '%s\n' "No Apple Vision Pro device type supports $RUNTIME." >&2; exit 1; }
  fi

  printf '%s\n' "$SIMID" > .simid
fi

SIMID=$(tr -d '[:space:]' < .simid)
xcrun simctl list devices -j | python3 -c '
import json, re, sys
udid = sys.argv[1]
def version(runtime):
    return tuple(int(n) for n in re.findall(r"\d+", runtime))
for runtime, devices in json.load(sys.stdin).get("devices", {}).items():
    if ".SimRuntime.xrOS-" in runtime and version(runtime) >= (26, 0):
        for device in devices:
            if device.get("udid") == udid and device.get("isAvailable", True):
                raise SystemExit(0)
raise SystemExit(f".simid does not name an available visionOS 26+ simulator: {udid}")
' "$SIMID"

scripts/worktree-sim.sh --platform visionos setup
```

If the bootstrap reports that no compatible runtime or device type is installed, add a visionOS 26+
Simulator runtime in Xcode Settings, then rerun it. If validation rejects a stale `.simid`, remove
that file and rerun the bootstrap. A newly created simulator has no Labstream credentials; sign in
through the app after the first launch when your test requires backend data. Do not commit `.simid`.

After the main checkout is initialized, `scripts/worktree-sim.sh` owns the lifecycle. A linked
worktree gets a shutdown clone of the main simulator when you run:

```sh
scripts/worktree-sim.sh --platform visionos setup
```

Always resolve a concrete UDID with the script rather than targeting `booted`.

## Build for the visionOS simulator

Use a dedicated DerivedData directory and remove it before a verification build. That makes the
product named by `$APP` unambiguous and ensures the subsequent install uses this build rather than
another checkout's product:

```sh
scripts/worktree-sim.sh --platform visionos setup
SIMID=$(scripts/worktree-sim.sh --platform visionos id)
xcrun simctl boot "$SIMID" 2>/dev/null || true
DD="$PWD/build/DerivedData-visionos"
rm -rf "$DD"

scripts/xcodebuild-versioned.sh \
  -project Labstream.xcodeproj \
  -scheme Labstream \
  -destination "platform=visionOS Simulator,id=$SIMID" \
  -configuration Debug \
  -derivedDataPath "$DD" \
  build CODE_SIGNING_ALLOWED=NO

APP="$DD/Build/Products/Debug-xrsimulator/Labstream.app"
test -x "$APP/Labstream"
```

Continue with [Install and observe a simulator smoke](#install-and-observe-a-simulator-smoke).

## Build for an iPhone or iPad simulator

The mobile target is named/schemed `LabstreamMobile` and builds one universal iPhone/iPad app whose
displayed product name is still `Labstream`. Unlike visionOS, the script can create a fresh iPhone
or iPad simulator without a pre-existing golden simulator. Select the platform explicitly; a
`.simplatform` file is optional convenience, not a prerequisite:

```sh
PLATFORM=iphone                    # change to ipad for the regular-width path
scripts/worktree-sim.sh --platform "$PLATFORM" setup
SIMID=$(scripts/worktree-sim.sh --platform "$PLATFORM" id)
xcrun simctl boot "$SIMID" 2>/dev/null || true
DD="$PWD/build/DerivedData-ios-$PLATFORM"
rm -rf "$DD"

scripts/xcodebuild-versioned.sh \
  -project Labstream.xcodeproj \
  -scheme LabstreamMobile \
  -destination "platform=iOS Simulator,id=$SIMID" \
  -configuration Debug \
  -derivedDataPath "$DD" \
  build CODE_SIGNING_ALLOWED=NO

APP="$DD/Build/Products/Debug-iphonesimulator/Labstream.app"
test -x "$APP/Labstream"
```

If Xcode says the iOS platform/runtime is missing or warns that the deployment target is newer than
the installed SDK, install the matching iOS Simulator runtime/platform in Xcode Settings. A newer
simulator runtime may not be usable with an older installed iOS SDK.

The visionOS and mobile targets use `com.jlipworth.Labstream` for the intended unified product
identity. Local installs with that bundle identifier can replace an existing install and its app
state.

## Build for an Apple TV simulator

The in-progress tvOS target is named/schemed `LabstreamTV`. It supports only the current Apple TV
4K third-generation simulator types; the helper intentionally does not fall back to older Apple TV
hardware. Unlike visionOS, tvOS creates a fresh shutdown simulator rather than cloning the Vision
Pro golden simulator:

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

APP="$DD/Build/Products/Debug-appletvsimulator/Labstream.app"
test -x "$APP/Labstream"
```

If `worktree-sim.sh` reports `no available tvOS simulator runtime found`, install the matching tvOS
runtime in Xcode Settings. The SDK alone can still prove the compile foundation with a generic
destination, but it cannot satisfy the launch/smoke gate:

```sh
scripts/xcodebuild-versioned.sh -project Labstream.xcodeproj -scheme LabstreamTV \
  -destination 'generic/platform=tvOS Simulator' \
  -derivedDataPath "$PWD/build/DerivedData-tvos-generic" \
  build CODE_SIGNING_ALLOWED=NO
```

Continue with [Install and observe a simulator smoke](#install-and-observe-a-simulator-smoke) only
when a concrete tvOS simulator runtime and `$SIMID` are available. The tvOS product deliberately has
no downloads, Offline destination, or download-storage settings.

## Install and observe a simulator smoke

After either simulator build above, `$SIMID` and `$APP` identify the exact simulator and product.
Install that product, compare the installed executable with it, launch, inspect bounded logs, and
capture a screenshot:

```sh
xcrun simctl install "$SIMID" "$APP"
INSTALLED_APP=$(xcrun simctl get_app_container "$SIMID" com.jlipworth.Labstream app)
BUILT_UUID=$(xcrun dwarfdump --uuid "$APP/Labstream" | cut -d' ' -f2)
INSTALLED_UUID=$(xcrun dwarfdump --uuid "$INSTALLED_APP/Labstream" | cut -d' ' -f2)
[ "$BUILT_UUID" = "$INSTALLED_UUID" ] || {
  printf '%s\n' "Installed executable does not match $APP" >&2
  exit 1
}
printf '%s\n' "UUID_MATCH $BUILT_UUID"

xcrun simctl terminate "$SIMID" com.jlipworth.Labstream 2>/dev/null || true
xcrun simctl launch "$SIMID" com.jlipworth.Labstream
sleep 3
xcrun simctl spawn "$SIMID" log show --last 2m \
  --predicate 'process == "Labstream"' | tail -120
mkdir -p build
xcrun simctl io "$SIMID" screenshot build/labstream-smoke.png
```

A passing smoke is observable, not just a successful build: `simctl launch` prints a process ID;
the bounded log has no crash, `fatalError`, or assertion for the changed area; and
`build/labstream-smoke.png` shows the expected app surface. A fresh simulator normally shows sign-in,
while a previously configured simulator should reach its browse UI. Inspect the PNG locally and do
not publish screenshots that expose server or media details.

Shut the simulator down as soon as the check finishes:

```sh
xcrun simctl shutdown "$SIMID"
```

Shutting down preserves the simulator and its app state. Do not use `teardown` for the main
worktree's golden visionOS simulator.

## Linked-worktree simulator cleanup

Linked worktrees own their `vpwt-*`, `iphonewt-*`, `ipadwt-*`, and `tvwt-*` simulators. Before removing a
linked worktree, delete all of its simulators and then remove the worktree:

```sh
scripts/worktree-sim.sh closeout /path/to/linked-worktree
git worktree remove /path/to/linked-worktree
```

`closeout` can be run from any remaining checkout of the repository. It tears down simulator state
for an existing linked worktree and prunes orphaned Labstream worktree simulators. If a worktree was
already removed, run `scripts/worktree-sim.sh prune` as the cleanup backstop. Neither command deletes
the main worktree's golden simulator.

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

`PMSKit/Tests/PMSKitTests` is the portable package suite. App-owned deterministic tests live in
`LabstreamTests/` and are hosted by platform-specific Xcode test targets over the same test sources:

- `LabstreamTests`, selected by the `LabstreamMobile` scheme and `LabstreamTests.xctestplan`, runs
  on an iPhone/iPad simulator;
- `LabstreamMacTests`, selected by the `LabstreamMac` scheme and
  `LabstreamMacTests.xctestplan`, runs on the macOS host;
- `LabstreamTVTests`, selected together with `LabstreamTVUITests` by the `LabstreamTV` scheme and
  `LabstreamTVTests.xctestplan`, compiles the shared app tests for tvOS. The initial UI target is a
  launch harness; focus/remote fixtures remain part of the active tvOS implementation plan.

Run the app suite for the platform affected by a change (both for shared app infrastructure):

```sh
# Mobile-hosted app tests.
scripts/worktree-sim.sh --platform iphone setup
SIMID=$(scripts/worktree-sim.sh --platform iphone id)
xcrun simctl boot "$SIMID" 2>/dev/null || true
scripts/xcodebuild-versioned.sh -project Labstream.xcodeproj \
  -scheme LabstreamMobile -testPlan LabstreamTests \
  -destination "platform=iOS Simulator,id=$SIMID" test CODE_SIGNING_ALLOWED=NO
xcrun simctl shutdown "$SIMID"

# Mac-hosted app tests.
scripts/xcodebuild-versioned.sh -project Labstream.xcodeproj \
  -scheme LabstreamMac -testPlan LabstreamMacTests \
  -destination 'platform=macOS,arch=arm64' test CODE_SIGNING_ALLOWED=NO

# tvOS test build (works with the SDK even before a runtime is installed).
scripts/xcodebuild-versioned.sh -project Labstream.xcodeproj \
  -scheme LabstreamTV -testPlan LabstreamTVTests \
  -destination 'generic/platform=tvOS Simulator' build-for-testing CODE_SIGNING_ALLOWED=NO
```

The shared app suites are host-app unit tests, not live-server acceptance tests. Keep policy and
wire-format logic in PMSKit tests; use the app suites for app-owned persistence/filesystem,
credential adapters, lifecycle coordination, playback ownership, and other platform integration
seams. Running the tvOS tests and UI launch harness requires a concrete tvOS simulator runtime.

## Physical Apple Vision Pro install

Simulator builds are unsigned and cannot install on hardware. Complete Apple's one-time device and
signing setup before using the repository wrapper:

1. Update the headset and Xcode to mutually compatible visionOS versions.
2. On Apple Vision Pro, enable Developer Mode in **Settings > Privacy & Security > Developer Mode**
   and restart the headset if prompted.
3. Keep the Mac and headset on the same Wi-Fi, then open **Xcode > Window > Devices and
   Simulators**. Select the discovered Apple Vision Pro, choose **Pair**, and enter or confirm the
   pairing code on the headset. Accept any trust prompt. The headset must be awake and worn for
   discovery, install, and launch.
4. In **Xcode > Settings > Accounts**, sign in with the Apple ID that belongs to the development
   team. Allow Xcode to create an Apple Development certificate if the account has none.
5. Confirm that CoreDevice can see an available headset:

   ```sh
   xcrun devicectl list devices
   ```

Use the wrapper rather than re-deriving device destinations, signing-team IDs, provisioning, build
locations, or install commands:

```sh
scripts/deploy-to-device.sh            # signed Debug-xros build + install
scripts/deploy-to-device.sh --launch   # also launch while the headset is awake/worn
scripts/deploy-to-device.sh --no-build # reinstall the last Debug-xros build
scripts/deploy-to-device.sh --verbose  # show full device/team IDs for troubleshooting
```

If several visionOS devices are paired, select one with
`VP_DEVICE_ID=<device-uuid> scripts/deploy-to-device.sh --launch`. The script normally derives the
development team from the Apple Development certificate; `VP_DEVELOPMENT_TEAM=<team-id>` is the
explicit override.

A certificate visible to `security find-identity -p codesigning -v` is not sufficient by itself for
command-line automatic provisioning. If the build reports `No Account for Team` or that no profile
for `com.jlipworth.Labstream` was found, sign the matching Apple ID into Xcode Settings and rerun the
script. For the first install, opening the project in Xcode, choosing the paired headset, and running
the `Labstream` scheme once is also a valid way to let Xcode finish interactive registration and
provisioning.

An `unavailable` headset usually needs to be woken, worn, and returned to the same Wi-Fi as the Mac.
Developer Mode and trust prompts must be completed on the headset; the deploy script cannot perform
those steps.

The development build uses the same bundle identifier as the intended App Store identity, so a local
install can replace another installed build and its app state. Development provisioning profiles can
also expire; review the profile lifetime printed by the wrapper before relying on an offline install.

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
  --predicate 'subsystem == "com.jlipworth.Labstream"'
```

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

Preview the published site locally with:

```sh
uv run --with-requirements requirements.txt mkdocs serve
```

Use the strict documentation build in [Core validation commands](#core-validation-commands) before
publishing changes. Keep current product, architecture, and contributor guidance in the published
Markdown files at the top of `docs/`. Classify repository-internal documents into these unpublished
lanes:

- `docs/plans/` for active implementation plans and acceptance journals;
- `docs/research/` for unresolved investigations;
- `docs/evidence/` for immutable audit and profiling observations; and
- `docs/archive/` for completed, superseded, or closed context that is never canonical.

The current manual validation matrix deliberately remains at the repository root in
[`TESTING-CHECKLIST.md`](https://github.com/jlipworth/Labstream/blob/main/TESTING-CHECKLIST.md).
Each lane README defines its naming and promotion/archive rules. Preserve historical prose when
moving snapshots, but repair live links, navigation, includes, and script references.
