# Compile performance audit

The Phase 0 compile baseline is intentionally opt-in: it performs many clean and incremental
builds and is not a CI gate. Run it on an otherwise idle Mac with the same Xcode version for every
baseline being compared.

```sh
# Inspect the matrix without building.
scripts/compile-audit.py

# Production baseline: median of three comparable arm64 runs.
scripts/compile-audit.py --run
```

The runner exports committed `HEAD` to an isolated workspace, so it neither measures nor mutates
uncommitted work. PMSKit uses an isolated SwiftPM scratch path; every app lane uses isolated
DerivedData and a generic destination, so no simulator is booted. The three representative edits
cover a PMSKit playback policy, a shared app UI leaf, and the current playback coordinator. They do
not touch download-engine code.

Results are written below the gitignored `build/compile-audit/` directory by default. `summary.md`
and `measurements.csv` contain commit/toolchain labels, elapsed time, peak RSS, warning counts,
type-check threshold counts, product size, and compile/link fanout. Individual logs and normalized
warning inventories remain local because raw compiler output includes filesystem paths. Do not
publish the output directory without reviewing it.

Compare medians only across the same Mac, Xcode, architecture, configuration, and repetition count.
Treat these as review prompts rather than test failures:

- function/body type checking over 300 ms;
- expression type checking over 200 ms;
- clean-build median regressions over 10%;
- representative incremental median regressions over 15%;
- peak RSS or product-size regressions over 10%.

Use `--output build/compile-audit/<label>` for a stable local label. The directory must not already
exist. A failed measured command is recorded in the summary and makes the runner exit nonzero after
the matrix completes.
