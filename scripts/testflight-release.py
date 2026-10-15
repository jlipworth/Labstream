#!/usr/bin/env python3
"""Archive, validate, upload, and select coordinated Labstream TestFlight builds.

Subcommands (run in this order; each is safe to rerun):

  preflight      clean public source, version/build per scheme, App Store profiles,
                 Apple Distribution identity, and (with credentials) that the
                 version/build has not already been uploaded.
  archive        preflight, then one manual-distribution-signed Release archive per
                 platform into Xcode's Organizer archive folder.
  validate       inspect the archives: identity, version/build, clean source slug,
                 signature, profile, entitlements, and privacy manifests.
  upload --yes   upload validated archives to App Store Connect with the API key.
  status         read-only processing, TestFlight group, and version-selection state.
  select-build   show which platform versions would change; --yes attaches the build.

App Review submission is intentionally not implemented.

The App Store Connect API key is read from 1Password at run time. Set
LABSTREAM_ASC_OP_ITEM (an op://<vault>/<item> reference to an item with key_id,
issuer_id, app_id fields and the PEM private key in its notes) in the environment
or in the gitignored scripts/asc.local.env. Alternatively set LABSTREAM_ASC_KEY_ID,
LABSTREAM_ASC_ISSUER_ID, LABSTREAM_ASC_APP_ID, and LABSTREAM_ASC_KEY_PATH. Set
LABSTREAM_OP_SA_KEYCHAIN_SERVICE to read a read-only 1Password service account token
from the login Keychain so unattended runs do not trigger 1Password prompts. The key
is written only to a private temporary file that is removed when the command exits.
Account identifiers are masked in output; pass --verbose to show them.
"""
from __future__ import annotations

import argparse
import base64
import contextlib
import datetime as dt
import importlib.util
import json
import os
import pathlib
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from typing import Any, Callable, Generator

REPO = pathlib.Path(__file__).resolve().parents[1]
BUNDLE_ID = "org.labstream.Labstream"
PROJECT = "Labstream.xcodeproj"
LOCAL_ENV = REPO / "scripts" / "asc.local.env"
ARCHIVES_ROOT = pathlib.Path.home() / "Library/Developer/Xcode/Archives"
DERIVED_DATA = REPO / "build" / "DerivedData-archive"
PROFILE_DIRS = [
    pathlib.Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles",
    pathlib.Path.home() / "Library/MobileDevice/Provisioning Profiles",
]
API_ROOT = "https://api.appstoreconnect.apple.com"
PROFILE_EXPIRY_WARN_DAYS = 30


@dataclass(frozen=True)
class Platform:
    key: str
    scheme: str
    destination: str
    profile_platforms: frozenset[str]
    asc_platform: str
    macos: bool = False


PLATFORMS: dict[str, Platform] = {
    p.key: p
    for p in (
        Platform("visionos", "Labstream", "generic/platform=visionOS", frozenset({"xrOS", "visionOS"}), "VISION_OS"),
        Platform("ios", "LabstreamMobile", "generic/platform=iOS", frozenset({"iOS"}), "IOS"),
        Platform("tvos", "LabstreamTV", "generic/platform=tvOS", frozenset({"tvOS"}), "TV_OS"),
        Platform("macos", "LabstreamMac", "generic/platform=macOS", frozenset({"OSX"}), "MAC_OS", macos=True),
    )
}


class ReleaseError(RuntimeError):
    pass


# --- Output and redaction ------------------------------------------------------


class Redactor:
    """Masks account identifiers in anything this script prints."""

    def __init__(self, verbose: bool = False) -> None:
        self.verbose = verbose
        self.secrets: set[str] = set()

    def add(self, *values: str) -> None:
        for value in values:
            if value and len(value) >= 4:
                self.secrets.add(value)

    @staticmethod
    def mask(value: str) -> str:
        return value if len(value) <= 4 else f"{value[:2]}…{value[-2:]}"

    def __call__(self, text: str) -> str:
        if self.verbose:
            return text
        for secret in sorted(self.secrets, key=len, reverse=True):
            text = text.replace(secret, self.mask(secret))
        return text


REDACT = Redactor()


def say(message: str = "") -> None:
    print(REDACT(message), flush=True)


def warn(message: str) -> None:
    print(REDACT(f"warning: {message}"), file=sys.stderr, flush=True)


