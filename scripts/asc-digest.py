#!/usr/bin/env python3
"""Private, read-only App Store Connect digest for the Labstream maintainer.

Collects, for the coordinated App Store app:

  * new App Store customer reviews (with platform attribution where App Store
    Connect exposes it through the per-version review relationship),
  * Xcode Organizer diagnostic signatures (HANGS, DISK_WRITES, LAUNCHES) for the
    newest builds of the current marketing version on each platform, and
  * TestFlight tester feedback (crash and screenshot submissions).

Everything user-generated (review text, nicknames, tester comments, emails, logs)
is written only to the gitignored artifacts/asc-digest/<YYYY-MM-DD>/ directory as
digest.md and digest.json. Stdout carries counts and the digest path only.

The script never writes to App Store Connect: every API call goes through a
GET-only wrapper. Endpoints that return 403/404 (for example before the app is
public) are recorded as unavailable instead of failing the run, and the run exits
0 when there is nothing new.

Credentials are loaded once per run with the same 1Password / Keychain service
account path as scripts/testflight-release.py (see that script and the gitignored
scripts/asc.local.env). Account identifiers never reach stdout or the digest.

Examples:
  scripts/asc-digest.py                    # last day, only items not seen before
  scripts/asc-digest.py --since 30d --all  # last 30 days, ignore the seen-state file
  scripts/asc-digest.py --version 1.7.2 --logs
"""
from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import importlib.util
import json
import os
import pathlib
import re
import sys
import urllib.parse
import urllib.request
from typing import Any, Callable, ContextManager, Iterable

REPO = pathlib.Path(__file__).resolve().parents[1]
OUT_ROOT = REPO / "artifacts" / "asc-digest"
STATE_FILE = "state.json"
PLATFORMS = ("IOS", "MAC_OS", "TV_OS", "VISION_OS")
DIAGNOSTIC_TYPES = ("HANGS", "DISK_WRITES", "LAUNCHES")
MAX_PAGES = 20
SEEN_CAP = 5000


def _load_release_module() -> Any:
    name = "testflight_release"
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, REPO / "scripts" / "testflight-release.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module  # dataclasses resolve their module through sys.modules
    spec.loader.exec_module(module)
    return module


tf = _load_release_module()


# --- Privacy helpers -------------------------------------------------------------

UUID_RE = re.compile(r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b")
LONG_NUMBER_RE = re.compile(r"\b\d{6,}\b")


def scrub(text: str) -> str:
    """Strip resource/account identifiers that App Store Connect errors can echo."""
    text = UUID_RE.sub("<uuid>", text)
    text = LONG_NUMBER_RE.sub("<id>", text)
    return tf.REDACT(text)


def private_write(path: pathlib.Path, data: str | bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "wb" if isinstance(data, bytes) else "w") as handle:
        handle.write(data)


# --- Time ------------------------------------------------------------------------


def parse_time(value: str) -> dt.datetime:
    value = value.strip()
    if value.endswith("Z"):
        value = value[:-1] + "+00:00"
    if re.fullmatch(r"\d{4}-\d{2}-\d{2}", value):
        value += "T00:00:00+00:00"
    parsed = dt.datetime.fromisoformat(value)
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=dt.timezone.utc)


def parse_since(value: str, now: dt.datetime) -> dt.datetime:
    match = re.fullmatch(r"(\d+)([dh])", value.strip())
    if match:
        amount, unit = int(match.group(1)), match.group(2)
        return now - (dt.timedelta(days=amount) if unit == "d" else dt.timedelta(hours=amount))
    try:
        return parse_time(value)
    except ValueError:
        raise argparse.ArgumentTypeError(f"--since must be Nd, Nh, or an ISO date: {value!r}") from None


# --- Read-only API access -----------------------------------------------------------


