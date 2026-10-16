# Report a bug

Found something broken in Labstream? Here's the fastest way to get it fixed.

Labstream does not automatically upload diagnostic reports. The optional project-operated review/demo server retains operational records separately (see the [Privacy Policy](privacy.md)). Depending on your sign-in choice it talks to Plex services and your selected Plex server, your Jellyfin server URL, or Emby Connect plus your selected Emby server. A GitHub issue is the way we learn about a problem, and the more reproducible detail
you give, the faster it gets fixed. The app has a built-in, **redacted**
diagnostic report to make that easy and safe.

## The easy path

1. **Reproduce with logging on.** In Labstream, open
   **Settings ▸ Diagnostics** and turn on **Enable diagnostic logging**. Then
   make the problem happen once.
2. **Grab the report.** On visionOS, iPhone, iPad, or Mac, tap **Send feedback to
   developer** to review the redacted report and share it via the system share
   sheet, **Copy diagnostic report** to copy it to the clipboard, or **Export
   diagnostic report file** if you want a text file. On Apple TV, Copy and Export
   are not compiled in; use **Send feedback to developer** for the preview/GitHub handoff.
   A long report may not fit in the issue URL, so treat this as a guided handoff rather than a
   guaranteed full-report transfer.
3. **Review it.** The report is redacted for you (see below) — but give it a
   quick read so you're comfortable with what it contains.
4. **Open a bug.** Go to the
   [bug report form](https://github.com/jlipworth/Labstream/issues/new?template=bug_report.yml),
   fill in what happened and the steps to reproduce, and **paste the report** into
   the *Diagnostic report* field.
5. **Turn logging back off** in Settings ▸ Diagnostics if you no longer need it.

That's it. The form will also ask for your Labstream version and build
(the **About** section at the bottom of Settings), your platform and OS version, which
backend you use (Plex / Jellyfin / Emby), and how badly the problem affects you.

If you are testing Mac or Apple TV, say so explicitly and include macOS or tvOS as the platform.
All platform targets remain pre-release, and reproducible source-build or TestFlight reports are
useful when they identify the exact platform, version, and build.

## What's in the diagnostic report — and what isn't

The diagnostic report is designed for public sharing. It **includes** safe context
like:

- app version/build and device/OS class
- backend name (Plex / Jellyfin / Emby) and connection scheme
- server product/version where known
- your selected quality settings
- download counts and queue state, with bucketed storage totals (not on Apple TV)
- a recent playback snapshot, passive redacted MetricKit diagnostic summaries
  when available, and up to 80 recent **redacted** events from the current app run

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
