# Signing and repo readiness — design

**Date:** 2026-06-10
**Status:** Approved direction; implementation plan pending
**Scope:** Personal-device signing and GitHub/Woodpecker repo hygiene for VisionPlex. App functionality is explicitly out of scope.

## Goal

Make the repository and local Xcode setup feel like a real personal-device Apple app project, without starting App Store/TestFlight publication work yet. The near-term target is: a clean VisionPlex identity, predictable local signing, documented device-install friction, and lightweight CI that matches the user's existing local Woodpecker style.

## Non-goals

- No App Store Connect setup.
- No TestFlight upload/archive workflow as part of this pass.
- No app functionality changes.
- No committed Apple certificates, provisioning profiles, Plex tokens, or machine-local developer account data.
- No broad Xcode project/file renames unless required for a stable bundle/display identity.

## Current state summary

The app already builds as a visionOS Xcode project with automatic signing and an ignored `Signing.local.xcconfig` containing the local Apple Developer Team ID. The public README already presents the project as **VisionPlex**, but signing/run commands and bundle identity still reference `com.personal.PlexAVPApp` in several places. GitHub CLI is authenticated locally, but the repo has no `.woodpecker/` CI config yet. The working tree currently has unrelated modified files; implementation must preserve them and stage only intentional readiness changes.

## Recommended approach: VisionPlex dev-ready

Use a focused personal-device readiness pass:

1. Update the development bundle identifier to `com.jlipworth.VisionPlex`.
2. Set display/app-facing naming to **VisionPlex** where appropriate, while avoiding disruptive internal target or folder renames unless Xcode requires them.
3. Keep automatic signing and the existing local signing include pattern:
   - commit `Signing.xcconfig`
   - keep `Signing.local.xcconfig` ignored
   - document that the local file should contain only `DEVELOPMENT_TEAM = your Apple Developer Team ID`
4. Add Woodpecker CI for lightweight, locally useful checks.
5. Update README, `docs/DEVELOPMENT.md`, and agent notes so commands and bundle IDs match the new state.
6. Include a future publication checklist so the repo does not paint itself into a corner.

## Signing design

`Signing.xcconfig` remains the shared committed signing shim. It should optionally include `Signing.local.xcconfig`, allowing fresh clones and CI to build without local developer credentials. Device installs use Xcode automatic signing with the local Apple Development identity and Xcode-managed development provisioning profiles.

The docs should be explicit that the Vision Pro trust/developer-mode prompts are Apple platform security gates for locally installed development apps. They are not a repo bug and cannot be removed by changing the project file. The practical runbook is: sign in to the Apple account in Xcode, enable Developer Mode/trust on device as prompted, let Xcode register/manage the device/profile, then run from Xcode.

## Naming and bundle identity

The development bundle ID should become:

```text
com.jlipworth.VisionPlex
```

The installed app/display identity should read **VisionPlex**. The Xcode target, source folder, scheme, and DerivedData product may remain `PlexAVPApp` during this pass if keeping them avoids fragile churn. This creates a clean external identity while preserving the working project structure.

Documentation must use the new bundle ID in install/launch commands. Any old `com.personal.PlexAVPApp` references should be removed or clearly marked historical.

## Woodpecker CI design

Add a small `.woodpecker/` setup modeled after the user's other repos: simple YAML pipelines with direct shell commands and no GitHub Actions dependency.

Initial pipelines:

- `plexkit.yml`: run `cd PlexKit && swift test`.
- `hygiene.yml`: run repository checks that do not require Apple signing credentials, such as `git diff --check`, committed-secret/local-signing guard checks, and lightweight docs/reference validation.

Avoid Discord notification/secrets plumbing in the first pass. It can be added later if the repo starts relying on Woodpecker status notifications.

Because Linux Woodpecker runners often cannot build a visionOS Xcode app, CI should not pretend to validate the full app target unless a macOS runner is confirmed. The local Mac remains the source of truth for `xcodebuild` visionOS simulator builds.

## README and repo hygiene design

Update the README and development docs to answer the practical setup questions first:

- prerequisites: Xcode 26.5, visionOS simulator/device, Apple account in Xcode
- simulator build command with signing disabled
- device signing setup with `Signing.local.xcconfig`
- device trust/developer-mode note
- `PlexKit` test command
- Woodpecker CI coverage and limitations
- secret hygiene: never commit Plex tokens, client identifiers, local signing files, or generated provisioning assets

The README can keep the sideload-only framing, but should no longer imply the old bundle ID or old app identity.

## Future path to publication

This pass should make a later publication push easier, not complete it. A future App Store/TestFlight pass would add:

1. paid Apple Developer Program account confirmation
2. App Store Connect app record
3. registered production bundle ID, likely still `com.jlipworth.VisionPlex` if available and appropriate
4. distribution certificate/profile or Xcode-managed distribution signing
5. archive/export/upload runbook
6. privacy nutrition label and data-use review, especially Plex login/token behavior
7. screenshots, icon review, marketing text, support URL, privacy policy URL
8. TestFlight beta workflow and expiration expectations
9. App Review risk review for third-party Plex client behavior and Plex terms

Keep these as documented future steps only. Do not add publication-only settings that complicate local development now.

## Verification plan

Implementation should prove the readiness work with:

- `xcodebuild -project PlexAVPApp.xcodeproj -scheme PlexAVPApp -destination 'platform=visionOS Simulator,name=Apple Vision Pro' -configuration Debug build CODE_SIGNING_ALLOWED=NO`
- `cd PlexKit && swift test`
- `xcodebuild -project PlexAVPApp.xcodeproj -scheme PlexAVPApp -showBuildSettings` filtered for bundle/signing/product values
- `git diff --check`
- confirm no ignored local signing file or secret-like artifact is staged
- inspect `.woodpecker/*.yml` for simple, runnable commands

## Implementation constraints

- Preserve existing unrelated working-tree changes unless the user explicitly approves touching them.
- Stage and commit only readiness-related files.
- Prefer narrow Xcode setting edits over broad project regeneration.
- Keep local signing values out of git.