class ReadOnlyClient:
    """Wraps an ASCClient-like object and refuses anything but GET."""

    def __init__(self, client: Any, app_id: str) -> None:
        self._client = client
        self.app_id = app_id

    def request(self, method: str, path: str, params: dict[str, str] | None = None, body: Any = None) -> Any:
        if method != "GET" or body is not None:
            raise RuntimeError(f"asc-digest is read-only; refused {method}")
        return self._client.request("GET", path, params)

    def get(self, path: str, params: dict[str, str] | None = None) -> Any:
        return self.request("GET", path, params)

    def paginate(self, path: str, params: dict[str, str] | None = None,
                 stop: Callable[[dict[str, Any]], bool] | None = None) -> tuple[list[dict], list[dict]]:
        """Follow links.next. `stop(item)` true means the (descending) list has passed the window."""
        data: list[dict] = []
        included: list[dict] = []
        next_path: str | None = path
        next_params = params
        for _ in range(MAX_PAGES):
            if not next_path:
                break
            res = self.get(next_path, next_params) or {}
            included.extend(res.get("included") or [])
            done = False
            for item in res.get("data") or []:
                if stop and stop(item):
                    done = True
                    break
                data.append(item)
            link = (res.get("links") or {}).get("next")
            if done or not link:
                break
            parsed = urllib.parse.urlparse(link)  # same API host; keep path + cursor query only
            next_path = parsed.path + (f"?{parsed.query}" if parsed.query else "")
            next_params = None
        return data, included


class Sections:
    """Runs each digest section independently and records unavailable endpoints."""

    def __init__(self) -> None:
        self.problems: list[dict[str, Any]] = []

    def run(self, name: str, fn: Callable[[], Any], default: Any = None) -> Any:
        try:
            return fn()
        except tf.APIError as exc:
            status = "unavailable" if exc.status in (403, 404) else "error"
            self.problems.append({"section": name, "status": status, "http": exc.status, "detail": scrub(str(exc))})
        except (tf.ReleaseError, OSError, ValueError, KeyError) as exc:
            self.problems.append({"section": name, "status": "error", "http": None, "detail": scrub(f"{type(exc).__name__}: {exc}")})
        return default


# --- Builds and diagnostics ---------------------------------------------------------


def fetch_builds(client: ReadOnlyClient) -> list[dict[str, Any]]:
    data, included = client.paginate("/v1/builds", {
        "filter[app]": client.app_id,
        "sort": "-uploadedDate",
        "limit": "200",
        "include": "preReleaseVersion",
        "fields[builds]": "version,uploadedDate,processingState,expired,preReleaseVersion",
        "fields[preReleaseVersions]": "version,platform",
    })
    pre = {i["id"]: i.get("attributes") or {} for i in included if i.get("type") == "preReleaseVersions"}
    builds = []
    for item in data:
        attrs = item.get("attributes") or {}
        rel = ((item.get("relationships") or {}).get("preReleaseVersion") or {}).get("data") or {}
        version = pre.get(rel.get("id"), {})
        builds.append({
            "id": item["id"],
            "build": attrs.get("version", "?"),
            "version": version.get("version", "?"),
            "platform": version.get("platform", "UNKNOWN"),
            "uploaded": attrs.get("uploadedDate", ""),
            "processing": attrs.get("processingState", ""),
        })
    return builds


def label(build: dict[str, Any]) -> str:
    return f"{build['version']} ({build['build']})"


def select_diagnostic_builds(builds: list[dict[str, Any]], version: str | None, per_platform: int) -> list[dict[str, Any]]:
    """Newest builds of the requested (or newest uploaded) marketing version per platform."""
    chosen = []
    for platform in PLATFORMS:
        mine = sorted((b for b in builds if b["platform"] == platform), key=lambda b: b["uploaded"], reverse=True)
        if not mine:
            continue
        target = version or mine[0]["version"]
        chosen.extend([b for b in mine if b["version"] == target][:per_platform])
    return chosen


def fetch_diagnostics(client: ReadOnlyClient, build: dict[str, Any]) -> list[dict[str, Any]]:
    data, _ = client.paginate(f"/v1/builds/{build['id']}/diagnosticSignatures", {
        "fields[diagnosticSignatures]": "diagnosticType,signature,weight,insight",
        "limit": "200",
    })
    out = []
    for item in data:
        attrs = item.get("attributes") or {}
        out.append({
            "id": item["id"],
            "type": attrs.get("diagnosticType", "UNKNOWN"),
            "signature": attrs.get("signature", ""),
            "weight": attrs.get("weight"),
            "insight": attrs.get("insight"),
        })
    out.sort(key=lambda s: -(s["weight"] or 0))
    return out


NO_DATA = object()


def diagnostics_or_no_data(client: ReadOnlyClient, build: dict[str, Any]) -> Any:
    """App Store Connect answers 404 for builds that have no diagnostic data yet."""
    try:
        return fetch_diagnostics(client, build)
    except tf.APIError as exc:
        if exc.status == 404:
            return NO_DATA
        raise


