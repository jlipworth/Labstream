#!/usr/bin/env python3
"""Paired, container-isolated macOS PerformanceAudit launch/idle runner."""
from __future__ import annotations

import argparse
import ctypes
import hashlib
import importlib.util
import json
import math
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
import zipfile
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any

ROOT = pathlib.Path(__file__).resolve().parents[1]
CONTRACT = ROOT / "scripts" / "performance-audit-contract.py"
SUMMARY = ROOT / "scripts" / "perf-log-summary.py"
IDLE_EXTRACTOR = ROOT / "scripts" / "perf-xctrace-idle-summary.py"
COMPARE = ROOT / "scripts" / "perf-compare.py"
IDLE_XCTRACE_XPATH = '//trace-toc[1]/run[1]/data[1]/table[@schema="thread-state"]'
PRODUCTION_IDS = {"org.labstream.Labstream"}
BUNDLE_ID_RE = re.compile(r"^org\.labstream\.Labstream\.perf\.[a-z0-9][a-z0-9-]{0,47}$")
SAFE_BUNDLE_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9.-]{2,199}$")
CANONICAL_INDEX = b'{"schemaVersion":4,"rows":[]}\n'
CANONICAL_INDEX_SHA256 = hashlib.sha256(CANONICAL_INDEX).hexdigest()
INDEX_RELATIVE = pathlib.Path("Data/Library/Application Support/Labstream/Downloads/index.json")
DEFAULTS = {
    "launch": {"warmups": 3, "measured": 20, "duration_seconds": 30, "settle_seconds": 0},
    "idle": {"warmups": 1, "measured": 5, "duration_seconds": 120, "settle_seconds": 10},
}
LAUNCH_PHASE_PROFILES = {
    "runtime.composition": {
        "field": "downloads_capable=1",
        "correctness_field": "downloads_capable",
    },
    "runtime.download_manager": {
        "field": "background_events=1",
        "correctness_field": "background_events",
    },
    "runtime.download_store": {
        "field": "default_store=1",
        "correctness_field": "default_store",
    },
    "runtime.download_transport_construct": {
        "field": "background_session=1",
        "correctness_field": "background_session",
    },
    "runtime.download_transport_submission": {
        "field": "startup_submission=1",
        "correctness_field": "startup_submission",
    },
}
IDLE_FAILURE_DETAIL_MAX_BYTES = 2 * 1024
IDLE_TRACE_FINALIZATION_TIMEOUT_SECONDS = 120
IDLE_TOOL_ERROR_PREFIXES = {
    str(IDLE_EXTRACTOR): "error: ",
    str(CONTRACT): "performance-audit-contract: FAIL: ",
}

def _load_compare() -> Any:
    spec = importlib.util.spec_from_file_location("perf_compare_for_launch", COMPARE)
    if spec is None or spec.loader is None:
        raise RuntimeError("could not load performance comparator")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module

compare = _load_compare()

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


def _redact_idle_tool_error(text: str) -> str:
    text = re.sub(r"(?i)\b(?:https?|file)://\S+", "<url>", text)
    text = re.sub(
        r"(?i)\b(password|passwd|token|api[_-]?key|authorization)\s*[:=]\s*\S+",
        lambda match: f"{match.group(1)}=<redacted>", text,
    )
    text = re.sub(r"(?i)\bbearer\s+\S+", "Bearer <redacted>", text)
    text = re.sub(r"(?<![A-Za-z0-9.])/(?:[^\s'\"<>]|\\ )+", "<path>", text)
    text = "".join(character if character.isprintable() else " " for character in text)
    return " ".join(text.split())


def idle_failure_record(error: Exception) -> dict[str, str]:
    """Expose only bounded closed-tool diagnostics for idle extractor/contract failures."""
    if not isinstance(error, subprocess.CalledProcessError):
        return {"type": type(error).__name__, "message": str(error)}
    command = error.cmd if isinstance(error.cmd, (list, tuple)) else []
    tool = next((path for path in IDLE_TOOL_ERROR_PREFIXES if path in command), None)
    if tool is None:
        return {"type": type(error).__name__, "message": str(error)}
    label = "idle extractor" if tool == str(IDLE_EXTRACTOR) else "performance audit contract"
    message = f"{label} failed with exit status {error.returncode}"
    chunks = [value for value in (error.stdout, error.stderr) if value not in (None, b"", "")]
    details: list[str] = []
    for chunk in chunks:
        if isinstance(chunk, bytes):
            try:
                decoded = chunk.decode("utf-8", errors="strict")
            except UnicodeDecodeError:
                continue
        elif isinstance(chunk, str):
            decoded = chunk
        else:
            continue
        prefix = IDLE_TOOL_ERROR_PREFIXES[tool]
        details.extend(_redact_idle_tool_error(line) for line in decoded.splitlines()
                       if line.startswith(prefix))
    detail = " | ".join(value for value in details if value)
    if detail:
        remaining = max(0, IDLE_FAILURE_DETAIL_MAX_BYTES - len((message + ": ").encode("utf-8")))
        encoded = detail.encode("utf-8")[:remaining]
        detail = encoded.decode("utf-8", errors="ignore").rstrip()
        if detail:
            message += f": {detail}"
    return {"type": type(error).__name__, "message": message}


def launch_profile(plan: dict[str, Any]) -> dict[str, str]:
    """Return and validate the exact closed launch span selected by this plan."""
    profile = plan.get("launch_profile")
    if not isinstance(profile, dict):
        fail("launch plan is missing its exact attribution profile")
    phase = profile.get("phase")
    expected = ({"phase": phase, **LAUNCH_PHASE_PROFILES[phase]}
                if isinstance(phase, str) and phase in LAUNCH_PHASE_PROFILES else None)
    if profile != expected:
        fail("launch profile is not one exact closed attribution profile")
    return profile


def launch_summary_arguments(plan: dict[str, Any]) -> list[str]:
    profile = launch_profile(plan)
    return [
        "--phase", profile["phase"], "--backend", "App",
        "--field", profile["field"],
        "--correctness-field", profile["correctness_field"],
        "--expected-span-count", "1",
    ]


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
        fail(f"{role} must use org.labstream.Labstream.perf.<lowercase-label>")
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

