import json
from pathlib import Path
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "diagnostics-summarize.py"


def write_events(bundle: Path, events: list[dict], suffix: str = "") -> None:
    bundle.mkdir(parents=True, exist_ok=True)
    (bundle / "summary.json").write_text(json.dumps({"device": "test-device", "bundle_id": "com.example.Labstream"}) + "\n")
    directory = bundle / "app-container-files/Library/Application Support/Labstream/Diagnostics"
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / f"app-diagnostics.jsonl{suffix}"
    path.write_text("".join(json.dumps(event) + "\n" for event in events))


class DiagnosticsSummarizeTests(unittest.TestCase):
    def run_script(self, bundle: Path, *args: str) -> dict:
        subprocess.run([str(SCRIPT), str(bundle), *args], check=True, text=True,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        return json.loads((bundle / "analysis/summary.json").read_text())

    def test_repeated_pull_reports_no_new_events(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            first = root / "headset-evidence-001"
            second = root / "headset-evidence-002"
            events = [
                {"timestamp": "2026-07-15T12:00:00Z", "category": "Downloads", "name": "downloads.retry", "fields": {"attempt": 1}},
                {"timestamp": "2026-07-15T12:00:01Z", "category": "Playback", "name": "playback.snapshot", "fields": {"state": "playing"}},
            ]
            write_events(first, events)
            write_events(second, events)
            self.run_script(first)
            summary = self.run_script(second, "--auto-baseline")
            self.assertEqual(summary["baseline"]["bundle"], first.name)
            self.assertEqual(summary["baseline"]["new_strict_events"], 0)
            self.assertEqual(summary["baseline"]["new_semantic_events"], 0)
            self.assertIn("do not re-ingest", (second / "analysis/triage.md").read_text())
            self.assertEqual((second / "analysis/novel-events.jsonl").read_text(), "")

    def test_repetition_is_counted_and_private_fields_are_not_emitted(self):
        with tempfile.TemporaryDirectory() as tmp:
            bundle = Path(tmp) / "headset-evidence-001"
            secret = "https://private.example/token-value"
            events = [
                {"timestamp": f"2026-07-15T12:00:{i:02d}Z", "category": "Downloads",
                 "name": "downloads.inflight_ownerless_repaired", "fields": {"url": secret, "attempt": 1}}
                for i in range(20)
            ]
            write_events(bundle, events)
            summary = self.run_script(bundle)
            self.assertEqual(summary["event_count"], 20)
            self.assertEqual(summary["counts"]["events"]["downloads.inflight_ownerless_repaired"], 20)
            for output in ("triage.md", "summary.json", "compact-events.jsonl", "novel-events.jsonl"):
                self.assertNotIn(secret, (bundle / "analysis" / output).read_text())
            self.assertLess((bundle / "analysis/triage.md").stat().st_size, 16_384)

    def test_malformed_lines_are_reported_not_silently_dropped(self):
        with tempfile.TemporaryDirectory() as tmp:
            bundle = Path(tmp) / "headset-evidence-001"
            write_events(bundle, [{"timestamp": "t", "category": "App", "name": "ok"}])
            path = next(bundle.rglob("app-diagnostics.jsonl"))
            path.write_text(path.read_text() + "not-json\n")
            summary = self.run_script(bundle)
            self.assertEqual(summary["event_count"], 1)
            self.assertEqual(summary["parse_errors"], 1)

    def test_novelty_sample_is_bounded_and_sources_are_unchanged(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            first = root / "headset-evidence-001"
            second = root / "headset-evidence-002"
            write_events(first, [{"timestamp": "t0", "category": "App", "name": "start"}])
            events = [
                {"timestamp": f"t{i}", "category": "Downloads", "name": f"event.{i}", "fields": {"value": i}}
                for i in range(100)
            ]
            write_events(second, events)
            source = next(second.rglob("app-diagnostics.jsonl"))
            before = source.read_bytes()
            self.run_script(first)
            summary = self.run_script(second, "--auto-baseline")
            self.assertEqual(len((second / "analysis/novel-events.jsonl").read_text().splitlines()), 50)
            self.assertEqual(summary["baseline"]["novel_references_omitted"], 50)
            self.assertEqual(source.read_bytes(), before)

    def test_unsafe_event_labels_are_hashed_not_emitted(self):
        with tempfile.TemporaryDirectory() as tmp:
            bundle = Path(tmp) / "headset-evidence-001"
            secret = "https://private.example/media-title"
            write_events(bundle, [{"timestamp": "t", "category": secret, "name": secret}])
            summary = self.run_script(bundle)
            self.assertEqual(summary["schema_errors"], 1)
            for output in ("triage.md", "summary.json", "compact-events.jsonl", "novel-events.jsonl"):
                self.assertNotIn(secret, (bundle / "analysis" / output).read_text())

    def test_auto_baseline_does_not_cross_device_scope(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            first = root / "headset-evidence-001"
            second = root / "headset-evidence-002"
            event = {"timestamp": "t", "category": "App", "name": "same"}
            write_events(first, [event])
            write_events(second, [event])
            (second / "summary.json").write_text(json.dumps({"device": "other-device", "bundle_id": "com.example.Labstream"}))
            self.run_script(first)
            summary = self.run_script(second, "--auto-baseline")
            self.assertIsNone(summary["baseline"]["bundle"])

    def test_multiset_delta_detects_more_copies_of_the_same_event(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            first = root / "headset-evidence-001"
            second = root / "headset-evidence-002"
            event = {"timestamp": "same", "category": "Downloads", "name": "downloads.retry"}
            write_events(first, [event])
            write_events(second, [event, event, event])
            self.run_script(first)
            summary = self.run_script(second, "--auto-baseline")
            self.assertEqual(summary["baseline"]["new_strict_events"], 2)
            self.assertEqual(summary["baseline"]["new_strict_fingerprints"], 0)
            self.assertEqual(len((second / "analysis/novel-events.jsonl").read_text().splitlines()), 2)


if __name__ == "__main__":
    unittest.main()
