# Contributing to Labstream

Thanks for helping improve Labstream. This project touches private media servers and headset diagnostics, so the main contribution rule is simple: keep code testable and keep private data private.

## Before you start

- Read [Development setup](DEVELOPMENT.md).
- Skim the [Architecture overview](ARCHITECTURE.md) and [Code map](CODE-MAP.md).
- For host-Mac work, read [macOS development preview](MACOS.md); it is a local-build preview,
  not a released support target.
- Check open issues to avoid duplicating work.

## Local workflow

```sh
git clone https://github.com/jlipworth/Labstream.git
cd Labstream
```

A new clone does not contain the machine-local `.simid` file. Before the first visionOS build,
follow [Bootstrap the first visionOS simulator](DEVELOPMENT.md#bootstrap-the-first-visionos-simulator).
Then use the platform-specific build, exact-product install, observable smoke, shutdown, and cleanup
procedures in [Development setup](DEVELOPMENT.md). Always resolve a concrete worktree simulator UDID
rather than targeting `booted`.

## Pull request expectations

A good PR includes:

- a focused description of the user-visible change;
- tests for pure policies or request builders when applicable;
- notes about simulator, device, or live-server validation when relevant;
- Mac host build/smoke notes when a change touches the `LabstreamMac` preview;
- screenshots only when they do not reveal private server or media details.

Run the [core validation commands](DEVELOPMENT.md#core-validation-commands) before opening or
updating a PR. For app-owned changes, also run the affected host-app unit suite: `LabstreamTests`
through the `LabstreamMobile` scheme on an iOS simulator and/or `LabstreamMacTests` through the
`LabstreamMac` scheme on the host. Exact commands and test-plan names are in
[Development setup](DEVELOPMENT.md). Shared app infrastructure should exercise both hosts; these
tests supplement rather than replace the affected app build and
[observable simulator smoke](DEVELOPMENT.md#install-and-observe-a-simulator-smoke).

## Privacy and secrets

Never commit or paste:

- Plex/Jellyfin/Emby tokens;
- client identifiers;
- server hostnames, LAN/public IPs, or full URLs;
- usernames/emails that are not intentionally public;
- media titles, filenames, library paths, or screenshots containing them;
- signing files, provisioning profiles, or local team IDs.

Use placeholders such as `plex.example.internal`, `192.0.2.10`, `<server-url>`, `<token>`, and `<media title>`.

## Architecture guidelines

- Keep backend-specific wire behavior explicit.
- Put reusable request, model, and policy decisions in `PMSKit`; keep its exceptional effectful
  infrastructure limited to narrow, injectable seams such as the media-session proxy and
  credential-artifact writer.
- Keep SwiftUI, `AVPlayer` ownership, target lifecycle, background-session delegation, app
  persistence/filesystem orchestration, and Keychain access in the app target.
- Use typed diagnostic fields and redaction helpers for anything that can reach a report.
- Archive research, implementation plans, and historical validation notes instead of publishing them as current docs.