# --- Customer reviews ---------------------------------------------------------------


def older_than(cutoff: dt.datetime) -> Callable[[dict[str, Any]], bool]:
    def stop(item: dict[str, Any]) -> bool:
        created = (item.get("attributes") or {}).get("createdDate")
        return bool(created) and parse_time(created) < cutoff
    return stop


def fetch_reviews(client: ReadOnlyClient, cutoff: dt.datetime) -> list[dict[str, Any]]:
    data, included = client.paginate(f"/v1/apps/{client.app_id}/customerReviews", {
        "sort": "-createdDate",
        "limit": "200",
        "include": "response",
        "fields[customerReviews]": "rating,title,body,reviewerNickname,createdDate,territory,response",
        "fields[customerReviewResponses]": "responseBody,lastModifiedDate,state",
    }, stop=older_than(cutoff))
    responses = {i["id"]: i.get("attributes") or {} for i in included if i.get("type") == "customerReviewResponses"}
    out = []
    for item in data:
        attrs = item.get("attributes") or {}
        rel = ((item.get("relationships") or {}).get("response") or {}).get("data") or {}
        out.append({
            "id": item["id"],
            "rating": attrs.get("rating"),
            "title": attrs.get("title") or "",
            "body": attrs.get("body") or "",
            "nickname": attrs.get("reviewerNickname") or "",
            "created": attrs.get("createdDate", ""),
            "territory": attrs.get("territory") or "",
            "response_state": (responses.get(rel.get("id")) or {}).get("state") if rel else None,
            "platform": "UNKNOWN",
            "app_version": None,
        })
    return out


def attribute_review_platforms(client: ReadOnlyClient, reviews: list[dict[str, Any]], cutoff: dt.datetime) -> None:
    """Customer reviews carry no platform; map them through each App Store version's reviews."""
    if not reviews:
        return
    versions, _ = client.paginate(f"/v1/apps/{client.app_id}/appStoreVersions", {
        "fields[appStoreVersions]": "versionString,platform", "limit": "200",
    })
    wanted = {r["id"]: r for r in reviews}
    for version in versions:
        attrs = version.get("attributes") or {}
        data, _ = client.paginate(f"/v1/appStoreVersions/{version['id']}/customerReviews", {
            "sort": "-createdDate", "limit": "200", "fields[customerReviews]": "createdDate",
        }, stop=older_than(cutoff))
        for item in data:
            if item["id"] in wanted:
                wanted[item["id"]]["platform"] = attrs.get("platform", "UNKNOWN")
                wanted[item["id"]]["app_version"] = attrs.get("versionString")


# --- TestFlight feedback ------------------------------------------------------------

FEEDBACK_KINDS = {
    "crash": "betaFeedbackCrashSubmissions",
    "screenshot": "betaFeedbackScreenshotSubmissions",
}


def fetch_feedback(client: ReadOnlyClient, kind: str, cutoff: dt.datetime,
                   builds_by_id: dict[str, dict[str, Any]]) -> list[dict[str, Any]]:
    resource = FEEDBACK_KINDS[kind]
    fields = "createdDate,comment,email,deviceModel,osVersion,appPlatform,devicePlatform,deviceFamily,build"
    if kind == "screenshot":
        fields += ",screenshots"
    data, included = client.paginate(f"/v1/apps/{client.app_id}/{resource}", {
        "sort": "-createdDate",
        "limit": "200",
        "include": "build",
        f"fields[{resource}]": fields,
        "fields[builds]": "version",
    }, stop=older_than(cutoff))
    included_builds = {i["id"]: (i.get("attributes") or {}).get("version") for i in included if i.get("type") == "builds"}
    out = []
    for item in data:
        attrs = item.get("attributes") or {}
        build_id = (((item.get("relationships") or {}).get("build") or {}).get("data") or {}).get("id")
        known = builds_by_id.get(build_id)
        build_label = label(known) if known else (f"build {included_builds[build_id]}" if included_builds.get(build_id) else "unknown build")
        out.append({
            "id": item["id"],
            "kind": kind,
            "created": attrs.get("createdDate", ""),
            "comment": attrs.get("comment") or "",
            "email": attrs.get("email") or "",
            "device": attrs.get("deviceModel") or "",
            "os": attrs.get("osVersion") or "",
            "platform": attrs.get("appPlatform") or attrs.get("devicePlatform") or "UNKNOWN",
            "build": build_label,
            "screenshots": [s.get("url") for s in (attrs.get("screenshots") or []) if isinstance(s, dict) and s.get("url")],
        })
    return out


