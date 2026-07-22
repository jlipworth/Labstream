#!/usr/bin/env python3
"""Run a paired, opt-in Labstream compile-cost audit (see --help)."""
from __future__ import annotations

import argparse
import csv
import datetime as dt
import hashlib
import json
import os
import pathlib
import platform
import plistlib
import re
import shutil
import statistics
import subprocess
from dataclasses import dataclass

ROOT = pathlib.Path(__file__).resolve().parents[1]
APP_EDIT_FILES = (
    "PMSKit/Sources/PMSKit/Playback/PlaybackFailurePolicy.swift",
    "Labstream/Shared/UI/ProgressSliver.swift",
    "Labstream/Shared/Player/PlaybackController.swift",
)
PMS_EDIT_FILE = "PMSKit/Sources/PMSKit/Playback/PlaybackFailurePolicy.swift"
MIN_REPETITIONS = 5
LIVE_ENV_PREFIXES = ("PLEX_LIVE_", "EMBY_LIVE_", "JELLYFIN_")
TYPECHECK_RE = re.compile(
    r"(?P<kind>instance\s+method|class\s+method|static\s+method|operator\s+function|"
    r"function|expression|getter|setter|initializer|deinitializer|subscript|closure)"
    r"(?:\s+[^\r\n]*?)?\s+took\s+(?P<ms>[0-9]+(?:\.[0-9]+)?)ms\b",
    re.I,
)
RSS_RE = re.compile(r"(?P<n>[0-9]+)\s+maximum resident set size")
REAL_RE = re.compile(r"^real\s+(?P<n>[0-9]+(?:\.[0-9]+)?)$", re.M)


@dataclass(frozen=True)
class Lane:
    name: str
    scheme: str
    destination: str


LANES = (
    Lane("visionos", "Labstream", "generic/platform=visionOS Simulator"),
    Lane("mobile", "LabstreamMobile", "generic/platform=iOS Simulator"),
    Lane("tvos", "LabstreamTV", "generic/platform=tvOS Simulator"),
    Lane("mac", "LabstreamMac", "generic/platform=macOS"),
)


def checked_output(argv: list[str], *, cwd: pathlib.Path = ROOT) -> str:
    return subprocess.check_output(argv, cwd=cwd, text=True, stderr=subprocess.STDOUT).strip()


def run_checked(argv: list[str], *, cwd: pathlib.Path, stdout=None) -> None:
    subprocess.run(argv, cwd=cwd, check=True, stdout=stdout)


def resolve_commit(reference: str) -> str:
    return checked_output(["git", "rev-parse", "--verify", f"{reference}^{{commit}}"])


