---
name: bump-version
description: Bump the Labstream app version (e.g. 1.1.0 → 1.2.0). Use whenever the user asks to update / increment / set the app version, cut a release, or change the marketing/build number. Covers the single source of truth, every file that must change, what NOT to touch, App Store version rules, and the required verification.
---

# Bumping the Labstream version

The version lives in **more than one place**, but there is **one source of truth** and a
short, fixed list of files to change. Follow it exactly — a partial bump compiles fine but
drifts (and `swift test` will fail on the pinned sanity test).

## Source of truth

`MARKETING_VERSION` in `Labstream.xcodeproj/project.pbxproj` is authoritative. At launch
`Labstream/App/Labstream.swift` reads the bundle's `CFBundleShortVersionString`
(= `MARKETING_VERSION`) to build the `X-Plex-Version` header (decision #26), so the header
can never drift from the marketing version. Everything else just keeps a copy in sync.

## Files to change (the whole list)

1. **`Labstream.xcodeproj/project.pbxproj` → `MARKETING_VERSION`** — TWO occurrences
   (Debug + Release config blocks). Set both to the new semver `X.Y.Z`. This is the real
   app version → `CFBundleShortVersionString` → `X-Plex-Version`.
2. **`Labstream.xcodeproj/project.pbxproj` → `CURRENT_PROJECT_VERSION`** — the *build
   number* (`CFBundleVersion`), TWO occurrences. This is **not** the version. Leave it at
   `1` for a brand-new marketing version. Only increment it when uploading **another build
   of the same marketing version** to App Store Connect (each upload under one version must
   have a higher build number). Never decrease it relative to a build you've already
   uploaded.
3. **`PMSKit/Sources/PMSKit/PMSKit.swift` → `PMSKit.version`** — library fallback constant.
   The app overrides it via the bundle, but keep it in sync with `MARKETING_VERSION`.
4. **`PMSKit/Tests/PMSKitTests/SanityTests.swift`** — `#expect(PMSKit.version == "X.Y.Z")`
   pins #3. Update the literal or `swift test` fails.

Find them all to self-audit before and after:

```sh
rg -n 'MARKETING_VERSION|CURRENT_PROJECT_VERSION' Labstream.xcodeproj/project.pbxproj
rg -n 'static let version|PMSKit.version ==' PMSKit/Sources PMSKit/Tests
```

## Do NOT touch

- **`Labstream/App/Labstream.swift` and `Labstream/Player/CustomPlayerView.swift`** —
  both source the version from `Bundle.main … CFBundleShortVersionString`, so they track
  `MARKETING_VERSION` automatically. No edit needed (that's the point of #26).
- **Test fixtures** that hardcode a version string in a `ClientIdentity(... version: "…")`
  (e.g. `PlexHeadersTests`, `JellyfinPlaybackTests`, live-probe tests) — those are arbitrary
  inputs the test sets and asserts against itself, not the app version. Leave them.
- **`pyproject.toml` / `uv.lock`** — that's the separate `labstream-tooling` Python package
  with its own lifecycle. Unrelated to the app version.

## Versioning rules

- Semver `MAJOR.MINOR.PATCH`. Minor bump = new user-facing features, backward compatible.
- **The app will ship to the App Store**, so `CFBundleShortVersionString` must
  **strictly increase** over any version already submitted. The current train is **1.x** —
  never drop to `0.x` (that reads as a downgrade and App Store Connect rejects it).

## Verify (required — a green build is not "done")

1. `cd PMSKit && swift test` → all suites pass (catches `SanityTests`).
2. Build the app, then confirm the bundle actually carries the new version:
   ```sh
   APP=$(/bin/ls -td $HOME/Library/Developer/Xcode/DerivedData/Labstream-*/Build/Products/Debug-xrsimulator/Labstream.app | head -1)
   /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Info.plist"   # == X.Y.Z
   /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Info.plist"              # build number
   ```
3. Run the standard headless smoke test from the repo `CLAUDE.md` (install → launch → log →
   screenshot on this worktree's `$SIMID`). Confirm the app reaches the browse UI and the
   Settings "About" version reads `X.Y.Z`.
