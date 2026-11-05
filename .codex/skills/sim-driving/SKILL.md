---
name: sim-driving
description: Run bounded visionOS simulator evidence scenarios and know when Xcode 27 requires a human or headset gate.
---

# Driving the visionOS simulator

> **STATUS on Xcode 27: passive harness plus XCUITest element queries for visionOS.**
> Free-form synthetic clicking is not allowed: it caused misses/swallowed clicks and mouse
> takeover, and no synthetic click scenario exists for Device Hub. Official Xcode Device
> Interaction is an iOS Simulator path, not a visionOS path. XCUITest *does* work on the visionOS
> simulator (verified 2026-11-05): use the `LabstreamVisionUITests` bundle and the
> `visionos-ui-smoke` matrix lane for accessibility-identifier taps. Never use coordinates. Ask
> for human/headset confirmation for anything XCUITest and the passive probes cannot prove.

## XCUITest on visionOS

```sh
SIMID=$(scripts/worktree-sim.sh --platform visionos id)
xcrun simctl boot "$SIMID"
scripts/native-test-matrix.py full --visionos-sim-id "$SIMID" --allow-simulator \
  --run --lane visionos-ui-smoke
xcrun simctl shutdown "$SIMID"
```

- In-process screenshots are 1×1 on visionOS. Put `checkpoint("name")` in the test and run it
  through `scripts/ui-test-checkpoints.py --udid "$SIMID" --out DIR -- <xcodebuild
  test-without-building …>` so the host captures `DIR/name.png` while the test waits.
- Always pass `-collect-test-diagnostics never`; a failure otherwise stalls ~10 minutes.
- There is no visionOS player fixture. Playback start needs the opt-in live-catalog test
  (`docs/TESTING-STRATEGY.md#live-catalog-sign-in-tests`).
- XCUITest does not prove gaze hover, pinch-drag, immersive, or Cinema behavior.

If a future Device Hub-compatible click path is added, it must first re-prove the bounded loop:
screenshot/crop → locate target → synthetic click → screenshot/logs to verify. Hand off to the
user for auth setup, gaze-hover effects (a real cursor hover ≠ gaze highlight rendering in all
cases), pinch-drag gestures, or any flow where the harness cannot prove the UI changed.

## Repo scenario harness

Prefer the bounded harness over ad hoc clicks:

```sh
scripts/agent-sim-run.sh launch-fixture-home-passive --allow-simulator
```

The harness resolves the worktree simulator via `scripts/worktree-sim.sh id`, records
artifacts under `artifacts/agent-sim-runs/`, and shuts the simulator down unless
`--keep-booted` is passed. Use scenario artifacts for issue comments and debugging notes.
