# Report a bug

**We want your reports.** Labstream is an open-source project with no analytics and no
developer-run backend, so a report from you is the only way a crash, a stuck download or a film
that will not play ever reaches us. Every report is read. A two-line report is useful; you do not
need to diagnose anything.

Labstream does not automatically upload diagnostic reports. The optional project-operated review/demo server retains operational records separately (see the [Privacy Policy](privacy.md)). Depending on your sign-in choice it talks to Plex services and your selected Plex server, your Jellyfin server URL, or Emby Connect plus your selected Emby server.

## The easy path: Report a problem

1. **Open the report screen.** Tap **Report a problem** in any of these places:
   - the card that appears when playback fails;
   - **Settings ▸ About** or **Settings ▸ Diagnostics**;
   - **Help ▸ Report a Problem…** on Mac.
2. **Say what happened** in a sentence or two.
3. **Tap Open a GitHub issue.** A short form opens with your description, your app and device
   details, and the redacted report already filled in. Tick the privacy box and press
   **Submit new issue**. This needs a free GitHub account.

On **Apple TV**, which has no browser, the same screen shows a QR code. Scan it with your phone to
open the form with your note and your app, device and server details filled in. The diagnostic
report itself is not included there (it does not fit a scannable code).

**No GitHub account?** Use **Share report…** on the same screen and send it to
[support@labstream.app](mailto:support@labstream.app), or just email a description.

A link can only hold so much, so the form receives the report's summary (build, device, server,
crash summaries, last playback) and as many of the most recent events as fit. The complete report
is copied to your clipboard at the same moment; paste it over the shortened one if you want to
send everything.

### Make the report more useful

Diagnostic logging is off by default. Without it the report still names your build, device,
server type and version, and any crash the system recorded, but it has no playback details. For a
problem you can repeat, open **Settings ▸ Diagnostics**, turn on **Enable diagnostic logging**,
make the problem happen once, then report it. Turn logging back off afterwards if you like.

**Copy diagnostic report** and **Export diagnostic report file** in Settings ▸ Diagnostics give
you the same report as text (not on Apple TV).

### The longer form

Writing a report by hand, without the app? Use the
[bug report form](https://github.com/jlipworth/Labstream/issues/new?template=bug_report.yml). It
asks for your Labstream version and build (the **About** section at the bottom of Settings), your
platform and OS version, which backend you use (Plex / Jellyfin / Emby), and how badly the problem
affects you.

If you are testing Mac or Apple TV, say so explicitly and include macOS or tvOS as the platform.
All platform targets remain pre-release, and reproducible source-build or TestFlight reports are
useful when they identify the exact platform, version, and build.

## What's in the diagnostic report — and what isn't

The diagnostic report is designed for public sharing. It **includes** safe context
like:

- app version/build, where it was installed from (App Store, TestFlight, or a development
  build), OS, and device model (a product code such as `iPhone17,1`, not a device identifier)
- backend name (Plex / Jellyfin / Emby) and connection scheme
- server product/version where known
- your selected quality settings
- download counts and queue state, with bucketed storage totals (not on Apple TV)
- a recent playback snapshot, passive redacted MetricKit crash and hang summaries when
  available (the crashed thread as binary names and offsets, with no memory contents), and up
  to 80 recent **redacted** events from the current app run

It is designed to **omit** sensitive values, including:

- Plex, Jellyfin, and Emby access tokens and client identifiers
- your server's hostname, IP address, or full URLs
- usernames, library paths, filenames, and media titles

Diagnostics are **off by default**, kept in a bounded in-memory ring and small rotating
already-redacted local files, and **never
uploaded automatically by the app** — the report leaves your device only when *you* copy,
export, or share it. For the full contract, see
[Diagnostics and privacy](DIAGNOSTICS-PRIVACY.md) and the [Privacy Policy](privacy.md).

## Before you post: a 10-second privacy check

This repository is **public**, so anything in your issue is publicly visible.
Before submitting, glance over everything you're attaching — the diagnostic
report, **screenshots, and any logs** — and remove anything you'd rather not
share: in particular tokens, your server's name / URL / IP, usernames, and media
titles. The bug form has a checkbox confirming you've done this.

## Using a coding agent?

If an AI coding agent (Claude Code, Codex, or similar) is helping you, have it follow the
[triage playbook](https://github.com/jlipworth/Labstream/blob/main/.github/triage/PLAYBOOK.md).
It searches for duplicates, collects the fields above, keeps private data out, and asks for your
approval before anything is posted.

## No diagnostic report? Still file it

A report is optional. If you can't capture one, open the
[bug report form](https://github.com/jlipworth/Labstream/issues/new?template=bug_report.yml)
anyway with a clear description and steps to reproduce — that alone is often
enough to get started.

## Requesting a feature instead?

Use the
[feature request form](https://github.com/jlipworth/Labstream/issues/new?template=feature_request.yml)
for a concrete, scoped change. Open-ended ideas belong in
[Discussions ▸ Ideas](https://github.com/jlipworth/Labstream/discussions/categories/ideas), and
questions in [Discussions ▸ Q&A](https://github.com/jlipworth/Labstream/discussions/categories/q-a).
