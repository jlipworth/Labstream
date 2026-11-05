#!/usr/bin/env python3
"""Run bounded synthetic ownership cases; stdout contains only aggregate JSON.

Compile download-backlog-worker.swift first. Each child uses/removes its own unique
private temporary directory. No network, app data, or general fixture cleanup.
"""
import argparse
import json
import os
import shutil
import tempfile
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--worker", required=True)
    parser.add_argument("--suite", choices=("all", "files", "assets", "large-file"), default="all")
    parser.add_argument("--repetitions", type=int, choices=range(1, 4), default=1)
    args = parser.parse_args()
    cases = [("assets", n, 262144, delay, window)
             for n in (8, 128) for delay in (0, 12) for window in (0, 2)]
    cases += [("assets", 128, 1048576, 12, window) for window in (0, 2)]
    cases += [("files", n, 1048576, delay, pool)
              for n in (4, 32) for delay in (0, 12) for pool in (0, 1, 2, 3)]
    if args.suite == "large-file":
        cases = [("files", 1, 1048576, 0, pool, 128) for pool in (0, 1, 2, 3)]
    else:
        cases = [case for case in cases if args.suite == "all" or case[0] == args.suite]
    for repetition in range(args.repetitions):
        for case in (cases if repetition % 2 == 0 else list(reversed(cases))):
            with tempfile.TemporaryDirectory(prefix="download-research-owner-") as root:
                if shutil.disk_usage(root).free < 1024**3:
                    raise RuntimeError("research needs at least 1 GiB free")
                completed = subprocess.run(
                    [args.worker, *map(str, case)], check=True, capture_output=True,
                    text=True, timeout=30, env=dict(os.environ, RESEARCH_ROOT=root))
            assert not os.path.exists(root), "isolated directory was not removed"
            row = json.loads(completed.stdout)
            row["isolated_directory_removed"] = True
            row["repetition"] = repetition + 1
            if case[0] == "assets":
                bound = case[1] if case[4] == 0 else case[4]
                assert 0 < row["peak_owned_payloads"] <= bound
                assert row["peak_owned_payload_bytes"] <= bound * case[2]
            else:
                assert row["logical_append_write_bytes"] == case[1] * (case[5] if len(case) > 5 else 8) * 1024**2
            print(json.dumps(row, sort_keys=True), flush=True)


if __name__ == "__main__":
    main()
