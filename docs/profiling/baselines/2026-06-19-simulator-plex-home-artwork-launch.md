# Profiling baseline: Plex Home launch artwork loads

- Branch: `issue/42-performance-profiling`
- Commit: containing #42 profiling commit on `issue/42-performance-profiling` (read with `git log -- docs/profiling/baselines/2026-06-19-simulator-plex-home-artwork-launch.md`)
- Date/time: 2026-06-19 11:33-11:34
- Device: Apple Vision Pro simulator, visionOS 26.5 runtime
- Backend: Plex
- Scenario: signed-in app launched to Home after rebuild/relaunch, then after a second relaunch; visible Home artwork loaded; no manual navigation
- Instrumentation: `PerformanceInstrumentation` `perf.span` logs summarized with `uv run scripts/perf-log-summary.py --markdown`
- Raw evidence: XcodeBuildMCP `osLogPath` file kept locally only, not committed

## Summary

| phase | backend | count | failures | min_ms | p50_ms | p95_ms | max_ms |
| --- | --- | --- | --- | --- | --- | --- | --- |
| artwork.load | Plex | 20 | 0 | 45 | 47 | 49 | 49 |
| home.load | Plex | 2 | 0 | 919 | 2112 | 3187 | 3306 |

## Interpretation

This confirms the new artwork span is emitted and parseable for visible Home posters/thumbs. The Home loads include one rebuild-adjacent outlier and should not replace the earlier small Home-only launch baseline. The artwork numbers are useful as a first simulator smoke baseline only; repeat cold/warm runs and device traces are still needed before product conclusions.
