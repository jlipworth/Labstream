---
name: deploy-mobile-to-device
description: Build and install Labstream on a physical iPhone or iPad for device testing. Use when the user asks to deploy, install, sideload, or test Labstream on real iOS/iPadOS hardware rather than a simulator.
---

# Deploy Labstream to physical iPhone or iPad

Use the repository wrapper; do not adapt simulator commands because unsigned
`Debug-iphonesimulator` products cannot install on hardware.

```sh
scripts/deploy-mobile-to-device.sh            # signed build and install
scripts/deploy-mobile-to-device.sh --launch   # install and launch
scripts/deploy-mobile-to-device.sh --no-build # reinstall this worktree's last device build
scripts/deploy-mobile-to-device.sh --verbose  # show unmasked device/team IDs
scripts/deploy-mobile-to-device.sh --full-ids # alias for --verbose
```

If several devices are paired, set `IOS_DEVICE_ID=<uuid>` (or its `MOBILE_DEVICE_ID` alias) before
running. Set the signing team with `IOS_DEVELOPMENT_TEAM=<team>` (or
`MOBILE_DEVELOPMENT_TEAM`); otherwise the wrapper derives the certificate OU. The product must be
the `LabstreamMobile` scheme's signed `Debug-iphoneos/Labstream.app`. `--full-ids` is an alias for
`--verbose`.

The wrapper builds into the worktree-local `build/DerivedData-device-ios` (`-derivedDataPath`),
wiping that directory before every build so there is no incremental link to skip. It installs only
this worktree's exact `build/DerivedData-device-ios/Build/Products/Debug-iphoneos/Labstream.app`
and never touches Xcode's global DerivedData or another worktree's product. `--no-build`
reinstalls this worktree's last device build and fails clearly if none exists.

By default, the wrapper prunes matching short-lived development profiles before a signed build;
set `IOS_REFRESH_SHORT_DEV_PROFILES=0` to opt out. It checks the embedded profile and refuses to
install a short-lived profile with fewer than six days remaining; use TestFlight/App Store for
longer-lived installs.

For first use, the user must pair and trust the device, enable Developer Mode, and sign the matching
Apple ID into Xcode Settings > Accounts. If automatic provisioning reports no account/profile,
stop and ask the user to complete that credentialed step; do not invent a team ID.

A successful install is not hardware acceptance. Ask the user to exercise device-only behavior;
the agent may collect only evidence available through the documented tooling. Never expose full
device/team identifiers in public reports, and never treat a simulator result as physical proof.
