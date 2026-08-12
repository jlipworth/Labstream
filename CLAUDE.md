# Labstream (Labstream) — Claude Code notes

Apple-platform Plex/Jellyfin/Emby client. App code in `Labstream/`, networking/model
layer in `PMSKit/` (local Swift package with its own tests). The primary shipping path is
still visionOS, and the repo also contains the `LabstreamMobile` universal iOS/iPadOS
target, the in-development streaming-only `LabstreamTV` target, and a native `LabstreamMac`
development preview. `docs/DEVELOPMENT.md` covers
build/run setup; current player ownership and the load-bearing startup, stall,
seek/restart, cleanup, HDR/DV, and Cinema invariants live in
`docs/PLAYBACK-ARCHITECTURE.md`. Archived development notes are historical context only.

## Build / install / test loop

```sh
# This worktree's simulator. In the main worktree this resolves to the golden
# sim recorded in <main>/.simid; in a linked worktree it's that worktree's own cloned sim (see
# "Worktree simulators" below). It may be Shutdown — boot it first.
SIMID=$(scripts/worktree-sim.sh --platform visionos id)
xcrun simctl boot "$SIMID" 2>/dev/null || true   # no-op if already booted

# Build (simulator UDID may differ; `xcrun simctl list devices booted` to check).
# ⚠️ LINK-SKIP TRAP (bit us live): after a source edit xcodebuild may recompile the .o
# but SKIP the Ld step — exit 0, no new binary, and the "fix" you then install is the OLD
# app. Guard every fix build: delete the .app product first, and verify afterwards that
# the binary mtime is fresh (and matches the installed copy via
# `xcrun simctl get_app_container "$SIMID" com.jlipworth.Labstream app`).
# ⚠️ DETERMINISTIC LC_UUID (don't be fooled): this project emits a content-INDEPENDENT
# Mach-O UUID — two different builds (even a real source change) produce the IDENTICAL
# `dwarfdump --uuid`, and even a full clean rebuild reuses it. So a cross-build UUID
# comparison CANNOT detect a stale binary, and grepping the binary for a changed string
# is unreliable (Swift literal storage). The only thing that proves the Ld step ran is a
# FULL clean-DerivedData build (`rm -rf …/DerivedData/Labstream-*`) with exit 0 — there
# is no incremental link to skip — plus a fresh product mtime. The UUID diff below is
# still valid for ONE thing: confirming the INSTALLED copy == the copy you just built
# (same build → same UUID), i.e. the STALE-PROCESS/wrong-install guard, NOT staleness vs
# the source.
# Use a worktree-local DerivedData path; never delete or select another worktree's product.
DD="$PWD/build/DerivedData-visionos"
rm -rf "$DD"
scripts/xcodebuild-versioned.sh -project Labstream.xcodeproj -scheme Labstream \
  -destination "platform=visionOS Simulator,id=$SIMID" \
  -configuration Debug -derivedDataPath "$DD" build CODE_SIGNING_ALLOWED=NO -quiet

# Install + relaunch on this worktree's simulator (upgrade in place — login survives).
# Install only the exact product from this worktree-local DerivedData path.
APP="$DD/Build/Products/Debug-xrsimulator/Labstream.app"
xcrun simctl install "$SIMID" "$APP"
xcrun simctl terminate "$SIMID" com.jlipworth.Labstream; xcrun simctl launch "$SIMID" com.jlipworth.Labstream

# Hermetic PMSKit correctness (live probes are always opt-in and excluded here)
swift test --package-path PMSKit --no-parallel --skip 'Live.*ProbeTests'
```

New Swift files are picked up automatically (file-system-synchronized groups) — never
edit the pbxproj to add one.

### Building the native iPad/iPhone target

The mobile app target/scheme is `LabstreamMobile`; its product/display name is
`Labstream` and it shares the bundle id `com.jlipworth.Labstream`.

