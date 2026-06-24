# Public docs site + easy bug-report path — design (#69, #85)

**Date:** 2026-06-24
**Issues:** #69 (CI pipeline + published docs site), #85 (anonymized bug-report path)
**Status:** approved design; implementation pending

## Goal

Stand up a published documentation site for VisionPlay and an easy, privacy-safe
bug-report path, as the public-launch / App Store (#92) prerequisite. Two largely
independent tracks plus a small CI fix:

- **Track A** — curated MkDocs site on **GitHub Pages**, built and deployed by the
  existing self-hosted **Woodpecker** CI on every push to `main` that touches docs.
- **Track B** — easy bug reporting: an in-app "Send feedback" share flow (#85 v1,
  no backend) **and** GitHub Issue Forms + a docs "Report a bug" page.
- **Track C** — fix the hygiene pipeline, which is currently red (uv gap).

### Decisions locked during brainstorming

- Hosting: **GitHub Pages** (zero ops; survives proxmox downtime).
- Content scope: **curated** (user-facing + clean technical docs; internal
  AI/process/profiling/archive stays repo-only).
- Bug-report: **in-app + web both**.
- Deploy mechanism: **Option A** — Woodpecker runs `mkdocs gh-deploy` via a
  repo-scoped SSH deploy key (matches the explicit "hook this up with Woodpecker"
  ask; keeps one CI pane; GitHub still hosts the rendered site).
- **GitHub Discussions: enable it** (keep Discussions contact links).
- Staging: **one spec, fan out implementation per track** on isolated worktrees.

### Out of scope (noted; #69 stays open for the first item)

- The self-hosted **macOS Woodpecker live-test agent** (`local` backend running
  `xcodebuild` + live PMSKit tests against the real servers) — a separate
  sub-project; #69 remains open to track it.
- **MetricKit** crash/hang intake → defer to #92.
- Full git-history audit → already completed under #91 (closed).

---

## Track A — Docs site

### A1. Curated published set

Published = 4 root docs + 11 of 12 `docs/*.md`. Everything else stays repo-only.

| File | Decision | Note |
|---|---|---|
| `README.md` | include (Home) | landing page |
| `SUPPORT.md` | include | user-facing support |
| `PRIVACY.md` | include | privacy policy |
| `APP-STORE-EXCEPTION.md` | include | GPL §7 exception |
| `docs/ARCHITECTURE.md` | include | |
| `docs/PLAYBACK-ARCHITECTURE.md` | include | |
| `docs/BACKENDS.md` | include | **fix cross-links** (A4) |
| `docs/DOWNLOADS-OFFLINE.md` | include | |
| `docs/PERSISTENCE.md` | include | |
| `docs/DIAGNOSTICS-PRIVACY.md` | include | |
| `docs/SYSTEM-INTEGRATION.md` | include | |
| `docs/TESTING-STRATEGY.md` | include | |
| `docs/DEVELOPMENT.md` | include | **fix cross-links** (A4) |
| `docs/MUSIC-DESIGN.md` | include | de-process "judge-endorsed" (A4) |
| `docs/PROFILING.md` | include | under Contributing |
| `docs/PLEX_AVP_TRANSCODE_OOM_REPORT.md` | **EXCLUDE** | real k8s pod/node/namespace ids |

Excluded subtrees (repo-only): `docs/superpowers/**`, `docs/archive/**`,
`docs/research/**`, `docs/proposals/**`, `docs/profiling/baselines/**`,
`CLAUDE.md`, `AGENTS.md`, `.claude/skills/**`, `TESTING-CHECKLIST.md`.

### A2. Structure — no physical file moves (keystone)

Keep `docs_dir: docs/`. Use MkDocs ≥1.6 `exclude_docs` (drops internal files from
the build entirely, so their internal cross-links never trip `--strict`) plus
`not_in_nav`. Surface the 4 root docs via `mkdocs-include-markdown-plugin`: thin
stub pages under `docs/` (`index.md`, `support.md`, `privacy.md`,
`app-store-exception.md`) whose body is a single
`{% include-markdown "../README.md" %}` (etc.), keeping the source of truth at repo
root where GitHub renders it.

`mkdocs.yml` and `requirements.txt` live at **repo root**.

### A3. Config artifacts

**`requirements.txt`** (root):

```
mkdocs==1.6.1
mkdocs-material==9.5.49
mkdocs-include-markdown-plugin==7.1.2
pymdown-extensions==10.14
```

**`mkdocs.yml`** (root) — Material theme, light/dark toggle, the `exclude_docs`
keystone, and this nav:

```yaml
site_name: VisionPlay
site_description: Native Apple Vision Pro client for your own Plex, Jellyfin, or Emby server.
site_url: https://jlipworth.github.io/VisionPlay/
repo_url: https://github.com/jlipworth/VisionPlay
repo_name: jlipworth/VisionPlay
docs_dir: docs
copyright: Copyright (C) 2026 Jonathan Lipworth — GPL-3.0 with §7 exception

theme:
  name: material
  features: [navigation.sections, navigation.top, content.code.copy, toc.follow, search.suggest]
  palette:
    - media: "(prefers-color-scheme: dark)"
      scheme: slate
      toggle: { icon: material/weather-night, name: Switch to light }
    - media: "(prefers-color-scheme: light)"
      scheme: default
      toggle: { icon: material/weather-sunny, name: Switch to dark }

plugins:
  - search
  - include-markdown

markdown_extensions:
  - admonition
  - attr_list
  - md_in_html
  - tables
  - toc: { permalink: true }
  - pymdownx.highlight: { anchor_linenums: true }
  - pymdownx.superfences
  - pymdownx.inlinehilite
  - pymdownx.tabbed: { alternate_style: true }

exclude_docs: |
  PLEX_AVP_TRANSCODE_OOM_REPORT.md
  research/
  proposals/
  archive/
  superpowers/
  profiling/baselines/

nav:
  - Home: index.md
  - Using VisionPlay:
      - Support & Troubleshooting: support.md
      - Report a bug: REPORTING-BUGS.md
      - Privacy Policy: privacy.md
      - License Exception: app-store-exception.md
  - Architecture:
      - Overview: ARCHITECTURE.md
      - Playback: PLAYBACK-ARCHITECTURE.md
      - System Integration: SYSTEM-INTEGRATION.md
      - Persistence: PERSISTENCE.md
  - Backends & Playback:
      - Backends (Plex / Jellyfin / Emby): BACKENDS.md
      - Downloads & Offline: DOWNLOADS-OFFLINE.md
      - Music: MUSIC-DESIGN.md
  - Privacy & Diagnostics:
      - Diagnostics: DIAGNOSTICS-PRIVACY.md
  - Contributing:
      - Development Setup: DEVELOPMENT.md
      - Testing Strategy: TESTING-STRATEGY.md
      - Profiling: PROFILING.md
```

Add `site/` to `.gitignore` (a local `mkdocs build` output must not be committable).

### A4. Pre-publish content fixes (required for `--strict`)

- `docs/BACKENDS.md` lines 3, 22, 36 — links into excluded `research/` /
  `proposals/`: rewrite to GitHub blob URLs or drop.
- `docs/DEVELOPMENT.md` line 30 — links into excluded `research/` / `archive/`:
  rewrite to GitHub blob URLs or drop.
- `docs/MUSIC-DESIGN.md` lines 4, 248 — reword "judge-endorsed" (internal review
  term) → neutral phrasing. Cosmetic.
- Sweep verdict: published set is otherwise **clean of secrets** (no tokens,
  hostnames, LAN IPs, `/Users` paths, personal emails beyond the intentional
  public name). Issue-number references (`#NN`) are fine for OSS.

### A5. Pipeline — `.woodpecker/docs.yml`

```yaml
# .woodpecker/docs.yml
# Build the MkDocs site (strict) and deploy to GitHub Pages via the gh-pages branch.
# Runs only on push to main, only when docs sources change.
when:
  - event: push
    branch: main
    path:
      include: [docs/**, mkdocs.yml, requirements.txt, .woodpecker/docs.yml]

steps:
  - name: build-and-deploy
    image: python:3.12-slim
    environment:
      DEPLOY_KEY: { from_secret: github_deploy_key }
    commands:
      - apt-get update && apt-get install -y --no-install-recommends git openssh-client
      - rm -rf /var/lib/apt/lists/*
      - pip install --no-cache-dir -r requirements.txt
      - mkdocs build --strict
      - mkdir -p ~/.ssh && chmod 700 ~/.ssh
      - printf '%s\n' "$DEPLOY_KEY" > ~/.ssh/id_ed25519
      - chmod 600 ~/.ssh/id_ed25519
      - ssh-keyscan -t ed25519 github.com >> ~/.ssh/known_hosts 2>/dev/null
      - git config --global user.name  "woodpecker-ci"
      - git config --global user.email "ci@visionplay.local"
      - git remote set-url origin git@github.com:jlipworth/VisionPlay.git
      - export GIT_SSH_COMMAND="ssh -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes"
      - mkdocs gh-deploy --force --remote-name origin
```

Notes: the list-form `when:` is required for `path` filtering (the map form used by
the other two pipelines does not support it). The `git remote set-url` guarantees an
SSH origin so the deploy key applies even if Woodpecker clones over HTTPS. The secret
is written to a file (not interpolated into a command) to keep it out of logs.

### A6. One-time manual hookup (owner)

1. `ssh-keygen -t ed25519 -C "woodpecker-docs-deploy" -f vp_docs_deploy -N ""`
2. GitHub → repo **Settings → Deploy keys → Add** the `.pub`, **allow write**.
3. Woodpecker → repo **Settings → Secrets → Add** `github_deploy_key` = the private
   key, **push events only**.
4. GitHub → **Settings → Pages → Source = Deploy from a branch → `gh-pages` / root**
   (after the first successful deploy creates the branch).
5. GitHub → **Settings → General → Features → enable Discussions**.

---

## Track B — Bug-report path (#85 in-app + web)

### B1. In-app v1 (no backend)

The redaction keystone already ships in PMSKit and is the sole trust boundary
(`DiagnosticRedactor.redact` at `DiagnosticLogging.swift:124-174`; bounded opt-in
ring buffer `DiagnosticLogStore` `:330-389`; renderer `:435-486`). No PMSKit source
changes needed.

**Edit `VisionPlay/UI/SettingsView.swift`:**
- Add `@State private var presentingFeedback = false` (~line 31).
- New button in `diagnosticsSection` after "Export diagnostic report file" (~line
  662): `Label("Send feedback to developer", systemImage: "envelope")` → sets
  `presentingFeedback = true`.
- Attach `.sheet(isPresented: $presentingFeedback) { FeedbackSheet(reportText:
  diagnosticReportText, githubIssuesURL: Self.feedbackIssuesURL) }` to the `Form`
  (~line 88, beside the existing `.fileExporter`).
- Add `static let feedbackIssuesURL = URL(string:
  "https://github.com/jlipworth/VisionPlay/issues/new?template=bug_report.yml")!`
  (single source of truth for the web link).
- Update the diagnostics section footer to mention the new path.

**New `VisionPlay/UI/FeedbackSheet.swift`** (file-system-synchronized group; no
pbxproj edit):
- Props: `reportText: String` (already redacted, passed in), `githubIssuesURL: URL`.
- `@State note: String` — optional "What were you doing?" free text.
- `sharedReport` computed: folds the note in **only** through
  `DiagnosticRedactor.redact(note)` (never raw), prepended to `reportText`.
- Body: note `TextField` (axis vertical) with a "your note is scrubbed too" footer;
  a read-only live `Text(sharedReport)` monospaced preview (recomputes as the note
  changes, so the user sees exactly what ships); a `ShareLink`; a "Open an issue on
  GitHub" `Link(destination: githubIssuesURL)`; Cancel toolbar item.
- Share via **`ShareLink`** (first share-sheet use in the app) of a `.txt` through a
  small `struct FeedbackReportFile: Transferable` (`DataRepresentation(exportedContentType:
  .plainText)`, `suggestedFileName "VisionPlay-Feedback.txt"`). Prefer ShareLink over
  `UIActivityViewController` (SwiftUI-native; floor is visionOS 26).
- **Smoke-test note:** verify the share sheet presents/anchors correctly from the
  Settings window (windowed vs expanded) and screenshot it.

**Add adversarial tests** to
`PMSKit/Tests/PMSKitTests/DiagnosticLoggingTests.swift` for the free-text-note path
(`DiagnosticRedactor.redact(note)`), following the existing `XCTAssertFalse(redacted.contains(...))`
pattern:
1. odd-separator tokens (`X-Plex-Token:`, `token=…`, comma/semicolon/newline) → gone.
2. prose URLs/hosts/IPs (`https://…`, bare host, `192.0.2.10`) → `[url]`/`[host]`/`[ip]`.
3. file-shaped media title (`Blade Runner 2049.mkv` → `[file]`) **and** a documenting
   assertion that a bare prose title is an accepted residual (preview/footer is the
   mitigation).
4. dotless personal name (`Bob's Laptop`) survives — documents the limit.
5. bracketed IPv6 (`[2001:db8::1]`, `[fe80::1%en0]`) → `[ip]`; note bare IPv6 residual.
6. email + `password=`/`pw=` in prose → `[email]` / redacted.

### B2. Web — GitHub Issue Forms + docs page

Net-new `.github/ISSUE_TEMPLATE/`:

- **`bug_report.yml`** — Issue Form: intro markdown (privacy framing + SUPPORT
  link); required *What happened / Expected / Steps*; **Media backend** dropdown
  (Plex / Jellyfin / Emby / Not sure); **Affected area** dropdown (Playback /
  Downloads / Browse / Music / Subtitles / Sign-in / Other); VisionPlay version+build
  (Settings → About), visionOS version, optional server type+version (with "do NOT
  include name/URL/IP"); a `render: text` **Diagnostic report (redacted)** paste
  field pointing at the in-app flow; an *Anything else?* field; and a **required
  privacy-ack checkbox** ("I have reviewed everything and removed anything I don't
  want public — tokens, server name/URL/IP, usernames, media titles").
- **`feature_request.yml`** — lean: problem / proposal / related-area dropdown /
  alternatives; intro points open-ended ideas to Discussions.
- **`config.yml`** — `blank_issues_enabled: false`; `contact_links`: Support
  (`SUPPORT.md`), Report-a-bug guide (`docs/REPORTING-BUGS.md`), Discussions.

New **`docs/REPORTING-BUGS.md`** (in nav under *Using VisionPlay → Report a bug*):
the easy path (Settings → Diagnostics → enable logging → reproduce → Send feedback /
Copy report → review → open the bug form → paste), what the report includes/omits
(reusing the canonical redaction wording from `PRIVACY.md` /
`DIAGNOSTICS-PRIVACY.md`), the 10-second privacy check, "no report? file anyway", and
a feature-request pointer.

**Wiring:** `SUPPORT.md` links to `docs/REPORTING-BUGS.md` + the bug form (keep its
short Diagnostics steps, link to the fuller guide — no duplication). The in-app
"Open an issue" link uses the template-prefilled new-issue URL. Keep the redaction
wording identical across `bug_report.yml`, `REPORTING-BUGS.md`, `PRIVACY.md`,
`DIAGNOSTICS-PRIVACY.md`.

> Label consistency: #85 introduces the "Send feedback to developer" entry point;
> the web docs reference both that and the existing "Copy diagnostic report" /
> "Export diagnostic report file" buttons (all in Settings → Diagnostics). Keep the
> strings in sync between the app and `REPORTING-BUGS.md` / `bug_report.yml`.

---

## Track C — hygiene CI fix

`.woodpecker/hygiene.yml` currently installs only `bash git ripgrep`, but
`scripts/ci-hygiene.sh:221-223` hard-fails when `pyproject.toml` exists without
`uv` — so the pipeline is red (or has not run since `pyproject.toml` landed). Fix in
the hygiene step:

```yaml
- apk add --no-cache bash git ripgrep python3
- pip install --break-system-packages uv   # or the astral.sh installer
- ./scripts/ci-hygiene.sh
```

This lets `uv run python -m unittest discover -s scripts/tests` actually execute.
Small, self-contained.

---

## Verification

- **Track A:** `pip install -r requirements.txt && mkdocs build --strict` passes
  locally (no broken links / nav); rendered site spot-checked; after hookup, a
  push-to-main touching `docs/` deploys and the Pages URL serves the nav.
- **Track B in-app:** PMSKit `swift test` green incl. the 6 new redaction tests;
  app builds; **smoke test on the worktree `$SIMID`** (install → launch → log →
  screenshot) per CLAUDE.md — reach Settings → Diagnostics → Send feedback, confirm
  the preview renders redacted and the share sheet presents.
- **Track B web:** issue forms render on GitHub (validate YAML); `REPORTING-BUGS.md`
  builds into the site nav.
- **Track C:** hygiene pipeline goes green; `scripts/tests` run.
- **Hard constraints:** `ci-hygiene.sh` passes; no tokens/identifiers/real
  hostnames/LAN IPs/`/Users` paths in any new published artifact; placeholders
  (`plex.example.internal` / `192.0.2.10`) preserved.

## Decomposition for implementation (fan-out)

- **A** — docs site: `requirements.txt`, `mkdocs.yml`, 4 stub pages, `.gitignore`,
  content fixes (A4), `.woodpecker/docs.yml`. Verify `mkdocs build --strict`.
- **B** — bug-report: `SettingsView.swift` edit + `FeedbackSheet.swift` + 6 tests;
  `.github/ISSUE_TEMPLATE/*`; `docs/REPORTING-BUGS.md`; `SUPPORT.md` wiring. Verify
  `swift test` + app smoke test.
- **C** — `.woodpecker/hygiene.yml` uv fix.

A and C touch CI/docs only; B touches app + tests + GitHub config. C is fully
independent. **A and B share one coupling:** A's nav lists `REPORTING-BUGS.md`, which
B creates, so `mkdocs build --strict` fails if A merges first. Resolve by either (i)
having A create a one-line `docs/REPORTING-BUGS.md` stub that B fleshes out, or (ii)
merging B's `REPORTING-BUGS.md` before/with A. Recommend (i): A owns the nav + a stub,
B fills the content — keeps the strict build green at every merge point. The
owner-side hookup (A6) is manual and gates the live Pages deploy but not the code.
