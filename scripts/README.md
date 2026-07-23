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
- `perf-idle-compare.py` — separately compares the Mac runner's typed System Trace idle evidence.
  Its primary input is the complete runner result rather than manifest globs, so failed arms cannot
  disappear. It revalidates every successful manifest and typed archive/XML/extraction/summary chain,
  enforces the runner-declared complete seeded schedule and requires the exact long policy (one
  warmup, five measured pairs, and 120-second arms) for both the threshold pilot and verdict, plus
  chronology, identity, environment, stable external-power/thermal covariates, caller-declared
  storage/start-gap/trace-window tolerances, and reports both raw
  `cpu_running_ns`/`wakeups_count` and duration-normalized CPU ns/s and wakeups/minute. Relative
  deltas are deliberately `null` at a zero control baseline; the absolute normalized delta remains
  authoritative.

  Idle uses a two-pass protocol, not the latency comparator's ordinary control-calibration flow:

  1. Complete a successful 1+5 paired, 120-second pilot with `perf-macos-launch-idle.py`.
  2. Freeze thresholds from that complete pilot. The freeze derives its guardrail only from the five
     measured control arms, records the pilot result, manifest, control commit, and product checksums,
     and prints the threshold-artifact checksum.
  3. After recording that checksum, capture a fresh, non-overlapping 1+5 paired verdict run with the
     same control product.
  4. Compare the fresh result with the frozen artifact and its exact checksum. The comparator rejects
     a reused pilot result, comparison/order identity, run ID, or manifest, and rejects a changed
     control commit or product.

  The threshold artifact has the closed tool identity `labstream-perf-idle-thresholds` version 1,
  `sample_policy: long`, the exact capture duration, a bounded rationale, control provenance, and
  `absolute_mde` plus `relative_mde_percent` for both `cpu_running_ns_per_second` and
  `wakeups_per_minute`. Each effective threshold is the larger of the absolute floor and the frozen
  relative percentage of the fresh control median. Without that artifact, the tool still emits
  descriptive paired statistics but exits 3 with `insufficient_data`. The manifest does not bind the
  threshold checksum before verdict capture, so temporal ordering remains explicitly
  operator-attested.

  ```sh
  # First complete a distinct 1+5/120-second pilot runner result, then freeze it.
  scripts/perf-idle-compare.py freeze \
    --runner-result artifacts/performance-audit/mac-idle-pilot.json \
    --thresholds-out frozen-idle-thresholds.json
  SHA=$(shasum -a 256 frozen-idle-thresholds.json | awk '{print $1}')

  # Capture a fresh non-overlapping 1+5/120-second verdict result before comparing.
  scripts/perf-idle-compare.py \
    --runner-result artifacts/performance-audit/mac-idle-verdict.json \
    --thresholds frozen-idle-thresholds.json --thresholds-sha256 "$SHA" \
    --max-free-storage-drift-bytes 5368709120 \
    --max-pair-start-gap-seconds 300 --max-actual-window-drift-ms 1000 \
    --json-out artifacts/performance-audit/mac-idle-comparison.json \
    --csv-out artifacts/performance-audit/mac-idle-pairs.csv
  ```

  The start-gap limit must exceed the capture duration: manifest timestamps precede settle, capture,
  export, and packaging, so the latency comparator's 120-second gap is not valid for a 120-second idle
  arm. Threshold values and all tolerances are audit decisions, not defaults supplied by the tool.
