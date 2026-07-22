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
import shutil
import stat
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any

ROOT = pathlib.Path(__file__).resolve().parents[1]
CONTRACT = ROOT / "scripts" / "performance-audit-contract.py"
SUMMARY = ROOT / "scripts" / "perf-log-summary.py"
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

    def disk_free(self, path: pathlib.Path) -> int:
        return os.statvfs(path).f_bavail * os.statvfs(path).f_frsize

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
    """Return adjacent pairs in the exact order accepted by perf-compare."""
    result: list[dict[str, Any]] = []
    order_seed = opaque("seed", seed, length=16)
    for sample_kind, count in (("warmup", warmups), ("measured", measured)):
        for index in range(count):
            control_first = hashlib.sha256(f"{order_seed}:{sample_kind}:{index}".encode()).digest()[0] & 1 == 0
            order = ("control", "candidate") if control_first else ("candidate", "control")
            for pair_order, role in enumerate(order, 1):
                result.append({"scenario": scenario, "sample_kind": sample_kind,
                               "sample_index": index, "pair_order": pair_order, "role": role})
    return result

def opaque(prefix: str, *values: object, length: int = 12) -> str:
    digest = hashlib.sha256("\0".join(map(str, values)).encode()).hexdigest()[:length]
    return f"{prefix}-{digest}"

def bundle_sha256(app: pathlib.Path) -> str:
    digest = hashlib.sha256()
    for path in sorted(app.rglob("*")):
        if path.is_symlink():
            fail("measured app bundle must not contain symlinks")
        relative = path.relative_to(app).as_posix().encode()
        mode = path.stat(follow_symlinks=False).st_mode & 0o7777
        if path.is_dir():
            kind, size, content_digest = b"D", 0, b""
        elif path.is_file():
            kind, size = b"F", path.stat(follow_symlinks=False).st_size
            content = hashlib.sha256()
            with path.open("rb") as handle:
                for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                    content.update(chunk)
            content_digest = content.digest()
        else:
            fail("measured app bundle contains an unsupported filesystem entry")
        digest.update(kind)
        digest.update(len(relative).to_bytes(8, "big"))
        digest.update(relative)
        digest.update(mode.to_bytes(4, "big"))
        digest.update(size.to_bytes(8, "big"))
        digest.update(content_digest)
    return digest.hexdigest()

def host_facts(executor: Executor, storage_root: pathlib.Path) -> dict[str, Any]:
    os_build = executor.output(["/usr/bin/sw_vers", "-buildVersion"]).strip()
    xcode = executor.output(["/usr/bin/xcodebuild", "-version"])
    match = re.search(r"^Build version (\S+)$", xcode, re.M)
    if not match:
        fail("xcodebuild did not report an Xcode build identifier")
    power = executor.output(["/usr/bin/pmset", "-g", "batt"])
    thermal = executor.output(["/usr/bin/pmset", "-g", "therm"])
    source = "external" if "AC Power" in power else "battery" if "Battery Power" in power else "unknown"
    state = ("full" if re.search(r"\bcharged\b", power, re.I) else
             "charging" if "charging" in power.lower() else "discharging"
             if "discharging" in power.lower() else "full" if "100%" in power else "unknown")
    no_thermal_warning = "No thermal warning level has been recorded" in thermal
    no_performance_warning = "No performance warning level has been recorded" in thermal
    thermal_state = "nominal" if no_thermal_warning and no_performance_warning else "unknown"
    return {"os_build": os_build, "xcode_build": match.group(1), "power_source": source,
            "battery_state": state, "thermal_state": thermal_state,
            "free_storage_bytes": executor.disk_free(storage_root), "display_mode": "windowed"}

