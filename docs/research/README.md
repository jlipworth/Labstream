# Current research notes

This directory is for active research that may shape upcoming implementation, but is not yet part of the shipped architecture.

Use this lane when a topic is still being evaluated, has not been implemented, or needs live validation before it can become a current invariant in the top-level docs. Once implementation lands and behavior is proven, promote the durable parts into the focused current docs such as `BACKENDS.md`, `PLAYBACK-ARCHITECTURE.md`, `PERSISTENCE.md`, `DOWNLOADS-OFFLINE.md`, or `TESTING-STRATEGY.md`.

Historical or superseded research belongs in `docs/archive/research/`. Do not put new planning work directly in the archive unless it is already obsolete at the time it is written.

## Promotion rule

- **Research docs:** cite source APIs, list uncertainties, and define validation tasks.
- **Current docs:** describe only implemented or deliberately accepted project behavior.
- **Archive docs:** retain historical context that should not be treated as current guidance.
