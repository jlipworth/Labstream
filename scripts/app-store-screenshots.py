#!/usr/bin/env python3
"""Capture and validate credential-free App Store screenshots for Labstream targets.

Raw runner evidence remains under the ignored artifact root. The export contains only flattened
JPEG screenshots and a sanitized manifest: no logs, simulator IDs, absolute paths, credentials,
or real catalog data are copied into the store-ready directory.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
SPEC_PATH = ROOT / "scripts" / "app-store-screenshot-specs.json"
TARGET_ORDER = ("visionos", "iphone", "ipad", "tvos", "macos")
SIMULATOR_TARGETS = frozenset({"visionos", "iphone", "ipad", "tvos"})
SOURCE_NAMES = {
    "visionos": "screen-end.png",
    "iphone": "screen-end.png",
    "ipad": "screen-end.png",
    "tvos": "screen-end.png",
    "macos": "screen-before.png",
}
EXPORT_NAMES = {
    "visionos": "visionos-home-3840x2160.jpg",
    "iphone": "iphone-home-portrait.jpg",
    "ipad": "ipad-home-portrait.jpg",
    "tvos": "tvos-home-3840x2160.jpg",
    "macos": "macos-home-2560x1600.jpg",
}


class ScreenshotError(RuntimeError):
    pass


def load_specs(path: Path = SPEC_PATH) -> dict[str, Any]:
    try:
        specs = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise ScreenshotError(f"cannot read screenshot specifications: {error}") from error
    if specs.get("schemaVersion") != 1 or set(specs.get("targets", {})) != set(TARGET_ORDER):
        raise ScreenshotError("screenshot specification manifest has an unsupported shape")
    for target, entry in specs["targets"].items():
        accepted = entry.get("acceptedPixels")
        capture = entry.get("capturePixels")
        if not accepted or capture not in accepted:
            raise ScreenshotError(f"{target} capture size is not in its accepted size set")
    return specs


def image_properties(path: Path) -> tuple[int, int, bool]:
    result = subprocess.run(
        ["sips", "-g", "pixelWidth", "-g", "pixelHeight", "-g", "hasAlpha", str(path)],
        text=True,
        capture_output=True,
    )
    if result.returncode:
        raise ScreenshotError(f"cannot inspect image {path.name}: {result.stderr.strip()}")
    values: dict[str, str] = {}
    for line in result.stdout.splitlines():
        if ": " in line:
            key, value = line.strip().split(": ", 1)
            values[key] = value
    try:
        return int(values["pixelWidth"]), int(values["pixelHeight"]), values["hasAlpha"] == "yes"
    except (KeyError, ValueError) as error:
        raise ScreenshotError(f"incomplete image metadata for {path.name}") from error


def _run(command: list[str], *, output: Path | None = None) -> None:
    if output is None:
        result = subprocess.run(command, cwd=ROOT, text=True, capture_output=True)
    else:
        with output.open("w") as handle:
            result = subprocess.run(command, cwd=ROOT, stdout=handle, stderr=subprocess.STDOUT)
    if result.returncode:
        detail = (result.stderr or result.stdout or "").strip() if output is None else ""
        suffix = f": {detail}" if detail else ""
        raise ScreenshotError(f"command failed ({result.returncode}): {' '.join(command)}{suffix}")


def _runner_command(target: str, evidence_root: Path) -> list[str]:
    common = ["--artifact-root", str(evidence_root)]
    if target == "visionos":
        return ["scripts/agent-sim-run.sh", "launch-fixture-home-passive", "--allow-simulator",
                "--duration", "3", *common]
    if target in {"iphone", "ipad"}:
        return ["scripts/agent-mobile-run.sh", target, "fixture-home-passive",
                "--allow-simulator", "--duration", "3", *common]
    if target == "tvos":
        return ["scripts/agent-tvos-run.sh", "fixture-home-passive", "--allow-simulator", *common]
    return ["scripts/agent-macos-run.sh", "fixture-home-passive", *common]


def _sole_run_directory(evidence_root: Path) -> Path:
    run_files = list(evidence_root.glob("*/run.json"))
    if len(run_files) != 1:
        raise ScreenshotError(
            f"expected one runner manifest beneath {evidence_root}, found {len(run_files)}"
        )
    payload = json.loads(run_files[0].read_text())
    if payload.get("status") != "passed" or payload.get("exitCode") != 0:
        raise ScreenshotError(f"runner did not pass: {run_files[0]}")
    return run_files[0].parent


def _convert_to_store_jpeg(source: Path, destination: Path, target: str,
                           capture_pixels: tuple[int, int]) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    work = destination.with_suffix(".working.png")
    shutil.copyfile(source, work)
    if target == "macos":
        width, height, _ = image_properties(work)
        wanted_width, wanted_height = capture_pixels
        scale = min(wanted_width / width, wanted_height / height)
        fitted_width = max(1, math.floor(width * scale))
        fitted_height = max(1, math.floor(height * scale))
        _run(["sips", "--resampleHeightWidth", str(fitted_height), str(fitted_width), str(work)])
        _run(["sips", "--padToHeightWidth", str(wanted_height), str(wanted_width),
              "--padColor", "101014", str(work)])
    _run(["sips", "-s", "format", "jpeg", "-s", "formatOptions", "100",
          str(work), "--out", str(destination)])
    work.unlink(missing_ok=True)


def validate_export(export_dir: Path, specs: dict[str, Any] | None = None,
                    required_targets: tuple[str, ...] = TARGET_ORDER) -> dict[str, Any]:
    specs = specs or load_specs()
    manifest_path = export_dir / "manifest.json"
    try:
        manifest = json.loads(manifest_path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise ScreenshotError(f"cannot read export manifest: {error}") from error
    if manifest.get("schemaVersion") != 1:
        raise ScreenshotError("export manifest schemaVersion must be 1")
    entries = manifest.get("screenshots", [])
    by_target = {entry.get("target"): entry for entry in entries}
    if set(by_target) != set(required_targets):
        raise ScreenshotError("export manifest does not contain exactly the requested targets")
    for target in required_targets:
        entry = by_target[target]
        image = export_dir / entry["file"]
        if image.parent != export_dir.resolve() or not image.is_file():
            raise ScreenshotError(f"invalid screenshot path for {target}")
        width, height, has_alpha = image_properties(image)
        accepted = {tuple(pair) for pair in specs["targets"][target]["acceptedPixels"]}
        if (width, height) not in accepted:
            raise ScreenshotError(f"{target} dimensions {width}x{height} are not Apple-accepted")
        if has_alpha:
            raise ScreenshotError(f"{target} image contains a forbidden alpha channel")
        digest = hashlib.sha256(image.read_bytes()).hexdigest()
        if digest != entry.get("sha256"):
            raise ScreenshotError(f"{target} screenshot checksum mismatch")
    return manifest


def capture(targets: tuple[str, ...], artifact_root: Path, *, allow_simulator: bool,
            allow_dirty: bool = False) -> Path:
    specs = load_specs()
    if any(target in SIMULATOR_TARGETS for target in targets) and not allow_simulator:
        raise ScreenshotError("simulator capture requires --allow-simulator after acquiring the lease")
    dirty = bool(subprocess.check_output(
        ["git", "status", "--porcelain", "--untracked-files=normal"], cwd=ROOT, text=True
    ).strip())
    if dirty and not allow_dirty:
        raise ScreenshotError(
            "refusing to capture an uncommitted source tree; commit it or use --allow-dirty for review-only output"
        )
    session = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    root = artifact_root.resolve() / session
    export_dir = root / "store-ready"
    export_dir.mkdir(parents=True)
    entries: list[dict[str, Any]] = []
    for target in targets:
        evidence_root = root / "runner-evidence" / target
        command = _runner_command(target, evidence_root)
        _run(command, output=root / f"{target}-runner.log")
        run_dir = _sole_run_directory(evidence_root)
        source = run_dir / SOURCE_NAMES[target]
        if not source.is_file():
            raise ScreenshotError(f"{target} runner did not produce {source.name}")
        if target != "macos":
            source_size = image_properties(source)[:2]
            accepted = {tuple(pair) for pair in specs["targets"][target]["acceptedPixels"]}
            if source_size not in accepted:
                raise ScreenshotError(
                    f"{target} simulator produced {source_size[0]}x{source_size[1]}, not an accepted size"
                )
        destination = export_dir / EXPORT_NAMES[target]
        capture_pixels = tuple(specs["targets"][target]["capturePixels"])
        _convert_to_store_jpeg(source, destination, target, capture_pixels)  # type: ignore[arg-type]
        width, height, has_alpha = image_properties(destination)
        entries.append({
            "target": target,
            "file": destination.name,
            "pixels": [width, height],
            "hasAlpha": has_alpha,
            "sha256": hashlib.sha256(destination.read_bytes()).hexdigest(),
            "scenario": specs["targets"][target]["runner"],
            "content": "credential-free synthetic Labstream fixture",
        })
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    manifest = {
        "schemaVersion": 1,
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "gitCommit": commit,
        "gitDirty": dirty,
        "specificationsVerifiedAt": specs["verifiedAt"],
        "officialSpecification": specs["officialSource"],
        "privacy": "synthetic-fixture-only; sanitized export excludes logs, IDs, paths, and accounts",
        "screenshots": entries,
    }
    (export_dir / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    validate_export(export_dir, specs, targets)
    return export_dir


def parse_targets(values: list[str]) -> tuple[str, ...]:
    if not values or values == ["all"]:
        return TARGET_ORDER
    unknown = set(values) - set(TARGET_ORDER)
    if unknown:
        raise ScreenshotError(f"unknown target(s): {', '.join(sorted(unknown))}")
    return tuple(target for target in TARGET_ORDER if target in values)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    subparsers = result.add_subparsers(dest="command", required=True)
    capture_parser = subparsers.add_parser("capture")
    capture_parser.add_argument("--target", action="append", default=[])
    capture_parser.add_argument("--artifact-root", type=Path,
                                default=ROOT / "artifacts" / "app-store-screenshots")
    capture_parser.add_argument("--allow-simulator", action="store_true")
    capture_parser.add_argument("--allow-dirty", action="store_true")
    validate_parser = subparsers.add_parser("validate")
    validate_parser.add_argument("export_dir", type=Path)
    return result


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        if args.command == "capture":
            output = capture(parse_targets(args.target), args.artifact_root,
                             allow_simulator=args.allow_simulator, allow_dirty=args.allow_dirty)
            print(f"PASS: {output}")
        else:
            validate_export(args.export_dir.resolve())
            print(f"PASS: {args.export_dir.resolve()}")
        return 0
    except (ScreenshotError, OSError, subprocess.SubprocessError, json.JSONDecodeError) as error:
        print(f"app-store-screenshots: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
