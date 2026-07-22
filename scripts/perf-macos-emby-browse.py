#!/usr/bin/env python3
"""Plan or capture paired, externally-driven macOS Emby browse workloads."""
from __future__ import annotations

import argparse
import copy
import hashlib
import importlib.util
import json
import math
import os
import pathlib
import plistlib
import re
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
}
ALLOWED_TRANSIENT_RESULTS = {
    "home.load": {"cancelled"},
    "library_grid.complete": {"cancelled", "superseded"},
    "search.load": {"cancelled", "superseded"},
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

    def __init__(self, pid: int, executable: pathlib.Path):
        self.pid = pid
        self.executable = executable
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


def stop_app_and_prove_gone(process: Any, executor: Any) -> str | None:
    """Stop a child or detached exact-path app without ever signaling a reused PID."""
    if not isinstance(process, DetachedAppProcess):
        return base.stop_and_prove_gone(process, executor)

    pid = int(process.pid)

    def still_exact() -> bool:
        return pid in exact_executable_pids(process.executable, executor)

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


def launch_app(app: Any, executor: Any) -> DetachedAppProcess:
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
            return DetachedAppProcess(new_pids.pop(), app.executable)
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
            if span is not None and span.phase == phase and span.backend == "Emby":
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
                                    phase: str) -> None:
    """Retain the capture binding and one successful target span; preserve the full log separately."""
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
        if span is not None and span.phase == phase and span.backend == "Emby":
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
        "artifact_status": ("pre_manifest_raw_capture" if scenario == "artwork"
                            else "planned_admissible_per_run_manifests"),
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
        "fields": {},
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
        "search": "search_loaded", "artwork": "artwork_requested",
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
        manifests = [pathlib.Path(record["manifest"]) for record in records]
        samples = [compare.load_sample(path, "control") for path in manifests]
        validate_calibration_covariates(
            samples, plan["max_free_storage_drift_bytes"])
        artifact = compare.freeze_control(
            samples, selector=freeze_selector(plan), sample_policy="short")
        write_durable_json_exclusive(destination, artifact)
        digest = hashlib.sha256(destination.read_bytes()).hexdigest()
        compare.load_frozen(destination, digest)
        return digest
    except (compare.CompareError, OSError) as error:
        fail(f"control-only MDE freeze failed: {error}")


