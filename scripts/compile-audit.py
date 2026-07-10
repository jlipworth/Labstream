#!/usr/bin/env python3
"""Run the opt-in Labstream compile-cost baseline (see --help)."""
from __future__ import annotations

import argparse
import csv
import datetime as dt
import pathlib
import platform
import plistlib
import re
import statistics
import subprocess
from dataclasses import dataclass

ROOT = pathlib.Path(__file__).resolve().parents[1]
EDIT_FILES = (
    "PMSKit/Sources/PMSKit/Playback/PlaybackFailurePolicy.swift",
    "Labstream/UI/ProgressSliver.swift",
    "Labstream/Player/PlaybackController.swift",
)
TYPECHECK_RE = re.compile(r"(?P<kind>function|expression).*?(?P<ms>[0-9]+(?:\.[0-9]+)?)ms", re.I)
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
    Lane("mac", "LabstreamMac", "generic/platform=macOS"),
)


def run_checked(argv: list[str], *, cwd: pathlib.Path, stdout=None) -> None:
    subprocess.run(argv, cwd=cwd, check=True, stdout=stdout)


def snapshot(destination: pathlib.Path) -> str:
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    archive = destination.parent / "source.tar"
    with archive.open("wb") as output:
        run_checked(["git", "archive", "HEAD"], cwd=ROOT, stdout=output)
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
        command.append("--enable-code-coverage")
    command += ["-Xswiftc", "-Xfrontend", "-Xswiftc", "-warn-long-function-bodies=300",
                "-Xswiftc", "-Xfrontend", "-Xswiftc", "-warn-long-expression-type-checking=200"]
    return command


def product_sizes(dd: pathlib.Path, lane: str) -> tuple[int, int]:
    # All three targets currently emit Labstream.app. ``Debug*`` covers macOS's
    # unqualified Debug directory and the simulator SDK-qualified directories.
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


def machine_label() -> str:
    """Return comparison-relevant hardware/OS facts without a hostname or device ID."""
    try:
        model = subprocess.check_output(["sysctl", "-n", "hw.model"], text=True).strip()
    except (OSError, subprocess.CalledProcessError):
        model = "unknown"
    return f"{model} / macOS {platform.mac_ver()[0] or 'unknown'}"


def measure(command: list[str], *, cwd: pathlib.Path, log: pathlib.Path,
            group: str, lane: str, scenario: str, repetition: int, dd: pathlib.Path | None) -> dict[str, object]:
    with log.open("w") as output:
        result = subprocess.run(["/usr/bin/time", "-lp", *command], cwd=cwd,
                                stdout=output, stderr=subprocess.STDOUT, text=True)
    text = log.read_text(errors="replace")
    warnings = sorted({normalize_warning(line) for line in text.splitlines() if "warning:" in line})
    (log.with_suffix(".warnings.txt")).write_text("\n".join(warnings) + ("\n" if warnings else ""))
    rss = RSS_RE.search(text)
    elapsed = REAL_RE.search(text)
    typechecks = [float(m.group("ms")) for m in TYPECHECK_RE.finditer(text)]
    app_bytes, mach_o_bytes = product_sizes(dd, lane) if dd else (0, 0)
    return {
        "group": group, "lane": lane, "scenario": scenario, "repetition": repetition,
        "result": result.returncode, "seconds": float(elapsed.group("n")) if elapsed else 0,
        "peak_rss_bytes": int(rss.group("n")) if rss else 0,
        "warning_count": len(warnings),
        "typecheck_over_threshold_count": len(typechecks),
        "max_typecheck_ms": max(typechecks, default=0),
        "compiled_file_count": len(re.findall(r"^(?:SwiftCompile .* Compiling|\[[0-9]+/[0-9]+\] Compiling)\b", text, re.M)),
        "link_count": len(re.findall(r"^(?:Ld\b|\[[0-9]+/[0-9]+\] Linking\b)", text, re.M)),
        "product_bytes": app_bytes, "mach_o_bytes": mach_o_bytes,
    }


def temporary_edit(path: pathlib.Path):
    original = path.read_bytes()
    path.write_bytes(original + b"\n// compile-audit representative edit\n")
    return original


