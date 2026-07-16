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
the CI system. Set `MACOS_CI_OUTPUT_DIR` when the runner's artifact collector
requires a specific path.

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
