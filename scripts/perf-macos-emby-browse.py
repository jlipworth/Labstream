#!/usr/bin/env python3
"""Plan or capture paired, externally-driven macOS Emby browse workloads."""
from __future__ import annotations

import argparse
import copy
import ctypes
import hashlib
import importlib.util
import json
import math
import os
import pathlib
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import urllib.request
from typing import Any
from urllib.parse import urlsplit

ROOT = pathlib.Path(__file__).resolve().parents[1]
BASE_RUNNER_PATH = ROOT / "scripts" / "perf-macos-launch-idle.py"
FIXTURE = ROOT / "scripts" / "perf-emby-browse-fixture.py"
DRIVER = ROOT / "scripts" / "perf-macos-ax-driver.swift"
SUMMARY = ROOT / "scripts" / "perf-log-summary.py"
CONTRACT = ROOT / "scripts" / "performance-audit-contract.py"
EVIDENCE_SCHEMA_PATH = ROOT / "scripts" / "perf_evidence_schema.py"
COMPARE_PATH = ROOT / "scripts" / "perf-compare.py"
SCENARIOS = ("home", "catalog", "search", "artwork")
AUTH_ACCOUNTS = (
    "token", "clientIdentifier", "selectedBackend", "selectedPlexServerID",
    "jellyfinServerURL", "jellyfinAccessToken", "jellyfinUserID", "jellyfinServerID",
    "embyServerURL", "embyAccessToken", "embyUserID", "embyServerID",
)
FIXTURE_USERNAME = "benchmark-user"
FIXTURE_PASSWORD = "benchmark-pass-v1"
VISIBILITY_PROMPT_KEY = (
    "libraryVisibility.promptShown."
    "emby:sid#970ebee6faf3b564:user#75ca7eeedfa213cf"
)


