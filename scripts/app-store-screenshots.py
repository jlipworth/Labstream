#!/usr/bin/env python3
"""Capture, validate and check coverage of Labstream App Store screenshots.

Two capture modes share one export format:

* ``capture`` (fixture mode) drives the credential-free platform runners with Debug-only
  ``--ui-testing`` fixture routes. Its images are layout evidence only and are never eligible for
  upload; the manifest says so.
* ``live start`` / ``live shot`` / ``live finish`` (live-catalog mode) launch the installed app with
  no arguments at all, let a person sign in to the review catalog and navigate normally, and then
  capture the exact simulator display after two identical frames. The manifest records the
  zero-argument launch and the unchanged process, never credentials, endpoints or IDs.

Raw runner evidence stays under the ignored artifact root. The export contains only flattened JPEG
screenshots and a sanitized manifest: no logs, simulator IDs, absolute paths, credentials, or
catalog identifiers are copied into the export directory.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import shutil
import subprocess
import sys
import time
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
SPEC_PATH = ROOT / "scripts" / "app-store-screenshot-specs.json"
BUNDLE_ID = "org.labstream.Labstream"
TARGET_ORDER = ("visionos", "iphone", "iphone69", "ipad", "duo-outer", "duo-inner", "tvos", "macos")
SIMULATOR_TARGETS = frozenset(TARGET_ORDER) - {"macos"}
MOBILE_TARGETS = frozenset({"iphone", "iphone69", "ipad", "duo-outer", "duo-inner"})
SCENE_ORDER = ("home", "library", "detail", "playback", "downloads")
MANIFEST_SCHEMA = 2
FIXTURE_CONTENT = "credential-free synthetic Labstream fixture; layout evidence only, not for upload"
LIVE_CONTENT = ("Labstream review catalog (Jellyfin open-films-v2) in an ordinary signed-in "
                "session launched without arguments; requires editorial, licensing and privacy "
                "approval before upload")
FIXTURE_PRIVACY = "synthetic-fixture-only; sanitized export excludes logs, IDs, paths, and accounts"
LIVE_PRIVACY = ("live review catalog; sanitized export excludes logs, simulator IDs, paths, "
                "server addresses, accounts and credentials")

# Debug fixture routes per scene. `None` means no credential-free route exists for that product;
# the scene stays a live/human capture. tvOS is streaming-only, so it has no Downloads scene.
MOBILE_ROUTES: dict[str, dict[str, Any] | None] = {
    "home": {"fixture": "browse", "args": []},
    "library": {"fixture": "browse", "args": ["--ui-testing-open-first-library"]},
    "detail": {"fixture": "browse", "args": ["--ui-testing-open-item", "plex-orbit"]},
    "playback": {"fixture": "player", "args": ["--ui-testing-player-paused"]},
    "downloads": {"fixture": "browse", "args": ["--ui-testing-initial-tab", "offline"]},
}
FIXTURE_ROUTES: dict[str, dict[str, dict[str, Any] | None]] = {
    **{target: MOBILE_ROUTES for target in MOBILE_TARGETS - {"duo-inner"}},
    "duo-inner": {
        **MOBILE_ROUTES,
        # appResize can only start while the app is portrait and frontmost, so the player waits
        # until the proxy session is running before it presents (and applies its orientation).
        "playback": {"fixture": "player",
                     "args": ["--ui-testing-player-paused", "--ui-testing-player-present-delay", "8"]},
    },
    "visionos": {
        **MOBILE_ROUTES,
        # The visionOS player is spatial and has no Debug player fixture; the simulator cannot be
        # driven on Xcode 27, so playback is a human/headset capture.
        "playback": None,
    },
    "tvos": {
        "home": MOBILE_ROUTES["home"],
        "library": MOBILE_ROUTES["library"],
        "detail": MOBILE_ROUTES["detail"],
        "playback": {"fixture": "player", "args": ["--ui-testing-player-paused"]},
    },
    "macos": {
        **MOBILE_ROUTES,
        # The Mac sidebar lists libraries from the live catalog repository, which has no
        # synthetic data, so the library scene is a live capture on Mac.
        "library": None,
        "playback": {"fixture": "player", "args": []},
    },
}
# Seconds to let each scene settle before capture; the player fixture must finish preparing its clip.
SCENE_SETTLE_SECONDS = {"home": 4, "library": 4, "detail": 4, "playback": 16, "downloads": 4}
SOURCE_NAMES = {target: "screen-end.png" for target in SIMULATOR_TARGETS} | {"macos": "screen-before.png"}
# Live capture display names (simctl io --display). The Duo's plain screenshot targets the inner
# LCD, which is black while folded; outer is `primary`, the real unfolded inner is `primary-1`.
LIVE_DISPLAYS = {"duo-outer": "primary", "duo-inner": "primary-1"}


class ScreenshotError(RuntimeError):
    pass


def load_specs(path: Path = SPEC_PATH) -> dict[str, Any]:
    try:
        specs = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise ScreenshotError(f"cannot read screenshot specifications: {error}") from error
    if specs.get("schemaVersion") != 2 or set(specs.get("targets", {})) != set(TARGET_ORDER):
        raise ScreenshotError("screenshot specification manifest has an unsupported shape")
    classes = specs.get("displayClasses", {})
    for target, entry in specs["targets"].items():
        display_class = classes.get(entry.get("displayClass"))
        if display_class is None:
            raise ScreenshotError(f"{target} names an unknown display class")
        if entry.get("capturePixels") not in display_class.get("acceptedPixels", []):
            raise ScreenshotError(f"{target} capture size is not in its accepted size set")
    for rule in specs.get("coverageRules", []):
        names = rule.get("anyOf", []) + rule.get("allOf", [])
        if not names or any(name not in classes for name in names):
            raise ScreenshotError(f"coverage rule {rule.get('id')} names an unknown display class")
    return specs


def accepted_pixels(specs: dict[str, Any], target: str) -> set[tuple[int, int]]:
    display_class = specs["targets"][target]["displayClass"]
    return {tuple(pair) for pair in specs["displayClasses"][display_class]["acceptedPixels"]}


def fixture_scenes(target: str) -> tuple[str, ...]:
    routes = FIXTURE_ROUTES[target]
    return tuple(scene for scene in SCENE_ORDER if routes.get(scene) is not None)


def live_scenes(target: str) -> tuple[str, ...]:
    return tuple(scene for scene in SCENE_ORDER if scene in FIXTURE_ROUTES[target])


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


def _run(command: list[str], *, output: Path | None = None) -> str:
    if output is None:
        result = subprocess.run(command, cwd=ROOT, text=True, capture_output=True)
    else:
        with output.open("w") as handle:
            result = subprocess.run(command, cwd=ROOT, stdout=handle, stderr=subprocess.STDOUT)
    if result.returncode:
        detail = (result.stderr or result.stdout or "").strip() if output is None else ""
        suffix = f": {detail}" if detail else ""
        raise ScreenshotError(f"command failed ({result.returncode}): {' '.join(command)}{suffix}")
    return str(result.stdout) if output is None else ""


def _runner_command(target: str, scene: str, evidence_root: Path, *, first: bool,
                    last: bool) -> list[str]:
    route = FIXTURE_ROUTES[target].get(scene)
    if route is None:
        raise ScreenshotError(f"{target} has no fixture route for the {scene} scene")
    common = ["--artifact-root", str(evidence_root)]
    launch: list[str] = []
    for arg in route["args"]:
        launch += ["--launch-arg", arg]
    keep = [] if last else ["--keep-booted"]
    if target == "visionos":
        if route["fixture"] != "browse":
            raise ScreenshotError("the visionOS runner only supports the browse fixture")
        return ["scripts/agent-sim-run.sh", "launch-fixture-home-passive", "--allow-simulator",
                "--duration", str(SCENE_SETTLE_SECONDS[scene]), *([] if first else ["--skip-build"]), *keep, *launch, *common]
    if target in MOBILE_TARGETS:
        platform = specs_platform(target)
        duo = ["--duo-display", "inner"] if target == "duo-inner" else []
        return ["scripts/agent-mobile-run.sh", platform, "fixture-home-passive",
                "--allow-simulator", "--duration", str(SCENE_SETTLE_SECONDS[scene]),
                "--fixture", route["fixture"],
                *duo, *([] if first else ["--skip-build"]), *keep, *launch, *common]
    if target == "tvos":
        return ["scripts/agent-tvos-run.sh", "fixture-home-passive", "--allow-simulator",
                "--duration", str(SCENE_SETTLE_SECONDS[scene]), "--fixture", route["fixture"], *([] if first else ["--skip-build"]), *keep,
                *launch, *common]
    return ["scripts/agent-macos-run.sh", "fixture-home-passive", "--fixture", route["fixture"],
            "--settle", str(SCENE_SETTLE_SECONDS[scene]),
            *([] if first else ["--skip-build"]), *launch, *common]


def specs_platform(target: str) -> str:
    return {"iphone": "iphone", "iphone69": "iphone69", "ipad": "ipad",
            "duo-outer": "duo", "duo-inner": "duo", "visionos": "visionos",
            "tvos": "tvos"}[target]


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


def _crop_to_capture(work: Path, capture_pixels: tuple[int, int]) -> None:
    """Crop an appResize Resizable-display frame to the app's top-left capture window."""
    width, height, _ = image_properties(work)
    wanted_width, wanted_height = capture_pixels
    if (width, height) == (wanted_width, wanted_height):
        return
    if width < wanted_width or height < wanted_height:
        raise ScreenshotError(f"proxy frame {width}x{height} is smaller than the capture size")
    _run(["sips", "--cropToHeightWidth", str(wanted_height), str(wanted_width),
          "--cropOffset", "0", "0", str(work)])


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