def run(cmd: list[str], *, cwd: pathlib.Path = REPO, check: bool = True, **kw: Any) -> subprocess.CompletedProcess:
    result = subprocess.run(cmd, cwd=cwd, text=True, capture_output=True, **kw)
    if check and result.returncode != 0:
        tail = "\n".join((result.stdout + result.stderr).strip().splitlines()[-40:])
        raise ReleaseError(f"{cmd[0]} failed ({result.returncode}):\n{tail}")
    return result


# --- Credentials ---------------------------------------------------------------


@dataclass
class Credentials:
    key_id: str
    issuer_id: str
    app_id: str
    private_key_pem: str = field(repr=False)


def read_local_env(path: pathlib.Path = LOCAL_ENV) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.is_file():
        return values
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip().strip("'\"")
    return values


def setting(name: str, local: dict[str, str]) -> str:
    return os.environ.get(name) or local.get(name, "")


def extract_pem(text: str) -> str:
    match = re.search(r"-----BEGIN PRIVATE KEY-----.*?-----END PRIVATE KEY-----", text.replace("\\n", "\n"), re.S)
    if not match:
        raise ReleaseError("App Store Connect private key not found (expected a PEM PRIVATE KEY block)")
    lines = [line.strip() for line in match.group(0).splitlines() if line.strip()]
    return "\n".join(lines) + "\n"


def parse_op_item(item: dict[str, Any]) -> Credentials:
    fields = {f.get("label"): f.get("value") or "" for f in item.get("fields", [])}
    missing = [name for name in ("key_id", "issuer_id", "app_id") if not fields.get(name)]
    if missing:
        raise ReleaseError(f"1Password item is missing field(s): {', '.join(missing)}")
    pem_source = fields.get("private_key") or fields.get("notesPlain") or ""
    return Credentials(fields["key_id"], fields["issuer_id"], fields["app_id"], extract_pem(pem_source))


def op_environment(local: dict[str, str]) -> dict[str, str]:
    """Use a read-only 1Password service account token from the login Keychain when configured.

    The desktop-app integration prompts for every new terminal session; a service account
    token does not. The token is passed only to the `op` child process.
    """
    env = dict(os.environ)
    service = setting("LABSTREAM_OP_SA_KEYCHAIN_SERVICE", local)
    if service and not env.get("OP_SERVICE_ACCOUNT_TOKEN"):
        token = subprocess.run(
            ["security", "find-generic-password", "-a", os.environ.get("USER", ""), "-s", service, "-w"],
            text=True, capture_output=True,
        )
        if token.returncode != 0 or not token.stdout.strip():
            raise ReleaseError(f"Keychain has no 1Password service account token under service {service!r}")
        env["OP_SERVICE_ACCOUNT_TOKEN"] = token.stdout.strip()
    return env


def load_credentials() -> Credentials:
    creds = optional_credentials()
    if creds is None:
        raise ReleaseError(
            "App Store Connect credentials are not configured; set LABSTREAM_ASC_OP_ITEM "
            "in scripts/asc.local.env (gitignored)"
        )
    return creds


def optional_credentials() -> Credentials | None:
    local = read_local_env()
    item_ref = setting("LABSTREAM_ASC_OP_ITEM", local)
    if item_ref:
        match = re.fullmatch(r"op://([^/]+)/([^/]+)/?", item_ref)
        if not match:
            raise ReleaseError("LABSTREAM_ASC_OP_ITEM must look like op://<vault>/<item>")
        vault, item = match.groups()
        if not shutil.which("op"):
            raise ReleaseError("1Password CLI `op` is not installed")
        result = subprocess.run(
            ["op", "item", "get", item, "--vault", vault, "--format", "json", "--reveal"],
            text=True, capture_output=True, env=op_environment(local),
        )
        if result.returncode != 0:
            raise ReleaseError("could not read the App Store Connect key from 1Password (approve the prompt or run `op signin`)")
        creds = parse_op_item(json.loads(result.stdout))
    else:
        key_path = setting("LABSTREAM_ASC_KEY_PATH", local)
        key_id = setting("LABSTREAM_ASC_KEY_ID", local)
        issuer_id = setting("LABSTREAM_ASC_ISSUER_ID", local)
        app_id = setting("LABSTREAM_ASC_APP_ID", local)
        if not (key_path and key_id and issuer_id and app_id):
            return None
        creds = Credentials(key_id, issuer_id, app_id, extract_pem(pathlib.Path(key_path).expanduser().read_text()))
    REDACT.add(creds.key_id, creds.issuer_id, creds.app_id)
    return creds


