# VisionPlay

[![License: GPL-3.0](https://img.shields.io/badge/License-GPL--3.0-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)
[![Platform: visionOS 26.5](https://img.shields.io/badge/Platform-visionOS%2026.5-black.svg)](https://developer.apple.com/visionos/)
[![Swift 6](https://img.shields.io/badge/Swift-6-orange.svg)](https://www.swift.org/)
[![Xcode 26](https://img.shields.io/badge/Xcode-26-blue.svg)](https://developer.apple.com/xcode/)

A personal-use, native **visionOS (Apple Vision Pro)** media client for Plex and Jellyfin. It combines
server-aware streaming quality control, custom Apple Vision Pro cinema playback, and offline downloads
that choose between raw originals and compatible server-rendered copies.

> **Status: working app.** End-to-end playback runs in the visionOS 26.5 simulator and on device.
> Build is green and the `PMSKit` package ships a full unit-test suite (`cd PMSKit && swift test`).
> This is a single-user, sideload-only project — there is no App Store build.

## What this app does

- **Sign-in** via Plex PIN OAuth or Jellyfin credentials, with secrets stored in Keychain
- **Browse + search** Home hubs, libraries, and a search surface
- **Server-aware playback** — Direct Play / Maximum attempts copy/direct paths where viable; explicit
  quality rungs request capped server streams
- **Scrubbing + resume** — seeks cleanly and resumes half-watched titles at the right offset
- **Cinema mode** — the custom player expands into an app-owned immersive Cinema surface with the
  same transport, menus, retry, scrubber, and Up Next controls
- **TV show hierarchy** — drill down Show → Seasons → Episodes
- **Skip Intro / Skip Credits** during server-detected marker windows
- **Up Next + autoplay** — advances to the next episode with a countdown, crossing season boundaries
- **Offline downloads** — raw original downloads only when locally playable; otherwise compatible
  original-quality or bitrate-capped server-rendered files with metadata, poster, resume, and integrity checks
- **Failure recovery** — a stall watchdog surfaces a "Playback failed" overlay and rebuilds the player
  to recover from wedged HLS network loss without relaunching the app
- **Playback extras** — quality switch that keeps the playhead, subtitles by language name, chapters,
  stats, and 0.5×–2× speed; progress scrobble / mark-watched; buffering spinner; audio-session
  interruption handling

## Tech

- **SwiftUI** app shell with a custom AVFoundation player surface for streaming, offline playback,
  and app-owned Cinema mode
- **Swift 6** with strict concurrency
- **`PMSKit`** — a local Swift package providing tested Plex/Jellyfin request builders, models,
  playback/download decision helpers, diagnostics primitives, and policy state machines
- **Xcode 26**, targeting **visionOS 26.5**

## Project structure

```
VisionPlay/
├── VisionPlay/            # visionOS app (SwiftUI)
│   ├── App/              # app entry + session state
│   ├── Auth/             # Plex/Jellyfin auth + Keychain
│   ├── Backend/          # Jellyfin service lane
│   ├── Networking/       # Plex client wiring
│   ├── Player/           # custom AVPlayer surface + app-owned Cinema mode + recovery
│   ├── Music/            # Plexamp-style music browse + audio player
│   ├── Downloads/        # offline transfers + offline library
│   └── UI/               # Home · Libraries · Search · Detail
├── PMSKit/              # local Swift package: request/model/policy layer (+ tests)
└── docs/                 # current architecture docs plus archived research/plans
```

## Build & run

This is a **personal-device sideload** project today. The app identity is **VisionPlay** and the
development bundle identifier is `com.jlipworth.VisionPlay`. It runs from Xcode on the visionOS 26.5
simulator unsigned, or on a registered Apple Vision Pro with local signing. Free Apple-ID profiles
expire every 7 days, so a device install needs a periodic Mac-tethered rebuild. Developer Mode and
the first-launch trust prompt are Apple's expected security gate for sideloaded development builds.

Build the app (visionOS 26.5 simulator, unsigned):

```bash
xcodebuild -project VisionPlay.xcodeproj -scheme VisionPlay \
  -destination 'platform=visionOS Simulator,name=Apple Vision Pro' \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO
```

Run the `PMSKit` test suite:

```bash
cd PMSKit && swift test
```

For personal-device signing, create a local-only `Signing.local.xcconfig` containing only your Apple Developer Team ID. The bundle ID and signing style are committed project settings:

```xcconfig
DEVELOPMENT_TEAM = YOUR_TEAM_ID
```

Do not commit local signing files, provisioning profiles, certificates, Plex tokens, server
hostnames, or LAN IPs.

Local validation before handing off:

```bash
xcodebuild -project VisionPlay.xcodeproj -scheme VisionPlay \
  -destination 'platform=visionOS Simulator,name=Apple Vision Pro' \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO
(cd PMSKit && swift test)
./scripts/ci-hygiene.sh
```

Woodpecker runs the portable CI checks only: `PMSKit` tests and repo hygiene. The unsigned
visionOS simulator `xcodebuild` remains a local macOS/Xcode validation step unless or until a future
macOS-runner CI job is added. A future App Store/TestFlight pass can add distribution signing,
entitlements review, screenshots, privacy metadata, and store-specific release automation later; it
is intentionally not part of this personal sideload setup.

See [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md) for install/launch, logging, and the platform
gotchas worth knowing before changing the player or transcode code. Current architecture docs start at
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md), with focused notes for
[`playback`](docs/PLAYBACK-ARCHITECTURE.md), [`backends`](docs/BACKENDS.md),
[`downloads/offline`](docs/DOWNLOADS-OFFLINE.md), [`persistence`](docs/PERSISTENCE.md),
[`diagnostics/privacy`](docs/DIAGNOSTICS-PRIVACY.md), [`system integration`](docs/SYSTEM-INTEGRATION.md),
and [`testing`](docs/TESTING-STRATEGY.md).

On first launch, choose Plex or Jellyfin and sign in to your server. Reinstalling wipes the app
container, so a re-login is required after a fresh install.

## Docs

Current architecture and operating guidance lives in the top-level files under [`docs/`](docs/). Active research for not-yet-implemented work lives in [`docs/research/`](docs/research/); promote only proven behavior from research into the current docs. Historical design research, completed implementation plans, and superseded review snapshots live in [`docs/archive/`](docs/archive/). Archived files are context only; they are not the current source of truth and may contain retired decisions such as the old `Safari` Plex profile assumption.

## License

This project is licensed under the **GNU General Public License v3.0**. See [LICENSE](LICENSE) for the
full text.

For distribution through the Apple App Store / TestFlight, a GPLv3 **section 7 additional permission**
applies — see [`APP-STORE-EXCEPTION.md`](APP-STORE-EXCEPTION.md). It resolves the well-known
GPL-vs-App-Store conflict while keeping copyleft fully intact: the source stays GPL and any fork must
remain open.

Copyright (C) 2026 Jonathan Lipworth
