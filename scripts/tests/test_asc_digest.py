import contextlib
import datetime as dt
import io
import json
import pathlib
import stat
import tempfile
import unittest
from _script_loader import load_script

ROOT = pathlib.Path(__file__).resolve().parents[2]
digest_mod = load_script("asc_digest", ROOT / "scripts/asc-digest.py")
tf = digest_mod.tf

FAKE_APP = "1234567890"
FAKE_ISSUER = "00000000-1111-2222-3333-444444444444"
NOW = dt.datetime(2026, 10, 15, 12, 0, tzinfo=dt.timezone.utc)
DAY = digest_mod.day_name(NOW)


def review(rid, created, rating=5, title="Great", body="Works well", nickname="viewer"):
    return {"type": "customerReviews", "id": rid, "attributes": {
        "rating": rating, "title": title, "body": body, "reviewerNickname": nickname,
        "createdDate": created, "territory": "USA"}}


def build_item(bid, number, pre_id, uploaded):
    return {"type": "builds", "id": bid, "attributes": {"version": number, "uploadedDate": uploaded,
                                                        "processingState": "VALID"},
            "relationships": {"preReleaseVersion": {"data": {"type": "preReleaseVersions", "id": pre_id}}}}


def pre_item(pre_id, version, platform):
    return {"type": "preReleaseVersions", "id": pre_id, "attributes": {"version": version, "platform": platform}}


def feedback_item(fid, created, comment, build_id="b-vision-2", screenshots=None):
    attrs = {"createdDate": created, "comment": comment, "email": "tester@example.com",
             "deviceModel": "RealityDevice14,1", "osVersion": "26.0", "appPlatform": "VISION_OS"}
    if screenshots is not None:
        attrs["screenshots"] = screenshots
    return {"type": "betaFeedbackCrashSubmissions", "id": fid, "attributes": attrs,
            "relationships": {"build": {"data": {"type": "builds", "id": build_id}}}}


class FakeClient:
    """Records every call and serves canned JSON keyed by path."""

    def __init__(self, routes, errors=None):
        self.app_id = FAKE_APP
        self.routes = routes
        self.errors = errors or {}
        self.calls = []

    def request(self, method, path, params=None, body=None):
        self.calls.append((method, path, params, body))
        base = path.split("?", 1)[0]
        if base in self.errors:
            code = self.errors[base]
            raise tf.APIError(f"App Store Connect API {method} {path} -> HTTP {code}: "
                              f"The resource '{FAKE_APP}' with issuer {FAKE_ISSUER} was not found", code)
        if path in self.routes:
            return self.routes[path]
        if base in self.routes:
            return self.routes[base]
        return {"data": []}


def standard_routes():
    app = f"/v1/apps/{FAKE_APP}"
    return {
        "/v1/builds": {
            "data": [
                build_item("b-vision-2", "1490", "p-vision", "2026-10-14T10:00:00Z"),
                build_item("b-vision-1", "1480", "p-vision-old", "2026-10-01T10:00:00Z"),
                build_item("b-ios-2", "1490", "p-ios", "2026-10-14T09:00:00Z"),
            ],
            "included": [pre_item("p-vision", "1.7.2", "VISION_OS"), pre_item("p-vision-old", "1.7.1", "VISION_OS"),
                         pre_item("p-ios", "1.7.2", "IOS")],
        },
        f"{app}/customerReviews": {
            "data": [
                review("r-new", "2026-10-15T08:00:00-07:00", rating=4),
                review("r-recent", "2026-10-14T20:00:00Z", rating=5),
                review("r-old", "2026-10-01T00:00:00Z", rating=1),
            ],
            "links": {"next": f"{tf.API_ROOT}{app}/customerReviews?cursor=SHOULDNOTFOLLOW"},
        },
        f"{app}/appStoreVersions": {"data": [
            {"type": "appStoreVersions", "id": "v-vision", "attributes": {"versionString": "1.7.2", "platform": "VISION_OS"}},
            {"type": "appStoreVersions", "id": "v-ios", "attributes": {"versionString": "1.7.2", "platform": "IOS"}},
        ]},
        "/v1/appStoreVersions/v-vision/customerReviews": {"data": [
            {"type": "customerReviews", "id": "r-new", "attributes": {"createdDate": "2026-10-15T08:00:00-07:00"}}]},
        "/v1/appStoreVersions/v-ios/customerReviews": {"data": [
            {"type": "customerReviews", "id": "r-recent", "attributes": {"createdDate": "2026-10-14T20:00:00Z"}}]},
        "/v1/builds/b-vision-2/diagnosticSignatures": {"data": [
            {"type": "diagnosticSignatures", "id": "s-1", "attributes": {
                "diagnosticType": "HANGS", "signature": "PlayerView.body", "weight": 12.5}},
            {"type": "diagnosticSignatures", "id": "s-2", "attributes": {
                "diagnosticType": "HANGS", "signature": "Library.load", "weight": 40.0}},
        ]},
        f"{app}/betaFeedbackCrashSubmissions": {
            "data": [feedback_item("f-1", "2026-10-15T01:00:00Z", "Crashed on seek")],
            "included": [{"type": "builds", "id": "b-vision-2", "attributes": {"version": "1490"}}],
        },
        f"{app}/betaFeedbackScreenshotSubmissions": {"data": [
            feedback_item("f-2", "2026-10-15T02:00:00Z", "Button clipped", screenshots=[{"url": "https://example.invalid/s.png"}])]},
    }