@contextlib.contextmanager
def private_key_file(creds: Credentials) -> Generator[pathlib.Path, None, None]:
    """Materialize the key for tools that need a path; always removed afterwards."""
    directory = pathlib.Path(tempfile.mkdtemp(prefix="ls-asc-"))
    try:
        os.chmod(directory, 0o700)
        path = directory / f"AuthKey_{creds.key_id}.p8"
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as handle:
            handle.write(creds.private_key_pem)
        yield path
    finally:
        shutil.rmtree(directory, ignore_errors=True)


# --- App Store Connect API -----------------------------------------------------


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def der_to_raw_signature(der: bytes, size: int = 32) -> bytes:
    """Convert an ASN.1 DER ECDSA signature into the JOSE r||s form."""
    if len(der) < 8 or der[0] != 0x30:
        raise ValueError("not a DER ECDSA signature")
    index = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F)
    parts = []
    for _ in range(2):
        if der[index] != 0x02:
            raise ValueError("malformed DER integer")
        length = der[index + 1]
        value = der[index + 2 : index + 2 + length].lstrip(b"\x00")
        if len(value) > size:
            raise ValueError("DER integer too large")
        parts.append(value.rjust(size, b"\x00"))
        index += 2 + length
    return parts[0] + parts[1]


def make_jwt(creds: Credentials, key_path: pathlib.Path, now: int | None = None) -> str:
    now = int(time.time()) if now is None else now
    header = {"alg": "ES256", "kid": creds.key_id, "typ": "JWT"}
    payload = {"iss": creds.issuer_id, "iat": now, "exp": now + 15 * 60, "aud": "appstoreconnect-v1"}
    signing_input = f"{b64url(json.dumps(header, separators=(',', ':')).encode())}.{b64url(json.dumps(payload, separators=(',', ':')).encode())}"
    der = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", str(key_path)],
        input=signing_input.encode(), capture_output=True, check=True,
    ).stdout
    return f"{signing_input}.{b64url(der_to_raw_signature(der))}"


class ASCClient:
    def __init__(self, token: str, app_id: str) -> None:
        self.token = token
        self.app_id = app_id

    def request(self, method: str, path: str, params: dict[str, str] | None = None, body: Any = None) -> Any:
        url = API_ROOT + path
        if params:
            url += "?" + urllib.parse.urlencode(params)
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("Authorization", f"Bearer {self.token}")
        if data is not None:
            req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                raw = resp.read()
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode(errors="replace")
            with contextlib.suppress(Exception):
                detail = "; ".join(e.get("detail") or e.get("title", "") for e in json.loads(detail)["errors"])
            raise ReleaseError(f"App Store Connect API {method} {path} -> HTTP {exc.code}: {detail}") from None
        return json.loads(raw) if raw else None

    def builds(self, version: str, build: str, platform: Platform) -> list[dict[str, Any]]:
        res = self.request("GET", "/v1/builds", {
            "filter[app]": self.app_id,
            "filter[version]": build,
            "filter[preReleaseVersion.version]": version,
            "filter[preReleaseVersion.platform]": platform.asc_platform,
            "include": "buildBetaDetail",
            "fields[builds]": "version,processingState,uploadedDate,expired,buildBetaDetail",
            "fields[buildBetaDetails]": "internalBuildState,externalBuildState",
        })
        details = {i["id"]: i["attributes"] for i in res.get("included", []) if i["type"] == "buildBetaDetails"}
        out = []
        for item in res["data"]:
            rel = ((item.get("relationships") or {}).get("buildBetaDetail") or {}).get("data") or {}
            out.append({"id": item["id"], **item["attributes"], "beta": details.get(rel.get("id"), {})})
        return out

    def beta_groups(self, build_id: str) -> list[str]:
        res = self.request("GET", "/v1/betaGroups", {"filter[builds]": build_id, "fields[betaGroups]": "name"})
        return [g["attributes"]["name"] for g in res["data"]]

    def app_store_version(self, version: str, platform: Platform) -> dict[str, Any] | None:
        res = self.request("GET", f"/v1/apps/{self.app_id}/appStoreVersions", {
            "filter[platform]": platform.asc_platform,
            "filter[versionString]": version,
            "fields[appStoreVersions]": "versionString,platform,appStoreState,build",
            "include": "build",
        })
        if not res["data"]:
            return None
        item = res["data"][0]
        rel = ((item.get("relationships") or {}).get("build") or {}).get("data") or {}
        return {"id": item["id"], **item["attributes"], "build_id": rel.get("id")}

    def build_label(self, build_id: str) -> str:
        res = self.request("GET", f"/v1/builds/{build_id}", {
            "include": "preReleaseVersion", "fields[builds]": "version,preReleaseVersion",
            "fields[preReleaseVersions]": "version",
        })
        pre = next((i["attributes"]["version"] for i in res.get("included", [])), "?")
        return f"{pre} ({res['data']['attributes']['version']})"

    def select_build(self, version_id: str, build_id: str) -> None:
        self.request("PATCH", f"/v1/appStoreVersions/{version_id}/relationships/build",
                     body={"data": {"type": "builds", "id": build_id}})


