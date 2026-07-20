# Evidence

This lane contains privacy-safe, immutable observations used to support decisions. Evidence records what was measured, audited, reviewed, or observed at a named point in time; it does not replace current guidance or create an implementation queue by itself.

## What belongs here

- dated audit inventories, coverage matrices, and retained validation observations under [`audits/`](audits/);
- small, reviewed profiling summaries under [`profiling/`](profiling/);
- enough provenance to understand the source revision, environment, method, and limits of the observation.

Do not put active implementation plans here (`docs/plans/`), unresolved questions here (`docs/research/`), resolved branch reviews here (`docs/archive/reviews/`), raw logs/traces/screenshots, or canonical product and contributor instructions.

## Naming and lifecycle

Use `YYYY-MM-DD-<topic>.md`, adding a short commit or environment label only when it distinguishes comparable observations. Keep raw or sensitive artifacts outside git. If later work changes the conclusion, preserve the original observation and add a dated correction or status banner rather than rewriting history.

Promote durable conclusions into the relevant current published page. Evidence normally remains in this lane for comparison and auditability; move it to the archive only when it is no longer useful as active evidence, and keep any live navigation working after the move.