def launch_manifest(plan: dict[str, Any], sample: dict[str, Any], app: App,
                    facts: dict[str, Any], run_dir: pathlib.Path, recorded_at: str) -> tuple[dict[str, Any], str]:
    commits = plan["commits"]; seed = plan["seed"]
    comparison = opaque("comparison", seed, commits["control"], commits["candidate"])
    workload = opaque("workload", seed, *commits.values(), "runtime.composition")
    scenario = opaque("scenario", seed, *commits.values(), "launch")
    fixture = opaque("fixture", seed, *commits.values(), CANONICAL_INDEX_SHA256)
    run_id = opaque("run", comparison, sample["role"], sample["sample_kind"],
                    sample["sample_index"], sample["pair_order"])
    raw_pointer = {"path": "raw/artifact-0001.log", "sha256": "0" * 64}
    summary_pointer = {"path": "summary/redacted.json", "sha256": "0" * 64}
    manifest = {
        "schema_version": 1, "tool": {"name": "labstream-performance-audit", "version": "1"},
        "run": {"id": run_id, "recorded_at": recorded_at, "comparison_id": comparison,
                    "artifact_role": sample["role"], "sample_kind": sample["sample_kind"],
                "sample_index": sample["sample_index"], "order_seed": opaque("seed", seed, length=16)},
        "product": {"commit": commits[sample["role"]], "sha256": bundle_sha256(app.path),
                    "configuration": "PerformanceAudit", "target": "LabstreamMac", "platform": "macos",
                    "os_build": facts["os_build"], "xcode_build": facts["xcode_build"]},
        "device": {"label": plan["device_label"], **{key: facts[key] for key in
                   ("power_source", "battery_state", "thermal_state", "free_storage_bytes", "display_mode")}},
        "state": {"install_state": "direct_staged_artifact", "container_state": "restored_fixture",
                  "cache_reset": {"command_id": "fixture-cache-seed-v1", "result": "success"}},
        "scenario": {"id": scenario, "category": "launch", "run_kind": "deterministic_fixture",
                     "fixture_id": fixture, "fixture_sha256": CANONICAL_INDEX_SHA256,
                     "backend_kind": "none", "server_version": None, "cache_state": "declared_seed"},
        "launch_contract": {"arguments": [], "environment_keys": [], "ui_test_fixture": False,
                            "live_probe": False, "tv_event_swizzle": False, "verbose_debug_evidence": False},
        "evidence": {"artifacts": [raw_pointer], "redacted_summary": summary_pointer,
                     "privacy_review": "pending", "retention_deadline": plan["retention_deadline"],
                     "publishable": False},
    }
    return manifest, workload

def command_plan(apps: tuple[App, App], scenario: str, warmups: int, measured: int,
                 duration: int, seed: int, output: pathlib.Path, *, settle_seconds: int | None = None,
                 containers_root: pathlib.Path | None = None, control_commit: str = "0" * 40,
                 candidate_commit: str = "1" * 40, device_label: str = "local-device-01",
                 retention_deadline: str = "2099-01-01T00:00:00Z") -> dict[str, Any]:
    if (not re.fullmatch(r"[a-f0-9]{40}", control_commit) or
            not re.fullmatch(r"[a-f0-9]{40}", candidate_commit) or control_commit == candidate_commit):
        fail("control and candidate commits must be distinct exact lowercase hashes")
    if not re.fullmatch(r"local-device-[0-9]{2,3}", device_label):
        fail("device label must use local-device-NN")
    try:
        retention = datetime.fromisoformat(retention_deadline.replace("Z", "+00:00"))
    except ValueError:
        fail("retention deadline must be ISO-8601 UTC")
    if not retention_deadline.endswith("Z") or retention <= datetime.now(timezone.utc):
        fail("retention deadline must be a future ISO-8601 UTC timestamp")
    by_role = {app.role: app for app in apps}
    container = (containers_root or pathlib.Path.home() / "Library/Containers") / apps[0].bundle_id
    settle = DEFAULTS[scenario]["settle_seconds"] if settle_seconds is None else settle_seconds
    samples = schedule(scenario, warmups, measured, seed)
    for sample in samples:
        app = by_role[sample["role"]]
        sample["commands"] = {
            "reset": {"operation": "fd_anchored_clear_children",
                      "path": str(container / "Data"), "preserve_root": True},
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
        "artifact_status": ("planned_admissible_per_run_manifests" if scenario == "launch"
                            else "pre_manifest_raw_capture"),
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
        "commits": {"control": control_commit, "candidate": candidate_commit},
        "device_label": device_label,
        "retention_deadline": retention_deadline,
        "output": str(output.absolute()),
        "samples": samples,
    }

