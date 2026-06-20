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
rm -rf $HOME/Library/Developer/Xcode/DerivedData/VisionPlay-*/Build/Products/Debug-xrsimulator/VisionPlay.app
xcodebuild -project VisionPlay.xcodeproj -scheme VisionPlay \
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

## Worktree simulators

Each worktree gets its own visionOS simulator so parallel worktrees don't clobber each
other's app container / login. `scripts/worktree-sim.sh` is the single source of truth;
the same script backs both the git hook and these agent steps.

- The **main** worktree owns the *golden* logged-in sim (`D9BD8E9D…`, recorded in
  `<main>/.simid`). Never delete it.
- A **linked** worktree gets a `vpwt-<branch>` clone of the golden, created **shut down**
  (boot it yourself when building). Its UDID lives in `<worktree>/.simid` (git-ignored).
- `scripts/worktree-sim.sh id` prints this worktree's UDID — used as `$SIMID` above.
  Always target `"$SIMID"`, never `booted` (which errors once two sims are up).

```sh
scripts/worktree-sim.sh install-hook   # one-time: post-checkout auto-clones on `git worktree add`
scripts/worktree-sim.sh setup          # provision this worktree's sim (idempotent; clone bounces the golden briefly)
scripts/worktree-sim.sh teardown       # delete this worktree's clone + .simid (run before removing the worktree)
scripts/worktree-sim.sh prune          # sweep clones whose worktree is gone (backstop after a bare `git worktree remove`)
```

**Agent rule:** after creating a worktree, run `setup`; when finishing/removing one, run
`teardown` (or `prune` later). `setup` clones from the golden sim, which `simctl` can only
do while the golden is **shut down**, so it briefly bounces your booted main sim — expect
a ~10s blip in the main worktree's simulator when a new worktree is provisioned.

## Live-testing workflow (semi-automated)

The USER performs all simulator interaction (synthetic clicking was tried and shelved —
see the status note in the **`sim-driving` skill** before considering it). Claude
self-serves the passive half — screenshots and logs. Don't ask the user for screenshots
or log dumps:

```sh
# SIMID is this worktree's sim (see Build block / "Worktree simulators"); in the main
# worktree `booted` still works, but $SIMID is always correct.
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
  media titles/library paths, home timezone, local `/path/to/user` paths. If something
  sensitive was already PUSHED, history must be rewritten with `git filter-repo`
  (amend/reset suffices only while unpushed). GH issues also become public — keep
  identifying details out of issue bodies/comments too.

## Conventions

- Do not add Anthropic/Claude co-author trailers to commits.
- Verified platform findings (what works windowed vs expanded, proven-impossible
  approaches) belong in `docs/DEVELOPMENT.md`, not just commit messages.
