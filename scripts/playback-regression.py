#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy", "imageio-ffmpeg"]
# ///
"""Bounded, simulator-free playback regression package; decoded evidence, not speakers."""
from __future__ import annotations

import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import platform
import re
import signal
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
CASES = {"clean": [], "audio-gap": ["audio-gap"], "audio-gain": ["audio-gain"],
         "audio-delay": ["audio-sync"], "video-freeze": ["video-content"],
         "video-bright": ["video-content"]}
STATUSES = {"pass", "failure", "unsupported-capture", "inconclusive"}
SCOPES = {"transport-only", "decoded-audio-coverage", "decoded-audio-reference",
          "capture-cleanup", "seek-freshness"}
SOURCE_PATHS = ["scripts/playback-regression.py", "scripts/playback-signal-lab.py",
                "scripts/playback-signal-matrix.py", "scripts/playback-multichannel-lab.py",
                "scripts/playback-coverage.py",
                "scripts/playback-signal-host.swift",
                "Labstream/Shared/Debug/DebugPlaybackSignalCapture.swift",
                "Labstream/Shared/Debug/DebugPlaybackAudioTap.swift"]


class InvalidEvidence(ValueError):
    pass


def digest(path):
    hasher = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""): hasher.update(block)
    return hasher.hexdigest()


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result: raise InvalidEvidence("duplicate JSON key")
        result[key] = value
    return result


def read_json(path):
    if Path(path).stat().st_size > 16 * 1024 * 1024: raise InvalidEvidence("oversized report")
    try:
        return json.loads(Path(path).read_text(), object_pairs_hook=unique_object,
                          parse_constant=lambda _: (_ for _ in ()).throw(InvalidEvidence("nonfinite JSON")))
    except (UnicodeError, json.JSONDecodeError) as error:
        raise InvalidEvidence("malformed JSON") from error


def write_json(path, data):
    Path(path).write_text(json.dumps(data, indent=2, sort_keys=True, allow_nan=False) + "\n")


def load_module(name):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), ROOT / "scripts" / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def relative_file(root, name):
    if not isinstance(name, str): raise InvalidEvidence("invalid artifact path")
    path = (root / name).resolve()
    if not path.is_relative_to(root.resolve()) or not path.is_file():
        raise InvalidEvidence("missing or escaped artifact")
    return path


def record(case, status, scope, reason, **extra):
    return dict(case=case, status=status, scope=scope, reason=reason, **extra)


def exact_cells(rows, key, expected):
    if not isinstance(rows, list) or not all(isinstance(row, dict) for row in rows):
        raise InvalidEvidence("missing result rows")
    actual = [row.get(key) for row in rows]
    if len(actual) != len(set(actual)) or set(actual) != set(expected):
        raise InvalidEvidence("missing, duplicate, or unexpected result cells")


def capture_path(root, run_id):
    if not isinstance(run_id, str) or not re.fullmatch(r"(?:offline-|host-|matrix-)?[0-9a-fA-F-]{36}", run_id):
        raise InvalidEvidence("invalid capture run ID")
    uuid.UUID(run_id.removeprefix("offline-").removeprefix("host-").removeprefix("matrix-"))
    directory = root / "runs" / run_id
    relative_file(root, str((directory / "capture.json").relative_to(root)))
    return directory


def detector_results(root, filename, suite):
    rows = read_json(root / filename)
    exact_cells(rows, "case", CASES)
    if len({row.get("runID") for row in rows}) != len(rows): raise InvalidEvidence("reused capture run ID")
    by_case = {row["case"]: row for row in rows}
    lab = load_module("playback-signal-lab")
    baseline, results = None, []
    for case, expected in CASES.items():
        row = by_case[case]
        directory = capture_path(root, row.get("runID"))
        measured = lab.analyze(directory, root / "reference.rgba", row["runID"], baseline)
        failures = sorted(measured["failures"])
        if failures != sorted(row.get("failures", [])): raise InvalidEvidence("report differs from raw capture")
        if case == "clean":
            if failures: return [record(suite + "/clean", "failure", "decoded-reference", "clean calibration failed", findings=failures)]
            baseline = measured["audioEnvelopeOffsetSeconds"]
        matched = failures == expected
        results.append(record(suite + "/" + case, "pass" if matched else "failure",
                              "offline-detector" if suite == "offline" else "decoded-reference",
                              "expected classification" if matched else "unexpected classification",
                              expectation="clean-playback" if case == "clean" else "detect-injected-defect",
                              expectedFindings=expected, findings=failures, captureRunID=row["runID"],
                              cleanPlayback=case == "clean" and matched))
    return results


