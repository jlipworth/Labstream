#!/usr/bin/env python3
"""Run one command with a wall-clock limit and capture combined output."""

import argparse
import signal
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from bounded_process import terminate_process_group
from xcode_lease import default_path, inherited


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--timeout", type=int, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if args.timeout < 1 or not command:
        parser.error("a positive --timeout and a command are required")
    def interrupted(signum, frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupted)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w") as output:
        lease_fd = inherited(default_path())
        process = subprocess.Popen(
            command,
            stdout=output,
            stderr=subprocess.STDOUT,
            start_new_session=True,
            text=True,
            pass_fds=() if lease_fd is None else (lease_fd,),
        )
        try:
            return process.wait(timeout=args.timeout)
        except subprocess.TimeoutExpired:
            output.write(f"\nrun-bounded-command: timed out after {args.timeout} seconds\n")
            output.flush()
            return 124
        except KeyboardInterrupt:
            return 130
        finally:
            terminate_process_group(process)


if __name__ == "__main__":
    sys.exit(main())