def download(url: str) -> bytes:
    req = urllib.request.Request(url, method="GET")
    with urllib.request.urlopen(req, timeout=60) as resp:
        return resp.read()


# --- State --------------------------------------------------------------------------


def load_state(path: pathlib.Path) -> dict[str, Any]:
    try:
        state = json.loads(path.read_text())
    except (OSError, ValueError):
        state = {}
    state.setdefault("seen", {})
    return state


def save_state(path: pathlib.Path, state: dict[str, Any], now: dt.datetime) -> None:
    state["last_run"] = now.isoformat()
    for key, values in state["seen"].items():
        state["seen"][key] = list(dict.fromkeys(values))[-SEEN_CAP:]
    private_write(path, json.dumps(state, indent=2, sort_keys=True) + "\n")


def new_items(items: Iterable[dict[str, Any]], seen: Iterable[str], cutoff: dt.datetime, ignore_seen: bool) -> list[dict[str, Any]]:
    seen_set = set(seen)
    return [i for i in items
            if (not i.get("created") or parse_time(i["created"]) >= cutoff)
            and (ignore_seen or i["id"] not in seen_set)]


# --- Rendering ----------------------------------------------------------------------


def quote(text: str) -> str:
    return "\n".join("> " + line for line in (text.strip() or "(empty)").splitlines())


def by_platform(items: Iterable[dict[str, Any]]) -> dict[str, int]:
    counts: dict[str, int] = {}
    for item in items:
        counts[item["platform"]] = counts.get(item["platform"], 0) + 1
    return dict(sorted(counts.items()))


def fmt_counts(counts: dict[str, int]) -> str:
    return ", ".join(f"{k} {v}" for k, v in counts.items())


def summary_lines(digest: dict[str, Any]) -> list[str]:
    reviews = digest["reviews"]
    lines = [f"since {digest['since']}"]
    if reviews:
        ratings = [r["rating"] for r in reviews if isinstance(r["rating"], (int, float))]
        avg = f" (avg {sum(ratings) / len(ratings):.1f})" if ratings else ""
        lines.append(f"{len(reviews)} new review{'s' if len(reviews) != 1 else ''}{avg} [{fmt_counts(by_platform(reviews))}]")
    else:
        lines.append("0 new reviews")
    diag_parts = []
    for entry in digest["diagnostics"]:
        if entry.get("signatures") is None:
            if entry.get("note"):
                diag_parts.append(f"{entry['platform']} {entry['build']}: {entry['note']}")
            continue
        types: dict[str, int] = {}
        for sig in entry["signatures"]:
            types[sig["type"]] = types.get(sig["type"], 0) + 1
        new = sum(1 for s in entry["signatures"] if s.get("new"))
        detail = ", ".join(f"{n} {t.lower().replace('_', ' ')}" for t, n in sorted(types.items())) or "none"
        diag_parts.append(f"{entry['platform']} {entry['build']}: {detail}" + (f" ({new} new)" if new else ""))
    lines.append("diagnostic signatures: " + ("; ".join(diag_parts) if diag_parts else "no builds checked"))
    feedback = digest["feedback"]
    crash = sum(1 for f in feedback if f["kind"] == "crash")
    lines.append(f"{len(feedback)} TestFlight feedback ({crash} crash, {len(feedback) - crash} screenshot)"
                 + (f" [{fmt_counts(by_platform(feedback))}]" if feedback else ""))
    if digest["unavailable"]:
        lines.append("unavailable: " + ", ".join(f"{p['section']} ({p['status']}"
                                                  + (f" HTTP {p['http']}" if p.get("http") else "") + ")"
                                                  for p in digest["unavailable"]))
    return lines


