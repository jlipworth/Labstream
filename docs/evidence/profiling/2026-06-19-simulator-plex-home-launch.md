# Profiling baseline: Plex Home launch load

> **Historical baseline:** measurements from the dated branch/runtime below. Compare trends
> only; this is not a current performance claim or current profiling procedure.

- Branch: `issue/42-performance-profiling`
- Commit: `73d9629` (`Add repeatable performance profiling spans`); use `git log --follow -- docs/evidence/profiling/2026-06-19-simulator-plex-home-launch.md` for later history
- Date/time: 2026-06-19 11:19-11:26
- Device: Apple Vision Pro simulator, visionOS 26.5 runtime
- Backend: Plex
- Scenario: signed-in app launched to Home after stop/relaunch; no manual navigation
- Instrumentation: `PerformanceInstrumentation` `perf.span` logs summarized with `uv run scripts/perf-log-summary.py --markdown`
- Raw evidence: XcodeBuildMCP `osLogPath` files kept locally only, not committed

## Summary

| phase | backend | count | failures | min_ms | p50_ms | p95_ms | max_ms |
| --- | --- | --- | --- | --- | --- | --- | --- |
| home.load | Plex | 3 | 0 | 814 | 823 | 1152 | 1188 |

## Interpretation

This is a small simulator-only smoke baseline proving the new privacy-safe profiling spans are emitted and parseable over repeated launches. It should not be treated as headset or product performance. The next useful baselines are Jellyfin Home, library-grid first/page loads, and playback startup paths on simulator, then representative physical Vision Pro traces before making product claims.
