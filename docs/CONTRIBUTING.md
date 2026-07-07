# Contributing to Labstream

Thanks for helping improve Labstream. This project touches private media servers and headset diagnostics, so the main contribution rule is simple: keep code testable and keep private data private.

## Before you start

- Read [Development setup](DEVELOPMENT.md).
- Skim the [Architecture overview](ARCHITECTURE.md) and [Code map](CODE-MAP.md).
- Check open issues to avoid duplicating work.

## Local workflow

```sh
git clone git@github.com:jlipworth/Labstream.git
cd Labstream
scripts/worktree-sim.sh setup
```

Build and test with the commands in [Development setup](DEVELOPMENT.md). Use the worktree simulator ID for the platform you are testing rather than `booted`.

## Pull request expectations

A good PR includes:

- a focused description of the user-visible change;
- tests for pure policies or request builders when applicable;
- notes about simulator, device, or live-server validation when relevant;
- screenshots only when they do not reveal private server or media details.

Run the basic checks before opening or updating a PR:

```sh
cd PMSKit && swift test
cd ..
scripts/ci-hygiene.sh
uv run --with-requirements requirements.txt mkdocs build --strict
```

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
- Put pure decisions in `PMSKit` where they can be unit-tested.
- Keep SwiftUI, AVFoundation, URLSession side effects, files, and Keychain in the app target.
- Use typed diagnostic fields and redaction helpers for anything that can reach a report.
- Archive research, implementation plans, and historical validation notes instead of publishing them as current docs.
