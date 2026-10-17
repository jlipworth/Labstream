import base64
import contextlib
import datetime as dt
import io
import json
import os
import pathlib
import plistlib
import shutil
import stat
import subprocess
import tempfile
import unittest
from unittest import mock
from _script_loader import load_script

ROOT = pathlib.Path(__file__).resolve().parents[2]
tf = load_script("testflight_release", ROOT / "scripts/testflight-release.py")

FAKE_KEY_ID = "KEYID12345"
FAKE_ISSUER = "00000000-1111-2222-3333-444444444444"
FAKE_APP = "1234567890"
# Structurally valid PEM framing for tests that never sign with it.
DUMMY_PEM = "-----BEGIN PRIVATE KEY-----\nMIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQg\n-----END PRIVATE KEY-----\n"


def generate_pem() -> str:
    return subprocess.run(
        ["openssl", "genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256"],
        check=True, capture_output=True, text=True,
    ).stdout


def b64url_decode(value: str) -> bytes:
    return base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))


def raw_to_der(raw: bytes) -> bytes:
    def integer(part: bytes) -> bytes:
        part = part.lstrip(b"\x00") or b"\x00"
        if part[0] & 0x80:
            part = b"\x00" + part
        return b"\x02" + bytes([len(part)]) + part

    body = integer(raw[:32]) + integer(raw[32:])
    return b"\x30" + bytes([len(body)]) + body