def capture(plan: dict[str, Any], apps: tuple[Any, Any], executor: Any,
            *, calibration_plan: dict[str, Any] | None = None,
            calibration_output: pathlib.Path | None = None,
            frozen_mde_output: pathlib.Path | None = None) -> dict[str, Any]:
    if plan["scenario"] == "artwork":
        fail("artwork capture is pre-manifest until an exact loaded-artwork milestone exists")
    base.preflight_no_existing_app(apps, executor)
    for command in plan["configuration_contract_commands"]:
        executor.run(command)
    stages = ([calibration_plan, plan] if calibration_plan is not None else [plan])
    if calibration_plan is not None and (calibration_output is None or frozen_mde_output is None):
        fail("integrated calibration requires calibration and frozen-MDE output paths")
    raw_roots = []
    for stage in stages:
        output = pathlib.Path(stage["output"])
        raw_root = output.parent / f"{output.stem}-raw"
        raw_root.mkdir(parents=True, exist_ok=calibration_plan is None)
        raw_roots.append(raw_root)
    raw_root = raw_roots[-1]
    driver_binary = raw_root / ".perf-macos-ax-driver"
    if driver_binary.exists() or driver_binary.is_symlink():
        fail("private AX driver output already exists")
    # Compile once, before the fixture or any sample starts, so compiler work cannot enter a
    # measured pair or perturb one arm differently from the other.
    executor.run(["/usr/bin/xcrun", "swiftc", str(DRIVER), "-o", str(driver_binary)])
    driver_binary.chmod(0o700)
    if not driver_binary.is_file() or driver_binary.is_symlink():
        fail("AX driver preflight did not produce a private regular executable")
    driver_binary_sha256 = hashlib.sha256(driver_binary.read_bytes()).hexdigest()
    fixture_source_sha256 = hashlib.sha256(FIXTURE.read_bytes()).hexdigest()
    ready_path = raw_root / ".fixture-ready.json"
    try:
        ready_path.unlink()
    except FileNotFoundError:
        pass
    try:
        fixture = executor.spawn([sys.executable, str(FIXTURE), "--ready-file", str(ready_path)])
    except BaseException:
        driver_binary.unlink(missing_ok=True)
        raise
    fixture_error = None
    records_by_stage: list[list[dict[str, Any]]] = [[] for _stage in stages]
    frozen_mde_sha256: str | None = None
    try:
        ready = wait_ready(ready_path, fixture, executor)
        by_role = {app.role: app for app in apps}
        work_items = [
            (stage_index, stage, raw_roots[stage_index], ordinal, sample)
            for stage_index, stage in enumerate(stages)
            for ordinal, sample in enumerate(stage["samples"], 1)
        ]
        for work_index, (stage_index, active_plan, active_raw_root, ordinal, sample) in enumerate(
                work_items):
            app = by_role[sample["role"]]
            record = {key: sample[key] for key in
                      ("scenario", "sample_kind", "sample_index", "pair_order", "role")}
            app_process = None
            run_dir = active_raw_root / f"sample-{ordinal:04d}"
            run_dir.mkdir(mode=0o700)
            spec_path = run_dir / ".workload-spec.json"
            raw_dir = run_dir / "raw"
            summary_dir = run_dir / "summary"
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
                workload_spec_sha256 = hashlib.sha256(spec_path.read_bytes()).hexdigest()
                automation = {
                    "fixture_implementation_sha256": fixture_source_sha256,
                    "driver_sha256": driver_binary_sha256,
                    "workload_spec_sha256": workload_spec_sha256,
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
                app_process = launch_app(app, executor)
                pid = int(app_process.pid)
                record["pid"] = pid
                if executor.poll(app_process) is not None:
                    fail(f"app PID {pid} exited at launch")
                driver_output = raw_dir / "artifact-0002.json"
                executor.run([str(driver_binary), "--pid", str(pid),
                              "--workload-spec", str(spec_path), "--output", str(driver_output)])
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
                # The process boundary closes the workload. Persist only the ledger observed
                # after that boundary, and reject any request that escaped the stable-zero window.
                ledger = request_fixture(ready["base_url"], "/__fixture__/ledger")
                validate_ledger(ledger, ready, active_plan["scenario"])
                if ledger != stable_ledger:
                    fail("fixture ledger changed after the stable-zero process boundary")
                reset_performance_keychain(active_plan["keychain_service"], executor)
                post_reset_done = True
                ledger_path = raw_dir / "artifact-0003.json"
                ledger_path.write_text(json.dumps(ledger, indent=2, sort_keys=True) + "\n")
                phase = SCENARIO_PHASES[active_plan["scenario"]]
                selected_log = raw_dir / "artifact-0004.log"
                write_success_selector_artifact(raw_log, selected_log, phase)
                update_pointer_checksums(manifest, run_dir)
                write_manifest(manifest_path, manifest)
                correctness = evidence_schema.REQUIRED_CORRECTNESS_FIELDS[(phase, "Emby")]
                summary_path = summary_dir / "redacted.json"
                summary_command = [sys.executable, str(SUMMARY), "--json", "--strict",
                                   "--manifest", str(manifest_path), "--raw-artifact", str(selected_log),
                                   "--workload-id", active_plan["identities"]["workload_id"],
                                   "--phase", phase, "--backend", "Emby",
                                   "--expected-span-count", "1"]
                for field in correctness:
                    summary_command += ["--correctness-field", field]
                with summary_path.open("wb") as output:
                    executor.run(summary_command, stdout=output)
                manifest["evidence"]["redacted_summary"]["sha256"] = hashlib.sha256(
                    summary_path.read_bytes()).hexdigest()
                write_manifest(manifest_path, manifest)
                executor.run([sys.executable, str(CONTRACT), "manifest", str(manifest_path)])
                record["status"] = "success"
                record["raw_directory"] = str(run_dir)
                record["manifest"] = str(manifest_path)
            except Exception as error:
                # Placeholder manifests are never evidence. Preserve bounded raw diagnostics but
                # remove any incomplete contract surface so discovery cannot ingest it.
                manifest_path.unlink(missing_ok=True)
                add_record_error(record, str(error))
            finally:
                try:
                    spec_path.unlink()
                except FileNotFoundError:
                    pass
                if app_process is not None:
                    cleanup = stop_app_and_prove_gone(app_process, executor)
                    if cleanup:
                        add_record_error(record, cleanup)
                if not post_reset_done:
                    try:
                        reset_performance_keychain(active_plan["keychain_service"], executor)
                    except Exception as error:
                        add_record_error(record, f"post-stop Keychain reset failed: {error}")
                records_by_stage[stage_index].append(record)
            if record["status"] != "success":
                break
            stage_finished = ordinal == len(active_plan["samples"])
            if calibration_plan is not None and stage_index == 0 and stage_finished:
                base.preflight_no_existing_app(apps, executor)
                calibration_result = {
                    "schema_version": 1, "capture_status": "success",
                    "artifact_status": "admissible_control_only_calibration_manifests",
                    "scenario": active_plan["scenario"],
                    "fixture_lifecycle": "shared_with_paired_capture",
                    "cooldown_seconds": active_plan["cooldown_seconds"],
                    "max_free_storage_drift_bytes":
                        active_plan["max_free_storage_drift_bytes"],
                    "records": records_by_stage[0],
                }
                write_durable_json_exclusive(calibration_output, calibration_result)
                frozen_mde_sha256 = freeze_calibration(
                    active_plan, records_by_stage[0], frozen_mde_output)
                # Validation and the directory fsync above complete before the first paired arm.
                base.preflight_no_existing_app(apps, executor)
            if work_index + 1 < len(work_items) and active_plan["cooldown_seconds"] > 0:
                executor.sleep(active_plan["cooldown_seconds"])
    finally:
        try:
            ready_path.unlink()
        except FileNotFoundError:
            pass
        fixture_error = base.stop_and_prove_gone(fixture, executor)
        try:
            driver_binary.unlink()
        except FileNotFoundError:
            pass
    records = records_by_stage[-1]
    status = "success" if records and len(records) == len(plan["samples"]) and all(
        row["status"] == "success" for row in records) and fixture_error is None else "failure"
    result = {"schema_version": 1, "capture_status": status,
            "artifact_status": "admissible_per_run_manifests", "scenario": plan["scenario"],
            "cooldown_seconds": plan["cooldown_seconds"],
            "fixture_cleanup_error": fixture_error, "records": records}
    if calibration_plan is not None:
        result["calibration"] = {
            "capture_output": str(calibration_output),
            "frozen_mde": str(frozen_mde_output),
            "frozen_mde_sha256": frozen_mde_sha256,
        }
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
    if calibration_plan is not None:
        validate_integrated_outputs([
            args.output, args.calibration_output, args.frozen_mde_output])
    result = capture(
        plan, apps, executor or Executor(), calibration_plan=calibration_plan,
        calibration_output=args.calibration_output, frozen_mde_output=args.frozen_mde_output)
    if calibration_plan is not None:
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