@contextlib.contextmanager
def asc_client(creds: Credentials) -> Generator[ASCClient, None, None]:
    with private_key_file(creds) as key_path:
        yield ASCClient(make_jwt(creds, key_path), creds.app_id)


# --- Source, versions, signing -------------------------------------------------


def source_state(allow_unpublished: bool) -> dict[str, str]:
    if run(["git", "status", "--porcelain", "--untracked-files=no"]).stdout.strip():
        raise ReleaseError("tracked files have uncommitted changes; release archives must come from a clean commit")
    slug = next(
        line.split("=", 1)[1] for line in run(["scripts/build-version-args.sh"]).stdout.splitlines()
        if line.startswith("LABSTREAM_BUILD_SLUG=")
    )
    if not slug.endswith("-clean"):
        raise ReleaseError(f"build slug {slug} is not clean (untracked app sources or assets?)")
    head = run(["git", "rev-parse", "HEAD"]).stdout.strip()
    published = run(["git", "merge-base", "--is-ancestor", "HEAD", "origin/main"], check=False).returncode == 0
    if not published and not allow_unpublished:
        raise ReleaseError("HEAD is not on origin/main; release from published source (or pass --allow-unpublished)")
    return {"head": head, "slug": slug}


def scheme_versions(platform: Platform) -> dict[str, str]:
    out = run(["xcodebuild", "-project", PROJECT, "-scheme", platform.scheme, "-configuration", "Release",
               "-showBuildSettings", "-json"]).stdout
    for entry in json.loads(out):
        if entry.get("target") == platform.scheme:
            s = entry["buildSettings"]
            return {"version": s["MARKETING_VERSION"], "build": s["CURRENT_PROJECT_VERSION"],
                    "bundle_id": s["PRODUCT_BUNDLE_IDENTIFIER"]}
    raise ReleaseError(f"no build settings for target {platform.scheme}")


def installed_identity_sha1s() -> set[str]:
    out = run(["security", "find-identity", "-p", "codesigning", "-v"]).stdout
    return {m.group(1).upper() for m in re.finditer(r"\b([0-9A-Fa-f]{40})\b", out)}


def _profile_helper():
    spec = importlib.util.spec_from_file_location("profile_info", REPO / "scripts" / "provisioning-profile-info.py")
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@dataclass
class Profile:
    name: str
    uuid: str
    team: str
    platforms: frozenset[str]
    expires: dt.datetime
    cert_sha1s: list[str]
    path: pathlib.Path
    xcode_managed: bool = False


def app_store_profiles(dirs: list[pathlib.Path] | None = None) -> list[Profile]:
    helper = _profile_helper()
    found: dict[str, Profile] = {}
    for root in dirs or PROFILE_DIRS:
        for path in sorted(root.glob("*.mobileprovision")) + sorted(root.glob("*.provisionprofile")) if root.is_dir() else []:
            try:
                data = helper.decode_profile(path)
            except Exception:
                continue
            ent = data.get("Entitlements") or {}
            team = (data.get("TeamIdentifier") or [""])[0]
            app_id = ent.get("application-identifier") or ent.get("com.apple.application-identifier") or ""
            expires = data.get("ExpirationDate")
            # macOS distribution profiles omit get-task-allow; development ones set a true flag.
            debuggable = ent.get("get-task-allow", ent.get("com.apple.security.get-task-allow"))
            if (app_id != f"{team}.{BUNDLE_ID}" or debuggable is True
                    or ("get-task-allow" not in ent and not path.suffix == ".provisionprofile")
                    or data.get("ProvisionedDevices") or data.get("ProvisionsAllDevices")
                    or not isinstance(expires, dt.datetime)):
                continue
            if expires.tzinfo is None:
                expires = expires.replace(tzinfo=dt.timezone.utc)
            found[data["UUID"]] = Profile(
                data.get("Name", ""), data["UUID"], team, frozenset(data.get("Platform") or []), expires,
                helper.cert_sha1s(data.get("DeveloperCertificates") or []), path,
                bool(data.get("IsXcodeManaged")),
            )
    return list(found.values())