def matrix_results(root):
    matrix = load_module("playback-signal-matrix")
    payload = read_json(root / "matrix-results.json")
    if not isinstance(payload, dict) or payload.get("schema") != 1 or payload.get("status") != "complete":
        raise InvalidEvidence("unfinished matrix")
    uuid.UUID(payload["runID"])
    rows = payload.get("results")
    exact_cells(rows, "name", [profile[0] for profile in matrix.PROFILES])
    manifest = read_json(root / "matrix-manifest.json")
    exact_cells(manifest.get("profiles"), "name", [profile[0] for profile in matrix.PROFILES])
    if payload.get("manifestSHA256") != digest(root / "matrix-manifest.json"):
        raise InvalidEvidence("matrix manifest changed")
    preflight = detector_results(root, "host-results.json", "matrix-preflight")
    if len(preflight) != len(CASES) or any(row["status"] != "pass" for row in preflight):
        raise InvalidEvidence("matrix detector preflight failed")
    baseline = next(row for row in read_json(root / "host-results.json") if row["case"] == "clean")["audioEnvelopeOffsetSeconds"]
    results = []
    for row in rows:
        old = row.get("status")
        status = {"signal-pass": "pass", "signal-mismatch": "failure",
                  "generation-failed": "inconclusive", "fixture-invalid": "inconclusive",
                  "capture-timeout": "inconclusive", "playback-not-ready": "inconclusive",
                  "capture-inconclusive": "inconclusive"}.get(old)
        if status is None: raise InvalidEvidence("unknown matrix status")
        if old in ("signal-pass", "signal-mismatch"):
            fixture = next(p for p in manifest["profiles"] if p["name"] == row["name"])
            matrix.verify_files(root, fixture["files"])
            measured = matrix.lab.analyze(capture_path(root, row.get("runID")), root / "reference.rgba", row["runID"], baseline)
            if measured["failures"] != row.get("failures") or (not measured["failures"]) != (old == "signal-pass"):
                raise InvalidEvidence("matrix finding differs from capture")
        results.append(record("matrix/" + row["name"], status, "decoded-reference", old,
                              findings=row.get("failures", []), captureRunID=row.get("runID"),
                              interpretation="exploratory finding, not universal codec support"))
    return results


