#!/usr/bin/env python3
"""Run the live Downloads-queue UI test on this worktree's iPhone simulator.

Drives `LabstreamMobileLiveDownloadQueueUITests` against the Jellyfin review catalog and saves a
simulator screenshot at each checkpoint. The private configuration comes from the gitignored
`scripts/app-review-live.env`; its values are redacted from the test log and never printed.

Build the UI tests and install the app first (see docs/APP-STORE-SCREENSHOTS.md), boot the
simulator, then:

    scripts/live-download-queue-check.py --allow-simulator
"""
from __future__ import annotations

import argparse
import importlib.util
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TEST = "LabstreamMobileUITests/LabstreamMobileLiveDownloadQueueUITests"


def _screenshots_module():
    spec = importlib.util.spec_from_file_location(
        "app_store_screenshots", ROOT / "scripts" / "app-store-screenshots.py")
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Run the live Downloads-queue UI test on this worktree's iPhone simulator.")
    parser.add_argument("--allow-simulator", action="store_true",
                        help="confirm this run holds the one-simulator lease")
    parser.add_argument("--output", type=Path, default=ROOT / "artifacts" / "live-download-queue",
                        help="directory for checkpoint screenshots and the private log (gitignored)")
    parser.add_argument("--xctestrun", type=Path,
                        help="default: the one under build/DerivedData-ios-iphone/Build/Products")
    args = parser.parse_args()
    if not args.allow_simulator:
        parser.error("pass --allow-simulator once you hold the simulator lease")

    sys.path.insert(0, str(ROOT / "scripts"))
    import ui_checkpoint_driver as driver
    shots = _screenshots_module()

    udid = subprocess.run(["scripts/worktree-sim.sh", "--platform", "iphone", "id"], cwd=ROOT,
                          check=True, capture_output=True, text=True).stdout.strip()
    booted = subprocess.run(["xcrun", "simctl", "list", "devices", "booted"],
                            check=True, capture_output=True, text=True).stdout
    if udid not in booted:
        print("error: this worktree's iPhone simulator is not booted", file=sys.stderr)
        return 2
    xctestrun = args.xctestrun
    if xctestrun is None:
        found = sorted((ROOT / "build/DerivedData-ios-iphone/Build/Products").glob("*.xctestrun"))
        if not found:
            print("error: no .xctestrun; build-for-testing LabstreamMobile first", file=sys.stderr)
            return 2
        xctestrun = found[-1]

    try:
        config = shots.load_live_config(shots.LIVE_CONFIG_PATH)
    except shots.ScreenshotError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    args.output.mkdir(parents=True, exist_ok=True)
    for stale in args.output.glob("*.png"):
        stale.unlink()
    checkpoints = args.output / "checkpoints"
    runner = {**config, "LABSTREAM_LIVE_CATALOG_ALLOWED": "1", driver.CHECKPOINT_ENV: str(checkpoints)}
    command = ["scripts/xcodebuild-versioned.sh", "test-without-building", "-xctestrun", str(xctestrun),
               "-destination", f"id={udid}", f"-only-testing:{TEST}",
               "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never"]

    def shoot(name: str) -> None:
        subprocess.run(["xcrun", "simctl", "io", udid, "screenshot", str(args.output / f"{name}.png")],
                       check=True, capture_output=True)

    log = args.output / "private-test.log"
    code, seen = driver.run(command, checkpoint_dir=checkpoints, on_checkpoint=shoot, log_path=log,
                            cwd=ROOT, env=driver.runner_environment(runner),
                            secrets=[config[key] for key in shots.LIVE_SECRET_KEYS], timeout=1500)
    print(f"checkpoints: {', '.join(seen) or 'none'}")
    print(f"screenshots: {args.output}")
    if code != 0:
        print(f"FAILED (exit {code}); see {log}", file=sys.stderr)
        return 1
    print("PASSED")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