def seed_container(container: pathlib.Path, executor: Executor) -> None:
    del executor  # Seeding is intentionally descriptor-anchored rather than shell/path based.
    directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    try:
        container_fd = os.open(container, directory_flags)
    except OSError:
        fail("dedicated sandbox container is not system-managed; launch one staged audit app "
             "once to bootstrap it, terminate it, then retry")
    try:
        metadata = os.stat(".com.apple.containermanagerd.metadata.plist", dir_fd=container_fd,
                           follow_symlinks=False)
        if not stat.S_ISREG(metadata.st_mode):
            fail("dedicated sandbox container has invalid containermanagerd metadata")
        data_fd = os.open("Data", directory_flags, dir_fd=container_fd)
        try:
            data_identity = os.fstat(data_fd)
            # Preserve the system-created Data directory, including its mode and metadata. The
            # fd-relative safe rmtree implementation refuses swapped directories and never follows
            # symlinks out of this already-open sandbox.
            if not shutil.rmtree.avoids_symlink_attacks:
                fail("this Python runtime cannot safely reset a sandbox fixture")
            for name in os.listdir(data_fd):
                entry = os.stat(name, dir_fd=data_fd, follow_symlinks=False)
                if stat.S_ISDIR(entry.st_mode):
                    shutil.rmtree(name, dir_fd=data_fd)
                else:
                    os.unlink(name, dir_fd=data_fd)

            current_fd = os.dup(data_fd)
            try:
                for component in ("Library", "Application Support", "Labstream", "Downloads"):
                    try:
                        os.mkdir(component, mode=0o700, dir_fd=current_fd)
                    except FileExistsError:
                        pass
                    next_fd = os.open(component, directory_flags, dir_fd=current_fd)
                    os.close(current_fd)
                    current_fd = next_fd
                temporary = ".index.json.runner-tmp"
                try:
                    os.unlink(temporary, dir_fd=current_fd)
                except FileNotFoundError:
                    pass
                output_fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                                    0o600, dir_fd=current_fd)
                try:
                    view = memoryview(CANONICAL_INDEX)
                    while view:
                        view = view[os.write(output_fd, view):]
                    os.fsync(output_fd)
                finally:
                    os.close(output_fd)
                os.replace(temporary, "index.json", src_dir_fd=current_fd, dst_dir_fd=current_fd)
                input_fd = os.open("index.json", os.O_RDONLY | os.O_NOFOLLOW, dir_fd=current_fd)
                try:
                    seeded = b""
                    while chunk := os.read(input_fd, 4096):
                        seeded += chunk
                finally:
                    os.close(input_fd)
                if seeded != CANONICAL_INDEX:
                    fail("canonical index seed verification failed")
            finally:
                os.close(current_fd)
            after = os.fstat(data_fd)
            if (after.st_dev, after.st_ino, stat.S_IMODE(after.st_mode)) != (
                    data_identity.st_dev, data_identity.st_ino, stat.S_IMODE(data_identity.st_mode)):
                fail("sandbox Data root identity or mode changed during reset")
        finally:
            os.close(data_fd)
    except (FileNotFoundError, NotADirectoryError, OSError) as error:
        fail(f"dedicated sandbox container is incomplete or unsafe: {error}")
    finally:
        os.close(container_fd)

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
        process = trace_process = None; manifest_path = temp_dir = None
        try:
            seed_container(container, executor)
            app = by_role[sample["role"]]
            start_utc = executor.now().replace("+00:00", "Z")
            facts = host_facts(executor, container.parent) if plan["scenario"] == "launch" else None
            if facts is not None:
                manifest, workload = launch_manifest(plan, sample, app, facts, log_root, start_utc)
                final_dir = log_root / manifest["run"]["id"]
                temp_dir = pathlib.Path(tempfile.mkdtemp(prefix=".incomplete-", dir=log_root))
                run_dir = temp_dir
                raw = run_dir / "raw/artifact-0001.log"; summary = run_dir / "summary/redacted.json"
                raw.parent.mkdir(parents=True); summary.parent.mkdir()
                manifest_path = run_dir / "manifest.json"
                manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
                nonce = opaque("nonce", manifest["run"]["id"], workload, length=16)
                with raw.open("wb") as output:
                    executor.run([sys.executable, str(SUMMARY), "--emit-capture-marker", "--manifest",
                                  str(manifest_path), "--workload-id", workload, "--launch-nonce", nonce], stdout=output)
            process = executor.spawn([str(app.executable)])
            pid = int(process.pid)
            record["pid"] = pid
            immediate_status = executor.poll(process)
            if immediate_status is not None:
                fail(f"app PID {pid} exited at launch with status {immediate_status}")
            log_path = raw if facts is not None else log_root / f"sample-{ordinal:04d}.jsonl"
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
            end_utc = executor.now().replace("+00:00", "Z")
            with log_path.open("ab" if facts is not None else "wb") as output:
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
            cleanup_error = stop_and_prove_gone(process, executor); process = None
            if cleanup_error:
                fail(cleanup_error)
            if facts is not None:
                manifest["evidence"]["artifacts"][0]["sha256"] = hashlib.sha256(raw.read_bytes()).hexdigest()
                manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
                with summary.open("wb") as output:
                    executor.run([sys.executable, str(SUMMARY), "--json", "--strict", "--manifest",
                                  str(manifest_path), "--raw-artifact", str(raw), "--workload-id", workload,
                                  "--phase", "runtime.composition", "--backend", "App", "--field",
                                  "downloads_capable=1", "--correctness-field", "downloads_capable",
                                  "--expected-span-count", "1"], stdout=output)
                manifest["evidence"]["redacted_summary"]["sha256"] = hashlib.sha256(summary.read_bytes()).hexdigest()
                manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
                if bundle_sha256(app.path) != manifest["product"]["sha256"]:
                    fail("measured app bundle mutated during capture")
                executor.run([sys.executable, str(CONTRACT), "manifest", str(manifest_path)])
                os.replace(temp_dir, final_dir); temp_dir = None
                manifest_path = final_dir / "manifest.json"; log_path = final_dir / "raw/artifact-0001.log"
            record.update({"status": "success", "failure": None, "log": str(log_path),
                           "trace": str(trace_path) if plan["scenario"] == "idle" else None,
                           "start_utc": start_utc, "end_utc": end_utc})
            if manifest_path is not None:
                record["manifest"] = str(manifest_path)
        except Exception as error:  # retain every infrastructure/app failure as a record
            record.update({"status": "failure", "failure": {"type": type(error).__name__,
                                                               "message": str(error)}})
        finally:
            if trace_process is not None:
                cleanup_error = stop_and_prove_gone(trace_process, executor)
                if cleanup_error:
                    record.setdefault("cleanup_errors", []).append(cleanup_error); record["status"] = "failure"
                    record.setdefault("failure", {"type": "CleanupError", "message": cleanup_error})
            if process is not None:
                cleanup_error = stop_and_prove_gone(process, executor)
                if cleanup_error:
                    record.setdefault("cleanup_errors", []).append(cleanup_error); record["status"] = "failure"
                    record.setdefault("failure", {"type": "CleanupError", "message": cleanup_error})
            if temp_dir is not None:
                shutil.rmtree(temp_dir, ignore_errors=True)
        records.append(record)
    measured_successes = sum(r["sample_kind"] == "measured" and r["status"] == "success"
                             for r in records)
    result = dict(plan)
    result.pop("samples")
    result["records"] = records
    result["verdict"] = {"status": "insufficient_data", "reason":
                         ("admissible samples require a separate paired comparison" if plan["scenario"] == "launch"
                          else "idle remains pre-manifest until trace packaging and extraction lands"),
                         "measured_successes": measured_successes}
    result["capture_status"] = "failure" if any(r["status"] == "failure" for r in records) else "success"
    result["artifact_status"] = ("admissible_per_run_manifests" if plan["scenario"] == "launch"
                                 else "pre_manifest_raw_capture")
    return result

def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--control-app", required=True, type=pathlib.Path)
    parser.add_argument("--candidate-app", required=True, type=pathlib.Path)
    parser.add_argument("--control-commit", required=True)
    parser.add_argument("--candidate-commit", required=True)
    parser.add_argument("--device-label", required=True)
    parser.add_argument("--retention-deadline", required=True)
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
                        settle_seconds=settle, control_commit=args.control_commit,
                        candidate_commit=args.candidate_commit, device_label=args.device_label,
                        retention_deadline=args.retention_deadline)
    if args.plan:
        print(json.dumps({**plan, "mode": "plan"}, indent=2, sort_keys=True))
        return 0
    result = capture(plan, apps, executor or Executor())
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    return 1 if result["capture_status"] == "failure" else 0

if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RunnerError, OSError, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
