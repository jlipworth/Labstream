# Scripts

Small repo utilities for local validation, live probes, simulator/worktree hygiene, and device deployment. Scripts that need real servers read gitignored `scripts/*-live.env` files; keep tokens, server URLs, item ids, and device ids out of commits and public issue comments.

## Safe local validation

- `ci-hygiene.sh` — repo hygiene guardrails, including redaction/signing checks.
- `xcodebuild-versioned.sh` and `build-version-args.sh` — version-aware Xcode build helpers.
- `perf-log-summary.py` — summarizes local performance signposts from exported logs.
- `tests/` — script/tooling tests.

## Simulator and device helpers

- `worktree-sim.sh` — provisions one Vision Pro simulator per git worktree. Use `SIMID=$(scripts/worktree-sim.sh id)` and target `"$SIMID"`, not `booted`.
- `simclick.swift` — local simulator click helper.
- `probe-plex-range-drop.sh` — simulator-only Plex download recoverability probe. It launches the DEBUG app in the worktree simulator with the range-drop URLProtocol enabled, using the simulator's signed-in app state and no token env file. Provide `VISIONPLAY_PROBE_QUERY` or `VISIONPLAY_PROBE_RATING_KEY`; logs go under `build/probes/plex-range-drop/`.
- `deploy-to-device.sh` — signed build/install wrapper for the paired Apple Vision Pro. Mutates the device install and may replace another app with the same bundle id.
- `headset-evidence.sh` — read-only devicectl evidence collector for a paired Apple Vision Pro after a user-driven repro; writes local bundles under `build/headset-evidence/` and may contain private artifacts that must be redacted before sharing.

## Live probes

`live-*.sh` scripts run opt-in PMSKit probes against real Plex/Jellyfin/Emby servers when the matching gitignored env file is present. They are useful for request-shape and server-wire validation, but they are not substitutes for headset-only media-plane checks.

Examples:

- `live-download-probe.sh`, `live-download-status-probe.sh`, `live-optimize-probe.sh` — Plex download/optimizer checks.
- `live-emby-probe.sh`, `live-emby-download-probe.sh` — Emby auth/browse/playback/download wire checks.
- `live-segment-probe.sh`, `live-subtitle-burn-probe.sh`, `live-sidecar-subtitle-probe.sh` — playback/profile/subtitle server checks.

Before adding a new live probe, document its required env keys, make it no-op safely when env is missing, and ensure logs redact tokens, hostnames, titles, and file paths.