class DigestRun(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.tmp.name) / "artifacts" / "asc-digest"

    def tearDown(self):
        self.tmp.cleanup()

    def run_digest(self, client, *argv, now=NOW):
        factory = lambda: contextlib.nullcontext(client)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = digest_mod.main(list(argv), client_factory=factory, now=now, out_root=self.root)
        self.assertEqual(code, 0)
        return out.getvalue()

    def read_json(self, stem="digest"):
        return json.loads((self.root / DAY / f"{stem}.json").read_text())

    def test_only_get_requests_without_bodies(self):
        client = FakeClient(standard_routes())
        self.run_digest(client, "--since", "30d", "--logs")
        self.assertTrue(client.calls)
        self.assertTrue(all(method == "GET" and body is None for method, _, _, body in client.calls))

    def test_read_only_wrapper_refuses_writes(self):
        wrapper = digest_mod.ReadOnlyClient(FakeClient({}), FAKE_APP)
        for method in ("POST", "PATCH", "DELETE"):
            with self.assertRaises(RuntimeError):
                wrapper.request(method, "/v1/betaGroups/x/relationships/builds", body={"data": []})
        with self.assertRaises(RuntimeError):
            wrapper.request("GET", "/v1/builds", body={"data": []})

    def test_parses_reviews_diagnostics_and_feedback(self):
        out = self.run_digest(FakeClient(standard_routes()), "--since", "1d")
        data = self.read_json()
        self.assertEqual([r["id"] for r in data["reviews"]], ["r-new", "r-recent"])
        self.assertEqual({r["id"]: r["platform"] for r in data["reviews"]}, {"r-new": "VISION_OS", "r-recent": "IOS"})
        self.assertEqual(data["reviews"][0]["nickname"], "viewer")
        vision = [d for d in data["diagnostics"] if d["platform"] == "VISION_OS"]
        self.assertEqual([d["build"] for d in vision], ["1.7.2 (1490)"])  # current marketing version only
        self.assertEqual([s["signature"] for s in vision[0]["signatures"]], ["Library.load", "PlayerView.body"])
        self.assertEqual({f["kind"] for f in data["feedback"]}, {"crash", "screenshot"})
        self.assertEqual(data["feedback"][0]["build"], "1.7.2 (1490)")
        self.assertIn("2 new reviews (avg 4.5)", out)
        self.assertIn("VISION_OS 1.7.2 (1490): 2 hangs (2 new)", out)
        self.assertIn("2 TestFlight feedback (1 crash, 1 screenshot)", out)
        # Stdout is counts only: no review/tester text or personal data.
        for private in ("Works well", "viewer", "Crashed on seek", "tester@example.com", "Library.load"):
            self.assertNotIn(private, out)
        md = (self.root / DAY / "digest.md").read_text()
        self.assertIn("Crashed on seek", md)
        self.assertIn("rerun with --attachments", md)

    def test_stops_paging_once_older_than_window(self):
        client = FakeClient(standard_routes())
        self.run_digest(client, "--since", "1d")
        self.assertFalse(any("SHOULDNOTFOLLOW" in path for _, path, _, _ in client.calls))

    def test_state_file_hides_already_seen_items(self):
        routes = standard_routes()
        self.run_digest(FakeClient(routes), "--since", "1d")
        later = NOW + dt.timedelta(hours=1)
        out = self.run_digest(FakeClient(routes), "--since", "1d", now=later)
        self.assertIn("0 new reviews", out)
        self.assertIn("0 TestFlight feedback", out)
        self.assertIn("2 hangs", out)
        self.assertNotIn("new)", out)
        # A second run the same day does not overwrite the first digest.
        files = sorted(p.name for p in (self.root / DAY).glob("digest*.md"))
        self.assertEqual(len(files), 2)
        out = self.run_digest(FakeClient(routes), "--since", "1d", "--all", now=later + dt.timedelta(minutes=1))
        self.assertIn("2 new reviews", out)

    def test_since_parsing(self):
        self.assertEqual(digest_mod.parse_since("30d", NOW), NOW - dt.timedelta(days=30))
        self.assertEqual(digest_mod.parse_since("6h", NOW), NOW - dt.timedelta(hours=6))
        self.assertEqual(digest_mod.parse_since("2026-10-01", NOW), dt.datetime(2026, 10, 1, tzinfo=dt.timezone.utc))
        self.assertEqual(digest_mod.parse_since("2026-10-01T05:00:00Z", NOW),
                         dt.datetime(2026, 10, 1, 5, tzinfo=dt.timezone.utc))

    def test_unavailable_endpoints_are_recorded_and_ids_redacted(self):
        app = f"/v1/apps/{FAKE_APP}"
        client = FakeClient(standard_routes(), errors={
            f"{app}/customerReviews": 404, f"{app}/betaFeedbackScreenshotSubmissions": 403,
            "/v1/builds/b-vision-2/diagnosticSignatures": 500,
        })
        out = self.run_digest(client, "--since", "1d")
        self.assertIn("customerReviews (unavailable HTTP 404)", out)
        self.assertIn("betaFeedbackScreenshotSubmissions (unavailable HTTP 403)", out)
        self.assertIn("(error HTTP 500)", out)
        day = self.root / DAY
        for text in (out, (day / "digest.md").read_text(), (day / "digest.json").read_text()):
            self.assertNotIn(FAKE_APP, text)
            self.assertNotIn(FAKE_ISSUER, text)
        self.assertEqual(self.read_json()["reviews"], [])

    def test_build_without_diagnostic_data_is_not_an_unavailable_endpoint(self):
        client = FakeClient(standard_routes(), errors={"/v1/builds/b-vision-2/diagnosticSignatures": 404})
        out = self.run_digest(client, "--since", "1d")
        self.assertIn("VISION_OS 1.7.2 (1490): no diagnostic data yet", out)
        self.assertNotIn("unavailable", out)

    def test_scrub_strips_ids(self):
        text = digest_mod.scrub(f"GET /v1/apps/{FAKE_APP}/x issuer {FAKE_ISSUER} build 1490")
        self.assertNotIn(FAKE_APP, text)
        self.assertNotIn(FAKE_ISSUER, text)
        self.assertIn("build 1490", text)

    def test_outputs_are_private_and_under_artifacts(self):
        out = self.run_digest(FakeClient(standard_routes()), "--since", "1d", "--logs")
        day = self.root / DAY
        self.assertEqual(day.parent.name, "asc-digest")
        self.assertEqual(day.parent.parent.name, "artifacts")
        for path in (day / "digest.md", day / "digest.json", self.root / "state.json"):
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600, path)
        self.assertTrue((day / "logs" / "diagnostic-s-1.json").exists())
        self.assertIn(f"digest: {day / 'digest.md'}", out)
        self.assertEqual(digest_mod.OUT_ROOT, ROOT / "artifacts" / "asc-digest")

    def test_artifacts_directory_is_gitignored(self):
        self.assertIn("artifacts/asc-digest/", (ROOT / ".gitignore").read_text().splitlines())

    def test_credential_failure_is_redacted_and_nonzero(self):
        @contextlib.contextmanager
        def failing():
            raise tf.ReleaseError(f"could not read key for app {FAKE_APP}")
            yield  # pragma: no cover

        err = io.StringIO()
        with contextlib.redirect_stderr(err), contextlib.redirect_stdout(io.StringIO()):
            code = digest_mod.main([], client_factory=failing, now=NOW, out_root=self.root)
        self.assertEqual(code, 1)
        self.assertNotIn(FAKE_APP, err.getvalue())


if __name__ == "__main__":
    unittest.main()
