import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

from _script_loader import load_script

SCRIPT = Path(__file__).resolve().parents[1] / "agent-playback-run.py"
runner = load_script("agent_playback_run", SCRIPT)


SUITE_URL = "test://com.apple.xcode/Labstream/LabstreamMacTests/PlaybackAgentEvidenceTests"


def case(name, result="Passed", arguments=()):
    node = dict(name=name, nodeIdentifier=f"PlaybackAgentEvidenceTests/{name}", nodeType="Test Case",
                result=result, nodeIdentifierURL=f"{SUITE_URL}/{name}")
    if arguments:
        node["children"] = [dict(name=label, nodeType="Arguments", result=outcome) for label, outcome in arguments]
    return node


def tree(cases):
    suite = dict(name="PlaybackAgentEvidenceTests", nodeType="Test Suite", result="Passed", children=cases)
    bundle = dict(name="LabstreamMacTests", nodeType="Unit test bundle", result="Passed", children=[suite])
    return dict(testNodes=[dict(name="LabstreamMacTests", nodeType="Test Plan", result="Passed", children=[bundle])])


def required_cases(consent_arguments=((".emby", "Passed"), (".jellyfin", "Passed"))):
    return [case("changedBackendStopsBeforeStartingPlayback()"), case("admissionIsSeparateForVideoEncoding()"),
            case("invalidOptionsFailClosed()"),
            case("fixtureConsentTransitions(backend:)", arguments=consent_arguments)]


GREEN = dict(result="Passed", passedTests=4, failedTests=0, skippedTests=0, totalTestCount=4)


class AgentPlaybackRunnerTests(unittest.TestCase):
    def invoke(self, summary, tests=None, *, failure=None):
        tests = tree(required_cases()) if tests is None else tests
        with tempfile.TemporaryDirectory() as directory:
            output = io.StringIO()

            def xcresult(command, **_):
                payload = tests if command[command.index("test-results") + 1] == "tests" else summary
                return subprocess.CompletedProcess(command, 0, stdout=json.dumps(payload).encode())

            with mock.patch.object(runner, "ROOT", Path(directory)), mock.patch.object(sys, "platform", "darwin"), \
                 mock.patch.object(sys, "argv", [str(SCRIPT), "fixture-consent"]), \
                 mock.patch.object(runner, "run", side_effect=failure, return_value=0) as execute, \
                 mock.patch.object(subprocess, "run", side_effect=xcresult), mock.patch("sys.stdout", output):
                code = runner.main()
            value = json.loads(output.getvalue())
            self.assertNotIn(directory, output.getvalue())
            if execute.call_args:
                command = execute.call_args.args[0]
                selected = [arg for arg in command if arg.startswith("-only-testing:")]
                self.assertEqual(sorted(selected), sorted(
                    "-only-testing:LabstreamMacTests/PlaybackAgentEvidenceTests/" + name
                    for name in runner.REQUIRED_TESTS))
                self.assertTrue(any(arg.startswith("PRODUCT_BUNDLE_IDENTIFIER=org.labstream.Labstream.dev.") for arg in command))
                self.assertFalse(any("--vp-probe-allow-live" in arg for arg in command))
            return code, value

    def test_only_complete_fixture_assertions_pass(self):
        code, value = self.invoke(GREEN)
        self.assertEqual(code, 0)
        self.assertEqual((value["status"], value["reason"], value["passedTests"]),
                         ("passed", "fixture_assertions", 4))
        self.assertEqual(value["visibleAttachment"], "unknown")
        for bad in [dict(GREEN, passedTests=0), dict(GREEN, failedTests=1), dict(GREEN, skippedTests=1),
                    dict(GREEN, result="Failed"), dict(GREEN, passedTests="4")]:
            code, value = self.invoke(bad)
            self.assertEqual((code, value["status"], value["reason"]), (1, "failed", "fixture_failed"))

    def test_parameterized_cases_may_count_separately(self):
        code, value = self.invoke(dict(GREEN, passedTests=5, totalTestCount=5))
        self.assertEqual((code, value["status"], value["passedTests"]), (0, "passed", 5))

    def test_selected_tests_must_cover_exactly_the_required_set(self):
        cases = required_cases()
        variants = [
            tree(cases[:-1]),
            tree(cases + [case("detachedSeekClockRemainsPending()")]),
            tree(cases[:-1] + [case("fixtureConsentTransitions(backend:)", "Failed")]),
            tree(cases[1:] + [case("changedBackendStopsBeforeStartingPlayback()", "Skipped")]),
            tree(required_cases(((".emby", "Passed"), (".jellyfin", "Failed")))),
            tree([]),
            dict(testNodes=["malformed"]),
        ]
        for tests in variants:
            code, value = self.invoke(GREEN, tests)
            self.assertEqual(code, 1 if tests.get("testNodes") != ["malformed"] else 2, tests)

    def test_timeout_is_blocked_and_does_not_echo_error(self):
        code, value = self.invoke({}, failure=subprocess.TimeoutExpired("private-sentinel", 1))
        self.assertEqual(code, 2)
        self.assertNotIn("private-sentinel", json.dumps(value))


if __name__ == "__main__":
    unittest.main()
