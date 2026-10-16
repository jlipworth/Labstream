#!/usr/bin/env python3
"""Bounded synthetic app-controller transition runner. No credentials/live admission.

The fixture uses the actual hosted PlaybackController's consent/stop lifecycle with
in-memory media-browser callbacks. It does not prove visible playback or server cleanup.
"""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from bounded_process import terminate_process_group

SUITE = "PlaybackAgentEvidenceTests"
# The fixture contract: consent lifecycle (parameterized over Jellyfin/Emby), admission,
# invalid options, and backend-change refusal. Swift Testing identifiers keep the `()` or
# argument-label suffix; xcodebuild accepts them verbatim in -only-testing.
REQUIRED_TESTS = (
    "fixtureConsentTransitions(backend:)",
    "admissionIsSeparateForVideoEncoding()",
    "invalidOptionsFailClosed()",
    "changedBackendStopsBeforeStartingPlayback()",
)


def test_case_results(nodes):
    """Yield (nodeIdentifier, result, argument results) for every Test Case node."""
    for node in nodes or []:
        if not isinstance(node, dict):
            raise ValueError("malformed test node")
        if node.get("nodeType") == "Test Case":
            arguments = [child.get("result") for child in node.get("children") or []
                         if isinstance(child, dict) and child.get("nodeType") == "Arguments"]
            yield node.get("nodeIdentifier"), node.get("result"), arguments
        else:
            yield from test_case_results(node.get("children"))


def fixture_passed(summary, tests):
    """Fail closed unless exactly the required tests ran and every selected case passed."""
    if summary.get("result") != "Passed" or summary.get("failedTests") != 0 or summary.get("skippedTests") != 0:
        return False
    passed = summary.get("passedTests")
    if type(passed) is not int or passed < len(REQUIRED_TESTS):
        return False
    cases = list(test_case_results(tests.get("testNodes")))
    if not cases or any(result != "Passed" or any(arg != "Passed" for arg in arguments)
                        for _, result, arguments in cases):
        return False
    return {identifier for identifier, _, _ in cases} == {f"{SUITE}/{name}" for name in REQUIRED_TESTS}


def xcresult_json(kind, bundle):
    completed = subprocess.run(["xcrun", "xcresulttool", "get", "test-results", kind, "--path",
                                str(bundle), "--format", "json"],
                               capture_output=True, timeout=30, check=True)
    value = json.loads(completed.stdout)
    if not isinstance(value, dict):
        raise ValueError("malformed xcresult")
    return value


def run(command, log, timeout):
    with subprocess.Popen(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
                          start_new_session=True) as process:
        try:
            return process.wait(timeout=timeout)
        except BaseException:
            terminate_process_group(process)
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
                   *(f"-only-testing:LabstreamMacTests/{SUITE}/{name}" for name in REQUIRED_TESTS), "test",
                   "CODE_SIGNING_ALLOWED=NO", "-enableCodeCoverage", "NO",
                   "PRODUCT_BUNDLE_IDENTIFIER=org.labstream.Labstream.dev." + run_id]
        with (output / "private-build.log").open("w") as log:
            code = run(command, log, args.timeout)
        summary = xcresult_json("summary", output / "fixture.xcresult")
        tests = xcresult_json("tests", output / "fixture.xcresult")
        passed = summary.get("passedTests", 0)
        valid = code == 0 and fixture_passed(summary, tests)
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