def render_markdown(digest: dict[str, Any]) -> str:
    out = [f"# App Store Connect digest — {digest['date']}", "",
           f"Window: since {digest['since']}{' (all, ignoring seen state)' if digest['ignore_seen'] else ' (new since last run)'}.",
           "", "Private: contains customer and tester text. Do not commit or paste publicly.", "",
           "## Summary", ""]
    out += [f"- {line}" for line in summary_lines(digest)]
    out += ["", "## Customer reviews", ""]
    if not digest["reviews"]:
        out.append("No new reviews.")
    for r in digest["reviews"]:
        version = f" {r['app_version']}" if r.get("app_version") else ""
        stars = "★" * int(r["rating"] or 0)
        out += [f"### {stars} {r['title'] or '(untitled)'}", "",
                f"{r['platform']}{version} · {r['territory']} · {r['created']} · {r['nickname']}"
                + (f" · response {r['response_state']}" if r.get("response_state") else " · no response"),
                "", quote(r["body"]), ""]
    out += ["", "## Diagnostic signatures", ""]
    if not digest["diagnostics"]:
        out.append("No builds found to check.")
    for entry in digest["diagnostics"]:
        out += [f"### {entry['platform']} {entry['build']}", ""]
        if entry.get("signatures") is None:
            out += [(entry.get("note") or "not available").capitalize() + ".", ""]
            continue
        if not entry["signatures"]:
            out += ["No signatures.", ""]
            continue
        out += ["| Type | Weight | New | Signature |", "| --- | --- | --- | --- |"]
        for sig in entry["signatures"]:
            weight = f"{sig['weight']:.1f}%" if isinstance(sig["weight"], (int, float)) else "?"
            text = sig["signature"].replace("|", "\\|").replace("\n", " ")
            out.append(f"| {sig['type']} | {weight} | {'yes' if sig.get('new') else ''} | `{text}` |")
            if sig.get("log_file"):
                out.append(f"| | | | logs: `{sig['log_file']}` |")
        out.append("")
    out += ["", "## TestFlight feedback", ""]
    if not digest["feedback"]:
        out.append("No new TestFlight feedback.")
    for f in digest["feedback"]:
        out += [f"### {f['kind']} · {f['platform']} {f['build']} · {f['created']}", "",
                f"{f['device']} · OS {f['os']} · {f['email'] or 'no email'}", "", quote(f["comment"]), ""]
        for path in f.get("files", []):
            out.append(f"- `{path}`")
        if f.get("screenshots") and not f.get("files"):
            out.append(f"- {len(f['screenshots'])} screenshot(s); rerun with --attachments to download")
        out.append("")
    if digest["unavailable"]:
        out += ["", "## Unavailable", ""]
        out += [f"- {p['section']}: {p['status']}" + (f" (HTTP {p['http']})" if p.get("http") else "") + f" — {p['detail']}"
                for p in digest["unavailable"]]
    return "\n".join(out).rstrip() + "\n"


def day_name(now: dt.datetime) -> str:
    return now.astimezone().strftime("%Y-%m-%d")  # the maintainer's local calendar day


def output_dir(root: pathlib.Path, now: dt.datetime) -> tuple[pathlib.Path, str]:
    """Day directory plus a file stem that never overwrites an earlier run that day."""
    day = root / day_name(now)
    stem = "digest"
    if (day / "digest.md").exists():
        stem = f"digest-{now.astimezone().strftime('%H%M%S')}"
    return day, stem


# --- Main ---------------------------------------------------------------------------


@contextlib.contextmanager
def live_client() -> Any:
    creds = tf.load_credentials()  # once per run; registers identifiers with the redactor
    with tf.asc_client(creds) as client:
        yield client


