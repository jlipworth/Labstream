#!/usr/bin/env python3
"""Run a UI test and capture the simulator display at each of its checkpoints.

    scripts/ui-test-checkpoints.py --udid <UDID> --out <dir> -- \\
        scripts/xcodebuild-versioned.sh test-without-building -xctestrun <file> \\
        -destination id=<UDID> -only-testing:<Target/Class/test> -parallel-testing-enabled NO \\
        -collect-test-diagnostics never

The test writes `<name>.ready` (see `UITestCheckpoint.swift`); this captures
`<out>/<name>.png` with `simctl io screenshot` and acknowledges the checkpoint. The command's
output goes to `<out>/test.log`, never to the terminal. The caller owns the simulator lease.
Exit status is the test command's.
"""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ui_checkpoint_driver as driver  # noqa: E402


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--udid", required=True)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--display", default=None, help="simctl io --display value")
    parser.add_argument("--timeout", type=float, default=1800)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("missing test command after --")
    out = args.out.resolve()
    checkpoints = out / "checkpoints"

    def capture(name: str) -> None:
        display = [f"--display={args.display}"] if args.display else []
        subprocess.run(["xcrun", "simctl", "io", args.udid, "screenshot", *display,
                        str(out / f"{name}.png")], check=True, capture_output=True)

    code, seen = driver.run(command, checkpoint_dir=checkpoints, on_checkpoint=capture,
                            log_path=out / "test.log",
                            env=driver.runner_environment({driver.CHECKPOINT_ENV: str(checkpoints)}),
                            timeout=args.timeout)
    print(f"exit={code} checkpoints={','.join(seen) or 'none'} out={out}")
    return code


if __name__ == "__main__":
    sys.exit(main())
