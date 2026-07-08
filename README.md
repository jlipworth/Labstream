# Labstream

[![License: GPL-3.0](https://img.shields.io/badge/License-GPL--3.0-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)
[![Platform: visionOS 26 + iOS/iPadOS 26.1+](https://img.shields.io/badge/Platform-visionOS%2026%20%2B%20iOS%2FiPadOS%2026.1%2B-black.svg)](https://developer.apple.com/)
[![Swift 6](https://img.shields.io/badge/Swift-6-orange.svg)](https://www.swift.org/)
[![Xcode 26](https://img.shields.io/badge/Xcode-26-blue.svg)](https://developer.apple.com/xcode/)

**Labstream is a native Apple-platform media client for your own Plex, Jellyfin, or Emby server.**

Labstream does not provide, host, sell, or bundle movies, TV, music, or other media. It connects only to servers you choose, and offline downloads are for media you are authorized to access and download under the applicable server/service terms.

It brings server-aware streaming, an Apple Vision Pro cinema playback surface, a native iPhone/iPad shell, music browsing, privacy-preserving diagnostics, and offline downloads to a source-first SwiftUI app.

> **Distribution status:** Labstream is currently distributed as source for local builds. There is no App Store or TestFlight build today.

## Contents

- [Features](#features)
- [Supported backends](#supported-backends)
- [Tech stack](#tech-stack)
- [Quick start](#quick-start)
- [Project structure](#project-structure)
- [Documentation](#documentation)
- [Contributing](#contributing)
- [Privacy and bug reports](#privacy-and-bug-reports)
- [License](#license)

## Features

### Playback

- Custom AVFoundation player surface shared by the visionOS and iOS/iPadOS targets.
- Direct Play / Maximum attempts copy or direct-stream paths where viable.
- Explicit quality rungs request capped server streams when needed.
- Resume, seek, retry, subtitles, chapters, playback speed, buffering state, and Stats for Nerds.
- Cinema mode expands playback into an app-owned immersive surface with the same transport controls.
- Watch progress, mark-watched behavior, Up Next, and episode autoplay.

### Libraries and search

- Home, library, search, and detail surfaces for personal media.
- TV hierarchy navigation from show to season to episode.
- Music browsing and playback for supported backend music libraries.
- Backend-aware sign-in and server/session restore.

### Downloads and offline

- Offline downloads with metadata, poster/side-asset support, integrity checks, and route-specific recovery: static/original and server-prepared static files use checkpoints, while live remux/transcode streams reconcile safely but may need retry/restart after interruption.
- Direct original downloads only when Labstream expects the file to be locally playable.
- Server-prepared or server-rendered compatible files when the original is not a safe offline target.

### Privacy and diagnostics

- Tokens and server credentials are stored in Keychain.
- Diagnostic logging is off by default, local-only, bounded, and user-exported only.
- Built-in bug-report diagnostics redact tokens, client identifiers, hostnames/IPs, full URLs, usernames, library paths, filenames, and media titles.

## Supported backends

| Backend | Sign-in | Core support |
| --- | --- | --- |
| Plex | Plex PIN/OAuth and server discovery | Browse, search, playback, progress, music, downloads/offline. |
| Jellyfin | Server URL plus Jellyfin auth or Quick Connect | Browse, search, playback, progress, music, downloads/offline. |
| Emby | Emby Connect PIN or manual server login | Browse, search, playback, progress, music, downloads/offline. |

Labstream is unofficial and independent. It is not affiliated with, endorsed by, sponsored by, or officially supported by Plex, the Jellyfin project, or Emby Media.

## Tech stack

- SwiftUI app shells targeting visionOS 26 and iOS/iPadOS 26.1+.
- Swift 6 with strict concurrency.
- Custom AVFoundation playback and offline playback paths.
- `PMSKit`, a local Swift package for Plex/Jellyfin/Emby request builders, models, diagnostics primitives, and pure policy state machines.
- MkDocs Material documentation published at <https://jlipworth.github.io/Labstream/>.

## Quick start

### Requirements

- macOS with Xcode 26 plus the visionOS 26 SDK and an iOS/iPadOS 26.1+ SDK/runtime for mobile builds.
- A compatible Apple Vision Pro simulator runtime for visionOS builds, a compatible iPhone/iPad simulator runtime for mobile builds, or paired Apple Vision Pro / iPhone / iPad hardware for device installs.
- A Plex, Jellyfin, or Emby server you control or have permission to access.

### Build for the visionOS simulator

```sh
SIMID=$(scripts/worktree-sim.sh --platform visionos id)
xcrun simctl boot "$SIMID" 2>/dev/null || true

scripts/xcodebuild-versioned.sh \
  -project Labstream.xcodeproj \
  -scheme Labstream \
  -destination "platform=visionOS Simulator,id=$SIMID" \
  -configuration Debug \
  build CODE_SIGNING_ALLOWED=NO
```

### Build for an iPhone simulator

```sh
printf 'iphone\n' > .simplatform   # gitignored per-worktree default
SIMID=$(scripts/worktree-sim.sh id)
xcrun simctl boot "$SIMID" 2>/dev/null || true

scripts/xcodebuild-versioned.sh \
  -project Labstream.xcodeproj \
  -scheme LabstreamMobile \
  -destination "platform=iOS Simulator,id=$SIMID" \
  -configuration Debug \
  build CODE_SIGNING_ALLOWED=NO
```

Use `printf 'ipad\n' > .simplatform` or `scripts/worktree-sim.sh --platform ipad id`
for the iPad build/smoke path. Both variants build the universal `LabstreamMobile`
target.

### Run core checks

```sh
cd PMSKit && swift test
cd ..
scripts/ci-hygiene.sh
uv run --with-requirements requirements.txt mkdocs build --strict
```

### Install on a physical Apple Vision Pro

```sh
scripts/deploy-to-device.sh            # build + install
scripts/deploy-to-device.sh --launch   # also launch while the headset is awake/worn
```

### Install on a physical iPhone or iPad

```sh
scripts/deploy-mobile-to-device.sh            # build + install
scripts/deploy-mobile-to-device.sh --launch   # also launch after install
```

Both app targets use the bundle identifier `com.jlipworth.Labstream` for the intended unified product identity.

## Project structure

```text
Labstream/
├── Labstream/             # shared app source for Labstream (visionOS) and LabstreamMobile (iOS/iPadOS)
│   ├── App/               # app entry, object graph, restore state
│   ├── Auth/              # Plex/Jellyfin/Emby auth and Keychain persistence
│   ├── Backend/           # backend service lanes, paging, search
│   ├── Diagnostics/       # local diagnostics/reporting helpers
│   ├── Downloads/         # offline transfers, offline index, download UI state
│   ├── Music/             # music browse, queue, and audio playback
│   ├── Networking/        # shared app networking helpers
│   ├── Player/            # custom player, diagnostics, restart/reopen logic
│   ├── SystemIntegration/ # App Intents, Spotlight, system-entry routing
│   ├── Theater/           # immersive playback surface support
│   └── UI/                # login, home, libraries, search, detail, settings
├── PMSKit/                # pure Swift package: requests, models, policies, tests
├── docs/                  # published docs plus archived research outside the nav
├── scripts/               # local validation, simulator, deploy, and probe helpers
└── .woodpecker/           # portable CI definitions
```

## Documentation

- Published docs: <https://jlipworth.github.io/Labstream/>
- Development setup: [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md)
- iOS/iPadOS target: [`docs/MOBILE-IOS.md`](docs/MOBILE-IOS.md)
- Architecture overview: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)
- Backend model: [`docs/BACKENDS.md`](docs/BACKENDS.md)
- Playback: [`docs/PLAYBACK-ARCHITECTURE.md`](docs/PLAYBACK-ARCHITECTURE.md)
- Downloads/offline: [`docs/DOWNLOADS-OFFLINE.md`](docs/DOWNLOADS-OFFLINE.md)
- Diagnostics/privacy: [`docs/DIAGNOSTICS-PRIVACY.md`](docs/DIAGNOSTICS-PRIVACY.md)

Public docs describe the current app. Internal research notes, old implementation plans, and superseded validation notes are kept under `docs/research/` or `docs/archive/` and are not part of the published navigation.

## Contributing

Start with [`docs/CONTRIBUTING.md`](docs/CONTRIBUTING.md). In short:

- keep backend-specific wire behavior explicit;
- put pure decisions in `PMSKit`;
- keep SwiftUI, AVFoundation, URLSession, Keychain, and filesystem side effects in the app target;
- never commit tokens, server URLs, private IPs, media titles, local signing files, or diagnostic artifacts.

For a quick module size readout, run:

```sh
scripts/loc.sh
```

## Privacy and bug reports

Labstream does not send analytics, diagnostics, or media-server data to the developer. If something breaks, the app can generate a local redacted diagnostic report that you review before posting to GitHub.

- Bug guide: [`docs/REPORTING-BUGS.md`](docs/REPORTING-BUGS.md)
- Bug form: <https://github.com/jlipworth/Labstream/issues/new?template=bug_report.yml>
- Privacy policy: [`PRIVACY.md`](PRIVACY.md)

## License

Labstream is licensed under the **GNU General Public License v3.0**. See [`LICENSE`](LICENSE) for the full text.

The project also carries a GPLv3 section 7 additional permission for Apple App Store / TestFlight distribution if that distribution path is used later. See [`APP-STORE-EXCEPTION.md`](APP-STORE-EXCEPTION.md).

Copyright (C) 2026 Jonathan Lipworth

<p align="center">
  <a href="https://www.gnu.org/licenses/gpl-3.0.en.html">
    <img src="https://www.gnu.org/graphics/gplv3-with-text-136x68.png" alt="GNU GPLv3" width="136" height="68">
  </a>
</p>