def multichannel_results(root):
    import numpy as np
    module = load_module("playback-multichannel-lab")
    rows = read_json(root / "results.json")
    manifest = read_json(root / "manifest.json")
    if not isinstance(manifest, dict) or manifest.get("schema") != 1: raise InvalidEvidence("invalid multichannel manifest")
    exact_cells(manifest.get("profiles"), "name", [profile[0] for profile in module.PROFILES])
    if not isinstance(rows, list): raise InvalidEvidence("missing multichannel results")
    expected = {(profile[0], channels) for profile in module.PROFILES for channels in (2, 6)}
    seen, results = set(), []
    statuses = {"routing-pass": "pass", "routing-mismatch": "failure", "layout-unverified": "inconclusive",
                "capture-failed": "inconclusive", "inconclusive": "inconclusive",
                "fixture-invalid": "inconclusive", "generation-failed": "inconclusive"}
    for row in rows:
        if not isinstance(row, dict) or row.get("status") not in statuses: raise InvalidEvidence("unknown multichannel status")
        name = row.get("profile", row.get("name"))
        old = row["status"]
        cells = {(name, channels) for channels in (2, 6)} if old in ("fixture-invalid", "generation-failed") else {(name, row.get("requestedChannels"))}
        if not cells <= expected or cells & seen: raise InvalidEvidence("duplicate or unexpected multichannel cells")
        seen |= cells
        if old in ("routing-pass", "routing-mismatch", "layout-unverified"):
            directory = capture_path(root, row.get("runID"))
            capture = read_json(directory / "capture.json")
            channels = row.get("requestedChannels")
            if (capture.get("schema") != 1 or capture.get("runID") != row["runID"] or
                capture.get("channels") != channels or capture.get("sampleRate") != 48000):
                raise InvalidEvidence("mismatched multichannel capture")
            fixture = next(p for p in manifest["profiles"] if p["name"] == name)
            if fixture.get("status") != "generated" or not fixture.get("files"):
                raise InvalidEvidence("unverified multichannel fixture")
            for path, expected_hash in fixture["files"].items():
                if digest(relative_file(root, path)) != expected_hash: raise InvalidEvidence("multichannel fixture changed")
            samples_metadata = capture.get("audio")
            if not isinstance(samples_metadata, list) or not samples_metadata: raise InvalidEvidence("missing multichannel samples")
            offset, previous_end = 0, None
            for sample in samples_metadata:
                frames, pts = sample["frames"], sample["pts"]
                if (type(frames) not in (int, float) or not math.isfinite(frames) or frames <= 0 or int(frames) != frames or
                    type(pts) not in (int, float) or not math.isfinite(pts) or sample["offset"] != offset or
                    (previous_end is not None and abs(pts - previous_end) > .005)):
                    raise InvalidEvidence("invalid multichannel sample metadata")
                offset += int(frames) * channels * 4
                previous_end = pts + frames / 48000
            if samples_metadata[0]["pts"] > .25 or previous_end < 9.5:
                raise InvalidEvidence("incomplete multichannel observation")
            if (directory / "audio.f32le").stat().st_size != offset: raise InvalidEvidence("truncated multichannel PCM")
            measured = module.measure(np.fromfile(directory / "audio.f32le", dtype="<f4").reshape(-1, channels))
            if measured["failures"] != row.get("failures"):
                raise InvalidEvidence("routing report differs from raw PCM")
            if old == "routing-pass" and row.get("failures") != []: raise InvalidEvidence("contradictory routing pass")
            if old == "routing-mismatch" and not row.get("failures"): raise InvalidEvidence("contradictory routing mismatch")
            if old == "routing-pass" and row.get("requestedChannels") == 6 and not capture.get("observedChannelLayoutTags"):
                raise InvalidEvidence("unproven channel mapping")
        for _, channels in sorted(cells):
            results.append(record(f"multichannel/{name}/{channels}", statuses[old],
                                  "stereo-downmix" if channels == 2 else "decoded-channel-routing", old,
                                  findings=row.get("failures", []), captureRunID=row.get("runID")))
    if seen != expected: raise InvalidEvidence("missing multichannel cells")
    return results


