import contextlib
import importlib.util
import io
import pathlib
import sys
import tempfile
import unittest
import unittest.mock

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("asc_metadata", ROOT / "scripts/asc-metadata.py")
am = importlib.util.module_from_spec(spec)
sys.modules["asc_metadata"] = am
spec.loader.exec_module(am)


class FakeClient:
    app_id = "app"

    def __init__(self, notes="", description="Old description", state="PREPARE_FOR_SUBMISSION"):
        self.calls = []
        self.state = state
        self.notes = notes
        self.description = description

    def request(self, method, path, params=None, body=None):
        self.calls.append((method, path, body))
        if method != "GET":
            return None
        if path.endswith("/appInfos"):
            return {"data": [{"id": "info", "attributes": {"state": "PREPARE_FOR_SUBMISSION"}}]}
        if path.endswith("/appInfoLocalizations"):
            return {"data": [{"id": "infoloc", "attributes": {
                "locale": "en-US", "name": "Labstream", "subtitle": "Client", "privacyPolicyUrl": "https://example.org/p"}}]}
        if path.endswith("/appStoreVersions"):
            platform = params["filter[platform]"]
            return {"data": [{"id": f"ver-{platform}", "attributes": {
                "versionString": "1.0", "platform": platform, "appStoreState": self.state, "copyright": "2026 Example"}}]}
        if path.endswith("/appStoreVersionLocalizations"):
            return {"data": [{"id": f"loc-{path.split('/')[3]}", "attributes": {
                "locale": "en-US", "description": self.description, "keywords": "a,b",
                "promotionalText": None, "whatsNew": None, "supportUrl": "https://example.org/s", "marketingUrl": None}}]}
        if path.endswith("/appStoreReviewDetail"):
            return {"data": {"id": f"review-{path.split('/')[3]}", "attributes": {"notes": self.notes}}}
        raise AssertionError(path)


def run(argv, client):
    out = io.StringIO()
    with contextlib.redirect_stdout(out), \
         unittest.mock.patch.object(am, "with_client", lambda args, action: action(client)):
        code = am.main(argv)
    return code, out.getvalue()



class MetadataTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.tmp.name) / "metadata"

    def tearDown(self):
        self.tmp.cleanup()

    def pull(self, client):
        return run(["--root", str(self.root), "pull", "--platform", "ios"], client)

    def test_pull_writes_one_file_per_field_and_round_trips(self):
        client = FakeClient(notes="Use the review server.")
        code, out = self.pull(client)
        self.assertEqual(code, 0)
        self.assertEqual((self.root / "app/en-US/name.txt").read_text(), "Labstream\n")
        self.assertEqual((self.root / "ios/review_notes.txt").read_text(), "Use the review server.\n")
        self.assertEqual((self.root / "ios/en-US/whats_new.txt").read_text(), "\n")
        code, out = run(["--root", str(self.root), "diff", "--platform", "ios"], client)
        self.assertIn("matches the repository", out)
        self.assertTrue(all(method == "GET" for method, _, _ in client.calls))

    def test_push_is_a_dry_run_without_yes(self):
        self.pull(FakeClient())
        (self.root / "ios/en-US/description.txt").write_text("New description\n")
        client = FakeClient()
        code, out = run(["--root", str(self.root), "push", "--platform", "ios"], client)
        self.assertEqual(code, 0)
        self.assertIn("dry run: 1 field(s)", out)
        self.assertIn("+New description", out)
        self.assertTrue(all(method == "GET" for method, _, _ in client.calls))

    def test_push_yes_patches_only_changed_fields(self):
        self.pull(FakeClient())
        (self.root / "ios/en-US/description.txt").write_text("New description\n")
        (self.root / "ios/review_notes.txt").write_text("Notes\n")
        client = FakeClient()
        code, out = run(["--root", str(self.root), "push", "--platform", "ios", "--yes"], client)
        self.assertEqual(code, 0, out)
        patches = [(path, body) for method, path, body in client.calls if method == "PATCH"]
        self.assertEqual(len(patches), 2)
        by_type = {body["data"]["type"]: body["data"]["attributes"] for _, body in patches}
        self.assertEqual(by_type["appStoreVersionLocalizations"], {"description": "New description"})
        self.assertEqual(by_type["appStoreReviewDetails"], {"notes": "Notes"})

    def test_review_detail_never_requests_contact_or_demo_fields(self):
        client = FakeClient()
        self.pull(client)
        written = {p.name for p in self.root.rglob("*.txt")}
        self.assertFalse({n for n in written if "demo" in n or "contact" in n or "password" in n})

    def test_push_refuses_invalid_files(self):
        self.pull(FakeClient())
        (self.root / "ios/en-US/keywords.txt").write_text("x" * 101 + "\n")
        code, out = run(["--root", str(self.root), "push", "--platform", "ios", "--yes"], FakeClient())
        self.assertEqual(code, 1)
        self.assertIn("limit 100", out)

    def test_check_rules(self):
        field = am.Field("keywords.txt", "keywords", 100, bytes_limit=True)
        self.assertTrue(am.problems_for(field, "a, b", "ios/en-US"))
        self.assertTrue(am.problems_for(field, "é" * 51, "ios/en-US"))
        url = am.Field("support_url.txt", "supportUrl", 255, url=True)
        self.assertTrue(am.problems_for(url, "http://example.org", "ios/en-US"))
        self.assertFalse(am.problems_for(url, "", "ios/en-US"))

    def test_review_notes_reject_server_addresses(self):
        notes = am.REVIEW_FIELDS[0]
        for leak in ("https://review.example.org", "jellyfin.example.net:8096", "192.0.2.10",
                     "reviewer@example.com"):
            self.assertTrue(am.problems_for(notes, f"Sign in to {leak} now.", "ios"), leak)
        self.assertFalse(am.problems_for(notes, "Use the address in Sign-In Information, e.g. there.", "ios"))

    def test_pull_does_not_copy_review_notes_with_an_address(self):
        code, out = self.pull(FakeClient(notes="Server: review.example.org"))
        self.assertEqual(code, 0)
        self.assertFalse((self.root / "ios/review_notes.txt").exists())
        self.assertIn("skipped ios/review_notes.txt", out)
        self.assertNotIn("example.org", out)

    def test_uneditable_version_is_skipped(self):
        client = FakeClient(state="READY_FOR_SALE")
        self.pull(client)
        self.assertFalse((self.root / "ios").exists())

    def test_scrub_masks_identifiers(self):
        text = am.scrub("no resource with id '1234567890' or 00000000-1111-2222-3333-444444444444")
        self.assertNotIn("1234567890", text)
        self.assertNotIn("444444444444", text)

    def test_committed_metadata_passes_check(self):
        self.assertEqual(am.check(), [])


if __name__ == "__main__":
    unittest.main()
