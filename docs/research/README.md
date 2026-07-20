# Current research notes

This directory is for active research that may shape upcoming implementation, but is not yet part of the shipped architecture.

Use this lane when a topic is still being evaluated, has not been implemented, or needs live validation before it can become a current invariant in the top-level docs. Once implementation lands and behavior is proven, promote the durable parts into the focused current docs such as `BACKENDS.md`, `PLAYBACK-ARCHITECTURE.md`, `PERSISTENCE.md`, or `TESTING-STRATEGY.md`.

Historical or superseded research belongs in `docs/archive/research/`. Do not put new planning work directly in the archive unless it is already obsolete at the time it is written.

## Promotion rule

- **Research docs:** cite source APIs, list uncertainties, and define validation tasks.
- **Current docs:** describe only implemented or deliberately accepted project behavior.
- **Archive docs:** retain historical context that should not be treated as current guidance.

## Active notes

- [`2026-07-20-tvos-implementation-plan.md`](2026-07-20-tvos-implementation-plan.md) —
  staged plan for a first-class tvOS target, ten-foot focus and Siri Remote UX,
  capability-driven playback negotiation, physical Apple TV validation, and
  TestFlight/App Store acceptance tracked by
  [issue #246](https://github.com/jlipworth/Labstream/issues/246).
- [`2026-07-10-codebase-remediation-plan.md`](2026-07-10-codebase-remediation-plan.md) —
  staged implementation plan for the whole-repository correctness, concurrency,
  performance, backend/platform sharing, and build-cost audit. It remains active until
  every audit ID is closed or explicitly superseded.
## Closed review snapshots

- [`2026-07-12-remediation-branch-review.md`](2026-07-12-remediation-branch-review.md) and
  [`2026-07-12-remediation-delta-review.md`](2026-07-12-remediation-delta-review.md) record
  point-in-time reviews of the remediation branch. Their confirmed code findings were
  subsequently fixed; consult their resolution banners and the remediation plan's current
  status table rather than treating their finding sections as open instructions.
- [`offline-playback-compatibility.md`](offline-playback-compatibility.md) records the
  implementation research for closed issue #167. Its codec/container rationale remains
  useful history, while current routing, finalization, and revalidation behavior is
  canonical in [`DOWNLOADS-OFFLINE.md`](../DOWNLOADS-OFFLINE.md).
