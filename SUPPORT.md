# VisionPlex — Support

VisionPlex is a native Apple Vision Pro client for **your own Plex Media Server**.

## Requirements

- Apple Vision Pro running **visionOS 26.0** or later.
- A **Plex account** (free) and a reachable **Plex Media Server** you administer
  or have access to.
- Local-network playback is free. Remote (off-LAN) streaming may require Plex
  Pass or Remote Watch Pass on your account — this is a Plex server-side
  requirement, not a VisionPlex feature.

## Getting started

1. Launch VisionPlex and sign in with your Plex account (PIN / OAuth).
2. The app discovers your servers; pick the one you want.
3. Browse your libraries, then play. Titles resume where you left off.

## Common questions

- **A re-install asks me to sign in again.** Reinstalling clears the app's
  container, including the stored token, so a fresh sign-in is expected.
- **Playback failed / spinner won't clear.** VisionPlex has a stall watchdog
  that surfaces a "Playback failed" overlay and rebuilds the player. If it
  persists, confirm the server is reachable and try a lower streaming quality in
  Settings.
- **Can I watch away from home?** Remote streaming of personal media may require
  Plex Pass / Remote Watch Pass on your Plex account (a Plex policy).

## Reporting a problem

Open an issue with steps to reproduce, your visionOS version, and the app
version (Settings):

<https://github.com/jlipworth/VisionPlex/issues>

For hard-to-reproduce playback, download, or music issues, you can include a
local diagnostic report:

1. Open **Settings ▸ Diagnostics**.
2. Turn on **Enable diagnostic logging**.
3. Reproduce the problem once.
4. Tap **Copy diagnostic report** and paste it into the issue.
5. Turn diagnostic logging off again if you no longer need it.

Diagnostics are opt-in, stored in a bounded local ring buffer, and exported only
when you tap the copy button. The report intentionally omits sensitive values
such as tokens, client identifiers, hostnames/IP addresses, full URLs, usernames,
library paths, filenames, and media titles.

## Privacy

See [PRIVACY.md](PRIVACY.md). VisionPlex collects no data and sends nothing to
the developer.
