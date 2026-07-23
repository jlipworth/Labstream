# Labstream — Support

Labstream is a native Apple-platform client for **your own Plex Media Server, Jellyfin server, or Emby server**.

The supported product paths documented here are Apple Vision Pro, iPhone, and iPad. The source
repository also contains native Mac and tvOS targets as local-build development previews; they are
not yet released or supported App Store products. Contributors testing those previews should use
the [Mac development documentation](https://github.com/jlipworth/Labstream/blob/main/docs/MACOS.md)
and [tvOS documentation](https://github.com/jlipworth/Labstream/blob/main/docs/TVOS.md).

## Requirements

- Apple Vision Pro running **visionOS 26.0** or later, or an iPhone/iPad running **iOS/iPadOS 26.1** or later.
- A reachable **Plex Media Server**, **Jellyfin server**, or **Emby server** you administer or have access to.
  Plex mode requires a Plex account for PIN/OAuth sign-in; Emby mode can use Emby Connect PIN sign-in or a manual Emby server URL.
- Labstream does not provide, host, sell, or bundle media. Playback and offline
  downloads are for media you are authorized to access on the server you choose.
- Local-network playback is free. Plex remote (off-LAN) **video** streaming can require
  Plex Pass or Remote Watch Pass on your account, or Plex Pass on the server owner's
  account. This is a Plex service policy, not a Labstream feature.

## Getting started

1. Launch Labstream and choose Plex, Jellyfin, or Emby.
2. Sign in to the selected backend and choose/enter the server.
3. Browse your libraries, then play. Titles resume where you left off.

## Common questions

- **A reinstall asks me to sign in again.** A normal upgrade install usually
  preserves app state. Deleting Labstream, erasing the simulator/device, or
  replacing an App Store/TestFlight build with a development build can clear the
  app container, including stored tokens, so sign-in is expected.
- **Playback failed / spinner won't clear.** Labstream has a stall watchdog
  that surfaces a "Playback failed" overlay and rebuilds the player. If it
  persists, confirm the server is reachable and try a lower streaming quality in
  Settings.
- **Can I watch away from home?** Remote Plex video can require Plex Pass / Remote Watch
  Pass on your account, or Plex Pass on the server owner's account (a Plex policy).
  Jellyfin and Emby remote access depend on your server/network setup.

## Reporting a problem

The fastest path is the [bug report form](https://github.com/jlipworth/Labstream/issues/new?template=bug_report.yml).
See the [bug reporting guide](https://github.com/jlipworth/Labstream/blob/main/docs/REPORTING-BUGS.md)
for the step-by-step flow, including what the diagnostic report does and does not include.

Open an issue with steps to reproduce, your device type (Apple Vision Pro, iPhone, iPad, or Mac
development preview), OS version, and the app version from **Settings ▸ About**:

<https://github.com/jlipworth/Labstream/issues>

For hard-to-reproduce playback, download, or music issues, include a local
diagnostic report if you're comfortable sharing the redacted preview:

1. Open **Settings ▸ Diagnostics**.
2. Turn on **Enable diagnostic logging**.
3. Reproduce the problem once.
4. Tap **Send feedback to developer**, **Copy diagnostic report**, or
   **Export diagnostic report file**.
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

See the [Privacy Policy](https://github.com/jlipworth/Labstream/blob/main/PRIVACY.md). Labstream does not automatically send analytics, diagnostics, or personal data to the developer; app state and optional diagnostic reports stay local unless you choose to copy, export, share, or open a GitHub issue.