- `perf-emby-browse-fixture.py` — external deterministic Emby-compatible browse/artwork fixture for
  paired performance workloads. It binds only to literal `127.0.0.1` (ephemeral port by default),
  accepts no token/password/public-bind configuration, and is outside every Xcode synchronized
  source root. Its closed routes are `System/Info/Public`, `Users/AuthenticateByName`,
  `Users/fixture-user/{Views,Items,Items/Resume,Items/Latest}`, `Shows/NextUp`, and
  `Items/<synthetic-item-id>/Images/Primary`; the corpus contains only synthetic IDs/titles and
  has a stable `fixture_id` plus SHA-256. The normal first-run Emby username/password UI can use
  the fixed public test values `benchmark-user` / `benchmark-pass-v1`; successful authentication
  returns the fixed non-secret `benchmark-access-v1` token. These are corpus constants, not secrets
  or configurable credentials. The focused contract tests for both production auth request/decoder
  shapes must pass before a UI driver may claim normal setup support. Saved-session relaunch probing
  through `GET /Users/<id>` remains outside this first fixture slice and must not be inferred.

  ```sh
  scripts/perf-emby-browse-fixture.py --ready-file /tmp/labstream-emby-fixture.json
  # The ready file contains the ephemeral loopback base URL, fixed fixture user ID, and corpus hash.
  ```

  The loopback-only control surface is intentionally narrow: `POST /__fixture__/configure` accepts
  exactly `route`, `delay_ms`, `status`, and `remaining` (`status: null` means delay-only);
  `POST /__fixture__/reset` clears faults, delays, and counters; and `GET /__fixture__/ledger`
  returns only aggregate route/status/concurrency counts. The server never retains or echoes raw
  request paths, query values, headers, bodies, or credentials. It caps active handlers, applies a
  timeout to every accepted socket, and returns a deterministic aggregate-counted 503 on overload.
  The ledger includes saturating declared/committed response-body bytes per closed route plus
  write-failure/client-disconnect counts; those counters are implemented, not deferred. This slice
  is server tooling only: it does not configure or drive the app, and it is not permission to start
  a paired capture.
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
- `tests/test_*.py` — the complete, discoverable script/tooling test inventory, including native
  matrix, publication/docs, performance contract/comparator/runner/fixture/AX/trace, diagnostics,
  compile-audit, macOS-CI, source-topology, and hardening coverage. `scripts/ci-hygiene.sh` runs the
  inventory with `python -m unittest discover -s scripts/tests -v` when `pyproject.toml` is present,
  so newly added matching test modules do not require this catalog to be hand-enumerated.

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
  opaque device label, and retention deadline. Launch capture also selects one exact
  `--launch-phase` profile: `runtime.composition`, `runtime.download_manager`,
  `runtime.download_store`, `runtime.download_transport_construct`, or
  `runtime.download_transport_submission`. The profile closes the span, selector, and correctness
  field used by every sample; it cannot drift on resume or be inferred after capture. Successful
  launch samples atomically publish a validated manifest, raw log, and strict selected-profile
  summary consumable by `perf-compare.py`. The idle path cleanly stops the exact app, privately
  exports the native System Trace TOC and `thread-state` table, creates a deterministic no-follow
  `.trace.zip`, and normalizes the native id/ref XML into the closed typed XML artifact. Native
  exports can contain paths and environment values, so they are deleted before atomic publication;
  the archived trace remains the authoritative raw evidence. Xcode 27 can take materially longer
  than the trace window to finalize a System Trace, so the runner allows a separate bounded
  120-second finalization wait.
  A timeout stops the exact app and trace processes, exports nothing, and publishes no run directory.
  Schema, build, PID, reference, state, and timing drift fail closed.
  Failures publish no run directory, remain in the complete runner result, and make the runner
  nonzero. The runner itself deliberately retains an `insufficient_data` verdict; pass that result to
  `perf-idle-compare.py` for the separate paired verdict rather than treating capture success as a
  performance conclusion.
- `perf-xctrace-idle-summary.py` — strict measurement-only normalizer for Xcode's native System
  Trace TOC and 16-column `thread-state` XML. It clips native intervals that cross the exact TOC
  boundary and sums only the in-window portion of target-process `Running` rows as
  `cpu_running_ns`; `wakeups_count` is the number of target-process `Runnable` transitions whose
  start lies inside that window and whose `made-runnable-by-thread` source is non-sentinel. It
  treats Xcode 27's typed `Terminated` state as a known non-running, non-wakeup state, while an
  unknown state or a mismatch between a state's formatted and typed values fails closed. It also
  rejects zero-length or wholly out-of-window intervals plus Xcode/table/column/type/PID/window and
  id/ref drift, then writes the closed normalized XML, typed extraction, and privacy-safe idle
  summary bound to the regular `.trace.zip`. It makes no paired performance claim.
- `perf-macos-emby-browse.py` — paired external Home, catalog, Search, and artwork runner for the same
  dedicated Mac `PerformanceAudit` artifacts. It launches the loopback-only Emby fixture, resets
  that performance identity's closed Keychain account set (including per-arm routing identity) and
  mutable sandbox data, compiles
  `perf-macos-ax-driver.swift` once before capture, and drives the exact app PID through semantic
  accessibility selectors without coordinates or app arguments/environment. Each successful arm
  waits for its exact terminal span, validates the aggregate fixture ledger, and publishes a
  contract-validated manifest plus strict summary whose automation hashes bind the fixture,
  compiled driver, and private workload spec. Begin with `--plan`. `artwork` is now an admitted
  scenario for the exact scoped `library_first_poster` milestone: the AX tree must contain one
  uniquely identified loaded poster image, the selected capture must contain exactly one successful
  scoped `artwork.load` span, and the fixture ledger must prove at least one successful image route.
  This proves only that first poster's loaded milestone and comparable scoped work; it does not prove
  a full viewport, cache warming, or all-artwork completion. Home, catalog, Search, and artwork AX
  captures require an unlocked interactive Mac session in which the audit app can become active and
  the invoking process already has Accessibility trust. A locked/background-only session or failed
  activation is an admission failure, not a performance sample.

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
