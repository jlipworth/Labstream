# Active plans

This lane contains approved implementation plans and acceptance journals for work that is still active. A plan may record dated checkpoints, but it must keep a clear current-status summary so historical entries are not mistaken for current instructions.

## What belongs here

- approved implementation plans with open work or acceptance gates;
- durable acceptance journals that track implementation, verification, and remaining external gates;
- one plan per coherent program of work when a separate design and implementation plan would duplicate ownership.

Do not put unresolved investigations here (`docs/research/`), immutable audit or profiling observations here (`docs/evidence/`), or current product and contributor guidance here (the published top level of `docs/`).

## Naming and lifecycle

Name new plans `YYYY-MM-DD-<topic>.md`. Prefer the durable topic name over a redundant `-plan` suffix. Put the status and ownership boundary near the top, link the evidence that motivated the work, and name the verification gates required for completion.

When a plan is complete or superseded:

1. promote proven behavior and durable procedures into the relevant current published pages;
2. resolve or move any still-open work into an explicitly linked successor;
3. move the plan to `docs/archive/plans/` without rewriting its historical journal; and
4. repair live links that should continue to navigate to it.

## Active plans

- [`2026-07-10-codebase-remediation.md`](2026-07-10-codebase-remediation.md) — whole-repository correctness, concurrency, performance, backend/platform sharing, and build-cost remediation journal.
- [`2026-07-20-macos-shell-redesign.md`](2026-07-20-macos-shell-redesign.md) — approved Mac source-list, toolbar Search, adaptive-window, and acceptance plan for #232.
- [`2026-07-20-tvos-implementation.md`](2026-07-20-tvos-implementation.md) — first-class tvOS implementation and acceptance plan.
