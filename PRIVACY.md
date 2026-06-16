# VisionPlex — Privacy Policy

_Last updated: 2026-06-16_

VisionPlex is a personal media client for Apple Vision Pro that connects to a
Plex Media Server **that you choose and control**. It is designed to collect as
little as possible.

## What VisionPlex does not do

- **No data is collected by or sent to the developer.** There is no analytics,
  no telemetry, no crash reporting to the developer, and no advertising.
- **No tracking.** VisionPlex does not track you across apps or websites and
  contains no third-party tracking SDKs.
- **No third-party servers.** VisionPlex communicates only with Plex
  (`plex.tv`, for sign-in) and the Plex Media Server you point it at.

## What stays on your device

- **Your Plex authentication token** is stored in the iOS/visionOS **Keychain**
  on your device. It is sent only to Plex and to your own server to authenticate
  requests. It is never transmitted to the developer.
- **Playback preferences and resume positions** are stored locally
  (UserDefaults) and, where applicable, reported to your Plex server as Plex's
  normal playback-state ("scrobble") feature.
- **Offline downloads** you choose to make are stored in the app's private
  container on your device and can be deleted at any time from within the app or
  by removing the app.
- **Opt-in diagnostics** are off by default. If you enable diagnostic logging in
  Settings, VisionPlex keeps recent app events in a bounded local ring buffer so
  you can copy a bug-report summary after reproducing a problem. This diagnostic
  report is user-initiated only and is not uploaded automatically.

## Diagnostic reports

When you tap **Copy diagnostic report**, VisionPlex includes safe app/server
version information, the selected quality setting, a recent playback snapshot
when available, and recent redacted events. The diagnostics API and report
renderer are designed to omit sensitive values such as Plex tokens, client
identifiers, hostnames/IP addresses, full URLs, usernames, library paths,
filenames, and media titles.

Diagnostic logging does not add analytics, developer telemetry, remote log
upload, or background reporting. The report leaves your device only if you
choose to paste or attach it somewhere.

## Data shared with Plex

When you sign in and stream, VisionPlex talks to Plex and to your server exactly
as an official Plex client would (account sign-in, library browsing, playback,
playback-state reporting). That interaction is governed by **Plex's own privacy
policy** (<https://www.plex.tv/about/privacy-legal/>), not by the developer of
VisionPlex.

## Children

VisionPlex is not directed at children and collects no personal information.

## Contact

Questions about privacy: open an issue at
<https://github.com/jlipworth/VisionPlex/issues> (or the support contact listed
in the App Store).

## Changes

If this policy changes, the updated version will be published at the same URL
with a new "last updated" date.