def external_results(path, expected_id, now=None):
    envelope = read_json(path)
    required = {"schemaVersion", "kind", "runID", "capturedAtUTC", "sourceSHA256", "app", "artifact", "results"}
    if not isinstance(envelope, dict) or set(envelope) != required or envelope.get("schemaVersion") != 1 or envelope.get("kind") != "native-evidence":
        raise InvalidEvidence("unsupported external evidence envelope")
    if str(uuid.UUID(envelope["runID"])) != str(uuid.UUID(expected_id)): raise InvalidEvidence("stale external run")
    captured = datetime.fromisoformat(envelope["capturedAtUTC"].replace("Z", "+00:00"))
    if captured.tzinfo is None: raise InvalidEvidence("external timestamp lacks timezone")
    age = ((now or datetime.now(timezone.utc)) - captured).total_seconds()
    if not -60 <= age <= 86400: raise InvalidEvidence("expired external evidence")
    sources = envelope["sourceSHA256"]
    required_source = "Labstream/Shared/Debug/DebugPlaybackSignalCapture.swift"
    if not isinstance(sources, dict) or required_source not in sources: raise InvalidEvidence("missing external source provenance")
    for name, expected in sources.items():
        if digest(relative_file(ROOT, name)) != expected: raise InvalidEvidence("stale external source")
    app = envelope["app"]
    if (not isinstance(app, dict) or set(app) != {"executableSHA256", "pid", "exactExecutableVerified"} or
        not isinstance(app["executableSHA256"], str) or not re.fullmatch(r"[0-9a-f]{64}", app["executableSHA256"]) or
        type(app["pid"]) is not int or app["pid"] <= 0 or app["exactExecutableVerified"] is not True):
        raise InvalidEvidence("missing process identity attestation")
    artifact = envelope["artifact"]
    if not isinstance(artifact, dict) or set(artifact) != {"path", "sha256"}: raise InvalidEvidence("invalid external artifact")
    source = relative_file(Path(path).parent, artifact["path"])
    if digest(source) != artifact["sha256"]: raise InvalidEvidence("external artifact changed")
    payload = read_json(source)
    if not isinstance(payload, dict) or payload.get("schemaVersion") != 1 or payload.get("runID") != envelope["runID"]:
        raise InvalidEvidence("external artifact run binding missing")
    rows = envelope["results"]
    if not isinstance(rows, list) or not rows: raise InvalidEvidence("empty external evidence")
    if payload.get("results") != rows: raise InvalidEvidence("external results differ from bound artifact")
    seen, results = set(), []
    for row in rows:
        if (not isinstance(row, dict) or set(row) != {"case", "status", "scope", "reason"} or
            not isinstance(row["case"], str) or not re.fullmatch(r"[a-zA-Z0-9/_-]{1,100}", row["case"]) or
            row["case"] in seen or row["status"] not in STATUSES or row["scope"] not in SCOPES or
            not isinstance(row["reason"], str) or len(row["reason"]) > 240 or "\n" in row["reason"]):
            raise InvalidEvidence("invalid external result")
        seen.add(row["case"])
        results.append(dict(row, case="external/" + row["case"], captureRunID=envelope["runID"],
                            interpretation="trusted local collector attestation, not independent process verification; scope is not expanded"))
    return results