def choose_profile(profiles: list[Profile], platform: Platform, identities: set[str],
                   now: dt.datetime | None = None) -> tuple[Profile, str]:
    now = now or dt.datetime.now(dt.timezone.utc)
    usable = []
    for profile in profiles:
        if not (profile.platforms & platform.profile_platforms) or profile.expires <= now:
            continue
        certs = [sha for sha in profile.cert_sha1s if sha.upper() in identities]
        if certs:
            usable.append((profile, certs[0].upper()))
    if not usable:
        raise ReleaseError(
            f"no unexpired App Store distribution profile for {BUNDLE_ID} on {platform.key} whose "
            "certificate is installed; download it in Xcode or the Apple Developer portal"
        )
    # Prefer the explicitly created App Store profiles over Xcode-managed team profiles.
    return max(usable, key=lambda pair: (not pair[0].xcode_managed, pair[0].expires))


@dataclass
class Plan:
    platform: Platform
    version: str
    build: str
    profile: Profile
    identity: str

    @property
    def team(self) -> str:
        return self.profile.team


def build_plans(platforms: list[Platform]) -> list[Plan]:
    identities = installed_identity_sha1s()
    profiles = app_store_profiles()
    plans = []
    for platform in platforms:
        versions = scheme_versions(platform)
        if versions["bundle_id"] != BUNDLE_ID:
            raise ReleaseError(f"{platform.scheme} bundle id is {versions['bundle_id']}, expected {BUNDLE_ID}")
        profile, identity = choose_profile(profiles, platform, identities)
        REDACT.add(profile.team, profile.uuid, identity)
        plans.append(Plan(platform, versions["version"], versions["build"], profile, identity))
    if len({(p.version, p.build) for p in plans}) > 1:
        warn("platforms have different version/build numbers: "
             + ", ".join(f"{p.platform.key} {p.version} ({p.build})" for p in plans))
    return plans


def archive_path(plan: Plan, head: str, day: str | None = None) -> pathlib.Path:
    day = day or dt.date.today().isoformat()
    return ARCHIVES_ROOT / day / f"{plan.platform.scheme}-{plan.version}-b{plan.build}-{head[:8]}.xcarchive"


def find_archive(plan: Plan, head: str) -> pathlib.Path:
    name = archive_path(plan, head).name
    matches = sorted(ARCHIVES_ROOT.glob(f"*/{name}"))
    if not matches:
        raise ReleaseError(f"no archive named {name} under {ARCHIVES_ROOT}; run `archive` first")
    return matches[-1]


# --- Archive validation --------------------------------------------------------


def archive_app(archive: pathlib.Path) -> pathlib.Path:
    apps = list((archive / "Products" / "Applications").glob("*.app"))
    if len(apps) != 1:
        raise ReleaseError(f"{archive.name}: expected exactly one app in Products/Applications")
    return apps[0]


