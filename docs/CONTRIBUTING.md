# Contributing to Labstream

Thanks for helping improve Labstream. This project touches private media servers and headset diagnostics, so the main contribution rule is simple: keep code testable and keep private data private.

## Before you start

- Read [Development setup](DEVELOPMENT.md).
- Skim the [Architecture overview](ARCHITECTURE.md) and [Code map](CODE-MAP.md).
- For host-Mac work, read [macOS development preview](MACOS.md); it is a local-build preview,
  not a released support target.
- For tvOS work, read [tvOS development](TVOS.md); `LabstreamTV` is a streaming-only,
  in-development target with the Downloads capability compiled out.
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
- tvOS build/smoke notes when a change touches the `LabstreamTV` target;
- screenshots only when they do not reveal private server or media details.

Run the [core validation commands](DEVELOPMENT.md#core-validation-commands) before opening or
updating a PR. For app-owned changes, also run the affected host-app unit suite(s): `LabstreamTests`
through the `LabstreamMobile` scheme on an iOS simulator, `LabstreamMacTests` through the
`LabstreamMac` scheme on the host, and/or `LabstreamTVTests` (with `LabstreamTVUITests`) through
the `LabstreamTV` scheme on a tvOS simulator. Exact commands and test-plan names are in
[Development setup](DEVELOPMENT.md). Shared app infrastructure should exercise all affected
hosts (iOS, macOS, and tvOS); these
tests supplement rather than replace the affected app build and
[observable simulator smoke](DEVELOPMENT.md#install-and-observe-a-simulator-smoke).

## Documentation information architecture

Classify a document before creating it:

- current user, contributor, and architecture guidance is a stable published topic page directly
  under `docs/`;
- approved work with open implementation or acceptance gates belongs in `docs/plans/`;
- an investigation with unresolved questions belongs in `docs/research/`;
- immutable, point-in-time audit or profiling observations belong in `docs/evidence/`;
- completed plans, resolved reviews, and superseded context belong in `docs/archive/`.

The README in each internal lane defines what belongs there, what does not, its filename
convention, and its lifecycle. New internal documents use `YYYY-MM-DD-<topic>.md`; prefer a
durable topic name over a redundant `-plan` suffix. Keep published URLs stable unless a rename
fixes a concrete semantic defect. When work becomes proven, promote the durable behavior or
procedure into the canonical published topic page; then archive completed plans and resolved
reviews without rewriting their historical journal. During a move, preserve historical prose but
repair live Markdown navigation, MkDocs entries, script references, and contributor instructions.

Mermaid source lives beside the canonical prose it illustrates and changes with the behavior or
ownership it depicts. Every diagram needs `accTitle` and `accDescr`, complete adjacent prose, and
conservative flowchart, sequence, or state syntax that works in both GitHub and MkDocs Material.
Avoid HTML labels, click directives, custom colors, and meaning conveyed only by color or line
style. Keep diagrams readable at mobile widths and do not add a separate Mermaid dependency,
external script, or generated image copy. After content or path changes, run the strict MkDocs
build, repository-wide link validation, Mermaid structural check, and `scripts/ci-hygiene.sh` as
described in [Testing strategy](TESTING-STRATEGY.md). Run the repository-wide local link and anchor
check directly with `scripts/check-doc-links.py` when iterating on documentation.

## Privacy and secrets

Never commit or paste:

- Plex/Jellyfin/Emby tokens;
- client identifiers;
- server hostnames, LAN/public IPs, or full URLs;
- usernames/emails that are not intentionally public;
- media titles, filenames, library paths, or screenshots containing them;
- signing files, provisioning profiles, or local team IDs.

Use placeholders such as `plex.example.internal`, `192.0.2.10`, `<server-url>`, `<token>`, and `<media title>`.

Security vulnerabilities and reports containing private data must use the private route in the
[security policy](https://github.com/jlipworth/Labstream/blob/main/SECURITY.md), not an issue,
Discussion, or pull request.

## Contribution license

By submitting a contribution, you agree that it is licensed under GPLv3 together with the
repository's existing App Store/TestFlight additional permission in
[`APP-STORE-EXCEPTION.md`](app-store-exception.md). Its framework-linking portion currently names
the visionOS, iOS, and iPadOS application paths; do not infer Mac or tvOS distribution permission
without a separate licensing review.
Do not contribute code, assets, or documentation that you do not have the right to license on
those terms. New third-party material must include its provenance, license, and required notice.

## Architecture guidelines

- Keep backend-specific wire behavior explicit.
- Put reusable request, model, and policy decisions in `PMSKit`; keep its exceptional effectful
  infrastructure limited to narrow, injectable seams such as the media-session proxy and
  credential-artifact writer.
- Keep SwiftUI, `AVPlayer` ownership, target lifecycle, background-session delegation, app
  persistence/filesystem orchestration, and Keychain access in the app target.
- Use typed diagnostic fields and redaction helpers for anything that can reach a report.
- Use the current/plans/research/evidence/archive lanes above instead of publishing internal or
  historical material as current guidance.
