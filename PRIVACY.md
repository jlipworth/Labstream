# VisionPlay — Privacy Policy

_Last updated: 2026-06-26_

VisionPlay is a personal media client for Apple Vision Pro that connects to a
Plex Media Server, Jellyfin server, or Emby server **that you choose and
control**. It is designed to collect as little as possible.

## What VisionPlay does not do

- **No data is collected by or sent to the developer.** There is no analytics,
  no developer-operated telemetry pipeline, no crash reporting to the developer,
  and no advertising.
- **No tracking.** VisionPlay does not track you across apps or websites and
  contains no third-party tracking SDKs.
- **No developer servers.** VisionPlay communicates only with the media backend
  you configure. Plex sign-in uses Plex (`plex.tv`) plus the Plex Media Server
  you select; Jellyfin mode talks to the Jellyfin server URL you enter; Emby
  mode uses Emby Connect (`emby.media`) for PIN sign-in when selected and then
  talks to the Emby server URL you choose.

## What stays on your device

- **Your media-server credentials/tokens** are stored in the iOS/visionOS
  **Keychain** on your device. Plex tokens are sent only to Plex and the selected
  Plex server; Jellyfin access tokens are sent only to your Jellyfin server;
  Emby access tokens are sent only to Emby Connect during sign-in and to your
  selected Emby server. They are never transmitted to the developer.
- **Playback preferences and resume positions** are stored locally
  (UserDefaults) and, where applicable, reported to your selected media server as
  that backend's normal playback-state/progress feature.
- **Offline downloads** you choose to make are stored in the app's private
  container on your device and can be deleted at any time from within the app or
  by removing the app.
- **Spotlight, Siri, and Shortcuts media suggestions** can expose browsed media
  titles and summaries to Apple system surfaces on your device. You can turn this
  off in Settings with **Show Media in Spotlight & Siri**; turning it off stops
  new Spotlight indexing, clears VisionPlay's Spotlight index, and removes media
  title entity results from VisionPlay's Shortcuts/App Intents queries.
- **Opt-in diagnostic logs** are off by default. If you enable diagnostic logging
  in Settings, VisionPlay keeps recent app events in a bounded local ring buffer
  so you can copy a bug-report summary after reproducing a problem. This
  diagnostic report is user-initiated only and is not uploaded automatically.
- **Passive MetricKit crash/hang summaries** may be delivered by visionOS after a
  bad run and stored locally in a small bounded list. VisionPlay keeps only
  redacted summary fields for inclusion in a report you explicitly preview/copy/
  export; these summaries are not uploaded automatically and are separate from
  opt-in event logging.

## Diagnostic reports

When you tap **Copy diagnostic report**, export a report, or open the feedback
sheet, VisionPlay includes safe app/server product/version information, backend
name, connection scheme, selected quality settings, a recent playback snapshot
when available, passive redacted MetricKit summaries when present, and recent
redacted events when diagnostic logging was enabled. The diagnostics API and
report renderer are designed to omit sensitive values such as Plex/Jellyfin/Emby
tokens, client identifiers, hostnames/IP addresses, full URLs, usernames,
library paths, filenames, and media titles.

The optional free-form feedback note is best-effort scrubbed and shown in the
preview before sharing, but ordinary prose can still contain a media title or
personal detail that automated redaction cannot identify. Review the preview and
edit anything you do not want to make public before opening a GitHub issue or
sharing the report.

Diagnostic logging does not add analytics, developer telemetry, remote log
upload, or background reporting. The report leaves your device only if you
choose to paste, attach, or share it somewhere.

## Data shared with Plex, Jellyfin, and Emby

When you sign in and stream with Plex, VisionPlay talks to Plex and to your
server for account sign-in, library browsing, playback, and playback-state
reporting. That interaction is governed by **Plex's own privacy policy**
(<https://www.plex.tv/about/privacy-legal/>), not by the developer of
VisionPlay.

When you use Jellyfin, VisionPlay talks directly to the Jellyfin server URL you
configure. That server is controlled by you or your server administrator.

When you use Emby, VisionPlay can use Emby Connect for PIN sign-in and then talks
to the Emby server URL you select or enter. Emby Connect and your Emby server are
controlled by Emby Media or your server administrator, not by the developer of
VisionPlay.

## Children

VisionPlay is not directed at children and collects no personal information.

## Contact

Questions about privacy: open an issue at
<https://github.com/jlipworth/VisionPlay/issues> (or the support contact listed
in the App Store).

## Changes

If this policy changes, the updated version will be published at the same URL
with a new "last updated" date.