class CredentialTests(unittest.TestCase):
    def setUp(self):
        self.pem = DUMMY_PEM
        self.creds = tf.Credentials(FAKE_KEY_ID, FAKE_ISSUER, FAKE_APP, self.pem)

    @unittest.skipUnless(shutil.which("openssl"), "openssl is not installed (Linux hygiene image)")
    def test_jwt_is_es256_and_verifies_with_openssl(self):
        self.pem = generate_pem()
        self.creds = tf.Credentials(FAKE_KEY_ID, FAKE_ISSUER, FAKE_APP, self.pem)
        with tf.private_key_file(self.creds) as key_path:
            token = tf.make_jwt(self.creds, key_path, now=1_700_000_000)
            header_b64, payload_b64, signature_b64 = token.split(".")
            header = json.loads(b64url_decode(header_b64))
            payload = json.loads(b64url_decode(payload_b64))
            self.assertEqual(header, {"alg": "ES256", "kid": FAKE_KEY_ID, "typ": "JWT"})
            self.assertEqual(payload["iss"], FAKE_ISSUER)
            self.assertEqual(payload["aud"], "appstoreconnect-v1")
            self.assertEqual(payload["exp"] - payload["iat"], 900)
            raw = b64url_decode(signature_b64)
            self.assertEqual(len(raw), 64)
            with tempfile.TemporaryDirectory() as tmp:
                pub = pathlib.Path(tmp) / "pub.pem"
                sig = pathlib.Path(tmp) / "sig.der"
                subprocess.run(["openssl", "pkey", "-in", str(key_path), "-pubout", "-out", str(pub)], check=True)
                sig.write_bytes(raw_to_der(raw))
                verified = subprocess.run(
                    ["openssl", "dgst", "-sha256", "-verify", str(pub), "-signature", str(sig)],
                    input=f"{header_b64}.{payload_b64}".encode(), capture_output=True,
                )
                self.assertEqual(verified.returncode, 0, verified.stdout + verified.stderr)

    def test_private_key_file_is_owner_only_and_removed(self):
        with tf.private_key_file(self.creds) as key_path:
            self.assertEqual(stat.S_IMODE(key_path.stat().st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(key_path.parent.stat().st_mode), 0o700)
            self.assertEqual(key_path.read_text(), self.pem.strip() + "\n")
            saved = key_path
        self.assertFalse(saved.exists())
        self.assertFalse(saved.parent.exists())

    def test_private_key_file_removed_on_error(self):
        with self.assertRaises(RuntimeError):
            with tf.private_key_file(self.creds) as key_path:
                saved = key_path
                raise RuntimeError("boom")
        self.assertFalse(saved.parent.exists())

    def test_parse_op_item_reads_fields_and_escaped_notes(self):
        escaped = self.pem.replace("\n", "\\n")
        item = {"fields": [
            {"label": "key_id", "value": FAKE_KEY_ID},
            {"label": "issuer_id", "value": FAKE_ISSUER},
            {"label": "app_id", "value": FAKE_APP},
            {"label": "notesPlain", "value": f"App Store Connect key\n{escaped}\nrotate yearly"},
        ]}
        creds = tf.parse_op_item(item)
        self.assertEqual((creds.key_id, creds.issuer_id, creds.app_id), (FAKE_KEY_ID, FAKE_ISSUER, FAKE_APP))
        self.assertEqual(creds.private_key_pem, self.pem.strip() + "\n")
        self.assertNotIn(self.pem.strip(), repr(creds))

    def test_parse_op_item_requires_ids(self):
        with self.assertRaisesRegex(tf.ReleaseError, "issuer_id, app_id"):
            tf.parse_op_item({"fields": [{"label": "key_id", "value": FAKE_KEY_ID},
                                         {"label": "notesPlain", "value": self.pem}]})

    def test_op_environment_reads_keychain_token_only_when_configured(self):
        with mock.patch.dict(os.environ, {"USER": "tester"}, clear=True):
            with mock.patch.object(tf.subprocess, "run") as run:
                self.assertNotIn("OP_SERVICE_ACCOUNT_TOKEN", tf.op_environment({}))
                run.assert_not_called()
                run.return_value = subprocess.CompletedProcess([], 0, stdout="ops_token\n", stderr="")
                env = tf.op_environment({"LABSTREAM_OP_SA_KEYCHAIN_SERVICE": "svc"})
                self.assertEqual(env["OP_SERVICE_ACCOUNT_TOKEN"], "ops_token")
                self.assertNotIn("OP_SERVICE_ACCOUNT_TOKEN", os.environ)
                run.return_value = subprocess.CompletedProcess([], 44, stdout="", stderr="")
                with self.assertRaisesRegex(tf.ReleaseError, "Keychain"):
                    tf.op_environment({"LABSTREAM_OP_SA_KEYCHAIN_SERVICE": "svc"})


class RedactionTests(unittest.TestCase):
    def test_redactor_masks_registered_identifiers(self):
        redactor = tf.Redactor()
        redactor.add(FAKE_KEY_ID, FAKE_ISSUER, "ab")
        text = redactor(f"key {FAKE_KEY_ID} issuer {FAKE_ISSUER} ab")
        self.assertNotIn(FAKE_KEY_ID, text)
        self.assertNotIn(FAKE_ISSUER, text)
        self.assertIn("KE…45", text)
        redactor.verbose = True
        self.assertIn(FAKE_KEY_ID, redactor(FAKE_KEY_ID))

    def test_export_options_upload_without_credentials(self):
        profile = tf.Profile("P", "UUID-1", "TEAM123456", frozenset({"tvOS"}),
                             dt.datetime(2030, 1, 1, tzinfo=dt.timezone.utc), ["AB" * 20], pathlib.Path("p"))
        plan = tf.Plan(tf.PLATFORMS["tvos"], "1.0", "3", profile, "AB" * 20)
        options = tf.export_options(plan)
        self.assertEqual(options["method"], "app-store-connect")
        self.assertEqual(options["destination"], "upload")
        self.assertEqual(options["provisioningProfiles"], {tf.BUNDLE_ID: "UUID-1"})
        self.assertFalse(options["manageAppVersionAndBuildNumber"])
        self.assertFalse(any("key" in name.lower() or "issuer" in name.lower() for name in options))


class MacAndSourceTests(unittest.TestCase):
    def test_mac_export_names_installer_identity(self):
        profile = tf.Profile("P", "UUID-1", "TEAM123456", frozenset({"OSX"}),
                             dt.datetime(2030, 1, 1, tzinfo=dt.timezone.utc), ["AB" * 20], pathlib.Path("p"))
        plan = tf.Plan(tf.PLATFORMS["macos"], "1.0", "3", profile, "AB" * 20, "CD" * 20)
        self.assertEqual(tf.export_options(plan)["installerSigningCertificate"], "CD" * 20)
        ios = tf.Plan(tf.PLATFORMS["ios"], "1.0", "3", profile, "AB" * 20)
        self.assertNotIn("installerSigningCertificate", tf.export_options(ios))

    def test_installer_identity_matches_team(self):
        listing = (
            '  1) ' + 'A1' * 20 + ' "Apple Distribution: Someone (TEAM123456)"\n'
            '  2) ' + 'b2' * 20 + ' "3rd Party Mac Developer Installer: Someone (OTHERTEAM1)"\n'
            '  3) ' + 'c3' * 20 + ' "3rd Party Mac Developer Installer: Someone (TEAM123456)"\n'
        )
        self.assertEqual(tf.installer_identity("TEAM123456", listing), "C3" * 20)
        with self.assertRaisesRegex(tf.ReleaseError, "installer"):
            tf.installer_identity("MISSING000", listing)

    def test_slug_problems(self):
        archive = pathlib.Path("LabstreamTV-1.0-b5-abcdef12.xcarchive")
        published = subprocess.CompletedProcess([], 0)
        unpublished = subprocess.CompletedProcess([], 1)
        with mock.patch.object(tf, "run", return_value=published):
            self.assertEqual(tf.slug_problems("1490-abcdef123456-clean", archive, False), [])
            self.assertIn("uncommitted", " ".join(tf.slug_problems("1490-abcdef123456-dirty", archive, False)))
            self.assertIn("does not match", " ".join(tf.slug_problems("1490-123456abcdef-clean", archive, False)))
            self.assertTrue(tf.slug_problems("dev", archive, False))
        with mock.patch.object(tf, "run", return_value=unpublished):
            self.assertIn("origin/main", " ".join(tf.slug_problems("1490-abcdef123456-clean", archive, False)))
            self.assertEqual(tf.slug_problems("1490-abcdef123456-clean", archive, True), [])


class ProfileSelectionTests(unittest.TestCase):
    NOW = dt.datetime(2026, 10, 15, tzinfo=dt.timezone.utc)

    def profile(self, name, platforms, days, cert="AA", managed=False):
        return tf.Profile(name, name, "TEAM", frozenset(platforms), self.NOW + dt.timedelta(days=days),
                          [cert * 20], pathlib.Path(name), managed)

    def test_prefers_named_profile_over_xcode_managed_and_skips_unusable(self):
        profiles = [
            self.profile("managed", {"iOS", "xrOS"}, 400, managed=True),
            self.profile("named", {"iOS", "xrOS", "visionOS"}, 300),
            self.profile("expired", {"iOS"}, -1),
            self.profile("other-cert", {"iOS"}, 500, cert="BB"),
            self.profile("tv", {"tvOS"}, 300),
        ]
        identities = {"AA" * 20}
        chosen, identity = tf.choose_profile(profiles, tf.PLATFORMS["visionos"], identities, self.NOW)
        self.assertEqual((chosen.name, identity), ("named", "AA" * 20))
        self.assertEqual(tf.choose_profile(profiles, tf.PLATFORMS["tvos"], identities, self.NOW)[0].name, "tv")
        with self.assertRaisesRegex(tf.ReleaseError, "macos"):
            tf.choose_profile(profiles, tf.PLATFORMS["macos"], identities, self.NOW)


class FakeClient:
    def __init__(self, attached):
        self.attached = attached
        self.patched = []

    def builds(self, version, build, platform):
        return [{"id": f"build-{platform.key}", "processingState": "VALID", "beta": {}}]

    def beta_groups(self, build_id):
        return ["Internal"]

    def app_store_version(self, version, platform):
        return {"id": f"asv-{platform.key}", "build_id": self.attached.get(platform.key)}

    def build_label(self, build_id):
        return "1.0 (1)"

    def select_build(self, version_id, build_id):
        self.patched.append((version_id, build_id))

    def group_id(self, name):
        return f"group-{name}"

    def add_to_group(self, group_id, build_id):
        self.patched.append((group_id, build_id))


class CommandGuardTests(unittest.TestCase):
    def run_main(self, argv):
        err, out = io.StringIO(), io.StringIO()
        with contextlib.redirect_stderr(err), contextlib.redirect_stdout(out):
            code = tf.main(argv)
        return code, out.getvalue(), err.getvalue()

    def test_upload_requires_explicit_yes_before_any_work(self):
        with mock.patch.object(tf, "source_state", side_effect=AssertionError("must not run")):
            code, _, err = self.run_main(["upload"])
        self.assertEqual(code, 1)
        self.assertIn("--yes", err)

    def test_select_build_dry_run_does_not_patch(self):
        client = FakeClient({"ios": "build-ios", "tvos": "old-build"})

        @contextlib.contextmanager
        def fake_client(_creds):
            yield client

        creds = tf.Credentials(FAKE_KEY_ID, FAKE_ISSUER, FAKE_APP, "pem")
        with mock.patch.object(tf, "load_credentials", return_value=creds), \
                mock.patch.object(tf, "asc_client", fake_client):
            code, out, _ = self.run_main(["select-build", "--version", "1.0", "--build-number", "2"])
            self.assertEqual(code, 0)
            self.assertEqual(client.patched, [])
            self.assertIn("would attach the build for: visionos, tvos, macos", out)
            code, out, _ = self.run_main(["select-build", "--version", "1.0", "--build-number", "2", "--yes"])
            self.assertEqual(code, 0)
            self.assertEqual([v for v, _ in client.patched], ["asv-visionos", "asv-tvos", "asv-macos"])
            self.assertIn("nothing was submitted for review", out)

    def fake_asc(self, client):
        @contextlib.contextmanager
        def fake_client(_creds):
            yield client

        creds = tf.Credentials(FAKE_KEY_ID, FAKE_ISSUER, FAKE_APP, "pem")
        return mock.patch.object(tf, "load_credentials", return_value=creds), mock.patch.object(tf, "asc_client", fake_client)

    def test_distribute_dry_run_then_adds_only_missing_builds(self):
        client = FakeClient({})
        creds_patch, client_patch = self.fake_asc(client)
        with creds_patch, client_patch:
            argv = ["distribute", "--version", "1.0", "--build-number", "5", "--group", "Other"]
            code, out, _ = self.run_main(argv)
            self.assertEqual((code, client.patched), (0, []))
            self.assertIn("would add to 'Other': visionos, ios, tvos, macos", out)
            code, out, _ = self.run_main(argv + ["--yes"])
            self.assertEqual(code, 0)
            self.assertEqual({g for g, _ in client.patched}, {"group-Other"})
            self.assertEqual(len(client.patched), 4)
            client.patched.clear()
            code, out, _ = self.run_main(["distribute", "--version", "1.0", "--build-number", "5", "--group", "Internal", "--yes"])
            self.assertEqual((code, client.patched), (0, []))
            self.assertIn("already in 'Internal'", out)

    def test_ship_requires_yes_and_group_before_archiving(self):
        with mock.patch.object(tf, "cmd_archive", side_effect=AssertionError("must not archive")), \
                mock.patch.dict(os.environ, {}, clear=False), \
                mock.patch.object(tf, "read_local_env", return_value={}):
            os.environ.pop("LABSTREAM_TESTFLIGHT_GROUP", None)
            code, _, err = self.run_main(["ship", "--group", "Internal"])
            self.assertEqual(code, 1)
            self.assertIn("--yes", err)
            code, _, err = self.run_main(["ship", "--yes"])
            self.assertEqual(code, 1)
            self.assertIn("--group", err)

    def test_ship_runs_steps_in_order_with_auto_build_number(self):
        calls = []
        def step(name):
            def record(args):
                calls.append((name, args.build_number))
                return 0
            return record
        def prune(args):
            calls.append(("prune", args.keep, args.yes))
            return 0
        with mock.patch.multiple(tf, cmd_archive=step("archive"), cmd_upload=step("upload"),
                                 cmd_status=step("status"), cmd_distribute=step("distribute"),
                                 cmd_prune_archives=prune):
            code, out, _ = self.run_main(["ship", "--group", "Internal", "--yes"])
        self.assertEqual(code, 0)
        self.assertEqual(calls, [("archive", "auto"), ("upload", "auto"), ("status", "auto"),
                                 ("distribute", "auto"), ("prune", 3, True)])
        self.assertIn("nothing was submitted for review", out)

    def test_build_number_resolution(self):
        args = mock.Mock(build_number="auto")
        with mock.patch.object(tf, "run", return_value=subprocess.CompletedProcess([], 0, stdout="1500\n", stderr="")):
            self.assertEqual(tf.build_number(args), "1500")
        self.assertIsNone(tf.build_number(mock.Mock(build_number=None)))
        self.assertEqual(tf.build_number(mock.Mock(build_number="42")), "42")
        with self.assertRaises(tf.ReleaseError):
            tf.build_number(mock.Mock(build_number="1.2"))

    def test_no_review_submission_surface(self):
        source = (ROOT / "scripts/testflight-release.py").read_text()
        self.assertNotIn("reviewSubmissions", source)
        self.assertNotIn("appStoreVersionSubmissions", source)


class ArchivePruneTests(unittest.TestCase):
    T0 = dt.datetime(2026, 10, 1, tzinfo=dt.timezone.utc)

    def entry(self, build, day, version="1.7.2"):
        return tf.ArchiveSet(version, str(build), self.T0 + dt.timedelta(days=day), [pathlib.Path(f"b{build}")])

    def test_keeps_newest_uploaded_attached_and_pending_sets(self):
        sets = [self.entry(b, d) for b, d in [(1500, 9), (1499, 8), (1498, 7), (1497, 6), (1496, 5), (2, 4), (1, 3)]]
        sets.sort(key=lambda s: s.created, reverse=True)
        uploaded = {("1.7.2", b) for b in ("1499", "1498", "1497", "1496", "2")}
        attached = {("1.7.2", "2")}
        kept, removed = tf.plan_prune(sets, uploaded, attached, keep=3)
        self.assertEqual([k.build for k in kept], ["1500", "1499", "1498", "1497", "2"])
        self.assertEqual([r.build for r in removed], ["1496", "1"])

    def test_nothing_uploaded_keeps_everything(self):
        sets = [self.entry(2, 2), self.entry(1, 1)]
        kept, removed = tf.plan_prune(sets, set(), set())
        self.assertEqual((len(kept), removed), (2, []))

    def test_archive_sets_group_by_version_and_build(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            def make(day, name, scheme, build, bundle=tf.BUNDLE_ID, hour=0):
                path = root / day / f"{name}.xcarchive"
                path.mkdir(parents=True)
                (path / "Info.plist").write_bytes(plistlib.dumps({
                    "SchemeName": scheme,
                    "CreationDate": dt.datetime(2026, 10, int(day[-2:]), hour),
                    "ApplicationProperties": {"CFBundleShortVersionString": "1.7.2", "CFBundleVersion": build,
                                              "CFBundleIdentifier": bundle},
                }))
            make("2026-10-04", "a", "Labstream", "1")
            make("2026-10-04", "b", "LabstreamTV", "1", hour=3)
            make("2026-10-13", "c", "LabstreamMac", "2")
            make("2026-10-13", "d", "OtherApp", "2")
            make("2026-10-13", "e", "Labstream", "2", bundle="org.example.other")
            sets = tf.archive_sets(root)
            self.assertEqual([(s.build, len(s.paths)) for s in sets], [("2", 1), ("1", 2)])
            self.assertEqual(sets[1].created.hour, 3)


if __name__ == "__main__":
    unittest.main()
