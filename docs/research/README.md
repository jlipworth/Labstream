# Active research

This lane is only for unresolved investigations that may shape future implementation. A research note should make the open questions, competing interpretations, source evidence, and validation needed for a decision explicit.

## What belongs here

- investigations whose answer or implementation direction is still unknown;
- source/API comparisons that need live or device validation before becoming an accepted invariant;
- bounded spikes with an explicit decision or validation exit.

Do not put approved implementation plans here (`docs/plans/`), immutable audit or profiling evidence here (`docs/evidence/`), resolved reviews or closed investigations here (`docs/archive/`), or current product guidance here (the published top level of `docs/`).

## Naming and lifecycle

Name new notes `YYYY-MM-DD-<topic>.md`. State the unresolved questions and exit criteria near the top, cite primary sources, and avoid presenting hypotheses as shipped behavior.

When the investigation resolves:

- move approved implementation work to `docs/plans/`;
- move durable observations to `docs/evidence/` when they remain useful as comparison data;
- promote proven behavior into the relevant current published pages; and
- move a closed investigation to `docs/archive/research/` when its historical reasoning is still worth retaining.

## Active research notes

- [`2026-07-20-tvos-screen-audit.md`](2026-07-20-tvos-screen-audit.md) — exhaustive tvOS
  screen/interaction audit for [issue #246](https://github.com/jlipworth/Labstream/issues/246),
  tracking per-defect status; open items remain (search input, physical-device sweep).
- [`2026-07-21-tvos-session-report.md`](2026-07-21-tvos-session-report.md) — evidence-first
  session record for the tvOS focus/remote-input work, including the parked TVUI-004
  search-keyboard investigation. The tvOS implementation plan itself lives in
  [`docs/plans/2026-07-20-tvos-implementation.md`](../plans/2026-07-20-tvos-implementation.md).
