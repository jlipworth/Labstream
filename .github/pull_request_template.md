<!--
Thanks for contributing! Please read docs/CONTRIBUTING.md first. This repository is public:
everything below is visible to anyone.
-->

## Summary

<!-- What changed and why, in user-visible terms. Keep the PR focused on one change. -->

## Linked issue

<!-- e.g. "Fixes #123" or "Refs #123". Open an issue first for non-trivial changes. -->

## Affected surface

- Platforms: <!-- Apple Vision Pro / iPhone / iPad / Apple TV / Mac / none (tooling or docs) -->
- Backends: <!-- Plex / Jellyfin / Emby / none -->

## Verification evidence

<!--
List what you actually ran and what you observed; "builds" alone is not verification.
- `scripts/native-test-matrix.py affected` output (which targets your change touches).
- Core checks from docs/DEVELOPMENT.md#core-validation-commands (hermetic PMSKit tests,
  strict MkDocs build and link/Mermaid checks for docs changes).
- For app code: the affected app build plus an install -> launch -> log -> screenshot smoke on a
  simulator (or the macOS host helper), per docs/DEVELOPMENT.md.
- Physical-device or live-server results, labeled as such. Do not present simulator evidence as
  hardware validation. For shared playback changes, say which backends you checked.
-->

- [ ] Commands run and results:
- [ ] Simulator / host / device evidence:
- [ ] Not verified (and why):

## Privacy checklist

- [ ] No tokens, client identifiers, passwords, or signing/team identifiers.
- [ ] No real server hostnames, IPs, or URLs (use `plex.example.internal` / `192.0.2.10`).
- [ ] No usernames, media titles, filenames, library paths, or personal home-directory paths in
      code, logs, screenshots, or this description.
- [ ] Security-sensitive changes were discussed privately first (see `SECURITY.md`).

## AI assistance

<!-- If an AI tool helped, name the model and harness (e.g. "Claude Opus via Claude Code",
"GPT via Codex"), and what it did. You remain responsible for reviewing every line. Write "None" otherwise. -->
