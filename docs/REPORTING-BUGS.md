# Report a bug

Found something broken in VisionPlay? Here's the fastest way to get it fixed.

VisionPlay sends **nothing** to the developer — it talks only to your own Plex,
Jellyfin, or Emby server (see [PRIVACY.md](https://github.com/jlipworth/VisionPlay/blob/main/PRIVACY.md)). That means a GitHub
issue is the only way we learn about a problem, and the more reproducible detail
you give, the faster it gets fixed. The app has a built-in, **redacted**
diagnostic report to make that easy and safe.

## The easy path

1. **Reproduce with logging on.** In VisionPlay, open
   **Settings ▸ Diagnostics** and turn on **Enable diagnostic logging**. Then
   make the problem happen once.
2. **Grab the report.** Tap **Send feedback to developer** to review the redacted
   report and share it via the visionOS share sheet, or **Copy diagnostic report**
   to copy it to the clipboard.
3. **Review it.** The report is redacted for you (see below) — but give it a
   quick read so you're comfortable with what it contains.
4. **Open a bug.** Go to the
   [bug report form](https://github.com/jlipworth/VisionPlay/issues/new?template=bug_report.yml),
   fill in what happened and the steps to reproduce, and **paste the report** into
   the *Diagnostic report* field.
5. **Turn logging back off** in Settings ▸ Diagnostics if you no longer need it.

That's it. The form will also ask for your VisionPlay version and build
(**Settings ▸ About**), your visionOS version, and which backend you use
(Plex / Jellyfin / Emby).

## What's in the diagnostic report — and what isn't

The diagnostic report is built to be safe to share publicly. It **includes** safe
context like:

- app version/build and device/OS class
- backend name (Plex / Jellyfin / Emby) and connection scheme
- server product/version where known
- your selected quality settings
- a recent playback snapshot and recent **redacted** event summaries

It is designed to **omit** sensitive values, including:

- Plex tokens and client identifiers
- your server's hostname, IP address, or full URLs
- usernames, library paths, filenames, and media titles

Diagnostics are **off by default**, kept in a small local buffer, and **never
uploaded by the app** — the report leaves your device only when *you* copy or
share it. For the full contract, see
[Diagnostics and privacy](DIAGNOSTICS-PRIVACY.md) and [PRIVACY.md](https://github.com/jlipworth/VisionPlay/blob/main/PRIVACY.md).

## Before you post: a 10-second privacy check

This repository is **public**, so anything in your issue is publicly visible.
Before submitting, glance over everything you're attaching — the diagnostic
report, **screenshots, and any logs** — and remove anything you'd rather not
share: in particular tokens, your server's name / URL / IP, usernames, and media
titles. The bug form has a checkbox confirming you've done this.

## No diagnostic report? Still file it

A report is optional. If you can't capture one, open the
[bug report form](https://github.com/jlipworth/VisionPlay/issues/new?template=bug_report.yml)
anyway with a clear description and steps to reproduce — that alone is often
enough to get started.

## Requesting a feature instead?

Use the
[feature request form](https://github.com/jlipworth/VisionPlay/issues/new?template=feature_request.yml),
or start a thread in
[Discussions](https://github.com/jlipworth/VisionPlay/discussions) for open-ended
ideas and questions.
