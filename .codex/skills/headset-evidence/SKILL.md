---
name: visionplay-headset-evidence
description: Gather a read-only VisionPlay evidence bundle from a paired Apple Vision Pro after the user reproduces a headset-only bug. Use before ad hoc sysdiagnose/unified-log attempts.
---

# Gather VisionPlay headset evidence

Use this after `scripts/deploy-to-device.sh --launch` and a user-driven repro on the physical Apple Vision Pro, or whenever the user asks for headset logs/evidence.

## TL;DR

```sh
scripts/headset-evidence.sh
scripts/headset-evidence.sh --device "$VP_DEVICE_ID"
scripts/headset-evidence.sh --out /tmp/visionplay-headset-evidence
```

The script is read-only. It does not install, launch, delete, or mutate the headset. It writes a local bundle under `build/headset-evidence/` by default.

## Evidence priority

1. Run `scripts/headset-evidence.sh` first.
2. Inspect `summary.json` for command failures and copied-file paths.
3. Inspect copied app-owned diagnostics and `app-container-files/Library/Application Support/VisionPlay/Downloads/index.json` before guessing from UI symptoms.
4. Use the app-container JSON listings to decide whether another bounded file should be copied manually.
5. Try host unified-log/sysdiagnose paths only opportunistically; prior headset runs found them less reliable than devicectl process/container evidence plus app-owned diagnostics.

## Privacy rules

Evidence bundles are local and may contain device IDs, media filenames, server metadata, item IDs, hostnames, tokens, and playSession IDs. Do not paste raw bundle contents into GitHub issues or public comments. Redact before sharing.

## If collection is flaky

Preserve whatever bundle exists, report the exact failed command from `summary.json`/`logs/devicectl/`, and ask the human for a fresh in-app diagnostic export or a fresh headset repro instead of spinning on sysdiagnose.

If `summary.json` reports `developer_disk_image_mount_unauthorized` (CoreDeviceError 12040 / network unauthorized), devicectl can see the headset but cannot mount the xrOS developer disk image. Check VPN/network filtering first (this has caused the failure before), then ask the human to wear/unlock/trust the headset and check Xcode Devices, then rerun the script.