```sh
printf 'iphone\n' > .simplatform # gitignored per-worktree default; use ipad for iPad smoke
SIMID=$(scripts/worktree-sim.sh id)
xcrun simctl boot "$SIMID" 2>/dev/null || true

DD="$PWD/build/DerivedData-mobile"
rm -rf "$DD"
scripts/xcodebuild-versioned.sh -project Labstream.xcodeproj -scheme LabstreamMobile \
  -destination "platform=iOS Simulator,id=$SIMID" \
  -configuration Debug -derivedDataPath "$DD" build CODE_SIGNING_ALLOWED=NO -quiet

APP="$DD/Build/Products/Debug-iphonesimulator/Labstream.app"
xcrun simctl install "$SIMID" "$APP"
xcrun simctl terminate "$SIMID" com.jlipworth.Labstream 2>/dev/null || true
xcrun simctl launch "$SIMID" com.jlipworth.Labstream
```

Mobile simulator builds require an iOS Simulator runtime compatible with the installed
iOS SDK. If Xcode reports the iOS platform/runtime is missing, install the matching
runtime in Xcode Settings before treating `LabstreamMobile` as broken.

### Building the native Apple TV target

The in-development tvOS target/scheme is `LabstreamTV`. It owns a streaming-only TV shell;
the Downloads capability, Offline destination, and download-storage settings are absent at
compile time. Use the exact worktree Apple TV simulator rather than a generic `booted` device:

```sh
scripts/worktree-sim.sh --platform tvos setup
SIMID=$(scripts/worktree-sim.sh --platform tvos id)
xcrun simctl boot "$SIMID" 2>/dev/null || true
DD="$PWD/build/DerivedData-tvos"
rm -rf "$DD"

scripts/xcodebuild-versioned.sh -project Labstream.xcodeproj -scheme LabstreamTV \
  -destination "platform=tvOS Simulator,id=$SIMID" -configuration Debug \
  -derivedDataPath "$DD" build CODE_SIGNING_ALLOWED=NO
```

The complete install, launch, fixture, test, and shutdown procedures live in
`docs/DEVELOPMENT.md` and `docs/TVOS.md`. Simulator evidence does not close physical Siri
Remote, HDR/audio/HDMI, lifecycle, accessibility, performance, or release gates.

### Installing on a physical iPhone or iPad (device testing)

The mobile simulator flow builds with `CODE_SIGNING_ALLOWED=NO`, which will NOT install
on hardware. A real iPhone/iPad needs a code-signed **iphoneos** device build (product
lands in `Debug-iphoneos`, NOT `Debug-iphonesimulator`):

```sh
scripts/deploy-mobile-to-device.sh            # build (signed, version-stamped) + install
scripts/deploy-mobile-to-device.sh --launch   # also launch after install
scripts/deploy-mobile-to-device.sh --no-build # reinstall last iOS device build without rebuilding
scripts/deploy-mobile-to-device.sh --verbose  # show full device/team IDs instead of masked IDs
```

If both an iPad and iPhone are paired, set `IOS_DEVICE_ID=<uuid>` (or
`MOBILE_DEVICE_ID=<uuid>`) so the script targets the intended device. The script uses the
`LabstreamMobile` scheme, derives the signing team from the Apple Development certificate
OU unless `IOS_DEVELOPMENT_TEAM` is set, deletes stale `Debug-iphoneos/Labstream.app`
products before building, and stamps the internal Build ID via
`scripts/build-version-args.sh`.

First hardware deploy still needs the user's one-time setup: connect/pair the device,
trust this Mac, enable Developer Mode on-device if prompted, and sign the matching Apple
ID into Xcode Settings ▸ Accounts so CLI automatic provisioning works.

### Installing on a physical Vision Pro (device testing)

The simulator flow above builds with `CODE_SIGNING_ALLOWED=NO`, which will NOT install on
hardware. A real headset needs a code-signed **device** build (product lands in
`Debug-xros`, NOT `Debug-xrsimulator`):

```sh
scripts/deploy-to-device.sh            # build (signed, version-stamped) + install
scripts/deploy-to-device.sh --launch   # also launch (headset must be awake/worn)
scripts/deploy-to-device.sh --no-build # reinstall last device build without rebuilding
scripts/deploy-to-device.sh --verbose  # show full device/team IDs instead of masked IDs
```

