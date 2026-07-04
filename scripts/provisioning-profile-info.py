#!/usr/bin/env python3
"""Inspect and filter Apple provisioning profiles for deploy scripts.

This keeps plist/CMS/date/certificate parsing out of shell scripts. The shell
scripts should orchestrate builds; this helper owns provisioning-profile facts.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import pathlib
import plistlib
import shlex
import subprocess
import sys
import tempfile
from typing import Any, Iterable

DEFAULT_PROFILE_DIRS = [
    pathlib.Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles",
    pathlib.Path.home() / "Library/MobileDevice/Provisioning Profiles",
]


def decode_profile(path: pathlib.Path) -> dict[str, Any]:
    try:
        decoded = subprocess.check_output(
            ["security", "cms", "-D", "-i", str(path)], stderr=subprocess.DEVNULL
        )
    except subprocess.CalledProcessError as exc:
        raise RuntimeError(f"could not decode provisioning profile: {path}") from exc
    return plistlib.loads(decoded)


def iso_date(value: Any) -> str:
    if not isinstance(value, dt.datetime):
        return ""
    if value.tzinfo is None:
        value = value.replace(tzinfo=dt.timezone.utc)
    return value.isoformat().replace("+00:00", "Z")


def cert_sha1s(certs: Iterable[bytes]) -> list[str]:
    out: list[str] = []
    for cert in certs:
        with tempfile.NamedTemporaryFile(delete=False) as tf:
            tf.write(cert)
            cert_path = pathlib.Path(tf.name)
        try:
            raw = subprocess.check_output(
                [
                    "openssl",
                    "x509",
                    "-inform",
                    "DER",
                    "-in",
                    str(cert_path),
                    "-noout",
                    "-fingerprint",
                    "-sha1",
                ],
                text=True,
                stderr=subprocess.DEVNULL,
            ).strip()
            out.append(raw.split("=", 1)[1].replace(":", "").upper())
        finally:
            cert_path.unlink(missing_ok=True)
    return out


def profile_summary(path: pathlib.Path, device_udid: str = "") -> dict[str, Any]:
    data = decode_profile(path)
    ent = data.get("Entitlements") or {}
    teams = data.get("TeamIdentifier") or []
    devices = data.get("ProvisionedDevices") or []
    exp = data.get("ExpirationDate")
    now = dt.datetime.now(dt.timezone.utc)
    remaining_hours = ""
    remaining_days = ""
    not_expired = False
    if isinstance(exp, dt.datetime):
        if exp.tzinfo is None:
            exp = exp.replace(tzinfo=dt.timezone.utc)
        remaining = exp - now
        remaining_hours = int(remaining.total_seconds() // 3600)
        remaining_days = remaining.days
        not_expired = exp > now

    app_id = ent.get("application-identifier") or ""
    team = teams[0] if teams else ""
    bundle_id = app_id[len(team) + 1 :] if team and app_id.startswith(team + ".") else ""
    sha1s = cert_sha1s(data.get("DeveloperCertificates") or [])

    return {
        "path": str(path),
        "file": path.name,
        "name": data.get("Name") or "",
        "uuid": data.get("UUID") or "",
        "team": team,
        "team_name": data.get("TeamName") or "",
        "app_id": app_id,
        "bundle_id": bundle_id,
        "expiration": iso_date(exp),
        "not_expired": not_expired,
        "remaining_hours": remaining_hours,
        "remaining_days": remaining_days,
        "time_to_live_days": data.get("TimeToLive") or "",
        "get_task_allow": ent.get("get-task-allow"),
        "provisioned_device_count": len(devices),
        "contains_device": (device_udid in devices) if device_udid else "",
        "certificate_sha1s": sha1s,
        "first_certificate_sha1": sha1s[0] if sha1s else "",
    }


def bool_text(value: Any) -> str:
    if value is True:
        return "true"
    if value is False:
        return "false"
    return ""


def env_value(value: Any) -> str:
    if isinstance(value, bool):
        return bool_text(value)
    if isinstance(value, list):
        return " ".join(str(v) for v in value)
    if value is None:
        return ""
    return str(value)


def print_summary(summary: dict[str, Any], fmt: str) -> None:
    if fmt == "json":
        print(json.dumps(summary, indent=2, sort_keys=True))
        return
    if fmt == "env":
        for key, value in summary.items():
            env_key = "PROFILE_" + key.upper()
            print(f"{env_key}={shlex.quote(env_value(value))}")
        return
    if fmt == "tsv":
        print(tsv_row(summary))
        return
    for key, value in summary.items():
        print(f"{key}: {env_value(value)}")


def default_dirs(paths: list[str]) -> list[pathlib.Path]:
    return [pathlib.Path(p).expanduser() for p in paths] if paths else DEFAULT_PROFILE_DIRS


def iter_profiles(paths: list[pathlib.Path]) -> Iterable[pathlib.Path]:
    seen: set[pathlib.Path] = set()
    for root in paths:
        if root.is_file() and root.suffix == ".mobileprovision":
            candidates = [root]
        elif root.is_dir():
            candidates = sorted(root.glob("*.mobileprovision"))
        else:
            candidates = []
        for candidate in candidates:
            resolved = candidate.resolve()
            if resolved in seen:
                continue
            seen.add(resolved)
            yield candidate


def matches(summary: dict[str, Any], args: argparse.Namespace) -> bool:
    if args.bundle_id and summary["bundle_id"] != args.bundle_id:
        return False
    if args.team and summary["team"] != args.team:
        return False
    if args.kind == "development" and summary["get_task_allow"] is not True:
        return False
    if args.kind == "ad-hoc":
        if summary["get_task_allow"] is not False:
            return False
        if int(summary["provisioned_device_count"] or 0) <= 0:
            return False
    if args.device_udid and summary["contains_device"] is not True:
        return False
    if getattr(args, "only_usable", False) and summary["not_expired"] is not True:
        return False
    return True


def tsv_row(summary: dict[str, Any]) -> str:
    fields = [
        "uuid",
        "name",
        "team",
        "expiration",
        "not_expired",
        "provisioned_device_count",
        "file",
        "path",
        "first_certificate_sha1",
        "contains_device",
        "get_task_allow",
        "time_to_live_days",
        "remaining_hours",
    ]
    vals = []
    for field in fields:
        value = summary.get(field, "")
        if isinstance(value, bool):
            value = bool_text(value)
        vals.append(str(value).replace("\t", " ").replace("\n", " "))
    return "\t".join(vals)


def cmd_summary(args: argparse.Namespace) -> int:
    print_summary(profile_summary(pathlib.Path(args.profile), args.device_udid), args.format)
    return 0


def cmd_list(args: argparse.Namespace) -> int:
    for profile in iter_profiles(default_dirs(args.dir)):
        try:
            summary = profile_summary(profile, args.device_udid)
        except Exception:
            continue
        if matches(summary, args):
            print_summary(summary, args.format)
    return 0


def cmd_find(args: argparse.Namespace) -> int:
    for profile in iter_profiles(default_dirs(args.dir)):
        try:
            summary = profile_summary(profile, args.device_udid)
        except Exception:
            continue
        if args.specifier not in {summary["uuid"], summary["name"]}:
            continue
        if matches(summary, args):
            print(summary["path"])
            return 0
    return 1


def cmd_prune(args: argparse.Namespace) -> int:
    removed = 0
    for profile in iter_profiles(default_dirs(args.dir)):
        try:
            summary = profile_summary(profile, args.device_udid)
        except Exception:
            continue
        if not matches(summary, args):
            continue
        ttl = summary["time_to_live_days"]
        short_lived = isinstance(ttl, int) and ttl <= args.short_ttl_days
        expired = summary["not_expired"] is not True
        if not (short_lived or expired):
            continue
        msg = (
            f"removed_short_dev_profile: {summary['name']} "
            f"exp={summary['expiration']} ttl={ttl} path={summary['path']}"
        )
        if args.dry_run:
            print("would_" + msg)
        else:
            try:
                pathlib.Path(summary["path"]).unlink()
                removed += 1
                print(msg)
            except Exception as exc:
                print(f"could_not_remove={summary['path']}: {exc}")
    return 0 if removed or args.dry_run else 0


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("summary", help="print facts for one provisioning profile")
    s.add_argument("profile")
    s.add_argument("--device-udid", default="")
    s.add_argument("--format", choices=["text", "json", "env", "tsv"], default="text")
    s.set_defaults(func=cmd_summary)

    def add_filter_args(sp: argparse.ArgumentParser) -> None:
        sp.add_argument("--dir", action="append", default=[], help="profile directory or profile file; repeatable")
        sp.add_argument("--bundle-id", default="")
        sp.add_argument("--team", default="")
        sp.add_argument("--kind", choices=["all", "development", "ad-hoc"], default="all")
        sp.add_argument("--device-udid", default="")
        sp.add_argument("--only-usable", action="store_true", help="require not expired")

    l = sub.add_parser("list", help="list matching provisioning profiles")
    add_filter_args(l)
    l.add_argument("--format", choices=["text", "json", "env", "tsv"], default="tsv")
    l.set_defaults(func=cmd_list)

    f = sub.add_parser("find", help="find a profile path by name or UUID")
    add_filter_args(f)
    f.add_argument("--specifier", required=True)
    f.set_defaults(func=cmd_find)

    pr = sub.add_parser("prune", help="remove matching expired or short-lived profiles")
    add_filter_args(pr)
    pr.add_argument("--short-ttl-days", type=int, default=14)
    pr.add_argument("--dry-run", action="store_true")
    pr.set_defaults(func=cmd_prune)
    return p


def main() -> int:
    args = parser().parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
