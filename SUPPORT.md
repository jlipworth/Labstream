# VisionPlay — Support

VisionPlay is a native Apple Vision Pro client for **your own Plex Media Server, Jellyfin server, or Emby server**.

## Requirements

- Apple Vision Pro running **visionOS 26.0** or later.
- A reachable **Plex Media Server**, **Jellyfin server**, or **Emby server** you administer or have access to.
  Plex mode requires a Plex account for PIN/OAuth sign-in; Emby mode can use Emby Connect PIN sign-in or a manual Emby server URL.
- Local-network playback is free. Plex remote (off-LAN) streaming may require Plex
  Pass or Remote Watch Pass on your account — this is a Plex server-side
  requirement, not a VisionPlay feature.

## Getting started

1. Launch VisionPlay and choose Plex, Jellyfin, or Emby.
2. Sign in to the selected backend and choose/enter the server.
3. Browse your libraries, then play. Titles resume where you left off.

## Common questions

- **A reinstall asks me to sign in again.** A normal upgrade install usually
  preserves app state. Deleting VisionPlay, erasing the simulator/device, or
  replacing an App Store/TestFlight build with a development build can clear the
  app container, including stored tokens, so sign-in is expected.
- **Playback failed / spinner won't clear.** VisionPlay has a stall watchdog
  that surfaces a "Playback failed" overlay and rebuilds the player. If it
  persists, confirm the server is reachable and try a lower streaming quality in
  Settings.
- **Can I watch away from home?** Remote streaming of personal media may require
  Plex Pass / Remote Watch Pass on your Plex account in Plex mode (a Plex policy).
  Jellyfin and Emby remote access depend on your server/network setup.

## Reporting a problem

The fastest path is the [bug report form](https://github.com/jlipworth/VisionPlay/issues/new?template=bug_report.yml).
See the [bug reporting guide](https://github.com/jlipworth/VisionPlay/blob/main/docs/REPORTING-BUGS.md)
for the step-by-step flow, including what the diagnostic report does and does not include.

Open an issue with steps to reproduce, your visionOS version, and the app
version from **Settings ▸ About**:

<https://github.com/jlipworth/VisionPlay/issues>

For hard-to-reproduce playback, download, or music issues, include a local
diagnostic report if you're comfortable sharing the redacted preview:

1. Open **Settings ▸ Diagnostics**.
2. Turn on **Enable diagnostic logging**.
3. Reproduce the problem once.
4. Tap **Send feedback to developer**, **Copy diagnostic report**, or
   **Export diagnostic report file**.
5. Review the redacted report before sharing it.
6. Turn diagnostic logging off again if you no longer need it.

Diagnostic event logging is opt-in, stored in bounded local storage, and exported
only when you tap a copy/export/feedback button. Passive redacted MetricKit
crash/hang summaries may also be stored locally in a small bounded list for
inclusion in a user-initiated report. The report intentionally omits sensitive
values such as tokens, client identifiers, hostnames/IP addresses, full URLs,
usernames, library paths, filenames, and media titles.

## Privacy

See the [Privacy Policy](https://github.com/jlipworth/VisionPlay/blob/main/PRIVACY.md). VisionPlay sends no analytics,
diagnostics, or personal data to the developer; app state and optional
diagnostic reports stay local unless you choose to share them.
