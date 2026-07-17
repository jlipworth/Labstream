# Native macOS CI

Labstream keeps its portable Linux Woodpecker pipelines and adds a separate
native Apple Silicon lane for Xcode-only validation. The lane is prepared in
the repository but is not operational until a physical Mac agent is enrolled.

## Rollout state and trust boundary

`.woodpecker/macos.yml` is deliberately restricted to a manual build of
`main` and requires all of these agent labels:

```yaml
platform: darwin/arm64
backend: local
purpose: mac-ci
```

The Woodpecker local backend runs repository commands directly on the host; it
is not a container security boundary. Do not add `pull_request` events. In
particular, fork code must never execute on this runner. Owner-controlled push
events may be considered only after enrollment, host isolation, cleanup, and
repository trust have been validated on the real machine.

## What the job proves

`scripts/ci-macos-apple-platforms.sh` performs:

1. a Darwin/arm64, disk-space, Xcode, visionOS SDK, and iOS SDK preflight;
2. an unsigned visionOS Simulator build of the `Labstream` scheme;
3. an unsigned iOS Simulator build of `LabstreamMobile`, the universal
   iPhone/iPad application target;
4. the PMSKit unit suite with an isolated SwiftPM scratch directory.

Each Xcode action receives its own DerivedData directory and `.xcresult`
bundle. Logs, toolchain facts, and result bundles are written beneath
`build/ci-macos/<run>/evidence`. DerivedData and SwiftPM build state are removed
through an exit/signal trap; the evidence remains for bounded collection by
the CI system. The Woodpecker workflow sets `MACOS_CI_ARTIFACT_ROOT` to the
runner-owned persistent artifact directory. Runs older than seven days are
deleted and at most ten runs are retained. These defaults can be tightened with
`MACOS_CI_RETENTION_DAYS` and `MACOS_CI_MAX_RUNS`.

This is deliberately runner-local retention, not a claim that Woodpecker has a
built-in artifact store. Off-host upload remains disabled until an existing
S3-compatible destination and scoped credentials are selected. The local
backend would also need a trusted uploader executable installed on the host;
no storage secrets belong in this repository.

The workflow never requests signing, provisioning, a developer identity,
physical devices, TestFlight, or App Store access. It also does not boot a
simulator. Simulator launch smoke, artifact upload behavior, cancellation
behavior, and cleanup must be validated after the physical runner exists.

## Runner prerequisites

The runner-provisioning repository owns:

- current stable Xcode 27 or newer and its first-launch components;
- current iOS/iPadOS and visionOS simulator SDKs/runtimes;
- Git, Swift, Xcode Command Line Tools, and at least 100 GB free space;
- the Woodpecker agent and mandatory labels;
- one-workflow concurrency and workspace retention limits.

Check a prepared host without compiling:

```bash
./scripts/ci-macos-apple-platforms.sh --preflight
```

For local diagnosis, the free-space threshold can be changed explicitly and
build state can be retained:

```bash
MACOS_CI_MIN_FREE_GB=20 \
MACOS_CI_KEEP_BUILD_DIRS=true \
./scripts/ci-macos-apple-platforms.sh
```

Those overrides are diagnostic controls and should not be set in routine CI.

## Activation checklist

Before changing the pipeline beyond manual/main-only:

- confirm the agent advertises exactly the required labels and runs as the
  non-admin CI account;
- confirm an unlabelled job cannot schedule on the Mac;
- run the preflight and this workflow from a trusted `main` revision;
- verify `.xcresult` and logs are collected and bounded;
- interrupt a build and prove the isolated work directories are removed;
- confirm no personal home, Keychain, signing, or device credentials enter the
  job environment;
- keep fork pull requests permanently excluded.

The portable hygiene workflow runs `scripts/validate-macos-pipeline.py`. It
requires all three exact labels, a manual-only event and the `main` branch. It
is a review regression check, not an agent-side event filter. Woodpecker must
continue to require approval for fork pipelines, and fork pipelines must never
be approved for execution while the native agent is eligible.
