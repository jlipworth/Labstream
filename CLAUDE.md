# VisionPlay (VisionPlay) — Claude Code notes

visionOS Plex client. App code in `VisionPlay/`, networking/model layer in `PMSKit/`
(local Swift package with its own tests). Design rationale and hard-won AVKit findings
live in `docs/DEVELOPMENT.md` — read it before re-deriving anything about the player.

## Build / install / test loop

```sh
# This worktree's simulator. In the main worktree this resolves to the golden
# D9BD8E9D…; in a linked worktree it's that worktree's own cloned sim (see
# "Worktree simulators" below). It may be Shutdown — boot it first.
SIMID=$(scripts/worktree-sim.sh id)
xcrun simctl boot "$SIMID" 2>/dev/null || true   # no-op if already booted

# Build (simulator UDID may differ; `xcrun simctl list devices booted` to check).
# ⚠️ LINK-SKIP TRAP (bit us live): after a source edit xcodebuild may recompile the .o
# but SKIP the Ld step — exit 0, no new binary, and the "fix" you then install is the OLD
# app. Guard every fix build: delete the .app product first, and verify afterwards that
# the binary mtime is fresh (and matches the installed copy via
# `xcrun simctl get_app_container "$SIMID" com.jlipworth.VisionPlay app`).
# ⚠️ DETERMINISTIC LC_UUID (don't be fooled): this project emits a content-INDEPENDENT
# Mach-O UUID — two different builds (even a real source change) produce the IDENTICAL
# `dwarfdump --uuid`, and even a full clean rebuild reuses it. So a cross-build UUID
# comparison CANNOT detect a stale binary, and grepping the binary for a changed string
# is unreliable (Swift literal storage). The only thing that proves the Ld step ran is a
# FULL clean-DerivedData build (`rm -rf …/DerivedData/VisionPlay-*`) with exit 0 — there
# is no incremental link to skip — plus a fresh product mtime. The UUID diff below is
# still valid for ONE thing: confirming the INSTALLED copy == the copy you just built
# (same build → same UUID), i.e. the STALE-PROCESS/wrong-install guard, NOT staleness vs
# the source.
rm -rf $HOME/Library/Developer/Xcode/DerivedData/VisionPlay-*/Build/Products/Debug-xrsimulator/VisionPlay.app
scripts/xcodebuild-versioned.sh -project VisionPlay.xcodeproj -scheme VisionPlay \
  -destination "platform=visionOS Simulator,id=$SIMID" \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO -quiet

# Install + relaunch on this worktree's simulator (upgrade in place — login survives).
# Multiple stale VisionPlay-* DerivedData dirs exist — always pick the newest, and use
# /bin/ls (plain `ls` is aliased to eza, whose output breaks the substitution).
APP=$(/bin/ls -td $HOME/Library/Developer/Xcode/DerivedData/VisionPlay-*/Build/Products/Debug-xrsimulator/VisionPlay.app | head -1)
xcrun simctl install "$SIMID" "$APP"
xcrun simctl terminate "$SIMID" com.jlipworth.VisionPlay; xcrun simctl launch "$SIMID" com.jlipworth.VisionPlay

# PMSKit unit tests
cd PMSKit && swift test
```

New Swift files are picked up automatically (file-system-synchronized groups) — never
edit the pbxproj to add one.

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
deletes the stale `Debug-xros/VisionPlay.app` product before building, and stamps the
internal Build ID via `scripts/build-version-args.sh`.

⚠️ **RECURRING SIGNING GOTCHA (hit often).** A command-line device build fails with
`error: No Account for Team "<id>"` / `No profiles for 'com.jlipworth.VisionPlay' were found`
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
a workflow / subagent — you MUST headlessly verify it actually *runs* on **this worktree's
own `$SIMID`** (`scripts/worktree-sim.sh id`; boot it first — clones are created Shutdown;
never target `booted`). The minimum smoke test, which Claude self-serves (it is the passive
half of the live-testing workflow — do NOT ask the user to do it):