def missing_edit_paths(commits: dict[str, str]) -> list[str]:
    missing = []
    paths = sorted(set(APP_EDIT_FILES) | {PMS_EDIT_FILE})
    for variant, commit in commits.items():
        for path in paths:
            result = subprocess.run(
                ["git", "cat-file", "-e", f"{commit}:{path}"], cwd=ROOT,
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            if result.returncode != 0:
                missing.append(f"{variant}:{path}")
    return missing


def snapshot(reference: str, destination: pathlib.Path) -> str:
    """Export exactly one committed tree; never copy the caller's working tree."""
    commit = resolve_commit(reference)
    archive = destination.parent / f"{destination.name}.tar"
    with archive.open("wb") as output:
        run_checked(["git", "archive", commit], cwd=ROOT, stdout=output)
    destination.mkdir()
    run_checked(["tar", "-xf", str(archive), "-C", str(destination)], cwd=ROOT)
    archive.unlink()
    return commit


def command_for_xcode(source: pathlib.Path, dd: pathlib.Path, lane: Lane) -> list[str]:
    return [
        "xcodebuild", "-project", str(source / "Labstream.xcodeproj"),
        "-scheme", lane.scheme, "-configuration", "Debug",
        "-destination", lane.destination, "-derivedDataPath", str(dd),
        "ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES", "CODE_SIGNING_ALLOWED=NO",
        "OTHER_SWIFT_FLAGS=$(inherited) -Xfrontend -warn-long-function-bodies=300 "
        "-Xfrontend -warn-long-expression-type-checking=200",
        "-showBuildTimingSummary", "build",
    ]


def command_for_pms(source: pathlib.Path, scratch: pathlib.Path, scenario: str) -> list[str]:
    action = "test" if scenario == "test_coverage" else "build"
    command = ["swift", action, "--package-path", str(source / "PMSKit"),
               "--scratch-path", str(scratch), "--configuration", "debug", "--arch", "arm64"]
    if action == "test":
        command += ["--enable-code-coverage", "--skip", "Live.*ProbeTests"]
    command += ["-Xswiftc", "-Xfrontend", "-Xswiftc", "-warn-long-function-bodies=300",
                "-Xswiftc", "-Xfrontend", "-Xswiftc", "-warn-long-expression-type-checking=200"]
    return command


def product_sizes(dd: pathlib.Path, lane: str) -> tuple[int, int]:
    candidates = list((dd / "Build/Products").glob("Debug*/Labstream.app"))
    if not candidates:
        return 0, 0
    app = candidates[0]
    total = sum(p.stat().st_size for p in app.rglob("*") if p.is_file())
    plist = app / ("Contents/Info.plist" if lane == "mac" else "Info.plist")
    executable_size = 0
    if plist.exists():
        executable = plistlib.loads(plist.read_bytes()).get("CFBundleExecutable")
        binary = app / (f"Contents/MacOS/{executable}" if lane == "mac" else str(executable))
        if binary.is_file():
            executable_size = binary.stat().st_size
    return total, executable_size


def normalize_warning(line: str) -> str:
    message = line.split("warning:", 1)[1].strip()
    message = re.sub(r"https?://\S+", "<redacted-url>", message)
    message = re.sub(r"(?:/[A-Za-z0-9_.+-]+){2,}", "<redacted-path>", message)
    message = re.sub(r'(["\']).*?\1', "<redacted-value>", message)
    return message[:300]


def safe_output(argv: list[str]) -> str:
    try:
        return checked_output(argv)
    except (OSError, subprocess.CalledProcessError):
        return "unknown"


def host_covariates(output: pathlib.Path) -> dict[str, object]:
    usage = shutil.disk_usage(output)
    return {
        "hardware_model": safe_output(["sysctl", "-n", "hw.model"]),
        "physical_cpu_count": safe_output(["sysctl", "-n", "hw.physicalcpu"]),
        "logical_cpu_count": safe_output(["sysctl", "-n", "hw.logicalcpu"]),
        "memory_bytes": safe_output(["sysctl", "-n", "hw.memsize"]),
        "macos_version": platform.mac_ver()[0] or "unknown",
        "macos_sw_vers": safe_output(["sw_vers"]),
        "machine_architecture": platform.machine(),
        "load_average_at_start": list(os.getloadavg()),
        "free_disk_bytes_at_start": usage.free,
        "power_at_start": safe_output(["pmset", "-g", "batt"]),
    }


def machine_label(covariates: dict[str, object] | None = None) -> str:
    facts = covariates or host_covariates(ROOT)
    return f"{facts['hardware_model']} / macOS {facts['macos_version']}"


def variant_order(repetition: int, seed: int) -> tuple[str, str]:
    """Alternate A/B order by paired index; seed deterministically selects the first order."""
    control_first = (repetition + seed) % 2 == 1
    return ("control", "candidate") if control_first else ("candidate", "control")


def isolated_environment() -> dict[str, str]:
    """Exclude all opt-in live-media probe credentials from measured commands."""
    return {
        key: value for key, value in os.environ.items()
        if not any(key.startswith(prefix) for prefix in LIVE_ENV_PREFIXES)
    }


def make_log_private(path: pathlib.Path) -> None:
    path.chmod(0o600)


def measure(command: list[str], *, cwd: pathlib.Path, log: pathlib.Path,
            variant: str, commit: str, pair_order: int, group: str, lane: str,
            scenario: str, repetition: int, dd: pathlib.Path | None,
            env: dict[str, str] | None = None) -> dict[str, object]:
    with log.open("w") as output:
        result = subprocess.run(["/usr/bin/time", "-lp", *command], cwd=cwd,
                                stdout=output, stderr=subprocess.STDOUT, text=True, env=env)
    make_log_private(log)
    text = log.read_text(errors="replace")
    warnings = sorted({normalize_warning(line) for line in text.splitlines() if "warning:" in line})
    warning_path = log.with_suffix(".warnings.txt")
    warning_path.write_text("\n".join(warnings) + ("\n" if warnings else ""))
    make_log_private(warning_path)
    rss = RSS_RE.search(text)
    elapsed = REAL_RE.search(text)
    typechecks = [float(m.group("ms")) for m in TYPECHECK_RE.finditer(text)]
    app_bytes, mach_o_bytes = product_sizes(dd, lane) if dd else (0, 0)
    return {
        "variant": variant, "commit": commit, "pair_order": pair_order,
        "group": group, "lane": lane, "scenario": scenario, "repetition": repetition,
        "result": result.returncode, "valid": True, "invalid_reason": "",
        "restoration_result": "", "restoration_source_match": "",
        "seconds": float(elapsed.group("n")) if elapsed else 0,
        "peak_rss_bytes": int(rss.group("n")) if rss else 0,
        "warning_count": len(warnings),
        "typecheck_over_threshold_count": len(typechecks),
        "max_typecheck_ms": max(typechecks, default=0),
        "compiled_file_count": len(re.findall(r"^(?:SwiftCompile .* Compiling|\[[0-9]+/[0-9]+\] Compiling)\b", text, re.M)),
        "link_count": len(re.findall(r"^(?:Ld\b|\[[0-9]+/[0-9]+\] Linking\b)", text, re.M)),
        "product_bytes": app_bytes, "mach_o_bytes": mach_o_bytes,
        "log": log.name, "restoration_log": "",
    }


def temporary_edit(path: pathlib.Path) -> bytes:
    original = path.read_bytes()
    path.write_bytes(original + b"\n// compile-audit representative edit\n")
    return original


def settle_restoration(command: list[str], *, cwd: pathlib.Path, log: pathlib.Path,
                       env: dict[str, str] | None = None) -> int:
    """Build after restoring an edit and return a checked, recorded result."""
    with log.open("w") as output:
        result = subprocess.run(
            command, cwd=cwd, stdout=output, stderr=subprocess.STDOUT, text=True, env=env)
    make_log_private(log)
    return result.returncode


def source_matches_restoration(path: pathlib.Path, original: bytes) -> bool:
    return path.read_bytes() == original


def skipped_measurement(*, variant: str, commit: str, pair_order: int, group: str,
                        lane: str, scenario: str, repetition: int, reason: str) -> dict[str, object]:
    return {
        "variant": variant, "commit": commit, "pair_order": pair_order,
        "group": group, "lane": lane, "scenario": scenario, "repetition": repetition,
        "result": 125, "valid": False, "invalid_reason": reason,
        "restoration_result": "", "restoration_source_match": "",
        "seconds": 0, "peak_rss_bytes": 0, "warning_count": 0,
        "typecheck_over_threshold_count": 0, "max_typecheck_ms": 0,
        "compiled_file_count": 0, "link_count": 0, "product_bytes": 0,
        "mach_o_bytes": 0, "log": "", "restoration_log": "",
    }


METRICS = (
    "seconds", "peak_rss_bytes", "product_bytes", "mach_o_bytes",
    "compiled_file_count", "link_count", "warning_count", "max_typecheck_ms",
)


def measurement_is_usable(row: dict[str, object]) -> bool:
    return (
        bool(row.get("valid", True))
        and int(row["result"]) == 0
        and row.get("restoration_result", "") in ("", 0)
        and row.get("restoration_source_match", "") in ("", True)
    )


def paired_deltas(rows: list[dict[str, object]]) -> list[dict[str, object]]:
    indexed: dict[tuple[str, str, str, int], dict[str, dict[str, object]]] = {}
    for row in rows:
        if not measurement_is_usable(row):
            continue
        key = (str(row["group"]), str(row["lane"]), str(row["scenario"]), int(row["repetition"]))
        indexed.setdefault(key, {})[str(row["variant"])] = row
    deltas: list[dict[str, object]] = []
    for key, variants in sorted(indexed.items()):
        if set(variants) != {"control", "candidate"}:
            continue
        control, candidate = variants["control"], variants["candidate"]
        item: dict[str, object] = {
            "group": key[0], "lane": key[1], "scenario": key[2], "repetition": key[3],
            "control_result": control["result"], "candidate_result": candidate["result"],
        }
        for metric in METRICS:
            a, b = float(control[metric]), float(candidate[metric])
            item[f"control_{metric}"] = a
            item[f"candidate_{metric}"] = b
            item[f"delta_{metric}"] = b - a
            item[f"delta_percent_{metric}"] = ((b - a) / a * 100) if a else ""
        deltas.append(item)
    return deltas


def write_csv(path: pathlib.Path, rows: list[dict[str, object]],
              fieldnames: tuple[str, ...] | None = None) -> None:
    columns = list(rows[0]) if rows else list(fieldnames or ())
    with path.open("w", newline="") as file:
        writer = csv.DictWriter(file, fieldnames=columns)
        writer.writeheader()
        writer.writerows(rows)


def write_results(output: pathlib.Path, rows: list[dict[str, object]], metadata: dict[str, object]) -> None:
    write_csv(output / "measurements.csv", rows)
    deltas = paired_deltas(rows)
    paired_fields = (
        "group", "lane", "scenario", "repetition", "control_result", "candidate_result",
        *(field for metric in METRICS for field in (
            f"control_{metric}", f"candidate_{metric}", f"delta_{metric}",
            f"delta_percent_{metric}",
        )),
    )
    write_csv(output / "paired-deltas.csv", deltas, paired_fields)
    groups: dict[tuple[str, str, str], list[dict[str, object]]] = {}
    for row in rows:
        groups.setdefault((str(row["group"]), str(row["lane"]), str(row["scenario"])), []).append(row)
    xcode_lines = str(metadata["toolchain"]["xcodebuild"]).splitlines()
    host = metadata["host_covariates"]
    lines = [
        "# Paired compile audit summary", "",
        f"- Control: `{str(metadata['commits']['control'])[:12]}`",
        f"- Candidate: `{str(metadata['commits']['candidate'])[:12]}`",
        f"- Paired samples per scenario: {metadata['repetitions']}",
        f"- Order seed: `{metadata['seed']}` (same-index order alternates A/B)",
        f"- Toolchain: `{' / '.join(xcode_lines)}`",
        f"- Host: `{machine_label(host)}`", "- Architecture: `arm64`", "",
        "| group | lane | scenario | control median s | candidate median s | paired median delta s | paired median delta % | control status | candidate status |",
        "| --- | --- | --- | ---: | ---: | ---: | ---: | --- | --- |",
    ]
    for key, values in sorted(groups.items()):
        by_variant = {v: [r for r in values if r["variant"] == v] for v in ("control", "candidate")}
        successful = {
            variant: [r for r in by_variant[variant] if measurement_is_usable(r)]
            for variant in ("control", "candidate")
        }
        control_seconds = [float(r["seconds"]) for r in successful["control"]]
        candidate_seconds = [float(r["seconds"]) for r in successful["candidate"]]
        matching = [d for d in deltas if (d["group"], d["lane"], d["scenario"]) == key]
        delta_seconds = statistics.median(float(d["delta_seconds"]) for d in matching) if matching else None
        delta_percent_values = [float(d["delta_percent_seconds"]) for d in matching if d["delta_percent_seconds"] != ""]
        delta_percent = statistics.median(delta_percent_values) if delta_percent_values else None
        statuses = []
        for variant in ("control", "candidate"):
            statuses.append("pass" if all(
                int(r["result"]) == 0
                and bool(r.get("valid", True))
                and r["restoration_result"] in ("", 0)
                and r["restoration_source_match"] in ("", True)
                for r in by_variant[variant]
            ) else "FAIL")
        control_text = f"{statistics.median(control_seconds):.2f}" if control_seconds else "n/a"
        candidate_text = f"{statistics.median(candidate_seconds):.2f}" if candidate_seconds else "n/a"
        delta_text = f"{delta_seconds:+.2f}" if delta_seconds is not None else "n/a"
        percent_text = f"{delta_percent:+.1f}%" if delta_percent is not None else "n/a"
        lines.append(f"| {' | '.join(key)} | {control_text} | {candidate_text} | {delta_text} | "
                     f"{percent_text} | {statuses[0]} | {statuses[1]} |")
    lines += [
        "", "> These are descriptive paired summaries of five or more local samples. They do not establish statistical significance.",
        "> Raw logs may contain local paths and remain private in the ignored output directory. Verify `manifest.sha256` before sharing selected artifacts.",
    ]
    (output / "summary.md").write_text("\n".join(lines) + "\n")


def write_integrity_manifest(output: pathlib.Path) -> None:
    """Checksum result artifacts and private logs, excluding large disposable workspaces."""
    entries = []
    for path in sorted(output.rglob("*")):
        if not path.is_file() or path.name == "manifest.sha256" or "workspace" in path.parts:
            continue
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        entries.append(f"{digest}  {path.relative_to(output)}")
    (output / "manifest.sha256").write_text("\n".join(entries) + "\n")


def print_plan(repetitions: int, control: str | None, candidate: str | None, seed: int) -> None:
    print(f"architecture: arm64\nrepetitions: {repetitions}\nseed: {seed}")
    print(f"control: {control or '<required with --run>'}\ncandidate: {candidate or '<required with --run>'}")
    print("order: same-index A/B, B/A alternating")
    print("pmskit: cold, no_op, incremental_PlaybackFailurePolicy, checked restoration, test_coverage")
    for lane in LANES:
        edits = ", ".join(f"incremental_{pathlib.Path(p).stem}" for p in APP_EDIT_FILES)
        print(f"{lane.name}: clean, no_op, {edits} (checked restoration after each edit)")


def run_repetition(*, output: pathlib.Path, commits: dict[str, str],
                   sources: dict[str, pathlib.Path], repetition: int, seed: int,
                   rows: list[dict[str, object]]) -> None:
    """Run each scenario as an adjacent A/B pair while preserving per-variant build state."""
    order = variant_order(repetition, seed)
    pair_positions = {variant: index for index, variant in enumerate(order, start=1)}
    prefixes = {variant: f"{repetition:02d}-{pair_positions[variant]}-{variant}" for variant in order}
    scratches = {variant: output / "workspace" / f"pms-{prefixes[variant]}" for variant in order}
    pms_valid = {variant: True for variant in order}
    audit_env = isolated_environment()

    def skip(variant: str, *, group: str, lane: str, scenario: str, reason: str) -> None:
        rows.append(skipped_measurement(
            variant=variant, commit=commits[variant], pair_order=pair_positions[variant],
            group=group, lane=lane, scenario=scenario, repetition=repetition, reason=reason))

    for scenario in ("cold", "no_op"):
        for variant in order:
            if not pms_valid[variant]:
                skip(variant, group="pmskit", lane="pmskit", scenario=scenario,
                     reason="invalidated by earlier PMSKit prerequisite failure")
                continue
            row = measure(
                command_for_pms(sources[variant], scratches[variant], scenario),
                cwd=sources[variant], log=output / f"{prefixes[variant]}-pmskit-{scenario}.log",
                variant=variant, commit=commits[variant], pair_order=pair_positions[variant],
                group="pmskit", lane="pmskit", scenario=scenario, repetition=repetition, dd=None,
                env=audit_env)
            rows.append(row)
            pms_valid[variant] = int(row["result"]) == 0

    pms_incremental = "incremental_PlaybackFailurePolicy"
    measured_pms_incrementals: dict[str, dict[str, object]] = {}
    for variant in order:
        if not pms_valid[variant]:
            skip(variant, group="pmskit", lane="pmskit", scenario=pms_incremental,
                 reason="invalidated by earlier PMSKit prerequisite failure")
            continue
        edit_path = sources[variant] / PMS_EDIT_FILE
        original = temporary_edit(edit_path)
        try:
            row = measure(
                command_for_pms(sources[variant], scratches[variant], "incremental"),
                cwd=sources[variant], log=output / f"{prefixes[variant]}-pmskit-incremental.log",
                variant=variant, commit=commits[variant], pair_order=pair_positions[variant],
                group="pmskit", lane="pmskit", scenario=pms_incremental,
                repetition=repetition, dd=None, env=audit_env)
        finally:
            edit_path.write_bytes(original)
        row["restoration_source_match"] = source_matches_restoration(edit_path, original)
        measured_pms_incrementals[variant] = row

    # Keep the measured A/B pair adjacent. Restoration settles are intentionally deferred until
    # both variants have been measured, then recorded against their owning rows.
    for variant in order:
        row = measured_pms_incrementals.get(variant)
        if row is None:
            continue
        restoration_log = output / f"{prefixes[variant]}-pmskit-restoration-settle.log"
        row["restoration_log"] = restoration_log.name
        row["restoration_result"] = settle_restoration(
            command_for_pms(sources[variant], scratches[variant], "settle"),
            cwd=sources[variant], log=restoration_log, env=audit_env)
        rows.append(row)
        pms_valid[variant] = (
            int(row["result"]) == 0 and row["restoration_result"] == 0
            and row["restoration_source_match"] is True)

    for variant in order:
        if not pms_valid[variant]:
            skip(variant, group="pmskit", lane="pmskit", scenario="test_coverage",
                 reason="invalidated by earlier PMSKit prerequisite failure")
            continue
        row = measure(
            command_for_pms(sources[variant], scratches[variant], "test_coverage"),
            cwd=sources[variant], log=output / f"{prefixes[variant]}-pmskit-test_coverage.log",
            variant=variant, commit=commits[variant], pair_order=pair_positions[variant],
            group="pmskit", lane="pmskit", scenario="test_coverage", repetition=repetition,
            dd=None, env=audit_env)
        rows.append(row)
        pms_valid[variant] = int(row["result"]) == 0

    for lane in LANES:
        derived = {
            variant: output / "workspace" / f"dd-{lane.name}-{prefixes[variant]}"
            for variant in order
        }
        lane_valid = {variant: True for variant in order}
        for scenario in ("clean", "no_op"):
            for variant in order:
                if not lane_valid[variant]:
                    skip(variant, group="app", lane=lane.name, scenario=scenario,
                         reason=f"invalidated by earlier {lane.name} prerequisite failure")
                    continue
                row = measure(
                    command_for_xcode(sources[variant], derived[variant], lane),
                    cwd=sources[variant], log=output / f"{prefixes[variant]}-{lane.name}-{scenario}.log",
                    variant=variant, commit=commits[variant], pair_order=pair_positions[variant],
                    group="app", lane=lane.name, scenario=scenario, repetition=repetition,
                    dd=derived[variant], env=audit_env)
                rows.append(row)
                lane_valid[variant] = int(row["result"]) == 0
        for edit in APP_EDIT_FILES:
            scenario = "incremental_" + pathlib.Path(edit).stem
            measured_incrementals: dict[str, dict[str, object]] = {}
            for variant in order:
                if not lane_valid[variant]:
                    skip(variant, group="app", lane=lane.name, scenario=scenario,
                         reason=f"invalidated by earlier {lane.name} prerequisite failure")
                    continue
                path = sources[variant] / edit
                original = temporary_edit(path)
                try:
                    row = measure(
                        command_for_xcode(sources[variant], derived[variant], lane),
                        cwd=sources[variant],
                        log=output / f"{prefixes[variant]}-{lane.name}-{scenario}.log",
                        variant=variant, commit=commits[variant], pair_order=pair_positions[variant],
                        group="app", lane=lane.name, scenario=scenario,
                        repetition=repetition, dd=derived[variant], env=audit_env)
                finally:
                    path.write_bytes(original)
                row["restoration_source_match"] = source_matches_restoration(path, original)
                measured_incrementals[variant] = row

            # Do not insert either variant's unmeasured settle build between the paired samples.
            for variant in order:
                row = measured_incrementals.get(variant)
                if row is None:
                    continue
                restoration_log = output / f"{prefixes[variant]}-{lane.name}-{scenario}-restoration-settle.log"
                row["restoration_log"] = restoration_log.name
                row["restoration_result"] = settle_restoration(
                    command_for_xcode(sources[variant], derived[variant], lane),
                    cwd=sources[variant], log=restoration_log, env=audit_env)
                rows.append(row)
                lane_valid[variant] = (
                    int(row["result"]) == 0 and row["restoration_result"] == 0
                    and row["restoration_source_match"] is True)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true", help="perform the long-running audit; otherwise print its plan")
    parser.add_argument("--control", help="control git commit/ref (required with --run)")
    parser.add_argument("--candidate", help="candidate git commit/ref (required with --run)")
    parser.add_argument("--repetitions", type=int, default=MIN_REPETITIONS,
                        help=f"paired runs per scenario (minimum/default: {MIN_REPETITIONS})")
    parser.add_argument("--seed", type=int, default=0, help="deterministic A/B starting-order seed (default: 0)")
    parser.add_argument("--output", type=pathlib.Path, help="private output directory (default: build/compile-audit/<UTC>)")
    args = parser.parse_args(argv)
    if args.repetitions < MIN_REPETITIONS:
        parser.error(f"--repetitions must be at least {MIN_REPETITIONS}")
    if not args.run:
        print_plan(args.repetitions, args.control, args.candidate, args.seed)
        return 0
    if not args.control or not args.candidate:
        parser.error("--control and --candidate are required with --run")
    control_commit, candidate_commit = resolve_commit(args.control), resolve_commit(args.candidate)
    if control_commit == candidate_commit:
        parser.error("--control and --candidate must resolve to different commits")
    missing = missing_edit_paths({"control": control_commit, "candidate": candidate_commit})
    if missing:
        parser.error("representative edit path missing from compared snapshot(s): " + ", ".join(missing))
    output = (args.output or ROOT / "build/compile-audit" / dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")).resolve()
    if output.exists():
        parser.error(f"output already exists: {output}")
    output.mkdir(parents=True, mode=0o700)
    output.chmod(0o700)
    started = dt.datetime.now(dt.timezone.utc)
    metadata: dict[str, object] = {
        "schema_version": 2, "started_at_utc": started.isoformat(),
        "commits": {"control": control_commit, "candidate": candidate_commit},
        "requested_refs": {"control": args.control, "candidate": args.candidate},
        "repetitions": args.repetitions, "seed": args.seed,
        "pair_orders": {str(i): list(variant_order(i, args.seed)) for i in range(1, args.repetitions + 1)},
        "configuration": "Debug", "architecture": "arm64",
        "destinations": {lane.name: lane.destination for lane in LANES},
        "toolchain": {
            "xcodebuild": safe_output(["xcodebuild", "-version"]),
            "xcode_select_path": safe_output(["xcode-select", "-p"]),
            "swift": safe_output(["swift", "--version"]),
            "git": safe_output(["git", "--version"]),
        },
        "build_environment": {
            key: os.environ.get(key, "<unset>")
            for key in ("DEVELOPER_DIR", "SDKROOT", "TOOLCHAINS")
        },
        "host_covariates": host_covariates(output),
        "runner": {
            "sha256": hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest(),
            "repository_commit": resolve_commit("HEAD"),
            "worktree_status": safe_output(["git", "status", "--porcelain", "--", "scripts/compile-audit.py"]),
        },
    }
    shutil.copy2(pathlib.Path(__file__), output / "runner-source.py")
    sources = {
        "control": output / "workspace" / "control-source",
        "candidate": output / "workspace" / "candidate-source",
    }
    sources["control"].parent.mkdir()
    exported = {variant: snapshot(commit, sources[variant]) for variant, commit in
                (("control", control_commit), ("candidate", candidate_commit))}
    if exported != {"control": control_commit, "candidate": candidate_commit}:
        raise RuntimeError("exported snapshot commit mismatch")
    rows: list[dict[str, object]] = []
    commits = {"control": control_commit, "candidate": candidate_commit}
    for repetition in range(1, args.repetitions + 1):
        run_repetition(output=output, commits=commits, sources=sources,
                       repetition=repetition, seed=args.seed, rows=rows)
    failures = [
        {"variant": row["variant"], "lane": row["lane"], "scenario": row["scenario"],
         "repetition": row["repetition"], "result": row["result"],
         "restoration_result": row["restoration_result"],
         "restoration_source_match": row["restoration_source_match"],
         "valid": row["valid"], "invalid_reason": row["invalid_reason"],
         "log": row["log"], "restoration_log": row["restoration_log"]}
        for row in rows if (
            int(row["result"]) != 0
            or not bool(row["valid"])
            or row["restoration_result"] not in ("", 0)
            or row["restoration_source_match"] not in ("", True)
        )
    ]
    metadata["completed_at_utc"] = dt.datetime.now(dt.timezone.utc).isoformat()
    metadata["host_covariates_at_end"] = host_covariates(output)
    metadata["failure_count"] = len(failures)
    metadata["failures"] = failures
    (output / "metadata.json").write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n")
    write_results(output, rows, metadata)
    write_integrity_manifest(output)
    print(output / "summary.md")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
