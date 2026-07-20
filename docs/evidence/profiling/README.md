# Profiling evidence

This directory contains small, privacy-safe, immutable profiling baselines. A baseline records a dated observation for comparison; it does not describe current performance, replace the current instrumentation/script interfaces, or establish an optimization backlog by itself.

## What belongs here

Use this lane only for manually reviewed summaries that are useful across branches or releases. Keep raw Instruments traces, simulator logs, screenshots, and media-specific notes out of git because they can contain private server, account, library, media-title, URL, token, hostname, or local-path data.

Do not put current profiling instructions here, speculative performance plans here, or raw/generated measurement directories here. Current procedures belong in published development documentation, active work belongs in `docs/plans/`, and unresolved performance questions belong in `docs/research/`.

## Naming and contents

Prefer one Markdown file per profiling pass, named:

```text
YYYY-MM-DD[-<commit>]-<device>-<scenario>.md
```

Examples:

- `2026-06-19-simulator-home-cold.md`
- `2026-06-19-466b76d-vision-pro-playback-start.md`

Each baseline should include:

- branch and commit SHA;
- date/time and simulator/runtime or physical-device class, without serial numbers;
- backend (`Plex`, `Jellyfin`, or `Local`) and scenario name, without media titles or server names;
- command used to collect or summarize logs;
- a redacted summary from `uv run scripts/perf-log-summary.py --markdown`;
- a short interpretation and follow-up issue numbers, if any; and
- a nonsensitive local-only pointer to raw evidence kept outside the repository.

Do not rewrite an old baseline to match current performance. Add a new dated baseline, promote durable procedures or conclusions into current documentation, and keep this file only while it remains useful for trend comparison.