def log_time_bound(iso_timestamp: str, *, end: bool = False) -> str:
    """Translate an exact UTC timestamp to log(1)'s supported epoch-second syntax."""
    value = datetime.fromisoformat(iso_timestamp.replace("Z", "+00:00")).timestamp()
    return f"@{math.ceil(value) if end else math.floor(value)}"

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
    commits = plan["commits"]
    seed = plan["seed"]
    identities = plan.get("identities", {})
    launch_phase = launch_profile(plan)["phase"]
    comparison = identities.get(
        "comparison_id", opaque("comparison", seed, commits["control"], commits["candidate"]))
    workload = identities.get(
        "workload_id", opaque("workload", seed, *commits.values(), launch_phase))
    scenario = identities.get(
        "scenario_id", opaque("scenario", seed, *commits.values(), "launch"))
    fixture = identities.get(
        "fixture_id", opaque("fixture", seed, *commits.values(), CANONICAL_INDEX_SHA256))
    run_id = opaque("run", comparison, sample["role"], sample["sample_kind"],
                    sample["sample_index"], sample["pair_order"])
    raw_pointer = {"path": "raw/artifact-0001.log", "sha256": "0" * 64}
    summary_pointer = {"path": "summary/redacted.json", "sha256": "0" * 64}
    manifest = {
        "schema_version": 1, "tool": {"name": "labstream-performance-audit", "version": "1"},
        "run": {"id": run_id, "recorded_at": recorded_at, "comparison_id": comparison,
                    "artifact_role": sample["role"], "sample_kind": sample["sample_kind"],
                "sample_index": sample["sample_index"],
                "order_seed": identities.get("order_seed", opaque("seed", seed, length=16))},
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


def idle_manifest(plan: dict[str, Any], sample: dict[str, Any], app: App,
                  facts: dict[str, Any], recorded_at: str) -> dict[str, Any]:
    commits = plan["commits"]
    identities = plan.get("identities", {})
    comparison = identities.get(
        "comparison_id", opaque("comparison", plan["seed"], *commits.values()))
    scenario = identities.get(
        "scenario_id", opaque("scenario", plan["seed"], *commits.values(), "idle"))
    fixture = identities.get(
        "fixture_id", opaque("fixture", plan["seed"], *commits.values(), CANONICAL_INDEX_SHA256))
    run_id = idle_run_id(plan, sample)
    return {
        "schema_version": 1, "tool": {"name": "labstream-performance-audit", "version": "1"},
        "run": {"id": run_id, "recorded_at": recorded_at, "comparison_id": comparison,
                "artifact_role": sample["role"], "sample_kind": sample["sample_kind"],
                "sample_index": sample["sample_index"],
                "order_seed": identities.get("order_seed", opaque("seed", plan["seed"], length=16))},
        "product": {"commit": commits[sample["role"]], "sha256": bundle_sha256(app.path),
                    "configuration": "PerformanceAudit", "target": "LabstreamMac", "platform": "macos",
                    "os_build": facts["os_build"], "xcode_build": facts["xcode_build"]},
        "device": {"label": plan["device_label"], **{key: facts[key] for key in
                   ("power_source", "battery_state", "thermal_state", "free_storage_bytes", "display_mode")}},
        "state": {"install_state": "direct_staged_artifact", "container_state": "restored_fixture",
                  "cache_reset": {"command_id": "fixture-cache-seed-v1", "result": "success"}},
        "scenario": {"id": scenario, "category": "idle", "run_kind": "deterministic_fixture",
                     "fixture_id": fixture, "fixture_sha256": CANONICAL_INDEX_SHA256,
                     "backend_kind": "none", "server_version": None, "cache_state": "declared_seed"},
        "launch_contract": {"arguments": [], "environment_keys": [], "ui_test_fixture": False,
                            "live_probe": False, "tv_event_swizzle": False,
                            "verbose_debug_evidence": False},
        "evidence": {
            "artifacts": [
                {"path": "raw/artifact-0001.trace.zip", "sha256": "0" * 64},
                {"path": "raw/artifact-0002.xml", "sha256": "0" * 64},
                {"path": "raw/artifact-0003.json", "sha256": "0" * 64},
            ],
            "redacted_summary": {"path": "summary/redacted.json", "sha256": "0" * 64},
            "privacy_review": "pending", "retention_deadline": plan["retention_deadline"],
            "publishable": False,
        },
    }


def idle_run_id(plan: dict[str, Any], sample: dict[str, Any]) -> str:
    comparison = plan.get("identities", {}).get(
        "comparison_id", opaque("comparison", plan["seed"], *plan["commits"].values()))
    return opaque("run", comparison, "idle", sample["role"], sample["sample_kind"],
                  sample["sample_index"], sample["pair_order"])


def _zip_info(name: str, mode: int, *, directory: bool) -> zipfile.ZipInfo:
    info = zipfile.ZipInfo(name + ("/" if directory and not name.endswith("/") else ""),
                           date_time=(1980, 1, 1, 0, 0, 0))
    info.create_system = 3
    info.compress_type = zipfile.ZIP_DEFLATED
    info.external_attr = mode << 16
    return info


def archive_trace_directory(trace: pathlib.Path, output: pathlib.Path) -> None:
    """Write one deterministic, no-follow ZIP containing exactly this trace bundle."""
    if trace.is_symlink() or not trace.is_dir() or not trace.name.endswith(".trace"):
        fail("System Trace output must be one real .trace directory")
    if output.exists() or output.is_symlink():
        fail("idle trace archive output collision")
    entries: list[tuple[pathlib.Path, pathlib.PurePosixPath, os.stat_result]] = []
    root_parent = trace.parent
    for current, names, files in os.walk(trace, topdown=True, followlinks=False):
        directory = pathlib.Path(current)
        names.sort()
        files.sort()
        for name in names:
            metadata = (directory / name).lstat()
            if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
                fail("System Trace output contains a symlink or special file")
        for child in [directory, *(directory / name for name in files)]:
            metadata = child.lstat()
            relative = pathlib.PurePosixPath(child.relative_to(root_parent).as_posix())
            if (not relative.parts or any(part in {"", ".", ".."} or "\\" in part
                                          or any(ord(character) < 32 for character in part)
                                          for part in relative.parts)):
                fail("System Trace output contains an unsafe archive name")
            if stat.S_ISLNK(metadata.st_mode) or not (
                    stat.S_ISDIR(metadata.st_mode) or stat.S_ISREG(metadata.st_mode)):
                fail("System Trace output contains a symlink or special file")
            entries.append((child, relative, metadata))
    entries.sort(key=lambda entry: entry[1].as_posix())
    if not any(stat.S_ISREG(metadata.st_mode) for _, _, metadata in entries):
        fail("System Trace output contains no regular trace payload")
    output.parent.mkdir(parents=True, exist_ok=True)
    try:
        with zipfile.ZipFile(output, "x", compression=zipfile.ZIP_DEFLATED,
                             compresslevel=9, strict_timestamps=True) as archive:
            for path, relative, metadata in entries:
                if stat.S_ISDIR(metadata.st_mode):
                    archive.writestr(_zip_info(relative.as_posix(), stat.S_IFDIR | 0o700,
                                               directory=True), b"")
                    continue
                info = _zip_info(relative.as_posix(), stat.S_IFREG | 0o600, directory=False)
                descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
                try:
                    opened = os.fstat(descriptor)
                    if ((opened.st_dev, opened.st_ino, opened.st_size)
                            != (metadata.st_dev, metadata.st_ino, metadata.st_size)
                            or not stat.S_ISREG(opened.st_mode)):
                        fail("System Trace output changed during archive creation")
                    with archive.open(info, "w", force_zip64=True) as destination:
                        while chunk := os.read(descriptor, 1024 * 1024):
                            destination.write(chunk)
                    after = os.fstat(descriptor)
                    if (after.st_size, after.st_mtime_ns) != (opened.st_size, opened.st_mtime_ns):
                        fail("System Trace output changed during archive creation")
                finally:
                    os.close(descriptor)
        archive_fd = os.open(output, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            os.fsync(archive_fd)
        finally:
            os.close(archive_fd)
    except Exception:
        output.unlink(missing_ok=True)
        raise

def command_plan(apps: tuple[App, App], scenario: str, warmups: int, measured: int,
                 duration: int, seed: int, output: pathlib.Path, *, settle_seconds: int | None = None,
                 containers_root: pathlib.Path | None = None, control_commit: str = "0" * 40,
                 candidate_commit: str = "1" * 40, device_label: str = "local-device-01",
                 retention_deadline: str = "2099-01-01T00:00:00Z",
                 cooldown_seconds: float = 0, launch_phase: str | None = None) -> dict[str, Any]:
    if scenario == "idle" and launch_phase is not None:
        fail("launch phase selection is not valid for the idle scenario")
    selected_launch_phase = "runtime.composition" if launch_phase is None else launch_phase
    if scenario == "launch" and selected_launch_phase not in LAUNCH_PHASE_PROFILES:
        fail("launch phase is not a supported closed attribution profile")
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
            "log": ["/usr/bin/log", "show", "--info", "--style", "ndjson", "--start", "{start_epoch_floor}",
                    "--end", "{end_epoch_ceil}", "--process", "{exact_pid}"],
            "idle_trace": (["/usr/bin/xcrun", "xctrace", "record", "--template",
                            "System Trace", "--attach", "{exact_pid}", "--time-limit",
                            f"{duration}s", "--output", "{trace_path}", "--no-prompt"]
                           if scenario == "idle" else None),
            "idle_export_toc": (["/usr/bin/xcrun", "xctrace", "export", "--input",
                                  "{trace_path}", "--toc", "--output", "{private_toc_path}"]
                                 if scenario == "idle" else None),
            "idle_export_thread_state": (["/usr/bin/xcrun", "xctrace", "export", "--input",
                                           "{trace_path}", "--xpath", IDLE_XCTRACE_XPATH,
                                           "--output", "{private_thread_state_path}"]
                                          if scenario == "idle" else None),
            "idle_archive": ({"operation": "deterministic_safe_trace_zip",
                              "input": "{trace_path}", "output": "{trace_archive_path}"}
                             if scenario == "idle" else None),
            "idle_extract": ([sys.executable, str(IDLE_EXTRACTOR), "--toc-xml",
                              "{private_toc_path}", "--thread-state-xml",
                              "{private_thread_state_path}", "--normalized-xml-out", "{xml_path}",
                              "--trace-archive", "{trace_archive_path}", "--expected-pid",
                              "{exact_pid}"] if scenario == "idle" else None),
            "terminate": ["SIGTERM", "{exact_pid}"],
        }
    identity_suffix = (() if selected_launch_phase == "runtime.composition"
                       else (selected_launch_phase,))
    identities = {
        "comparison_id": opaque("comparison", seed, control_commit, candidate_commit,
                                *identity_suffix),
        "workload_id": opaque("workload", seed, control_commit, candidate_commit,
                              selected_launch_phase if scenario == "launch" else "idle.metrics"),
        "scenario_id": opaque("scenario", seed, control_commit, candidate_commit, scenario,
                              *identity_suffix),
        "fixture_id": opaque("fixture", seed, control_commit, candidate_commit,
                             CANONICAL_INDEX_SHA256),
        "order_seed": opaque("seed", seed, length=16),
    }
    result = {
        "schema_version": 1,
        "artifact_status": ("planned_admissible_per_run_manifests" if scenario == "launch"
                            else "planned_typed_idle_per_run_manifests"),
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
        "cooldown_seconds": cooldown_seconds,
        "warmups": warmups,
        "measured": measured,
        "seed": seed,
        "commits": {"control": control_commit, "candidate": candidate_commit},
        "device_label": device_label,
        "retention_deadline": retention_deadline,
        "identities": identities,
        "output": str(output.absolute()),
        "samples": samples,
    }
    if scenario == "launch":
        result["launch_profile"] = {
            "phase": selected_launch_phase,
            **LAUNCH_PHASE_PROFILES[selected_launch_phase],
        }
    return result

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


def cleanup_idle_handles(process: Any | None, trace_process: Any | None,
                         executor: Executor) -> list[str]:
    """Attempt both cleanups independently; callers retain handles until this returns clean."""
    errors: list[str] = []
    for label, handle in (("app", process), ("trace", trace_process)):
        if handle is None:
            continue
        try:
            cleanup = (None if executor.poll(handle) is not None
                       else stop_and_prove_gone(handle, executor))
            if cleanup:
                errors.append(f"{label}: {cleanup}")
        except Exception as error:
            errors.append(f"{label}: {type(error).__name__}: {error}")
    return errors


def capture_idle_sample(plan: dict[str, Any], sample: dict[str, Any], app: App,
                        run_dir: pathlib.Path, executor: Executor) -> dict[str, Any]:
    record = {key: sample[key] for key in
              ("scenario", "sample_kind", "sample_index", "pair_order", "role")}
    raw_dir = run_dir / "raw"
    summary_dir = run_dir / "summary"
    raw_dir.mkdir()
    summary_dir.mkdir()
    trace_path = run_dir / "artifact.trace"
    archive_path = raw_dir / "artifact-0001.trace.zip"
    xml_path = raw_dir / "artifact-0002.xml"
    extraction_path = raw_dir / "artifact-0003.json"
    summary_path = summary_dir / "redacted.json"
    manifest_path = run_dir / "manifest.json"
    private_log = run_dir / ".capture-log.jsonl"
    private_toc = run_dir / ".xctrace-toc.xml"
    private_thread_state = run_dir / ".xctrace-thread-state.xml"
    process = trace_process = None
    try:
        seed_container(pathlib.Path(plan["container"]), executor)
        facts = host_facts(executor, pathlib.Path(plan["container"]).parent)
        start_utc = executor.now().replace("+00:00", "Z")
        manifest = idle_manifest(plan, sample, app, facts, start_utc)
        process = executor.spawn([str(app.executable)])
        pid = int(process.pid)
        record["pid"] = pid
        if executor.poll(process) is not None:
            fail(f"app PID {pid} exited at launch")
        executor.sleep(plan["settle_seconds"])
        if executor.poll(process) is not None:
            fail(f"app PID {pid} exited while settling")
        trace_process = executor.spawn([
            "/usr/bin/xcrun", "xctrace", "record", "--template", "System Trace",
            "--attach", str(pid), "--time-limit", f'{plan["duration_seconds"]}s',
            "--output", str(trace_path), "--no-prompt",
        ])
        if executor.poll(trace_process) is not None:
            fail("System Trace xctrace exited at launch")
        executor.sleep(plan["duration_seconds"])
        end_utc = executor.now().replace("+00:00", "Z")
        with private_log.open("wb") as output:
            executor.run(["/usr/bin/log", "show", "--info", "--style", "ndjson", "--start",
                          log_time_bound(start_utc), "--end", log_time_bound(end_utc, end=True),
                          "--process", str(pid)], stdout=output)
        if executor.poll(process) is not None:
            fail(f"app PID {pid} exited during capture")
        try:
            trace_status = executor.wait(
                trace_process, IDLE_TRACE_FINALIZATION_TIMEOUT_SECONDS)
        except subprocess.TimeoutExpired:
            fail(
                "System Trace xctrace did not finalize within "
                f"{IDLE_TRACE_FINALIZATION_TIMEOUT_SECONDS} seconds")
        if trace_status != 0:
            fail(f"System Trace xctrace failed with status {trace_status}")
        if trace_path.is_symlink() or not trace_path.is_dir():
            fail("System Trace xctrace did not produce one real trace directory")
        cleanup_errors = cleanup_idle_handles(process, trace_process, executor)
        if cleanup_errors:
            fail("idle process cleanup failed: " + "; ".join(cleanup_errors))
        process = trace_process = None

        executor.run([
            "/usr/bin/xcrun", "xctrace", "export", "--input", str(trace_path),
            "--toc", "--output", str(private_toc),
        ])
        executor.run([
            "/usr/bin/xcrun", "xctrace", "export", "--input", str(trace_path),
            "--xpath", IDLE_XCTRACE_XPATH, "--output", str(private_thread_state),
        ])
        if (private_toc.is_symlink() or not private_toc.is_file()
                or private_thread_state.is_symlink() or not private_thread_state.is_file()):
            fail("xctrace did not produce the private native idle XML inputs")
        archive_trace_directory(trace_path, archive_path)
        shutil.rmtree(trace_path)
        private_log.unlink(missing_ok=True)

        extractor = [
            sys.executable, str(IDLE_EXTRACTOR), "--toc-xml", str(private_toc),
            "--thread-state-xml", str(private_thread_state),
            "--normalized-xml-out", str(xml_path),
            "--trace-archive", str(archive_path), "--run-dir", str(run_dir),
            "--extraction-out", str(extraction_path), "--summary-out", str(summary_path),
            "--xcode-build", facts["xcode_build"], "--expected-pid", str(pid),
            "--duration-seconds", str(plan["duration_seconds"]), "--window-tolerance-ms", "1000",
            "--run-id", manifest["run"]["id"], "--comparison-id", manifest["run"]["comparison_id"],
            "--artifact-role", sample["role"], "--sample-kind", sample["sample_kind"],
            "--sample-index", str(sample["sample_index"]),
            "--scenario-id", manifest["scenario"]["id"],
        ]
        executor.run(extractor)
        private_toc.unlink()
        private_thread_state.unlink()
        for pointer, path in zip(manifest["evidence"]["artifacts"],
                                 (archive_path, xml_path, extraction_path), strict=True):
            pointer["sha256"] = hashlib.sha256(read_regular_bytes(path)).hexdigest()
        manifest["evidence"]["redacted_summary"]["sha256"] = hashlib.sha256(
            read_regular_bytes(summary_path)).hexdigest()
        manifest_path.write_bytes(_json_bytes(manifest))
        if bundle_sha256(app.path) != manifest["product"]["sha256"]:
            fail("measured app bundle mutated during idle capture")
        executor.run([sys.executable, str(CONTRACT), "manifest", str(manifest_path)])
        record.update(status="success", failure=None, manifest=str(manifest_path),
                      manifest_sha256=hashlib.sha256(manifest_path.read_bytes()).hexdigest(),
                      trace=str(archive_path), start_utc=start_utc, end_utc=end_utc)
        return record
    finally:
        private_log.unlink(missing_ok=True)
        private_toc.unlink(missing_ok=True)
        private_thread_state.unlink(missing_ok=True)
        cleanup_errors = cleanup_idle_handles(process, trace_process, executor)
        if cleanup_errors:
            fail("idle process cleanup retry failed: " + "; ".join(cleanup_errors))


def capture_idle(plan: dict[str, Any], apps: tuple[App, App], executor: Executor) -> dict[str, Any]:
    by_role = {app.role: app for app in apps}
    preflight_no_existing_app(apps, executor)
    templates = executor.output(["/usr/bin/xcrun", "xctrace", "list", "templates"])
    if "System Trace" not in templates:
        fail("required xctrace template 'System Trace' is unavailable; no capture started")
    for command in plan["configuration_contract_commands"]:
        executor.run(command)
    log_root = pathlib.Path(plan["output"]).parent / (pathlib.Path(plan["output"]).stem + "-logs")
    if log_root.is_symlink() or (log_root.exists() and not log_root.is_dir()):
        fail("idle evidence root is unsafe")
    log_root.mkdir(parents=True, exist_ok=True)
    records: list[dict[str, Any]] = []
    for sample in plan["samples"]:
        record = {key: sample[key] for key in
                  ("scenario", "sample_kind", "sample_index", "pair_order", "role")}
        final_dir = log_root / idle_run_id(plan, sample)
        pending: pathlib.Path | None = None
        try:
            if final_dir.exists() or final_dir.is_symlink():
                fail(f"idle evidence destination already exists: {final_dir}")
            pending = pathlib.Path(tempfile.mkdtemp(prefix=".incomplete-idle-", dir=log_root))
            record = capture_idle_sample(
                plan, sample, by_role[sample["role"]], pending, executor)
            publish_evidence_directory(pending, final_dir)
            pending = None
            record["manifest"] = str(final_dir / "manifest.json")
            record["manifest_sha256"] = hashlib.sha256(
                read_regular_bytes(final_dir / "manifest.json")).hexdigest()
            record["trace"] = str(final_dir / "raw/artifact-0001.trace.zip")
        except Exception as error:
            record.update(status="failure", failure=idle_failure_record(error))
        finally:
            if pending is not None:
                discard_private_directory(pending)
        records.append(record)
    measured_successes = sum(record["sample_kind"] == "measured" and record["status"] == "success"
                             for record in records)
    result = dict(plan)
    result.pop("samples")
    result.update(
        records=records,
        verdict={"status": "insufficient_data",
                 "reason": "paired idle metric comparison support has not landed",
                 "measured_successes": measured_successes},
        capture_status=("failure" if any(record["status"] == "failure" for record in records)
                        else "success"),
        artifact_status="typed_idle_per_run_manifests",
    )
    return result

def capture(plan: dict[str, Any], apps: tuple[App, App], executor: Executor) -> dict[str, Any]:
    if plan["scenario"] == "idle":
        return capture_idle(plan, apps, executor)
    by_role = {app.role: app for app in apps}
    preflight_no_existing_app(apps, executor)
    for command in plan["configuration_contract_commands"]:
        executor.run(command)
    container = pathlib.Path(plan["container"])
    records: list[dict[str, Any]] = []
    log_root = pathlib.Path(plan["output"]).parent / (pathlib.Path(plan["output"]).stem + "-logs")
    log_root.mkdir(parents=True, exist_ok=True)
    for sample in plan["samples"]:
        record = {key: sample[key] for key in
                  ("scenario", "sample_kind", "sample_index", "pair_order", "role")}
        process = None
        manifest_path = temp_dir = None
        try:
            seed_container(container, executor)
            app = by_role[sample["role"]]
            start_utc = executor.now().replace("+00:00", "Z")
            facts = host_facts(executor, container.parent)
            manifest, workload = launch_manifest(plan, sample, app, facts, log_root, start_utc)
            final_dir = log_root / manifest["run"]["id"]
            temp_dir = pathlib.Path(tempfile.mkdtemp(prefix=".incomplete-", dir=log_root))
            run_dir = temp_dir
            raw = run_dir / "raw/artifact-0001.log"
            summary = run_dir / "summary/redacted.json"
            raw.parent.mkdir(parents=True)
            summary.parent.mkdir()
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
            executor.sleep(plan["duration_seconds"])
            end_utc = executor.now().replace("+00:00", "Z")
            with raw.open("ab") as output:
                executor.run(["/usr/bin/log", "show", "--info", "--style", "ndjson", "--start",
                              log_time_bound(start_utc), "--end", log_time_bound(end_utc, end=True),
                              "--process", str(pid)], stdout=output)
            returncode = executor.poll(process)
            if returncode is not None:
                fail(f"app PID {pid} exited during capture with status {returncode}")
            cleanup_error = stop_and_prove_gone(process, executor)
            process = None
            if cleanup_error:
                fail(cleanup_error)
            manifest["evidence"]["artifacts"][0]["sha256"] = hashlib.sha256(raw.read_bytes()).hexdigest()
            manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
            with summary.open("wb") as output:
                executor.run([sys.executable, str(SUMMARY), "--json", "--strict", "--manifest",
                              str(manifest_path), "--raw-artifact", str(raw), "--workload-id", workload,
                              *launch_summary_arguments(plan)], stdout=output)
            manifest["evidence"]["redacted_summary"]["sha256"] = hashlib.sha256(summary.read_bytes()).hexdigest()
            manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
            if bundle_sha256(app.path) != manifest["product"]["sha256"]:
                fail("measured app bundle mutated during capture")
            executor.run([sys.executable, str(CONTRACT), "manifest", str(manifest_path)])
            os.replace(temp_dir, final_dir)
            temp_dir = None
            manifest_path = final_dir / "manifest.json"
            log_path = final_dir / "raw/artifact-0001.log"
            record.update({"status": "success", "failure": None, "log": str(log_path), "trace": None,
                           "start_utc": start_utc, "end_utc": end_utc})
            if manifest_path is not None:
                record["manifest"] = str(manifest_path)
        except Exception as error:  # retain every infrastructure/app failure as a record
            record.update({"status": "failure", "failure": {"type": type(error).__name__,
                                                               "message": str(error)}})
        finally:
            if process is not None:
                cleanup_error = stop_and_prove_gone(process, executor)
                if cleanup_error:
                    record.setdefault("cleanup_errors", []).append(cleanup_error)
                    record["status"] = "failure"
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
                         "admissible samples require a separate paired comparison",
                         "measured_successes": measured_successes}
    result["capture_status"] = "failure" if any(r["status"] == "failure" for r in records) else "success"
    result["artifact_status"] = "admissible_per_run_manifests"
    return result


