---
name: sim-driving
description: Run bounded visionOS simulator evidence scenarios and know when Xcode 27 requires a human or headset gate.
---

# Driving the visionOS simulator

> **STATUS on Xcode 27: passive harness only for visionOS.** Free-form synthetic clicking
> is not allowed: it caused misses/swallowed clicks and mouse takeover. The bounded click
> scenario also still addresses the retired standalone Simulator app and has not been proven
> against Device Hub, so do not invoke it on Xcode 27. Official Xcode Device Interaction is
> currently an iOS Simulator path, not a visionOS path. Use the passive harness and app-side
> probes for visionOS; ask for human/headset confirmation when they cannot prove the result.

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

`click-login-jellyfin-tab` is retained as legacy evidence, not as an Xcode 27-supported scenario.
