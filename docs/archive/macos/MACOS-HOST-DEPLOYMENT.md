# macOS host deployment

> **Archived:** merged into [`docs/MACOS.md`](../../MACOS.md). Retained as the issue-era host
> deployment snapshot, not as current operating guidance.

Labstream's native Mac target runs on the host Mac. There is no macOS simulator lane in
this repository, and agents must not create fake `simctl` state for macOS.

Use:

```sh
scripts/deploy-macos-to-host.sh          # build + stage a per-worktree dev app
scripts/deploy-macos-to-host.sh --launch # also launch it
```

By default the script builds `LabstreamMac` for `platform=macOS,arch=arm64` and overrides
the local debug bundle id to a deterministic per-worktree value such as
`com.jlipworth.Labstream.dev.issue-228-macos`. It also uses that dev bundle id as the
Mac keychain service for local debug runs, so parallel worktrees do not share the same
sandbox container/keychain namespace by accident.

The Mac download background-session identifier is also derived from the effective bundle id
for local host builds, so an in-flight dev download from one worktree does not get reattached
by another worktree's Mac app. iOS/visionOS keep their existing shipped background-session
identifier for update compatibility.

Use `--use-production-bundle-id` only when intentionally testing the App Store identity
`com.jlipworth.Labstream`. Release/App Store configuration remains canonical in the Xcode
target; the dev identity is a deploy-script build override.

Safety notes:

- The staged app lives under the worktree at `build/macos-host/<identity>/Labstream.app`.
- The script never deletes `/Applications/Labstream.app`.
- `--reset-container` removes only `~/Library/Containers/<effective bundle id>`.
- Resetting the production container requires both `--use-production-bundle-id` and
  `--allow-production-container-reset`.
- macOS has no per-worktree simulator/container unless you use a distinct dev bundle id.
- Multiple worktrees using the production bundle id share LaunchServices identity, sandbox
  container, keychain behavior, and logs. Do not run them concurrently.
- Existing-platform regressions still use `scripts/worktree-sim.sh`; Mac validation is a
  host build/run.