# Integrated launch capture deliberately lives beside the older one-shot launch/idle path.
# Browse capture has additional LaunchServices, fixture, AX, and Keychain concerns; importing it
# here would create a circular dependency and widen the already-reviewed runtime surface.
def calibration_plan_for(plan: dict[str, Any], output: pathlib.Path,
                         max_storage_drift_bytes: int) -> dict[str, Any]:
    calibration = json.loads(json.dumps(plan))
    calibration["mode"] = "calibration_capture"
    calibration["artifact_status"] = "planned_control_only_calibration_manifests"
    calibration["warmups"] = 3
    calibration["measured"] = 20
    calibration["output"] = str(output.absolute())
    calibration["max_free_storage_drift_bytes"] = max_storage_drift_bytes
    calibration["samples"] = [sample for sample in schedule(
        "launch", 3, 20, plan["seed"]) if sample["role"] == "control"]
    calibration["identities"]["comparison_id"] = opaque(
        "comparison", "calibration", plan["identities"]["comparison_id"])
    return calibration


def _json_bytes(value: Any) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode()


def canonical_sha256(value: Any) -> str:
    return hashlib.sha256(json.dumps(
        value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def read_regular_bytes(path: pathlib.Path, *, private: bool = False) -> bytes:
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except OSError as error:
        fail(f"regular file is missing or unsafe: {path}: {error}")
    try:
        metadata = os.fstat(fd)
        if not stat.S_ISREG(metadata.st_mode) or (private and metadata.st_mode & 0o077):
            fail(f"regular file has unsafe type or permissions: {path}")
        chunks = []
        while chunk := os.read(fd, 1024 * 1024):
            chunks.append(chunk)
        return b"".join(chunks)
    finally:
        os.close(fd)


def read_private_json(path: pathlib.Path) -> Any:
    try:
        return json.loads(read_regular_bytes(path, private=True))
    except json.JSONDecodeError as error:
        fail(f"private state is unreadable: {error}")


def fsync_directory(path: pathlib.Path) -> None:
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def validate_directory_ancestors(path: pathlib.Path, *, leaf_directory: bool = False) -> None:
    """Reject link-shaped/non-directory ancestors before integrated filesystem mutation."""
    absolute = path.absolute()
    ancestors = list(reversed(absolute.parents))
    for ancestor in ancestors:
        try:
            metadata = os.lstat(ancestor)
        except FileNotFoundError:
            continue
        if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
            fail(f"integrated output has an unsafe directory ancestor: {ancestor}")
    if leaf_directory:
        try:
            metadata = os.lstat(absolute)
        except FileNotFoundError:
            return
        if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
            fail(f"integrated private root is not a real directory: {absolute}")


def preflight_nonintegrated_output(path: pathlib.Path) -> pathlib.Path:
    """Reject output aliases/collisions before any non-integrated capture work begins."""
    output = path.absolute()
    if output.exists() or output.is_symlink():
        fail("non-integrated result output must not already exist")
    parent = output.parent
    validate_directory_ancestors(parent, leaf_directory=True)
    parent.mkdir(parents=True, exist_ok=True)
    validate_directory_ancestors(parent, leaf_directory=True)
    canonical = parent.resolve() / output.name
    if canonical.exists() or canonical.is_symlink():
        fail("non-integrated result output appeared during preflight")
    return canonical


def write_private_json_atomic(path: pathlib.Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_symlink() or (path.exists() and not path.is_file()):
        fail(f"private state path is unsafe: {path}")
    fd, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    temporary = pathlib.Path(temporary_name)
    try:
        os.fchmod(fd, 0o600)
        view = memoryview(_json_bytes(value))
        while view:
            view = view[os.write(fd, view):]
        os.fsync(fd)
        os.close(fd)
        fd = -1
        os.replace(temporary, path)
        fsync_directory(path.parent)
    finally:
        if fd >= 0:
            os.close(fd)
        temporary.unlink(missing_ok=True)


def write_durable_json_exclusive(path: pathlib.Path, value: Any) -> str:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    temporary = pathlib.Path(temporary_name)
    try:
        view = memoryview(_json_bytes(value))
        while view:
            view = view[os.write(fd, view):]
        os.fsync(fd)
        os.close(fd)
        fd = -1
        os.link(temporary, path, follow_symlinks=False)
        temporary.unlink()
        fsync_directory(path.parent)
    finally:
        if fd >= 0:
            os.close(fd)
        temporary.unlink(missing_ok=True)
    return hashlib.sha256(read_regular_bytes(path)).hexdigest()


def fsync_evidence_tree(path: pathlib.Path) -> None:
    if path.is_symlink() or not path.is_dir():
        fail(f"evidence tree is missing or unsafe: {path}")
    directories: list[pathlib.Path] = []
    for root, names, files in os.walk(path, topdown=True, followlinks=False):
        directory = pathlib.Path(root)
        directories.append(directory)
        for name in [*names, *files]:
            if (directory / name).is_symlink():
                fail(f"evidence tree contains a symlink: {directory / name}")
        for name in files:
            fd = os.open(directory / name, os.O_RDONLY | os.O_NOFOLLOW)
            try:
                if not stat.S_ISREG(os.fstat(fd).st_mode):
                    fail("evidence tree contains a non-regular file")
                os.fsync(fd)
            finally:
                os.close(fd)
    for directory in reversed(directories):
        fsync_directory(directory)


def publish_evidence_directory(pending: pathlib.Path, destination: pathlib.Path) -> None:
    if destination.exists() or destination.is_symlink():
        fail(f"evidence destination already exists: {destination}")
    fsync_evidence_tree(pending)
    os.rename(pending, destination)
    fsync_directory(destination.parent)


def discard_private_directory(path: pathlib.Path) -> None:
    if path.is_symlink():
        fail(f"private pending path is a symlink: {path}")
    if path.exists():
        if not path.is_dir():
            fail(f"private pending path is not a directory: {path}")
        shutil.rmtree(path)
        fsync_directory(path.parent)


def discard_private_file(path: pathlib.Path) -> None:
    if path.is_symlink() or not path.is_file() or path.stat().st_mode & 0o077:
        fail(f"private temporary path is unsafe: {path}")
    path.unlink()
    fsync_directory(path.parent)


class DetachedAppProcess:
    def __init__(self, pid: int, executable: pathlib.Path, start_identity: str):
        self.pid = pid
        self.executable = executable
        self.start_identity = start_identity
        self.returncode: int | None = None


def process_rows(executor: Executor) -> list[tuple[int, str]]:
    rows = []
    for line in executor.output(["/bin/ps", "-axo", "pid=,comm="]).splitlines():
        fields = line.strip().split(maxsplit=1)
        if len(fields) == 2:
            try:
                rows.append((int(fields[0]), fields[1]))
            except ValueError:
                pass
    return rows


def exact_executable_pids(executable: pathlib.Path, executor: Executor) -> set[int]:
    return {pid for pid, command in process_rows(executor) if command == str(executable)}


def process_start_identity(pid: int, executor: Executor) -> str:
    override = getattr(executor, "process_start_identity", None)
    if override is not None:
        return str(override(pid))

    class ProcBSDInfo(ctypes.Structure):
        _fields_ = [
            ("pbi_flags", ctypes.c_uint32), ("pbi_status", ctypes.c_uint32),
            ("pbi_xstatus", ctypes.c_uint32), ("pbi_pid", ctypes.c_uint32),
            ("pbi_ppid", ctypes.c_uint32), ("pbi_uid", ctypes.c_uint32),
            ("pbi_gid", ctypes.c_uint32), ("pbi_ruid", ctypes.c_uint32),
            ("pbi_rgid", ctypes.c_uint32), ("pbi_svuid", ctypes.c_uint32),
            ("pbi_svgid", ctypes.c_uint32), ("rfu_1", ctypes.c_uint32),
            ("pbi_comm", ctypes.c_char * 16), ("pbi_name", ctypes.c_char * 32),
            ("pbi_nfiles", ctypes.c_uint32), ("pbi_pgid", ctypes.c_uint32),
            ("pbi_pjobc", ctypes.c_uint32), ("e_tdev", ctypes.c_uint32),
            ("e_tpgid", ctypes.c_uint32), ("pbi_nice", ctypes.c_int32),
            ("pbi_start_tvsec", ctypes.c_uint64), ("pbi_start_tvusec", ctypes.c_uint64),
        ]
    info = ProcBSDInfo()
    libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    libproc.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64,
                                     ctypes.c_void_p, ctypes.c_int]
    libproc.proc_pidinfo.restype = ctypes.c_int
    size = libproc.proc_pidinfo(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info))
    if size != ctypes.sizeof(info) or info.pbi_pid != pid:
        fail("could not bind the exact app process start identity")
    return f"{info.pbi_start_tvsec}:{info.pbi_start_tvusec}"


def stop_detached_and_prove_gone(process: DetachedAppProcess, executor: Executor) -> str | None:
    def still_exact() -> bool:
        return (process.pid in exact_executable_pids(process.executable, executor)
                and process_start_identity(process.pid, executor) == process.start_identity)
    if not still_exact():
        return None
    try:
        if not still_exact():
            return None
        executor.terminate(process.pid)
        for _ in range(50):
            if not still_exact():
                return None
            executor.sleep(0.1)
        if not still_exact():
            return None
        executor.kill(process.pid)
        for _ in range(50):
            if not still_exact():
                return None
            executor.sleep(0.1)
        return f"PID {process.pid} exceeded both cleanup deadlines"
    except (OSError, ProcessLookupError):
        if still_exact():
            return f"could not prove exact app PID {process.pid} terminated"
    return None


def cleared_active_app() -> dict[str, Any]:
    return {"schema_version": 1, "status": "cleared"}


def cleanup_checkpointed_active_app(path: pathlib.Path, apps: tuple[App, App],
                                    executor: Executor) -> None:
    document = read_private_json(path)
    if document == cleared_active_app():
        return
    by_role = {app.role: app for app in apps}
    if isinstance(document, dict) and document.get("status") == "launching":
        expected = {"schema_version", "status", "role", "executable", "bundle_id"}
        app = by_role.get(document.get("role"))
        if (set(document) != expected or document.get("schema_version") != 1 or app is None
                or document.get("executable") != str(app.executable)
                or document.get("bundle_id") != app.bundle_id):
            fail("launching app checkpoint identity drift detected")
        if exact_executable_pids(app.executable, executor):
            fail("unbound direct-launch app requires explicit operator cleanup before resume")
        write_private_json_atomic(path, cleared_active_app())
        return
    keys = {"schema_version", "status", "pid", "role", "executable", "bundle_id",
            "start_identity"}
    if not isinstance(document, dict) or set(document) != keys or document.get("status") != "active":
        fail("active app checkpoint is invalid")
    app = by_role.get(document.get("role"))
    if (document.get("schema_version") != 1 or app is None
            or document.get("executable") != str(app.executable)
            or document.get("bundle_id") != app.bundle_id
            or type(document.get("pid")) is not int or document["pid"] <= 1
            or not isinstance(document.get("start_identity"), str)):
        fail("active app checkpoint identity drift detected")
    error = stop_detached_and_prove_gone(DetachedAppProcess(
        document["pid"], app.executable, document["start_identity"]), executor)
    if error:
        fail(f"could not clean checkpointed app before resume: {error}")
    write_private_json_atomic(path, cleared_active_app())


def validate_calibration_covariates(samples: list[Any], max_storage_drift_bytes: int) -> None:
    devices = [sample.manifest["device"] for sample in samples]
    if {device["power_source"] for device in devices} != {"external"}:
        fail("control-only calibration requires stable external power")
    if len({device["battery_state"] for device in devices}) != 1:
        fail("control-only calibration requires a stable battery state")
    thermal = {device["thermal_state"] for device in devices}
    if len(thermal) != 1 or not thermal <= {"nominal", "fair"}:
        fail("control-only calibration requires one stable supported thermal state")
    storage = [device["free_storage_bytes"] for device in devices]
    if max(storage) - min(storage) > max_storage_drift_bytes:
        fail("control-only calibration exceeds its free-storage drift tolerance")


def calibration_artifact(plan: dict[str, Any], records: list[dict[str, Any]]) -> dict[str, Any]:
    samples = [compare.load_sample(pathlib.Path(record["manifest"]), "control")
               for record in records]
    validate_calibration_covariates(samples, plan["max_free_storage_drift_bytes"])
    return compare.freeze_control(samples, selector=samples[0].workload, sample_policy="short")


def calibration_result(plan: dict[str, Any], records: list[dict[str, Any]]) -> dict[str, Any]:
    return {"schema_version": 1, "capture_status": "success",
            "artifact_status": "admissible_control_only_calibration_manifests",
            "scenario": "launch", "cooldown_seconds": plan["cooldown_seconds"],
            "max_free_storage_drift_bytes": plan["max_free_storage_drift_bytes"],
            "records": records}


def validate_current_calibration_environment(reference: Any, plan: dict[str, Any],
                                             executor: Executor) -> None:
    facts = host_facts(executor, pathlib.Path(plan["container"]).parent)
    product = reference.manifest["product"]
    device = reference.manifest["device"]
    if (facts["os_build"] != product["os_build"]
            or facts["xcode_build"] != product["xcode_build"]
            or facts["display_mode"] != device["display_mode"]):
        fail("current host environment no longer matches calibration")
    if (facts["power_source"] != "external"
            or facts["battery_state"] != device["battery_state"]
            or facts["thermal_state"] != device["thermal_state"]
            or facts["thermal_state"] not in {"nominal", "fair"}
            or abs(facts["free_storage_bytes"] - device["free_storage_bytes"])
            > plan["max_free_storage_drift_bytes"]):
        fail("current host covariates no longer match calibration")


def validate_sample_calibration_covariates(sample: Any, reference: Any,
                                           max_storage_drift_bytes: int) -> None:
    device = sample.manifest["device"]
    frozen = reference.manifest["device"]
    if (device["power_source"] != "external"
            or device["power_source"] != frozen["power_source"]
            or device["battery_state"] != frozen["battery_state"]
            or device["thermal_state"] != frozen["thermal_state"]
            or device["thermal_state"] not in {"nominal", "fair"}
            or abs(device["free_storage_bytes"] - frozen["free_storage_bytes"])
            > max_storage_drift_bytes):
        fail("captured arm covariates do not match frozen calibration")


def validate_new_evidence_chronology(samples: list[Any], previous: Any | None) -> None:
    if (not samples or any(not first.recorded_at < second.recorded_at
                           for first, second in zip(samples, samples[1:]))):
        fail("new evidence is not in strict chronological order")
    if previous is not None and not previous.recorded_at < samples[0].recorded_at:
        fail("new evidence does not follow retained evidence chronologically")


def capture_launch_sample(plan: dict[str, Any], sample: dict[str, Any], app: App,
                          run_dir: pathlib.Path, executor: Executor,
                          active_app_path: pathlib.Path) -> dict[str, Any]:
    record = {key: sample[key] for key in
              ("scenario", "sample_kind", "sample_index", "pair_order", "role")}
    run_dir.mkdir(mode=0o700)
    raw = run_dir / "raw/artifact-0001.log"
    summary = run_dir / "summary/redacted.json"
    raw.parent.mkdir()
    summary.parent.mkdir()
    manifest_path = run_dir / "manifest.json"
    process = None
    try:
        seed_container(pathlib.Path(plan["container"]), executor)
        facts = host_facts(executor, pathlib.Path(plan["container"]).parent)
        start = executor.now().replace("+00:00", "Z")
        manifest, workload = launch_manifest(plan, sample, app, facts, run_dir, start)
        manifest_path.write_bytes(_json_bytes(manifest))
        nonce = opaque("nonce", manifest["run"]["id"], workload, length=16)
        with raw.open("wb") as output:
            executor.run([sys.executable, str(SUMMARY), "--emit-capture-marker", "--manifest",
                          str(manifest_path), "--workload-id", workload,
                          "--launch-nonce", nonce], stdout=output)
        write_private_json_atomic(active_app_path, {
            "schema_version": 1, "status": "launching", "role": app.role,
            "executable": str(app.executable), "bundle_id": app.bundle_id})
        preflight_no_existing_app((app, app), executor)
        process = executor.spawn([str(app.executable)])
        start_identity = process_start_identity(int(process.pid), executor)
        write_private_json_atomic(active_app_path, {
            "schema_version": 1, "status": "active", "pid": int(process.pid), "role": app.role,
            "executable": str(app.executable), "bundle_id": app.bundle_id,
            "start_identity": start_identity})
        if executor.poll(process) is not None:
            fail(f"app PID {process.pid} exited at launch")
        executor.sleep(plan["duration_seconds"])
        end = executor.now().replace("+00:00", "Z")
        with raw.open("ab") as output:
            executor.run(["/usr/bin/log", "show", "--info", "--style", "ndjson", "--start",
                          log_time_bound(start), "--end", log_time_bound(end, end=True),
                          "--process", str(process.pid)], stdout=output)
        if executor.poll(process) is not None:
            fail(f"app PID {process.pid} exited during capture")
        cleanup = stop_and_prove_gone(process, executor)
        if cleanup:
            fail(cleanup)
        process = None
        write_private_json_atomic(active_app_path, cleared_active_app())
        manifest["evidence"]["artifacts"][0]["sha256"] = hashlib.sha256(raw.read_bytes()).hexdigest()
        manifest_path.write_bytes(_json_bytes(manifest))
        with summary.open("wb") as output:
            executor.run([sys.executable, str(SUMMARY), "--json", "--strict", "--manifest",
                          str(manifest_path), "--raw-artifact", str(raw), "--workload-id", workload,
                          *launch_summary_arguments(plan)], stdout=output)
        manifest["evidence"]["redacted_summary"]["sha256"] = hashlib.sha256(
            summary.read_bytes()).hexdigest()
        manifest_path.write_bytes(_json_bytes(manifest))
        if bundle_sha256(app.path) != manifest["product"]["sha256"]:
            fail("measured app bundle mutated during capture")
        executor.run([sys.executable, str(CONTRACT), "manifest", str(manifest_path)])
        record.update(status="success", manifest=str(manifest_path),
                      manifest_sha256=hashlib.sha256(manifest_path.read_bytes()).hexdigest())
        return record
    finally:
        if process is not None:
            cleanup = stop_and_prove_gone(process, executor)
            if cleanup:
                fail(cleanup)
        if read_private_json(active_app_path).get("status") == "active":
            write_private_json_atomic(active_app_path, cleared_active_app())


def _recorded_sample(record: dict[str, Any], role: str) -> Any:
    return compare.load_sample(pathlib.Path(record["manifest"]), role)


def validate_records(records: Any, samples: list[dict[str, Any]], raw_root: pathlib.Path,
                     plan: dict[str, Any], apps: tuple[App, App], *,
                     paired: bool) -> tuple[set[str], set[str]]:
    if not isinstance(records, list) or len(records) > len(samples) or (paired and len(records) % 2):
        fail("resume state record cardinality is invalid")
    ids: set[str] = set()
    nonces: set[str] = set()
    previous = None
    app_hashes = {app.role: bundle_sha256(app.path) for app in apps}
    for ordinal, record in enumerate(records):
        sample = samples[ordinal]
        if record.get("status") != "success":
            fail("resume state contains a non-success record")
        for key in ("scenario", "sample_kind", "sample_index", "pair_order", "role"):
            if record.get(key) != sample[key]:
                fail("resume state record ordering drift detected")
        expected = (raw_root / f"pair-{ordinal // 2 + 1:04d}" /
                    f"arm-{ordinal % 2 + 1}" / "manifest.json" if paired else
                    raw_root / f"sample-{ordinal + 1:04d}" / "manifest.json")
        if pathlib.Path(record.get("manifest", "")).absolute() != expected.absolute():
            fail("resume state manifest path drift detected")
        current = raw_root.absolute()
        if current.is_symlink() or not current.is_dir():
            fail("resume evidence root is missing or unsafe")
        for component in expected.absolute().parent.relative_to(current).parts:
            current /= component
            if current.is_symlink() or not current.is_dir():
                fail("resume manifest has an unsafe directory ancestor")
        payload = read_regular_bytes(expected)
        if hashlib.sha256(payload).hexdigest() != record.get("manifest_sha256"):
            fail("resume state manifest checksum drift detected")
        loaded = _recorded_sample(record, sample["role"])
        document = loaded.manifest
        if (document["run"]["comparison_id"] != plan["identities"]["comparison_id"]
                or document["run"]["order_seed"] != plan["identities"]["order_seed"]
                or document["scenario"]["id"] != plan["identities"]["scenario_id"]
                or loaded.workload["id"] != plan["identities"]["workload_id"]
                or loaded.workload["phase"] != launch_profile(plan)["phase"]
                or document["product"]["commit"] != plan["commits"][sample["role"]]
                or document["product"]["sha256"] != app_hashes[sample["role"]]):
            fail("resume evidence identity drift detected")
        run_id = document["run"]["id"]
        nonce = loaded.capture_binding["launch_nonce"]
        expected_run_id = opaque(
            "run", plan["identities"]["comparison_id"], sample["role"],
            sample["sample_kind"], sample["sample_index"], sample["pair_order"])
        expected_nonce = opaque(
            "nonce", expected_run_id, plan["identities"]["workload_id"], length=16)
        if run_id != expected_run_id or nonce != expected_nonce:
            fail("resume evidence run binding drift detected")
        if run_id in ids or nonce in nonces:
            fail("resume evidence contains duplicate run or launch identities")
        ids.add(run_id)
        nonces.add(nonce)
        if previous is not None and not previous.recorded_at < loaded.recorded_at:
            fail("resume evidence is not in strict chronological order")
        previous = loaded
    return ids, nonces


def integrated_identity(plan: dict[str, Any], calibration: dict[str, Any],
                        apps: tuple[App, App], calibration_output: pathlib.Path,
                        frozen_output: pathlib.Path, max_pair_gap: float) -> dict[str, Any]:
    return {"schema_version": 1, "paired_plan": plan, "calibration_plan": calibration,
            "apps": [{"role": app.role, "path": str(app.path),
                      "bundle_sha256": bundle_sha256(app.path)} for app in apps],
            "outputs": {"paired": plan["output"], "calibration": str(calibration_output.absolute()),
                        "frozen_mde": str(frozen_output.absolute())},
            "max_pair_gap_seconds": max_pair_gap,
            "sources": {"runner_sha256": hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest(),
                        "compare_sha256": hashlib.sha256(COMPARE.read_bytes()).hexdigest()}}


def integrated_result(plan: dict[str, Any], calibration: dict[str, Any], state: dict[str, Any]) -> dict[str, Any]:
    result = {key: value for key, value in plan.items() if key != "samples"}
    result.update(records=state["paired_records"], capture_status="success",
                  artifact_status="admissible_per_run_manifests",
                  calibration={"output": calibration["output"],
                               "frozen_mde_sha256": state["frozen_mde_sha256"],
                               "records": len(state["calibration_records"])},
                  verdict={"status": "insufficient_data",
                           "reason": "admissible samples require a separate paired comparison",
                           "measured_successes": sum(record["sample_kind"] == "measured"
                                                     for record in state["paired_records"])})
    return result


def validate_integrated_plan(plan: dict[str, Any], calibration: dict[str, Any]) -> None:
    paired_profile = launch_profile(plan)
    calibration_profile = launch_profile(calibration)
    expected_pairs = schedule("launch", 3, 20, plan["seed"])
    expected_calibration = [sample for sample in expected_pairs if sample["role"] == "control"]
    sample_keys = ("scenario", "sample_kind", "sample_index", "pair_order", "role")
    projected_pairs = [{key: sample[key] for key in sample_keys} for sample in plan["samples"]]
    projected_calibration = [
        {key: sample[key] for key in sample_keys} for sample in calibration["samples"]]
    if (plan.get("scenario") != "launch" or (plan.get("warmups"), plan.get("measured")) != (3, 20)
            or projected_pairs != expected_pairs
            or (calibration.get("warmups"), calibration.get("measured")) != (3, 20)
            or projected_calibration != expected_calibration
            or any(sample["role"] != "control" for sample in calibration["samples"])
            or calibration["identities"]["comparison_id"] == plan["identities"]["comparison_id"]
            or calibration["identities"]["order_seed"] != plan["identities"]["order_seed"]
            or calibration["identities"]["workload_id"] != plan["identities"]["workload_id"]
            or calibration_profile != paired_profile):
        fail("integrated launch plan violates the fixed short-policy schedule")


def capture_integrated(plan: dict[str, Any], calibration: dict[str, Any],
                       apps: tuple[App, App], executor: Executor, *,
                       calibration_output: pathlib.Path, frozen_output: pathlib.Path,
                       resume: bool, max_pair_gap_seconds: float) -> dict[str, Any]:
    validate_integrated_plan(plan, calibration)
    output = pathlib.Path(plan["output"])
    roots = [calibration_output.parent / f"{calibration_output.stem}-logs",
             output.parent / f"{output.stem}-logs"]
    calibration_root, paired_root = roots
    artifact_paths = [output.absolute(), calibration_output.absolute(), frozen_output.absolute()]
    root_paths = [root.absolute() for root in roots]
    if (len(set(artifact_paths)) != len(artifact_paths) or len(set(root_paths)) != len(root_paths)
            or any(path == root or root in path.parents
                   for path in artifact_paths for root in root_paths)):
        fail("integrated launch output and private-root paths must be distinct")
    for path in artifact_paths:
        validate_directory_ancestors(path)
    for root in roots:
        validate_directory_ancestors(root, leaf_directory=True)
    state_path = paired_root / ".resume-state.json"
    plan_path = paired_root / ".resume-plan.json"
    active_path = paired_root / ".active-app.json"
    identity = integrated_identity(plan, calibration, apps, calibration_output,
                                   frozen_output, max_pair_gap_seconds)
    digest = canonical_sha256(identity)
    if resume:
        if read_private_json(plan_path) != identity:
            fail("resume plan identity drift detected")
        state = read_private_json(state_path)
        if not isinstance(state, dict) or set(state) != {
                "schema_version", "plan_sha256", "calibration_records", "paired_records",
                "calibration_output_sha256", "frozen_mde_sha256"}:
            fail("resume state has an unexpected shape")
        if state["schema_version"] != 1 or state["plan_sha256"] != digest:
            fail("resume state does not match the fixed plan")
        if (not isinstance(state["calibration_records"], list)
                or len(state["calibration_records"]) > len(calibration["samples"])
                or not isinstance(state["paired_records"], list)
                or len(state["paired_records"]) > len(plan["samples"])
                or len(state["paired_records"]) % 2):
            fail("resume state record cardinality is invalid")
        for key in ("calibration_output_sha256", "frozen_mde_sha256"):
            value = state[key]
            if value is not None and (not isinstance(value, str)
                                      or re.fullmatch(r"[a-f0-9]{64}", value) is None):
                fail("resume state contains an invalid artifact digest")
        cleanup_checkpointed_active_app(active_path, apps, executor)
        for directory, names in (
                (paired_root, (state_path.name, plan_path.name, active_path.name)),
                (output.parent, (output.name, calibration_output.name, frozen_output.name))):
            for name in names:
                for temporary in directory.glob(f".{name}.*.tmp"):
                    discard_private_file(temporary)
    else:
        if any(path.exists() or path.is_symlink() for path in
               [*roots, output, calibration_output, frozen_output]):
            fail("integrated launch outputs must not already exist")
        for root in roots:
            root.mkdir(parents=True, mode=0o700)
        write_private_json_atomic(plan_path, identity)
        state = {"schema_version": 1, "plan_sha256": digest, "calibration_records": [],
                 "paired_records": [], "calibration_output_sha256": None,
                 "frozen_mde_sha256": None}
        write_private_json_atomic(state_path, state)
        write_private_json_atomic(active_path, cleared_active_app())
    calibration_ids, calibration_nonces = validate_records(
        state["calibration_records"], calibration["samples"], calibration_root,
        calibration, apps, paired=False)
    paired_ids, paired_nonces = validate_records(
        state["paired_records"], plan["samples"], paired_root, plan, apps, paired=True)
    if calibration_ids & paired_ids or calibration_nonces & paired_nonces:
        fail("calibration and paired evidence identities are not globally unique")
    if state["paired_records"] and (state["calibration_output_sha256"] is None
                                    or state["frozen_mde_sha256"] is None):
        fail("resume state advanced before the calibration freeze boundary")
    if (len(state["calibration_records"]) != len(calibration["samples"])
            and (state["calibration_output_sha256"] is not None
                 or state["frozen_mde_sha256"] is not None)):
        fail("resume state froze artifacts before calibration completed")
    if state["frozen_mde_sha256"] is not None and state["calibration_output_sha256"] is None:
        fail("resume state froze MDE before calibration output")
    # Only the exact next abandoned slot is discardable.
    for root in roots:
        validate_directory_ancestors(root, leaf_directory=True)
    calibration_done = len(state["calibration_records"])
    paired_done = len(state["paired_records"]) // 2
    allowed = {calibration_root / f".pending-sample-{calibration_done + 1:04d}",
               paired_root / f".pending-pair-{paired_done + 1:04d}"}
    for root in roots:
        for pending in root.glob(".pending-*"):
            if pending not in allowed:
                fail("unexpected pending output in resume root")
            discard_private_directory(pending)
    next_calibration = calibration_root / f"sample-{calibration_done + 1:04d}"
    next_pair = paired_root / f"pair-{paired_done + 1:04d}"
    for root, prefix, completed, limit, next_path in (
            (calibration_root, "sample-", calibration_done, len(calibration["samples"]),
             next_calibration),
            (paired_root, "pair-", paired_done, len(plan["samples"]) // 2, next_pair)):
        for path in root.glob(f"{prefix}*"):
            try:
                ordinal = int(path.name.removeprefix(prefix))
            except ValueError:
                fail("unexpected evidence path in resume root")
            if completed < limit and path == next_path:
                discard_private_directory(path)
            elif not 1 <= ordinal <= completed:
                fail("unexpected evidence ordinal in resume root")
    allowed_calibration_names = {
        *(f"sample-{index:04d}" for index in range(1, calibration_done + 1))}
    allowed_paired_names = {
        ".resume-state.json", ".resume-plan.json", ".active-app.json",
        *(f"pair-{index:04d}" for index in range(1, paired_done + 1))}
    for root, allowed_names in ((calibration_root, allowed_calibration_names),
                                (paired_root, allowed_paired_names)):
        unexpected = {path.name for path in root.iterdir()
                      if not path.name.startswith(".pending-")} - allowed_names
        if unexpected:
            fail(f"unexpected retained output inventory: {sorted(unexpected)}")
    if state["calibration_output_sha256"] is not None:
        payload = read_regular_bytes(calibration_output)
        if (payload != _json_bytes(calibration_result(
                calibration, state["calibration_records"]))
                or hashlib.sha256(payload).hexdigest() != state["calibration_output_sha256"]):
            fail("checkpointed calibration output drift detected")
    if state["frozen_mde_sha256"] is not None:
        frozen = calibration_artifact(calibration, state["calibration_records"])
        payload = read_regular_bytes(frozen_output)
        if json.loads(payload) != frozen or hashlib.sha256(payload).hexdigest() != state["frozen_mde_sha256"]:
            fail("checkpointed frozen MDE drift detected")
        compare.load_frozen(frozen_output, state["frozen_mde_sha256"])
    if output.exists() or output.is_symlink():
        expected = integrated_result(plan, calibration, state)
        if (len(state["paired_records"]) != len(plan["samples"])
                or read_regular_bytes(output) != _json_bytes(expected)):
            fail("published integrated output does not match completed state")
        return expected
    by_role = {app.role: app for app in apps}
    for ordinal in range(calibration_done + 1, len(calibration["samples"]) + 1):
        if ordinal > 1 and plan["cooldown_seconds"]:
            executor.sleep(plan["cooldown_seconds"])
        pending = calibration_root / f".pending-sample-{ordinal:04d}"
        discard_private_directory(pending)
        sample = calibration["samples"][ordinal - 1]
        record = capture_launch_sample(calibration, sample, by_role["control"], pending,
                                       executor, active_path)
        captured = _recorded_sample(record, "control")
        previous_calibration = (_recorded_sample(state["calibration_records"][-1], "control")
                                if state["calibration_records"] else None)
        validate_new_evidence_chronology([captured], previous_calibration)
        destination = calibration_root / f"sample-{ordinal:04d}"
        publish_evidence_directory(pending, destination)
        record["manifest"] = str(destination / "manifest.json")
        record["manifest_sha256"] = hashlib.sha256(
            read_regular_bytes(destination / "manifest.json")).hexdigest()
        state["calibration_records"].append(record)
        write_private_json_atomic(state_path, state)
    if state["frozen_mde_sha256"] is None:
        calibration_document = calibration_result(calibration, state["calibration_records"])
        expected_calibration = _json_bytes(calibration_document)
        if state["calibration_output_sha256"] is None and calibration_output.exists():
            if read_regular_bytes(calibration_output) != expected_calibration:
                fail("uncheckpointed calibration output does not match accepted evidence")
            state["calibration_output_sha256"] = hashlib.sha256(expected_calibration).hexdigest()
        elif state["calibration_output_sha256"] is None:
            state["calibration_output_sha256"] = write_durable_json_exclusive(
                calibration_output, calibration_document)
        write_private_json_atomic(state_path, state)
        artifact = calibration_artifact(calibration, state["calibration_records"])
        expected_frozen = _json_bytes(artifact)
        if frozen_output.exists():
            if read_regular_bytes(frozen_output) != expected_frozen:
                fail("uncheckpointed frozen MDE does not match accepted evidence")
            state["frozen_mde_sha256"] = hashlib.sha256(expected_frozen).hexdigest()
        else:
            state["frozen_mde_sha256"] = write_durable_json_exclusive(frozen_output, artifact)
        compare.load_frozen(frozen_output, state["frozen_mde_sha256"])
        write_private_json_atomic(state_path, state)
        preflight_no_existing_app(apps, executor)
    reference = _recorded_sample(state["calibration_records"][0], "control")
    for pair_index in range(paired_done + 1, len(plan["samples"]) // 2 + 1):
        if plan["cooldown_seconds"]:
            executor.sleep(plan["cooldown_seconds"])
        validate_current_calibration_environment(reference, calibration, executor)
        pending = paired_root / f".pending-pair-{pair_index:04d}"
        discard_private_directory(pending)
        pending.mkdir(mode=0o700)
        pair_records = []
        for arm, sample in enumerate(plan["samples"][(pair_index - 1) * 2:pair_index * 2], 1):
            pair_records.append(capture_launch_sample(
                plan, sample, by_role[sample["role"]], pending / f"arm-{arm}", executor, active_path))
        loaded = [_recorded_sample(record, record["role"]) for record in pair_records]
        if any(compare._environment_fingerprint(sample) != compare._environment_fingerprint(reference)
               for sample in loaded):
            fail("pending pair environment does not match frozen calibration")
        for captured in loaded:
            validate_sample_calibration_covariates(
                captured, reference, calibration["max_free_storage_drift_bytes"])
        previous = (_recorded_sample(state["paired_records"][-1],
                                     state["paired_records"][-1]["role"])
                    if state["paired_records"] else
                    _recorded_sample(state["calibration_records"][-1], "control"))
        validate_new_evidence_chronology(loaded, previous)
        # Pairing validation requires zero-based consecutive indexes for each sample kind. Validate
        # the retained corpus plus this unpublished pair: validating pair N alone would incorrectly
        # reject every N > 1 because its local sample index does not begin at zero.
        retained = [_recorded_sample(record, record["role"])
                    for record in state["paired_records"]]
        pending_corpus = [*retained, *loaded]
        compare._validate_pairing(
            [sample for sample in pending_corpus
             if sample.manifest["run"]["artifact_role"] == "control"],
            [sample for sample in pending_corpus
             if sample.manifest["run"]["artifact_role"] == "candidate"],
            calibration["max_free_storage_drift_bytes"], max_pair_gap_seconds)
        destination = paired_root / f"pair-{pair_index:04d}"
        publish_evidence_directory(pending, destination)
        for arm, record in enumerate(pair_records, 1):
            record["manifest"] = str(destination / f"arm-{arm}/manifest.json")
            record["manifest_sha256"] = hashlib.sha256(
                read_regular_bytes(pathlib.Path(record["manifest"]))).hexdigest()
            state["paired_records"].append(record)
        write_private_json_atomic(state_path, state)
    validate_records(state["paired_records"], plan["samples"], paired_root, plan, apps, paired=True)
    result = integrated_result(plan, calibration, state)
    write_durable_json_exclusive(output, result)
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
    parser.add_argument("--launch-phase", choices=sorted(LAUNCH_PHASE_PROFILES),
                        help="exact launch attribution span (default: runtime.composition; launch only)")
    parser.add_argument("--warmups", type=int)
    parser.add_argument("--measured", type=int)
    parser.add_argument("--duration-seconds", type=int)
    parser.add_argument("--idle-settle-seconds", type=int,
                        help="bounded readiness/settle interval before idle tracing (default: 10)")
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--cooldown-seconds", type=float, default=0,
                        help="cooldown between calibration samples and complete launch pairs")
    parser.add_argument("--calibration-output", type=pathlib.Path,
                        help="enable integrated launch calibration and write its durable result")
    parser.add_argument("--frozen-mde-output", type=pathlib.Path,
                        help="durable control-only MDE artifact for integrated launch capture")
    parser.add_argument("--max-calibration-storage-drift-bytes", type=int, default=0)
    parser.add_argument("--max-pair-gap-seconds", type=float, default=120)
    parser.add_argument("--resume", action="store_true",
                        help="resume an exact previously checkpointed integrated launch plan")
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
    if args.scenario == "idle" and args.launch_phase is not None:
        fail("--launch-phase is valid only for the launch scenario")
    settle = defaults["settle_seconds"] if args.idle_settle_seconds is None else args.idle_settle_seconds
    if (warmups < 0 or measured < 1 or not 1 <= duration <= 86_400 or settle < 0
            or not math.isfinite(args.cooldown_seconds) or args.cooldown_seconds < 0
            or args.max_calibration_storage_drift_bytes < 0
            or not math.isfinite(args.max_pair_gap_seconds) or args.max_pair_gap_seconds <= 0):
        fail("warmups and settle must be nonnegative; measured must be positive; duration must be 1...86400 seconds")
    integrated = args.calibration_output is not None or args.frozen_mde_output is not None
    if integrated and (args.calibration_output is None or args.frozen_mde_output is None):
        fail("integrated launch capture requires both calibration and frozen-MDE outputs")
    if integrated and args.scenario != "launch":
        fail("integrated calibration is supported only for the launch scenario")
    if integrated and (warmups, measured) != (3, 20):
        fail("integrated short-policy launch capture requires exactly 3 warmups and 20 measured pairs")
    if args.resume and not integrated:
        fail("--resume requires integrated launch calibration")
    if not integrated and args.cooldown_seconds:
        fail("--cooldown-seconds requires integrated launch calibration")
    apps = validate_pair(args.control_app, args.candidate_app)
    plan = command_plan(apps, args.scenario, warmups, measured, duration, args.seed, args.output,
                        settle_seconds=settle, control_commit=args.control_commit,
                        candidate_commit=args.candidate_commit, device_label=args.device_label,
                        retention_deadline=args.retention_deadline,
                        cooldown_seconds=args.cooldown_seconds, launch_phase=args.launch_phase)
    calibration = (calibration_plan_for(
        plan, args.calibration_output, args.max_calibration_storage_drift_bytes)
        if integrated else None)
    if args.plan:
        document = {**plan, "mode": "plan"}
        if calibration is not None:
            document["calibration"] = calibration
            document["frozen_mde_output"] = str(args.frozen_mde_output.absolute())
            document["max_pair_gap_seconds"] = args.max_pair_gap_seconds
            document["resume"] = args.resume
        print(json.dumps(document, indent=2, sort_keys=True))
        return 0
    result_output = (preflight_nonintegrated_output(args.output)
                     if calibration is None else args.output)
    active_executor = executor or Executor()
    if calibration is not None:
        result = capture_integrated(
            plan, calibration, apps, active_executor,
            calibration_output=args.calibration_output,
            frozen_output=args.frozen_mde_output, resume=args.resume,
            max_pair_gap_seconds=args.max_pair_gap_seconds)
    else:
        result = capture(plan, apps, active_executor)
        write_durable_json_exclusive(result_output, result)
    return 1 if result["capture_status"] == "failure" else 0

if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RunnerError, OSError, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
