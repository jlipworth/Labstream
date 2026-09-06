#!/usr/bin/env python3
"""Bounded synthetic app-controller transition runner. No credentials/live admission.

The fixture uses the actual hosted PlaybackController's consent/stop lifecycle with
in-memory media-browser callbacks. It does not prove visible playback or server cleanup.
"""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]


def run(command, log, timeout):
    with subprocess.Popen(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
                          start_new_session=True) as process:
        try:
            return process.wait(timeout=timeout)
        except BaseException:
            # Only this subprocess group, never an app-name/pattern kill or a container reset.
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("scenario", choices=["fixture-consent"])
    parser.add_argument("--timeout", type=int, default=600)
    args = parser.parse_args()
    if not 60 <= args.timeout <= 1800:
        parser.error("timeout must be 60 through 1800 seconds")
    run_id = "run-" + uuid.uuid4().hex[:12]
    output = ROOT / "artifacts/agent-platform-runs" / run_id
    output.mkdir(parents=True, mode=0o700)
    result = dict(schemaVersion=1, scenario=args.scenario, evidenceKind="syntheticAppController",
                  status="blocked", reason="precondition", visibleAttachment="unknown",
                  serverCleanup="unknown", hardwareDecode="unknown", passedTests=0)
    start = time.monotonic()
    try:
        if sys.platform != "darwin":
            raise OSError("unsupported")
        command = ["scripts/xcodebuild-versioned.sh", "-project", "Labstream.xcodeproj",
                   "-scheme", "LabstreamMac", "-testPlan", "LabstreamMacTests",
                   "-destination", "platform=macOS,arch=arm64", "-derivedDataPath", str(output / "DerivedData"),
                   "-resultBundlePath", str(output / "fixture.xcresult"),
                   "-only-testing:LabstreamMacTests/PlaybackAgentEvidenceTests", "test",
                   "CODE_SIGNING_ALLOWED=NO", "-enableCodeCoverage", "NO",
                   "PRODUCT_BUNDLE_IDENTIFIER=org.labstream.Labstream.dev." + run_id]
        with (output / "private-build.log").open("w") as log:
            code = run(command, log, args.timeout)
        summary = subprocess.run(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path",
                                  str(output / "fixture.xcresult"), "--format", "json"],
                                 capture_output=True, timeout=30, check=True)
        facts = json.loads(summary.stdout)
        passed = facts.get("passedTests", 0)
        valid = code == 0 and facts.get("result") == "Passed" and passed == 4 and facts.get("failedTests") == 0 and facts.get("skippedTests") == 0
        result.update(status="passed" if valid else "failed", reason="fixture_assertions" if valid else "fixture_failed",
                      passedTests=passed if type(passed) is int else 0)
    except (OSError, ValueError, subprocess.SubprocessError):
        result.update(status="blocked", reason="execution_unavailable")
    except KeyboardInterrupt:
        result.update(status="blocked", reason="cancelled")
    result["elapsedSeconds"] = round(time.monotonic() - start, 2)
    encoded = json.dumps(result, sort_keys=True, allow_nan=False) + "\n"
    (output / "run.json").write_text(encoded)
    print(encoded, end="")
    return {"passed": 0, "failed": 1, "blocked": 2}[result["status"]]


if __name__ == "__main__":
    sys.exit(main())