```sh
SIMID=$(scripts/worktree-sim.sh id)
xcrun simctl boot "$SIMID" 2>/dev/null || true
APP=$(/bin/ls -td $HOME/Library/Developer/Xcode/DerivedData/VisionPlay-*/Build/Products/Debug-xrsimulator/VisionPlay.app | head -1)
xcrun simctl install "$SIMID" "$APP"
# install guard (see STALE-PROCESS trap): installed UUID must match the build you just made.
# NOTE: LC_UUID is deterministic here (see DETERMINISTIC LC_UUID above), so this proves
# install==build, NOT that the binary is newer than your source edit — a clean build is what
# proves the latter. dwarfdump prints full paths (which differ), so compare only the UUID token.
B=$(xcrun dwarfdump --uuid "$APP/VisionPlay" | awk '{print $2}')
I=$(xcrun dwarfdump --uuid "$(xcrun simctl get_app_container "$SIMID" com.jlipworth.VisionPlay app)/VisionPlay" | awk '{print $2}')
[ "$B" = "$I" ] && echo UUID_MATCH || echo "UUID_MISMATCH built=$B installed=$I"
xcrun simctl terminate "$SIMID" com.jlipworth.VisionPlay 2>/dev/null || true
xcrun simctl launch "$SIMID" com.jlipworth.VisionPlay
xcrun simctl spawn "$SIMID" log show --last 2m --predicate 'process == "VisionPlay"' | tail -120
xcrun simctl io "$SIMID" screenshot /tmp/visionplay-smoke.png   # then Read it
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

Each worktree gets its own visionOS simulator so parallel worktrees don't clobber each
other's app container / login. `scripts/worktree-sim.sh` is the single source of truth;
the same script backs both the git hook and these agent steps.

- The **main** worktree owns the *golden* logged-in sim (`D9BD8E9D…`, recorded in
  `<main>/.simid`). Never delete it.
- A **linked** worktree gets a `vpwt-<branch>-<hash>` clone of the golden, created **shut down**
  (boot it yourself when building). Its UDID lives in `<worktree>/.simid` (git-ignored).
- `scripts/worktree-sim.sh id` prints this worktree's UDID — used as `$SIMID` above.
  Always target `"$SIMID"`, never `booted` (which errors once two sims are up).

```sh
scripts/worktree-sim.sh install-hook   # one-time: post-checkout auto-clones on `git worktree add`
scripts/worktree-sim.sh setup          # provision this worktree's sim (idempotent; clone bounces the golden briefly)
scripts/worktree-sim.sh teardown       # delete this worktree's clone + .simid (run before removing the worktree)
scripts/worktree-sim.sh closeout PATH  # teardown PATH if present, then prune orphaned vpwt-* sims
scripts/worktree-sim.sh prune          # sweep clones whose worktree is gone (backstop after a bare `git worktree remove`)
```

If `install-hook` warns that `core.hooksPath` is set, Git will ignore the shared hook it
just wrote; unset that config before relying on auto-clone behavior.

**Agent rule:** after creating a worktree, run `setup`; when finishing/removing one, run
`teardown` **before** `git worktree remove`, or run `closeout PATH` / `prune` immediately
afterward. `setup` clones from the golden sim, which `simctl` can only do while the
golden is **shut down**, so it briefly bounces your booted main sim — expect a ~10s
blip in the main worktree's simulator when a new worktree is provisioned.

**Booted sims are NOT free — shut them down.** When parallelizing work across several
worktrees (fanning out agents, many at a time), each linked worktree boots its own
visionOS simulator and several booted `vpwt-*` clones at once bog down the MacBook. So:
cap how many run concurrently, and **shut each worktree's sim down the moment its work is
done** — `xcrun simctl shutdown $(scripts/worktree-sim.sh id)` from inside the worktree
(or `xcrun simctl shutdown <UDID>`). Every fan-out coding agent should shut down its own
sim as its final step (after build/smoke-test + commit); the lead should also proactively
shut down the sims of already-finished batches. Shutting down ≠ teardown — it just frees
RAM/CPU and the clone (and its login) survive for later. The **golden** sim only needs to
be booted while the *main* worktree is actively building/testing — when it isn't (e.g. the
lead is just orchestrating fan-out agents on their own clones), shut golden down too; it's
re-booted on demand and `setup` needs it shut down to clone anyway.

### Worktree closeout checklist

Never call worktree cleanup done until the linked simulator is gone. Preferred flow:

```sh
# Before removing a linked worktree:
cd <worktree>
scripts/worktree-sim.sh teardown
cd <main>
git worktree remove <worktree>
git branch -D <branch>

# Safer one-command helper from any repo worktree:
scripts/worktree-sim.sh closeout <worktree>

# If the worktree was already removed or you are unsure:
scripts/worktree-sim.sh prune
xcrun simctl list devices | rg 'vpwt|<branch-fragment>' || true
```

Closeout invariant: only the main worktree owns the golden sim; linked-worktree closeout
must remove the relevant `vpwt-*` clone and must not remove the golden sim.

## Live-testing workflow (semi-automated)

The USER performs all simulator interaction (synthetic clicking was tried and shelved —
see the status note in the **`sim-driving` skill** before considering it). Claude
self-serves the passive half — screenshots and logs. Don't ask the user for screenshots
or log dumps:

```sh
# SIMID is this worktree's sim (see Build block / "Worktree simulators"); always target it
# explicitly because more than one simulator may be booted.
SIMID=$(scripts/worktree-sim.sh id)

# Claude takes its own screenshots after the user interacts
xcrun simctl io "$SIMID" screenshot /tmp/visionplay-test.png   # then Read the PNG

# Claude reads app logs itself (NSLog instrumentation shows up here)
xcrun simctl spawn "$SIMID" log show --last 5m --predicate 'process == "VisionPlay"'
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
- The repo WILL BE MADE PUBLIC eventually. Before committing any externally-authored
  doc/report/log, scrub personal identifiers: real hostnames/domains, ssh usernames,
  media titles/library paths, home timezone, local `/Users/...` paths. If something
  sensitive was already PUSHED, history must be rewritten with `git filter-repo`
  (amend/reset suffices only while unpushed). GH issues also become public — keep
  identifying details out of issue bodies/comments too.

## Conventions

- Do not add Anthropic/Claude co-author trailers to commits.
- Verified platform findings (what works windowed vs expanded, proven-impossible
  approaches) belong in `docs/DEVELOPMENT.md`, not just commit messages.
