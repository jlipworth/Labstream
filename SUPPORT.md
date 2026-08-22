# Labstream — Support

Labstream is a native Apple-platform client for **your own Plex Media Server, Jellyfin server, or Emby server**.

The repository contains pre-release targets for Apple Vision Pro, iPhone/iPad, Apple TV, and Mac.
That source coverage does not by itself assert availability in any binary distribution channel;
there is no public App Store release yet. Platform-specific status and acceptance gates are in the
[release guide](https://github.com/jlipworth/Labstream/blob/main/docs/RELEASES.md),
[Mac target guide](https://github.com/jlipworth/Labstream/blob/main/docs/MACOS.md), and
[tvOS target guide](https://github.com/jlipworth/Labstream/blob/main/docs/TVOS.md).

## Requirements

- Apple Vision Pro running **visionOS 26.0** or later; an iPhone/iPad running **iOS/iPadOS 26.1**
  or later; Apple TV running **tvOS 26** or later; or an Apple-silicon Mac running **macOS 26**.
- A reachable **Plex Media Server**, **Jellyfin server**, or **Emby server** you administer or have access to.
  Plex mode requires a Plex account for PIN/OAuth sign-in; Emby mode can use Emby Connect PIN sign-in or a manual Emby server URL.
- Labstream does not provide, host, sell, or bundle media. Playback and offline
  downloads are for media you are authorized to access on the server you choose.
- Local-network playback is free. Under Plex's current
  [remote playback requirements](https://support.plex.tv/articles/requirements-for-remote-playback-of-personal-media/),
  remote (off-LAN) **video** streaming can require
  Plex Pass or Remote Watch Pass on your account, or Plex Pass on the server owner's
  account. This is a Plex service policy, not a Labstream feature.

## Getting started

1. Launch Labstream and choose Plex, Jellyfin, or Emby.
2. Sign in to the selected backend and choose/enter the server.
3. Browse your libraries, then play. Titles resume where you left off.

## Common questions

- **A reinstall asks me to sign in again.** A normal upgrade install usually preserves app state.
  Deleting Labstream, erasing the simulator/device, or replacing a distribution build with a
  development build can reset the app container and selected-session state. Canonical credentials
  are Keychain-backed, but availability can still differ by identity, device, and Keychain state,
  so a fresh sign-in may be required.
- **Playback failed / spinner won't clear.** Labstream has a stall watchdog
  that can attempt a bounded recovery and otherwise surfaces a **Playback failed** / Retry overlay.
  Choosing Retry rebuilds the player. If the problem persists, confirm the server is reachable and
  try a lower streaming quality in Settings.
- **Can I watch away from home?** Remote Plex video can require Plex Pass / Remote Watch
  Pass on your account, or Plex Pass on the server owner's account (a Plex policy).
  Jellyfin and Emby remote access depend on your server/network setup.

## Reporting a problem

The fastest path is the [bug report form](https://github.com/jlipworth/Labstream/issues/new?template=bug_report.yml).
See the [bug reporting guide](https://github.com/jlipworth/Labstream/blob/main/docs/REPORTING-BUGS.md)
for the step-by-step flow, including what the diagnostic report does and does not include.

Open an issue with steps to reproduce, your device type (Apple Vision Pro, iPhone, iPad, Apple TV,
or Mac), OS version, and the app version from
**Settings ▸ About**:

<https://github.com/jlipworth/Labstream/issues>

For hard-to-reproduce playback, download, or music issues, include a local
diagnostic report if you're comfortable sharing the redacted preview:

1. Open **Settings ▸ Diagnostics**.
2. Turn on **Enable diagnostic logging**.
3. Reproduce the problem once.
4. On visionOS, iPhone, iPad, or Mac, tap **Send feedback to developer**,
   **Copy diagnostic report**, or **Export diagnostic report file**. On Apple TV,
   Copy and Export are not available; use **Send feedback to developer** for the preview/GitHub
   handoff. A long report may not fit in the issue URL, so the handoff does not guarantee that the
   full report transfers.
5. Review the redacted report before sharing it.
6. Turn diagnostic logging off again if you no longer need it.

Diagnostic event logging is opt-in, stored in a bounded in-memory ring plus small rotating
already-redacted local files, and exported only when you tap a copy/export/feedback button.
Passive redacted MetricKit
crash/hang summaries may also be stored locally in a small bounded list for
inclusion in a user-initiated report. The report intentionally omits sensitive
values such as tokens, client identifiers, hostnames/IP addresses, full URLs,
usernames, library paths, filenames, and media titles.

## Privacy

See the [Privacy Policy](https://github.com/jlipworth/Labstream/blob/main/PRIVACY.md). Labstream does
not automatically send analytics, diagnostics, or personal data to the developer. Optional
diagnostic reports stay local unless you choose to copy, export, share, or open a GitHub issue;
ordinary playback progress and other backend operations may still be sent to the media server you
selected.
