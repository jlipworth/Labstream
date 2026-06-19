# VisionPlay

[![License: GPL-3.0](https://img.shields.io/badge/License-GPL--3.0-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)
[![Platform: visionOS 26.5](https://img.shields.io/badge/Platform-visionOS%2026.5-black.svg)](https://developer.apple.com/visionos/)
[![Swift 6](https://img.shields.io/badge/Swift-6-orange.svg)](https://www.swift.org/)
[![Xcode 26](https://img.shields.io/badge/Xcode-26-blue.svg)](https://developer.apple.com/xcode/)

A personal-use, native **visionOS (Apple Vision Pro)** Plex client that combines the three things no
current visionOS Plex app cleanly does together: **reliable bitrate-capped HLS transcoding** (request
a capped HLS stream, not direct-play-only), **theater/cinema playback** on a giant virtual screen, and
**offline downloads** of capped copies of your library.

> **Status: working app.** End-to-end playback runs in the visionOS 26.5 simulator and on device.
> Build is green and the `PMSKit` package ships a full unit-test suite (`cd PMSKit && swift test`).
> This is a single-user, sideload-only project — there is no App Store build.

## What this app does

- **Sign-in** via Plex PIN OAuth (in-app web sheet that auto-closes), token stored in Keychain
- **Browse + search** Home hubs, libraries, and a search surface
- **Transcoded HLS playback** — forces a server-side bitrate-capped HLS stream (4K HEVC → ~7.5 Mbps
  1080p H.264 by default) rather than relying on direct play
- **Scrubbing + resume** — seeks cleanly and resumes half-watched titles at the right offset
- **Cinema docking** — the player expands into a system Cinema Environment with a controllable transport
  that stays tappable in both inline and expanded states
- **TV show hierarchy** — drill down Show → Seasons → Episodes
- **Skip Intro / Skip Credits** during server-detected marker windows
- **Up Next + autoplay** — advances to the next episode with a countdown, crossing season boundaries
- **Offline downloads** — quality-picker downloads with persistent transfers, offline metadata + poster
  + resume, and download-integrity rejection of truncated/error bodies
- **Failure recovery** — a stall watchdog surfaces a "Playback failed" overlay and rebuilds the player
  to recover from wedged HLS network loss without relaunching the app
- **Playback extras** — quality switch that keeps the playhead, subtitles by language name, chapters,
  stats, and 0.5×–2× speed; progress scrobble / mark-watched; buffering spinner; audio-session
  interruption handling

## Tech

- **SwiftUI** app shell with **AVKit / AVFoundation** for transcoded HLS playback and Cinema Environment docking
- **Swift 6** with strict concurrency
- **`PMSKit`** — a local Swift package providing the hand-rolled Plex API layer (auth, library browse,
  transcode decision, playback-state endpoints, TV + music hierarchy), fully unit-tested
- **Xcode 26**, targeting **visionOS 26.5**

## Project structure

```
VisionPlay/
├── PlexAVPApp/            # visionOS app (SwiftUI)
│   ├── App/              # app entry + session state
│   ├── Auth/             # Plex PIN OAuth + Keychain
│   ├── Networking/       # Plex client wiring
│   ├── Player/           # AVKit player + Cinema Environment + recovery
│   ├── Music/            # Plexamp-style music browse + audio player
│   ├── Downloads/        # offline transfers + offline library
│   └── UI/               # Home · Libraries · Search · Detail
├── PMSKit/              # local Swift package: Plex API layer (+ tests)
├── research/             # design research that informed the build
└── docs/                 # supporting notes
```

## Build & run

This is a **personal-device sideload** project today. The app identity is **VisionPlay** and the
development bundle identifier is `com.jlipworth.VisionPlay`. It runs from Xcode on the visionOS 26.5
simulator unsigned, or on a registered Apple Vision Pro with local signing. Free Apple-ID profiles
expire every 7 days, so a device install needs a periodic Mac-tethered rebuild. Developer Mode and
the first-launch trust prompt are Apple's expected security gate for sideloaded development builds.

Build the app (visionOS 26.5 simulator, unsigned):

```bash
xcodebuild -project PlexAVPApp.xcodeproj -scheme PlexAVPApp \
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
xcodebuild -project PlexAVPApp.xcodeproj -scheme PlexAVPApp \
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
gotchas worth knowing before changing the player or transcode code.

On first launch, sign in with your Plex account and point the app at your server (e.g.
`https://your-server:32400`). Reinstalling wipes the app container, so a re-login is required after a
fresh install.

## Research

The `research/` directory holds the design research that informed this client — the Plex transcoding
API surface, visionOS playback/theater capabilities, the offline-download approach, a competitive
teardown, and playback-state plumbing. It documents *why* the app is built the way it is and remains a
useful reference for the transcode-decision and download paths.

## License

This project is licensed under the **GNU General Public License v3.0**. See [LICENSE](LICENSE) for the
full text.

For distribution through the Apple App Store / TestFlight, a GPLv3 **section 7 additional permission**
applies — see [`APP-STORE-EXCEPTION.md`](APP-STORE-EXCEPTION.md). It resolves the well-known
GPL-vs-App-Store conflict while keeping copyleft fully intact: the source stays GPL and any fork must
remain open.

Copyright (C) 2026 Jonathan Lipworth