def execute(command, log_path, timeout):
    environment = {key: value for key, value in os.environ.items() if not key.startswith("SIGNAL_LAB_")}
    started = time.monotonic()
    with log_path.open("wb") as output:
        process = subprocess.Popen([str(value) for value in command], cwd=ROOT, env=environment,
                                   stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
        def stop_owned_group():
            try: os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError: pass
            try: process.wait(timeout=3)
            except subprocess.TimeoutExpired: pass
            finally:
                # The leader may already have exited while a grandchild ignored TERM.
                try: os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError: pass
            process.wait(timeout=5)
        try:
            code = process.wait(timeout=timeout)
            status = "completed"
        except subprocess.TimeoutExpired:
            stop_owned_group()
            code, status = None, "timeout"
        except BaseException:
            stop_owned_group()
            raise
    return dict(exitCode=code, execution=status, elapsedSeconds=round(time.monotonic() - started, 3),
                timeoutSeconds=timeout, log=log_path.name)


def planned_commands(directory, suites):
    commands = [("core-generate", "playback-signal-lab.py", "generate", "core", 180),
                ("core-offline", "playback-signal-lab.py", "self-test", "core", 180),
                ("core-host", "playback-signal-lab.py", "run-host", "core", 480)]
    if "matrix" in suites:
        commands += [("matrix-generate", "playback-signal-matrix.py", "generate", "matrix", 600),
                     ("matrix-host", "playback-signal-matrix.py", "run", "matrix", 1200)]
    if "multichannel" in suites:
        commands += [("multichannel-generate", "playback-multichannel-lab.py", "generate", "multichannel", 300),
                     ("multichannel-host", "playback-multichannel-lab.py", "run", "multichannel", 900)]
    return [(name, ["uv", "run", str(ROOT / "scripts" / script), action, "--output", str(directory / subdir)], timeout)
            for name, script, action, subdir, timeout in commands]


def summarize(data):
    counts = dict(sorted(Counter(row["status"] for row in data["results"]).items()))
    status = "failure" if counts.get("failure") else "inconclusive" if not counts or any(counts.get(x) for x in ("inconclusive", "unsupported-capture")) else "pass"
    return dict(data, status=status, counts=counts)


def write_report(directory, data):
    result = summarize(data)
    write_json(directory / "report.json", result)
    lines = ["# Headless playback regression", "", f"Run: `{result['runID']}`", f"Status: **{result['status']}**", "",
             "Scope: controlled decoded-signal tests; no physical speakers, absolute A/V sync, HDR, or universal codec certification.", "",
             "An expected defect detection is a detector pass, not clean playback. Exploratory matrix findings are not established regressions without a prior baseline.", "",
             "| Case | Status | Scope | Result |", "| --- | --- | --- | --- |"]
    for row in result["results"]:
        values = [str(row[key]).replace("|", "\\|").replace("\n", " ") for key in ("case", "status", "scope", "reason")]
        lines.append("| " + " | ".join(values) + " |")
    lines += ["", f"Raw captures retained: {result['rawCapturesRetained']}. " +
              ("Raw evidence can be reanalyzed." if result["rawCapturesRetained"] else "Compact reports remain; raw-signal reanalysis is unavailable."), ""]
    (directory / "report.md").write_text("\n".join(lines))
    return result


def validate_saved(directory):
    data = read_json(directory / "run.json")
    if not isinstance(data, dict) or data.get("schemaVersion") != 1 or data.get("state") != "complete":
        raise InvalidEvidence("unfinished package")
    uuid.UUID(data["runID"])
    if directory.name != data["runID"]: raise InvalidEvidence("package run binding changed")
    if not isinstance(data.get("sourceSHA256"), dict) or set(data["sourceSHA256"]) != set(SOURCE_PATHS):
        raise InvalidEvidence("missing package source provenance")
    if (not isinstance(data.get("suites"), list) or not data["suites"] or data["suites"][0] != "core" or
        len(data["suites"]) != len(set(data["suites"])) or not set(data["suites"]) <= {"core", "matrix", "multichannel"} or
        type(data.get("rawCapturesRetained")) is not bool):
        raise InvalidEvidence("invalid package settings")
    for name, expected in data["sourceSHA256"].items():
        if digest(relative_file(ROOT, name)) != expected: raise InvalidEvidence("source changed since package run")
    artifacts = data.get("artifacts")
    actual_json = {str(path.relative_to(directory)) for path in directory.rglob("*.json") if path.name not in {"run.json", "report.json"}}
    if not isinstance(artifacts, dict) or "admitted-results.json" not in artifacts or not actual_json <= set(artifacts):
        raise InvalidEvidence("missing package artifact provenance")
    for name, expected in data["artifacts"].items():
        if digest(relative_file(directory, name)) != expected: raise InvalidEvidence("package artifact changed")
    rows = data.get("results")
    if (not isinstance(rows, list) or not rows or not all(isinstance(row, dict) and row.get("status") in STATUSES for row in rows) or
        read_json(directory / "admitted-results.json") != rows):
        raise InvalidEvidence("invalid package results")
    if len({row.get("case") for row in rows}) != len(rows): raise InvalidEvidence("duplicate package result")
    for imported in data.get("externalImports", []):
        external_results(relative_file(directory, imported["path"]), imported["runID"])
    if summarize(data)["status"] == "pass":
        expected_commands = {name for name, _, _ in planned_commands(directory, data["suites"][1:])}
        if any(row["case"] == "inventory-report" for row in rows): expected_commands.add("coverage")
        commands = data.get("commands", [])
        if ({row.get("name") for row in commands} != expected_commands or len(commands) != len(expected_commands) or
            any(row.get("exitCode") != 0 or row.get("execution") != "completed" for row in commands)):
            raise InvalidEvidence("missing successful required command")
        validate_complete_package(directory, data)
    return data


def validate_complete_package(directory, data):
    """A green saved package needs the complete requested grid, not just valid hashes."""
    summaries = {row["case"]: row for row in data["results"]}
    expected = {suite + "/" + case for suite in ("offline", "host") for case in CASES}
    if "matrix" in data["suites"]:
        module = load_module("playback-signal-matrix")
        expected |= {"matrix/" + profile[0] for profile in module.PROFILES}
        payload = read_json(relative_file(directory, "matrix/matrix-results.json"))
        if payload.get("schema") != 1 or payload.get("status") != "complete": raise InvalidEvidence("unfinished saved matrix")
        exact_cells(payload.get("results"), "name", [profile[0] for profile in module.PROFILES])
        relative_file(directory, "matrix/matrix-manifest.json")
        relative_file(directory, "matrix/host-results.json")
        for row in payload["results"]:
            if row.get("status") != "signal-pass" or row.get("failures") != []:
                raise InvalidEvidence("saved matrix cannot support a pass")
            expected_row = record("matrix/" + row["name"], "pass", "decoded-reference", "signal-pass",
                                  findings=[], captureRunID=row.get("runID"),
                                  interpretation="exploratory finding, not universal codec support")
            if summaries.get(expected_row["case"]) != expected_row:
                raise InvalidEvidence("saved matrix summary disagrees")
            capture = capture_path(directory / "matrix", row.get("runID"))
            module.lab.validate_manifest(read_json(capture / "capture.json"), row["runID"])
            analysis = read_json(relative_file(capture, "analysis.json"))
            if analysis.get("runID") != row["runID"] or analysis.get("failures") != []:
                raise InvalidEvidence("saved matrix analysis disagrees")
    if "multichannel" in data["suites"]:
        module = load_module("playback-multichannel-lab")
        expected |= {f"multichannel/{profile[0]}/{channels}" for profile in module.PROFILES for channels in (2, 6)}
        rows = read_json(relative_file(directory, "multichannel/results.json"))
        relative_file(directory, "multichannel/manifest.json")
        if not isinstance(rows, list) or len(rows) != len(module.PROFILES) * 2:
            raise InvalidEvidence("missing saved multichannel cells")
        seen = set()
        for row in rows:
            name, channels = row.get("profile"), row.get("requestedChannels")
            key = f"multichannel/{name}/{channels}"
            if key in seen or row.get("status") != "routing-pass" or row.get("failures") != []:
                raise InvalidEvidence("saved multichannel cannot support a pass")
            seen.add(key)
            expected_row = record(key, "pass", "stereo-downmix" if channels == 2 else "decoded-channel-routing",
                                  "routing-pass", findings=[], captureRunID=row.get("runID"))
            if summaries.get(key) != expected_row:
                raise InvalidEvidence("saved multichannel summary disagrees")
            capture = read_json(capture_path(directory / "multichannel", row.get("runID")) / "capture.json")
            if (capture.get("runID") != row["runID"] or capture.get("channels") != channels or
                (channels == 6 and not capture.get("observedChannelLayoutTags"))):
                raise InvalidEvidence("saved multichannel capture disagrees")
    for index, imported in enumerate(data.get("externalImports", [])):
        imported_rows = external_results(relative_file(directory, imported["path"]), imported["runID"])
        expected |= {"external/" + str(index) + "/" + row["case"].removeprefix("external/") for row in imported_rows}
        for row in imported_rows:
            row["case"] = "external/" + str(index) + "/" + row["case"].removeprefix("external/")
            if summaries.get(row["case"]) != row:
                raise InvalidEvidence("saved external summary disagrees")
    if any(row["case"] == "inventory-report" for row in data["results"]):
        expected.add("inventory-report")
        relative_file(directory, "coverage/coverage.json")
    exact_cells(data["results"], "case", expected)
    lab = load_module("playback-signal-lab")
    for suite, filename in (("offline", "self-test-results.json"), ("host", "host-results.json")):
        rows = read_json(relative_file(directory, "core/" + filename))
        exact_cells(rows, "case", CASES)
        for row in rows:
            summary = next(item for item in data["results"] if item["case"] == suite + "/" + row["case"])
            if summary.get("captureRunID") != row.get("runID") or sorted(row.get("failures", [])) != CASES[row["case"]]:
                raise InvalidEvidence("saved detector results disagree")
            expected_row = record(suite + "/" + row["case"], "pass",
                                  "offline-detector" if suite == "offline" else "decoded-reference", "expected classification",
                                  expectation="clean-playback" if row["case"] == "clean" else "detect-injected-defect",
                                  expectedFindings=CASES[row["case"]], findings=CASES[row["case"]], captureRunID=row["runID"],
                                  cleanPlayback=row["case"] == "clean")
            if summary != expected_row: raise InvalidEvidence("saved detector scope or expectation disagrees")
            capture = capture_path(directory / "core", row["runID"])
            lab.validate_manifest(read_json(capture / "capture.json"), row["runID"])
            analysis = read_json(relative_file(capture, "analysis.json"))
            if analysis.get("runID") != row["runID"] or sorted(analysis.get("failures", [])) != CASES[row["case"]]:
                raise InvalidEvidence("saved detector analysis disagrees")
    relative_file(directory, "core/fixture.json")


def clean_raw(directory):
    # Only this newly-created run's owned media/host files; compact metadata and logs survive.
    for path in directory.rglob("*"):
        if path.is_file() and (path.suffix in {".f32le", ".rgba", ".rgb", ".m3u8", ".m4s", ".mp4", ".ts"} or path.name == "signal-host"):
            path.unlink()


def run(args):
    run_id = str(uuid.uuid4())
    directory = args.output.resolve() / run_id
    if not directory.is_relative_to(ROOT / "build"): raise InvalidEvidence("output must remain under build")
    directory.mkdir(parents=True, exist_ok=False)
    data = dict(schemaVersion=1, state="running", runID=run_id, startedAtUTC=datetime.now(timezone.utc).isoformat(),
                platform=platform.platform(), suites=["core", *args.suite], sourceSHA256={name: digest(ROOT / name) for name in SOURCE_PATHS},
                settings={"simulator": False, "inheritedSignalLabEnvironment": "cleared", "audioTap": False},
                commands=[], results=[], artifacts={}, externalImports=[], rawCapturesRetained=args.keep_captures)
    write_json(directory / "run.json", data)
    unavailable = set()
    for name, command, timeout in planned_commands(directory, args.suite):
        suite = name.split("-")[0]
        if suite in unavailable: continue
        outcome = execute(command, directory / (name + ".log"), timeout)
        data["commands"].append(dict(name=name, **outcome))
        if outcome["execution"] == "timeout" or (name.endswith("generate") and outcome["exitCode"] != 0):
            unavailable.add(suite)
            data["results"].append(record(suite, "inconclusive", "capture-harness", "bounded command failed or timed out"))
        elif suite == "core" and outcome["exitCode"] != 0:
            data["results"].append(record(name, "inconclusive", "capture-harness", "required detector command exited unsuccessfully"))
        write_json(directory / "run.json", data)
    for suite in ("core", *args.suite):
        if suite in unavailable: continue
        try:
            first = len(data["results"])
            if suite == "core":
                data["results"] += detector_results(directory / suite, "self-test-results.json", "offline")
                data["results"] += detector_results(directory / suite, "host-results.json", "host")
            elif suite == "matrix": data["results"] += matrix_results(directory / suite)
            else: data["results"] += multichannel_results(directory / suite)
            suite_rows = data["results"][first:]
            suite_commands = [row for row in data["commands"] if row["name"].startswith(suite + "-")]
            if suite_rows and all(row["status"] == "pass" for row in suite_rows) and any(row["exitCode"] != 0 for row in suite_commands):
                data["results"].append(record(suite + "/execution", "inconclusive", "capture-harness", "successful evidence but unsuccessful command completion"))
        except (ValueError, KeyError, TypeError, OSError) as error:
            data["results"].append(record(suite, "inconclusive", "capture-harness", "incomplete or invalid suite evidence"))
            (directory / (suite + "-admission.log")).write_text(type(error).__name__ + ": evidence admission failed\n")
    for index, (path, expected_id) in enumerate(args.evidence):
        try:
            imported_rows = external_results(Path(path), expected_id)
            for row in imported_rows: row["case"] = "external/" + str(index) + "/" + row["case"].removeprefix("external/")
            data["results"] += imported_rows
            envelope = read_json(path)
            artifact = relative_file(Path(path).parent, envelope["artifact"]["path"])
            imported = directory / "external" / str(index)
            imported.mkdir(parents=True)
            (imported / "evidence.json").write_bytes(artifact.read_bytes())
            envelope["artifact"]["path"] = "evidence.json"
            write_json(imported / "envelope.json", envelope)
            data["externalImports"].append(dict(path=str((imported / "envelope.json").relative_to(directory)), runID=expected_id))
        except (ValueError, KeyError, TypeError, OSError):
            data["results"].append(record(f"external/{index}", "inconclusive", "external-evidence", "external provenance or schema rejected"))
    if args.inventory:
        command = [sys.executable, ROOT / "scripts/playback-coverage.py", "--inventory", args.inventory, "--output", directory / "coverage"]
        for suite, filename in [("matrix", "matrix-results.json"), ("multichannel", "results.json")]:
            if suite in args.suite and (directory / suite / filename).exists(): command += ["--results", directory / suite / filename]
        outcome = execute(command, directory / "coverage.log", 120)
        data["commands"].append(dict(name="coverage", **outcome))
        data["results"].append(record("inventory-report", "pass" if outcome["exitCode"] == 0 else "inconclusive", "coverage-planning-not-playback", "report generated" if outcome["exitCode"] == 0 else "report generation failed"))
    if any(digest(ROOT / name) != expected for name, expected in data["sourceSHA256"].items()):
        data["results"].append(record("source-consistency", "inconclusive", "capture-harness", "source changed while package was running"))
    write_json(directory / "admitted-results.json", data["results"])
    if not args.keep_captures: clean_raw(directory)
    data["artifacts"] = {str(path.relative_to(directory)): digest(path) for path in sorted(directory.rglob("*"))
                         if path.is_file() and path.name != "run.json" and
                         (path.suffix == ".json" or (args.keep_captures and path.suffix in {".f32le", ".rgba", ".rgb", ".m3u8", ".m4s", ".mp4", ".ts"}))}
    data.update(state="complete", completedAtUTC=datetime.now(timezone.utc).isoformat())
    write_json(directory / "run.json", data)
    result = write_report(directory, data)
    print(json.dumps({"runID": run_id, "status": result["status"], "counts": result["counts"], "report": str(directory / "report.md")}))
    return 0 if result["status"] == "pass" else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("plan", "run", "report"))
    parser.add_argument("--suite", choices=("matrix", "multichannel"), action="append", default=[])
    parser.add_argument("--output", type=Path, default=ROOT / "build/playback-regression")
    parser.add_argument("--run-directory", type=Path)
    parser.add_argument("--inventory", type=Path)
    parser.add_argument("--evidence", nargs=2, action="append", default=[], metavar=("ENVELOPE", "RUN_UUID"))
    parser.add_argument("--keep-captures", action="store_true")
    args = parser.parse_args()
    args.suite = sorted(set(args.suite))
    try:
        if args.action == "plan":
            print(json.dumps({"controlledCases": list(CASES), "commands": [dict(name=name, argv=[str(x) for x in command], timeoutSeconds=timeout) for name, command, timeout in planned_commands(args.output / "<new-run-uuid>", args.suite)]}, indent=2))
            return 0
        if args.action == "report":
            if args.run_directory is None: parser.error("report requires --run-directory")
            result = write_report(args.run_directory, validate_saved(args.run_directory))
            print(json.dumps({"status": result["status"], "counts": result["counts"]}))
            return 0 if result["status"] == "pass" else 1
        return run(args)
    except (OSError, ValueError, KeyError, TypeError):
        print("regression package could not be completed or admitted; inspect the private run directory", file=sys.stderr)
        return 2


if __name__ == "__main__": raise SystemExit(main())
