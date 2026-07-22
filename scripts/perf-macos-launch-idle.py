#!/usr/bin/env python3
"""Paired, container-isolated macOS PerformanceAudit launch/idle runner."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import plistlib
import re
import signal
import subprocess
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any

ROOT = pathlib.Path(__file__).resolve().parents[1]
CONTRACT = ROOT / "scripts" / "performance-audit-contract.py"
PRODUCTION_IDS = {"com.jlipworth.Labstream", "com.visionplay.app"}
BUNDLE_ID_RE = re.compile(r"^com\.jlipworth\.Labstream\.perf\.[a-z0-9][a-z0-9-]{0,47}$")
SAFE_BUNDLE_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9.-]{2,199}$")
CANONICAL_INDEX = b'{"schemaVersion":4,"rows":[]}\n'
CANONICAL_INDEX_SHA256 = hashlib.sha256(CANONICAL_INDEX).hexdigest()
INDEX_RELATIVE = pathlib.Path("Data/Library/Application Support/Labstream/Downloads/index.json")
DEFAULTS = {
    "launch": {"warmups": 3, "measured": 20, "duration_seconds": 30, "settle_seconds": 0},
    "idle": {"warmups": 1, "measured": 5, "duration_seconds": 120, "settle_seconds": 10},
}


class RunnerError(ValueError):
    pass


@dataclass(frozen=True)
class App:
    role: str
    path: pathlib.Path
    bundle_id: str
    executable: pathlib.Path


class Executor:
    """Small injectable boundary around every command, wait, and process signal."""

    def run(self, argv: list[str], *, stdout: Any = subprocess.PIPE) -> None:
        subprocess.run(argv, check=True, stdout=stdout, stderr=subprocess.STDOUT)

    def output(self, argv: list[str]) -> str:
        return subprocess.check_output(argv, text=True, stderr=subprocess.STDOUT)

    def spawn(self, argv: list[str], *, stdout: Any = subprocess.DEVNULL) -> Any:
        return subprocess.Popen(argv, stdout=stdout, stderr=subprocess.STDOUT,
                                env={}, start_new_session=True)

    def sleep(self, seconds: int) -> None:
        time.sleep(seconds)

    def terminate(self, pid: int) -> None:
        os.kill(pid, signal.SIGTERM)

    def kill(self, pid: int) -> None:
        os.kill(pid, signal.SIGKILL)

    def poll(self, process: Any) -> int | None:
        return process.poll()

    def wait(self, process: Any, timeout: int) -> int:
        return process.wait(timeout=timeout)

    def now(self) -> str:
        return datetime.now(timezone.utc).isoformat(timespec="milliseconds")


def fail(message: str) -> None:
    raise RunnerError(message)


def validate_app(role: str, raw_path: pathlib.Path) -> App:
    path = raw_path.expanduser().absolute()
    if path.suffix != ".app" or path.is_symlink() or not path.is_dir():
        fail(f"{role} must be a real, non-symlink .app directory: {path}")
    plist = path / "Contents/Info.plist"
    if (path / "Contents").is_symlink() or plist.is_symlink() or not plist.is_file():
        fail(f"{role} has no real Contents/Info.plist")
    try:
        info = plistlib.loads(plist.read_bytes())
    except (OSError, plistlib.InvalidFileException) as error:
        fail(f"{role} has an unreadable Info.plist: {error}")
    bundle_id = info.get("CFBundleIdentifier")
    executable_name = info.get("CFBundleExecutable")
    if not isinstance(bundle_id, str) or not SAFE_BUNDLE_ID_RE.fullmatch(bundle_id):
        fail(f"{role} has an invalid bundle identifier")
    if bundle_id in PRODUCTION_IDS or not BUNDLE_ID_RE.fullmatch(bundle_id):
        fail(f"{role} must use com.jlipworth.Labstream.perf.<lowercase-label>")
    if not isinstance(executable_name, str) or pathlib.PurePath(executable_name).name != executable_name:
        fail(f"{role} has an invalid CFBundleExecutable")
    executable = path / "Contents/MacOS" / executable_name
    if ((path / "Contents/MacOS").is_symlink() or executable.is_symlink()
            or not executable.is_file() or not os.access(executable, os.X_OK)):
        fail(f"{role} executable must be a real executable file")
    return App(role, path, bundle_id, executable)


def validate_pair(control_path: pathlib.Path, candidate_path: pathlib.Path) -> tuple[App, App]:
    control = validate_app("control", control_path)
    candidate = validate_app("candidate", candidate_path)
    if control.bundle_id != candidate.bundle_id:
        fail("control and candidate must use the same dedicated bundle identifier")
    containers_root = pathlib.Path.home() / "Library/Containers"
    if (containers_root.is_symlink() or not containers_root.is_dir()
            or containers_root.resolve() != containers_root.absolute()):
        fail(f"refusing non-canonical sandbox root: {containers_root}")
    container = containers_root / control.bundle_id
    if container.is_symlink():
        fail(f"refusing symlink container: {container}")
    return control, candidate


def schedule(scenario: str, warmups: int, measured: int, seed: int) -> list[dict[str, Any]]:
    """Return same-index adjacent pairs, alternating which artifact runs first."""
    first_control = bool(hashlib.sha256(str(seed).encode("ascii")).digest()[0] & 1)
    result: list[dict[str, Any]] = []
    pair_number = 0
    for sample_kind, count in (("warmup", warmups), ("measured", measured)):
        for index in range(1, count + 1):
            control_first = first_control if pair_number % 2 == 0 else not first_control
            order = ("control", "candidate") if control_first else ("candidate", "control")
            for pair_order, role in enumerate(order, 1):
                result.append({"scenario": scenario, "sample_kind": sample_kind,
                               "sample_index": index, "pair_order": pair_order, "role": role})
            pair_number += 1
    return result


def command_plan(apps: tuple[App, App], scenario: str, warmups: int, measured: int,
                 duration: int, seed: int, output: pathlib.Path, *, settle_seconds: int | None = None,
                 containers_root: pathlib.Path | None = None) -> dict[str, Any]:
    by_role = {app.role: app for app in apps}
    container = (containers_root or pathlib.Path.home() / "Library/Containers") / apps[0].bundle_id
    settle = DEFAULTS[scenario]["settle_seconds"] if settle_seconds is None else settle_seconds
    samples = schedule(scenario, warmups, measured, seed)
    for sample in samples:
        app = by_role[sample["role"]]
        sample["commands"] = {
            "reset": ["/bin/rm", "-rf", str(container)],
            "seed_directory": ["/bin/mkdir", "-p", str((container / INDEX_RELATIVE).parent)],
            "seed": {"operation": "atomic_write", "path": str(container / INDEX_RELATIVE),
                     "sha256": CANONICAL_INDEX_SHA256},
            "launch": [str(app.executable)],
            "app_arguments": [],
            "app_environment": {},
            "settle": {"seconds": settle, "health_check": "exact_pid_alive"},
            "log": ["/usr/bin/log", "show", "--style", "json", "--start", "{start_utc}",
                    "--end", "{end_utc}", "--process", "{exact_pid}"],
            "idle_trace": (["/usr/bin/xcrun", "xctrace", "record", "--template",
                            "System Trace", "--attach", "{exact_pid}", "--time-limit",
                            f"{duration}s", "--output", "{trace_path}", "--no-prompt"]
                           if scenario == "idle" else None),
            "terminate": ["SIGTERM", "{exact_pid}"],
        }
    return {
        "schema_version": 1,
        "artifact_status": "pre_manifest_raw_capture",
        "mode": "capture",
        "scenario": scenario,
        "bundle_id": apps[0].bundle_id,
        "container": str(container),
        "canonical_index": {"relative_path": INDEX_RELATIVE.as_posix(),
                            "sha256": CANONICAL_INDEX_SHA256, "bytes": len(CANONICAL_INDEX)},
        "configuration_contract_commands": [
            [sys.executable, str(CONTRACT), "binary", str(app.path)] for app in apps
        ],
        "duration_seconds": duration,
        "settle_seconds": settle,
        "warmups": warmups,
        "measured": measured,
        "seed": seed,
        "output": str(output.absolute()),
        "samples": samples,
    }


def seed_container(container: pathlib.Path, executor: Executor) -> None:
    index = container / INDEX_RELATIVE
    executor.run(["/bin/rm", "-rf", str(container)])
    executor.run(["/bin/mkdir", "-p", str(index.parent)])
    temporary = index.with_name(".index.json.runner-tmp")
    temporary.write_bytes(CANONICAL_INDEX)
    os.replace(temporary, index)
    if index.read_bytes() != CANONICAL_INDEX:
        fail("canonical index seed verification failed")


def process_app_bundle_id(command: str) -> str | None:
    """Read the enclosing .app identity for one `ps comm=` executable path."""
    path = pathlib.Path(command.strip())
    app_path: pathlib.Path | None = None
    for parent in (path, *path.parents):
        if parent.suffix == ".app":
            app_path = parent
            break
    if app_path is None:
        return None
    plist = app_path / "Contents/Info.plist"
    try:
        value = plistlib.loads(plist.read_bytes()).get("CFBundleIdentifier")
    except (OSError, plistlib.InvalidFileException):
        return None
    return value if isinstance(value, str) else None


def preflight_no_existing_app(apps: tuple[App, App], executor: Executor) -> None:
    commands = executor.output(["/bin/ps", "-axo", "comm="]).splitlines()
    executables = {str(app.executable) for app in apps}
    bundle_id = apps[0].bundle_id
    collision = any(command.strip() in executables
                    or process_app_bundle_id(command) == bundle_id for command in commands)
    if collision:
        fail("refusing capture while an app with the measured bundle identifier is already running")


def stop_and_prove_gone(process: Any, executor: Executor) -> str | None:
    pid = int(process.pid)
    try:
        executor.terminate(pid)
        try:
            executor.wait(process, 5)
        except subprocess.TimeoutExpired:
            executor.kill(pid)
            try:
                executor.wait(process, 5)
            except subprocess.TimeoutExpired:
                return f"PID {pid} exceeded both TERM and KILL cleanup deadlines"
        if executor.poll(process) is None:
            return f"PID {pid} remained alive after SIGTERM/SIGKILL cleanup"
    except (OSError, ProcessLookupError):
        if executor.poll(process) is None:
            return f"could not prove PID {pid} terminated"
    return None


def capture(plan: dict[str, Any], apps: tuple[App, App], executor: Executor) -> dict[str, Any]:
    by_role = {app.role: app for app in apps}
    preflight_no_existing_app(apps, executor)
    if plan["scenario"] == "idle":
        templates = executor.output(["/usr/bin/xcrun", "xctrace", "list", "templates"])
        if "System Trace" not in templates:
            fail("required xctrace template 'System Trace' is unavailable; no capture started")
    for command in plan["configuration_contract_commands"]:
        executor.run(command)
    container = pathlib.Path(plan["container"])
    records: list[dict[str, Any]] = []
    log_root = pathlib.Path(plan["output"]).parent / (pathlib.Path(plan["output"]).stem + "-logs")
    log_root.mkdir(parents=True, exist_ok=True)
    for ordinal, sample in enumerate(plan["samples"], 1):
        record = {key: sample[key] for key in
                  ("scenario", "sample_kind", "sample_index", "pair_order", "role")}
        process = trace_process = None
        try:
            seed_container(container, executor)
            app = by_role[sample["role"]]
            start_utc = executor.now()
            process = executor.spawn([str(app.executable)])
            pid = int(process.pid)
            record["pid"] = pid
            immediate_status = executor.poll(process)
            if immediate_status is not None:
                fail(f"app PID {pid} exited at launch with status {immediate_status}")
            log_path = log_root / f"sample-{ordinal:04d}.jsonl"
            trace_path = log_root / f"sample-{ordinal:04d}.trace"
            if plan["scenario"] == "idle":
                executor.sleep(plan["settle_seconds"])
                settled_status = executor.poll(process)
                if settled_status is not None:
                    fail(f"app PID {pid} exited while settling with status {settled_status}")
                trace_process = executor.spawn([
                    "/usr/bin/xcrun", "xctrace", "record", "--template", "System Trace",
                    "--attach", str(pid), "--time-limit", f'{plan["duration_seconds"]}s',
                    "--output", str(trace_path), "--no-prompt",
                ])
                immediate_trace_status = executor.poll(trace_process)
                if immediate_trace_status is not None:
                    fail(f"System Trace xctrace exited at launch with status {immediate_trace_status}")
            executor.sleep(plan["duration_seconds"])
            end_utc = executor.now()
            with log_path.open("wb") as output:
                executor.run(["/usr/bin/log", "show", "--style", "json", "--start", start_utc,
                              "--end", end_utc, "--process", str(pid)], stdout=output)
            returncode = executor.poll(process)
            if returncode is not None:
                fail(f"app PID {pid} exited during capture with status {returncode}")
            if trace_process is not None:
                trace_status = executor.wait(trace_process, 15)
                trace_process = None
                if trace_status != 0:
                    fail(f"System Trace xctrace failed with status {trace_status}")
                if not trace_path.exists():
                    fail("System Trace xctrace did not produce its trace")
            record.update({"status": "success", "failure": None, "log": str(log_path),
                           "trace": str(trace_path) if plan["scenario"] == "idle" else None,
                           "start_utc": start_utc, "end_utc": end_utc})
        except Exception as error:  # retain every infrastructure/app failure as a record
            record.update({"status": "failure", "failure": {"type": type(error).__name__,
                                                               "message": str(error)}})
        finally:
            if trace_process is not None:
                cleanup_error = stop_and_prove_gone(trace_process, executor)
                if cleanup_error:
                    record.update({"status": "failure", "failure": {
                        "type": "CleanupError", "message": cleanup_error}})
            if process is not None:
                cleanup_error = stop_and_prove_gone(process, executor)
                if cleanup_error:
                    record.update({"status": "failure", "failure": {
                        "type": "CleanupError", "message": cleanup_error}})
        records.append(record)
    measured_successes = sum(r["sample_kind"] == "measured" and r["status"] == "success"
                             for r in records)
    result = dict(plan)
    result.pop("samples")
    result["records"] = records
    result["verdict"] = {"status": "insufficient_data", "reason":
                         "pre-manifest raw capture cannot enter the strict comparator until "
                         "per-run manifest and covariate binding lands",
                         "measured_successes": measured_successes}
    return result


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--control-app", required=True, type=pathlib.Path)
    parser.add_argument("--candidate-app", required=True, type=pathlib.Path)
    parser.add_argument("--scenario", choices=sorted(DEFAULTS), default="launch")
    parser.add_argument("--warmups", type=int)
    parser.add_argument("--measured", type=int)
    parser.add_argument("--duration-seconds", type=int)
    parser.add_argument("--idle-settle-seconds", type=int,
                        help="bounded readiness/settle interval before idle tracing (default: 10)")
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--output", type=pathlib.Path,
                        default=pathlib.Path("mac-perf-pre-manifest-raw.json"))
    parser.add_argument("--plan", action="store_true", help="print a side-effect-free JSON plan")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None, *, executor: Executor | None = None) -> int:
    args = parse_args(argv)
    defaults = DEFAULTS[args.scenario]
    warmups = defaults["warmups"] if args.warmups is None else args.warmups
    measured = defaults["measured"] if args.measured is None else args.measured
    duration = defaults["duration_seconds"] if args.duration_seconds is None else args.duration_seconds
    if args.scenario != "idle" and args.idle_settle_seconds is not None:
        fail("--idle-settle-seconds is valid only for the idle scenario")
    settle = defaults["settle_seconds"] if args.idle_settle_seconds is None else args.idle_settle_seconds
    if warmups < 0 or measured < 1 or duration < 1 or settle < 0:
        fail("warmups and settle must be nonnegative; measured and duration must be positive")
    apps = validate_pair(args.control_app, args.candidate_app)
    plan = command_plan(apps, args.scenario, warmups, measured, duration, args.seed, args.output,
                        settle_seconds=settle)
    if args.plan:
        print(json.dumps({**plan, "mode": "plan"}, indent=2, sort_keys=True))
        return 0
    result = capture(plan, apps, executor or Executor())
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RunnerError, OSError, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