def validate_archive(plan: Plan, archive: pathlib.Path, expected_slug: str) -> list[str]:
    problems: list[str] = []
    app = archive_app(archive)
    contents = app / "Contents" if plan.platform.macos else app
    info = plistlib.loads((contents / "Info.plist").read_bytes())
    checks = {
        "CFBundleIdentifier": BUNDLE_ID,
        "CFBundleShortVersionString": plan.version,
        "CFBundleVersion": plan.build,
        "LabstreamBuildSlug": expected_slug,
    }
    for key, expected in checks.items():
        if info.get(key) != expected:
            problems.append(f"{key} is {info.get(key)!r}, expected {expected!r}")
    min_os = info.get("LSMinimumSystemVersion" if plan.platform.macos else "MinimumOSVersion")

    verify = run(["codesign", "--verify", "--deep", "--strict", str(app)], check=False)
    if verify.returncode != 0:
        problems.append("codesign --verify --deep --strict failed")
    details = run(["codesign", "-dvv", str(app)], check=False).stderr
    if "Authority=Apple Distribution" not in details:
        problems.append("app is not signed with an Apple Distribution identity")
    if f"TeamIdentifier={plan.team}" not in details:
        problems.append("app is not signed by the profile's team")

    embedded = contents / ("embedded.provisionprofile" if plan.platform.macos else "embedded.mobileprovision")
    profile_name = ""
    if not embedded.is_file():
        problems.append("embedded provisioning profile is missing")
    else:
        data = _profile_helper().decode_profile(embedded)
        profile_name = data.get("Name", "")
        if (data.get("TeamIdentifier") or [""])[0] != plan.team:
            problems.append(f"embedded profile {profile_name!r} belongs to another team")
        if data.get("ProvisionedDevices") or data.get("ProvisionsAllDevices"):
            problems.append("embedded profile lists devices (not an App Store profile)")

    ents_raw = run(["codesign", "-d", "--entitlements", "-", "--xml", str(app)], check=False).stdout
    entitlements: dict[str, Any] = {}
    with contextlib.suppress(Exception):
        entitlements = plistlib.loads(ents_raw.encode()) if ents_raw.strip() else {}
    if plan.platform.macos:
        if entitlements.get("com.apple.security.get-task-allow") or entitlements.get("get-task-allow"):
            problems.append("macOS app is debuggable (get-task-allow is set)")
    elif entitlements.get("get-task-allow") is not False:
        problems.append(f"get-task-allow is {entitlements.get('get-task-allow')!r}, expected False")

    say(f"  {plan.platform.key:8} {plan.version} ({plan.build})  min OS {min_os}  profile {profile_name!r}")
    say(f"           entitlements: {', '.join(sorted(k for k in entitlements if 'get-task-allow' not in k)) or '(none)'}")
    return problems


def check_privacy(archives: dict[str, pathlib.Path]) -> list[str]:
    """The manifest checker compares all four packaged apps together."""
    if set(archives) != set(PLATFORMS):
        warn("privacy manifest check needs all four platforms; skipped")
        return []
    cmd = [sys.executable, "scripts/check-privacy-manifest.py"]
    for key, archive in archives.items():
        cmd += ["--app", f"{PLATFORMS[key].scheme}={archive_app(archive)}"]
    result = run(cmd, check=False)
    if result.returncode == 0:
        say("  privacy manifests match across all four apps")
        return []
    last = (result.stdout + result.stderr).strip().splitlines()[-1:]
    return ["privacy manifest check failed" + (f": {last[0]}" if last else "")]


def validate_all(plans: list[Plan], source: dict[str, str]) -> dict[str, pathlib.Path]:
    archives = {plan.platform.key: find_archive(plan, source["head"]) for plan in plans}
    problems: list[str] = []
    for plan in plans:
        for problem in validate_archive(plan, archives[plan.platform.key], source["slug"]):
            say(f"           FAIL {problem}")
            problems.append(f"{plan.platform.key}: {problem}")
    for problem in check_privacy(archives):
        say(f"  FAIL {problem}")
        problems.append(problem)
    if problems:
        raise ReleaseError("archive validation failed")
    return archives


# --- Commands ------------------------------------------------------------------


def selected_platforms(args: argparse.Namespace) -> list[Platform]:
    keys = args.platform or list(PLATFORMS)
    return [PLATFORMS[k] for k in keys]


def check_not_uploaded(plans: list[Plan], creds: Credentials) -> None:
    with asc_client(creds) as client:
        for plan in plans:
            if client.builds(plan.version, plan.build, plan.platform):
                raise ReleaseError(
                    f"{plan.platform.key} {plan.version} ({plan.build}) is already on App Store Connect; "
                    "bump CURRENT_PROJECT_VERSION before archiving a new binary"
                )


def cmd_preflight(args: argparse.Namespace) -> dict[str, Any]:
    source = source_state(args.allow_unpublished)
    plans = build_plans(selected_platforms(args))
    say(f"source: {source['head'][:12]} ({source['slug']})")
    now = dt.datetime.now(dt.timezone.utc)
    for plan in plans:
        days = (plan.profile.expires - now).days
        say(f"  {plan.platform.key:8} {plan.platform.scheme:16} {plan.version} ({plan.build})  "
            f"profile {plan.profile.name!r}, {days} days left")
        if days < PROFILE_EXPIRY_WARN_DAYS:
            warn(f"{plan.profile.name!r} expires in {days} days")
    creds = optional_credentials()
    if creds is None:
        warn("App Store Connect credentials not configured; skipped the already-uploaded check")
    else:
        check_not_uploaded(plans, creds)
        say("App Store Connect: these version/build numbers are not uploaded yet")
    return {"source": source, "plans": plans}


