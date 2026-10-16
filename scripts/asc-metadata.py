#!/usr/bin/env python3
"""Keep Labstream's App Store product-page text in the repository.

The editable App Store Connect text lives under appstore/metadata/ as one plain-text file
per field, so changes are reviewed in pull requests like any other source:

  appstore/metadata/app/<locale>/{name,subtitle,privacy_policy_url}.txt
  appstore/metadata/<platform>/<locale>/{description,keywords,promotional_text,
                                         whats_new,support_url,marketing_url}.txt
  appstore/metadata/<platform>/{copyright,review_notes}.txt

<platform> is visionos, ios, tvos, or macos. Subcommands:

  check          validate the files against App Store length limits (offline).
  pull           overwrite the files with the current App Store Connect text.
  diff           show where the files and App Store Connect differ (read-only).
  push [--yes]   dry run by default; --yes writes the differing fields.

Only the fields above are managed. Review contact details, demo-account credentials, and the
review server's address are never read into, written from, or stored in the repository; enter
those in App Store Connect. check rejects review notes that contain a URL, hostname, or IP
address, and pull refuses to copy such notes into the repository.
Screenshots, pricing, availability, age rating, and submission stay out of scope.

Credentials and version discovery reuse scripts/testflight-release.py (1Password service
account, gitignored scripts/asc.local.env). The editable version of each platform is the one
App Store Connect still allows changes on; pass --version to choose explicitly.
"""
from __future__ import annotations

import argparse
import difflib
import importlib.util
import pathlib
import re
import sys
from dataclasses import dataclass
from typing import Any

REPO = pathlib.Path(__file__).resolve().parents[1]
METADATA = REPO / "appstore" / "metadata"

_spec = importlib.util.spec_from_file_location("_asc_metadata_testflight", REPO / "scripts" / "testflight-release.py")
tf = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = tf
_spec.loader.exec_module(tf)

PLATFORMS = {"visionos": "VISION_OS", "ios": "IOS", "tvos": "TV_OS", "macos": "MAC_OS"}

# States in which App Store Connect accepts edits to version text.
EDITABLE_STATES = {
    "PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED",
    "INVALID_BINARY", "WAITING_FOR_REVIEW",
}


@dataclass(frozen=True)
class Field:
    file: str
    attribute: str
    limit: int
    url: bool = False
    bytes_limit: bool = False
    no_addresses: bool = False


APP_INFO_FIELDS = (
    Field("name.txt", "name", 30),
    Field("subtitle.txt", "subtitle", 30),
    Field("privacy_policy_url.txt", "privacyPolicyUrl", 255, url=True),
)
VERSION_LOCALE_FIELDS = (
    Field("description.txt", "description", 4000),
    Field("keywords.txt", "keywords", 100, bytes_limit=True),
    Field("promotional_text.txt", "promotionalText", 170),
    Field("whats_new.txt", "whatsNew", 4000),
    Field("support_url.txt", "supportUrl", 255, url=True),
    Field("marketing_url.txt", "marketingUrl", 255, url=True),
)
VERSION_FIELDS = (Field("copyright.txt", "copyright", 200),)
REVIEW_FIELDS = (Field("review_notes.txt", "notes", 4000, no_addresses=True),)

ID_PATTERN = re.compile(r"\b\d{8,}\b|\b[0-9a-fA-F]{8}-[0-9a-fA-F-]{27}\b")
# URLs, IPv4 addresses, and dotted hostnames (including the domain of an email address).
ADDRESS_PATTERN = re.compile(
    r"\b[a-z][a-z0-9+.-]*://\S+|\b(?:\d{1,3}\.){3}\d{1,3}\b|\b[a-z0-9-]+(?:\.[a-z0-9-]+)*\.[a-z]{2,}\b",
    re.IGNORECASE,
)


class MetadataError(RuntimeError):
    pass


def scrub(text: str) -> str:
    """Mask account and resource identifiers that API errors can echo back."""
    return ID_PATTERN.sub("<id>", text)


def read_value(path: pathlib.Path) -> str:
    if not path.exists():
        return ""
    text = path.read_text(encoding="utf-8")
    return text[:-1] if text.endswith("\n") else text


