---
name: testflight-deploy
description: Archive, validate, upload, distribute, and select coordinated Labstream builds for TestFlight with scripts/testflight-release.py. Use when the user asks to ship, push a build to their devices, upload, publish to TestFlight, archive a release, check App Store Connect processing, or attach a build to an App Store version. Never submits for App Review.
---

# TestFlight deploy

`scripts/testflight-release.py` owns the whole command-line path for the four App Store targets
(`Labstream`, `LabstreamMobile`, `LabstreamTV`, `LabstreamMac`). Do not drive Xcode Organizer or the
App Store Connect website for these steps; the canonical sequence and gates are in
`docs/RELEASES.md` ▸ Coordinated publication sequence.

## Authorization boundaries

- `preflight`, `archive`, `validate`, `status`, and a `select-build` dry run are read-only toward
  App Store Connect and may run without asking.
- `upload --yes`, `ship --yes`, and `distribute --yes` need explicit user authorization for
  that build set.
- `select-build --yes` changes App Store version drafts; confirm with the user first.
- App Review submission is not implemented and stays an Account Holder action. Never submit,
  release, or change storefront availability.

## Prerequisites (one-time, user-owned)

- Apple Distribution identity in the login keychain and unexpired App Store profiles for the
  bundle on iOS/visionOS, tvOS, and macOS (`preflight` reports days remaining).
- Gitignored `scripts/asc.local.env` with `LABSTREAM_ASC_OP_ITEM=op://<vault>/<item>` for a
  1Password item holding `key_id`, `issuer_id`, `app_id`, and the PEM key in its notes, plus
  `LABSTREAM_OP_SA_KEYCHAIN_SERVICE=<service>` naming a login-Keychain entry that holds a
  read-only 1Password service-account token for that vault. Without the service account every
  new shell triggers a 1Password approval prompt; do not loop on `op` calls.
- Never print, commit, or paste the key, key ID, issuer ID, app ID, team ID, vault/item IDs, or
  the service-account token. The script masks account identifiers; keep `--verbose` local.

## On-demand continuous build

When the user wants the current `main` on their own devices:

```sh
git switch main && git pull --ff-only
scripts/testflight-release.py ship --group "<internal group>" --yes
```

`ship` runs preflight, archive, validate, and upload with `--build-number auto` (the commit count
of HEAD, so no version-bump commit is needed), waits for processing, and adds the builds to the
internal group. The group can default from `LABSTREAM_TESTFLIGHT_GROUP` in `scripts/asc.local.env`.
After a successful ship it prunes `~/Library/Developer/Xcode/Archives`: it keeps the newest three
uploaded archive sets, every set attached to an App Store version, and any set newer than the
newest upload (pending or failed), and deletes the rest. Run
`scripts/testflight-release.py prune-archives` for a dry run and `--yes` to prune by hand.
It uploads to the project's current marketing version, which must still be open in App Store
Connect (not yet approved or released). Run it in the background: archiving four platforms and
processing take most of an hour.

## Step-by-step flow

```sh
# 1. Version/build bumped and merged first (bump-version skill); release from published main.
git switch main && git pull --ff-only

# 2. Checks: clean source, versions, profiles, identity, and that the build is not uploaded yet.
scripts/testflight-release.py preflight

# 3. Archives go to ~/Library/Developer/Xcode/Archives/<date>/ (visible in Organizer);
#    build/DerivedData-archive is removed afterwards. Takes several minutes per platform.
scripts/testflight-release.py archive

# 4. Identity, version/build, clean slug, signature, App Store profile, entitlements, and the
#    four-app privacy manifest comparison.
scripts/testflight-release.py validate

# 5. Only after the user authorizes the upload:
scripts/testflight-release.py upload --yes

# 6. Processing, TestFlight state, beta groups, and which build each platform version uses.
scripts/testflight-release.py status --wait

# 6b. Internal group membership (skip if the group distributes automatically).
scripts/testflight-release.py distribute --group "<internal group>" --yes

# 7. A new App Store version can inherit the previous version's build. Dry run, then confirm.
scripts/testflight-release.py select-build
scripts/testflight-release.py select-build --yes
```

Use `--platform visionos|ios|tvos|macos` (repeatable) for a single-platform replacement build;
the privacy comparison runs only when all four are selected. `status`/`select-build` take
`--version`/`--build-number` to inspect a set other than the project's current numbers.
`validate` and `upload` check the archive itself (clean source-derived build ID from a commit on
`origin/main`), not the current checkout, so a failed upload can be retried later with
`upload --platform <p> --build-number <n> --yes`. The Mac upload is a `.pkg` signed with the
team's installer identity (3rd Party Mac Developer Installer), which must be in the keychain. Every
command accepts `--build-number auto|<n>`; use the same value across the steps of one build set.
Build numbers only increase per version and platform, so once `auto` numbers (around the commit
count) are in use, a hand-bumped `CURRENT_PROJECT_VERSION` must exceed them.

## After upload

- Record the archive commit, upload date, processing result, and selection in `docs/RELEASES.md`
  through a docs PR.
- The aggregate privacy report is still generated from Organizer (archive context menu) when the
  data-collection label needs re-review.
- Physical TestFlight acceptance on each device family remains the user's gate.
