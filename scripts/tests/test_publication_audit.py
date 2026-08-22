import importlib.util
import json
import sys
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "publication_audit", REPO / "scripts" / "publication-audit.py")
assert SPEC and SPEC.loader
AUDIT = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = AUDIT
SPEC.loader.exec_module(AUDIT)


class PublicationAuditTests(unittest.TestCase):
    def test_home_path_is_blocking_and_redacted(self):
        audit = AUDIT.Audit([], [])
        audit.add_text("tracked", "doc.md", "build from /path/to/user/secret/project")
        self.assertEqual(audit.blockers, 1)
        report = AUDIT.render_text(audit)
        self.assertIn("/Users/<user>", report)
        self.assertNotIn("/path/to/user", report)

    def test_private_ip_and_token_shaped_value_block_without_leaking(self):
        token = "not-a-real-secret-value-123456"
        audit = AUDIT.Audit([], [])
        audit.add_text("tracked", "doc.md", f"host 192.0.2.10 token={token}")
        self.assertEqual(audit.blockers, 2)
        report = AUDIT.render_json(audit, None, "a" * 40)
        self.assertNotIn("192.0.2.10", report)
        self.assertNotIn(token, report)

    def test_documentary_header_can_be_narrowly_allowlisted(self):
        entries = [{
            "surface": "tracked", "location": "approved.md",
            "category": "plex_token_marker", "reason": "public API terminology",
        }]
        audit = AUDIT.Audit(entries, [])
        audit.add_text("tracked", "approved.md", "The X-Plex-Token header is confidential.")
        self.assertEqual(audit.blockers, 0)
        self.assertTrue(audit.findings[0].allowlisted)
        other = AUDIT.Audit(entries, [])
        other.add_text("tracked", "unapproved.md", "The X-Plex-Token header is confidential.")
        self.assertFalse(other.findings[0].allowlisted)

    def test_configured_forbidden_value_never_reaches_reports(self):
        forbidden = "private.example.invalid"
        audit = AUDIT.Audit([], [forbidden])
        audit.add_text("github", "issue:1:body", f"server={forbidden}")
        self.assertEqual(audit.blockers, 1)
        text = AUDIT.render_text(audit)
        structured = AUDIT.render_json(audit, "owner/repo", "b" * 40)
        self.assertNotIn(forbidden, text)
        self.assertNotIn(forbidden, structured)

    def test_edited_comment_is_a_blocker_until_history_is_reviewed(self):
        audit = AUDIT.Audit([], [])
        audit.add_text("github", "issue:1:comment:2", "safe current text", edited=True)
        self.assertEqual(audit.blockers, 1)
        self.assertEqual(audit.findings[0].category, "edit_history_unverified")

    def test_json_schema_and_status_are_stable(self):
        audit = AUDIT.Audit([], [])
        payload = json.loads(AUDIT.render_json(audit, "owner/repo", "c" * 40))
        self.assertEqual(payload["schema"], "publication-audit/v1")
        self.assertEqual(payload["status"], "pass")
        self.assertEqual(payload["counts"]["blockers"], 0)
        self.assertEqual(payload["targetSha"], "c" * 40)

    def test_placeholder_values_are_not_mistaken_for_private_values(self):
        audit = AUDIT.Audit([], [])
        audit.add_text("tracked", "doc.md", "plex.example.internal 192.0.2.10 /path/to/labstream")
        self.assertEqual(audit.blockers, 0)

    def test_live_shaped_emby_connect_fixture_is_detected(self):
        self.assertIsNotNone(AUDIT.EMBY_CONNECT_LIVE_FIXTURE.search(
            '{"AccessKey":"0123abc9"}'))
        self.assertIsNone(AUDIT.EMBY_CONNECT_LIVE_FIXTURE.search(
            '{"AccessKey":"server-access-key"}'))


if __name__ == "__main__":
    unittest.main()