def collect(client: ReadOnlyClient, args: argparse.Namespace, cutoff: dt.datetime, state: dict[str, Any],
            day: pathlib.Path) -> dict[str, Any]:
    sections = Sections()
    seen = state["seen"]

    builds = sections.run("builds", lambda: fetch_builds(client), default=[])
    builds_by_id = {b["id"]: b for b in builds}

    reviews = sections.run("customerReviews", lambda: fetch_reviews(client, cutoff), default=[])
    reviews = new_items(reviews, seen.get("reviews", []), cutoff, args.all)
    sections.run("reviewPlatforms", lambda: attribute_review_platforms(client, reviews, cutoff))

    diagnostics = []
    seen_diag = set(seen.get("diagnostics", []))
    for build in select_diagnostic_builds(builds, args.version, args.builds):
        sigs = sections.run(f"diagnosticSignatures {build['platform']} {label(build)}",
                            lambda b=build: diagnostics_or_no_data(client, b))
        if sigs is NO_DATA:
            diagnostics.append({"platform": build["platform"], "build": label(build), "signatures": None,
                                "note": "no diagnostic data yet"})
            continue
        for sig in sigs or []:
            sig["new"] = sig["id"] not in seen_diag
            if args.logs:
                logs = sections.run("diagnosticLogs", lambda s=sig: client.get(f"/v1/diagnosticSignatures/{s['id']}/logs"))
                if logs is not None:
                    rel = pathlib.Path("logs") / f"diagnostic-{sig['id']}.json"
                    private_write(day / rel, json.dumps(logs, indent=2))
                    sig["log_file"] = str(rel)
        diagnostics.append({"platform": build["platform"], "build": label(build), "signatures": sigs})

    feedback: list[dict[str, Any]] = []
    for kind, resource in FEEDBACK_KINDS.items():
        items = sections.run(resource, lambda k=kind: fetch_feedback(client, k, cutoff, builds_by_id), default=[])
        feedback.extend(new_items(items, seen.get("feedback", []), cutoff, args.all))
    feedback.sort(key=lambda f: f["created"], reverse=True)
    for f in feedback:
        f["files"] = []
        if args.logs and f["kind"] == "crash":
            log = sections.run("crashLog", lambda i=f["id"]: client.get(
                f"/v1/betaFeedbackCrashSubmissions/{i}/crashLog", {"fields[betaCrashLogs]": "logText"}))
            text = (((log or {}).get("data") or {}).get("attributes") or {}).get("logText")
            if text:
                rel = pathlib.Path("logs") / f"crash-{f['id']}.txt"
                private_write(day / rel, text)
                f["files"].append(str(rel))
        if args.attachments:
            for n, url in enumerate(f["screenshots"]):
                data = sections.run("screenshotDownload", lambda u=url: download(u))
                if data:
                    rel = pathlib.Path("attachments") / f"{f['id']}-{n}.png"
                    private_write(day / rel, data)
                    f["files"].append(str(rel))

    seen.setdefault("reviews", []).extend(r["id"] for r in reviews)
    seen.setdefault("feedback", []).extend(f["id"] for f in feedback)
    seen.setdefault("diagnostics", []).extend(s["id"] for d in diagnostics for s in d["signatures"] or [])
    return {
        "reviews": reviews,
        "diagnostics": diagnostics,
        "feedback": feedback,
        "unavailable": sections.problems,
    }


def main(argv: list[str] | None = None, client_factory: Callable[[], ContextManager[Any]] | None = None,
         now: dt.datetime | None = None, out_root: pathlib.Path | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--since", default="1d", help="window start: Nd, Nh, or an ISO date (default 1d)")
    parser.add_argument("--all", action="store_true", help="ignore the seen-state file; show everything in the window")
    parser.add_argument("--version", help="marketing version for diagnostics (default: newest uploaded per platform)")
    parser.add_argument("--builds", type=int, default=3, help="newest builds per platform to check for diagnostics")
    parser.add_argument("--logs", action="store_true", help="also save diagnostic and TestFlight crash logs (private files)")
    parser.add_argument("--attachments", action="store_true", help="download TestFlight feedback screenshots (private files)")
    parser.add_argument("--out-dir", type=pathlib.Path, help=argparse.SUPPRESS)
    args = parser.parse_args(argv)

    now = now or dt.datetime.now(dt.timezone.utc)
    root = out_root or args.out_dir or OUT_ROOT
    try:
        cutoff = parse_since(args.since, now)
    except argparse.ArgumentTypeError as exc:
        parser.error(str(exc))
    state_path = root / STATE_FILE
    state = load_state(state_path)
    day, stem = output_dir(root, now)

    try:
        with (client_factory or live_client)() as raw_client:
            client = ReadOnlyClient(raw_client, raw_client.app_id)
            digest = collect(client, args, cutoff, state, day)
    except tf.ReleaseError as exc:
        print(scrub(f"asc-digest: {exc}"), file=sys.stderr)
        return 1

    digest.update({"date": day_name(now), "generated": now.isoformat(),
                   "since": cutoff.isoformat(timespec="seconds"), "ignore_seen": args.all})
    private_write(day / f"{stem}.json", json.dumps(digest, indent=2, ensure_ascii=False) + "\n")
    md_path = day / f"{stem}.md"
    private_write(md_path, render_markdown(digest))
    save_state(state_path, state, now)

    for line in summary_lines(digest):
        print(scrub(line))
    try:
        shown = md_path.relative_to(REPO)
    except ValueError:
        shown = md_path
    print(f"digest: {shown}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
