# Compile performance

The Phase 5 compile audit is intentionally opt-in: it performs a large paired matrix of clean,
no-op, representative incremental, and test-coverage builds. It is not a CI gate. Run it on an
otherwise idle Mac and do not change Xcode, power mode, or other material host conditions during a
comparison.

```sh
# Inspect the matrix without building. Five paired repetitions is the enforced minimum/default.
scripts/compile-audit.py

# Compare two explicit committed snapshots. Refs are resolved to immutable commit IDs up front.
scripts/compile-audit.py --run \
  --control <control-commit> \
  --candidate <candidate-commit> \
  --seed 0 \
  --output build/compile-audit/<comparison-label>
```

`--control` and `--candidate` are required for a run, must resolve to different commits, and are
exported with `git archive` into separate isolated workspaces. Uncommitted files are therefore
neither measured nor mutated. The output directory must not already exist and is made private to
the current user. Each commit gets independent SwiftPM scratch and Xcode DerivedData directories;
all commands use arm64, Debug, fixed generic destinations, and no simulator boot.

## Pairing and scenarios

The numeric seed is recorded and deterministically chooses which variant runs first at paired
index 1. Each scenario runs as an adjacent control/candidate pair. Order then alternates by same
sample index (`control/candidate`, then
`candidate/control`, or the inverse) to reduce monotonic host drift without pretending to remove
it. Do not compare an unpaired control run from one invocation with a candidate from another.

PMSKit measures a cold build, a no-op build, an incremental edit to
`PlaybackFailurePolicy.swift`, and a code-coverage test build. App lanes measure clean and no-op
builds plus representative edits to a PMSKit playback policy, shared UI leaf, and playback
coordinator. After every temporary edit, the original bytes are restored and a **checked** settle
build runs before the next scenario. A failed settle is recorded as a run failure instead of being
silently ignored.

This is a representative compile-cost audit, not exhaustive dependency coverage. In particular,
it does not currently measure release/LTO builds, Intel compilation, physical-device signing,
simulator runtime launch cost, or every feature-module leaf edit.

## Results and interpretation

The ignored output directory contains:

- `metadata.json`: full control/candidate hashes, requested refs, seed and per-index order, full
  Xcode/Swift/Git versions and selected toolchain environment, fixed destinations,
  architecture/configuration, timestamps, relevant start/end host/power/load/disk covariates, and
  command/restoration failures;
- `runner-source.py`: the exact runner source used; metadata also records its SHA-256, repository
  commit, and worktree status, and the result manifest checksums the copy;
- `measurements.csv`: every raw measurement and its private-log filename;
- `paired-deltas.csv`: same-index candidate-minus-control deltas and percentages;
- `summary.md`: medians for each variant plus median paired elapsed-time deltas;
- `manifest.sha256`: SHA-256 checksums for result files, normalized warnings, and private raw logs
  (the large disposable `workspace/` is intentionally excluded);
- `*.log` and `*.warnings.txt`: private compiler output which may contain local filesystem paths.

Keep the entire directory local unless its raw files have been reviewed. Verify integrity from the
result directory with `shasum -a 256 -c manifest.sha256` before using or sharing selected results.
A failed measured command or restoration settle is retained in metadata/CSV and makes the runner
exit nonzero after completing the matrix.

Only compare runs with matching machine, toolchain, architecture, configuration, repetition count,
and materially similar recorded covariates. Candidate-minus-control medians and percentages are
descriptive summaries of at least five local paired samples; they do **not** establish statistical
significance. Treat these as investigation prompts rather than pass/fail thresholds:

- function/body type checking over 300 ms;
- expression type checking over 200 ms;
- clean-build paired median regression over 10%;
- representative incremental paired median regression over 15%;
- peak RSS or product-size paired median regression over 10%.

Increase `--repetitions` above five when noise is high. The runner intentionally rejects fewer than
five repetitions rather than producing a deceptively small “production baseline.”