def export_name(target: str, scene: str, pixels: tuple[int, int]) -> str:
    order = SCENE_ORDER.index(scene) + 1
    return f"{target}-{order:02d}-{scene}-{pixels[0]}x{pixels[1]}.jpg"


def _entry(specs: dict[str, Any], target: str, scene: str, destination: Path, *,
           mode: str, launch_arguments: list[str]) -> dict[str, Any]:
    width, height, has_alpha = image_properties(destination)
    entry = {
        "target": target,
        "scene": scene,
        "displayClass": specs["targets"][target]["displayClass"],
        "file": destination.name,
        "pixels": [width, height],
        "hasAlpha": has_alpha,
        "sha256": hashlib.sha256(destination.read_bytes()).hexdigest(),
        "mode": mode,
        "launchArguments": launch_arguments,
        "content": FIXTURE_CONTENT if mode == "fixture" else LIVE_CONTENT,
    }
    proxy = specs["targets"][target].get("fixtureProxy")
    if proxy and mode == "fixture":
        entry["proxy"] = proxy
    return entry


def _write_manifest(export_dir: Path, specs: dict[str, Any], entries: list[dict[str, Any]], *,
                    mode: str, dirty: bool, extra: dict[str, Any] | None = None) -> None:
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    manifest = {
        "schemaVersion": MANIFEST_SCHEMA,
        "mode": mode,
        "releaseEligible": False,
        "releaseEligibility": (
            "never: fixture images are layout evidence only" if mode == "fixture" else
            "pending: a person must approve composition, licensed artwork, credits and privacy"
        ),
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "gitCommit": commit,
        "gitDirty": dirty,
        "specificationsVerifiedAt": specs["verifiedAt"],
        "officialSpecification": specs["officialSource"],
        "privacy": FIXTURE_PRIVACY if mode == "fixture" else LIVE_PRIVACY,
        "screenshots": entries,
        **(extra or {}),
    }
    (export_dir / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")


def _read_manifest(export_dir: Path) -> dict[str, Any]:
    try:
        manifest = json.loads((export_dir / "manifest.json").read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise ScreenshotError(f"cannot read export manifest: {error}") from error
    if manifest.get("schemaVersion") != MANIFEST_SCHEMA:
        raise ScreenshotError(f"export manifest schemaVersion must be {MANIFEST_SCHEMA}")
    return manifest


def validate_export(export_dir: Path, specs: dict[str, Any] | None = None,
                    required_targets: tuple[str, ...] | None = None) -> dict[str, Any]:
    specs = specs or load_specs()
    export_dir = export_dir.resolve()
    manifest = _read_manifest(export_dir)
    mode = manifest.get("mode")
    if mode not in {"fixture", "live"}:
        raise ScreenshotError("export manifest mode must be fixture or live")
    if manifest.get("releaseEligible") is not False:
        raise ScreenshotError("export manifests are never self-certified as release eligible")
    entries = manifest.get("screenshots", [])
    targets = {entry.get("target") for entry in entries}
    if required_targets is not None and targets != set(required_targets):
        raise ScreenshotError("export manifest does not contain exactly the requested targets")
    seen: set[tuple[str, str]] = set()
    per_class: dict[str, int] = {}
    for entry in entries:
        target, scene = entry.get("target"), entry.get("scene")
        if target not in TARGET_ORDER or scene not in SCENE_ORDER:
            raise ScreenshotError(f"unknown target/scene {target}/{scene}")
        if (target, scene) in seen:
            raise ScreenshotError(f"duplicate {target} {scene} screenshot")
        seen.add((target, scene))
        if entry.get("displayClass") != specs["targets"][target]["displayClass"]:
            raise ScreenshotError(f"{target} display class does not match the specification")
        if entry.get("mode") != mode:
            raise ScreenshotError(f"{target} {scene} mode does not match the manifest")
        arguments = entry.get("launchArguments")
        if mode == "live" and arguments != []:
            raise ScreenshotError(f"live {target} {scene} screenshot records launch arguments")
        if mode == "fixture" and "--ui-testing" not in (arguments or []):
            raise ScreenshotError(f"fixture {target} {scene} screenshot lacks its fixture flags")
        expected_content = FIXTURE_CONTENT if mode == "fixture" else LIVE_CONTENT
        if entry.get("content") != expected_content:
            raise ScreenshotError(f"{target} {scene} content wording does not match {mode} mode")
        image = export_dir / entry["file"]
        if image.parent != export_dir or not image.is_file():
            raise ScreenshotError(f"invalid screenshot path for {target} {scene}")
        width, height, has_alpha = image_properties(image)
        if (width, height) not in accepted_pixels(specs, target):
            raise ScreenshotError(f"{target} dimensions {width}x{height} are not Apple-accepted")
        if has_alpha:
            raise ScreenshotError(f"{target} image contains a forbidden alpha channel")
        digest = hashlib.sha256(image.read_bytes()).hexdigest()
        if digest != entry.get("sha256"):
            raise ScreenshotError(f"{target} {scene} screenshot checksum mismatch")
        display_class = entry["displayClass"]
        per_class[display_class] = per_class.get(display_class, 0) + 1
    maximum = specs["requirements"]["maximumCount"]
    for display_class, count in per_class.items():
        if count > maximum:
            raise ScreenshotError(f"{display_class} has {count} screenshots; Apple allows {maximum}")
    return manifest


def coverage_report(manifests: list[dict[str, Any]], specs: dict[str, Any] | None = None, *,
                    as_of: date | None = None, families: set[str] | None = None,
                    include_upcoming: bool = False) -> dict[str, Any]:
    """Return which Apple-required display classes the given exports cover.

    `families` limits the check to rules whose classes belong to the requested targets (all
    shipped products by default). Rules with a future `effectiveFrom` are reported as upcoming
    and only fail when `include_upcoming` is set.
    """
    specs = specs or load_specs()
    as_of = as_of or date.today()
    covered = {entry["displayClass"] for manifest in manifests for entry in manifest["screenshots"]}
    wanted_classes = None
    if families is not None:
        wanted_classes = {specs["targets"][target]["displayClass"] for target in families}
    rules = []
    missing = []
    for rule in specs["coverageRules"]:
        names = rule.get("anyOf", []) + rule.get("allOf", [])
        if wanted_classes is not None and not set(names) & wanted_classes:
            continue
        effective = rule.get("effectiveFrom")
        upcoming = bool(effective) and date.fromisoformat(effective) > as_of
        if "allOf" in rule:
            satisfied = all(name in covered for name in rule["allOf"])
        else:
            satisfied = any(name in covered for name in rule["anyOf"])
        status = "covered" if satisfied else ("upcoming" if upcoming else "missing")
        if not satisfied and (not upcoming or include_upcoming):
            missing.append(rule["id"])
        rules.append({"id": rule["id"], "status": status, "effectiveFrom": effective})
    return {"asOf": as_of.isoformat(), "coveredClasses": sorted(covered), "rules": rules,
            "missing": missing}


def _git_dirty() -> bool:
    return bool(subprocess.check_output(
        ["git", "status", "--porcelain", "--untracked-files=normal"], cwd=ROOT, text=True
    ).strip())


def _shutdown_target_simulator(target: str) -> None:
    if target not in SIMULATOR_TARGETS:
        return
    result = subprocess.run(["scripts/worktree-sim.sh", "--platform", specs_platform(target), "id"],
                            cwd=ROOT, text=True, capture_output=True)
    udid = result.stdout.strip()
    if result.returncode == 0 and udid:
        subprocess.run(["xcrun", "simctl", "shutdown", udid], cwd=ROOT, capture_output=True)


def capture(targets: tuple[str, ...], artifact_root: Path, *, allow_simulator: bool,
            allow_dirty: bool = False, scenes: tuple[str, ...] | None = None) -> Path:
    specs = load_specs()
    if any(target in SIMULATOR_TARGETS for target in targets) and not allow_simulator:
        raise ScreenshotError("simulator capture requires --allow-simulator after acquiring the lease")
    dirty = _git_dirty()
    if dirty and not allow_dirty:
        raise ScreenshotError(
            "refusing to capture an uncommitted source tree; commit it or use --allow-dirty for review-only output"
        )
    session = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    root = artifact_root.resolve() / f"{session}-fixture"
    export_dir = root / "export"
    export_dir.mkdir(parents=True)
    entries: list[dict[str, Any]] = []
    skipped: list[dict[str, str]] = []
    for target in targets:
        requested = scenes or SCENE_ORDER
        wanted = [scene for scene in fixture_scenes(target) if scene in requested]
        skipped += [{"target": target, "scene": scene,
                     "reason": "no credential-free fixture route; live/human capture"}
                    for scene in requested
                    if scene in FIXTURE_ROUTES[target] and FIXTURE_ROUTES[target][scene] is None]
        try:
            for index, scene in enumerate(wanted):
                evidence_root = root / "runner-evidence" / target / scene
                command = _runner_command(target, scene, evidence_root, first=index == 0,
                                          last=index == len(wanted) - 1)
                _run(command, output=root / f"{target}-{scene}-runner.log")
                run_dir = _sole_run_directory(evidence_root)
                source = run_dir / SOURCE_NAMES[target]
                if not source.is_file():
                    raise ScreenshotError(f"{target} {scene} runner did not produce {source.name}")
                capture_pixels = tuple(specs["targets"][target]["capturePixels"])
                if target == "duo-inner":
                    cropped = root / f"{target}-{scene}-proxy.png"
                    shutil.copyfile(source, cropped)
                    _crop_to_capture(cropped, capture_pixels)  # type: ignore[arg-type]
                    source = cropped
                if target != "macos":
                    width, height, _ = image_properties(source)
                    if (width, height) not in accepted_pixels(specs, target):
                        raise ScreenshotError(
                            f"{target} {scene} produced {width}x{height}, not an accepted size"
                        )
                    pixels = (width, height)
                else:
                    pixels = capture_pixels  # type: ignore[assignment]
                destination = export_dir / export_name(target, scene, pixels)
                _convert_to_store_jpeg(source, destination, target, capture_pixels)  # type: ignore[arg-type]
                route = FIXTURE_ROUTES[target][scene]
                assert route is not None
                launch = ["--ui-testing", "--ui-testing-backend", "plex", "--ui-testing-fixture",
                          route["fixture"], *route["args"]]
                entries.append(_entry(specs, target, scene, destination, mode="fixture",
                                      launch_arguments=launch))
        finally:
            _shutdown_target_simulator(target)
    _write_manifest(export_dir, specs, entries, mode="fixture", dirty=dirty,
                    extra={"skippedScenes": skipped})
    validate_export(export_dir, specs)
    return export_dir


# --- live-catalog mode ---------------------------------------------------------------------


def _simulator_udid(target: str) -> str:
    return _run(["scripts/worktree-sim.sh", "--platform", specs_platform(target), "id"]).strip()


def _booted_udids() -> set[str]:
    payload = json.loads(_run(["xcrun", "simctl", "list", "devices", "--json"]))
    return {device["udid"] for devices in payload["devices"].values() for device in devices
            if device.get("state") == "Booted"}


def _app_pid(udid: str) -> int | None:
    """PID of the running Labstream app on this simulator, from the simulator's launchd."""
    listing = _run(["xcrun", "simctl", "spawn", udid, "launchctl", "list"])
    for line in listing.splitlines():
        fields = line.split()
        if len(fields) >= 3 and f"UIKitApplication:{BUNDLE_ID}[" in fields[2] and fields[0].isdigit():
            return int(fields[0])
    return None


def _installed_version(udid: str) -> dict[str, str]:
    container = _run(["xcrun", "simctl", "get_app_container", udid, BUNDLE_ID, "app"]).strip()
    info = Path(container) / "Info.plist"
    version: dict[str, str] = {}
    for key, name in (("CFBundleShortVersionString", "marketingVersion"),
                      ("CFBundleVersion", "buildNumber")):
        result = subprocess.run(["/usr/libexec/PlistBuddy", "-c", f"Print :{key}", str(info)],
                                text=True, capture_output=True)
        if result.returncode == 0:
            version[name] = result.stdout.strip()
    return version


def _session_state(session: Path) -> dict[str, Any]:
    try:
        return json.loads((session / "live-session.json").read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise ScreenshotError(f"not a live capture session: {error}") from error


def live_start(target: str, artifact_root: Path, *, allow_simulator: bool) -> Path:
    if target not in SIMULATOR_TARGETS:
        raise ScreenshotError("live mode supports simulator targets; capture macOS by hand")
    if not allow_simulator:
        raise ScreenshotError("live capture requires --allow-simulator after acquiring the lease")
    udid = _simulator_udid(target)
    foreign = _booted_udids() - {udid}
    if foreign:
        raise ScreenshotError("another simulator is booted; wait for the one-simulator lease")
    subprocess.run(["xcrun", "simctl", "boot", udid], cwd=ROOT, capture_output=True)
    _run(["xcrun", "simctl", "bootstatus", udid, "-b"])
    if target in MOBILE_TARGETS:
        subprocess.run(["xcrun", "simctl", "status_bar", udid, "override", "--time", "09:41",
                        "--dataNetwork", "wifi", "--wifiMode", "active", "--wifiBars", "3",
                        "--cellularMode", "active", "--cellularBars", "4", "--operatorName", "",
                        "--batteryState", "charged", "--batteryLevel", "100"],
                       cwd=ROOT, capture_output=True)
    subprocess.run(["xcrun", "simctl", "terminate", udid, BUNDLE_ID], cwd=ROOT, capture_output=True)
    # Deliberately no launch arguments: no --ui-testing, fixture, backend or route flags.
    _run(["xcrun", "simctl", "launch", udid, BUNDLE_ID])
    time.sleep(2)
    pid = _app_pid(udid)
    if pid is None:
        raise ScreenshotError("Labstream did not register a running process after launch")
    session_name = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    session = artifact_root.resolve() / f"{session_name}-live-{target}"
    (session / "export").mkdir(parents=True)
    state = {"schemaVersion": 1, "target": target, "pid": pid, "launchArguments": [],
             "app": _installed_version(udid), "startedAt": datetime.now(timezone.utc).isoformat()}
    (session / "live-session.json").write_text(json.dumps(state, indent=2) + "\n")
    return session


def _stable_frame(udid: str, display: str | None, work: Path, *, attempts: int = 5,
                  interval: float = 2.0) -> Path:
    display_args = [f"--display={display}"] if display else []
    previous: str | None = None
    for attempt in range(attempts):
        frame = work / f"frame-{attempt}.png"
        _run(["xcrun", "simctl", "io", udid, "screenshot", *display_args, str(frame)])
        digest = hashlib.sha256(frame.read_bytes()).hexdigest()
        if digest == previous:
            return frame
        previous = digest
        time.sleep(interval)
    raise ScreenshotError("the display never settled into two identical frames; wait and retry")


def live_shot(session: Path, scene: str) -> Path:
    specs = load_specs()
    state = _session_state(session)
    target = state["target"]
    if scene not in live_scenes(target):
        raise ScreenshotError(f"{target} has no {scene} scene")
    udid = _simulator_udid(target)
    if udid not in _booted_udids():
        raise ScreenshotError("the session's simulator is no longer booted")
    if _app_pid(udid) != state["pid"]:
        raise ScreenshotError(
            "Labstream is not the process this session launched without arguments; start a new session"
        )
    work = session / "frames" / scene
    if work.exists():
        shutil.rmtree(work)
    work.mkdir(parents=True)
    frame = _stable_frame(udid, LIVE_DISPLAYS.get(target), work)
    width, height, _ = image_properties(frame)
    if (width, height) not in accepted_pixels(specs, target):
        raise ScreenshotError(f"{target} display produced {width}x{height}, not an accepted size")
    export_dir = session / "export"
    for stale in export_dir.glob(f"{target}-*-{scene}-*.jpg"):
        stale.unlink()
    destination = export_dir / export_name(target, scene, (width, height))
    _convert_to_store_jpeg(frame, destination, target, (width, height))
    entries = [entry for entry in _live_entries(session) if entry["scene"] != scene]
    entries.append(_entry(specs, target, scene, destination, mode="live", launch_arguments=[]))
    entries.sort(key=lambda entry: SCENE_ORDER.index(entry["scene"]))
    _write_manifest(export_dir, specs, entries, mode="live", dirty=_git_dirty(),
                    extra={"app": state["app"], "launchedWithoutArguments": True})
    validate_export(export_dir, specs)
    return destination


def _live_entries(session: Path) -> list[dict[str, Any]]:
    path = session / "export" / "manifest.json"
    if not path.exists():
        return []
    return _read_manifest(session / "export").get("screenshots", [])


def live_finish(session: Path) -> Path:
    state = _session_state(session)
    target = state["target"]
    udid = _simulator_udid(target)
    if target in MOBILE_TARGETS:
        subprocess.run(["xcrun", "simctl", "status_bar", udid, "clear"], cwd=ROOT, capture_output=True)
    subprocess.run(["xcrun", "simctl", "shutdown", udid], cwd=ROOT, capture_output=True)
    shutil.rmtree(session / "frames", ignore_errors=True)
    export_dir = session / "export"
    if (export_dir / "manifest.json").exists():
        validate_export(export_dir)
    return export_dir


# --- command line --------------------------------------------------------------------------


def parse_targets(values: list[str]) -> tuple[str, ...]:
    if not values or values == ["all"]:
        return TARGET_ORDER
    unknown = set(values) - set(TARGET_ORDER)
    if unknown:
        raise ScreenshotError(f"unknown target(s): {', '.join(sorted(unknown))}")
    return tuple(target for target in TARGET_ORDER if target in values)


def parse_scenes(values: list[str]) -> tuple[str, ...] | None:
    if not values or values == ["all"]:
        return None
    unknown = set(values) - set(SCENE_ORDER)
    if unknown:
        raise ScreenshotError(f"unknown scene(s): {', '.join(sorted(unknown))}")
    return tuple(scene for scene in SCENE_ORDER if scene in values)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    subparsers = result.add_subparsers(dest="command", required=True)
    default_root = ROOT / "artifacts" / "app-store-screenshots"

    capture_parser = subparsers.add_parser("capture", help="fixture-mode layout captures")
    capture_parser.add_argument("--target", action="append", default=[])
    capture_parser.add_argument("--scene", action="append", default=[])
    capture_parser.add_argument("--artifact-root", type=Path, default=default_root)
    capture_parser.add_argument("--allow-simulator", action="store_true")
    capture_parser.add_argument("--allow-dirty", action="store_true")

    live_parser = subparsers.add_parser("live", help="live-catalog captures of an ordinary session")
    live_sub = live_parser.add_subparsers(dest="live_command", required=True)
    start = live_sub.add_parser("start")
    start.add_argument("--target", required=True, choices=sorted(SIMULATOR_TARGETS))
    start.add_argument("--artifact-root", type=Path, default=default_root)
    start.add_argument("--allow-simulator", action="store_true")
    shot = live_sub.add_parser("shot")
    shot.add_argument("session", type=Path)
    shot.add_argument("--scene", required=True, choices=SCENE_ORDER)
    finish = live_sub.add_parser("finish")
    finish.add_argument("session", type=Path)

    validate_parser = subparsers.add_parser("validate")
    validate_parser.add_argument("export_dir", type=Path)

    coverage_parser = subparsers.add_parser("coverage", help="check required display classes")
    coverage_parser.add_argument("export_dirs", type=Path, nargs="+")
    coverage_parser.add_argument("--as-of", type=date.fromisoformat, default=None)
    coverage_parser.add_argument("--target", action="append", default=[],
                                 help="limit to these products' display classes")
    coverage_parser.add_argument("--include-upcoming", action="store_true",
                                 help="also fail on requirements that are not yet in effect")
    coverage_parser.add_argument("--live-only", action="store_true",
                                 help="reject fixture exports (use for release candidates)")
    return result


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        if args.command == "capture":
            output = capture(parse_targets(args.target), args.artifact_root,
                             allow_simulator=args.allow_simulator, allow_dirty=args.allow_dirty,
                             scenes=parse_scenes(args.scene))
            print(f"PASS: {output}")
        elif args.command == "live":
            if args.live_command == "start":
                session = live_start(args.target, args.artifact_root,
                                     allow_simulator=args.allow_simulator)
                print(f"SESSION: {session}")
                print("Sign in and navigate normally, then run `live shot SESSION --scene NAME`.")
            elif args.live_command == "shot":
                print(f"PASS: {live_shot(args.session.resolve(), args.scene)}")
            else:
                print(f"PASS: {live_finish(args.session.resolve())}")
        elif args.command == "validate":
            validate_export(args.export_dir.resolve())
            print(f"PASS: {args.export_dir.resolve()}")
        else:
            specs = load_specs()
            manifests = [validate_export(path.resolve(), specs) for path in args.export_dirs]
            if args.live_only and any(manifest["mode"] != "live" for manifest in manifests):
                raise ScreenshotError("--live-only rejects fixture exports")
            families = set(parse_targets(args.target)) if args.target else None
            report = coverage_report(manifests, specs, as_of=args.as_of, families=families,
                                     include_upcoming=args.include_upcoming)
            print(json.dumps(report, indent=2))
            if report["missing"]:
                raise ScreenshotError(f"missing required display classes: {', '.join(report['missing'])}")
            print("PASS: required display classes covered")
        return 0
    except (ScreenshotError, OSError, subprocess.SubprocessError, json.JSONDecodeError) as error:
        print(f"app-store-screenshots: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
