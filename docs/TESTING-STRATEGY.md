# Testing strategy

## CI / portable checks

Portable CI should run:

```sh
(cd PMSKit && swift test)
./scripts/ci-hygiene.sh
```

`PMSKit` tests cover pure request builders, models, decision helpers, routing helpers, and policy state machines. Repo hygiene covers redaction/signing guardrails and other cheap checks.

## Local simulator checks

Run an unsigned simulator build locally on macOS/Xcode:

```sh
xcodebuild -project VisionPlay.xcodeproj -scheme VisionPlay \
  -destination 'platform=visionOS Simulator,name=Apple Vision Pro' \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO
```

The simulator is useful for compile/runtime smoke, browse flows, settings, downloads request shape, and many UI regressions. It is not a replacement for headset playback validation.

## Live probes

`PMSKit` live probe tests are opt-in discovery/log probes. They should not become required CI assertions because they depend on a real media server, credentials, library contents, network, and server version.

Use live probes to confirm wire shape and server behavior before documenting a behavior as “proven.”

## Device-only gates

Keep these as manual Apple Vision Pro checks:

- headset playback behavior and failures
- expanded Cinema/theater behavior
- audio interruptions and route changes
- Spotlight and Shortcuts/App Intents end-to-end behavior
- background downloads and headset sleep/off-head transfer behavior
- server-specific Plex/Jellyfin live download behavior

## Current validation boundaries

- Plex playback and download paths have the most live validation.
- Plex raw original download is intentionally offered only for compatible local containers.
- Plex compatible original-quality copies use the server optimizer/rendered-part route.
- Jellyfin browse/playback/download request paths are implemented and unit-tested, but Jellyfin downloads still need explicit live validation before being called headset-proven.

The manual checklist remains in [`../TESTING-CHECKLIST.md`](../TESTING-CHECKLIST.md). Treat it as a checklist and issue trail, not the canonical architecture doc.