def cmd_archive(args: argparse.Namespace) -> int:
    state = cmd_preflight(args)
    head, plans = state["source"]["head"], state["plans"]
    try:
        for plan in plans:
            dest = archive_path(plan, head)
            if dest.exists():
                if not args.force:
                    raise ReleaseError(f"{dest} already exists; pass --force to replace it")
                shutil.rmtree(dest)
            dest.parent.mkdir(parents=True, exist_ok=True)
            say(f"archiving {plan.platform.scheme} -> {dest.name}")
            run([
                "scripts/xcodebuild-versioned.sh", "-project", PROJECT, "-scheme", plan.platform.scheme,
                "-configuration", "Release", "-destination", plan.platform.destination,
                "-derivedDataPath", str(DERIVED_DATA), "-archivePath", str(dest), "archive", "-quiet",
                "CODE_SIGN_STYLE=Manual", f"DEVELOPMENT_TEAM={plan.team}", f"CODE_SIGN_IDENTITY={plan.identity}",
                # Scope the profile to the app target; Swift package targets reject a global specifier.
                "PROVISIONING_PROFILE_SPECIFIER=$(LS_PP_$(TARGET_NAME))", f"LS_PP_{plan.platform.scheme}={plan.profile.uuid}",
            ])
    finally:
        shutil.rmtree(DERIVED_DATA, ignore_errors=True)
    say("archives written; next: validate")
    return 0


def cmd_validate(args: argparse.Namespace) -> int:
    source = source_state(args.allow_unpublished)
    validate_all(build_plans(selected_platforms(args)), source)
    say("all archives valid; Organizer can also generate the aggregate privacy report from them")
    return 0


def export_options(plan: Plan) -> dict[str, Any]:
    return {
        "method": "app-store-connect",
        "destination": "upload",
        "signingStyle": "manual",
        "teamID": plan.team,
        "signingCertificate": plan.identity,
        "provisioningProfiles": {BUNDLE_ID: plan.profile.uuid},
        "manageAppVersionAndBuildNumber": False,
        "uploadSymbols": True,
    }


def cmd_upload(args: argparse.Namespace) -> int:
    if not args.yes:
        raise ReleaseError("upload sends binaries to App Store Connect; rerun with --yes once it is authorized")
    source = source_state(args.allow_unpublished)
    plans = build_plans(selected_platforms(args))
    archives = validate_all(plans, source)
    creds = load_credentials()
    check_not_uploaded(plans, creds)
    with private_key_file(creds) as key_path:
        for plan in plans:
            work = pathlib.Path(tempfile.mkdtemp(prefix="ls-export-"))
            try:
                options = work / "ExportOptions.plist"
                options.write_bytes(plistlib.dumps(export_options(plan)))
                say(f"uploading {plan.platform.key} {plan.version} ({plan.build})…")
                run([
                    "xcodebuild", "-exportArchive", "-archivePath", str(archives[plan.platform.key]),
                    "-exportPath", str(work / "export"), "-exportOptionsPlist", str(options),
                    "-allowProvisioningUpdates", "-authenticationKeyPath", str(key_path),
                    "-authenticationKeyID", creds.key_id, "-authenticationKeyIssuerID", creds.issuer_id,
                ])
                say(f"  uploaded {plan.platform.key}")
            finally:
                shutil.rmtree(work, ignore_errors=True)
    say("uploads complete; next: status --wait, then select-build")
    return 0


def platform_status(client: ASCClient, version: str, build: str, platform: Platform) -> dict[str, Any]:
    builds = client.builds(version, build, platform)
    target = builds[0] if builds else None
    asv = client.app_store_version(version, platform)
    state: dict[str, Any] = {"platform": platform, "build": target, "version": asv, "groups": []}
    if target:
        state["groups"] = client.beta_groups(target["id"])
    if asv and asv.get("build_id") and (not target or asv["build_id"] != target["id"]):
        state["selected_label"] = client.build_label(asv["build_id"])
    return state


def describe(state: dict[str, Any], version: str, build: str) -> str:
    platform, target, asv = state["platform"], state["build"], state["version"]
    if not target:
        processing = "not uploaded"
    else:
        processing = target["processingState"]
        beta = target["beta"].get("internalBuildState")
        if beta:
            processing += f", TestFlight {beta}"
    groups = ", ".join(state["groups"]) or "no groups"
    if not asv:
        selection = f"no {version} App Store version"
    elif target and asv.get("build_id") == target["id"]:
        selection = f"{version} version uses this build"
    elif asv.get("build_id"):
        selection = f"{version} version uses {state.get('selected_label', 'another build')}"
    else:
        selection = f"{version} version has no build"
    return f"  {platform.key:8} {version} ({build}): {processing}; {groups}; {selection}"


