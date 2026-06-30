# Current research notes

This directory is for active research that may shape upcoming implementation, but is not yet part of the shipped architecture.

Use this lane when a topic is still being evaluated, has not been implemented, or needs live validation before it can become a current invariant in the top-level docs. Once implementation lands and behavior is proven, promote the durable parts into the focused current docs such as `BACKENDS.md`, `PLAYBACK-ARCHITECTURE.md`, `PERSISTENCE.md`, or `TESTING-STRATEGY.md`.

Historical or superseded research belongs in `docs/archive/research/`. Do not put new planning work directly in the archive unless it is already obsolete at the time it is written.

## Promotion rule

- **Research docs:** cite source APIs, list uncertainties, and define validation tasks.
- **Current docs:** describe only implemented or deliberately accepted project behavior.
- **Archive docs:** retain historical context that should not be treated as current guidance.

## Active notes

Active research notes in this audit scope should be listed here once they are current enough for other contributors to rely on. If a note is superseded, move it under `docs/archive/` instead of leaving it in this index as active guidance.
