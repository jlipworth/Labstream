# Profiling baselines

Baseline files are immutable, dated evidence. They do not describe current performance or
replace the current instrumentation and script interfaces.

Keep raw Instruments traces, simulator logs, screenshots, and media-specific notes out of git. They can contain
private server, account, library, media-title, URL, token, hostname, or local-path data.

Use this directory only for small, manually reviewed, privacy-safe baseline summaries that are useful to compare over
time. Prefer one Markdown file per profiling pass, named:

```text
YYYY-MM-DD[-<commit>]-<device>-<scenario>.md
```

Suggested examples:

- `2026-06-19-simulator-home-cold.md`
- `2026-06-19-466b76d-vision-pro-playback-start.md`

Each baseline should include:

- branch and commit SHA
- date/time and simulator/runtime or physical-device class, without serial numbers
- backend (`Plex`, `Jellyfin`, or `Local`) and scenario name, without media titles or server names
- command used to collect/summarize logs
- redacted summary table from `uv run scripts/perf-log-summary.py --markdown`
- short interpretation and follow-up issue numbers, if any
- pointer to any raw trace kept outside the repo, using a local-only filename/location that is not sensitive

Do not commit a baseline until it has been reviewed for privacy. For quick one-off measurements, a GitHub issue comment
is usually enough; commit baselines here when we need long-term trend comparison across branches/releases.
