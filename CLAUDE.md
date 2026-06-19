# VisionPlay (PlexAVPApp) — Claude Code notes

visionOS Plex client. App code in `PlexAVPApp/`, networking/model layer in `PMSKit/`
(local Swift package with its own tests). Design rationale and hard-won AVKit findings
live in `docs/DEVELOPMENT.md` — read it before re-deriving anything about the player.

## Build / install / test loop

```sh
# Build (simulator UDID may differ; `xcrun simctl list devices booted` to check).
# ⚠️ LINK-SKIP TRAP (bit us live): after a source edit xcodebuild may recompile the .o
# but SKIP the Ld step — exit 0, no new binary, and the "fix" you then install is the OLD
# app. Guard every fix build: delete the .app product first, and verify afterwards that
# the binary mtime is fresh (and matches the installed copy via
# `xcrun simctl get_app_container booted com.jlipworth.VisionPlay app`).
rm -rf $HOME/Library/Developer/Xcode/DerivedData/PlexAVPApp-*/Build/Products/Debug-xrsimulator/PlexAVPApp.app
xcodebuild -project PlexAVPApp.xcodeproj -scheme PlexAVPApp \
  -destination 'platform=visionOS Simulator,id=D9BD8E9D-8E58-485D-B332-F8CDF37133B5' \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO -quiet

# Install + relaunch on the booted simulator (upgrade in place — login survives).
# Multiple stale PlexAVPApp-* DerivedData dirs exist — always pick the newest, and use
# /bin/ls (plain `ls` is aliased to eza, whose output breaks the substitution).
APP=$(/bin/ls -td $HOME/Library/Developer/Xcode/DerivedData/PlexAVPApp-*/Build/Products/Debug-xrsimulator/PlexAVPApp.app | head -1)
xcrun simctl install booted "$APP"
xcrun simctl terminate booted com.jlipworth.VisionPlay; xcrun simctl launch booted com.jlipworth.VisionPlay

# PMSKit unit tests
cd PMSKit && swift test
```

New Swift files are picked up automatically (file-system-synchronized groups) — never
edit the pbxproj to add one.

## Live-testing workflow (semi-automated)

The USER performs all simulator interaction (synthetic clicking was tried and shelved —
see the status note in the **`sim-driving` skill** before considering it). Claude
self-serves the passive half — screenshots and logs. Don't ask the user for screenshots
or log dumps:

```sh
# Claude takes its own screenshots after the user interacts
xcrun simctl io booted screenshot /tmp/visionplay-test.png   # then Read the PNG

# Claude reads app logs itself (NSLog instrumentation shows up here)
xcrun simctl spawn booted log show --last 5m --predicate 'process == "PlexAVPApp"'
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

- `X-Plex-Client-Profile-Name=Safari` in TranscodeRequest must NEVER change — an
  unknown profile makes PMS return a bare HTTP 400.
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
