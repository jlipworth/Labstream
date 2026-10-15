import base64
import contextlib
import datetime as dt
import importlib.util
import io
import json
import os
import pathlib
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("testflight_release", ROOT / "scripts/testflight-release.py")
tf = importlib.util.module_from_spec(spec)
sys.modules["testflight_release"] = tf
spec.loader.exec_module(tf)

FAKE_KEY_ID = "KEYID12345"
FAKE_ISSUER = "00000000-1111-2222-3333-444444444444"
FAKE_APP = "1234567890"


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
        self.pem = generate_pem()
        self.creds = tf.Credentials(FAKE_KEY_ID, FAKE_ISSUER, FAKE_APP, self.pem)

    def test_jwt_is_es256_and_verifies_with_openssl(self):
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
            code, out, _ = self.run_main(["select-build", "--version", "1.0", "--build", "2"])
            self.assertEqual(code, 0)
            self.assertEqual(client.patched, [])
            self.assertIn("would attach the build for: visionos, tvos, macos", out)
            code, out, _ = self.run_main(["select-build", "--version", "1.0", "--build", "2", "--yes"])
            self.assertEqual(code, 0)
            self.assertEqual([v for v, _ in client.patched], ["asv-visionos", "asv-tvos", "asv-macos"])
            self.assertIn("nothing was submitted for review", out)

    def test_no_review_submission_surface(self):
        source = (ROOT / "scripts/testflight-release.py").read_text()
        self.assertNotIn("reviewSubmissions", source)
        self.assertNotIn("appStoreVersionSubmissions", source)


if __name__ == "__main__":
    unittest.main()
