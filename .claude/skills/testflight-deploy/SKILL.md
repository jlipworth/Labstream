---
name: testflight-deploy
description: Archive, validate, upload, and select coordinated Labstream builds for TestFlight with scripts/testflight-release.py. Use when the user asks to ship, upload, publish to TestFlight, archive a release, check App Store Connect processing, or attach a build to an App Store version. Never submits for App Review.
---

# TestFlight deploy

`scripts/testflight-release.py` owns the whole command-line path for the four App Store targets
(`Labstream`, `LabstreamMobile`, `LabstreamTV`, `LabstreamMac`). Do not drive Xcode Organizer or the
App Store Connect website for these steps; the canonical sequence and gates are in
`docs/RELEASES.md` ▸ Coordinated publication sequence.

## Authorization boundaries

- `preflight`, `archive`, `validate`, `status`, and a `select-build` dry run are read-only toward
  App Store Connect and may run without asking.
- `upload --yes` needs explicit user authorization for that build set.
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

## Flow

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

# 7. A new App Store version can inherit the previous version's build. Dry run, then confirm.
scripts/testflight-release.py select-build
scripts/testflight-release.py select-build --yes
```

Use `--platform visionos|ios|tvos|macos` (repeatable) for a single-platform replacement build;
the privacy comparison runs only when all four are selected. `status`/`select-build` take
`--version`/`--build` to inspect a set other than the project's current numbers.

## After upload

- Record the archive commit, upload date, processing result, and selection in `docs/RELEASES.md`
  through a docs PR.
- The aggregate privacy report is still generated from Organizer (archive context menu) when the
  data-collection label needs re-review.
- Physical TestFlight acceptance on each device family remains the user's gate.