def write_results(output: pathlib.Path, rows: list[dict[str, object]], commit: str, repetitions: int) -> None:
    fields = list(rows[0])
    with (output / "measurements.csv").open("w", newline="") as file:
        writer = csv.DictWriter(file, fieldnames=fields)
        writer.writeheader(); writer.writerows(rows)
    groups: dict[tuple[str, str, str], list[dict[str, object]]] = {}
    for row in rows:
        groups.setdefault((str(row["group"]), str(row["lane"]), str(row["scenario"])), []).append(row)
    xcode = subprocess.check_output(["xcodebuild", "-version"], text=True).splitlines()
    lines = ["# Compile audit summary", "", f"- Commit: `{commit[:12]}`", f"- Runs per scenario: {repetitions}",
             f"- Toolchain: {xcode[0]}", f"- Host: `{machine_label()}`", "- Architecture: `arm64`", "",
             "| group | lane | scenario | median seconds | median peak RSS MiB | median app MiB | median Mach-O MiB | compile files | links | warnings | max type-check ms | status |",
             "| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |"]
    for key, values in sorted(groups.items()):
        med = lambda field: statistics.median(float(v[field]) for v in values)
        status = "pass" if all(int(v["result"]) == 0 for v in values) else "FAIL"
        lines.append(f"| {' | '.join(key)} | {med('seconds'):.2f} | {med('peak_rss_bytes') / 1048576:.1f} | "
                     f"{med('product_bytes') / 1048576:.1f} | {med('mach_o_bytes') / 1048576:.1f} | {med('compiled_file_count'):.0f} | {med('link_count'):.0f} | "
                     f"{med('warning_count'):.0f} | {max(float(v['max_typecheck_ms']) for v in values):.1f} | {status} |")
    lines += ["", "> Thresholds are review triggers, not CI failures. Raw logs may contain local paths and remain in the ignored output directory."]
    (output / "summary.md").write_text("\n".join(lines) + "\n")


def print_plan(repetitions: int) -> None:
    print(f"architecture: arm64\nrepetitions: {repetitions}\nsource: committed HEAD snapshot")
    print("pmskit: cold, no_op, test_coverage")
    for lane in LANES:
        print(f"{lane.name}: clean, no_op, " + ", ".join(f"incremental_{pathlib.Path(p).stem}" for p in EDIT_FILES))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true", help="perform the long-running audit; otherwise print its plan")
    parser.add_argument("--repetitions", type=int, default=3, help="comparable runs per scenario (default: 3)")
    parser.add_argument("--output", type=pathlib.Path, help="private output directory (default: build/compile-audit/<UTC>)")
    args = parser.parse_args(argv)
    if args.repetitions < 1:
        parser.error("--repetitions must be positive")
    if not args.run:
        print_plan(args.repetitions); return 0
    output = (args.output or ROOT / "build/compile-audit" / dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")).resolve()
    if output.exists():
        parser.error(f"output already exists: {output}")
    output.mkdir(parents=True)
    source = output / "workspace" / "source"
    source.parent.mkdir()
    commit = snapshot(source)
    rows: list[dict[str, object]] = []
    for repetition in range(1, args.repetitions + 1):
        scratch = output / "workspace" / f"pms-{repetition}"
        for scenario in ("cold", "no_op", "test_coverage"):
            log = output / f"pmskit-{scenario}-{repetition}.log"
            rows.append(measure(command_for_pms(source, scratch, scenario), cwd=source, log=log,
                                group="pmskit", lane="pmskit", scenario=scenario,
                                repetition=repetition, dd=None))
        for lane in LANES:
            dd = output / "workspace" / f"dd-{lane.name}-{repetition}"
            for scenario in ("clean", "no_op"):
                rows.append(measure(command_for_xcode(source, dd, lane), cwd=source,
                                    log=output / f"{lane.name}-{scenario}-{repetition}.log",
                                    group="app", lane=lane.name, scenario=scenario,
                                    repetition=repetition, dd=dd))
            for edit in EDIT_FILES:
                path = source / edit
                original = temporary_edit(path)
                scenario = "incremental_" + path.stem
                try:
                    rows.append(measure(command_for_xcode(source, dd, lane), cwd=source,
                                        log=output / f"{lane.name}-{scenario}-{repetition}.log",
                                        group="app", lane=lane.name, scenario=scenario,
                                        repetition=repetition, dd=dd))
                finally:
                    path.write_bytes(original)
                # Settle the restoration so the next representative edit measures only itself.
                subprocess.run(command_for_xcode(source, dd, lane), cwd=source,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    write_results(output, rows, commit, args.repetitions)
    print(output / "summary.md")
    return 1 if any(int(row["result"]) != 0 for row in rows) else 0


if __name__ == "__main__":
    raise SystemExit(main())