def _load_base() -> Any:
    spec = importlib.util.spec_from_file_location("perf_macos_launch_idle_for_browse", BASE_RUNNER_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError("could not load paired-runner foundation")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


base = _load_base()
RunnerError = base.RunnerError


def _load_evidence_schema() -> Any:
    spec = importlib.util.spec_from_file_location("perf_evidence_schema_for_browse", EVIDENCE_SCHEMA_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError("could not load performance evidence schema")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


evidence_schema = _load_evidence_schema()


def _load_compare() -> Any:
    spec = importlib.util.spec_from_file_location("perf_compare_for_browse", COMPARE_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError("could not load performance comparator")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


compare = _load_compare()
SCENARIO_PHASES = {
    "home": "home.load",
    "catalog": "library_grid.complete",
    "search": "search.load",
    "artwork": "artwork.load",
}
SCENARIO_SELECTOR_FIELDS = {
    "home": {},
    "catalog": {},
    "search": {},
    "artwork": {"scoped": "1", "milestone": "library_first_poster"},
}
ALLOWED_TRANSIENT_RESULTS = {
    "home.load": {"cancelled"},
    "library_grid.complete": {"cancelled", "superseded"},
    "search.load": {"cancelled", "superseded"},
    "artwork.load": set(),
}
DRIVER_ERROR_CODES = {
    "invalid_arguments", "invalid_output", "invalid_spec_file", "invalid_spec_permissions",
    "invalid_spec_schema", "invalid_fixture_url", "invalid_fixture_credentials", "invalid_pid",
    "process_unavailable", "accessibility_not_trusted", "element_not_found",
    "element_ambiguous", "accessibility_read_failed", "accessibility_action_failed",
    "keyboard_action_failed", "output_write_failed",
}
DRIVER_COMPLETED_STAGES = {
    "preflight", "attached", "backend_selected", "credential_method_selected",
    "server_entered", "username_entered", "password_entered", "sign_in_submitted",
    "awaiting_visibility_or_home", "visibility_ambiguous", "home_ambiguous",
    "authenticated", "home_loaded", "catalog_opened", "catalog_loaded", "search_opened",
    "search_entered", "search_loaded", "artwork_loaded",
}


class Executor(base.Executor):
    def run_status(self, argv: list[str]) -> int:
        return subprocess.run(argv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                              env={}).returncode

    def poll(self, process: Any) -> int | None:
        if not isinstance(process, DetachedAppProcess):
            return super().poll(process)
        if process.returncode is not None:
            return process.returncode
        if process.pid in exact_executable_pids(process.executable, self):
            return None
        process.returncode = 0
        return process.returncode

    def wait(self, process: Any, timeout: int) -> int:
        if not isinstance(process, DetachedAppProcess):
            return super().wait(process, timeout)
        for _ in range(max(1, timeout * 10)):
            status = self.poll(process)
            if status is not None:
                return status
            self.sleep(0.1)
        raise subprocess.TimeoutExpired(str(process.executable), timeout)


class DetachedAppProcess:
    """An exact LaunchServices child represented without a parent Popen handle."""

    def __init__(self, pid: int, executable: pathlib.Path, start_identity: str | None = None):
        self.pid = pid
        self.executable = executable
        self.start_identity = start_identity
        self.returncode: int | None = None


def fail(message: str) -> None:
    raise RunnerError(message)


def process_rows(executor: Any) -> list[tuple[int, str]]:
    """Return unambiguous PID/comm rows from one bounded process-table snapshot."""
    rows: list[tuple[int, str]] = []
    for line in executor.output(["/bin/ps", "-axo", "pid=,comm="]).splitlines():
        fields = line.strip().split(maxsplit=1)
        if len(fields) != 2:
            continue
        try:
            pid = int(fields[0])
        except ValueError:
            continue
        rows.append((pid, fields[1]))
    return rows


def exact_executable_pids(executable: pathlib.Path, executor: Any) -> set[int]:
    expected = str(executable)
    return {pid for pid, command in process_rows(executor) if command == expected}


def process_start_identity(pid: int, executor: Any) -> str:
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


def stop_app_and_prove_gone(process: Any, executor: Any) -> str | None:
    """Stop a child or detached exact-path app without ever signaling a reused PID."""
    if not isinstance(process, DetachedAppProcess):
        return base.stop_and_prove_gone(process, executor)

    pid = int(process.pid)

    def still_exact() -> bool:
        return (pid in exact_executable_pids(process.executable, executor)
                and (process.start_identity is None
                     or process_start_identity(pid, executor) == process.start_identity))

    if not still_exact():
        process.returncode = 0
        return None
    try:
        # Revalidate immediately before each signal. A disappeared or reused PID is already proof
        # that the exact measured process is gone and must never be signaled.
        if not still_exact():
            process.returncode = 0
            return None
        executor.terminate(pid)
        try:
            executor.wait(process, 5)
        except subprocess.TimeoutExpired:
            if not still_exact():
                process.returncode = 0
                return None
            executor.kill(pid)
            try:
                executor.wait(process, 5)
            except subprocess.TimeoutExpired:
                return f"PID {pid} exceeded both TERM and KILL cleanup deadlines"
        if executor.poll(process) is None:
            return f"PID {pid} remained alive after SIGTERM/SIGKILL cleanup"
    except (OSError, ProcessLookupError):
        if still_exact():
            return f"could not prove exact app PID {pid} terminated"
        process.returncode = 0
    return None


def launch_app(app: Any, executor: Any, bound_callback: Any | None = None) -> DetachedAppProcess:
    """Launch an exact staged bundle through LaunchServices and bind its sole new PID."""
    # Repeat the collision check at every sample boundary. This both protects PID discovery and
    # refuses to silently attach to an app left behind by a previous capture.
    base.preflight_no_existing_app((app, app), executor)
    before = exact_executable_pids(app.executable, executor)
    if before:
        fail(f"refusing LaunchServices launch with existing exact app PIDs: {sorted(before)}")
    executor.run(["/usr/bin/open", "-n", "-a", str(app.path)])
    for _ in range(100):
        new_pids = exact_executable_pids(app.executable, executor) - before
        if len(new_pids) == 1:
            process = DetachedAppProcess(new_pids.pop(), app.executable)
            if bound_callback is not None:
                try:
                    bound_callback(process)
                except BaseException as error:
                    cleanup = stop_app_and_prove_gone(process, executor)
                    if cleanup:
                        raise RunnerError(
                            f"app binding checkpoint failed and cleanup failed: {cleanup}") from error
                    raise
            return process
        if len(new_pids) > 1:
            cleanup_errors = []
            for pid in sorted(new_pids):
                error = stop_app_and_prove_gone(
                    DetachedAppProcess(pid, app.executable), executor)
                if error:
                    cleanup_errors.append(error)
            suffix = f"; cleanup: {'; '.join(cleanup_errors)}" if cleanup_errors else ""
            fail(f"LaunchServices created ambiguous exact app PIDs: {sorted(new_pids)}{suffix}")
        executor.sleep(0.05)
    # LaunchServices may publish the child just beyond the primary discovery deadline. Observe a
    # bounded grace window and clean every exact-path late arrival before failing the capture.
    late_pids: set[int] = set()
    for _ in range(20):
        late_pids.update(exact_executable_pids(app.executable, executor) - before)
        executor.sleep(0.05)
    # Cover the final sleep boundary too: a child published during that last interval must not
    # outlive a failed capture merely because no subsequent loop iteration observes it.
    late_pids.update(exact_executable_pids(app.executable, executor) - before)
    cleanup_errors = []
    for pid in sorted(late_pids):
        error = stop_app_and_prove_gone(DetachedAppProcess(pid, app.executable), executor)
        if error:
            cleanup_errors.append(error)
    suffix = f"; cleanup: {'; '.join(cleanup_errors)}" if cleanup_errors else ""
    fail(f"LaunchServices exact app PID discovery deadline exceeded{suffix}")


def keychain_service(app: Any) -> str:
    try:
        info = plistlib.loads((app.path / "Contents/Info.plist").read_bytes())
    except (OSError, plistlib.InvalidFileException) as error:
        fail(f"{app.role} has an unreadable Info.plist: {error}")
    service = info.get("LabstreamKeychainService")
    if service != app.bundle_id or not base.BUNDLE_ID_RE.fullmatch(str(service)):
        fail(f"{app.role} must use its dedicated performance bundle identifier as Keychain service")
    return service


def validate_inputs(control: pathlib.Path, candidate: pathlib.Path,
                    driver: pathlib.Path = DRIVER) -> tuple[tuple[Any, Any], str]:
    apps = base.validate_pair(control, candidate)
    services = tuple(keychain_service(app) for app in apps)
    if services[0] != services[1]:
        fail("control and candidate must use the same dedicated Keychain service")
    if driver.is_symlink() or not driver.is_file():
        fail("AX driver must be a real repository file")
    if driver.resolve().parent != (ROOT / "scripts").resolve():
        fail("AX driver must live in the repository scripts directory")
    return apps, services[0]


def reset_performance_keychain(service: str, executor: Any) -> None:
    if not base.BUNDLE_ID_RE.fullmatch(service):
        fail("refusing to reset a non-performance Keychain service")
    for account in AUTH_ACCOUNTS:
        status = executor.run_status([
            "/usr/bin/security", "delete-generic-password", "-s", service, "-a", account,
        ])
        if status not in (0, 44):
            fail(f"dedicated Keychain reset failed for account {account}")
        remaining = executor.run_status([
            "/usr/bin/security", "find-generic-password", "-s", service, "-a", account,
        ])
        if remaining != 44:
            fail(f"dedicated Keychain reset could not prove account {account} absent")


def preference_seed(service: str) -> bytes:
    if not base.BUNDLE_ID_RE.fullmatch(service):
        fail("refusing to seed preferences for a non-performance service")
    return plistlib.dumps({VISIBILITY_PROMPT_KEY: True}, fmt=plistlib.FMT_BINARY,
                          sort_keys=True)


def seed_browse_preferences(container: pathlib.Path, service: str) -> str:
    """Seed the fixture user's first-run prompt flag through anchored sandbox descriptors."""
    payload = preference_seed(service)
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    root_fd = os.open(container, flags)
    try:
        data_fd = os.open("Data", flags, dir_fd=root_fd)
        try:
            library_fd = os.open("Library", flags, dir_fd=data_fd)
            try:
                try:
                    os.mkdir("Preferences", mode=0o700, dir_fd=library_fd)
                except FileExistsError:
                    pass
                preferences_fd = os.open("Preferences", flags, dir_fd=library_fd)
                try:
                    name = f"{service}.plist"
                    output_fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                                        0o600, dir_fd=preferences_fd)
                    try:
                        view = memoryview(payload)
                        while view:
                            view = view[os.write(output_fd, view):]
                        os.fsync(output_fd)
                    finally:
                        os.close(output_fd)
                    input_fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=preferences_fd)
                    try:
                        seeded = b""
                        while chunk := os.read(input_fd, 4096):
                            seeded += chunk
                    finally:
                        os.close(input_fd)
                    if seeded != payload:
                        fail("browse preference seed verification failed")
                finally:
                    os.close(preferences_fd)
            finally:
                os.close(library_fd)
        finally:
            os.close(data_fd)
    except (FileNotFoundError, FileExistsError, NotADirectoryError, OSError) as error:
        fail(f"dedicated browse preference seed is incomplete or unsafe: {error}")
    finally:
        os.close(root_fd)
    return hashlib.sha256(payload).hexdigest()


def request_fixture(base_url: str, path: str, *, method: str = "GET") -> dict[str, Any]:
    request = urllib.request.Request(base_url + path, method=method,
                                     headers={"Content-Type": "application/json"},
                                     data=b"" if method == "POST" else None)
    with urllib.request.urlopen(request, timeout=3) as response:
        if response.status != 200:
            fail("fixture control request failed")
        value = json.loads(response.read())
    if not isinstance(value, dict):
        fail("fixture control response is not an object")
    return value


def validate_fixture_identity(ready: dict[str, Any]) -> None:
    if set(ready) != {"schema_version", "base_url", "fixture_id", "fixture_sha256", "user_id"}:
        fail("fixture readiness document has an unexpected shape")
    url = urlsplit(ready["base_url"] if isinstance(ready["base_url"], str) else "")
    if (ready["schema_version"] != 1 or url.scheme != "http" or url.hostname != "127.0.0.1"
            or url.port is None or url.username is not None or url.password is not None
            or url.path not in ("", "/") or url.query or url.fragment):
        fail("fixture readiness document is invalid")
    if (not isinstance(ready["fixture_id"], str)
            or re.fullmatch(r"fixture-[a-f0-9]{12}", ready["fixture_id"]) is None
            or not isinstance(ready["fixture_sha256"], str)
            or re.fullmatch(r"[a-f0-9]{64}", ready["fixture_sha256"]) is None
            or ready["user_id"] != "fixture-user"):
        fail("fixture identity is invalid")


def validate_ledger(ledger: dict[str, Any], ready: dict[str, Any], scenario: str | None = None) -> None:
    required = {"schema_version", "fixture_id", "fixture_sha256", "total", "by_route",
                "by_status", "delayed", "faulted", "in_flight", "max_in_flight",
                "declared_response_bytes", "committed_response_bytes", "write_failures",
                "client_disconnects"}
    if set(ledger) != required or ledger.get("schema_version") != 1:
        fail("fixture ledger has an unexpected shape")
    if (ledger.get("fixture_id"), ledger.get("fixture_sha256")) != (
            ready["fixture_id"], ready["fixture_sha256"]):
        fail("fixture ledger identity changed during capture")
    if ledger.get("in_flight") != 0 or not isinstance(ledger.get("total"), int) or ledger["total"] < 1:
        fail("fixture ledger is incomplete")
    if (ledger.get("faulted") != 0 or ledger.get("write_failures") != 0
            or ledger.get("client_disconnects") != 0):
        fail("fixture ledger records a workload failure")
    if ledger["declared_response_bytes"] != ledger["committed_response_bytes"]:
        fail("fixture ledger records an incomplete response body")
    if any(status != "200" and count for status, count in ledger["by_status"].items()):
        fail("fixture ledger records a non-success response")
    if scenario is not None:
        required_routes = {
            "home": {"authenticate", "views", "resume", "next_up", "latest"},
            "catalog": {"authenticate", "views", "items"},
            "search": {"authenticate", "views", "items"},
            "artwork": {"authenticate", "views", "items", "image"},
        }[scenario]
        missing = sorted(route for route in required_routes if ledger["by_route"].get(route, 0) < 1)
        if missing:
            fail("fixture ledger is missing required scenario routes: " + ", ".join(missing))


def wait_for_stable_zero_ledger(base_url: str, ready: dict[str, Any], scenario: str,
                                executor: Any) -> dict[str, Any]:
    """Require three identical zero-in-flight observations, not one transient zero."""
    previous: dict[str, Any] | None = None
    stable_count = 0
    for _ in range(100):
        current = request_fixture(base_url, "/__fixture__/ledger")
        if current.get("in_flight") == 0:
            validate_ledger(current, ready, scenario)
            stable_count = stable_count + 1 if current == previous else 1
            previous = current
            if stable_count == 3:
                return current
        else:
            previous = None
            stable_count = 0
        executor.sleep(0.1)
    fail("fixture ledger did not reach a stable unchanged zero window")


def wait_for_terminal_span(pid: int, start: str, scenario: str, executor: Any) -> None:
    phase = SCENARIO_PHASES[scenario]
    selector_fields = SCENARIO_SELECTOR_FIELDS[scenario]
    for _ in range(100):
        end = executor.now().replace("+00:00", "Z")
        document = executor.output([
            "/usr/bin/log", "show", "--info", "--style", "ndjson",
            "--start", base.log_time_bound(start), "--end", base.log_time_bound(end, end=True),
            "--process", str(pid),
        ])
        successes = []
        for line in document.splitlines():
            span, _reason = evidence_schema.parse_span_line_diagnostic(line)
            if (span is not None and span.phase == phase and span.backend == "Emby"
                    and all(span.fields.get(key) == value
                            for key, value in selector_fields.items())):
                if span.result == "success":
                    successes.append(span)
                elif span.result not in ALLOWED_TRANSIENT_RESULTS[phase]:
                    fail(f"non-success terminal {phase} span observed for exact app PID")
        if len(successes) > 1:
            fail(f"multiple successful {phase} spans observed for exact app PID")
        if len(successes) == 1:
            return
        executor.sleep(0.1)
    fail(f"terminal {phase} span deadline exceeded for exact app PID")


def write_success_selector_artifact(source: pathlib.Path, destination: pathlib.Path,
                                    phase: str, selector_fields: dict[str, str] | None = None) -> None:
    """Retain the capture binding and one successful target span; preserve the full log separately."""
    selector_fields = selector_fields or {}
    selected: list[str] = []
    binding_count = 0
    success_count = 0
    for line in source.read_text().splitlines(keepends=True):
        binding, binding_reason = evidence_schema.parse_capture_line_diagnostic(line)
        if binding_reason is not None:
            fail("full capture contains a malformed capture binding")
        if binding is not None:
            binding_count += 1
            selected.append(line)
        span, span_reason = evidence_schema.parse_span_line_diagnostic(line)
        if span_reason is not None:
            fail("full capture contains a malformed performance span")
        if (span is not None and span.phase == phase and span.backend == "Emby"
                and all(span.fields.get(key) == value
                        for key, value in selector_fields.items())):
            if span.result == "success":
                success_count += 1
                selected.append(line)
            elif span.result not in ALLOWED_TRANSIENT_RESULTS[phase]:
                fail("full capture contains a non-success target span")
    if binding_count != 1 or success_count != 1:
        fail("success selector requires one capture binding and one successful target span")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
    fd = os.open(destination, flags, 0o600)
    try:
        payload = "".join(selected).encode()
        view = memoryview(payload)
        while view:
            view = view[os.write(fd, view):]
        os.fsync(fd)
    finally:
        os.close(fd)


def plan_for(apps: tuple[Any, Any], service: str, scenario: str, warmups: int, measured: int,
             seed: int, output: pathlib.Path, control_commit: str, candidate_commit: str,
             device_label: str, retention_deadline: str,
             cooldown_seconds: float = 0) -> dict[str, Any]:
    foundation = base.command_plan(
        apps, "launch", warmups, measured, 1, seed, output,
        control_commit=control_commit, candidate_commit=candidate_commit,
        device_label=device_label, retention_deadline=retention_deadline,
    )
    samples = base.schedule(scenario, warmups, measured, seed)
    by_role = {app.role: app for app in apps}
    for ordinal, sample in enumerate(samples, 1):
        app = by_role[sample["role"]]
        sample["commands"] = {
            "container_reset": foundation["samples"][ordinal - 1]["commands"]["reset"],
            "keychain_reset": {"service": service, "accounts": list(AUTH_ACCOUNTS)},
            "preference_seed": {
                "relative_path": f"Data/Library/Preferences/{service}.plist",
                "sha256": hashlib.sha256(preference_seed(service)).hexdigest(),
            },
            "fixture_reset": "POST /__fixture__/reset",
            "launch": ["/usr/bin/open", "-n", "-a", str(app.path)],
            "app_arguments": [], "app_environment": {},
            "driver": ["{precompiled_private_ax_driver}", "--pid", "{exact_pid}",
                       "--workload-spec", "{private_0600_spec}", "--output", "{driver_output}"],
            "fixture_ledger": "GET /__fixture__/ledger",
            "log": ["/usr/bin/log", "show", "--info", "--style", "ndjson", "--start",
                    "{start_epoch_floor}", "--end", "{end_epoch_ceil}", "--process", "{exact_pid}"],
            "terminate": ["SIGTERM", "{exact_pid}"],
        }
    return {
        "schema_version": 1, "mode": "capture",
        "artifact_status": "planned_admissible_per_run_manifests",
        "scenario": scenario, "bundle_id": apps[0].bundle_id, "keychain_service": service,
        "fixture": {"command": [sys.executable, str(FIXTURE), "--ready-file", "{private_ready_file}"],
                    "lifetime": "one_process_per_capture", "bind": "127.0.0.1", "port": "ephemeral"},
        "driver": {"source": str(DRIVER),
                   "preflight_compile": ["/usr/bin/xcrun", "swiftc", str(DRIVER),
                                         "-o", "{precompiled_private_ax_driver}"]},
        "warmups": warmups, "measured": measured, "seed": seed,
        "cooldown_seconds": cooldown_seconds,
        "commits": foundation["commits"], "device_label": device_label,
        "identities": {
            "comparison_id": base.opaque("comparison", seed, control_commit, candidate_commit),
            "workload_id": base.opaque("workload", seed, control_commit, candidate_commit,
                                       f"emby.{scenario}"),
            "scenario_id": base.opaque("scenario", seed, control_commit, candidate_commit,
                                       f"emby.{scenario}"),
            "order_seed": base.opaque("seed", seed, length=16),
        },
        "retention_deadline": retention_deadline, "output": str(output.absolute()),
        "container": foundation["container"],
        "configuration_contract_commands": foundation["configuration_contract_commands"],
        "samples": samples,
    }


def calibration_plan_for(plan: dict[str, Any], output: pathlib.Path,
                         max_storage_drift_bytes: int = 0) -> dict[str, Any]:
    """Build the fixed short-policy control-only collection that precedes paired capture."""
    calibration = copy.deepcopy(plan)
    calibration["mode"] = "calibration_capture"
    calibration["artifact_status"] = "planned_control_only_calibration_manifests"
    calibration["warmups"] = 3
    calibration["measured"] = 20
    calibration["max_free_storage_drift_bytes"] = max_storage_drift_bytes
    calibration["output"] = str(output.absolute())
    calibration["samples"] = [
        sample for sample in base.schedule(plan["scenario"], 3, 20, plan["seed"])
        if sample["role"] == "control"
    ]
    control_commands = next(sample["commands"] for sample in plan["samples"]
                            if sample["role"] == "control")
    for sample in calibration["samples"]:
        sample["commands"] = copy.deepcopy(control_commands)
    calibration["identities"]["comparison_id"] = base.opaque(
        "comparison", "calibration", plan["identities"]["comparison_id"])
    return calibration


def freeze_selector(plan: dict[str, Any]) -> dict[str, Any]:
    phase = SCENARIO_PHASES[plan["scenario"]]
    return {
        "id": plan["identities"]["workload_id"], "phase": phase, "backend": "Emby",
        "fields": SCENARIO_SELECTOR_FIELDS[plan["scenario"]],
        "correctness_fields": list(evidence_schema.REQUIRED_CORRECTNESS_FIELDS[(phase, "Emby")]),
        "expected_span_count": 1, "aggregation": "median",
    }


def wait_ready(path: pathlib.Path, process: Any, executor: Any) -> dict[str, Any]:
    for _ in range(100):
        if executor.poll(process) is not None:
            fail("fixture exited before readiness")
        if path.is_file():
            try:
                ready = json.loads(path.read_text())
                validate_fixture_identity(ready)
                request_fixture(ready["base_url"], "/__fixture__/ledger")
                return ready
            except (OSError, json.JSONDecodeError, urllib.error.URLError):
                pass
        executor.sleep(0.05)
    fail("fixture readiness deadline exceeded")


def write_private_json(path: pathlib.Path, value: dict[str, Any]) -> None:
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
    fd = os.open(path, flags, 0o600)
    try:
        payload = (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()
        view = memoryview(payload)
        while view:
            view = view[os.write(fd, view):]
        os.fsync(fd)
    finally:
        os.close(fd)
    if (path.stat().st_mode & 0o777) != 0o600:
        fail("private workload spec mode is not 0600")


def validate_driver_result(path: pathlib.Path, *, pid: int, scenario: str) -> dict[str, Any]:
    if path.is_symlink() or not path.is_file() or (path.stat().st_mode & 0o077):
        fail("AX driver result is not a private regular file")
    try:
        value = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        fail(f"AX driver did not produce valid JSON: {error}")
    keys = {"schema_version", "tool", "pid", "scenario", "status", "completed_stage",
            "action_count", "elapsed_milliseconds", "error_code"}
    if not isinstance(value, dict) or set(value) != keys:
        fail("AX driver result has an unexpected shape")
    expected_stage = {
        "home": "home_loaded", "catalog": "catalog_loaded",
        "search": "search_loaded", "artwork": "artwork_loaded",
    }[scenario]
    if (value.get("schema_version") != 1 or value.get("tool") != {
            "name": "labstream-macos-ax-driver", "version": 1}
            or value.get("pid") != pid or value.get("scenario") != scenario
            or value.get("status") != "success" or value.get("error_code") is not None
            or value.get("completed_stage") != expected_stage):
        fail("AX driver result does not prove successful exact-PID completion")
    if (not isinstance(value.get("action_count"), int) or value["action_count"] < 1
            or not isinstance(value.get("elapsed_milliseconds"), int)
            or value["elapsed_milliseconds"] < 0):
        fail("AX driver result counters are invalid")
    return value


def safe_driver_failure(path: pathlib.Path, *, pid: int, scenario: str) -> dict[str, Any]:
    """Validate a private failure result while returning only closed, non-sensitive fields."""
    try:
        payload = read_regular_bytes(path, private=True, max_bytes=16_384)
        value = json.loads(payload)
    except (RunnerError, json.JSONDecodeError, UnicodeDecodeError):
        fail("AX driver failed with malformed private result")
    keys = {"schema_version", "tool", "pid", "scenario", "status", "completed_stage",
            "action_count", "elapsed_milliseconds", "error_code"}
    if (not isinstance(value, dict) or set(value) != keys
            or value.get("schema_version") != 1
            or value.get("tool") != {"name": "labstream-macos-ax-driver", "version": 1}
            or value.get("pid") != pid or value.get("scenario") != scenario
            or value.get("status") != "failure"
            or value.get("error_code") not in DRIVER_ERROR_CODES
            or value.get("completed_stage") not in DRIVER_COMPLETED_STAGES
            or type(value.get("action_count")) is not int or value["action_count"] < 0
            or type(value.get("elapsed_milliseconds")) is not int
            or value["elapsed_milliseconds"] < 0):
        fail("AX driver failed with malformed private result")
    return {
        "error_code": value["error_code"],
        "completed_stage": value["completed_stage"],
        "elapsed_milliseconds": value["elapsed_milliseconds"],
    }


def add_record_error(record: dict[str, Any], message: str) -> None:
    record["status"] = "failure"
    record["error"] = f'{record["error"]}; {message}' if record.get("error") else message


def browse_manifest(plan: dict[str, Any], sample: dict[str, Any], app: Any,
                    facts: dict[str, Any], ready: dict[str, Any], recorded_at: str,
                    automation: dict[str, Any]) -> dict[str, Any]:
    run_id = base.opaque("run", plan["identities"]["comparison_id"], sample["role"],
                         sample["sample_kind"], sample["sample_index"], sample["pair_order"])
    pointers = [
        {"path": "raw/artifact-0001.log", "sha256": "0" * 64},
        {"path": "raw/artifact-0002.json", "sha256": "0" * 64},
        {"path": "raw/artifact-0003.json", "sha256": "0" * 64},
        {"path": "raw/artifact-0004.log", "sha256": "0" * 64},
    ]
    return {
        "schema_version": 1,
        "tool": {"name": "labstream-performance-audit", "version": "1"},
        "run": {"id": run_id, "recorded_at": recorded_at,
                "comparison_id": plan["identities"]["comparison_id"],
                "artifact_role": sample["role"], "sample_kind": sample["sample_kind"],
                "sample_index": sample["sample_index"],
                "order_seed": plan["identities"]["order_seed"]},
        "product": {"commit": plan["commits"][sample["role"]],
                    "sha256": base.bundle_sha256(app.path),
                    "configuration": "PerformanceAudit", "target": "LabstreamMac",
                    "platform": "macos", "os_build": facts["os_build"],
                    "xcode_build": facts["xcode_build"]},
        "device": {"label": plan["device_label"], **{key: facts[key] for key in
                   ("power_source", "battery_state", "thermal_state",
                    "free_storage_bytes", "display_mode")}},
        "state": {"install_state": "direct_staged_artifact",
                  "container_state": "restored_fixture",
                  "cache_reset": {"command_id": "app-container-reset-v1", "result": "success"}},
        "scenario": {"id": plan["identities"]["scenario_id"],
                     "category": plan["scenario"], "run_kind": "deterministic_fixture",
                     "fixture_id": ready["fixture_id"],
                     "fixture_sha256": ready["fixture_sha256"], "backend_kind": "emby",
                     "server_version": None, "cache_state": "cold"},
        "automation": automation,
        "launch_contract": {"arguments": [], "environment_keys": [], "ui_test_fixture": False,
                            "live_probe": False, "tv_event_swizzle": False,
                            "verbose_debug_evidence": False},
        "evidence": {"artifacts": pointers,
                     "redacted_summary": {"path": "summary/redacted.json", "sha256": "0" * 64},
                     "privacy_review": "pending", "retention_deadline": plan["retention_deadline"],
                     "publishable": False},
    }


def update_pointer_checksums(manifest: dict[str, Any], run_dir: pathlib.Path) -> None:
    for pointer in manifest["evidence"]["artifacts"]:
        pointer["sha256"] = hashlib.sha256((run_dir / pointer["path"]).read_bytes()).hexdigest()


def write_manifest(path: pathlib.Path, manifest: dict[str, Any]) -> None:
    path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")


def write_durable_json_exclusive(path: pathlib.Path, value: Any) -> tuple[int, int]:
    """Atomically publish durable JSON without following links or replacing prior evidence."""
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    temporary = pathlib.Path(temporary_name)
    published_identity: tuple[int, int] | None = None
    try:
        payload = (json.dumps(value, indent=2, sort_keys=True) + "\n").encode()
        view = memoryview(payload)
        while view:
            view = view[os.write(fd, view):]
        os.fsync(fd)
        os.close(fd)
        fd = -1
        # Link publication is atomic and fails if another file or symlink appeared after
        # preflight; os.replace() would silently overwrite that newly created evidence.
        os.link(temporary, path, follow_symlinks=False)
        observed = path.stat(follow_symlinks=False)
        published_identity = (observed.st_dev, observed.st_ino)
        temporary.unlink()
        directory_fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        if fd >= 0:
            os.close(fd)
        temporary.unlink(missing_ok=True)
    assert published_identity is not None
    return published_identity


def write_private_json_atomic(path: pathlib.Path, value: Any) -> None:
    """Durably replace runner-private state while refusing link-shaped destinations."""
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_symlink() or (path.exists() and not path.is_file()):
        fail(f"private state path is unsafe: {path}")
    fd, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    temporary = pathlib.Path(temporary_name)
    try:
        os.fchmod(fd, 0o600)
        payload = (json.dumps(value, indent=2, sort_keys=True) + "\n").encode()
        view = memoryview(payload)
        while view:
            view = view[os.write(fd, view):]
        os.fsync(fd)
        os.close(fd)
        fd = -1
        os.replace(temporary, path)
        directory_fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        if fd >= 0:
            os.close(fd)
        temporary.unlink(missing_ok=True)


def read_regular_bytes(path: pathlib.Path, *, private: bool = False,
                       max_bytes: int | None = None) -> bytes:
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except OSError as error:
        fail(f"regular file is missing or unsafe: {path}: {error}")
    try:
        metadata = os.fstat(fd)
        if not stat.S_ISREG(metadata.st_mode) or (private and metadata.st_mode & 0o077):
            fail(f"regular file has unsafe type or permissions: {path}")
        if max_bytes is not None and metadata.st_size > max_bytes:
            fail(f"regular file exceeds its size bound: {path}")
        chunks = []
        total = 0
        while True:
            remaining = (max_bytes - total + 1) if max_bytes is not None else 1024 * 1024
            chunk = os.read(fd, min(1024 * 1024, remaining))
            if not chunk:
                return b"".join(chunks)
            total += len(chunk)
            if max_bytes is not None and total > max_bytes:
                fail(f"regular file exceeds its size bound: {path}")
            chunks.append(chunk)
    finally:
        os.close(fd)


def read_private_json(path: pathlib.Path) -> Any:
    try:
        return json.loads(read_regular_bytes(path, private=True))
    except json.JSONDecodeError as error:
        fail(f"private state is unreadable: {error}")


def decode_json_bytes(payload: bytes, label: str) -> Any:
    try:
        return json.loads(payload)
    except json.JSONDecodeError as error:
        fail(f"{label} is unreadable: {error}")


def canonical_sha256(value: Any) -> str:
    return hashlib.sha256(json.dumps(
        value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def private_json_sha256(value: Any) -> str:
    payload = (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()
    return hashlib.sha256(payload).hexdigest()


def discard_private_directory(path: pathlib.Path) -> None:
    if path.is_symlink():
        fail(f"private pending path is a symlink: {path}")
    if path.exists():
        if not path.is_dir():
            fail(f"private pending path is not a directory: {path}")
        shutil.rmtree(path)
        fsync_directory(path.parent)


def fsync_directory(path: pathlib.Path) -> None:
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def fsync_evidence_tree(path: pathlib.Path) -> None:
    if path.is_symlink() or not path.is_dir():
        fail(f"evidence tree is missing or unsafe: {path}")
    directories: list[pathlib.Path] = []
    for root, names, files in os.walk(path, topdown=True, followlinks=False):
        root_path = pathlib.Path(root)
        directories.append(root_path)
        for name in [*names, *files]:
            child = root_path / name
            if child.is_symlink():
                fail(f"evidence tree contains a symlink: {child}")
        for name in files:
            fd = os.open(root_path / name, os.O_RDONLY | os.O_NOFOLLOW)
            try:
                if not stat.S_ISREG(os.fstat(fd).st_mode):
                    fail(f"evidence tree contains a non-regular file: {root_path / name}")
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


def require_exact_manifest_path(raw_root: pathlib.Path, manifest: pathlib.Path,
                                expected: pathlib.Path) -> None:
    if manifest.absolute() != expected.absolute():
        fail("resume state manifest path does not match its schedule slot")
    root = raw_root.absolute()
    if root.is_symlink() or not root.is_dir():
        fail("resume raw root is missing or unsafe")
    try:
        relative_parent = expected.absolute().parent.relative_to(root)
    except ValueError:
        fail("resume manifest escapes its raw root")
    current = root
    for component in relative_parent.parts:
        current /= component
        if current.is_symlink() or not current.is_dir():
            fail("resume manifest has an unsafe directory ancestor")


def validate_calibration_covariates(samples: list[Any], max_storage_drift_bytes: int) -> None:
    devices = [sample.manifest["device"] for sample in samples]
    if {device["power_source"] for device in devices} != {"external"}:
        fail("control-only calibration requires stable external power")
    if len({device["battery_state"] for device in devices}) != 1:
        fail("control-only calibration requires a stable battery state")
    thermal_states = {device["thermal_state"] for device in devices}
    if len(thermal_states) != 1 or not thermal_states <= {"nominal", "fair"}:
        fail("control-only calibration requires one stable supported thermal state")
    storage = [device["free_storage_bytes"] for device in devices]
    if max(storage) - min(storage) > max_storage_drift_bytes:
        fail("control-only calibration exceeds its free-storage drift tolerance")


def freeze_calibration(plan: dict[str, Any], records: list[dict[str, Any]],
                       destination: pathlib.Path) -> str:
    try:
        artifact = frozen_artifact_for(plan, records)
        write_durable_json_exclusive(destination, artifact)
        digest = hashlib.sha256(destination.read_bytes()).hexdigest()
        compare.load_frozen(destination, digest)
        return digest
    except (compare.CompareError, OSError) as error:
        fail(f"control-only MDE freeze failed: {error}")


def calibration_result_for(plan: dict[str, Any], records: list[dict[str, Any]],
                           *, stateful: bool) -> dict[str, Any]:
    return {
        "schema_version": 1, "capture_status": "success",
        "artifact_status": "admissible_control_only_calibration_manifests",
        "scenario": plan["scenario"],
        "fixture_lifecycle": ("restarted_on_pinned_port" if stateful else
                              "shared_with_paired_capture"),
        "cooldown_seconds": plan["cooldown_seconds"],
        "max_free_storage_drift_bytes": plan["max_free_storage_drift_bytes"],
        "records": records,
    }


def frozen_artifact_for(plan: dict[str, Any], records: list[dict[str, Any]]) -> dict[str, Any]:
    manifests = [pathlib.Path(record["manifest"]) for record in records]
    samples = [compare.load_sample(path, "control") for path in manifests]
    validate_calibration_covariates(samples, plan["max_free_storage_drift_bytes"])
    return compare.freeze_control(samples, selector=freeze_selector(plan), sample_policy="short")


def calibration_reference(records: list[dict[str, Any]]) -> Any:
    if not records:
        fail("paired capture requires retained calibration evidence")
    return compare.load_sample(pathlib.Path(records[0]["manifest"]), "control")


def validate_current_calibration_environment(reference: Any, plan: dict[str, Any],
                                             ready: dict[str, Any], driver_sha256: str,
                                             fixture_sha256: str, executor: Any) -> None:
    facts = base.host_facts(executor, pathlib.Path(plan["container"]).parent)
    manifest = reference.manifest
    if (manifest["product"]["os_build"] != facts["os_build"]
            or manifest["product"]["xcode_build"] != facts["xcode_build"]
            or manifest["device"]["display_mode"] != facts["display_mode"]):
        fail("current host environment no longer matches calibration")
    if (manifest["scenario"]["fixture_id"] != ready["fixture_id"]
            or manifest["scenario"]["fixture_sha256"] != ready["fixture_sha256"]):
        fail("current fixture environment no longer matches calibration")
    expected_spec = {
        "schema_version": 1, "scenario": plan["scenario"], "base_url": ready["base_url"],
        "username": FIXTURE_USERNAME, "password": FIXTURE_PASSWORD, "timeout_seconds": 30,
    }
    expected_automation = {
        "fixture_implementation_sha256": fixture_sha256,
        "driver_sha256": driver_sha256,
        "workload_spec_sha256": private_json_sha256(expected_spec),
        "client_state_seed_sha256": hashlib.sha256(
            preference_seed(plan["keychain_service"])).hexdigest(),
        "fixture_protocol_version": int(ready["schema_version"]),
        "driver_protocol_version": 1,
    }
    if manifest.get("automation") != expected_automation:
        fail("current automation environment no longer matches calibration")


def validate_pending_pair_environment(records: list[dict[str, Any]], reference: Any,
                                      previous_record: dict[str, Any] | None = None) -> None:
    samples = [compare.load_sample(pathlib.Path(record["manifest"]), record["role"])
               for record in records]
    reference_environment = compare._environment_fingerprint(reference)
    if any(compare._environment_fingerprint(sample) != reference_environment
           for sample in samples):
        fail("pending pair environment does not match frozen calibration")
    if not samples[0].recorded_at < samples[1].recorded_at:
        fail("pending pair is not in strict chronological order")
    if previous_record is not None:
        previous = compare.load_sample(
            pathlib.Path(previous_record["manifest"]), previous_record["role"])
        if not previous.recorded_at < samples[0].recorded_at:
            fail("pending pair does not follow retained evidence chronologically")


def validate_retained_pair_chronology(records: list[dict[str, Any]]) -> None:
    seen_measured = False
    previous = None
    for offset in range(0, len(records), 2):
        pair = [compare.load_sample(pathlib.Path(record["manifest"]), record["role"])
                for record in records[offset:offset + 2]]
        if len(pair) != 2 or not pair[0].recorded_at < pair[1].recorded_at:
            fail("retained pair is not in strict chronological order")
        if previous is not None and not previous.recorded_at < pair[0].recorded_at:
            fail("retained pairs are not in one strict chronological sequence")
        if pair[0].kind == "measured":
            seen_measured = True
        elif seen_measured:
            fail("retained warmup pair follows measured evidence")
        previous = pair[1]


def validate_checkpointed_calibration_artifacts(
        state: dict[str, Any], plan: dict[str, Any], calibration_output: pathlib.Path,
        frozen_mde_output: pathlib.Path, *, require_complete: bool) -> None:
    records = state["calibration_records"]
    if require_complete and (state["calibration_output_sha256"] is None
                             or state["frozen_mde_sha256"] is None):
        fail("published result is missing its calibration artifacts")
    if state["calibration_output_sha256"] is not None:
        actual = read_regular_bytes(calibration_output)
        expected = (json.dumps(calibration_result_for(plan, records, stateful=True),
                               indent=2, sort_keys=True) + "\n").encode()
        if (actual != expected or hashlib.sha256(actual).hexdigest()
                != state["calibration_output_sha256"]):
            fail("checkpointed calibration output does not match retained evidence")
    if state["frozen_mde_sha256"] is not None:
        actual = read_regular_bytes(frozen_mde_output)
        expected = frozen_artifact_for(plan, records)
        if (decode_json_bytes(actual, "checkpointed frozen MDE") != expected
                or hashlib.sha256(actual).hexdigest()
                != state["frozen_mde_sha256"]):
            fail("checkpointed frozen MDE does not match retained evidence")
        compare.load_frozen(frozen_mde_output, state["frozen_mde_sha256"])


def resume_identity(plan: dict[str, Any], calibration_plan: dict[str, Any],
                    apps: tuple[Any, Any], calibration_output: pathlib.Path,
                    frozen_mde_output: pathlib.Path, fixture_port: int) -> dict[str, Any]:
    """Identity contract that must remain byte-for-byte stable across processes."""
    return {
        "schema_version": 1,
        "paired_plan": plan,
        "calibration_plan": calibration_plan,
        "apps": [{
            "role": app.role, "path": str(app.path), "executable": str(app.executable),
            "bundle_sha256": base.bundle_sha256(app.path),
        } for app in apps],
        "sources": {
            "driver_sha256": hashlib.sha256(DRIVER.read_bytes()).hexdigest(),
            "fixture_sha256": hashlib.sha256(FIXTURE.read_bytes()).hexdigest(),
            "client_state_seed_sha256": hashlib.sha256(
                preference_seed(plan["keychain_service"])).hexdigest(),
        },
        "outputs": {
            "paired": plan["output"], "calibration": str(calibration_output.absolute()),
            "frozen_mde": str(frozen_mde_output.absolute()),
        },
        "fixture_port": fixture_port,
    }


def validate_paired_schedule(samples: list[dict[str, Any]]) -> None:
    if not samples or len(samples) % 2:
        fail("paired schedule must contain complete two-arm pairs")
    for offset in range(0, len(samples), 2):
        first, second = samples[offset:offset + 2]
        if (first["sample_kind"] != second["sample_kind"]
                or first["sample_index"] != second["sample_index"]
                or [first["pair_order"], second["pair_order"]] != [1, 2]
                or {first["role"], second["role"]} != {"control", "candidate"}):
            fail("paired schedule contains a malformed adjacent pair")


RESUME_STATE_KEYS = {"schema_version", "plan_sha256", "driver_sha256",
                     "calibration_records", "paired_records", "calibration_output_sha256",
                     "frozen_mde_sha256"}


def validate_resume_state_transition(state: dict[str, Any], calibration_count: int,
                                     paired_count: int) -> None:
    if not isinstance(state, dict) or set(state) != RESUME_STATE_KEYS or state.get(
            "schema_version") != 1:
        fail("resume state has an unexpected shape")
    calibration_records, paired_records = state.get("calibration_records"), state.get(
        "paired_records")
    if (not isinstance(calibration_records, list) or len(calibration_records) > calibration_count
            or not isinstance(paired_records, list) or len(paired_records) > paired_count
            or len(paired_records) % 2):
        fail("resume state record cardinality is invalid")
    for key in ("calibration_output_sha256", "frozen_mde_sha256"):
        value = state.get(key)
        if value is not None and (not isinstance(value, str)
                                  or re.fullmatch(r"[a-f0-9]{64}", value) is None):
            fail("resume state contains an invalid artifact digest")
    calibration_complete = len(calibration_records) == calibration_count
    calibration_digest = state["calibration_output_sha256"]
    frozen_digest = state["frozen_mde_sha256"]
    if not calibration_complete and (calibration_digest is not None or frozen_digest is not None
                                     or paired_records):
        fail("resume state advanced before calibration completed")
    if frozen_digest is not None and calibration_digest is None:
        fail("resume state froze MDE before checkpointing calibration output")
    if paired_records and (calibration_digest is None or frozen_digest is None):
        fail("resume state contains pairs before the calibration freeze boundary")


def cleared_active_app() -> dict[str, Any]:
    return {"schema_version": 1, "status": "cleared"}


def launching_active_app(app: Any) -> dict[str, Any]:
    return {"schema_version": 1, "status": "launching", "role": app.role,
            "executable": str(app.executable), "bundle_id": app.bundle_id}


def cleanup_checkpointed_active_app(path: pathlib.Path, apps: tuple[Any, Any],
                                    executor: Any) -> None:
    document = read_private_json(path)
    if document == cleared_active_app():
        return
    by_role = {app.role: app for app in apps}
    if isinstance(document, dict) and document.get("status") == "launching":
        if set(document) != {"schema_version", "status", "role", "executable", "bundle_id"}:
            fail("launching app checkpoint is invalid")
        app = by_role.get(document.get("role"))
        if (app is None or document.get("schema_version") != 1
                or document.get("executable") != str(app.executable)
                or document.get("bundle_id") != app.bundle_id):
            fail("launching app checkpoint identity drift detected")
        # LaunchServices can publish its detached child after the runner has already died.
        # Observe the same primary+grace window as launch discovery, including a final boundary
        # scan. An unbound arrival is deliberately not signaled: without the callback's PID/start
        # provenance it could be a later manual launch from the same staged executable.
        pids: set[int] = set()
        for _ in range(120):
            pids.update(exact_executable_pids(app.executable, executor))
            if pids:
                break
            executor.sleep(0.05)
        pids.update(exact_executable_pids(app.executable, executor))
        if pids:
            fail("unbound LaunchServices app requires explicit operator cleanup before resume")
        write_private_json_atomic(path, cleared_active_app())
        return
    expected_keys = {"schema_version", "status", "pid", "role", "executable", "bundle_id",
                     "start_identity"}
    if (not isinstance(document, dict) or set(document) != expected_keys
            or document.get("schema_version") != 1 or document.get("status") != "active"
            or type(document.get("pid")) is not int or document["pid"] <= 1):
        fail("active app checkpoint is invalid")
    app = by_role.get(document["role"])
    if (app is None or document["executable"] != str(app.executable)
            or document["bundle_id"] != app.bundle_id
            or not isinstance(document["start_identity"], str)):
        fail("active app checkpoint identity drift detected")
    process = DetachedAppProcess(
        document["pid"], app.executable, document["start_identity"])
    error = stop_app_and_prove_gone(process, executor)
    if error:
        fail(f"could not clean checkpointed app before resume: {error}")
    write_private_json_atomic(path, cleared_active_app())


def validate_resume_records(records: list[dict[str, Any]], expected_samples: list[dict[str, Any]],
                            raw_root: pathlib.Path, plan: dict[str, Any],
                            driver_sha256: str, fixture_port: int, *, paired: bool) -> tuple[
                                set[str], set[str]]:
    expected_count = len(expected_samples)
    if not isinstance(records, list) or len(records) > expected_count:
        fail("resume state record count is invalid")
    run_ids: set[str] = set()
    launch_nonces: set[str] = set()
    for ordinal, record in enumerate(records):
        if (record.get("status") != "success" or not isinstance(record.get("manifest"), str)
                or not isinstance(record.get("manifest_sha256"), str)
                or not re.fullmatch(r"[a-f0-9]{64}", record["manifest_sha256"])):
            fail("resume state contains a non-success record")
        sample = expected_samples[ordinal]
        for key in ("scenario", "sample_kind", "sample_index", "pair_order", "role"):
            if record.get(key) != sample[key]:
                fail("resume state record ordering drift detected")
        manifest_path = pathlib.Path(record["manifest"])
        expected_manifest = (raw_root / f"pair-{ordinal // 2 + 1:04d}" /
                             f"arm-{ordinal % 2 + 1}" / "manifest.json" if paired else
                             raw_root / f"sample-{ordinal + 1:04d}" / "manifest.json")
        require_exact_manifest_path(raw_root, manifest_path, expected_manifest)
        manifest_bytes = read_regular_bytes(manifest_path)
        if hashlib.sha256(manifest_bytes).hexdigest() != record["manifest_sha256"]:
            fail("resume state manifest checksum drift detected")
        try:
            loaded = compare.load_sample(manifest_path, sample["role"])
            document = loaded.manifest
            run_id = document["run"]["id"]
        except compare.CompareError as error:
            fail(f"resume state manifest contract failed: {error}")
        if (loaded.kind != sample["sample_kind"] or loaded.index != sample["sample_index"]
                or document["run"]["comparison_id"] != plan["identities"]["comparison_id"]
                or document["run"]["order_seed"] != plan["identities"]["order_seed"]
                or document["scenario"]["id"] != plan["identities"]["scenario_id"]
                or loaded.workload["id"] != plan["identities"]["workload_id"]):
            fail("resume state manifest binding drift detected")
        if run_id in run_ids:
            fail("resume state contains duplicate run IDs")
        run_ids.add(run_id)
        nonce = loaded.capture_binding["launch_nonce"]
        if nonce in launch_nonces:
            fail("resume state contains duplicate launch nonces")
        launch_nonces.add(nonce)
        expected_spec = {
            "schema_version": 1, "scenario": plan["scenario"],
            "base_url": f"http://127.0.0.1:{fixture_port}", "username": FIXTURE_USERNAME,
            "password": FIXTURE_PASSWORD, "timeout_seconds": 30,
        }
        automation = document.get("automation", {})
        if (document.get("product", {}).get("commit") != plan["commits"][sample["role"]]
                or automation.get("driver_sha256") != driver_sha256
                or automation.get("fixture_implementation_sha256") !=
                hashlib.sha256(FIXTURE.read_bytes()).hexdigest()
                or automation.get("client_state_seed_sha256") != hashlib.sha256(
                    preference_seed(plan["keychain_service"])).hexdigest()
                or automation.get("workload_spec_sha256") != private_json_sha256(expected_spec)):
            fail("resume evidence identity drift detected")
    return run_ids, launch_nonces


def capture_sample(active_plan: dict[str, Any], sample: dict[str, Any], app: Any,
                   run_dir: pathlib.Path, ready: dict[str, Any], driver_binary: pathlib.Path,
                   driver_binary_sha256: str, fixture_source_sha256: str,
                   executor: Any, active_app_path: pathlib.Path | None = None) -> dict[str, Any]:
    record = {key: sample[key] for key in
              ("scenario", "sample_kind", "sample_index", "pair_order", "role")}
    app_process = None
    spec_path = run_dir / ".workload-spec.json"
    raw_dir = run_dir / "raw"
    summary_dir = run_dir / "summary"
    run_dir.mkdir(mode=0o700)
    raw_dir.mkdir()
    summary_dir.mkdir()
    manifest_path = run_dir / "manifest.json"
    post_reset_done = False
    try:
        base.seed_container(pathlib.Path(active_plan["container"]), executor)
        preference_seed_sha256 = seed_browse_preferences(
            pathlib.Path(active_plan["container"]), active_plan["keychain_service"])
        reset_performance_keychain(active_plan["keychain_service"], executor)
        reset = request_fixture(ready["base_url"], "/__fixture__/reset", method="POST")
        if reset != {"reset": True}:
            fail("fixture reset was not acknowledged")
        facts = base.host_facts(executor, pathlib.Path(active_plan["container"]).parent)
        start = executor.now().replace("+00:00", "Z")
        workload_spec = {
            "schema_version": 1, "scenario": active_plan["scenario"],
            "base_url": ready["base_url"], "username": FIXTURE_USERNAME,
            "password": FIXTURE_PASSWORD, "timeout_seconds": 30,
        }
        write_private_json(spec_path, workload_spec)
        automation = {
            "fixture_implementation_sha256": fixture_source_sha256,
            "driver_sha256": driver_binary_sha256,
            "workload_spec_sha256": hashlib.sha256(spec_path.read_bytes()).hexdigest(),
            "client_state_seed_sha256": preference_seed_sha256,
            "fixture_protocol_version": int(ready["schema_version"]),
            "driver_protocol_version": 1,
        }
        manifest = browse_manifest(active_plan, sample, app, facts, ready, start, automation)
        write_manifest(manifest_path, manifest)
        raw_log = raw_dir / "artifact-0001.log"
        nonce = base.opaque("nonce", manifest["run"]["id"],
                            active_plan["identities"]["workload_id"], length=16)
        with raw_log.open("wb") as output:
            executor.run([sys.executable, str(SUMMARY), "--emit-capture-marker",
                          "--manifest", str(manifest_path), "--workload-id",
                          active_plan["identities"]["workload_id"], "--launch-nonce", nonce],
                         stdout=output)
        def checkpoint_bound_process(process: DetachedAppProcess) -> None:
            if active_app_path is None:
                return
            start_identity = process_start_identity(process.pid, executor)
            process.start_identity = start_identity
            write_private_json_atomic(active_app_path, {
                "schema_version": 1, "status": "active", "pid": process.pid,
                "role": app.role, "executable": str(app.executable),
                "bundle_id": app.bundle_id, "start_identity": start_identity,
            })

        if active_app_path is not None:
            base.preflight_no_existing_app((app, app), executor)
            write_private_json_atomic(active_app_path, launching_active_app(app))
        app_process = launch_app(app, executor, checkpoint_bound_process)
        pid = int(app_process.pid)
        record["pid"] = pid
        if executor.poll(app_process) is not None:
            fail(f"app PID {pid} exited at launch")
        driver_output = raw_dir / "artifact-0002.json"
        try:
            executor.run([str(driver_binary), "--pid", str(pid),
                          "--workload-spec", str(spec_path), "--output", str(driver_output)])
        except subprocess.CalledProcessError:
            driver_failure = safe_driver_failure(
                driver_output, pid=pid, scenario=active_plan["scenario"])
            record["driver_failure"] = driver_failure
            fail("AX driver failed: " + " ".join(
                f"{key}={driver_failure[key]}" for key in
                ("error_code", "completed_stage", "elapsed_milliseconds")))
        validate_driver_result(driver_output, pid=pid, scenario=active_plan["scenario"])
        if executor.poll(app_process) is not None:
            fail(f"app PID {pid} exited during AX workload")
        wait_for_terminal_span(pid, start, active_plan["scenario"], executor)
        stable_ledger = wait_for_stable_zero_ledger(
            ready["base_url"], ready, active_plan["scenario"], executor)
        end = executor.now().replace("+00:00", "Z")
        with raw_log.open("ab") as log:
            executor.run(["/usr/bin/log", "show", "--info", "--style", "ndjson",
                          "--start", base.log_time_bound(start), "--end",
                          base.log_time_bound(end, end=True), "--process", str(pid)], stdout=log)
        cleanup = stop_app_and_prove_gone(app_process, executor)
        if cleanup:
            fail(cleanup)
        app_process = None
        if active_app_path is not None:
            write_private_json_atomic(active_app_path, cleared_active_app())
        ledger = request_fixture(ready["base_url"], "/__fixture__/ledger")
        validate_ledger(ledger, ready, active_plan["scenario"])
        if ledger != stable_ledger:
            fail("fixture ledger changed after the stable-zero process boundary")
        reset_performance_keychain(active_plan["keychain_service"], executor)
        post_reset_done = True
        (raw_dir / "artifact-0003.json").write_text(
            json.dumps(ledger, indent=2, sort_keys=True) + "\n")
        phase = SCENARIO_PHASES[active_plan["scenario"]]
        selected_log = raw_dir / "artifact-0004.log"
        write_success_selector_artifact(
            raw_log, selected_log, phase,
            SCENARIO_SELECTOR_FIELDS[active_plan["scenario"]])
        update_pointer_checksums(manifest, run_dir)
        write_manifest(manifest_path, manifest)
        summary_path = summary_dir / "redacted.json"
        summary_command = [sys.executable, str(SUMMARY), "--json", "--strict",
                           "--manifest", str(manifest_path), "--raw-artifact", str(selected_log),
                           "--workload-id", active_plan["identities"]["workload_id"],
                           "--phase", phase, "--backend", "Emby", "--expected-span-count", "1"]
        for key, value in SCENARIO_SELECTOR_FIELDS[active_plan["scenario"]].items():
            summary_command += ["--field", f"{key}={value}"]
        for field in evidence_schema.REQUIRED_CORRECTNESS_FIELDS[(phase, "Emby")]:
            summary_command += ["--correctness-field", field]
        with summary_path.open("wb") as output:
            executor.run(summary_command, stdout=output)
        manifest["evidence"]["redacted_summary"]["sha256"] = hashlib.sha256(
            summary_path.read_bytes()).hexdigest()
        write_manifest(manifest_path, manifest)
        executor.run([sys.executable, str(CONTRACT), "manifest", str(manifest_path)])
        record.update(status="success", raw_directory=str(run_dir), manifest=str(manifest_path))
    except Exception as error:
        manifest_path.unlink(missing_ok=True)
        add_record_error(record, str(error))
    finally:
        spec_path.unlink(missing_ok=True)
        if app_process is not None:
            cleanup = stop_app_and_prove_gone(app_process, executor)
            if cleanup:
                add_record_error(record, cleanup)
            elif active_app_path is not None:
                write_private_json_atomic(active_app_path, cleared_active_app())
        elif active_app_path is not None:
            try:
                cleanup_checkpointed_active_app(active_app_path, (app,), executor)
            except Exception as error:
                add_record_error(record, f"active app checkpoint cleanup failed: {error}")
        if not post_reset_done:
            try:
                reset_performance_keychain(active_plan["keychain_service"], executor)
            except Exception as error:
                add_record_error(record, f"post-stop Keychain reset failed: {error}")
    return record


def capture(plan: dict[str, Any], apps: tuple[Any, Any], executor: Any,
            *, calibration_plan: dict[str, Any] | None = None,
            calibration_output: pathlib.Path | None = None,
            frozen_mde_output: pathlib.Path | None = None,
            resume: bool = False, fixture_port: int = 0) -> dict[str, Any]:
    if not resume:
        base.preflight_no_existing_app(apps, executor)
    validate_paired_schedule(plan["samples"])
    for command in plan["configuration_contract_commands"]:
        executor.run(command)
    if calibration_plan is None:
        if resume or fixture_port:
            fail("resume and pinned fixture ports require integrated calibration")
        # Ordinary captures remain intentionally one-shot.
        stages = [plan]
    else:
        if calibration_output is None or frozen_mde_output is None:
            fail("integrated calibration requires calibration and frozen-MDE output paths")
        stages = [calibration_plan, plan]
        if resume and fixture_port == 0:
            fail("--resume requires a nonzero --fixture-port")
    raw_roots = [pathlib.Path(stage["output"]).parent /
                 f"{pathlib.Path(stage['output']).stem}-raw" for stage in stages]
    raw_root = raw_roots[-1]
    driver_binary = raw_root / ".perf-macos-ax-driver"
    fixture_source_sha256 = hashlib.sha256(FIXTURE.read_bytes()).hexdigest()
    stateful = calibration_plan is not None and fixture_port != 0
    plan_path = raw_root / ".resume-plan.json"
    state_path = raw_root / ".resume-state.json"
    active_app_path = raw_root / ".active-app.json"
    state: dict[str, Any]
    if stateful:
        identity = resume_identity(plan, calibration_plan, apps, calibration_output,
                                   frozen_mde_output, fixture_port)
        identity_digest = canonical_sha256(identity)
        if resume:
            stored_identity = read_private_json(plan_path)
            if stored_identity != identity:
                fail("resume plan identity drift detected")
            state = read_private_json(state_path)
            if state.get("schema_version") != 1 or state.get("plan_sha256") != identity_digest:
                fail("resume state does not match the pinned plan")
            validate_resume_state_transition(
                state, len(calibration_plan["samples"]), len(plan["samples"]))
            driver_binary_sha256 = hashlib.sha256(
                read_regular_bytes(driver_binary, private=True)).hexdigest()
            if state.get("driver_sha256") != driver_binary_sha256:
                fail("retained AX driver checksum drift detected")
            calibration_ids, calibration_nonces = validate_resume_records(
                state.get("calibration_records"), calibration_plan["samples"], raw_roots[0],
                calibration_plan, driver_binary_sha256, fixture_port, paired=False)
            paired_ids, paired_nonces = validate_resume_records(
                state.get("paired_records"), plan["samples"], raw_root,
                plan, driver_binary_sha256, fixture_port, paired=True)
            if calibration_ids & paired_ids or calibration_nonces & paired_nonces:
                fail("resume evidence identities are not globally unique")
            validate_retained_pair_chronology(state["paired_records"])
            cleanup_checkpointed_active_app(active_app_path, apps, executor)
            # A process can die after an atomic directory publication but before its state
            # checkpoint. Such an uncheckpointed whole sample/pair is not accepted evidence;
            # validate the complete inventory before deleting only the exact next slot.
            cleanup_paths: list[pathlib.Path] = []
            calibration_completed = len(state["calibration_records"])
            for path in list(raw_roots[0].glob("sample-*")):
                try:
                    ordinal = int(path.name.removeprefix("sample-"))
                except ValueError:
                    fail("unexpected calibration sample path in resume root")
                if (calibration_completed < len(calibration_plan["samples"])
                        and ordinal == calibration_completed + 1):
                    cleanup_paths.append(path)
                elif not 1 <= ordinal <= calibration_completed:
                    fail("unexpected calibration sample ordinal in resume root")
            paired_completed = len(state["paired_records"]) // 2
            for path in list(raw_root.glob("pair-*")):
                try:
                    pair_index = int(path.name.removeprefix("pair-"))
                except ValueError:
                    fail("unexpected paired path in resume root")
                if (paired_completed < len(plan["samples"]) // 2
                        and pair_index == paired_completed + 1):
                    cleanup_paths.append(path)
                elif not 1 <= pair_index <= paired_completed:
                    fail("unexpected paired ordinal in resume root")
            allowed_pending = set()
            if calibration_completed < len(calibration_plan["samples"]):
                allowed_pending.add(
                    raw_roots[0] / f".pending-sample-{calibration_completed + 1:04d}")
            if paired_completed < len(plan["samples"]) // 2:
                allowed_pending.add(raw_root / f".pending-pair-{paired_completed + 1:04d}")
            for root in raw_roots:
                for path in list(root.glob(".pending-*")):
                    if path not in allowed_pending:
                        fail("unexpected pending path in resume root")
                    cleanup_paths.append(path)
            if (sum(path.parent == raw_roots[0] for path in cleanup_paths) > 1
                    or sum(path.parent == raw_root for path in cleanup_paths) > 1):
                fail("resume root contains multiple uncheckpointed slots")
            for path in cleanup_paths:
                discard_private_directory(path)
            validate_checkpointed_calibration_artifacts(
                state, calibration_plan, calibration_output, frozen_mde_output,
                require_complete=bool(state["paired_records"]))
        else:
            for root in raw_roots:
                root.mkdir(parents=True, exist_ok=False)
            executor.run(["/usr/bin/xcrun", "swiftc", str(DRIVER), "-o", str(driver_binary)])
            driver_binary.chmod(0o700)
            if not driver_binary.is_file() or driver_binary.is_symlink():
                fail("AX driver preflight did not produce a private regular executable")
            driver_binary_sha256 = hashlib.sha256(driver_binary.read_bytes()).hexdigest()
            write_private_json_atomic(plan_path, identity)
            state = {"schema_version": 1, "plan_sha256": identity_digest,
                     "driver_sha256": driver_binary_sha256, "calibration_records": [],
                     "paired_records": [], "calibration_output_sha256": None,
                     "frozen_mde_sha256": None}
            write_private_json_atomic(state_path, state)
            write_private_json_atomic(active_app_path, cleared_active_app())
    else:
        for root in raw_roots:
            root.mkdir(parents=True, exist_ok=calibration_plan is None)
        if driver_binary.exists() or driver_binary.is_symlink():
            fail("private AX driver output already exists")
        executor.run(["/usr/bin/xcrun", "swiftc", str(DRIVER), "-o", str(driver_binary)])
        driver_binary.chmod(0o700)
        if not driver_binary.is_file() or driver_binary.is_symlink():
            fail("AX driver preflight did not produce a private regular executable")
        driver_binary_sha256 = hashlib.sha256(driver_binary.read_bytes()).hexdigest()
        state = {"calibration_records": [], "paired_records": [],
                 "calibration_output_sha256": None, "frozen_mde_sha256": None}

    if resume:
        base.preflight_no_existing_app(apps, executor)

    ready_path = raw_root / ".fixture-ready.json"
    ready_path.unlink(missing_ok=True)
    fixture_command = [sys.executable, str(FIXTURE), "--ready-file", str(ready_path),
                       "--parent-pid", str(os.getpid())]
    if fixture_port:
        fixture_command += ["--port", str(fixture_port)]
    try:
        fixture = executor.spawn(fixture_command)
    except BaseException:
        if not stateful:
            driver_binary.unlink(missing_ok=True)
        raise
    fixture_error = None
    by_role = {app.role: app for app in apps}
    failure_record: dict[str, Any] | None = None
    try:
        ready = wait_ready(ready_path, fixture, executor)
        if fixture_port and urlsplit(ready["base_url"]).port != fixture_port:
            fail("fixture did not bind the pinned resume port")
        # Calibration checkpoints one accepted sample at a time. Cooldown is before the next
        # sample, so interruption during it deliberately causes the whole cooldown to repeat.
        if calibration_plan is not None:
            completed = len(state["calibration_records"])
            for ordinal in range(completed + 1, len(calibration_plan["samples"]) + 1):
                if ordinal > 1 and calibration_plan["cooldown_seconds"] > 0:
                    executor.sleep(calibration_plan["cooldown_seconds"])
                pending = raw_roots[0] / f".pending-sample-{ordinal:04d}"
                discard_private_directory(pending)
                sample = calibration_plan["samples"][ordinal - 1]
                record = capture_sample(calibration_plan, sample, by_role["control"], pending,
                                        ready, driver_binary, driver_binary_sha256,
                                        fixture_source_sha256, executor,
                                        active_app_path if stateful else None)
                if record["status"] != "success":
                    failure_record = record
                    discard_private_directory(pending)
                    break
                destination = raw_roots[0] / f"sample-{ordinal:04d}"
                publish_evidence_directory(pending, destination)
                record["raw_directory"] = str(destination)
                record["manifest"] = str(destination / "manifest.json")
                record["manifest_sha256"] = hashlib.sha256(
                    read_regular_bytes(destination / "manifest.json")).hexdigest()
                state["calibration_records"].append(record)
                if stateful:
                    write_private_json_atomic(state_path, state)
            if failure_record is None and state["frozen_mde_sha256"] is None:
                calibration_result = calibration_result_for(
                    calibration_plan, state["calibration_records"], stateful=stateful)
                expected_calibration = (json.dumps(
                    calibration_result, indent=2, sort_keys=True) + "\n").encode()
                if state["calibration_output_sha256"] is None:
                    if calibration_output.exists() or calibration_output.is_symlink():
                        if read_regular_bytes(calibration_output) != expected_calibration:
                            fail("uncheckpointed calibration output does not match accepted samples")
                    else:
                        write_durable_json_exclusive(calibration_output, calibration_result)
                    state["calibration_output_sha256"] = hashlib.sha256(
                        read_regular_bytes(calibration_output)).hexdigest()
                    if stateful:
                        write_private_json_atomic(state_path, state)
                if frozen_mde_output.exists() or frozen_mde_output.is_symlink():
                    expected_frozen = frozen_artifact_for(
                        calibration_plan, state["calibration_records"])
                    frozen_bytes = read_regular_bytes(frozen_mde_output)
                    if decode_json_bytes(frozen_bytes, "uncheckpointed frozen MDE") != expected_frozen:
                        fail("uncheckpointed frozen MDE does not match accepted calibration")
                    state["frozen_mde_sha256"] = hashlib.sha256(
                        frozen_bytes).hexdigest()
                    compare.load_frozen(frozen_mde_output, state["frozen_mde_sha256"])
                else:
                    state["frozen_mde_sha256"] = freeze_calibration(
                        calibration_plan, state["calibration_records"], frozen_mde_output)
                if stateful:
                    write_private_json_atomic(state_path, state)
                base.preflight_no_existing_app(apps, executor)
        # Paired checkpoints are published only after both arms succeed. A failed or abandoned
        # hidden pending directory is deleted and the entire pair is retried on resume.
        if failure_record is None:
            completed_pairs = len(state["paired_records"]) // 2
            pair_count = len(plan["samples"]) // 2
            reference = None
            if calibration_plan is not None:
                reference = calibration_reference(state["calibration_records"])
                validate_current_calibration_environment(
                    reference, plan, ready, driver_binary_sha256,
                    fixture_source_sha256, executor)
                if completed_pairs == 0 and plan["cooldown_seconds"] > 0:
                    executor.sleep(plan["cooldown_seconds"])
            for pair_index in range(completed_pairs + 1, pair_count + 1):
                if pair_index > 1 and plan["cooldown_seconds"] > 0:
                    executor.sleep(plan["cooldown_seconds"])
                pending_pair = raw_root / f".pending-pair-{pair_index:04d}"
                discard_private_directory(pending_pair)
                pending_pair.mkdir(mode=0o700)
                pair_records = []
                for arm, sample in enumerate(plan["samples"][(pair_index - 1) * 2:pair_index * 2], 1):
                    record = capture_sample(plan, sample, by_role[sample["role"]],
                                            pending_pair / f"arm-{arm}", ready, driver_binary,
                                            driver_binary_sha256, fixture_source_sha256, executor,
                                            active_app_path if stateful else None)
                    pair_records.append(record)
                    if record["status"] != "success":
                        failure_record = record
                        break
                if failure_record is not None:
                    discard_private_directory(pending_pair)
                    break
                if reference is not None:
                    validate_pending_pair_environment(
                        pair_records, reference,
                        state["paired_records"][-1] if state["paired_records"] else None)
                for arm, record in enumerate(pair_records, 1):
                    destination = raw_root / f"pair-{pair_index:04d}" / f"arm-{arm}"
                    record["raw_directory"] = str(destination)
                    record["manifest"] = str(destination / "manifest.json")
                # One rename publishes both manifests or neither; no observable sample-* path
                # can ever contain only one completed arm.
                publish_evidence_directory(
                    pending_pair, raw_root / f"pair-{pair_index:04d}")
                for record in pair_records:
                    record["manifest_sha256"] = hashlib.sha256(
                        read_regular_bytes(pathlib.Path(record["manifest"]))).hexdigest()
                state["paired_records"].extend(pair_records)
                if stateful:
                    write_private_json_atomic(state_path, state)
    finally:
        ready_path.unlink(missing_ok=True)
        fixture_error = base.stop_and_prove_gone(fixture, executor)
        if not stateful:
            driver_binary.unlink(missing_ok=True)
    completed_records = state["paired_records"]
    records = completed_records if failure_record is None else [*completed_records, failure_record]
    status = "success" if (failure_record is None and len(completed_records) == len(plan["samples"])
                           and fixture_error is None) else "failure"
    result = {"schema_version": 1, "capture_status": status,
              "artifact_status": "admissible_per_run_manifests", "scenario": plan["scenario"],
              "cooldown_seconds": plan["cooldown_seconds"],
              "fixture_cleanup_error": fixture_error, "records": records}
    if failure_record is not None:
        result["failure_record"] = failure_record
    if calibration_plan is not None:
        result["calibration"] = {
            "capture_output": str(calibration_output), "frozen_mde": str(frozen_mde_output),
            "frozen_mde_sha256": state["frozen_mde_sha256"],
        }
        failure_report = ({"schema_version": 1, "status": "failure",
                           "scenario": plan["scenario"],
                           "sample_kind": failure_record.get("sample_kind")
                           if failure_record else None,
                           "sample_index": failure_record.get("sample_index")
                           if failure_record else None,
                           "pair_order": failure_record.get("pair_order")
                           if failure_record else None,
                           "role": failure_record.get("role") if failure_record else None,
                           "error": str(failure_record.get("error") if failure_record else
                                        fixture_error or "capture incomplete")[:2048]}
                          if status != "success" else
                          {"schema_version": 1, "status": "cleared"})
        write_private_json_atomic(raw_root / ".last-failure.json", failure_report)
    return result

def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--control-app", required=True, type=pathlib.Path)
    result.add_argument("--candidate-app", required=True, type=pathlib.Path)
    result.add_argument("--control-commit", required=True)
    result.add_argument("--candidate-commit", required=True)
    result.add_argument("--scenario", required=True, choices=SCENARIOS)
    result.add_argument("--output", required=True, type=pathlib.Path)
    result.add_argument("--warmups", type=int, default=3)
    result.add_argument("--measured", type=int, default=20)
    result.add_argument("--seed", type=int, default=1)
    result.add_argument("--device-label", default="local-device-01")
    result.add_argument("--retention-deadline", default="2099-01-01T00:00:00Z")
    result.add_argument("--cooldown-seconds", type=float, default=0)
    result.add_argument("--calibrate-and-capture", action="store_true")
    result.add_argument("--calibration-output", type=pathlib.Path)
    result.add_argument("--frozen-mde-output", type=pathlib.Path)
    result.add_argument("--max-calibration-free-storage-drift-bytes", type=int)
    result.add_argument("--resume", action="store_true")
    result.add_argument("--fixture-port", type=int, default=0)
    result.add_argument("--plan", action="store_true")
    return result


def validate_integrated_outputs(paths: list[pathlib.Path]) -> None:
    resolved = [path.absolute() for path in paths]
    raw_roots = [path.parent / f"{path.stem}-raw" for path in paths[:2]]
    all_paths = [*resolved, *raw_roots]
    if len({path.resolve() for path in all_paths}) != len(all_paths):
        fail("integrated calibration output paths must be distinct")
    for output in resolved:
        if any(output.resolve().is_relative_to(root.resolve()) for root in raw_roots):
            fail("integrated calibration outputs must remain outside raw evidence roots")
    for path in all_paths:
        if path.exists() or path.is_symlink():
            fail(f"integrated calibration output already exists: {path}")


def validate_published_resume_output(output: pathlib.Path, plan: dict[str, Any],
                                     calibration_plan: dict[str, Any], apps: tuple[Any, Any],
                                     calibration_output: pathlib.Path,
                                     frozen_mde_output: pathlib.Path, fixture_port: int) -> None:
    document = decode_json_bytes(
        read_regular_bytes(output, private=True), "published resumable output")
    expected_keys = {"schema_version", "capture_status", "artifact_status", "scenario",
                     "cooldown_seconds", "fixture_cleanup_error", "records", "calibration"}
    if (not isinstance(document, dict) or set(document) != expected_keys
            or document["schema_version"] != 1 or document["capture_status"] != "success"
            or document["artifact_status"] != "admissible_per_run_manifests"
            or document["fixture_cleanup_error"] is not None
            or document["scenario"] != plan["scenario"]
            or document["cooldown_seconds"] != plan["cooldown_seconds"]):
        fail("published resumable output is invalid")
    raw_root = output.parent / f"{output.stem}-raw"
    stored_identity = read_private_json(raw_root / ".resume-plan.json")
    identity = resume_identity(plan, calibration_plan, apps, calibration_output,
                               frozen_mde_output, fixture_port)
    if stored_identity != identity:
        fail("published resumable output plan identity drift detected")
    state = read_private_json(raw_root / ".resume-state.json")
    validate_resume_state_transition(
        state, len(calibration_plan["samples"]), len(plan["samples"]))
    if (state.get("plan_sha256") != canonical_sha256(identity)
            or document["records"] != state.get("paired_records")
            or len(document["records"]) != len(plan["samples"])
            or document["calibration"] != {
                "capture_output": str(calibration_output),
                "frozen_mde": str(frozen_mde_output),
                "frozen_mde_sha256": state.get("frozen_mde_sha256"),
            }):
        fail("published resumable output does not match its checkpoint state")
    driver_sha256 = hashlib.sha256(read_regular_bytes(
        raw_root / ".perf-macos-ax-driver", private=True)).hexdigest()
    if driver_sha256 != state.get("driver_sha256"):
        fail("published resumable output driver checksum drift detected")
    calibration_ids, calibration_nonces = validate_resume_records(
        state.get("calibration_records"), calibration_plan["samples"],
        calibration_output.parent / f"{calibration_output.stem}-raw",
        calibration_plan, driver_sha256, fixture_port, paired=False)
    paired_ids, paired_nonces = validate_resume_records(
        state.get("paired_records"), plan["samples"], raw_root,
        plan, driver_sha256, fixture_port, paired=True)
    if calibration_ids & paired_ids or calibration_nonces & paired_nonces:
        fail("published resumable evidence identities are not globally unique")
    validate_retained_pair_chronology(state["paired_records"])
    validate_checkpointed_calibration_artifacts(
        state, calibration_plan, calibration_output, frozen_mde_output,
        require_complete=True)
    reference = calibration_reference(state["calibration_records"])
    previous = None
    for offset in range(0, len(state["paired_records"]), 2):
        pair_records = state["paired_records"][offset:offset + 2]
        validate_pending_pair_environment(pair_records, reference, previous)
        previous = pair_records[-1]
    frozen = compare.load_frozen(frozen_mde_output, state["frozen_mde_sha256"])
    controls = [compare.load_sample(pathlib.Path(record["manifest"]), "control")
                for record in state["paired_records"] if record["role"] == "control"]
    compare._validate_frozen(frozen, controls, controls[0].workload, "short")


def main(argv: list[str] | None = None, executor: Any | None = None) -> int:
    args = parser().parse_args(argv)
    if args.warmups < 0 or args.measured < 1:
        fail("warmups must be nonnegative and measured must be positive")
    if (isinstance(args.cooldown_seconds, bool) or not math.isfinite(args.cooldown_seconds)
            or args.cooldown_seconds < 0):
        fail("cooldown seconds must be a finite nonnegative number")
    if args.calibrate_and_capture != bool(
            args.calibration_output is not None and args.frozen_mde_output is not None):
        fail("--calibrate-and-capture requires both calibration output paths")
    if not args.calibrate_and_capture and (
            args.calibration_output is not None or args.frozen_mde_output is not None
            or args.max_calibration_free_storage_drift_bytes is not None):
        fail("calibration output paths require --calibrate-and-capture")
    if args.calibrate_and_capture and (
            args.max_calibration_free_storage_drift_bytes is None
            or args.max_calibration_free_storage_drift_bytes < 0):
        fail("integrated calibration requires a nonnegative storage-drift tolerance")
    if args.fixture_port < 0 or args.fixture_port > 65535:
        fail("fixture port must be zero or a valid TCP port")
    if args.fixture_port and not args.calibrate_and_capture:
        fail("a pinned fixture port requires integrated calibration")
    if args.resume and (not args.calibrate_and_capture or args.fixture_port == 0):
        fail("--resume requires integrated calibration and a nonzero --fixture-port")
    if args.resume and args.plan:
        fail("--plan cannot inspect or mutate resumable capture state")
    apps, service = validate_inputs(args.control_app, args.candidate_app)
    plan = plan_for(apps, service, args.scenario, args.warmups, args.measured, args.seed,
                    args.output, args.control_commit, args.candidate_commit, args.device_label,
                    args.retention_deadline, args.cooldown_seconds)
    calibration_plan = (calibration_plan_for(
        plan, args.calibration_output, args.max_calibration_free_storage_drift_bytes)
                        if args.calibrate_and_capture else None)
    if args.plan:
        document = {**plan, "mode": "plan"}
        if calibration_plan is not None:
            document["calibration"] = {
                **calibration_plan, "mode": "calibration_plan",
                "frozen_mde_output": str(args.frozen_mde_output.absolute()),
            }
        print(json.dumps(document, indent=2, sort_keys=True))
        return 0
    if calibration_plan is not None and not args.resume:
        validate_integrated_outputs([
            args.output, args.calibration_output, args.frozen_mde_output])
    if args.resume and (args.output.exists() or args.output.is_symlink()):
        validate_published_resume_output(
            args.output, plan, calibration_plan, apps, args.calibration_output,
            args.frozen_mde_output, args.fixture_port)
        return 0
    try:
        result = capture(
            plan, apps, executor or Executor(), calibration_plan=calibration_plan,
            calibration_output=args.calibration_output, frozen_mde_output=args.frozen_mde_output,
            resume=args.resume, fixture_port=args.fixture_port)
    except (RunnerError, OSError, subprocess.CalledProcessError) as error:
        if calibration_plan is not None:
            raw_root = args.output.parent / f"{args.output.stem}-raw"
            if raw_root.is_dir() and not raw_root.is_symlink():
                try:
                    write_private_json_atomic(raw_root / ".last-failure.json", {
                        "schema_version": 1, "status": "failure",
                        "scenario": args.scenario, "sample_kind": None,
                        "sample_index": None, "pair_order": None, "role": None,
                        "error": str(error)[:2048],
                    })
                except (RunnerError, OSError):
                    pass
        raise
    if result["capture_status"] != "success":
        failure = result.get("failure_record", {})
        message = failure.get("error") or result.get("fixture_cleanup_error") or "unknown failure"
        print(f"error: browse capture failed: {str(message)[:512]}",
              file=sys.stderr)
    if calibration_plan is not None:
        # A failed resumable run owns only private state. Publishing a top-level failure result
        # would make the exact output pathname unavailable to the successful resumed process.
        if result["capture_status"] == "success":
            write_durable_json_exclusive(args.output, result)
    else:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    return 0 if result["capture_status"] == "success" else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RunnerError, OSError, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
