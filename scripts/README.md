# Scripts

Repository utilities for validation, simulator/worktree hygiene, local host runs, device deploys,
privacy-safe evidence collection, and opt-in live-server probes. Scripts that need real servers read
gitignored environment files; keep tokens, server URLs, item IDs, device IDs, generated logs, and
media details out of commits and public issues.

## Build and validation

- `xcodebuild-versioned.sh` — wraps `xcodebuild` and stamps a source-derived internal Build ID.
- `build-version-args.sh` — prints the version/build arguments used by the wrapper and deploy scripts.
- `ci-hygiene.sh` — repository privacy, signing, placeholder, and tooling guardrails.
- `check-docs-mermaid.py` — verifies that published Mermaid source fences become
  generated Mermaid containers without external script dependencies.
- `ci-macos-apple-platforms.sh` — native-runner preflight, isolated unsigned
  visionOS/iOS/iPadOS builds, PMSKit tests, evidence, and cleanup. See
  [`docs/MACOS-CI.md`](../docs/MACOS-CI.md).
- `native-test-matrix.py` + `native-test-matrix.json` — side-effect-free smoke,
  affected-platform, and full native validation planning, with explicitly gated
  lane-at-a-time execution. Simulator lanes require the exact ID owned by the current
  worktree, sole-booted state, and an explicit lease assertion; see
  [Testing strategy](../docs/TESTING-STRATEGY.md#native-apple-matrix-driver).
- `publication-audit.py` — audits tracked text, Git history, and optionally GitHub issue text for
  sensitive publication regressions without echoing matched secrets.
- `loc.sh` — informational per-module source line counts.
- `perf-log-summary.py` — converts privacy-safe performance signposts into summaries/Markdown and
  produces strict, raw-artifact-bound comparison summaries.
- `perf-compare.py` — freezes a control-only minimum detectable effect, then validates and compares
  seeded paired control/candidate runs with correctness, provenance, failure, and covariate gates.
- `performance-audit-contract.py` — validates Release-parity `PerformanceAudit` build
  settings, scans a built app for Debug-only fixture/probe/evidence contracts, and validates
  version-1 local evidence manifests plus their checksums. The closed JSON schema lives at
  `schemas/performance-audit-manifest-v1.schema.json`. Profile actions for all four app schemes use
  `PerformanceAudit` and intentionally do not inherit Debug launch arguments or environment. Run:

  ```sh
  scripts/performance-audit-contract.py configuration
  scripts/performance-audit-contract.py binary /path/to/PerformanceAudit/Labstream.app
  scripts/performance-audit-contract.py manifest artifacts/performance-audit/<run>/manifest.json
  ```

  Raw runs belong under the gitignored `artifacts/performance-audit/` directory. Each manifest records
  comparison role, warmup/measured status, sample index, and seeded-order identity in addition to the
  product, device, state, scenario, and retention metadata required by the comparison protocol.
  Manifest identity fields use generated opaque shapes (`run-<hex>`, `scenario-<hex>`,
  `fixture-<hex>`) and semantic fields use bounded enums; raw pointers use only
  `raw/artifact-NNNN.<type>`, with a fixed `summary/redacted.json` summary path. The validator also
  rejects URLs, IP addresses, and absolute user paths in manifest strings.

  This is a metadata contract, not a content scrubber. It does not inspect raw trace/log payloads,
  prove that a human marked the correct privacy status, or make raw evidence publication-safe. Keep
  raw artifacts local and review the redacted summary before setting `publishable` with a `reviewed`
  status. The configuration check compares effective Swift/C/C++ flags, definitions, optimization,
  coverage, sanitizers, signing, and other Release-parity settings; the profiling compilation
  condition is the sole permitted condition difference.

### Paired performance comparison

Comparison evidence is fail-closed. Each raw log contains the opaque capture marker generated from
its manifest, and that manifest points to the exact raw artifact and SHA-256. Generate the marker
before appending the bounded unified-log capture, update the raw checksum, then derive the strict
summary with the closed correctness fields required for that phase/backend:

Browse/artwork measurement uses separate `home.first_content`/`home.load` and
`library_grid.first_content`/`library_grid.complete` spans, a post-debounce `search.load` span,
terminal page/publication counters, and the closed `artwork.load delivery=` provenance enum. These
records measure existing execution only; they do not select a transport, fixture, cache policy, or
retry policy. `publication_count` is an allowed diagnostic, not a correctness selector: concurrent
completion order can vary between otherwise equivalent runs.

```sh
scripts/perf-log-summary.py --emit-capture-marker \
  --manifest run/manifest.json --workload-id workload-0123456789ab \
  >> run/raw/artifact-0001.log
# Append only this launched run's bounded `log show`, then update the manifest raw checksum.
scripts/perf-log-summary.py --json --strict \
  --manifest run/manifest.json --raw-artifact run/raw/artifact-0001.log \
  --workload-id workload-0123456789ab --phase home.load --backend Plex \
  --correctness-field hub_count --correctness-field item_count \
  --expected-span-count 1 > run/summary/redacted.json
```

Freeze the MDE from control-only evidence **before** candidate capture, record the printed checksum,
then compare separately collected seeded pairs. `short` requires three warmups and twenty measured
pairs; `long` requires one warmup and five measured pairs. Invalid, incomplete, failed, mismatched-
work, privacy-unsafe, out-of-order, or materially drifted evidence produces insufficient data rather
than an improvement. The current manifest schema does not cryptographically bind the frozen checksum
before candidate capture, so the result records that ordering as operator-attested.

```sh
scripts/perf-compare.py freeze --control-manifest runs/control-*/*.json \
  --phase home.load --backend Plex --correctness-field hub_count \
  --correctness-field item_count \
  --sample-policy short --out frozen-mde.json
scripts/perf-compare.py compare \
  --control-manifest runs/pairs/control-*/*.json \
  --candidate-manifest runs/pairs/candidate-*/*.json \
  --phase home.load --backend Plex --correctness-field hub_count \
  --correctness-field item_count --sample-policy short \
  --frozen-mde frozen-mde.json --frozen-mde-sha256 <printed-checksum> \
  --max-free-storage-drift-bytes 1073741824 --max-pair-gap-seconds 120 \
  --json-out result.json --csv-out pairs.csv
```
- `compile-audit.py` — opt-in, isolated, paired arm64 compile-cost comparison for explicit control
  and candidate commits across PMSKit and all app schemes; it enforces at least five alternating
  same-index repetitions and records integrity/covariate metadata. See
  [`docs/COMPILE-PERFORMANCE.md`](../docs/COMPILE-PERFORMANCE.md).
- `tests/test_compile_audit.py`, `tests/test_docs_mermaid.py`,
  `tests/test_perf_log_summary.py`, `tests/test_perf_compare.py`, and
  `tests/test_tooling_hardening.py` —
  script/tooling tests. They run as part of
  `scripts/ci-hygiene.sh` when `pyproject.toml` is present.

## Simulator and worktree helpers

- `worktree-sim.sh` — provisions one simulator per worktree. The default is visionOS
  (`vpwt-*`, `.simid`); opt into iPhone or iPad with `--platform`,
  `LABSTREAM_SIM_PLATFORM`, or a gitignored `.simplatform` file. Resolve a concrete ID and never
  target `booted`.
- `agent-sim-run.sh` — bounded visionOS agent scenarios with build/install/launch, screenshots,
  video, logs, and a machine-readable run result.
- `simclick.swift` — low-level simulator coordinate click helper used only by controlled local
  automation.

## Local Mac development preview

- `deploy-macos-to-host.sh` — builds/stages/optionally launches `LabstreamMac` on the arm64 host
  under an isolated per-worktree development identity; also owns safe staged-app/container cleanup.
- `smoke-macos-host.sh` — bounded signed-out host launch smoke under an isolated identity.
- `validate-macos-228.sh` — repeatable Mac-preview validation sweep. The filename is retained from
  the implementation issue; it also builds shared targets and runs focused diagnostics checks.
- `perf-macos-launch-idle.py` — external paired runner for two already-built Mac
  `PerformanceAudit` apps using the same dedicated `com.jlipworth.Labstream.perf.*` identity. It validates both
  products with `performance-audit-contract.py`, preserves the system-managed container root while
  resetting only its mutable `Data` subtree, seeds the
  canonical empty download index, and records adjacent A/B launch logs or exact-PID 120-second
  System Trace captures after a bounded 10-second readiness/settle interval. Unified-log bounds
  still begin before launch. Start with `--plan` and supply exact distinct artifact commits, an
  opaque device label, and retention deadline. Successful launch samples atomically publish a
  validated manifest, raw log, and strict `runtime.composition` summary consumable by
  `perf-compare.py`; failures publish no manifest and make the runner nonzero. Idle traces remain
  explicitly pre-manifest and `insufficient_data` until trace extraction lands.

There is no macOS simulator lane. See [`docs/MACOS.md`](../docs/MACOS.md).

## Physical-device deployment and evidence

- `deploy-to-device.sh` — development-signed build/install wrapper for a paired Apple Vision Pro.
- `deploy-mobile-to-device.sh` — development-signed `LabstreamMobile` build/install wrapper for a
  paired iPhone or iPad; set `IOS_DEVICE_ID` when more than one is paired.
- `deploy-ad-hoc-to-device.sh` — distribution-signed Ad Hoc Vision Pro build/export/install path;
  requires an appropriate distribution certificate and provisioning profile.
- `provisioning-profile-info.py` — provisioning-profile parsing/filtering shared by deploy scripts.
- `headset-evidence.sh` — read-only `devicectl` evidence bundle after a headset repro. Output under
  `build/headset-evidence/` can contain private artifacts and must be reviewed before sharing.
- `diagnostics-summarize.py` — deterministic, privacy-conscious first pass over an evidence bundle.
  It writes bounded triage/delta artifacts under the bundle's `analysis/` directory so agents do
  not repeatedly ingest raw rotated JSONL logs. Raw evidence is retained unchanged.

Device deploy scripts mutate the installed app and may replace another build with the same bundle
identifier. Read their `--help` output and the platform documentation before use.

## Simulator download probes

These launch the Debug app using the selected worktree simulator's already signed-in state. They do
not read a token environment file:

- `probe-plex-range-drop.sh` — Plex static-range recoverability with connection-loss (default),
  validator-flip, and one-shot mid-train 401 transport faults.
- `probe-jellyfin-download.sh` — Jellyfin original/static and optimize/transcode download lanes.
- `probe-emby-download.sh` — Emby route negotiation, converted-source reuse, and optimize/download
  lanes.

Outputs live under `build/probes/` and are local evidence, not publication-ready artifacts.

## Opt-in live-server probes

Start from `plex-live.env.example` where applicable and keep the resulting `*-live.env` files
gitignored. `live-test-filter.sh` is the shared output/exit-status filter used by probe wrappers.

### Plex decisions, browsing, state, and downloads

- `live-decision-probe.sh` — universal-transcode decision wire shape.
- `live-plex-browse-probe.sh` — sections, library browsing, and TV hierarchy decoding.
- `live-plex-timeline-probe.sh` — progress round trip and transcode-session stop cleanup.
- `live-playqueue-mutation-probe.sh` — ephemeral queue creation, play-next, and shuffle mutations.
- `live-download-probe.sh` — direct-original versus optimizer route decision.
- `live-download-status-probe.sh` — read-only optimizer queue/progress status.
- `live-phase6-download-candidate-probe.sh` — finds a large original/static Plex item suitable for
  the static-range transport-fault harness.
- `live-optimize-probe.sh` — optimizer discovery, creation grammar, and rendered static part.
- `live-offline-playback-decision-probe.sh` — local completed-row playback routing fixture.

### Playback and subtitle media-plane probes

- `live-segment-probe.sh` — deep-offset HLS playlist/segment behavior outside AVFoundation.
- `live-subtitle-burn-probe.sh` — image-subtitle burn request and server re-encode verdict.
- `live-subtitle-off-probe.sh` — selected-stream state and `subtitles=auto`/Off behavior; its
  opt-in mutation mode restores the original server selection.
- `live-sidecar-subtitle-probe.sh` — real SRT/VTT fetch and offline parser coverage.

### Emby

- `live-emby-probe.sh` — Emby auth/browse/playback request builders, shared progress-plan 2xx
  proof, and live response decoding. Copy `emby-live.env.example`. Timeline acceptance always
  mutates a TEST ACCOUNT resume point and requires both the explicit write opt-in and a distinct
  offset; the probe verifies the write and verifies restoration before reporting PASS.

### Jellyfin

- `live-jellyfin-browse-timeline-probe.sh` — authoritative shared browse wrappers plus all four
  shared progress events. Copy `jellyfin-live.env.example`. Timeline acceptance always mutates a
  TEST ACCOUNT resume point and requires both the explicit write opt-in and a distinct offset; the
  probe verifies the write and verifies restoration before reporting PASS.

The browse/timeline wrappers print an explicit `VERDICT: SKIP` and exit successfully when their
ignored credential file or required values are absent. A hermetic test pass containing that
verdict is readiness evidence only, never live acceptance; acceptance requires a recorded
`VERDICT: PASS` from a credentialed run.

Before adding a live probe, document every required environment key, fail or skip safely when
configuration is absent, clean up any server-side mutation, and ensure output redacts tokens,
hosts, titles, identifiers, and paths.
