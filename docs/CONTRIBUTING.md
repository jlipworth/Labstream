# Contributing to VisionPlay

VisionPlay is a personal-use, sideloaded visionOS media client. Contributions are welcome, but the safest workflow is to keep secrets/device state local, prove pure logic in `PMSKit`, and only use live servers or a headset when a change genuinely needs them.

## Prerequisites

- macOS with Xcode 26 and an Apple Vision Pro visionOS 26.x simulator runtime.
- Swift 6 / Swift Package Manager, as provided by the selected Xcode toolchain.
- Optional: a paired Apple Vision Pro for device-only validation.
- Optional live-server env files copied locally from your own secrets. Never commit tokens, URLs, LAN IPs, or signing material.

## First checkout

```sh
git clone https://github.com/jlipworth/VisionPlay.git
cd VisionPlay
(cd PMSKit && swift test)
SIMID=$(scripts/worktree-sim.sh id)
xcrun simctl boot "$SIMID" 2>/dev/null || true
scripts/xcodebuild-versioned.sh -project VisionPlay.xcodeproj -scheme VisionPlay \
  -destination "platform=visionOS Simulator,id=$SIMID" \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO
./scripts/ci-hygiene.sh
```

New Swift files are picked up by Xcode file-system-synchronized groups and SwiftPM source discovery, so most changes should not require manual `project.pbxproj` edits.

## Simulator workflow

Use the worktree-specific simulator helper when working in linked worktrees. It avoids several contributors fighting over one app container or targeting the wrong booted simulator.

```sh
scripts/worktree-sim.sh setup
SIMID=$(scripts/worktree-sim.sh id)
xcrun simctl boot "$SIMID" 2>/dev/null || true
xcrun simctl install "$SIMID" /path/to/VisionPlay.app
xcrun simctl launch "$SIMID" com.jlipworth.VisionPlay
xcrun simctl spawn "$SIMID" log show --last 5m --predicate 'process == "VisionPlay"' --style compact
```

Target `"$SIMID"`, not `booted`; multiple Vision Pro simulators can be booted during parallel work.

## Device installs

Use the wrapper script instead of re-deriving signing flags:

```sh
scripts/deploy-to-device.sh
scripts/deploy-to-device.sh --launch
scripts/deploy-to-device.sh --no-build
```

The script expects local signing state and a paired headset. The development build uses `com.jlipworth.VisionPlay`; installing it can replace another build with the same bundle id and app state may be reset when the app is deleted or overwritten across install sources.

## Validation expectations

Run the cheapest faithful checks for your change:

- Pure request/model/policy changes: targeted `PMSKit` tests, then `cd PMSKit && swift test`.
- App-code changes: generic unsigned visionOS simulator build plus relevant unit tests.
- UI/runtime changes: install and launch on the worktree simulator when possible.
- Playback, audio routing, and off-head behavior: device validation is required before calling behavior headset-proven.
- Docs changes: `uv run --with-requirements requirements.txt mkdocs build --strict`.

## Secrets and privacy

Do not commit or paste:

- Plex, Jellyfin, or Emby tokens.
- server hostnames, LAN IPs, real media titles, item ids, device ids, or play-session ids unless explicitly scrubbed.
- signing files, provisioning profiles, certificates, or Xcode account details.

Diagnostics and bug reports should follow [`REPORTING-BUGS.md`](REPORTING-BUGS.md) and [`DIAGNOSTICS-PRIVACY.md`](DIAGNOSTICS-PRIVACY.md).

## Architecture rules of thumb

- Keep `PMSKit` pure and testable: request builders, decoders, route decisions, and policy state machines.
- Keep backend-specific behavior explicit. Plex, Jellyfin, and Emby share concepts, not one universal protocol.
- Avoid growing large app controllers such as `PlaybackController` into god objects. Prefer small coordinators or pure policy helpers at new seams.
- Promote proven current behavior into public docs; keep active research in `docs/research/` and move obsolete/future-refactor notes to `docs/archive/`.
