# Poisoned Plex Connection Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make player Retry/recovery avoid a poisoned pooled `URLSession.shared` connection after heavy-stream stalls (#33).

**Architecture:** Add a small PMSKit-owned recovery session policy so the timeout/cache/reuse choices are unit-testable. Add an app-side `PlexClient.recovery(identity:)` factory and let `PlaybackController.retry()` switch its control-plane client (decision/probe/stop/timeline) to a fresh short-timeout session before rebuilding. Leave app-wide networking and AVFoundation media loading unchanged.

**Tech Stack:** Swift, PMSKit Swift Package tests, visionOS app code, URLSessionConfiguration.

---

## File structure

- Create `PMSKit/Sources/PMSKit/PlexSessionConfiguration.swift`: pure tested URLSessionConfiguration factory for recovery control-plane requests.
- Create `PMSKit/Tests/PMSKitTests/PlexSessionConfigurationTests.swift`: tests timeout/cache/no-cookie behavior.
- Modify `VisionPlay/Networking/PlexClient.swift`: add app-side recovery client factory using PMSKit policy.
- Modify `VisionPlay/Player/TimelineReporter.swift`: allow PlaybackController to swap the reporter's client after a recovery retry.
- Modify `VisionPlay/Player/PlaybackController.swift`: store player control-plane client as mutable and replace it with a fresh recovery client before user Retry rebuild.
- Modify `TESTING-CHECKLIST.md`: add #33 live retry validation.

## Tasks

### Task 1: TDD PMSKit recovery session policy

- [ ] Write failing tests in `PMSKit/Tests/PMSKitTests/PlexSessionConfigurationTests.swift` for a `PlexSessionConfiguration.recoveryControlPlane(timeout:)` factory.
- [ ] Run `cd PMSKit && swift test --filter PlexSessionConfigurationTests`; expect compile failure because the type does not exist.
- [ ] Create `PMSKit/Sources/PMSKit/PlexSessionConfiguration.swift` with the minimal policy factory.
- [ ] Re-run the filtered test and full `cd PMSKit && swift test`.

### Task 2: Wire app recovery client

- [ ] Add `PlexClient.recovery(identity:timeout:)` in `VisionPlay/Networking/PlexClient.swift`.
- [ ] Change `PlaybackController`'s app control-plane client from `let` to `var`.
- [ ] Add a `switchToRecoveryControlClient()` helper that creates a fresh recovery `PlexClient`, assigns it, and updates the timeline reporter.
- [ ] Call the helper at the start of user `retry()` before `beginStreaming(...)`.
- [ ] Add `TimelineReporter.useClient(_:)` so future heartbeats use the fresh client too.

### Task 3: Verify and document

- [ ] Add #33 live-test line to `TESTING-CHECKLIST.md`.
- [ ] Run `cd PMSKit && swift test`.
- [ ] Run fresh unsigned visionOS simulator build.
- [ ] Run `./scripts/ci-hygiene.sh` and `git diff --check`.
- [ ] Commit and comment on #33.
