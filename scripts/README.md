# Scripts

Repository utilities for validation, simulator/worktree hygiene, local host runs, device deploys,
privacy-safe evidence collection, and opt-in live-server probes. Scripts that need real servers read
gitignored environment files; keep tokens, server URLs, item IDs, device IDs, generated logs, and
media details out of commits and public issues.

## Build and validation

- `xcodebuild-versioned.sh` — wraps `xcodebuild` and stamps a source-derived internal Build ID.
- `build-version-args.sh` — prints the version/build arguments used by the wrapper and deploy scripts.
- `ci-hygiene.sh` — repository privacy, signing, placeholder, and tooling guardrails.
- `publication-audit.py` — audits tracked text, Git history, and optionally GitHub issue text for
  sensitive publication regressions without echoing matched secrets.
- `loc.sh` — informational per-module source line counts.
- `perf-log-summary.py` — converts privacy-safe performance signposts into summaries/Markdown.
- `tests/test_perf_log_summary.py` and `tests/test_tooling_hardening.py` — script/tooling tests.

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

Device deploy scripts mutate the installed app and may replace another build with the same bundle
identifier. Read their `--help` output and the platform documentation before use.

## Simulator download probes

These launch the Debug app using the selected worktree simulator's already signed-in state. They do
not read a token environment file:

- `probe-plex-range-drop.sh` — Plex static-range recoverability and injected connection-loss path.
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
- `live-optimize-probe.sh` — optimizer discovery, creation grammar, and rendered static part.
- `live-offline-playback-decision-probe.sh` — local completed-row playback routing fixture.

### Playback and subtitle media-plane probes

- `live-segment-probe.sh` — deep-offset HLS playlist/segment behavior outside AVFoundation.
- `live-subtitle-burn-probe.sh` — image-subtitle burn request and server re-encode verdict.
- `live-subtitle-off-probe.sh` — selected-stream state and `subtitles=auto`/Off behavior; its
  opt-in mutation mode restores the original server selection.
- `live-sidecar-subtitle-probe.sh` — real SRT/VTT fetch and offline parser coverage.

### Emby

- `live-emby-probe.sh` — Emby auth/browse/playback request builders and live response decoding.

Before adding a live probe, document every required environment key, fail or skip safely when
configuration is absent, clean up any server-side mutation, and ensure output redacts tokens,
hosts, titles, identifiers, and paths.
