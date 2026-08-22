# Labstream

[![License: GPL-3.0](https://img.shields.io/badge/License-GPL--3.0-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)
[![visionOS 26](https://img.shields.io/badge/visionOS-26-black.svg)](https://developer.apple.com/visionos/)
[![iOS 26.1+](https://img.shields.io/badge/iOS-26.1%2B-black.svg)](https://developer.apple.com/ios/)
[![iPadOS 26.1+](https://img.shields.io/badge/iPadOS-26.1%2B-black.svg)](https://developer.apple.com/ipados/)
[![tvOS 26 in development](https://img.shields.io/badge/tvOS-26%20in%20development-lightgrey.svg)](docs/TVOS.md)
[![macOS 26 preview](https://img.shields.io/badge/macOS-26%20development%20preview-lightgrey.svg)](docs/MACOS.md)
[![Swift 6](https://img.shields.io/badge/Swift-6-orange.svg)](https://www.swift.org/)
[![Xcode 27](https://img.shields.io/badge/Xcode-27-blue.svg)](https://developer.apple.com/xcode/)

**Labstream is a native Apple-platform media client for your own Plex, Jellyfin, or Emby server.**

Labstream does not provide, host, sell, or bundle movies, TV, music, or other media. It connects only to servers you choose, and offline downloads are for media you are authorized to access and download under the applicable server/service terms.

The repository contains native targets for Apple Vision Pro, iPhone/iPad, Apple TV, and Mac. The
visionOS target is the primary development path, `LabstreamMobile` is one universal iPhone/iPad
target, `LabstreamTV` is an in-development streaming-only TV target, and `LabstreamMac` is a
local-build development preview. They share the SwiftUI app core, custom AVFoundation player, and
`PMSKit` backend layer while owning platform-specific shells, input, and system integration.

> **Distribution status:** Labstream is publicly distributed as source for local builds. The
> primary visionOS path has an invitation-only internal TestFlight build, but there is no public
> App Store release. iPhone/iPad distribution has not started, and Mac and Apple TV remain
> development previews rather than distribution products. See the
> [release and App Store status](docs/RELEASES.md).

> **Development status:** This is an active, pre-release project rather than a compatibility
> promise. Plex, Jellyfin, and Emby paths are implemented, but backend, server-version, media,
> and platform combinations do not all have equal live-device validation. Expect incomplete
> behavior and regressions while platform parity, hardware validation, performance measurement,
> and release acceptance remain ongoing work.

## Contents

- [Features](#features)
- [Supported backends](#supported-backends)
- [Platform status](#platform-status)
- [Tech stack](#tech-stack)
- [Quick start](#quick-start)
- [Project structure](#project-structure)
- [Documentation](#documentation)
- [Contributing](#contributing)
- [Privacy and bug reports](#privacy-and-bug-reports)
- [License](#license)

## Features

These are implemented product areas, not a claim that every item is complete on every platform
and backend. See the platform and backend status tables below for the current support boundaries.

### Playback

- Custom AVFoundation player surface shared across visionOS, iOS/iPadOS, tvOS, and the Mac preview.
- Direct Play / Maximum attempts copy or direct-stream paths where viable.
- Explicit quality rungs request capped server streams when needed.
- Resume, seek, retry, subtitles, chapters, playback speed, buffering state, and Stats for Nerds.
- On visionOS, Cinema mode expands playback into an app-owned immersive surface with the same transport controls.
- Watch progress, mark-watched behavior, Up Next, and episode autoplay.

### Libraries and search

- Home, library, search, and detail surfaces for personal media.
- TV hierarchy navigation from show to season to episode.
- Music browsing and playback for supported backend music libraries.
- Backend-aware sign-in and server/session restore.

### Downloads and offline

Downloads and offline playback are available on visionOS, iOS/iPadOS, and the Mac preview. The
tvOS target deliberately omits the complete download capability and Offline product surface.

- Offline downloads with metadata, poster/side-asset support, integrity checks, and route-specific recovery: static/original and server-prepared static files use checkpoints, while live remux/transcode streams reconcile safely but may need retry/restart after interruption.
- Direct original downloads only when Labstream expects the file to be locally playable.
- Server-prepared or server-rendered compatible files when the original is not a safe offline target.

### Privacy and diagnostics

- Canonical app builds store tokens and server credentials in Keychain. The Plex account token is
  the one synchronizable Keychain item; per-device client identity, Jellyfin/Emby tokens, and server
  selection remain device-local. Per-worktree Mac preview builds use isolated, backup-excluded
  credential files instead.
- Diagnostic logging is off by default and local-only. When enabled, events are kept in a bounded
  in-memory ring and small rotating redacted files; reports leave the device only after a user action.
- Built-in bug-report diagnostics redact tokens, client identifiers, hostnames/IPs, full URLs, usernames, library paths, filenames, and media titles.

## Supported backends

| Backend | Sign-in | Core support |
| --- | --- | --- |
| Plex | Plex PIN/OAuth and server discovery | Implemented across browse, search, playback, progress, music, and downloads/offline; primary live-test backend. |
| Jellyfin | Server URL plus Jellyfin auth or Quick Connect | Browse, search, playback, progress, music, and downloads/offline paths are implemented; live coverage varies by server and media. |
| Emby | Emby Connect PIN or manual server login | Browse, search, playback, progress, music, and downloads/offline paths are implemented; live coverage varies by server and media. |

Labstream is unofficial and independent. It is not affiliated with, endorsed by, sponsored by, or officially supported by Plex, the Jellyfin project, or Emby Media.

## Platform status

| Platform | Target / scheme | Current status |
| --- | --- | --- |
| Apple Vision Pro / visionOS 26 | `Labstream` | Primary development and validation path. Includes the app-owned immersive cinema surface. |
| iPhone / iOS 26.1+ | `LabstreamMobile` | Native adaptive mobile shell in active development. Local simulator and signed-device builds are supported. |
| iPad / iPadOS 26.1+ | `LabstreamMobile` | The same universal mobile target, using the regular-width sidebar layout. Local simulator and signed-device builds are supported. |
| Apple TV / tvOS 26+ | `LabstreamTV` | Native streaming-only development target with a ten-foot shell and custom Siri Remote player interactions. Downloads and Offline are absent; physical-device, parity, accessibility, system-integration, and release acceptance remain open. |
| Apple-silicon Mac / macOS 26 | `LabstreamMac` | Local-build development preview only; not a supported distribution target or compatibility promise. Shared sign-in, playback, media-key, and background-download code is present, but live Mac validation is not yet equivalent to the primary visionOS lane. |

## Tech stack

- SwiftUI app shells targeting visionOS 26, iOS/iPadOS 26.1+, and tvOS 26+, plus a macOS 26 development-preview target.
- Swift 6 with strict concurrency.
- Custom AVFoundation playback and offline playback paths.
- `PMSKit`, a local Swift package for Plex/Jellyfin/Emby request builders, models,
  diagnostics primitives, policy state machines, and narrow reusable networking/storage infrastructure.
- MkDocs Material documentation built from the checked-in `docs/` source.

## Quick start

### Requirements

- macOS with Xcode 27 plus the SDK/runtime for each target being built: visionOS 26, iOS/iPadOS 26.1+, or tvOS 26+.
- A compatible simulator runtime for visionOS, iPhone/iPad, or Apple TV work, or paired physical hardware for the device acceptance being performed.
- Python 3.11+ and [`uv`](https://docs.astral.sh/uv/getting-started/installation/) for documentation and repository tooling checks.
- A Plex, Jellyfin, or Emby server you control or have permission to access.

The optional `LabstreamMac` development preview builds directly for an Apple-silicon Mac running
macOS 26; it has no simulator lane.

### Build and smoke

[`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md) is the canonical executable workflow:

- Before the first visionOS build or linked visionOS worktree, [select or create and record the initial visionOS simulator](docs/DEVELOPMENT.md#bootstrap-the-first-visionos-simulator). Mobile-only and tvOS-only work do not require this bootstrap.
- Build the primary [`Labstream` visionOS scheme](docs/DEVELOPMENT.md#build-for-the-visionos-simulator), the universal [`LabstreamMobile` iPhone/iPad scheme](docs/DEVELOPMENT.md#build-for-an-iphone-or-ipad-simulator), or the [`LabstreamTV` Apple TV scheme](docs/DEVELOPMENT.md#build-for-an-apple-tv-simulator).
- Complete the [exact-product install, observable launch/log/screenshot smoke, and simulator shutdown](docs/DEVELOPMENT.md#install-and-observe-a-simulator-smoke).
- Run the [core validation commands](docs/DEVELOPMENT.md#core-validation-commands) and clean up any [linked-worktree simulators](docs/DEVELOPMENT.md#linked-worktree-simulator-cleanup).

### Physical devices and Mac preview

- Apple Vision Pro: complete the [first-use pairing, Developer Mode, Xcode account/signing, install, and launch procedure](docs/DEVELOPMENT.md#physical-apple-vision-pro-install).
- iPhone/iPad: use the canonical [signed hardware install procedure](docs/DEVELOPMENT.md#physical-iphone-or-ipad-install).
- Apple TV: simulator procedures are documented today; physical Apple TV deployment and acceptance remain open development gates in the [tvOS target guide](docs/TVOS.md).
- Apple-silicon Mac: use the [host development-preview procedure](docs/DEVELOPMENT.md#build-and-run-the-macos-development-preview).

The visionOS, mobile, and tvOS app targets currently use `com.jlipworth.Labstream`. The Mac helper
defaults to a per-worktree development bundle identifier so local host
builds do not collide; see [macOS development preview](docs/MACOS.md).

## Project structure

```text
Labstream/
├── Labstream/             # app-owned source, split by capability and platform ownership
│   ├── Shared/            # universal app core, backend facades, player, music, and shared UI
│   ├── Capabilities/
│   │   └── Downloads/ # visionOS, mobile, and Mac offline engine/UI; absent from tvOS
│   └── Platforms/
│       ├── visionOS/      # vision app entry point, Cinema, scoped system media, SharePlay
│       ├── Mobile/        # universal iPhone/iPad entry point and mobile player integration
│       ├── macOS/         # single-window Mac entry point and desktop player integration
│       └── tvOS/          # streaming-only TV entry point and Debug fixture ownership
├── PMSKit/                # reusable requests, models, policies, infrastructure, and tests
├── docs/                  # current docs plus plans, research, evidence, and archive lanes
├── scripts/               # local validation, simulator, deploy, and probe helpers
└── .woodpecker/           # portable CI definitions
```

## Documentation

- Documentation source and local site build: [`docs/`](docs/)
- Release and App Store status: [`docs/RELEASES.md`](docs/RELEASES.md)
- Development setup: [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md)
- iOS/iPadOS target: [`docs/MOBILE-IOS.md`](docs/MOBILE-IOS.md)
- tvOS target: [`docs/TVOS.md`](docs/TVOS.md)
- macOS development preview: [`docs/MACOS.md`](docs/MACOS.md)
- Architecture overview: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)
- Backend model: [`docs/BACKENDS.md`](docs/BACKENDS.md)
- Playback: [`docs/PLAYBACK-ARCHITECTURE.md`](docs/PLAYBACK-ARCHITECTURE.md)
- Downloads/offline: [`docs/DOWNLOADS-OFFLINE.md`](docs/DOWNLOADS-OFFLINE.md)
- Diagnostics/privacy: [`docs/DIAGNOSTICS-PRIVACY.md`](docs/DIAGNOSTICS-PRIVACY.md)
- Compile performance: [`docs/COMPILE-PERFORMANCE.md`](docs/COMPILE-PERFORMANCE.md)
- Manual validation checklist: [`TESTING-CHECKLIST.md`](TESTING-CHECKLIST.md)

Public pages at the top of `docs/` describe the current app. Internal documents use explicit unpublished lanes: active implementation plans and acceptance journals in `docs/plans/`, unresolved investigations in `docs/research/`, immutable audit/profiling observations in `docs/evidence/`, and completed or superseded context in `docs/archive/`. The repository-root `TESTING-CHECKLIST.md` is the deliberate operational exception and remains the current manual validation matrix.

## Contributing

Start with [`docs/CONTRIBUTING.md`](docs/CONTRIBUTING.md). In short:

- keep backend-specific wire behavior explicit;
- put reusable request, model, and policy decisions in `PMSKit`, keeping its few effectful networking/storage utilities narrow and injectable;
- keep SwiftUI, `AVPlayer` ownership, target lifecycle, background-session delegation, Keychain, and app persistence in the app target;
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
- Security reports: [`SECURITY.md`](SECURITY.md) — vulnerabilities must use the private route
- Community conduct: [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md)

## License

Labstream is licensed under the **GNU General Public License v3.0**. See [`LICENSE`](LICENSE) for the full text.

The project also carries a GPLv3 section 7 additional permission for the visionOS/iOS/iPadOS Apple
App Store and TestFlight paths if those distribution channels are used. It does not establish Mac
or tvOS distribution approval; see [`APP-STORE-EXCEPTION.md`](APP-STORE-EXCEPTION.md).

Copyright (C) 2026 Jonathan Lipworth

<p align="center">
  <a href="https://www.gnu.org/licenses/gpl-3.0.en.html">
    <img src="https://www.gnu.org/graphics/gplv3-with-text-136x68.png" alt="GNU GPLv3" width="136" height="68">
  </a>
</p>
