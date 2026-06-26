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

- **A re-install asks me to sign in again.** Reinstalling clears the app's
  container, including the stored token, so a fresh sign-in is expected.
- **Playback failed / spinner won't clear.** VisionPlay has a stall watchdog
  that surfaces a "Playback failed" overlay and rebuilds the player. If it
  persists, confirm the server is reachable and try a lower streaming quality in
  Settings.
- **Can I watch away from home?** Remote streaming of personal media may require
  Plex Pass / Remote Watch Pass on your Plex account in Plex mode (a Plex policy).
  Jellyfin and Emby remote access depend on your server/network setup.

## Reporting a problem

The fastest path is the [bug report form](https://github.com/jlipworth/VisionPlay/issues/new?template=bug_report.yml);
see [docs/REPORTING-BUGS.md](docs/REPORTING-BUGS.md) for the full step-by-step guide
(including what the diagnostic report does and does not include).

Open an issue with steps to reproduce, your visionOS version, and the app
version (Settings):

<https://github.com/jlipworth/VisionPlay/issues>

For hard-to-reproduce playback, download, or music issues, you can include a
local diagnostic report:

1. Open **Settings ▸ Diagnostics**.
2. Turn on **Enable diagnostic logging**.
3. Reproduce the problem once.
4. Tap **Copy diagnostic report** and paste it into the issue.
5. Turn diagnostic logging off again if you no longer need it.

Diagnostic event logging is opt-in, stored in a bounded local ring buffer, and exported only
when you tap the copy/export/feedback button. Passive redacted MetricKit crash/hang summaries may also be stored locally in a small bounded list for inclusion in a user-initiated report. The report intentionally omits sensitive values
such as tokens, client identifiers, hostnames/IP addresses, full URLs, usernames,
library paths, filenames, and media titles.

## Privacy

See [PRIVACY.md](https://github.com/jlipworth/VisionPlay/blob/main/PRIVACY.md). VisionPlay collects no data and sends nothing to
the developer.
