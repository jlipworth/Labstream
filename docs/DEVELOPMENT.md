# Development setup

This page is the shortest path from a clean checkout to a running Labstream build.

## Requirements

- macOS with Xcode 27.1 (27A9275). It ships the iOS 27.1 SDK and the visionOS, tvOS, and macOS
  27.0 SDKs; see [the toolchain note](#build-for-an-iphone-or-ipad-simulator) below.
- Deployment targets (from `Labstream.xcodeproj`, not changed by the toolchain): visionOS 26.0,
  iOS/iPadOS 26.1, tvOS 26.0, and macOS 26.0. `PMSKit` declares the same iOS, tvOS, and visionOS
  floors; its own macOS floor is 15, below the Mac app target.
- An iOS Simulator runtime for the `LabstreamMobile` target; the iPhone Duo device type needs the
  iOS 27.1 runtime.
- An installed tvOS simulator runtime (27.0 with Xcode 27.1) for the `LabstreamTV` target.
- macOS 26 or later on an Apple-silicon host when testing the `LabstreamMac` target.
- A visionOS 26 or newer Apple Vision Pro simulator runtime compatible with the active Xcode
  (visionOS 27.0 with Xcode 27.1).
- Swift Package Manager for `PMSKit` tests (included with Xcode).
- Python 3.11+ and [`uv`](https://docs.astral.sh/uv/getting-started/installation/) for the repository's
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
Booted simulators are not free: obtain the current simulator lease, use only one
simulator at a time, shut it down before switching platforms, and release the lease
before another agent boots a simulator. Do not leave the golden visionOS simulator
booted while a linked-worktree simulator is running.

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
PLATFORM=iphone                    # ipad for the regular-width path; duo for the iPhone Duo foldable
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

`PLATFORM=duo` creates a `duowt-*` simulator from the `iPhone Duo`
(`com.apple.CoreSimulator.SimDeviceType.iPhone-Duo`) device type, which requires Xcode 27.1 and an
iOS 27.1 or later simulator runtime (`xcodebuild -downloadPlatform iOS`). The script never falls back
to a non-foldable iPhone for this platform. Simulator folding/unfolding is not proof of physical
iPhone Duo behavior; the hardware gate stays open.

Verified on Xcode 27.1 with the Duo simulator (2026-10-26):

- The iOS 27.1 simulator runtime supports only the iPhone Duo device type. iPhone and iPad
  worktree simulators are created on the newest runtime that lists their device type (iOS 27.0),
  which `scripts/worktree-sim.sh` selects automatically.
- `XCUIDevice.shared.orientation` changes the reported device orientation but never rotates the
  folded Duo app. Folded-landscape evidence uses the DEBUG `--ui-testing-orientation
  landscape-left|landscape-right` capture route (a scene geometry request).
- A plain `simctl io screenshot` targets the inner `LCD-1` display, which is black while folded.
  Capture the outer display by its UUID (`simctl io <id> enumerate`, the 1398x2034 port) and an
  `appResize` session with `--display=Resizable`.
- While `devicectl device appResize` has moved the app to the Resizable display, XCUITest still
  reports the outer-display window (466x678), so inner-size and resize-during-playback runs are
  judged from screenshots and `AppDiagnostics`, not XCUITest. The `appResize` session also uses
  horizontal bars, so the inner display's vertical bar is not reproduced.
- Setting `UISegmentedControl.appearance().selectedSegmentTintColor` turns the iOS 27.1 tab
  bar's selected item system blue (the accent is lost), so do not tint segmented pickers through
  the appearance proxy.

Xcode 27.1 (27A9275) is the required toolchain for every target. It ships the iOS 27.1 SDK, which
opts `LabstreamMobile` into the full iPhone Duo inner display and the vertical tab bar/toolbars on
the trailing edge. The visionOS, tvOS and macOS SDKs bundled with it remain 27.0. Every target
uses an unversioned `SDKROOT`, so the move is a toolchain change only; deployment targets are
unchanged. Duo-specific SwiftUI API (for example `toolbarVerticalEdge`) is `anyAppleOS 27.1`, so
shared code must guard it with `#if os(iOS)` and `if #available(iOS 27.1, *)` or the 27.0-SDK
targets stop compiling. The Duo UI lane is `duo-ui-smoke` in `scripts/native-test-matrix.py`
(`--duo-sim-id "$(scripts/worktree-sim.sh --platform duo id)"`).

All four production targets use `org.labstream.Labstream` on their respective platforms; ordinary
Mac host development is the documented exception and uses an isolated worktree identity. A
development install can replace another Labstream build
with the same bundle identifier on the same compatible device, but separate simulator devices and
operating-system platforms do not share or replace one another's app container or login state.

Debug mobile builds also accept the credential-free browse fixture described in the tvOS section
below. For a bounded agent smoke that builds, installs, launches, records screenshots/video/logs,
and shuts down the leased simulator, use:

```sh
# The visionOS runner requires the explicit one-simulator lease assertion.
scripts/agent-sim-run.sh launch-fixture-home-passive --allow-simulator
scripts/agent-mobile-run.sh iphone fixture-home-passive --allow-simulator
# Use `ipad` to exercise the regular-width layout.
```

The mobile and visionOS runners require `--allow-simulator` as an assertion that their caller owns
the repository's single-simulator lease. VisionOS evidence defaults to `artifacts/agent-sim-runs/`; mobile
and tvOS runner evidence defaults to `artifacts/agent-platform-runs/`. The fixture exposes stable accessibility targets including
`labstream.fixture.browse.root` and `labstream.home.fixture-resume.<backend>-orbit`, so Xcode 27
Device Interaction can inspect and drive it semantically rather than by free-form coordinates.

## Build for an Apple TV simulator

The tvOS release-candidate target is named/schemed `LabstreamTV`. It supports only the current Apple TV
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

Debug builds on every platform expose production-isolated launch arguments for deterministic UI
work. They never read or persist production credentials: `--ui-testing` starts signed out,
`--ui-testing-backend plex|jellyfin|emby` selects the authentication surface, and
`--ui-testing-fixture browse` supplies synthetic data to the real Home/Libraries/Detail views:

```sh
xcrun simctl launch "$SIMID" org.labstream.Labstream \
  --ui-testing --ui-testing-backend plex --ui-testing-fixture browse
```

`--ui-testing-fixture offline` (not tvOS) opens the restricted cold-launch Offline surface with no
server, so its navigation subtitle and Reconnect/Sign In/Settings toolbar can be screenshot-tested
headlessly. It shows whatever completed downloads exist in the simulator, or the empty state.

## Install and observe a simulator smoke

After either simulator build above, `$SIMID` and `$APP` identify the exact simulator and product.
Install that product, compare the installed executable with it, launch, inspect bounded logs, and
capture a screenshot:

```sh
xcrun simctl install "$SIMID" "$APP"
INSTALLED_APP=$(xcrun simctl get_app_container "$SIMID" org.labstream.Labstream app)
BUILT_UUID=$(xcrun dwarfdump --uuid "$APP/Labstream" | awk '{print $2}')
INSTALLED_UUID=$(xcrun dwarfdump --uuid "$INSTALLED_APP/Labstream" | awk '{print $2}')
[ "$BUILT_UUID" = "$INSTALLED_UUID" ] || {
  printf '%s\n' "Installed executable does not match $APP" >&2
  exit 1
}
printf '%s\n' "UUID_MATCH $BUILT_UUID"

xcrun simctl terminate "$SIMID" org.labstream.Labstream 2>/dev/null || true
xcrun simctl launch "$SIMID" org.labstream.Labstream
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

# Credential-free semantic mobile evidence (run one platform at a time under the lease).
scripts/agent-mobile-run.sh iphone fixture-detail-semantic --allow-simulator
scripts/agent-mobile-run.sh ipad fixture-detail-semantic --allow-simulator
```

Shutting down preserves the simulator and its app state. Do not use `teardown` for the main
worktree's golden visionOS simulator.

## Search matching and result identity

Search uses the server's retrieval capabilities: Plex `/hubs/search`, and Jellyfin/Emby
recursive `SearchTerm` requests scoped to each allowed user-view library (50 initial hits
per library, at most four library requests concurrently). The 300 ms debounce suppresses
requests while typing. No library download or alternate-query fanout is performed.

Each accepted response publishes its trimmed query, authenticated session identity, and
presentation groups together. During the next debounce, visible rows and MediaBrowser
**View All** continue to use the query that produced them. Clearing hides results immediately;
backend/session changes hide old results, and cancelled or superseded responses cannot publish.
Library discovery order, type sections, music navigation, and native search/keyboard controls
remain intact, including the existing command-F stack-reset policy.

Within each returned library/type section, shared title ranking folds case, diacritics and
width, treats punctuation as word separators, and ranks exact title, title prefix, all-word
prefix matches (any order), substring, then one-edit word matches. For example, `cafe moon`
ranks `Café—Moon` as exact; `pap moo` matches `Paper Moon`; `horizno`, `horizn`, and `horixon`
can rank `Horizon` through a transposition, deletion, or substitution. Typo matching requires
at least four query characters per fuzzy word and is bounded to 16 query words, 64 title
words, and 64 characters per fuzzy word. Equal title matches sort by normalized title then
item ID; non-title matches retain server relevance order. No returned hit is removed, since
servers may match people or other metadata. Rankings never move items across libraries/types.

These examples describe **ranking of returned hits**, not corpus-wide fuzzy recall. A server
may omit a typo, accent, punctuation, or prefix match before the app can rank it, and the
initial MediaBrowser page is limited and server-sorted. View All retains server pagination
and ordering. Reliable corpus-wide typo recall would need a backend-supported fuzzy query
or a separately designed, incremental, permission-scoped index; it must not be simulated by
fetching entire libraries or sending multiple queries on every keystroke. Live backend recall
and physical keyboard/headset behavior remain separate acceptance checks from fixture tests.

## Linked-worktree simulator cleanup

Linked worktrees own their `vpwt-*`, `iphonewt-*`, `duowt-*`, `ipadwt-*`, and `tvwt-*` simulators. Before removing a
linked worktree, delete all of its simulators and then remove the worktree:

```sh
scripts/worktree-sim.sh closeout /path/to/linked-worktree
git worktree remove /path/to/linked-worktree
```

`closeout` can be run from any remaining checkout of the repository. It tears down simulator state
for an existing linked worktree and prunes orphaned Labstream worktree simulators. If a worktree was
already removed, run `scripts/worktree-sim.sh prune` as the cleanup backstop. Neither command deletes
the main worktree's golden simulator.

The full merge-and-closeout procedure (rebase, validation, doc and plan lifecycle, issue status,
simulator and macOS host-app teardown, worktree removal, and branch deletion) is the
[`merge-worktree` skill](https://github.com/jlipworth/Labstream/blob/main/.claude/skills/merge-worktree/SKILL.md).

## Build and run the macOS target

The `LabstreamMac` target runs directly on the Apple-silicon host; there is no Mac simulator lane.
Use the host helper so builds are staged under a per-worktree development identity:

```sh
scripts/deploy-macos-to-host.sh --launch
```

The [macOS target guide](MACOS.md) owns identity isolation, the Debug-launcher local-network
workaround, the credential-free `agent-macos-run.sh` runner, display capability, cleanup,
validation, and release gates.

## Core validation commands

```sh
# Hermetic Swift package correctness; live probes remain separate and opt-in
swift test --package-path PMSKit --no-parallel --skip 'Live.*ProbeTests'

# Repository hygiene, redaction, and tooling tests
scripts/ci-hygiene.sh

# Documentation build
uv run --with-requirements requirements.txt mkdocs build --strict

# Validate repository links and anchors, including links in the rendered site.
# Run after the strict build so `site/` exists.
uv run python scripts/check-doc-links.py --site-dir site

# Validate that every published Mermaid fence rendered.
uv run python scripts/check-docs-mermaid.py
```

PMSKit geometry helpers and their tests conditionally import `CoreGraphics` where available;
Linux uses Foundation geometry types. Keep these helpers in the portable test lane rather than
excluding pose or player-arrangement coverage from Linux CI.

`PMSKit/Tests/PMSKitTests` is the portable package suite. App-owned deterministic tests live in
`LabstreamTests/` and are hosted by platform-specific Xcode test targets over the same test sources:

- `LabstreamTests`, selected by the `LabstreamMobile` scheme and `LabstreamTests.xctestplan`, runs
  on an iPhone/iPad simulator;
- `LabstreamMobileUITests`, selected by the same scheme/test plan, owns the credential-free
  semantic Home-to-detail regression used by the mobile agent loop;
- `LabstreamMacTests`, selected by the `LabstreamMac` scheme and
  `LabstreamMacTests.xctestplan`, runs on the macOS host;
- `LabstreamTVTests`, selected by `LabstreamTVTests.xctestplan`, runs the applicable shared app
  tests for tvOS while excluding the approved download-only exception;
  `LabstreamTVUITests.xctestplan` isolates deterministic authentication and the initial
  remote-only Home-to-detail browse journey so unrelated hosted sources cannot block UI execution.

On Xcode 27, a printed test-pass summary is not a completed hosted run: require the
terminal `xcodebuild` result and a readable `.xcresult`. If the runner stops making
progress, take a bounded process sample before termination. One observed iOS stall
was inside `collectSimulatorDiagnostics` / `simCtlDiagnose` after the test host exited.
A diagnostic repeat with `-collect-test-diagnostics never` can separate test execution
from that ancillary verbose-diagnostics collection; retain the original non-green run
and state the flag explicitly. It does not waive test failures, replace result bundles
or prove every runner hang has the same cause. The [P7 review-preparation evidence](https://github.com/jlipworth/Labstream/blob/main/docs/research/dv-p7-decoder-boundary.md#review-preparation-deterministic-replacement-and-persistence-barriers)
records the bounded observation and its limitations.

For a deterministic smoke, affected-platform, or full plan, use the checked
[`native-test-matrix.py`](TESTING-STRATEGY.md#native-apple-matrix-driver) driver. The commands below
remain the direct forms for an individually leased platform lane. Run the app suite for the
platform affected by a change (all three hosts — iOS, macOS, and tvOS — for shared app
infrastructure):

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
# Keep the unsigned host lane on the isolated development entitlements; the canonical Mac
# entitlements contain a keychain access group and require a development-signed build.
scripts/xcodebuild-versioned.sh -project Labstream.xcodeproj \
  -scheme LabstreamMac -testPlan LabstreamMacTests \
  -destination 'platform=macOS,arch=arm64' test CODE_SIGNING_ALLOWED=NO \
  CODE_SIGN_ENTITLEMENTS=Config/LabstreamMacDevelopment.entitlements

# tvOS test build (works with the SDK even before a runtime is installed).
scripts/xcodebuild-versioned.sh -project Labstream.xcodeproj \
  -scheme LabstreamTV -testPlan LabstreamTVTests \
  -destination 'generic/platform=tvOS Simulator' build-for-testing CODE_SIGNING_ALLOWED=NO

# tvOS unit and UI suites (requires the worktree's concrete tvOS simulator).
scripts/worktree-sim.sh --platform tvos setup
SIMID=$(scripts/worktree-sim.sh --platform tvos id)
xcrun simctl boot "$SIMID" 2>/dev/null || true
scripts/xcodebuild-versioned.sh -project Labstream.xcodeproj \
  -scheme LabstreamTV -testPlan LabstreamTVTests \
  -destination "platform=tvOS Simulator,id=$SIMID" \
  -only-testing:LabstreamTVTests test CODE_SIGNING_ALLOWED=NO -enableCodeCoverage NO
scripts/xcodebuild-versioned.sh -project Labstream.xcodeproj \
  -scheme LabstreamTV -testPlan LabstreamTVUITests \
  -destination "platform=tvOS Simulator,id=$SIMID" \
  -only-testing:LabstreamTVUITests test CODE_SIGNING_ALLOWED=NO -enableCodeCoverage NO

# Credential-free TV evidence wrappers.
scripts/agent-tvos-run.sh fixture-home-semantic --allow-simulator
scripts/agent-tvos-run.sh fixture-player-basic --allow-simulator
xcrun simctl shutdown "$SIMID"
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
scripts/deploy-to-device.sh --no-build # reinstall this worktree's last Debug-xros build
scripts/deploy-to-device.sh --verbose  # show full device/team IDs for troubleshooting
```

The wrapper builds into the worktree-local `build/DerivedData-device-visionos`, wiping it before
every build, and installs only that exact `Debug-xros/Labstream.app`. It never deletes or installs
another worktree's product or anything in Xcode's global DerivedData; `--no-build` fails if this
worktree has no device build yet. Each build stamps the internal Build ID through
`scripts/build-version-args.sh`.

If several visionOS devices are paired, select one with
`VP_DEVICE_ID=<device-uuid> scripts/deploy-to-device.sh --launch`. The script normally derives the
development team from the Apple Development certificate; `VP_DEVELOPMENT_TEAM=<team-id>` is the
explicit override.

A certificate visible to `security find-identity -p codesigning -v` is not sufficient by itself for
command-line automatic provisioning. If the build reports `No Account for Team` or that no profile
for `org.labstream.Labstream` was found, sign the matching Apple ID into Xcode Settings and rerun the
script. For the first install, opening the project in Xcode, choosing the paired headset, and running
the `Labstream` scheme once is also a valid way to let Xcode finish interactive registration and
provisioning.

An `unavailable` headset usually needs to be woken, worn, and returned to the same Wi-Fi as the Mac.
Developer Mode and trust prompts must be completed on the headset; the deploy script cannot perform
those steps.

The development build uses the same bundle identifier as the intended App Store identity, so a local
install can replace another installed build and its app state. Development provisioning profiles can
also expire. By default the wrapper deletes matching short-lived (14 days or less) development
profiles before building so Xcode fetches a fresh one, prints the embedded profile's lifetime, and
refuses to install a short-lived profile with fewer than six days remaining. Set
`VP_REFRESH_SHORT_DEV_PROFILES=0` to skip the pruning. If the refusal persists, confirm the Apple ID
is signed into Xcode, or use the Ad Hoc wrapper below.

For an install that must outlive a development provisioning profile (for example, offline use away
from the development Mac), use TestFlight (see the
[`testflight-deploy` skill](https://github.com/jlipworth/Labstream/blob/main/.claude/skills/testflight-deploy/SKILL.md))
or the distribution-signed Ad Hoc wrapper instead. It requires an Apple
Distribution certificate and a non-expired Ad Hoc provisioning profile that includes the headset's UDID:

```sh
scripts/deploy-ad-hoc-to-device.sh                 # distribution-signed build + install
scripts/deploy-ad-hoc-to-device.sh --launch        # also launch
scripts/deploy-ad-hoc-to-device.sh --list-profiles # inspect installed Ad Hoc profiles
scripts/deploy-ad-hoc-to-device.sh --profile "<name-or-uuid>"
```

Select a device or team explicitly with VP_DEVICE_ID, VP_DISTRIBUTION_TEAM, or
VP_AD_HOC_PROFILE_SPECIFIER when the defaults are ambiguous.

## Physical iPhone or iPad install

Use the mobile wrapper for a signed `iphoneos` build:

```sh
scripts/deploy-mobile-to-device.sh
scripts/deploy-mobile-to-device.sh --launch
scripts/deploy-mobile-to-device.sh --no-build # reinstall this worktree's last Debug-iphoneos build
scripts/deploy-mobile-to-device.sh --verbose  # show full device/team IDs for troubleshooting
```

If more than one phone or tablet is paired, set `IOS_DEVICE_ID=<device-uuid>` (alias
`MOBILE_DEVICE_ID`) explicitly. The signing team is derived from the Apple Development certificate;
`IOS_DEVELOPMENT_TEAM=<team-id>` (alias `MOBILE_DEVELOPMENT_TEAM`) is the explicit override. Like
the visionOS wrapper, it builds into a worktree-local path (`build/DerivedData-device-ios`), wiping
it first so no stale `Debug-iphoneos/Labstream.app` survives, stamps the internal Build ID through
`scripts/build-version-args.sh`, installs only that worktree's exact product, prunes matching short-lived development profiles before building
(`IOS_REFRESH_SHORT_DEV_PROFILES=0` opts out) and refuses to install a short-lived profile with
fewer than six days remaining; use TestFlight for longer-lived installs. First use still requires
pairing/trust, Developer Mode, and the matching Apple ID in Xcode Settings. As with the headset, a
`No Account for Team` or missing-profile error means that Apple ID is not signed into Xcode
Settings > Accounts; installing once from Xcode is also a valid first-install path.

## Credentials and iCloud Keychain sync

Which credentials sync through iCloud Keychain, and why the rest stay device-local, is documented
in [Persistence](PERSISTENCE.md#icloud-keychain-sync).

## Logs

```sh
SIMID=$(scripts/worktree-sim.sh --platform visionos id)
xcrun simctl spawn "$SIMID" log show --last 10m --info --debug \
  --predicate 'subsystem == "org.labstream.Labstream"'
```

## Verified platform findings

These are live-verified platform and backend behaviors that are easy to re-learn the hard way.
Where a current topic page owns the invariant, the bullet points there instead of repeating it.

### visionOS UI hit-testing

- **Never put a custom `ButtonStyle` on a poster/card link or picker row; use `.cardLink()`.**
  On visionOS any custom `ButtonStyle` registers the link's gaze/hover hit region displaced
  (measured at about 1.35× scaled about the window center), so pinches on edge cards and rows
  route to a neighbor (card N opens card N+1; center cards hide the pattern). Live bisection
  proved the style is the cause: lazy-to-plain stacks, padding-to-`contentMargins`, and dropping
  `scrollClipDisabled` or the hover lift changed nothing, and it is not fixable inside the style
  (`contentShape(.hoverEffect, …)`, `hoverEffect(.highlight)`, or removing the press scale still
  misroute). Built-in styles register correctly; `.cardLink()` in `DesignSystem.swift` wraps
  `.plain` plus a `contentShape(.hoverEffect, …)` that shapes the automatic highlight.
- **Inset lazy rails and pickers with `.contentMargins(…, for: .scrollContent)`, not `.padding`.**
  Padding the lazy content puts the inset into the cards' own geometry and shifts their
  gaze/hit shapes; content margins keep it outside. `mediaRailScrollStyle(horizontalMargin:)`
  applies this for browse rails.
- **Gaze hover is rendered out of process.** `.onHover` never fires for gaze, so the app cannot
  observe hover. Diagnose pinch routing by logging a
  `.simultaneousGesture(SpatialTapGesture(coordinateSpace: .global))` instead. In the simulator,
  sweeping in from the left can expand the leading tab ornament, whose region may eat the first
  click (`MRUIFeedbackTypeCircularButtonTouchDown` in the log); that effect is simulator-only.
- **One main window plus Cinema.** visionOS browsing uses one `WindowGroup`, with video presented
  over it; Cinema is the only other scene (an `ImmersiveSpace`) and may reopen the main window on
  exit. Do not add unrelated secondary windows. Cinema ownership, its measured-`visualBounds`
  attachment scaling, and exit routing are in
  [Playback architecture](PLAYBACK-ARCHITECTURE.md#cinema-ownership).
- **The music mini player has no volume control and a passive progress line.** The Digital Crown
  and system volume own loudness, so an `AVPlayer` slider would diverge from it; a 3-pt drag target
  violates the 60-pt gaze minimum, so scrubbing lives in Now Playing.

### Simulator testing and app state

- **Test AVFoundation playback inside the app process.** A standalone binary run with
  `xcrun simctl spawn` can load an asset, but its `AVPlayerItem` never reaches `.readyToPlay`
  because it lacks the playback environment, so every file falsely times out. Use a `#if DEBUG`,
  launch-argument-gated in-app probe (see `Labstream/Shared/Debug/`), place test files in the app's
  data container (`xcrun simctl get_app_container "$SIMID" org.labstream.Labstream data`), and read
  results from the log.
- **Install source decides whether app state survives.** Installing over the same bundle ID
  preserves the app container and sign-in. Deleting the app, erasing the simulator, or replacing
  an App Store build with a development build starts fresh and requires signing in again. Unsigned
  simulator builds persist credentials through the DEBUG file fallback described in
  [Persistence](PERSISTENCE.md#keychain).

### Playback

- **The system ⓘ Info card ignores string dates.** Without an override it shows the stream's
  creation year after the runtime, which for a live transcode is the current year. Only
  `.commonIdentifierCreationDate` with an **`NSDate`-typed** value (January 1 of the release year)
  works; string values under it and the QuickTime, ID3, and iTunes date identifiers were proven
  ignored live. Title and description work as strings; cap the description near 150 characters or
  it pushes the title off the card.
- **Play can beat the metadata backfill.** Listing payloads omit chapters and markers, and the
  detail screen backfills them asynchronously, so the player must not depend on the caller's copy:
  `PlaybackController.loadChaptersIfNeeded()` fetches full metadata (chapters, markers, and
  audio streams), re-derives Skip Intro/Credits ranges, and the chrome re-installs its info tabs
  when they arrive.
- **The Plex profile name, transcode stop-before-restart, restart budgets, MediaBrowser progress,
  and Emby encoder cleanup** are load-bearing invariants owned by
  [Playback architecture](PLAYBACK-ARCHITECTURE.md); network loss as a stall rather than a
  `.failed` item is covered under
  [Buffering and stalls](PLAYBACK-ARCHITECTURE.md#buffering-and-stalls).
- **PMS transcodes race ahead, then throttle.** The universal transcoder encodes faster than real
  time until it is `TranscoderThrottleBuffer` seconds ahead of the playhead (default 60 s;
  "throttled" is the healthy state) and prunes spent segments behind `TranscoderPruneBuffer`
  (default 300 s). The realized forward buffer is limited by AVPlayer, not PMS: raising
  `preferredForwardBufferDuration` beyond the server's lead buys nothing on a live transcode.
- **A segment request outside the produced window respawns PMS's encoder.** PMS starts a new
  FFmpeg job at that offset (`-ss <offset>`) instead of fast-forwarding, and AVPlayer fetches
  segments autonomously while scrubbing, so client restraint alone cannot prevent stacked
  encoders. One starved-scrub session stacked 21 jobs in about a minute and exhausted server
  memory. This is why out-of-buffer seeks are debounced and budgeted.
- **PMS HLS media playlists cover the full timeline with absolute-time segment names and PTS.**
  Segment `0NNNNN.ts` is absolute second NNNNN in every session. A session primed at an offset
  serves real MPEG-TS only from that offset forward; earlier segments are 188-byte PAT-only stubs,
  which is why a deep seek on a primed session stalls. Splicing segments from a second session
  without reloading the item was tried and removed after it drove retry storms.
- **macOS display scaling can gate HDR eligibility.** A bounded macOS 27 beta display check found
  that default scaling exposed a stable HDR switch where a higher scaled mode did not. Enabling HDR
  made AVPlayer eligible and raised potential EDR above 1; lowering refresh alone did not. This is
  host-specific capability evidence, not proof of rendered HDR, a universal scaling restriction, or
  a cable diagnosis. Restore temporary display modes and HDR settings after tests; keep
  per-player-screen and physical mixed-display acceptance separate (see
  [macOS display capability](MACOS.md#live-display-capability)).

### Backends and downloads

Download correctness uses the [P-phase pin suites](TESTING-STRATEGY.md#downloads-overhaul-pin-suites).
The `macos-hosted` matrix lane runs deterministic app-level downloads without a simulator. Keep
one Xcode lane active and use the normal manifest/parallelism for the full combined gate; focused
serial diagnosis does not close that gate. Product smokes and live/device acceptance remain
separate. tvOS builds shared policies/player code but no Downloads capability.

- **Emby stream URLs carry the access token as an `api_key` query value.** Besides the
  `Authorization: Emby …` and `X-Emby-Token` headers, server-generated HLS and direct-stream URLs
  embed the token, so any logged Emby URL must have `api_key` (and `X-Emby-Token`) redacted. Emby
  PlaybackInfo also needs `UserId` in both the query and the body, with `AutoOpenLiveStream:false`.
  The authorization-scheme and base-path rules are in [Backends](BACKENDS.md).
- **Plex ignores `If-Range`.** A ranged GET with a non-matching `If-Range` (ETag or date form)
  still returns 206 from the requested offset, even though Plex emits a strong ETag and
  `Last-Modified`. Emby honors a strong-ETag `If-Range` and Jellyfin honors the date form. Range
  resume therefore relies on a bounded per-body validator-equality check, not on `If-Range`; see
  [Downloads and offline playback](DOWNLOADS-OFFLINE.md#background-downloads-and-sleeping-devices).
- **Emby Convert (persistent server conversion) wire facts, verified against Emby 4.9.3:**
  - a converted copy appears as an extra `File` media source on the same item, and PlaybackInfo
    returns only the requested source when `MediaSourceId` is supplied, so enumerating existing
    versions needs a PlaybackInfo call without it;
  - convert to `originalmediafolder`; `originalmediafolderreplace` replaces the original and must
    never be used;
  - `POST /Sync/Jobs` returns the job nested under `"Job"`, while `GET /Sync/Jobs/{id}` returns it
    at the top level (`EmbyConvertRequest.decodeCreatedJob` versus `decodeJob`);
  - Emby ignores the submitted job name, so a job is identified and cancelled only by its
    persisted ID;
  - job `Progress` stays at 0 until completion, so a preparing row shows indeterminate
    "Preparing on server…" rather than a percentage;
  - the `tv` profile scales to the requested bitrate and caps at 1080p; true 4K needs
    `profile:"custom"`, which requires container, video-codec, and audio-codec criteria (HTTP 400
    without them) and has no resolution field;
  - a Sync job cannot select a media source, so a repeat convert can transcode an earlier derived
    copy; the download path reuses a matching converted source instead of creating a new job.
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
publishing changes. Where each document belongs (published topic pages versus the unpublished
plan, research, evidence, and archive lanes) is defined in
[Documentation information architecture](CONTRIBUTING.md#documentation-information-architecture).
The current manual validation matrix deliberately remains at the repository root in
[`TESTING-CHECKLIST.md`](https://github.com/jlipworth/Labstream/blob/main/TESTING-CHECKLIST.md).

## Required-reason privacy manifest packaging

Two source manifests define the contract: the shared
`Labstream/Shared/Resources/PrivacyInfo.xcprivacy` (visionOS, iOS/iPadOS, and macOS) and the tvOS
copy `Labstream/Platforms/tvOS/Resources/PrivacyInfo.xcprivacy`. The tvOS copy must stay identical
except that it omits the `CrashData` collected-data entry; edit both together. Both declare the
required-reason APIs `SystemBootTime` (`35F9.1`), `UserDefaults` (`CA92.1`), `FileTimestamp`
(`DDA9.1`), and `DiskSpace` (`85F4.1`), with no tracking.

`SystemBootTime` reason `35F9.1` covers in-app elapsed-time and timer calculations, including
PMSKit's statically linked media-session retry budget. Raw uptime and boot-relative sample
timestamps must stay on device. Apple's exception permits information about elapsed time between
in-app events to leave the device; it does not permit arbitrary uptime-derived identifiers or boot
epochs. Re-audit new diagnostic/export/network fields before changing this contract. The source audit is retained at
`docs/evidence/audits/2026-09-15-privacy-uptime-audit.md` (unpublished evidence).

`uv run python scripts/check-privacy-manifest.py` checks both declarations, the approved
collected-data mapping, every target's synchronized-resource membership, and the tvOS target's
membership exception that excludes the shared manifest in favor of its own copy; repository
hygiene runs its regression tests.

`scripts/testflight-release.py validate` already runs this check against the archived apps when
all four platform archives are present. For an ad hoc check of built products, build each scheme
in Release into a one-off path with `scripts/xcodebuild-versioned.sh ... -configuration Release
-derivedDataPath build/DerivedData-privacy-<platform> build CODE_SIGNING_ALLOWED=NO`, run the
command below, then delete those `build/DerivedData-privacy-*` directories:

```sh
uv run python scripts/check-privacy-manifest.py \
  --app Labstream=build/DerivedData-privacy-visionos/Build/Products/Release-xrsimulator/Labstream.app \
  --app LabstreamMobile=build/DerivedData-privacy-ios/Build/Products/Release-iphonesimulator/Labstream.app \
  --app LabstreamTV=build/DerivedData-privacy-tvos/Build/Products/Release-appletvsimulator/Labstream.app \
  --app LabstreamMac=build/DerivedData-privacy-macos/Build/Products/Release/Labstream.app
```

The checker requires all four products, compares their app-level manifests with
source, and parses every nested manifest. This is **not** Apple's aggregate privacy
report or signed archive validation. For each exact signed Release archive, inspect
the archived app and dependency manifests and generate/review Xcode's privacy report
before release. Keep that gate open when only unsigned builds were inspected.
Required-reason API declarations do not settle App Store collection disclosures.

## Workflow status and review evidence

Use `python3 scripts/workspace-status.py` to recover local worktree/branch state and
GitHub PR references and explicit issue-number candidates from recent commit subjects.
These references are candidates, not proof of remaining work. `--offline` skips GitHub; `--issue N` includes the complete issue
and its comments in JSON output, with outstanding body checklist items labelled as
reported rather than authoritative. Release excerpts are repository records, not live
App Store Connect state. The command never fetches, checks out, pulls, merges or writes
remote state. Failed or incomplete API inventories are errors, not proof of no work.

For duplicate discovery, use `python3 scripts/issues.py find home navigation` or
`python3 scripts/issues.py show 417`. The finder combines all open issues with issues
closed in the last 90 days (`--closed-days`), ranks title/body matches, and searches
comments for additional candidates. It retrieves full comments for the selected results.
Use `--json` before the subcommand for structured output. These tools use the current
`gh` login and issue only GET requests; they never file, comment on, or close an issue.

Wait on the exact commit after an authorized push:

```sh
python3 scripts/ci-wait.py --commit HEAD --branch my-branch
python3 scripts/ci-wait.py --commit HEAD --branch my-branch --require ci/woodpecker/push/hygiene --require ci/woodpecker/push/pmskit --require ci/woodpecker/push/docs
```

The default required contexts are the Woodpecker push hygiene and PMSKit checks. Explicit
`--require` options replace that set. Add docs or other contexts when required by the change.
The waiter reads GitHub's mirrored statuses/checks rather than a Woodpecker token. It does
not independently verify the upstream event type. It refuses branch-head drift rather than
substituting a newer commit. Missing checks remain pending; skipped, neutral and cancelled
checks are unverified. Exit codes: 0 passed, 1 failed, 2 API/usage error, 3 unverified or
branch drift, 4 pending at timeout (or `--once`). No remote pipeline is restarted.

### Shared Xcode host lease

`scripts/xcodebuild-versioned.sh` acquires an OS-backed lock for the Xcode command.
The four `agent-*-run.sh` platform runners hold the same lease across build, install,
UI work and teardown. Nested calls reuse an inherited descriptor; the bounded runner
and native matrix preserve it. This supplements, rather than replaces, simulator
identity and sole-booted checks. Manually booted simulators still need the usual lease
coordination; commands bypassing these wrappers do not participate.

```sh
python3 scripts/xcodebuild-lease.py status
python3 scripts/xcodebuild-lease.py run --lane manual-verification --wait-timeout 300 -- scripts/agent-macos-run.sh fixture-detail
```

The default lock is per-user at `~/.cache/labstream/xcode.lease`, shared by all worktrees.
`--lock PATH` (or `LABSTREAM_XCODE_LEASE_PATH`) isolates tests; use the same path in every
cooperating process. Exit 75 means the wait timed out. Stale metadata is not an active
lease: the kernel lock decides ownership. Never delete a lock file to break a live lease.
The runner forwards an interrupted command through normal process-group cleanup and
releases the lock on exit; status does not reveal command arguments or credentials.

### Receipts, checkpoints and review findings

`scripts/workflow-state.py` records local evidence references in ignored
`build/workflow/state.json`; `--file PATH` selects an explicit alternative store outside the repository or under a
gitignored path, so the receipt never hashes its own changes.
Keep the store private and preserve it with required artifacts before worktree removal.
A source fingerprint includes HEAD plus tracked/untracked edits, so a receipt becomes stale
when the source changes. `show` also flags stale checkpoints and stale verified findings;
the latter reappear in `pending_review` without changing their historical disposition.
Finding history retains each resolution commit and evidence path when reopened. A receipt is a human/agent claim with evidence, not proof a command
ran successfully. Inspect the named log/result and distinguish simulation from hardware.

```sh
python3 scripts/workflow-state.py receipt validation --name hygiene --status passed --evidence build/hygiene.log
python3 scripts/workflow-state.py receipt docs --name development-guide --status passed --evidence docs/DEVELOPMENT.md
python3 scripts/workflow-state.py receipt docs --name no-user-visible-change --status not-needed --note 'Internal refactor only; existing behavior remains accurate'
python3 scripts/workflow-state.py checkpoint --goal 'Finish review' --base main --issue 123 --next-action 'Review F2 and inspect Mac smoke' --authorized 'Local edits and tests' --gate 'Physical headset check'
python3 scripts/workflow-state.py finding add F2 --summary 'Stale callback replaces newer state' --severity high
python3 scripts/workflow-state.py finding set F2 --status fixed --commit HEAD --note 'Generation guard added'
python3 scripts/workflow-state.py show
```

Stable finding IDs survive review rounds. `fixed` means awaiting review; `verified`
requires an existing evidence file and a resolution commit reachable from current HEAD.
Reopened, rejected or deferred findings retain their history. Authorization fields record
existing user decisions, never grant permission. The mirrored `merge-worktree` and
`review-ledger` skills use these records without changing push, merge or issue-close gates.

## Experimental headless signal measurement

For the bounded routine command, optional codec/channel sweeps, inventory coverage,
and result interpretation, use [Headless playback testing](HEADLESS-PLAYBACK-TESTING.md).
`uv run scripts/playback-regression.py run` packages the generated-fixture and
standalone-host checks without starting a simulator.

The headless audio/video signal experiment (repository notes:
`docs/research/HEADLESS-AV-SIGNAL-LAB.md`) generates local H.264/AAC HLS fixtures and captures decoded audio/video from a
Debug-only visionOS 27 AVPlayer probe or standalone macOS 27 run-loop host. It needs
no server authentication. `uv run scripts/playback-signal-lab.py run-host` compiles a
small host around the shared capture method; with an `NSApplication` event loop,
AVPlayer advanced and delivered audio/video without a window or simulator. Six
controlled clean/defect cases passed the detector suite on that host. This is not a
LabstreamMac application acceptance run. Use it to
investigate capture methods and deliberately injected signal defects; it does not
establish backend playback acceptance, physical audio output, or HDR accuracy.
Direct pixel-buffer copying avoids the first-use Core Image stall observed in the
initial experiment. Keep simulator runs serialized and all generated evidence private.

The experimental codec sweep is `uv run scripts/playback-signal-matrix.py generate`
followed by `uv run scripts/playback-signal-matrix.py run`. It requires the six-case
detector suite to pass before testing fourteen generated SDR/stereo HLS combinations.
Its private manifest fingerprints the media; results distinguish generation/capture
failures from signal mismatches and preserve explicit untested codec families.


Set `SIGNAL_LAB_AUDIO_TAP=1` for the host suite to require a second audio check through
an OS-27 mixed-track audio tap. It captures player-mix samples, not speakers. Use
`scripts/playback-signal-compare.py` to compare pre/post-effects measurements and
fixture controls; API timing offsets remain unresolved, so these results do not
establish absolute A/V synchronization. The research notes retain observed limitations.


For 5.1 tone fixtures and separately measured stereo downmixes, use
`uv run scripts/playback-multichannel-lab.py generate` then `run`. The runner verifies
encoded fixtures with FFmpeg and retains unverified channel layouts as explicit
non-passing outcomes. See the research notes for current codec/packaging limits.

On visionOS 27 or macOS 27, admitted backend playback scenarios may add
`--vp-probe-observe-signals <UUID>` to capture their existing controller player at
initial and post-scenario points. The observer never starts, pauses, seeks or replaces
the player item and does not install an audio-mix tap. Private output goes to
`Documents/ProbeSignalCaptures/<UUID>/`. Summarize a copied capture using
`uv run scripts/playback-observation-report.py <directory> --run-id <UUID>`;
coverage and audio levels are evidence, not a quality verdict for unknown content.
