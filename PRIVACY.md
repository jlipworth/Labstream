# Labstream — Privacy Policy

_Last updated: 2026-07-05_

Labstream is a personal media client for Apple Vision Pro, iPhone, and iPad that connects to a Plex Media Server, Jellyfin server, or Emby server **that you choose and control**. It is designed to collect as little as possible.

## What Labstream does not do

- **No automatic developer collection.** Labstream does not automatically collect or transmit analytics, diagnostics, crash reports, media-server data, or personal data to the developer. If you choose to copy, export, share, or open a GitHub issue, the redacted report and any note you include leave the device only via GitHub or the destination you choose.
- **No tracking.** Labstream does not track you across apps or websites and
  contains no third-party tracking SDKs.
- **No developer servers.** Labstream has no developer-operated backend. Depending on the backend you choose, it contacts Plex services for sign-in/server discovery plus the Plex Media Server you select, the Jellyfin server URL you enter, or Emby Connect plus your selected Emby server.
- **No bundled media.** Labstream does not provide, host, sell, or bundle movies,
  TV, music, or other media. It connects only to servers you choose, and offline
  downloads are for media you are authorized to access and download under the
  applicable server/service terms.

## What stays on your device

- **Your media-server credentials/tokens** are stored in the Apple **Keychain** on your device. Plex tokens are sent only to Plex and the selected
  Plex server; Jellyfin access tokens are sent only to your Jellyfin server;
  Emby access tokens are sent only to Emby Connect during sign-in and to your
  selected Emby server. They are never transmitted to the developer.
- **Playback preferences and resume positions** are stored locally
  (UserDefaults) and, where applicable, reported to your selected media server as
  that backend's normal playback-state/progress feature.
- **Offline downloads** you choose to make are stored in Labstream's private app
  container on your device and can be deleted from within the app or by removing
  the app.
- **Local Network access** may be requested by iOS/iPadOS/visionOS when your
  selected server is on your local network, uses a `.local` name, or resolves to
  a LAN address. Labstream uses that access only to connect to the media server
  you choose for browsing, playback, and downloads; it does not scan the network
  for advertising or analytics.
- **Spotlight, Siri, and Shortcuts media suggestions** can expose browsed media
  titles and summaries to Apple system surfaces on your device. You can turn this
  off in Settings with **Show Media in Spotlight & Siri**; turning it off stops
  new Spotlight indexing, clears Labstream's Spotlight index, and removes media
  title entity results from Labstream's Shortcuts/App Intents queries.
- **Opt-in diagnostic logs** are off by default. If you enable diagnostic logging
  in Settings, Labstream keeps recent app events in bounded local storage so you
  can copy, export, or share a bug-report summary after reproducing a problem.
  This diagnostic report is user-initiated only and is not uploaded automatically.
- **Passive MetricKit diagnostic summaries** — crash, hang, CPU exception, or disk-write exception — may be delivered by iOS or visionOS after a problematic run and stored locally in a small bounded list. Labstream keeps only redacted summary fields for inclusion in a report you explicitly preview/copy/export; these summaries are not uploaded automatically and are separate from opt-in event logging.

## Diagnostic reports

When you tap **Send feedback to developer**, **Copy diagnostic report**, or
**Export diagnostic report file**, Labstream includes safe app/server
product/version information, backend name, connection scheme, selected quality
settings, Adaptive Bitrate state when available, a recent playback snapshot when
available, passive redacted MetricKit summaries when present, and recent redacted
events when diagnostic logging was enabled. The diagnostics API and report
renderer are designed to omit sensitive values such as Plex/Jellyfin/Emby tokens,
client identifiers, hostnames/IP addresses, full URLs, usernames, library paths,
filenames, and media titles.

The optional free-form feedback note is best-effort scrubbed and shown in the
preview before sharing, but ordinary prose can still contain a media title or
personal detail that automated redaction cannot identify. Review the preview and
edit anything you do not want to make public before opening a GitHub issue or
sharing the report.

Diagnostic logging does not add analytics, developer telemetry, remote log upload, or background reporting. The report leaves your device only if you choose to copy, export, paste, attach, share it somewhere, or open a GitHub issue.

## Data shared with Plex, Jellyfin, and Emby

When you sign in and stream with Plex, Labstream talks to Plex and to your
server for account sign-in, library browsing, playback, and playback-state
reporting. That interaction is governed by **Plex's own privacy policy**
(<https://www.plex.tv/about/privacy-legal/>), not by the developer of
Labstream.

When you use Jellyfin, Labstream talks directly to the Jellyfin server URL you
configure. That server is controlled by you or your server administrator.

When you use Emby, Labstream can use Emby Connect for PIN sign-in and then talks
to the Emby server URL you select or enter. Emby Connect and your Emby server are
controlled by Emby Media or your server administrator, not by the developer of
Labstream.

## Children

Labstream is not directed at children and collects no personal information.

## Contact

Questions about privacy: open an issue at
<https://github.com/jlipworth/Labstream/issues>.

## Changes

If this policy changes, the updated version will be published at the same URL
with a new "last updated" date.
