# Audit evidence

This directory contains dated, point-in-time audit and validation evidence. Files may describe defects, coverage gaps, harness results, or execution history at a specific revision, but their status banners and current published documentation determine whether a finding is still active.

## What belongs here

- subsystem audits and extracted state-machine snapshots;
- coverage matrices and adversarial review evidence that remain useful for comparison;
- bounded harness records whose code and current `--help` output remain authoritative for execution.

Do not treat this directory as an implementation backlog. Active remediation belongs in `docs/plans/`; unresolved investigation belongs in `docs/research/`; resolved branch reviews belong in `docs/archive/reviews/`; current behavior belongs in the published topic pages.

## Naming and lifecycle

Name files `YYYY-MM-DD-<subsystem>-<purpose>.md`. Record the source revision, method, scope, limitations, and privacy boundary. Preserve point-in-time observations; add a status banner or dated addendum when later work resolves or invalidates them. Promote current invariants and procedures into canonical documentation instead of continually refreshing an audit snapshot.

## Retained audits

- [`2026-07-10-downloads-engine-audit-plan.md`](2026-07-10-downloads-engine-audit-plan.md)
- [`2026-07-10-downloads-state-machines.md`](2026-07-10-downloads-state-machines.md)
- [`2026-07-11-downloads-fault-injection-harness.md`](2026-07-11-downloads-fault-injection-harness.md)
- [`2026-07-11-downloads-phase4-coverage-matrix.md`](2026-07-11-downloads-phase4-coverage-matrix.md)
