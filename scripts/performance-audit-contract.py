#!/usr/bin/env python3
"""Validate Labstream PerformanceAudit configuration, binaries, and evidence manifests."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import plistlib
import re
import stat
import subprocess
import sys
import xml.etree.ElementTree as ET
import zipfile
import zlib
from datetime import datetime
from typing import Any

TOOL_NAME = "labstream-performance-audit"
TOOL_VERSION = "1"
CONFIGURATION = "PerformanceAudit"
TARGETS = ("Labstream", "LabstreamMobile", "LabstreamMac", "LabstreamTV")
PLATFORMS = {"visionos", "ios", "ipados", "macos", "tvos"}
SAFE_LABEL_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
RUN_ID_RE = re.compile(r"^run-[a-f0-9]{12}$")
COMPARISON_ID_RE = re.compile(r"^comparison-[a-f0-9]{12}$")
ORDER_SEED_RE = re.compile(r"^seed-[a-f0-9]{16}$")
SCENARIO_ID_RE = re.compile(r"^scenario-[a-f0-9]{12}$")
FIXTURE_ID_RE = re.compile(r"^fixture-[a-f0-9]{12}$")
DEVICE_LABEL_RE = re.compile(r"^local-device-[0-9]{2,3}$")
APPLE_BUILD_RE = re.compile(r"^[0-9]{1,3}[A-Z][A-Za-z0-9]{1,16}$")
SERVER_VERSION_RE = re.compile(r"^[0-9]+(?:\.[0-9]+){1,3}(?:-[a-f0-9]{7,16})?$")
RAW_ARTIFACT_PATH_RE = re.compile(
    r"^raw/artifact-[0-9]{4}(?:\.trace\.zip|\.(?:trace|xml|json|jsonl|csv|log|txt|plist|spindump|ips))$"
)
SUMMARY_PATH = "summary/redacted.json"
MAX_TRACE_ARCHIVE_MEMBERS = 100_000
MAX_TRACE_ARCHIVE_MEMBER_BYTES = 8 * 1024**3
MAX_TRACE_ARCHIVE_UNCOMPRESSED_BYTES = 20 * 1024**3
MAX_TRACE_ARCHIVE_COMPRESSION_RATIO = 1_000
SHA256_RE = re.compile(r"^[a-f0-9]{64}$")
COMMIT_RE = re.compile(r"^[a-f0-9]{40}$")
PRIVATE_STRING_PATTERNS = (
    ("URL", re.compile(r"\b(?:https?|file)://", re.IGNORECASE)),
    ("absolute user path", re.compile(r"(?:^|[\s\"'])/(?:Users|home)/")),
    ("IP address", re.compile(r"(?<![A-Za-z0-9])(?:\d{1,3}\.){3}\d{1,3}(?![A-Za-z0-9])")),
)
FORBIDDEN_BINARY_MARKERS = {
    "UI test fixture": (b"--ui-testing-fixture", b"TVKeyboardFixture:"),
    "live app probe": (b"--vp-probe-",),
    "tvOS event swizzle": (b"labstream_evidenceSendEvent", b"TVEvidence:"),
    "verbose Debug evidence": (
        b"TVPlayerEvidence:",
        b"TVSearchEvidence:",
        b"PlaybackController[dp-diag]:",
        b"library.grid.items ",
        b"container.children ",
    ),
}
REQUIRED_AUDIT_BINARY_MARKERS = (b"perf.span phase=", b"home.load")
RELEASE_PARITY_KEYS = (
    # Effective Swift compiler contract. Active conditions are compared separately below.
    "OTHER_SWIFT_FLAGS",
    "SWIFT_OPTIMIZATION_LEVEL",
    "SWIFT_COMPILATION_MODE",
    "SWIFT_ENABLE_BATCH_MODE",
    "SWIFT_ENABLE_EXPLICIT_MODULES",
    "SWIFT_STRICT_CONCURRENCY",
    "SWIFT_UPCOMING_FEATURES",
    "SWIFT_VERSION",
    # Effective C/C++/Clang compiler contract.
    "OTHER_CFLAGS",
    "OTHER_CPLUSPLUSFLAGS",
    "GCC_C_LANGUAGE_STANDARD",
    "GCC_OPTIMIZATION_LEVEL",
    "GCC_PREPROCESSOR_DEFINITIONS",
    "CLANG_CXX_LANGUAGE_STANDARD",
    "CLANG_CXX_LIBRARY",
    "CLANG_ENABLE_MODULES",
    "CLANG_ENABLE_OBJC_ARC",
    "CLANG_ENABLE_OBJC_WEAK",
    # Instrumentation and sanitizers materially alter runtime behavior.
    "ENABLE_ADDRESS_SANITIZER",
    "ENABLE_THREAD_SANITIZER",
    "ENABLE_UNDEFINED_BEHAVIOR_SANITIZER",
    "CLANG_ENABLE_CODE_COVERAGE",
    "GCC_GENERATE_TEST_COVERAGE_FILES",
    "GCC_INSTRUMENT_PROGRAM_FLOW_ARCS",
    "ENABLE_NS_ASSERTIONS",
    "ENABLE_TESTABILITY",
    "ENABLE_CODE_COVERAGE",
    "COPY_PHASE_STRIP",
    "DEAD_CODE_STRIPPING",
    "DEBUG_INFORMATION_FORMAT",
    "CODE_SIGN_ENTITLEMENTS",
    "CODE_SIGN_IDENTITY",
    "CODE_SIGN_INJECT_BASE_ENTITLEMENTS",
    "CODE_SIGN_STYLE",
    "CODE_SIGNING_ALLOWED",
    "CODE_SIGNING_REQUIRED",
    "DEVELOPMENT_TEAM",
    "PROVISIONING_PROFILE_SPECIFIER",
    "ENABLE_HARDENED_RUNTIME",
    "LLVM_LTO",
    "MTL_ENABLE_DEBUG_INFO",
    "MTL_FAST_MATH",
    "STRIP_INSTALLED_PRODUCT",
    "STRIP_STYLE",
    "VALIDATE_PRODUCT",
    "PRODUCT_BUNDLE_IDENTIFIER",
    "SUPPORTED_PLATFORMS",
    "SDKROOT",
    "OTHER_LDFLAGS",
)


class ContractError(ValueError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ContractError(message)


def exact_keys(value: Any, path: str, required: set[str]) -> dict[str, Any]:
    require(isinstance(value, dict), f"{path} must be an object")
    actual = set(value)
    missing = sorted(required - actual)
    extra = sorted(actual - required)
    require(not missing, f"{path} missing fields: {', '.join(missing)}")
    require(not extra, f"{path} has unsupported fields: {', '.join(extra)}")
    return value


def closed_keys(value: Any, path: str, required: set[str], optional: set[str]) -> dict[str, Any]:
    require(isinstance(value, dict), f"{path} must be an object")
    actual = set(value)
    missing = sorted(required - actual)
    extra = sorted(actual - required - optional)
    require(not missing, f"{path} missing fields: {', '.join(missing)}")
    require(not extra, f"{path} has unsupported fields: {', '.join(extra)}")
    return value


def enum_value(value: Any, path: str, allowed: set[str]) -> str:
    require(isinstance(value, str) and value in allowed,
            f"{path} must be one of: {', '.join(sorted(allowed))}")
    return value


def relative_path(value: Any, path: str) -> pathlib.PurePosixPath:
    require(isinstance(value, str) and value != "", f"{path} must be a relative path")
    require(len(value) <= 240 and "\\" not in value, f"{path} must use a short POSIX relative path")
    candidate = pathlib.PurePosixPath(value)
    require(not candidate.is_absolute() and ".." not in candidate.parts and "." not in candidate.parts,
            f"{path} must remain inside the run directory")
    require(all(SAFE_LABEL_RE.fullmatch(part) for part in candidate.parts),
            f"{path} contains a non-public path component")
    return candidate


def parse_utc(value: Any, path: str) -> datetime:
    require(isinstance(value, str) and value.endswith("Z"), f"{path} must be an ISO-8601 UTC timestamp")
    try:
        return datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError as error:
        raise ContractError(f"{path} must be an ISO-8601 UTC timestamp") from error


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate_pointer(value: Any, path: str, run_dir: pathlib.Path,
                     verify_files: bool, pointer_kind: str) -> None:
    pointer = exact_keys(value, path, {"path", "sha256"})
    rel = relative_path(pointer["path"], f"{path}.path")
    if pointer_kind == "raw":
        require(RAW_ARTIFACT_PATH_RE.fullmatch(pointer["path"]) is not None,
                f"{path}.path must use the opaque raw/artifact-NNNN.ext shape")
    else:
        require(pointer["path"] == SUMMARY_PATH,
                f"{path}.path must equal {SUMMARY_PATH}")
    require(isinstance(pointer["sha256"], str) and SHA256_RE.fullmatch(pointer["sha256"]) is not None,
            f"{path}.sha256 must be a lowercase SHA-256 digest")
    if verify_files:
        artifact = run_dir.joinpath(*rel.parts)
        require(artifact.is_file() and not artifact.is_symlink(),
                f"{path}.path does not name a regular file in the run directory")
        try:
            artifact.resolve().relative_to(run_dir.resolve())
        except ValueError as error:
            raise ContractError(f"{path}.path escapes the run directory") from error
        digest = sha256_file(artifact)
        require(digest == pointer["sha256"], f"{path}.sha256 does not match its file")


def reject_private_strings(value: Any, path: str = "manifest") -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            reject_private_strings(child, f"{path}.{key}")
    elif isinstance(value, list):
        for index, child in enumerate(value):
            reject_private_strings(child, f"{path}[{index}]")
    elif isinstance(value, str):
        for label, pattern in PRIVATE_STRING_PATTERNS:
            require(pattern.search(value) is None, f"{path} contains a forbidden {label}")


def read_json_file(path: pathlib.Path, label: str) -> Any:
    require(path.is_file() and not path.is_symlink(), f"{label} must be a regular non-symlink file")
    require(path.stat().st_size <= 1024 * 1024, f"{label} exceeds the bounded JSON size")
    try:
        return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise ContractError(f"{label} must be readable versioned JSON") from error


def validate_trace_archive(path: pathlib.Path) -> None:
    """Fully stream and reject misleading, corrupt, traversing, or bomb-like trace ZIPs."""
    try:
        with zipfile.ZipFile(path) as archive:
            members = archive.infolist()
            require(0 < len(members) <= MAX_TRACE_ARCHIVE_MEMBERS,
                    "idle trace archive has an invalid member count")
            roots: set[str] = set()
            names: set[str] = set()
            declared_total = 0
            streamed_total = 0
            for member in members:
                candidate = pathlib.PurePosixPath(member.filename)
                require(member.filename not in names, "idle trace archive has duplicate members")
                names.add(member.filename)
                require(not candidate.is_absolute() and candidate.parts
                        and all(part not in {"", ".", ".."} for part in candidate.parts),
                        "idle trace archive member escapes its root")
                roots.add(candidate.parts[0])
                require(member.flag_bits & 0x1 == 0, "idle trace archive must not be encrypted")
                mode = member.external_attr >> 16
                if mode:
                    require((member.is_dir() and stat.S_ISDIR(mode))
                            or (not member.is_dir() and stat.S_ISREG(mode)),
                            "idle trace archive contains a symlink or special file")
                require(member.file_size <= MAX_TRACE_ARCHIVE_MEMBER_BYTES,
                        "idle trace archive member exceeds its size bound")
                if member.file_size:
                    require(member.compress_size > 0
                            and member.file_size <= member.compress_size * MAX_TRACE_ARCHIVE_COMPRESSION_RATIO,
                            "idle trace archive member exceeds its compression-ratio bound")
                declared_total += member.file_size
                require(declared_total <= MAX_TRACE_ARCHIVE_UNCOMPRESSED_BYTES,
                        "idle trace archive exceeds the bounded uncompressed size")
                if member.is_dir():
                    continue
                streamed_member = 0
                with archive.open(member, "r") as source:
                    while chunk := source.read(1024 * 1024):
                        streamed_member += len(chunk)
                        streamed_total += len(chunk)
                        require(streamed_member <= member.file_size
                                and streamed_member <= MAX_TRACE_ARCHIVE_MEMBER_BYTES,
                                "idle trace archive member expanded beyond its declared or bounded size")
                        require(streamed_total <= declared_total
                                and streamed_total <= MAX_TRACE_ARCHIVE_UNCOMPRESSED_BYTES,
                                "idle trace archive expanded beyond its declared or bounded total size")
                require(streamed_member == member.file_size,
                        "idle trace archive member size does not match its directory entry")
            require(len(roots) == 1 and next(iter(roots)).endswith(".trace"),
                    "idle trace archive must contain exactly one top-level .trace bundle")
            require(streamed_total == sum(member.file_size for member in members if not member.is_dir()),
                    "idle trace archive streamed size does not match its directory")
    except (OSError, RuntimeError, zipfile.BadZipFile, zlib.error) as error:
        raise ContractError("idle trace archive is not a readable ZIP file") from error


def validate_idle_evidence(manifest: dict[str, Any], run_dir: pathlib.Path) -> None:
    """Validate the typed summary/extraction chain for one idle trace sample."""
    evidence = manifest["evidence"]
    artifacts = evidence["artifacts"]
    by_path = {pointer["path"]: pointer for pointer in artifacts}
    require(len(by_path) == len(artifacts), "idle evidence artifact paths must be unique")
    summary_path = run_dir / SUMMARY_PATH
    summary = exact_keys(read_json_file(summary_path, "idle redacted summary"),
                         "idle redacted summary",
                         {"schema_version", "tool", "binding", "sources", "capture", "metrics"})
    reject_private_strings(summary, "idle redacted summary")
    require(summary["schema_version"] == 1, "idle redacted summary schema version is unsupported")
    require(summary["tool"] == {"name": "labstream-xctrace-idle-summary", "version": "1"},
            "idle redacted summary tool is unsupported")
    run, scenario, product = manifest["run"], manifest["scenario"], manifest["product"]
    expected_binding = {
        "run_id": run["id"], "comparison_id": run["comparison_id"],
        "artifact_role": run["artifact_role"], "sample_kind": run["sample_kind"],
        "sample_index": run["sample_index"], "scenario_id": scenario["id"],
    }
    require(summary["binding"] == expected_binding,
            "idle redacted summary binding does not match its manifest")
    sources = exact_keys(summary["sources"], "idle redacted summary sources",
                         {"trace_archive", "extraction"})
    for name, pointer in sources.items():
        require(pointer in artifacts, f"idle summary {name} is not an exact manifest artifact pointer")
    require(sources["trace_archive"]["path"].endswith(".trace.zip"),
            "idle trace archive must use the honest .trace.zip suffix")
    archive_path = run_dir.joinpath(*pathlib.PurePosixPath(sources["trace_archive"]["path"]).parts)
    validate_trace_archive(archive_path)
    require(sources["extraction"]["path"].endswith(".json"),
            "idle extraction must be a JSON artifact")

    extraction_path = run_dir.joinpath(*pathlib.PurePosixPath(sources["extraction"]["path"]).parts)
    extraction = exact_keys(read_json_file(extraction_path, "idle extraction"), "idle extraction",
                            {"schema_version", "tool", "xcode_build", "table", "sources",
                             "capture", "metrics"})
    reject_private_strings(extraction, "idle extraction")
    require(extraction["schema_version"] == 1 and extraction["tool"] == summary["tool"],
            "idle extraction schema/tool is unsupported")
    require(extraction["xcode_build"] == product["xcode_build"],
            "idle extraction Xcode build does not match the measured product")
    table = exact_keys(extraction["table"], "idle extraction table", {"name", "unit", "columns"})
    expected_columns = [
        {"name": "process-id", "unit": "count"},
        {"name": "window-start", "unit": "nanoseconds"},
        {"name": "window-end", "unit": "nanoseconds"},
        {"name": "cpu-running", "unit": "nanoseconds"},
        {"name": "wakeups", "unit": "count"},
    ]
    require(table == {"name": "system-trace-process-summary", "unit": "nanoseconds",
                      "columns": expected_columns},
            "idle extraction table/column/unit contract is unsupported")
    extraction_sources = exact_keys(extraction["sources"], "idle extraction sources",
                                    {"trace_archive", "source_export"})
    require(extraction_sources["trace_archive"] == sources["trace_archive"],
            "idle extraction is not bound to the summary trace archive")
    require(extraction_sources["source_export"] in artifacts,
            "idle extraction source export is not an exact manifest artifact pointer")
    require(extraction_sources["source_export"]["path"].endswith(".xml"),
            "idle extraction source must be an XML artifact")
    require(set(by_path) == {
        sources["trace_archive"]["path"], sources["extraction"]["path"],
        extraction_sources["source_export"]["path"],
    }, "idle manifest must contain exactly the archive, XML export, and typed extraction")

    capture = exact_keys(extraction["capture"], "idle extraction capture",
                         {"pid", "window_start_ns", "window_end_ns", "window_duration_ns"})
    require(type(capture["pid"]) is int and 0 < capture["pid"] <= 2**31 - 1,
            "idle extraction PID is invalid")
    for field in ("window_start_ns", "window_end_ns", "window_duration_ns"):
        require(type(capture[field]) is int and 0 <= capture[field] <= 86_400 * 1_000_000_000,
                f"idle extraction {field} is invalid")
    require(capture["window_end_ns"] > capture["window_start_ns"]
            and capture["window_duration_ns"] == capture["window_end_ns"] - capture["window_start_ns"],
            "idle extraction window is inconsistent")
    metrics = exact_keys(extraction["metrics"], "idle extraction metrics",
                         {"cpu_running_ns", "wakeups_count"})
    require(type(metrics["cpu_running_ns"]) is int
            and 0 <= metrics["cpu_running_ns"] <= capture["window_duration_ns"],
            "idle extraction CPU running time is invalid")
    require(type(metrics["wakeups_count"]) is int and 0 <= metrics["wakeups_count"] <= 1_000_000_000,
            "idle extraction wakeup count is invalid")
    require(summary["metrics"] == metrics, "idle summary metrics do not match the typed extraction")
    summary_capture = exact_keys(summary["capture"], "idle redacted summary capture", {
        "xcode_build", "pid", "expected_duration_ns", "window_tolerance_ns", "actual_duration_ns",
    })
    require(summary_capture["xcode_build"] == product["xcode_build"]
            and summary_capture["pid"] == capture["pid"]
            and summary_capture["actual_duration_ns"] == capture["window_duration_ns"],
            "idle summary capture does not match its extraction/product")
    require(type(summary_capture["expected_duration_ns"]) is int
            and 0 < summary_capture["expected_duration_ns"] <= 86_400 * 1_000_000_000,
            "idle summary expected duration is invalid")
    require(type(summary_capture["window_tolerance_ns"]) is int
            and 0 <= summary_capture["window_tolerance_ns"] <= 5_000_000_000,
            "idle summary window tolerance is invalid")
    require(abs(summary_capture["actual_duration_ns"] - summary_capture["expected_duration_ns"])
            <= summary_capture["window_tolerance_ns"],
            "idle summary capture window exceeds its declared tolerance")


def validate_manifest(data: Any, run_dir: pathlib.Path, verify_files: bool = True) -> None:
    manifest = closed_keys(data, "manifest", {
        "schema_version", "tool", "run", "product", "device", "state", "scenario",
        "launch_contract", "evidence",
    }, {"automation"})
    reject_private_strings(manifest)
    require(type(manifest["schema_version"]) is int and manifest["schema_version"] == 1,
            "manifest.schema_version must equal 1")

    tool = exact_keys(manifest["tool"], "manifest.tool", {"name", "version"})
    require(tool == {"name": TOOL_NAME, "version": TOOL_VERSION},
            "manifest.tool must identify schema/tool version 1")

    run = exact_keys(manifest["run"], "manifest.run", {
        "id", "recorded_at", "comparison_id", "artifact_role", "sample_kind", "sample_index", "order_seed",
    })
    require(isinstance(run["id"], str) and RUN_ID_RE.fullmatch(run["id"]) is not None,
            "manifest.run.id must use the opaque run-<12 hex> shape")
    parse_utc(run["recorded_at"], "manifest.run.recorded_at")
    require(isinstance(run["comparison_id"], str)
            and COMPARISON_ID_RE.fullmatch(run["comparison_id"]) is not None,
            "manifest.run.comparison_id must use the opaque comparison-<12 hex> shape")
    enum_value(run["artifact_role"], "manifest.run.artifact_role", {"control", "candidate", "standalone"})
    enum_value(run["sample_kind"], "manifest.run.sample_kind", {"warmup", "measured"})
    require(type(run["sample_index"]) is int and run["sample_index"] >= 0,
            "manifest.run.sample_index must be a nonnegative integer")
    require(isinstance(run["order_seed"], str)
            and ORDER_SEED_RE.fullmatch(run["order_seed"]) is not None,
            "manifest.run.order_seed must use the opaque seed-<16 hex> shape")

    product = exact_keys(manifest["product"], "manifest.product", {
        "commit", "sha256", "configuration", "target", "platform", "os_build", "xcode_build",
    })
    require(isinstance(product["commit"], str) and COMMIT_RE.fullmatch(product["commit"]) is not None,
            "manifest.product.commit must be an exact 40-character commit")
    require(isinstance(product["sha256"], str) and SHA256_RE.fullmatch(product["sha256"]) is not None,
            "manifest.product.sha256 must be a lowercase SHA-256 digest")
    require(product["configuration"] == CONFIGURATION,
            f"manifest.product.configuration must equal {CONFIGURATION}")
    enum_value(product["target"], "manifest.product.target", set(TARGETS))
    enum_value(product["platform"], "manifest.product.platform", PLATFORMS)
    require(isinstance(product["os_build"], str)
            and APPLE_BUILD_RE.fullmatch(product["os_build"]) is not None,
            "manifest.product.os_build must be an Apple build identifier")
    require(isinstance(product["xcode_build"], str)
            and APPLE_BUILD_RE.fullmatch(product["xcode_build"]) is not None,
            "manifest.product.xcode_build must be an Apple build identifier")

    device = exact_keys(manifest["device"], "manifest.device", {
        "label", "power_source", "battery_state", "thermal_state", "free_storage_bytes", "display_mode",
    })
    require(isinstance(device["label"], str) and DEVICE_LABEL_RE.fullmatch(device["label"]) is not None,
            "manifest.device.label must be an opaque local-device-NN label")
    enum_value(device["power_source"], "manifest.device.power_source", {"battery", "external", "unknown"})
    enum_value(device["battery_state"], "manifest.device.battery_state",
               {"charging", "discharging", "full", "not_applicable", "unknown"})
    enum_value(device["thermal_state"], "manifest.device.thermal_state",
               {"nominal", "fair", "serious", "critical", "unknown"})
    require(type(device["free_storage_bytes"]) is int and device["free_storage_bytes"] >= 0,
            "manifest.device.free_storage_bytes must be a nonnegative integer")
    enum_value(device["display_mode"], "manifest.device.display_mode",
               {"windowed", "fullscreen", "cinema", "immersive", "not_applicable", "unknown"})

    state = exact_keys(manifest["state"], "manifest.state", {"install_state", "container_state", "cache_reset"})
    enum_value(state["install_state"], "manifest.state.install_state",
               {"fresh_install", "upgrade", "reinstall_same_artifact", "direct_staged_artifact"})
    enum_value(state["container_state"], "manifest.state.container_state",
               {"fresh", "preserved", "restored_fixture"})
    cache = exact_keys(state["cache_reset"], "manifest.state.cache_reset", {"command_id", "result"})
    enum_value(cache["command_id"], "manifest.state.cache_reset.command_id", {
        "none", "app-cache-reset-v1", "app-container-reset-v1", "fixture-cache-seed-v1",
    })
    enum_value(cache["result"], "manifest.state.cache_reset.result", {"success", "failure", "not_requested"})

    scenario = exact_keys(manifest["scenario"], "manifest.scenario", {
        "id", "category", "run_kind", "fixture_id", "fixture_sha256", "backend_kind",
        "server_version", "cache_state",
    })
    require(isinstance(scenario["id"], str)
            and SCENARIO_ID_RE.fullmatch(scenario["id"]) is not None,
            "manifest.scenario.id must use the opaque scenario-<12 hex> shape")
    enum_value(scenario["category"], "manifest.scenario.category", {
        "launch", "home", "catalog", "search", "detail", "artwork", "music", "playback",
        "seek", "cinema", "shareplay", "download", "diagnostics", "background_recovery",
        "compile", "test", "idle", "other",
    })
    run_kind = enum_value(scenario["run_kind"], "manifest.scenario.run_kind",
                          {"deterministic_fixture", "live_server"})
    if run_kind == "deterministic_fixture":
        require(isinstance(scenario["fixture_id"], str)
                and FIXTURE_ID_RE.fullmatch(scenario["fixture_id"]) is not None,
                "manifest.scenario.fixture_id must use the opaque fixture-<12 hex> shape")
        require(isinstance(scenario["fixture_sha256"], str)
                and SHA256_RE.fullmatch(scenario["fixture_sha256"]) is not None,
                "deterministic fixture manifests require a lowercase fixture SHA-256")
        require(scenario["server_version"] is None,
                "deterministic fixture manifests must not claim a live server version")
    else:
        require(scenario["fixture_id"] is None and scenario["fixture_sha256"] is None,
                "live-server manifests must not claim a fixture identity or hash")
        require(isinstance(scenario["server_version"], str)
                and SERVER_VERSION_RE.fullmatch(scenario["server_version"]) is not None,
                "manifest.scenario.server_version must be version-shaped, never a host label")
    enum_value(scenario["backend_kind"], "manifest.scenario.backend_kind", {"plex", "jellyfin", "emby", "none"})
    enum_value(scenario["cache_state"], "manifest.scenario.cache_state", {"cold", "warm", "declared_seed"})

    if "automation" in manifest:
        automation = exact_keys(manifest["automation"], "manifest.automation", {
            "fixture_implementation_sha256", "driver_sha256", "workload_spec_sha256",
            "client_state_seed_sha256", "fixture_protocol_version", "driver_protocol_version",
        })
        for field in ("fixture_implementation_sha256", "driver_sha256", "workload_spec_sha256",
                      "client_state_seed_sha256"):
            require(isinstance(automation[field], str)
                    and SHA256_RE.fullmatch(automation[field]) is not None,
                    f"manifest.automation.{field} must be a lowercase SHA-256 digest")
        for field in ("fixture_protocol_version", "driver_protocol_version"):
            require(type(automation[field]) is int and 1 <= automation[field] <= 1_000,
                    f"manifest.automation.{field} must be a bounded positive integer")

    launch = exact_keys(manifest["launch_contract"], "manifest.launch_contract", {
        "arguments", "environment_keys", "ui_test_fixture", "live_probe", "tv_event_swizzle",
        "verbose_debug_evidence",
    })
    require(launch["arguments"] == [], "PerformanceAudit launches must not inherit scheme arguments")
    require(launch["environment_keys"] == [], "PerformanceAudit launches must not inherit scheme environment")
    for field in ("ui_test_fixture", "live_probe", "tv_event_swizzle", "verbose_debug_evidence"):
        require(launch[field] is False, f"manifest.launch_contract.{field} must be false")

    evidence = exact_keys(manifest["evidence"], "manifest.evidence", {
        "artifacts", "redacted_summary", "privacy_review", "retention_deadline", "publishable",
    })
    require(isinstance(evidence["artifacts"], list) and evidence["artifacts"],
            "manifest.evidence.artifacts must contain at least one file")
    for index, pointer in enumerate(evidence["artifacts"]):
        validate_pointer(pointer, f"manifest.evidence.artifacts[{index}]", run_dir,
                         verify_files, pointer_kind="raw")
    validate_pointer(evidence["redacted_summary"], "manifest.evidence.redacted_summary", run_dir,
                     verify_files, pointer_kind="summary")
    privacy = enum_value(evidence["privacy_review"], "manifest.evidence.privacy_review",
                         {"pending", "reviewed", "rejected"})
    parse_utc(evidence["retention_deadline"], "manifest.evidence.retention_deadline")
    require(type(evidence["publishable"]) is bool, "manifest.evidence.publishable must be a boolean")
    if evidence["publishable"]:
        require(privacy == "reviewed", "publishable evidence requires completed privacy review")
    if scenario["category"] == "idle":
        require(evidence["publishable"] is False,
                "idle System Trace evidence must remain local and non-publishable")
        if verify_files:
            validate_idle_evidence(manifest, run_dir)


def parse_build_settings(output: str) -> dict[str, str]:
    settings: dict[str, str] = {}
    for line in output.splitlines():
        match = re.match(r"^\s{4}([A-Z0-9_]+) = (.*)$", line)
        if match:
            settings[match.group(1)] = match.group(2).strip()
    return settings


def validate_optimized_settings(settings: dict[str, str], target: str) -> None:
    swift_optimization = settings.get("SWIFT_OPTIMIZATION_LEVEL", "-O")
    require(swift_optimization not in {"-Onone", "-O0"},
            f"{target}: PerformanceAudit must retain optimized Swift compilation")
    require(settings.get("GCC_OPTIMIZATION_LEVEL", "s") != "0",
            f"{target}: PerformanceAudit must retain optimized C compilation")
    require(settings.get("ENABLE_NS_ASSERTIONS") == "NO",
            f"{target}: PerformanceAudit must keep Release assertions disabled")
    require(settings.get("ENABLE_TESTABILITY") == "NO",
            f"{target}: PerformanceAudit must keep Release testability disabled")
    for sanitizer in (
        "ENABLE_ADDRESS_SANITIZER", "ENABLE_THREAD_SANITIZER",
        "ENABLE_UNDEFINED_BEHAVIOR_SANITIZER",
    ):
        require(settings.get(sanitizer, "NO") != "YES",
                f"{target}: PerformanceAudit must not enable {sanitizer}")
    swift_flags = settings.get("OTHER_SWIFT_FLAGS", "")
    c_flags = " ".join((settings.get("OTHER_CFLAGS", ""), settings.get("OTHER_CPLUSPLUSFLAGS", "")))
    definitions = settings.get("GCC_PREPROCESSOR_DEFINITIONS", "")
    require(not re.search(r"(?:^|\s)-(?:Onone|O0)(?:\s|$)", swift_flags),
            f"{target}: PerformanceAudit OTHER_SWIFT_FLAGS disable optimization")
    require(not re.search(r"(?:^|\s)-O0(?:\s|$)", c_flags),
            f"{target}: PerformanceAudit C/C++ flags disable optimization")
    require(not re.search(r"(?:^|\s)-D\s*DEBUG(?:=1)?(?:\s|$)", swift_flags),
            f"{target}: PerformanceAudit OTHER_SWIFT_FLAGS define DEBUG")
    require(not re.search(r"(?:^|\s)DEBUG(?:=1)?(?:\s|$)", definitions),
            f"{target}: PerformanceAudit C preprocessor definitions include DEBUG")


def compare_build_settings(release: dict[str, str], audit: dict[str, str], target: str) -> None:
    mismatches = [key for key in RELEASE_PARITY_KEYS if release.get(key) != audit.get(key)]
    require(not mismatches, f"{target}: PerformanceAudit differs from Release for {', '.join(mismatches)}")
    release_conditions = set(release.get("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "").split())
    audit_conditions = set(audit.get("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "").split())
    require("DEBUG" not in audit_conditions, f"{target}: PerformanceAudit must not define DEBUG")
    require(audit_conditions - release_conditions == {"PERFORMANCE_AUDIT"},
            f"{target}: profiling condition must be the only compilation-condition difference")
    require(release_conditions - audit_conditions == set(),
            f"{target}: PerformanceAudit dropped a Release compilation condition")
    validate_optimized_settings(audit, target)


def xcode_build_settings(project: pathlib.Path, target: str, configuration: str) -> dict[str, str]:
    command = [
        "/usr/bin/xcodebuild", "-project", str(project), "-target", target,
        "-configuration", configuration, "-showBuildSettings",
    ]
    result = subprocess.run(command, text=True, capture_output=True)
    require(result.returncode == 0, f"xcodebuild could not read {target} {configuration} settings")
    return parse_build_settings(result.stdout)


def check_profile_schemes(project: pathlib.Path) -> None:
    schemes = project / "xcshareddata" / "xcschemes"
    expected = {f"{target}.xcscheme" for target in TARGETS}
    actual = {path.name for path in schemes.glob("Labstream*.xcscheme")}
    require(expected <= actual, f"missing shared profiling schemes: {', '.join(sorted(expected - actual))}")
    for name in sorted(expected):
        root = ET.parse(schemes / name).getroot()
        profile = root.find("ProfileAction")
        require(profile is not None and profile.attrib.get("buildConfiguration") == CONFIGURATION,
                f"{name}: ProfileAction must use {CONFIGURATION}")
        require(profile.attrib.get("shouldUseLaunchSchemeArgsEnv") == "NO",
                f"{name}: ProfileAction must not inherit Debug launch arguments or environment")
        enabled_arguments = profile.findall("./CommandLineArguments/CommandLineArgument[@isEnabled='YES']")
        enabled_environment = profile.findall("./EnvironmentVariables/EnvironmentVariable[@isEnabled='YES']")
        require(not enabled_arguments and not enabled_environment,
                f"{name}: ProfileAction must not enable direct launch arguments or environment")
        for attribute, value in profile.attrib.items():
            if "sanitizer" in attribute.lower():
                require(value != "YES", f"{name}: ProfileAction must not enable {attribute}")


def check_configuration(project: pathlib.Path) -> None:
    check_profile_schemes(project)
    for target in TARGETS:
        release = xcode_build_settings(project, target, "Release")
        audit = xcode_build_settings(project, target, CONFIGURATION)
        compare_build_settings(release, audit, target)


def app_executable(app: pathlib.Path) -> pathlib.Path:
    plist = app / "Contents" / "Info.plist"
    if not plist.is_file():
        plist = app / "Info.plist"
    require(plist.is_file(), "app bundle is missing Info.plist")
    with plist.open("rb") as handle:
        info = plistlib.load(handle)
    executable_name = info.get("CFBundleExecutable")
    require(isinstance(executable_name, str) and executable_name != "", "Info.plist is missing CFBundleExecutable")
    executable = app / "Contents" / "MacOS" / executable_name
    if not executable.is_file():
        executable = app / executable_name
    require(executable.is_file(), "app bundle is missing its declared executable")
    environment = info.get("LSEnvironment", {})
    require(not environment, "PerformanceAudit app must not embed launch environment variables")
    return executable


def check_binary(app: pathlib.Path) -> None:
    executable = app_executable(app)
    payload = executable.read_bytes()
    failures = [
        category for category, markers in FORBIDDEN_BINARY_MARKERS.items()
        if any(marker in payload for marker in markers)
    ]
    require(not failures, f"PerformanceAudit binary contains forbidden contracts: {', '.join(failures)}")
    missing = [marker.decode("ascii") for marker in REQUIRED_AUDIT_BINARY_MARKERS if marker not in payload]
    require(not missing, "PerformanceAudit binary is missing profiling markers")


def read_manifest(path: pathlib.Path) -> Any:
    try:
        return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise ContractError("manifest is not readable JSON") from error


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    manifest_parser = subparsers.add_parser("manifest", help="validate manifest metadata and artifact checksums")
    manifest_parser.add_argument("path", type=pathlib.Path)
    manifest_parser.add_argument("--metadata-only", action="store_true",
                                 help="validate metadata without reading artifact files")

    binary_parser = subparsers.add_parser("binary", help="check a built PerformanceAudit .app")
    binary_parser.add_argument("app", type=pathlib.Path)

    configuration_parser = subparsers.add_parser("configuration", help="compare PerformanceAudit with Release")
    configuration_parser.add_argument("project", type=pathlib.Path, nargs="?", default=pathlib.Path("Labstream.xcodeproj"))

    args = parser.parse_args(argv)
    try:
        if args.command == "manifest":
            path = args.path.resolve()
            validate_manifest(read_manifest(path), path.parent, verify_files=not args.metadata_only)
        elif args.command == "binary":
            check_binary(args.app.resolve())
        else:
            check_configuration(args.project.resolve())
    except ContractError as error:
        print(f"performance-audit-contract: FAIL: {error}", file=sys.stderr)
        return 1
    print(f"performance-audit-contract: ok command={args.command} schema={TOOL_VERSION}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
