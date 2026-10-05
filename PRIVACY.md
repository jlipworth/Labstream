# Labstream — Privacy Policy

_Last updated: 2026-10-04_

Labstream is a personal media client with pre-release targets for Apple Vision Pro, iPhone/iPad,
Apple TV, and Mac. It connects to a Plex Media Server, Jellyfin server, or Emby server **that you
administer or are authorized to access**. Labstream is designed to collect as little as possible.

## What Labstream does not do

- **No automatic app telemetry.** Labstream has no automatic developer analytics,
  diagnostic-report upload, or crash-report upload. Ordinary server requests are separate:
  the server you select receives authentication, browsing, and playback requests.
- **No tracking.** Labstream does not track you across apps or websites and
  contains no third-party tracking SDKs.
- **Your choice of server.** Normal use connects to Plex services and your selected Plex
  server, your configured Jellyfin server, or Emby Connect and your selected Emby server.
  You do not need a Labstream-operated server for ordinary use. The project does operate a
  separate optional review/demo service, described below.
- **No app-bundled media or media subscription.** The app does not bundle or sell movies,
  TV, or music. The separate review/demo service hosts licensed sample content. Playback and
  offline downloads are for media you are authorized to access under the server/service terms.

## Device storage and server communication

- **Your media-server credentials/tokens** are stored in the Apple **Keychain** on visionOS,
  iOS/iPadOS, tvOS, and canonical production-style Mac builds. The Plex account token is the
  only synchronizable Keychain item, so it may sync through your iCloud Keychain to your other
  Labstream devices. The per-device client identifier, Jellyfin and Emby tokens, and selected
  backend/server do not sync. Plex tokens are sent only to Plex and the selected
  Plex server; Jellyfin access tokens are sent only to your Jellyfin server;
  Emby access tokens are sent only to Emby Connect during sign-in and to your
  selected Emby server. If you explicitly select the project-operated review/demo
  server, its credentials and tokens are exchanged with that service, operated by the developer;
  credentials for your other servers are not sent to it.
- **Noncanonical Mac development builds** created by the host deploy helper use an
  isolated, backup-excluded credential file inside that development app's sandbox instead of the
  production Keychain path. This avoids repeated Keychain prompts while an ad-hoc local build is
  replaced. Deleting/resetting that development identity's container deletes those credentials.
- **Playback preferences and resume positions** are stored locally
  (UserDefaults) and, where applicable, reported to your selected media server as
  that backend's normal playback-state/progress feature.
- **Offline downloads** you choose to make are stored in Labstream's private app
  container on your device and can be deleted from within the app or by removing
  the app.
- **Local Network access** may be requested by Labstream's Apple-platform builds, including tvOS,
  when your
  selected server is on your local network, uses a `.local` name, or resolves to
  a LAN address. Labstream uses that access only to connect to the media server
  you choose for browsing and playback, and for downloads where available; it does not scan the network
  for advertising or analytics.
- **Spotlight, Siri, and Shortcuts media suggestions** can expose browsed media
  titles and summaries to Apple system surfaces on your device. You can turn this
  off in Settings with **Show Media in Spotlight & Siri**; turning it off stops
  new Spotlight indexing, clears Labstream's Spotlight index, and removes media
  title entity results from Labstream's Shortcuts/App Intents queries.
- **Opt-in diagnostic logs** are off by default. If you enable diagnostic logging
  in Settings, Labstream keeps recent already-redacted app events in a 300-event
  in-memory ring and in small rotating local diagnostic files (one active file plus
  up to three archives, approximately 1 MB each). The rotating files exist so a
  user-initiated headset evidence collection can survive a suspension or termination;
  the same redacted event summaries may also appear in Apple's local unified log, and the in-app
  report uses the current process's ring buffer. You can copy, export, or
  share a bug-report summary after reproducing a problem.
  This diagnostic report is user-initiated only and is not uploaded automatically.
- **Passive MetricKit diagnostic summaries** — on non-tvOS builds, crash, hang, CPU exception, or
  disk-write exception summaries may be delivered by an Apple operating system after a problematic
  run and stored locally in a small bounded list. Labstream keeps only redacted summary fields for
  inclusion in a report you explicitly preview/copy/export; these summaries are not uploaded
  automatically and are separate from opt-in event logging.

