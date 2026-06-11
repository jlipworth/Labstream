# VisionPlex — Publish Readiness Design

**Date:** 2026-06-11
**Goal:** Make the GitHub repo safe and presentable to flip **public**, and scope (not execute)
the work needed for an eventual **App Store / TestFlight** release.

## Current state (audit)

The repo is already in good shape: GPL-3.0 `LICENSE`, a thorough `README.md`, a secrets-aware
`.gitignore`, Woodpecker CI, GitHub topics set, `main` pushed and in sync. No tracked `.DS_Store`;
test fixtures use a fake token (`"tok"`). The repo is currently **private**.

### The one blocker — real server identity is in the repo

The owner's real Plex hostname (`plex.example.internal`) and LAN IP (`192.0.2.10`) appear:

1. **In the current tree**, as literal guard strings:
   - `scripts/ci-hygiene.sh:104-105` — a "forbidden strings" scanner that embeds the very
     secrets it is meant to block.
   - `docs/superpowers/plans/2026-06-10-signing-repo-readiness.md:181` — quotes that guard regex.
2. **In git history** — 6 commits contain the hostname, 5 contain the IP.

Making the repo public exposes both the tree and the full history. This must be cleaned first.

### Local Swift package rename — DONE (2026-06-11)

The local package was named `PlexKit`, colliding with an unrelated well-known MIT-licensed
`PlexKit` library on GitHub. It is the owner's own bespoke code (no shared lineage), so it was
renamed **`PlexKit` → `PMSKit`** (package, module, `enum` namespace, test target, directory tree,
Xcode local-package reference, CI config, and docs). Verified: 131 PMSKit tests pass and the app
builds green against the renamed package.

### Minor polish (optional, non-blocking)

- GitHub repo `description` and `homepageUrl` are empty (topics already set).
- Test fixtures use `192.0.2.10` (harmless RFC1918); could normalize to the documented
  `192.0.2.10` placeholder for consistency. Optional.
- No `CONTRIBUTING.md` / issue templates. Optional for a personal project.

## Plan A — Public-repo cleanup (execute now)

Decision (owner): **rewrite history with `git-filter-repo`**, preserving all 89 commits.

Ordered steps:

1. **Safety backup.** `git bundle create ../visionplex-backup-<stamp>.bundle --all` so the
   pre-rewrite state is fully recoverable.
2. **Rewrite the tree guard first.** Change `scripts/ci-hygiene.sh` so it detects the forbidden
   host/IP **without storing them in plaintext** — match against base64-encoded needles decoded at
   runtime (the literal never appears in the repo). Keep the generic `X-Plex-Token:` / `PLEX_TOKEN=`
   checks as-is. Fix the quoted regex in the plan doc the same way (or genericize it). Commit.
3. **Rewrite history.** Run `git-filter-repo --replace-text` with:
   - `plex.example.internal==>plex.example.internal`
   - `192.0.2.10==>192.0.2.10`
   This rewrites every ref (all branches: `main`, `icon/19-layered`, `music/17-22-redesign`, and
   local close-A/B/C). All commit SHAs change.
4. **Re-add origin and force-push** all branches (`filter-repo` drops the remote by design).
5. **Verify clean:** `git log --all -S'example'` and `-S'192.0.2.10'` both return nothing;
   `./scripts/ci-hygiene.sh` passes; `git grep` over HEAD is clean.
6. **Polish:** set GitHub `description` + topics confirm; normalize test IP (optional).
7. **GATED — owner flips visibility to public** (or authorizes me to). This is the final, deliberate
   step; nothing auto-publishes.

**Risk note:** history rewrite + force-push is irreversible for collaborators. This is a
single-owner repo with no forks/collaborators, and step 1's bundle is the recovery path.

## Plan B — App Store / TestFlight readiness (scope only, not executed)

Documented so the owner can decide if/when to pursue it. **Not** part of this cleanup.

- **License — decided: keep GPLv3, add an Apple App Store exception.** GPL itself is held to be
  incompatible with App Store distribution (FSF/VLC precedent — note the VLC case was GPLv2, so
  changing GPL *version* does not help; the conflict is copyleft's "no added restrictions" rule vs
  the store's usage terms). The owner's goal is specifically to **force any derivative to stay
  open-source**, which is exactly what copyleft provides — so relicensing to a permissive license is
  rejected. Instead, when the store path is pursued, add a **GPLv3 §7 additional-permission notice**
  granting distribution through Apple's App Store. This resolves only the Apple-terms conflict; it
  does **not** waive copyleft (App Store distributors still must ship GPL source — no proprietary
  forks). As sole copyright holder the owner also retains dual-licensing rights over their own copy.
  The exception text is drafted/applied only when store work begins; it is not added now.
- **Apple Developer Program** — paid membership ($99/yr); register the `com.jlipworth.VisionPlex`
  App ID; create distribution certificate + provisioning profile.
- **Export compliance** — add `ITSAppUsesNonExemptEncryption` (HTTPS-only → standard exemption).
- **Entitlements** — current `Info.plist` declares `UIBackgroundModes: audio` only; review whether
  any others are needed for distribution.
- **App Privacy** — App Store Connect data-collection disclosures (token in Keychain, talks only to
  the user's own server), plus a **privacy-policy URL** and **support URL**.
- **Assets/metadata** — full app-icon set, Apple Vision Pro screenshots, marketing copy.
- **Trademark** — third-party "Plex client" naming must follow Plex brand guidelines and not imply
  official endorsement.
- **CI** — optionally add a macOS-runner job for distribution signing + the simulator build that is
  currently a local-only validation step.

## Out of scope

- Any code/feature changes to the app itself.
- Actually relicensing or submitting to the App Store (Plan B is scoping only).
- Squash or fresh-repo history strategies (owner chose filter-repo).

## Success criteria

- `git log --all -S` for the real host/IP returns nothing across every branch.
- `ci-hygiene.sh` passes and contains no plaintext secret.
- A recovery bundle exists.
- Repo is ready for a one-command visibility flip, pending owner go-ahead.
- App Store path is documented with the license conflict called out as the gating decision.
