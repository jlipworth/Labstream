# Development notes

Durable, easy-to-forget facts about building and working on this app. Task/bug tracking lives in
[GitHub Issues](https://github.com/jlipworth/plex-avp-app/issues); see the [README](../README.md)
for the basic build/run.

## Build, test, run

```sh
# Build (visionOS 26.5 simulator, unsigned)
xcodebuild -project PlexAVPApp.xcodeproj -scheme PlexAVPApp \
  -destination 'platform=visionOS Simulator,name=Apple Vision Pro' \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO

# PlexKit unit tests
cd PlexKit && swift test

# Install + launch on a booted sim
APP="$HOME/Library/Developer/Xcode/DerivedData/PlexAVPApp-<hash>/Build/Products/Debug-xrsimulator/PlexAVPApp.app"
xcrun simctl install booted "$APP" && xcrun simctl launch booted com.personal.PlexAVPApp

# After-the-fact logs
xcrun simctl spawn booted log show --last 5m --predicate 'process == "PlexAVPApp"' --style compact
```

- App bundle id: `com.personal.PlexAVPApp` · Sim: "Apple Vision Pro" (visionOS 26.5).
- New Swift files are auto-included (Xcode file-system-synchronized groups + SPM
  `PlexKit/Sources`, `PlexKit/Tests`) — no `project.pbxproj` edits needed.

## Gotchas we don't want to re-learn

- **CRITICAL — do not revert:** `TranscodeRequest` sends `X-Plex-Client-Profile-Name="Safari"`. An
  unknown profile name (e.g. "visionOS") makes PMS return a bare **HTTP 400** and playback breaks.
  The bitrate cap is enforced by `maxVideoBitrate`.
- **AVKit `contextualActions`** (`visionos(1.0)`) is the only affordance that renders over video in
  **both** inline and expanded cinema states and stays tappable — a floated SwiftUI sibling vanishes
  in the expanded experience, and the ⓘ panel is buried. (See the Close-button placement issue.)
- **HLS network loss is a stall, not a failure** — `timeControlStatus == .waitingToPlayAtSpecifiedRate`
  with an empty buffer; `AVPlayerItem.status` never flips to `.failed`. Hence the 15s stall watchdog.
- **Wedge recovery requires a brand-new view controller** — an in-place `retry()` (item swap)
  inherits the wedged control layer + dimmed cinema room. Rebuilding via a SwiftUI `.id()` bump is
  the only thing that clears both, resuming at the captured live playhead.
- **Reinstall wipes the app container** (keychain + Application Support) → **re-login required after
  every reinstall.** The token persists across plain relaunches via a file fallback in
  `KeychainStore` (the unsigned-sim keychain fails with `errSecMissingEntitlement -34018`).
- **Single-window constraint:** no `openWindow` / second `WindowGroup` — the player is a
  `.fullScreenCover`, like other native players.
- **Server:** configured per-user at sign-in (a Cloudflare-fronted PMS over `:443`). The real
  hostname/LAN IP are intentionally kept out of the repo.

## Conventions

- **Never commit** Plex tokens or client identifiers.
- Never `NSLog` a raw string containing `%` (format-string crash) — use `NSLog("%@", str)`.
