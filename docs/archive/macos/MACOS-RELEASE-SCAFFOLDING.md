# macOS release/versioning scaffolding

> **Archived:** issue-era release planning. The Mac target remains a local-build development
> preview; current status and deferred decisions live in [`docs/MACOS.md`](../../MACOS.md).

This is the minimal release/distribution note for #228. It deliberately does not decide the final App Store Connect strategy.

## Current #228 decision

- Native macOS target: `LabstreamMac`
- Local host deploy script: `scripts/deploy-macos-to-host.sh`
- Local host validation script: `scripts/validate-macos-228.sh`
- Default local Mac debug identity: per-worktree bundle id, e.g. `org.labstream.Labstream.dev.issue-228-macos`
- Production/canonical bundle id remains `org.labstream.Labstream`
- Mac App Store-first entitlement posture for v1: sandbox + network client
- Downloads live in the app container for v1; external folders/security-scoped bookmarks are deferred

## Versioning policy for now

The Mac target has its own marketing/build settings so Mac builds can be versioned independently from iPhone/iPad/visionOS while the product/release strategy is still being decided. Do not collapse those version settings into the mobile/vision release train without an explicit release decision.

Before any App Store/TestFlight archive:

1. Decide whether Mac ships under the same App Store record/universal purchase as iPhone/iPad/visionOS or a separate SKU.
2. Confirm the production bundle id and signing entitlements.
3. Confirm the production keychain service/access-group behavior.
4. Confirm whether Mac should share Plex credentials with the other platforms or stay platform-specific.
5. Re-run the #228 validation script plus the full manual validation checklist.
6. Archive using the canonical production bundle id, not a per-worktree dev id.

## Local dev identity rules

`deploy-macos-to-host.sh` defaults to a deterministic per-worktree dev identity. This is intentional because macOS has no simulator-per-worktree equivalent. The dev identity isolates:

- sandbox container
- app support/offline downloads
- keychain service used by the local debug app
- LaunchServices app identity
- background download session identifier

Use `--use-production-bundle-id` only when intentionally testing production identity behavior. Do not run multiple production-identity Mac worktrees concurrently.

## Deferred release decisions

These are intentionally out of scope for #228:

- final App Store Connect platform/SKU plan
- TestFlight lane setup
- direct download / notarization distribution
- external download folder support
- security-scoped bookmark migration/reconciliation
- final brand/icon art approval

Track those as follow-up release/product issues after the functional native Mac baseline is stable.