Headset must show available/paired — "unavailable" usually means asleep/off-network.
Wake it, put it on the SAME Wi-Fi as this Mac, enable Developer Mode
(Settings > Privacy & Security > Developer Mode), and trust this Mac. The script derives
the Vision Pro identifier from `devicectl`, the signing team from the certificate OU,
deletes the stale `Debug-xros/Labstream.app` product before building, and stamps the
internal Build ID via `scripts/build-version-args.sh`.

⚠️ **RECURRING SIGNING GOTCHA (hit often).** A command-line device build fails with
`error: No Account for Team "<id>"` / `No profiles for 'com.jlipworth.Labstream' were found`
**even though** `security find-identity -p codesigning -v` shows a valid "Apple Development"
cert. The keychain cert alone is NOT enough for CLI automatic provisioning — Xcode must have
the matching Apple ID **account** signed in (Xcode → Settings → Accounts → + → Apple ID).
**Claude cannot do this** (it needs the user's credentials), so when it surfaces, the fix is
the user's to perform. Two paths:
- **User signs the account into Xcode once**, then Claude re-runs the `xcodebuild` above.
- **User installs straight from Xcode** (open the project, pick the headset, Run) — Xcode
  signs interactively and is the most reliable path for a first device install.

Device testing is otherwise the USER's half (the headset is the device-only gate); Claude
owns the build/install command once signing is unblocked.

### Verification expectation — a green build is NOT "done"

Compiling is necessary but not sufficient. Any time you change app code — yourself OR via
a workflow / subagent — use `scripts/native-test-matrix.py affected` to identify the affected
targets, then headlessly verify the applicable product actually *runs* on **this worktree's own
simulator** (or through the isolated Mac host path). Resolve the selected platform with
`scripts/worktree-sim.sh id` or `--platform visionos|iphone|ipad|tvos`; boot it first because
worktree simulators are created Shutdown, and never target `booted`. The command below is the
minimum visionOS smoke; use the exact mobile/tvOS equivalents in `docs/DEVELOPMENT.md` for those
products. Claude self-serves this passive half of the live-testing workflow—do not ask the user
to do it:

```sh
SIMID=$(scripts/worktree-sim.sh --platform visionos id)
xcrun simctl boot "$SIMID" 2>/dev/null || true
DD="$PWD/build/DerivedData-visionos"
APP="$DD/Build/Products/Debug-xrsimulator/Labstream.app"
xcrun simctl install "$SIMID" "$APP"
# install guard (see STALE-PROCESS trap): installed UUID must match the build you just made.
# NOTE: LC_UUID is deterministic here (see DETERMINISTIC LC_UUID above), so this proves
# install==build, NOT that the binary is newer than your source edit — a clean build is what
# proves the latter. dwarfdump prints full paths (which differ), so compare only the UUID token.
B=$(xcrun dwarfdump --uuid "$APP/Labstream" | awk '{print $2}')
I=$(xcrun dwarfdump --uuid "$(xcrun simctl get_app_container "$SIMID" com.jlipworth.Labstream app)/Labstream" | awk '{print $2}')
[ "$B" = "$I" ] && echo UUID_MATCH || echo "UUID_MISMATCH built=$B installed=$I"
xcrun simctl terminate "$SIMID" com.jlipworth.Labstream 2>/dev/null || true
xcrun simctl launch "$SIMID" com.jlipworth.Labstream
xcrun simctl spawn "$SIMID" log show --last 2m --predicate 'process == "Labstream"' | tail -120
xcrun simctl io "$SIMID" screenshot /tmp/labstream-smoke.png   # then Read it
```

Confirm: the process stays alive (no crash/`.ips`, no `fatalError`/assertion), the log is
clean for the area you touched, and the screenshot shows the expected UI (the golden-clone
sim is signed in to **Plex** — you should reach the browse UI, not login; it is **not**
configured for Jellyfin/Emby). This is the default close-out for every code change.

**Automated runs must self-test, not be told to.** Any workflow/subagent that builds app code
is expected to include this install→launch→log→screenshot smoke step on the worktree `$SIMID`
as its own final gate — it should not need to be spelled out in each workflow prompt. Full
*interactive* functional testing (synthetic taps, multi-backend flows) remains the USER's half
(see the `sim-driving` skill status note); the smoke test is what Claude owns automatically.

## Worktree simulators

Each worktree gets its own simulator so parallel worktrees don't clobber each other's app
container / login. `scripts/worktree-sim.sh` is the single source of truth; the same
script backs both the git hook and these agent steps.

- The **main** worktree owns the visionOS *golden* logged-in sim (recorded in
  `<main>/.simid`). Never delete it.
- By default, a **linked** worktree gets a `vpwt-<branch>-<hash>` visionOS clone of the
  golden, created **shut down** (boot it yourself when building). Its UDID lives in
  `<worktree>/.simid` (git-ignored).
- iPhone/iPadOS work can opt into independent iOS simulators without touching the
  visionOS golden. Use `LABSTREAM_SIM_PLATFORM=iphone` or `ipad`,
  `scripts/worktree-sim.sh --platform iphone|ipad ...`, or a gitignored `.simplatform`
  containing `iphone` or `ipad`; iPhone UDIDs live in `.simid-iphone`, iPad UDIDs in `.simid-ipad`.
- tvOS work uses a fresh Apple TV simulator rather than cloning the visionOS golden. Select it
  with `LABSTREAM_SIM_PLATFORM=tvos`, `scripts/worktree-sim.sh --platform tvos ...`, or a
  gitignored `.simplatform` containing `tvos`; its UDID lives in `.simid-tvos`.
- `scripts/worktree-sim.sh id` prints the selected platform's UDID — used as `$SIMID`
  above. Always target `"$SIMID"`, never `booted` (which errors once two sims are up).

```sh
scripts/worktree-sim.sh install-hook   # one-time: post-checkout auto-clones on `git worktree add`
scripts/worktree-sim.sh setup          # provision this worktree's sim (idempotent; clone bounces the golden briefly)
scripts/worktree-sim.sh teardown       # delete this worktree's clone + .simid (run before removing the worktree)
scripts/worktree-sim.sh teardown --all # delete every sim owned by this linked worktree
scripts/worktree-sim.sh closeout PATH  # teardown PATH if present, then prune orphaned vpwt-*/iphonewt-*/ipadwt-*/tvwt-* sims
scripts/worktree-sim.sh prune          # sweep worktree sims whose worktree is gone (backstop after a bare `git worktree remove`)
scripts/worktree-sim.sh --platform visionos id
scripts/worktree-sim.sh --platform iphone id
scripts/worktree-sim.sh --platform ipad id
scripts/worktree-sim.sh --platform tvos id
```

If `install-hook` warns that `core.hooksPath` is set, Git will ignore the shared hook it
just wrote; unset that config before relying on auto-clone behavior.

**Agent rule:** after creating a worktree, run `setup`; when finishing/removing one,
prefer `scripts/worktree-sim.sh closeout PATH` from any repo worktree, or run
`scripts/worktree-sim.sh teardown --all` inside the linked worktree **before**
`git worktree remove`. Use `prune` immediately afterward if removal already happened.
visionOS `setup` clones from the golden sim, which `simctl` can only do while the golden
is **shut down**, so it briefly bounces your booted main sim — expect a ~10s blip in the
main worktree's simulator when a new visionOS worktree sim is provisioned. iPhone/iPad and tvOS
setup create fresh simulators from the newest compatible installed runtime instead.

**Booted sims are NOT free — use a strict one-at-a-time queue.** Never run multiple
simulators simultaneously. This is especially important when parallel agents are working
in separate worktrees: source work and unit tests may proceed in parallel, but simulator
build/install/launch/visual-verification turns must be serialized by the lead agent. An
agent must obtain the current simulator lease before booting any visionOS, iPhone, iPad, or tvOS
simulator; all other agents wait with their simulators shut down. A leased agent may use
only one simulator at a time, must shut it down before switching platforms, and must release
the lease before another agent boots a simulator. Do not leave the golden simulator booted
while a linked-worktree simulator is running.

**Shut the leased sim down immediately when its verification turn ends** —
`xcrun simctl shutdown $(scripts/worktree-sim.sh id)` from inside the worktree (or
`xcrun simctl shutdown <UDID>`). The lead should check `xcrun simctl list devices` between
queued turns and proactively shut down any simulator left booted by a finished/interrupted
agent. Shutting down ≠ teardown — it just frees RAM/CPU and the clone (and its login)
survive for later. The **golden** sim should be booted only during its own leased main-
worktree verification turn; it is re-booted on demand, and `setup` needs it shut down to
clone anyway.

### Worktree closeout checklist

Never call worktree cleanup done until the linked simulator is gone. Preferred flow:

```sh
# Before removing a linked worktree that may own both visionOS and iPad simulators:
cd <worktree>
scripts/worktree-sim.sh teardown --all
cd <main>
git worktree remove <worktree>
git branch -D <branch>

# Preferred one-command helper from any repo worktree:
scripts/worktree-sim.sh closeout <worktree>

# If the worktree was already removed or you are unsure:
scripts/worktree-sim.sh prune
xcrun simctl list devices | rg 'vpwt|iphonewt|ipadwt|tvwt|<branch-fragment>' || true
```

Closeout invariant: only the main worktree owns the golden sim; linked-worktree closeout
must remove the relevant `vpwt-*`, `iphonewt-*`, `ipadwt-*`, and/or `tvwt-*` simulator and must not
remove the golden sim.

## Native macOS host deploy/run and cleanup

There is no macOS simulator lane. Use the host helper, which builds `LabstreamMac` for
`platform=macOS,arch=arm64`, never uses `simctl`/`devicectl`, and defaults to a
per-worktree dev bundle id so parallel worktrees do not collide with the production
sandbox/keychain identity:

```sh
scripts/deploy-macos-to-host.sh
scripts/deploy-macos-to-host.sh --launch
scripts/deploy-macos-to-host.sh --no-build --launch
```

Use `--use-production-bundle-id` only intentionally. The helper stages dev apps under
`build/macos-host/<identity>/Labstream.app` and never deletes `/Applications/Labstream.app`.

**macOS host cleanup rule:** because there is no simulator to tear down, clean up the host
app/state when you are done with a macOS check, especially before closing out a worktree or
a one-off UI/smoke identity:

```sh
scripts/deploy-macos-to-host.sh --delete           # remove this identity's staged app only
scripts/deploy-macos-to-host.sh --delete-all-staged # remove all apps staged by this worktree
scripts/deploy-macos-to-host.sh --reset-container  # remove this identity's sandbox container only
```

Per-worktree builds are visibly labeled `Labstream Dev — <identity>` in macOS; an intentional
production-identity build remains `Labstream`. Cleanup commands preserve sandbox containers and
Keychain credentials unless `--reset-container` is explicitly requested.

`--use-production-bundle-id` is automatically Apple-Development-signed and provisions the Mac so
the canonical synchronized Plex-token Keychain item is accessible. Do not replace it with an ad-hoc
build: Security rejects synchronizable token access with OSStatus `-34018`, which surfaces as a
misleading token/session error.

Production container reset is intentionally guarded and requires both
`--use-production-bundle-id` and `--allow-production-container-reset`; do not touch the
production container unless explicitly testing/resetting the App Store identity. For old
manual identities, inspect `~/Library/Containers/com.jlipworth.Labstream.dev.*` and remove
only stale dev containers after confirming they do not correspond to an active worktree.
Current contributor guidance: `docs/MACOS.md`. The original host-helper rollout note is retained
as historical context at `docs/archive/macos/MACOS-HOST-DEPLOYMENT.md`.

## Live-testing workflow

Use the named platform runners in `docs/TESTING-STRATEGY.md`: semantic XCUITest for iPhone/iPad,
the isolated Accessibility runner for macOS, XCUITest/XCUIRemote for tvOS, and the passive/probe-first
runner documented by the **`sim-driving` skill** for visionOS. Xcode Device Interaction is an
iPhone/iPad exploratory path only; it is not the durable regression contract and does not support
the visionOS simulator. On Xcode 27, do not invoke the retained visionOS click scenario or use
free-form/coordinate clicking. Hand off authentication, gaze/hover, pinch-drag, immersive UI, and
hardware-only checks to the user/headset. Self-serve runner artifacts, screenshots, and logs rather
than asking the user to collect them.

For post-reproduction logs or evidence bundles, use the **`diagnostic-triage` skill**. Do not
open or paste complete diagnostic JSONL directories or broad unified logs into conversation
context by default. Run deterministic summarization/deduplication first, read its bounded brief,
and escalate only to a named source window with a stated reason. Every subsequent evidence pull
must be diffed against the prior bundle before its raw contents are read.

```sh
# SIMID is this worktree's visionOS sim (see Build block / "Worktree simulators"); always target it
# explicitly even though simulator turns are serialized; never target `booted`.
SIMID=$(scripts/worktree-sim.sh --platform visionos id)

# Claude takes its own screenshots after the user interacts
xcrun simctl io "$SIMID" screenshot /tmp/labstream-test.png   # then Read the PNG

# Claude reads app logs itself (NSLog instrumentation shows up here)
xcrun simctl spawn "$SIMID" log show --last 5m --predicate 'process == "Labstream"'
```

⚠️ STALE-PROCESS TRAP (bit us live): a running copy of the app can survive
`simctl install` (and `terminate` may report "found nothing to terminate" while it
lives on), so the user can keep interacting with the OLD binary after a fix is
installed. Before concluding a fix failed from a new .ips crash report, check the
report's `procLaunch` time and image UUIDs against the build time / `dwarfdump --uuid`
of the fixed dylib.

When a fix is speculative, instrument it with `NSLog` first and read the log after the
user exercises it — one build cycle instead of two. NEVER NSLog a raw string that may
contain `%` — always `NSLog("%@", str)`.

SourceKit diagnostics like "No such module 'PMSKit'/'UIKit'" are phantom noise in this
project — `xcodebuild` is the only truth.

Manual test plan: `TESTING-CHECKLIST.md` (keep it updated as fixes ship).

## Documentation information architecture

Evaluate factual accuracy and document placement together. Classify before creating: current
published guidance stays directly under `docs/`; active implementation/acceptance work uses
`docs/plans/`; unresolved investigation uses `docs/research/`; immutable point-in-time audits and
profiles use `docs/evidence/`; completed or superseded context uses `docs/archive/`. Never create a
tool-branded hierarchy such as `docs/superpowers/`, and do not split one coherent program into
separate design and implementation plans when one durable plan is sufficient.

Keep published URLs stable unless a move has concrete semantic benefit. Promote proven behavior
into canonical current docs, then archive completed plans and resolved reviews. During moves,
preserve historical prose while repairing live links, nav, scripts, and current instructions.
Co-locate Mermaid source with the canonical prose; include accessible title/description and
complete adjacent prose, and update the diagram whenever depicted behavior or ownership changes.
After any documentation content or path change, run strict MkDocs, repository-wide link and anchor
validation, Mermaid structural validation, and `scripts/ci-hygiene.sh`.

## Hard constraints (do not regress)

- `X-Plex-Client-Profile-Name=Generic` in TranscodeRequest is the proven-correct
  shipping value — keep it. Safari was tried and regressed high-bitrate 4K HEVC (it
  hard-limits 10-bit HEVC and forced ~20 Mbps video transcodes on 4K MKV even on
  Direct Play / Maximum), so we use `Generic` plus an explicit
  `X-Plex-Client-Profile-Extra`. An unknown or missing profile name makes PMS return a
  bare HTTP 400, so the name must always resolve to a real built-in profile.
- Never commit Plex tokens or client identifiers.
- Never reintroduce the scrubbed real PMS hostname or LAN IP; the repo uses
  `plex.example.internal` / `192.0.2.10` as placeholders.
- Treat the repository and GitHub issues as public. Before committing any externally-authored
  doc/report/log, scrub personal identifiers: real hostnames/domains, ssh usernames,
  media titles/library paths, home timezone, local home-directory paths. If something
  sensitive was already PUSHED, history must be rewritten with `git filter-repo`
  (amend/reset suffices only while unpushed). GH issues also become public — keep
  identifying details out of issue bodies/comments too.

## Conventions

- Do not add Anthropic/Claude co-author trailers to commits.
- Verified platform findings (what works windowed vs expanded, proven-impossible
  approaches) belong in `docs/DEVELOPMENT.md`, not just commit messages.
