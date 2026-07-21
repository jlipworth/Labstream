#!/usr/bin/env python3
"""Plan and explicitly run Labstream's native Apple validation matrix.

Planning is the default. Execution is lane-at-a-time so this tool never silently
claims a simulator lease or boots multiple platform simulators.
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import shlex
import subprocess
import sys
from pathlib import Path
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent
DEFAULT_MANIFEST = SCRIPT_DIR / "native-test-matrix.json"
SIMULATOR_ID_FILES = {"iphone": ".simid-iphone", "tvos": ".simid-tvos"}
class MatrixError(RuntimeError):
    pass


def load_manifest(path: Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise MatrixError(f"cannot read matrix manifest {path}: {error}") from error
    validate_manifest(data)
    return data


def validate_manifest(data: dict[str, Any]) -> None:
    if data.get("version") != 1:
        raise MatrixError("matrix manifest version must be 1")
    lanes = data.get("lanes")
    tiers = data.get("tiers")
    rules = data.get("affected_rules")
    if not isinstance(lanes, dict) or not lanes:
        raise MatrixError("matrix manifest requires non-empty lanes")
    if not isinstance(tiers, dict) or set(tiers) != {"smoke", "full"}:
        raise MatrixError("matrix manifest requires exactly smoke and full tiers")
    if not isinstance(rules, list):
        raise MatrixError("matrix manifest affected_rules must be a list")

    known = set(lanes)
    for tier, names in tiers.items():
        _validate_lane_names(names, known, f"tier {tier}")
    for index, rule in enumerate(rules):
        if not isinstance(rule.get("patterns"), list) or not rule["patterns"]:
            raise MatrixError(f"affected rule {index} requires patterns")
        _validate_lane_names(rule.get("lanes"), known, f"affected rule {index}")

    for name, lane in lanes.items():
        status = lane.get("status", "ready")
        if status not in {"ready", "planned"}:
            raise MatrixError(f"lane {name} has unsupported status {status!r}")
        command = lane.get("command")
        if status == "planned":
            if command is not None or not lane.get("reason"):
                raise MatrixError(f"planned lane {name} needs a reason and no command")
        elif not isinstance(command, list) or not all(isinstance(x, str) for x in command):
            raise MatrixError(f"ready lane {name} requires a string command array")
        simulator = lane.get("simulator")
        if simulator not in {None, "iphone", "tvos"}:
            raise MatrixError(f"lane {name} has unsupported simulator {simulator!r}")


def _validate_lane_names(names: Any, known: set[str], owner: str) -> None:
    if not isinstance(names, list) or not all(isinstance(x, str) for x in names):
        raise MatrixError(f"{owner} lanes must be a string array")
    unknown = set(names) - known
    if unknown:
        raise MatrixError(f"{owner} references unknown lanes: {', '.join(sorted(unknown))}")


def affected_lanes(manifest: dict[str, Any], changed_paths: list[str]) -> list[str]:
    selected: set[str] = set()
    lane_order = list(manifest["lanes"])
    for raw_path in changed_paths:
        path = raw_path.removeprefix("./")
        for rule in manifest["affected_rules"]:
            if any(fnmatch.fnmatchcase(path, pattern) for pattern in rule["patterns"]):
                selected.update(rule["lanes"])
                if rule.get("exclusive"):
                    break
    return [name for name in lane_order if name in selected]


def changed_paths(repo: Path, base: str, head: str, include_working_tree: bool) -> list[str]:
    commands = [["git", "diff", "--name-only", "--diff-filter=ACMR", f"{base}...{head}"]]
    if include_working_tree:
        commands.extend(
            [
                ["git", "diff", "--name-only", "--diff-filter=ACMR", "HEAD"],
                ["git", "ls-files", "--others", "--exclude-standard"],
            ]
        )
    paths: set[str] = set()
    for command in commands:
        result = subprocess.run(command, cwd=repo, text=True, capture_output=True)
        if result.returncode:
            detail = result.stderr.strip() or "git command failed"
            raise MatrixError(detail)
        paths.update(line for line in result.stdout.splitlines() if line)
    return sorted(paths)


def require_worktree_simulator(platform: str, supplied_udid: str, repo: Path = REPO_ROOT) -> None:
    id_file = repo / SIMULATOR_ID_FILES[platform]
    try:
        owned_udid = id_file.read_text().strip()
    except OSError as error:
        raise MatrixError(
            f"cannot read {id_file.name}; provision this worktree's {platform} simulator "
            f"with scripts/worktree-sim.sh --platform {platform} setup"
        ) from error
    if not owned_udid:
        raise MatrixError(f"worktree simulator record is empty: {id_file.name}")
    if supplied_udid != owned_udid:
        raise MatrixError(
            f"supplied {platform} simulator is not this worktree's {id_file.name} simulator"
        )

    result = subprocess.run(
        ["xcrun", "simctl", "list", "devices", "--json"], text=True, capture_output=True
    )
    if result.returncode:
        raise MatrixError(result.stderr.strip() or "cannot inspect simulator state")
    try:
        devices = json.loads(result.stdout)["devices"]
    except (json.JSONDecodeError, KeyError, TypeError) as error:
        raise MatrixError(f"cannot decode simulator inventory: {error}") from error
    all_devices = [device for runtime in devices.values() for device in runtime]
    matches = [device for device in all_devices if device.get("udid") == supplied_udid]
    if not matches:
        raise MatrixError(f"worktree simulator is not installed: {supplied_udid}")
    if matches[0].get("state") != "Booted":
        raise MatrixError(
            f"worktree simulator {supplied_udid} is not Booted; acquire the lease and boot it "
            "explicitly first"
        )
    additional_booted = sorted(
        device.get("udid", "<unknown>")
        for device in all_devices
        if device.get("state") == "Booted" and device.get("udid") != supplied_udid
    )
    if additional_booted:
        raise MatrixError(
            "one-simulator invariant violated: shut down every simulator except this worktree's "
            f"{platform} simulator (additional booted: {', '.join(additional_booted)})"
        )


def render_lane(
    name: str,
    lane: dict[str, Any],
    *,
    output_dir: Path,
    iphone_sim_id: str | None,
    tvos_sim_id: str | None,
) -> dict[str, Any]:
    entry: dict[str, Any] = {
        "name": name,
        "kind": lane["kind"],
        "status": lane.get("status", "ready"),
    }
    if entry["status"] == "planned":
        entry["reason"] = lane["reason"]
        return entry

    values = {
        "output_dir": str(output_dir),
        "iphone_sim_id": iphone_sim_id or "<required:iphone-sim-id>",
        "tvos_sim_id": tvos_sim_id or "<required:tvos-sim-id>",
    }
    command = [part.format(**values) for part in lane["command"]]
    simulator = lane.get("simulator")
    missing = (simulator == "iphone" and not iphone_sim_id) or (simulator == "tvos" and not tvos_sim_id)
    entry.update(
        {
            "simulator": simulator,
            "executable": not missing,
            "command": command,
        }
    )
    if missing:
        entry["reason"] = (
            f"requires --{simulator}-sim-id matching this worktree's simulator and the "
            "one-simulator lease"
        )
    return entry


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("tier", choices=("smoke", "affected", "full"))
    result.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    result.add_argument("--base", default="main")
    result.add_argument("--head", default="HEAD")
    result.add_argument("--include-working-tree", action="store_true")
    result.add_argument("--changed-file", action="append", default=[])
    result.add_argument("--iphone-sim-id")
    result.add_argument("--tvos-sim-id")
    result.add_argument("--output-dir", type=Path, default=REPO_ROOT / "build" / "native-test-matrix")
    result.add_argument("--format", choices=("text", "json"), default="text")
    result.add_argument("--run", action="store_true", help="execute one explicitly selected lane")
    result.add_argument("--lane", help="lane to execute; required with --run")
    result.add_argument(
        "--allow-simulator",
        action="store_true",
        help="confirm the caller owns the one-simulator lease for a simulator-hosted lane",
    )
    return result


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        manifest = load_manifest(args.manifest)
        if args.tier == "affected":
            paths = sorted(set(args.changed_file)) if args.changed_file else changed_paths(
                REPO_ROOT, args.base, args.head, args.include_working_tree
            )
            names = affected_lanes(manifest, paths)
        else:
            paths = []
            names = list(manifest["tiers"][args.tier])
        output_dir = args.output_dir.resolve()
        entries = [
            render_lane(
                name,
                manifest["lanes"][name],
                output_dir=output_dir,
                iphone_sim_id=args.iphone_sim_id,
                tvos_sim_id=args.tvos_sim_id,
            )
            for name in names
        ]

        if args.run:
            if not args.lane:
                raise MatrixError("--run requires exactly one --lane")
            entry = next((item for item in entries if item["name"] == args.lane), None)
            if entry is None:
                raise MatrixError(f"lane {args.lane!r} is not selected by the {args.tier} tier")
            if entry["status"] != "ready":
                raise MatrixError(f"lane {args.lane} is planned, not executable: {entry['reason']}")
            if not entry["executable"]:
                raise MatrixError(f"lane {args.lane} is blocked: {entry['reason']}")
            if entry.get("simulator") and not args.allow_simulator:
                raise MatrixError("simulator lane requires --allow-simulator after acquiring the lease")
            if entry.get("simulator"):
                simulator_id = (
                    args.iphone_sim_id if entry["simulator"] == "iphone" else args.tvos_sim_id
                )
                assert simulator_id is not None
                require_worktree_simulator(entry["simulator"], simulator_id)
            output_dir.mkdir(parents=True, exist_ok=True)
            return subprocess.run(entry["command"], cwd=REPO_ROOT).returncode

        payload = {"tier": args.tier, "changed_paths": paths, "lanes": entries}
        if args.format == "json":
            print(json.dumps(payload, indent=2, sort_keys=True))
        else:
            print(f"native-test-matrix: tier={args.tier} lanes={len(entries)}")
            if paths:
                print("changed paths:")
                for path in paths:
                    print(f"  - {path}")
            for entry in entries:
                suffix = f" [{entry['kind']}]"
                if entry["status"] == "planned":
                    print(f"- {entry['name']}{suffix}: PLANNED - {entry['reason']}")
                elif entry["executable"]:
                    print(f"- {entry['name']}{suffix}: {shlex.join(entry['command'])}")
                else:
                    print(f"- {entry['name']}{suffix}: BLOCKED - {entry['reason']}")
        return 0
    except MatrixError as error:
        print(f"native-test-matrix: ERROR: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
