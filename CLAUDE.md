# VisionPlex (PlexAVPApp) — Claude Code notes

visionOS Plex client. App code in `PlexAVPApp/`, networking/model layer in `PlexKit/`
(local Swift package with its own tests). Design rationale and hard-won AVKit findings
live in `docs/DEVELOPMENT.md` — read it before re-deriving anything about the player.

## Build / install / test loop

```sh
# Build (simulator UDID may differ; `xcrun simctl list devices booted` to check)
xcodebuild -project PlexAVPApp.xcodeproj -scheme PlexAVPApp \
  -destination 'platform=visionOS Simulator,id=D9BD8E9D-8E58-485D-B332-F8CDF37133B5' \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO -quiet

# Install + relaunch on the booted simulator (upgrade in place — login survives)
xcrun simctl install booted "$HOME/Library/Developer/Xcode/DerivedData/PlexAVPApp-*/Build/Products/Debug-xrsimulator/PlexAVPApp.app"
xcrun simctl terminate booted com.personal.PlexAVPApp; xcrun simctl launch booted com.personal.PlexAVPApp

# PlexKit unit tests
cd PlexKit && swift test
```

New Swift files are picked up automatically (file-system-synchronized groups) — never
edit the pbxproj to add one.

## Live-testing workflow (semi-automated)

Claude can drive the simulator itself — synthetic clicks, screenshots, coordinate
mapping, log reading. Full procedure in the **`sim-driving` skill** (use it before any
interactive testing). Hand off to the user only for gaze-hover rendering checks,
drag gestures, and the expanded cinema scene. Don't ask the user for screenshots or
log dumps:

```sh
# Claude takes its own screenshots after the user interacts
xcrun simctl io booted screenshot /tmp/visionplex-test.png   # then Read the PNG

# Claude reads app logs itself (NSLog instrumentation shows up here)
xcrun simctl spawn booted log show --last 5m --predicate 'process == "PlexAVPApp"'
```

When a fix is speculative, instrument it with `NSLog` first and read the log after the
user exercises it — one build cycle instead of two. NEVER NSLog a raw string that may
contain `%` — always `NSLog("%@", str)`.

SourceKit diagnostics like "No such module 'PlexKit'/'UIKit'" are phantom noise in this
project — `xcodebuild` is the only truth.

Manual test plan: `TESTING-CHECKLIST.md` (keep it updated as fixes ship).

## Hard constraints (do not regress)

- `X-Plex-Client-Profile-Name=Safari` in TranscodeRequest must NEVER change — an
  unknown profile makes PMS return a bare HTTP 400.
- Never commit Plex tokens or client identifiers.
- Never reintroduce the scrubbed strings `plex.example.internal` / `192.0.2.10`;
  the repo uses `plex.example.internal` / `192.0.2.10` as placeholders.

## Conventions

- GH issue bodies/comments end with `🤖 Generated with [Claude Code](https://claude.com/claude-code)`;
  commits end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Verified platform findings (what works windowed vs expanded, proven-impossible
  approaches) belong in `docs/DEVELOPMENT.md`, not just commit messages.
