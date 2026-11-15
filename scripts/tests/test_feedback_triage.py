import pathlib
import unittest
from _script_loader import load_script

ROOT = pathlib.Path(__file__).resolve().parents[2]
triage = load_script("feedback_triage", ROOT / "scripts/feedback-triage.py")
symbolicate = load_script("symbolicate_report", ROOT / "scripts/symbolicate-report.py")


class LabelTests(unittest.TestCase):
    def body(self, environment):
        return f"### What happened?\n\nIt froze\n\n### App and device\n\n{environment}\n\n### Diagnostic report (redacted)\n\n```text\nx\n```\n"

    def test_environment_line_is_read_from_the_form_heading(self):
        line = "Labstream 1.8.0 (1657) · iOS Version 27.1 · iPhone17,1 · TestFlight · Jellyfin 10.9.11 · https"
        self.assertEqual(triage.environment_line(self.body(line)), line)
        self.assertEqual(triage.environment_line(self.body("_No response_")), "")
        self.assertEqual(triage.environment_line("no headings"), "")

    def test_platform_and_backend_labels(self):
        cases = {
            "Labstream 1.8.0 (1657) · iOS Version 27.1 · iPhone17,1 · TestFlight · Jellyfin 10.9.11 · https":
                ["platform:ios", "backend:jellyfin"],
            "Labstream 1.8.0 (1) · visionOS Version 27.0 · RealityDevice14,1 · App Store · Plex Media Server 1.40.2.8395 · https":
                ["platform:visionos", "backend:plex"],
            "Labstream 1.8.0 (1) · tvOS Version 27.0 · AppleTV14,1 · App Store · Emby 4.8.11.0 · http":
                ["platform:tvos", "backend:emby"],
            "Labstream 1.8.0 (1) · macOS Version 27.2 · Mac15,6 · Development · Emby · https":
                ["platform:macos", "backend:emby"],
            "Labstream 1.8.0 (1) · iOS Version 27.1 · iPad16,3 · App Store · Plex Media Server · https":
                ["platform:ipados", "backend:plex"],
            "": [],
        }
        for environment, expected in cases.items():
            self.assertEqual(triage.labels_for(environment), expected, environment)


class DraftTests(unittest.TestCase):
    DIGEST = {
        "feedback": [{"kind": "crash", "platform": "IOS", "build": "1657", "os": "27.1", "device": "iPhone17,1",
                      "created": "2026-11-14T10:00:00Z", "email": "tester@example.com",
                      "comment": "It crashed while I watched Some Private Film", "files": ["a.png"]}],
        "reviews": [{"rating": 2, "platform": "TV_OS", "app_version": "1.8.0", "created": "2026-11-13T09:00:00Z",
                     "nickname": "couchfan", "territory": "USA", "title": "Audio", "body": "Sound is off"}],
    }

    def test_private_text_stays_below_the_marker(self):
        drafts = dict(triage.drafts_from(self.DIGEST))
        self.assertEqual(sorted(drafts), ["feedback-01", "review-01"])
        public, private = drafts["feedback-01"].split(triage.PRIVATE_MARKER)
        self.assertIn("labels: needs-triage, source:testflight, platform:ios, bug", public)
        for secret in ("tester@example.com", "Some Private Film", "a.png"):
            self.assertNotIn(secret, public)
            self.assertIn(secret, private)
        public, private = drafts["review-01"].split(triage.PRIVATE_MARKER)
        self.assertIn("labels: needs-triage, source:review, platform:tvos", public)
        self.assertNotIn("couchfan", public)
        self.assertNotIn("Sound is off", public)

    def test_unedited_draft_is_refused_and_private_part_is_never_sent(self):
        draft = dict(triage.drafts_from(self.DIGEST))["feedback-01"]
        with self.assertRaisesRegex(ValueError, "no title"):
            triage.parse_draft(draft)
        titled = draft.replace("title: ", "title: Crash during playback on iPhone", 1)
        with self.assertRaisesRegex(ValueError, "placeholder"):
            triage.parse_draft(titled)
        ready = titled.replace(triage.SUMMARY_PLACEHOLDER, "The app closed about a minute into a film.")
        title, labels, body = triage.parse_draft(ready)
        self.assertEqual(title, "Crash during playback on iPhone")
        self.assertEqual(labels, ["needs-triage", "source:testflight", "platform:ios", "bug"])
        self.assertIn("The app closed about a minute into a film.", body)
        for secret in ("tester@example.com", "Some Private Film", triage.PRIVATE_MARKER, "title:", "labels:"):
            self.assertNotIn(secret, body)
        with self.assertRaisesRegex(ValueError, "empty"):
            triage.parse_draft(titled.replace(triage.SUMMARY_PLACEHOLDER, ""))


class SymbolicateTests(unittest.TestCase):
    def test_only_the_app_binary_frames_get_addresses(self):
        lines = ["- Crash at 2026-11-14T00:00:00Z: EXC_BREAKPOINT",
                 "    app binary UUID: AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
                 "    Labstream +0x1a2e3c", "    SwiftUI +0x1000", "    Labstream +0x10", "Labstream +0x20"]
        self.assertEqual(symbolicate.frame_addresses(lines, "Labstream", 0x100000000),
                         {2: "0x1001a2e3c", 4: "0x100000010"})
        self.assertEqual(symbolicate.UUID_LINE.findall("\n".join(lines)), ["AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"])


if __name__ == "__main__":
    unittest.main()