## Diagnostic reports

When you tap **Send feedback to developer**, **Copy diagnostic report**, or
**Export diagnostic report file** (Copy and Export are available on visionOS,
iPhone, iPad, and Mac; Apple TV uses the feedback/GitHub handoff), Labstream includes safe app/server
product/version/build information, platform and safely redacted app identity,
backend and server product (plus version where available), connection scheme, selected quality
settings, Adaptive Bitrate state, download/storage state on download-capable products, a recent
playback snapshot when available, passive redacted MetricKit summaries when present, and up to 80 recent
redacted events from the current process when diagnostic logging was enabled. The diagnostics API and report
renderer are designed to omit sensitive values such as Plex/Jellyfin/Emby tokens,
client identifiers, hostnames/IP addresses, full URLs, usernames, library paths,
filenames, and media titles.

The optional free-form feedback note is best-effort scrubbed and shown in the
preview before sharing, but ordinary prose can still contain a media title or
personal detail that automated redaction cannot identify. Other personal labels may also remain
after generic redaction. Review the preview and
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
configure. That server is controlled by you or your server administrator; when you
select the project-operated review/demo service, the project is that administrator.

When you use Emby, Labstream can use Emby Connect for PIN sign-in and then talks
to the Emby server URL you select or enter. Emby Connect and your Emby server are
controlled by Emby Media or your server administrator, not by the developer of
Labstream.

## Optional project-operated review/demo service

The project operates an isolated Jellyfin service for App Review and controlled demonstrations,
with licensed sample media rather than a personal library. It is not an app-bundled catalog and
Labstream does not automatically connect ordinary users to it.

If you use that service, the project and its infrastructure providers process the requests needed
to authenticate, browse, stream, download, and maintain playback state. These include the review
account, access tokens, app/device identity and version, network connection information (including
IP addresses at the network edge), requested sample items, sessions, and playback progress.
Jellyfin stores account/device/authentication and activity information in its persistent database;
service administrators can access operational data. Shared review-account progress is not private
from other users of that account. Do not use a personal password or submit personal media there.

The service uses HTTPS, a non-admin review account, restricted infrastructure access, and read-only
sample media. The configured application route disables proxy access logs. Jellyfin warning/error
logs remain enabled; they are not the app's opt-in diagnostic reports. Operational logs and backups
may retain information beyond a request. The public edge provider also processes traffic; disabling
one proxy's access logs does not establish that no provider records exist.

A scheduled daily reset clears sample-item playback positions, played state, play counts and
favorites. **It is not deletion of all session, authentication, activity, log or backup records.**
Application file logging is configured for daily/size rotation with three retained files, but that
is not a service-wide deletion deadline. Database, centralized-log, edge-provider and backup
retention/deletion coverage is still being verified; no fixed maximum retention is promised here.
Contact the project using the privacy contact below for review-service data questions or deletion
requests. Do not post credentials or private connection details in a public issue.

## Submitted feedback and retention

Copying a report or saving a file locally does not by itself submit it to the developer. Opening
the prefilled GitHub form sends its included fields to GitHub before you publish the issue;
submitting an issue makes its contents and GitHub account association public. Sharing or attaching
an export sends it to the destination you choose. GitHub and other destinations apply their own
privacy and retention practices. Submitted issues may remain in project history; local report
rotation or deleting the app does not delete those copies. Review the report and free-form note
before every handoff. The project uses submitted feedback for support and troubleshooting, not
advertising, cross-app tracking, or sale. Whether received reports or attachments are also
stored outside GitHub has not yet been verified. No GitHub-only storage claim or fixed
project-wide retention/deletion period is made.

## Children

Labstream is not directed at children. Avoid including children's personal information in the
shared review service or public feedback. The server and feedback practices above apply whenever
those optional paths are used.

## Contact

For ordinary, non-sensitive privacy questions, open an issue at
<https://github.com/jlipworth/Labstream/issues>. If a question includes private data or describes
a possible vulnerability, use
[GitHub private vulnerability reporting](https://github.com/jlipworth/Labstream/security/advisories/new)
instead of a public issue.

## Changes

If this policy changes, the updated version will be published at the same URL
with a new "last updated" date.