def resolve_version(args: argparse.Namespace, platforms: list[Platform]) -> dict[str, tuple[str, str]]:
    if args.version and args.build:
        return {p.key: (args.version, args.build) for p in platforms}
    out = {}
    for platform in platforms:
        v = scheme_versions(platform)
        out[platform.key] = (args.version or v["version"], args.build or v["build"])
    return out


def cmd_status(args: argparse.Namespace) -> int:
    platforms = selected_platforms(args)
    versions = resolve_version(args, platforms)
    creds = load_credentials()
    deadline = time.monotonic() + args.timeout
    while True:
        with asc_client(creds) as client:
            states = [platform_status(client, *versions[p.key], p) for p in platforms]
        for state in states:
            say(describe(state, *versions[state["platform"].key]))
        pending = [s for s in states if not s["build"] or s["build"]["processingState"] == "PROCESSING"]
        if not args.wait or not pending:
            break
        if time.monotonic() > deadline:
            raise ReleaseError("timed out waiting for App Store Connect processing")
        say(f"waiting for {', '.join(s['platform'].key for s in pending)}…")
        time.sleep(60)
    bad = [s for s in states if s["build"] and s["build"]["processingState"] not in ("VALID", "PROCESSING")]
    if bad:
        raise ReleaseError("processing failed for " + ", ".join(s["platform"].key for s in bad))
    return 0


def cmd_select_build(args: argparse.Namespace) -> int:
    platforms = selected_platforms(args)
    versions = resolve_version(args, platforms)
    creds = load_credentials()
    with asc_client(creds) as client:
        changes = []
        for platform in platforms:
            state = platform_status(client, *versions[platform.key], platform)
            say(describe(state, *versions[platform.key]))
            target, asv = state["build"], state["version"]
            if not target or target["processingState"] != "VALID":
                raise ReleaseError(f"{platform.key} build is not processed (VALID) yet")
            if not asv:
                raise ReleaseError(f"{platform.key} has no {versions[platform.key][0]} App Store version to attach to")
            if asv.get("build_id") != target["id"]:
                changes.append((platform, asv, target))
        if not changes:
            say("every platform version already uses its build")
            return 0
        if not args.yes:
            say("would attach the build for: " + ", ".join(p.key for p, _, _ in changes) + " (rerun with --yes)")
            return 0
        for platform, asv, target in changes:
            client.select_build(asv["id"], target["id"])
            say(f"  {platform.key}: attached {versions[platform.key][0]} ({versions[platform.key][1]})")
    say("build selection saved; nothing was submitted for review")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--platform", action="append", choices=list(PLATFORMS),
                        help="limit to a platform (repeatable; default: all four)")
    common.add_argument("--verbose", action="store_true", help="show account identifiers unmasked")
    common.add_argument("--allow-unpublished", action="store_true", help="allow HEAD that is not on origin/main")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("preflight", parents=[common])
    archive = sub.add_parser("archive", parents=[common])
    archive.add_argument("--force", action="store_true", help="replace an existing archive with the same name")
    sub.add_parser("validate", parents=[common])
    upload = sub.add_parser("upload", parents=[common])
    upload.add_argument("--yes", action="store_true", help="confirm the upload is authorized")
    for name in ("status", "select-build"):
        sp = sub.add_parser(name, parents=[common])
        sp.add_argument("--version", help="marketing version (default: the project's)")
        sp.add_argument("--build", help="build number (default: the project's)")
        if name == "status":
            sp.add_argument("--wait", action="store_true", help="poll until processing finishes")
            sp.add_argument("--timeout", type=int, default=3600, help="seconds to wait with --wait")
        else:
            sp.add_argument("--yes", action="store_true", help="confirm attaching builds to App Store versions")
    args = parser.parse_args(argv)
    REDACT.verbose = args.verbose
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    handlers: dict[str, Callable[[argparse.Namespace], Any]] = {
        "preflight": cmd_preflight, "archive": cmd_archive, "validate": cmd_validate,
        "upload": cmd_upload, "status": cmd_status, "select-build": cmd_select_build,
    }
    try:
        handlers[args.command](args)
    except ReleaseError as exc:
        print(REDACT(f"testflight-release: {exc}"), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