def write_value(path: pathlib.Path, value: str | None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text((value or "") + "\n", encoding="utf-8")


def problems_for(field: Field, value: str, where: str) -> list[str]:
    out = []
    size = len(value.encode("utf-8")) if field.bytes_limit else len(value)
    if size > field.limit:
        unit = "bytes" if field.bytes_limit else "characters"
        out.append(f"{where}/{field.file}: {size} {unit}, limit {field.limit}")
    if field.url and value and not value.startswith("https://"):
        out.append(f"{where}/{field.file}: must be an https:// URL")
    if field.no_addresses and ADDRESS_PATTERN.search(value):
        out.append(f"{where}/{field.file}: contains a URL, hostname, or IP address; keep server details "
                   "only in App Store Connect's Sign-In Information")
    if field.attribute == "keywords" and value and re.search(r",\s", value):
        out.append(f"{where}/{field.file}: separate keywords with commas only; spaces waste the byte limit")
    return out


def check(root: pathlib.Path = METADATA) -> list[str]:
    problems: list[str] = []
    if not root.is_dir():
        return [f"{root} does not exist; run pull first"]
    for locale_dir in sorted((root / "app").glob("*/")):
        for field in APP_INFO_FIELDS:
            problems += problems_for(field, read_value(locale_dir / field.file), f"app/{locale_dir.name}")
        if not read_value(locale_dir / "name.txt"):
            problems.append(f"app/{locale_dir.name}/name.txt: empty")
    for key in PLATFORMS:
        pdir = root / key
        if not pdir.is_dir():
            continue
        for field in VERSION_FIELDS + REVIEW_FIELDS:
            problems += problems_for(field, read_value(pdir / field.file), key)
        for locale_dir in sorted(p for p in pdir.iterdir() if p.is_dir()):
            for field in VERSION_LOCALE_FIELDS:
                problems += problems_for(field, read_value(locale_dir / field.file), f"{key}/{locale_dir.name}")
            if not read_value(locale_dir / "description.txt"):
                problems.append(f"{key}/{locale_dir.name}/description.txt: empty")
    return problems


# --- App Store Connect model -------------------------------------------------------


@dataclass
class Remote:
    """One editable App Store Connect resource and the managed fields it holds."""
    path: str              # repo-relative directory, e.g. "ios/en-US"
    resource_type: str     # JSON:API type for PATCH
    resource_id: str
    fields: tuple[Field, ...]
    values: dict[str, str]


def resources(client: Any, version: str | None, platforms: list[str]) -> list[Remote]:
    out: list[Remote] = []
    infos = client.request("GET", f"/v1/apps/{client.app_id}/appInfos")["data"]
    editable_info = [i for i in infos if (i["attributes"].get("state") or i["attributes"].get("appStoreState"))
                     not in {"READY_FOR_DISTRIBUTION", "READY_FOR_SALE", "REPLACED_WITH_NEW_INFO"}]
    if editable_info:
        locs = client.request("GET", f"/v1/appInfos/{editable_info[0]['id']}/appInfoLocalizations")["data"]
        for loc in locs:
            out.append(Remote(f"app/{loc['attributes']['locale']}", "appInfoLocalizations", loc["id"],
                              APP_INFO_FIELDS, _values(loc["attributes"], APP_INFO_FIELDS)))
    for key in platforms:
        ver = editable_version(client, PLATFORMS[key], version)
        if ver is None:
            continue
        out.append(Remote(key, "appStoreVersions", ver["id"], VERSION_FIELDS,
                          _values(ver["attributes"], VERSION_FIELDS)))
        locs = client.request("GET", f"/v1/appStoreVersions/{ver['id']}/appStoreVersionLocalizations")["data"]
        for loc in locs:
            out.append(Remote(f"{key}/{loc['attributes']['locale']}", "appStoreVersionLocalizations", loc["id"],
                              VERSION_LOCALE_FIELDS, _values(loc["attributes"], VERSION_LOCALE_FIELDS)))
        review = client.request("GET", f"/v1/appStoreVersions/{ver['id']}/appStoreReviewDetail",
                                {"fields[appStoreReviewDetails]": "notes"})
        if review and review.get("data"):
            out.append(Remote(key, "appStoreReviewDetails", review["data"]["id"], REVIEW_FIELDS,
                              _values(review["data"]["attributes"], REVIEW_FIELDS)))
    return out


def _values(attributes: dict[str, Any], fields: tuple[Field, ...]) -> dict[str, str]:
    return {f.attribute: attributes.get(f.attribute) or "" for f in fields}


def editable_version(client: Any, platform: str, version: str | None) -> dict[str, Any] | None:
    params = {"filter[platform]": platform, "limit": "50",
              "fields[appStoreVersions]": "versionString,platform,appStoreState,copyright"}
    if version:
        params["filter[versionString]"] = version
    items = client.request("GET", f"/v1/apps/{client.app_id}/appStoreVersions", params)["data"]
    if version:
        return items[0] if items else None
    editable = [i for i in items if i["attributes"].get("appStoreState") in EDITABLE_STATES]
    if len(editable) > 1:
        names = ", ".join(i["attributes"]["versionString"] for i in editable)
        raise MetadataError(f"{platform}: several editable versions ({names}); pass --version")
    return editable[0] if editable else None


def local_value(root: pathlib.Path, remote: Remote, field: Field) -> str:
    return read_value(root / remote.path / field.file)


def differences(root: pathlib.Path, remotes: list[Remote]) -> list[tuple[Remote, Field, str, str]]:
    out = []
    for remote in remotes:
        for field in remote.fields:
            local, current = local_value(root, remote, field), remote.values[field.attribute]
            if local != current:
                out.append((remote, field, current, local))
    return out


def show_diff(remote: Remote, field: Field, current: str, local: str) -> str:
    label = f"{remote.path}/{field.file}"
    if field.no_addresses:
        current, local = ADDRESS_PATTERN.sub("<address>", current), ADDRESS_PATTERN.sub("<address>", local)
    lines = difflib.unified_diff(current.splitlines(), local.splitlines(),
                                 f"App Store Connect: {label}", f"repository: {label}", lineterm="")
    return "\n".join(lines)


def push(client: Any, changes: list[tuple[Remote, Field, str, str]]) -> list[str]:
    errors = []
    grouped: dict[tuple[str, str], dict[str, Any]] = {}
    for remote, field, _current, local in changes:
        grouped.setdefault((remote.resource_type, remote.resource_id), {})[field.attribute] = local or None
    for (rtype, rid), attributes in grouped.items():
        try:
            client.request("PATCH", f"/v1/{rtype}/{rid}",
                           body={"data": {"type": rtype, "id": rid, "attributes": attributes}})
        except Exception as exc:  # report every failing resource, then exit non-zero
            errors.append(f"{rtype} ({', '.join(sorted(attributes))}): {scrub(str(exc))}")
    return errors


# --- Commands ----------------------------------------------------------------------


def with_client(args: argparse.Namespace, action):
    creds = tf.load_credentials()
    with tf.asc_client(creds) as client:
        return action(client)


def cmd_check(args: argparse.Namespace) -> int:
    problems = check(args.root)
    for p in problems:
        print(f"error: {p}")
    print("metadata check: ok" if not problems else f"metadata check: {len(problems)} problem(s)")
    return 1 if problems else 0


def cmd_pull(args: argparse.Namespace) -> int:
    def action(client):
        remotes = resources(client, args.version, args.platform)
        for remote in remotes:
            for field in remote.fields:
                value = remote.values[field.attribute]
                if field.no_addresses and value and ADDRESS_PATTERN.search(value):
                    print(f"warning: skipped {remote.path}/{field.file}: App Store Connect copy contains a "
                          "URL, hostname, or IP address; remove it there or edit the file by hand")
                    continue
                write_value(args.root / remote.path / field.file, value)
        print(f"pulled {sum(len(r.fields) for r in remotes)} field(s) into {display(args.root)}")
        return 0
    return with_client(args, action)


def cmd_diff(args: argparse.Namespace) -> int:
    def action(client):
        changes = differences(args.root, resources(client, args.version, args.platform))
        for change in changes:
            print(show_diff(*change))
        print(f"{len(changes)} field(s) differ" if changes else "App Store Connect matches the repository")
        return 0
    return with_client(args, action)


def cmd_push(args: argparse.Namespace) -> int:
    problems = check(args.root)
    if problems:
        for p in problems:
            print(f"error: {p}")
        return 1

    def action(client):
        changes = differences(args.root, resources(client, args.version, args.platform))
        if not changes:
            print("App Store Connect matches the repository; nothing to push")
            return 0
        for change in changes:
            print(show_diff(*change))
        if not args.yes:
            print(f"dry run: {len(changes)} field(s) would change; rerun with --yes to write them")
            return 0
        errors = push(client, changes)
        for err in errors:
            print(f"error: {err}")
        print(f"pushed {len(changes)} field(s)" if not errors else f"{len(errors)} resource update(s) failed")
        return 1 if errors else 0
    return with_client(args, action)


def display(path: pathlib.Path) -> str:
    try:
        return str(path.relative_to(REPO))
    except ValueError:
        return str(path)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", type=pathlib.Path, default=METADATA, help=argparse.SUPPRESS)
    sub = parser.add_subparsers(dest="command", required=True)
    for name, func in (("check", cmd_check), ("pull", cmd_pull), ("diff", cmd_diff), ("push", cmd_push)):
        p = sub.add_parser(name)
        p.set_defaults(func=func)
        if name != "check":
            p.add_argument("--version", help="marketing version to edit (default: each platform's editable version)")
            p.add_argument("--platform", action="append", choices=sorted(PLATFORMS),
                           help="limit to one platform (repeatable); default all four")
        if name == "push":
            p.add_argument("--yes", action="store_true", help="write the differing fields to App Store Connect")
    args = parser.parse_args(argv)
    if getattr(args, "platform", None) is None:
        args.platform = list(PLATFORMS)
    try:
        return args.func(args)
    except (MetadataError, tf.ReleaseError) as exc:
        print(f"error: {scrub(str(exc))}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
