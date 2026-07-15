#!/usr/bin/env python3
"""Create a bounded, model-safe index of a Labstream evidence bundle.

Raw evidence is never changed. The default output contains counts, fingerprints,
and source references rather than event fields, which may contain private data.
"""
from __future__ import annotations

import argparse
import collections
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile
from typing import Any, Iterable


DIAGNOSTIC_GLOB = "app-diagnostics.jsonl*"
VOLATILE_KEYS = {
    "timestamp", "date", "pid", "processid", "process_id", "processrunid",
    "process_run_id", "sessionid", "session_id", "playsessionid", "play_session_id",
}
SIGNAL_TERMS = (
    "error", "fail", "fatal", "crash", "assert", "timeout", "retry", "stale",
    "pause", "resume", "complete", "cancel", "status_transition", "health_snapshot",
    "playback.snapshot",
)
SAFE_LABEL_RE = re.compile(r"^[A-Za-z0-9_.:-]{1,128}$")


def canonical(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def digest(value: Any) -> str:
    return hashlib.sha256(canonical(value)).hexdigest()


def safe_label(value: Any) -> tuple[str, bool]:
    if isinstance(value, str) and SAFE_LABEL_RE.fullmatch(value):
        return value, True
    return f"unsafe-{digest(value)[:12]}", False


def semantic_value(value: Any, key: str = "") -> Any:
    if key.casefold() in VOLATILE_KEYS:
        return None
    if isinstance(value, dict):
        return {
            k: semantic_value(v, k)
            for k, v in sorted(value.items())
            if k.casefold() not in VOLATILE_KEYS
        }
    if isinstance(value, list):
        return [semantic_value(v) for v in value]
    return value


def diagnostic_sort_key(path: Path) -> tuple[int, str]:
    # Rotation order is oldest (.3) to newest (un-suffixed).
    suffix = path.name.removeprefix("app-diagnostics.jsonl")
    if suffix.startswith(".") and suffix[1:].isdigit():
        return (-int(suffix[1:]), path.name)
    return (1, path.name)


def find_sources(bundle: Path) -> list[Path]:
    return sorted(
        (p for p in bundle.rglob(DIAGNOSTIC_GLOB) if p.is_file()),
        key=lambda p: (str(p.parent), diagnostic_sort_key(p)),
    )


def event_rows(bundle: Path, sources: Iterable[Path]):
    for source in sources:
        with source.open(encoding="utf-8", errors="replace") as handle:
            for line_number, raw in enumerate(handle, 1):
                raw = raw.rstrip("\n")
                if not raw.strip():
                    continue
                try:
                    event = json.loads(raw)
                except json.JSONDecodeError:
                    yield {"parse_error": True, "source": str(source.relative_to(bundle)), "line": line_number}
                    continue
                if not isinstance(event, dict):
                    yield {"parse_error": True, "source": str(source.relative_to(bundle)), "line": line_number}
                    continue
                category, category_valid = safe_label(event.get("category") or "unknown")
                name, name_valid = safe_label(event.get("name") or "unknown")
                timestamp = event.get("timestamp")
                timestamp_valid = timestamp is None or isinstance(timestamp, str)
                yield {
                    "parse_error": False,
                    "schema_error": not (category_valid and name_valid and timestamp_valid),
                    "source": str(source.relative_to(bundle)),
                    "line": line_number,
                    "timestamp": timestamp if timestamp_valid else None,
                    "category": category,
                    "name": name,
                    "strict": digest(event),
                    "semantic": digest(semantic_value(event)),
                }


def atomic_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle, indent=2, sort_keys=True)
            handle.write("\n")
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def atomic_jsonl(path: Path, rows: Iterable[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            for row in rows:
                handle.write(json.dumps(row, sort_keys=True, separators=(",", ":")) + "\n")
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def load_baseline(path: Path | None) -> dict[str, Any] | None:
    if path is None:
        return None
    analysis = path.parent if path.name == "summary.json" else path / "analysis"
    try:
        summary = json.loads((analysis / "summary.json").read_text())
        summary["fingerprints"] = json.loads((analysis / "fingerprints.json").read_text())
        summary["source_manifest"] = json.loads((analysis / "source-manifest.json").read_text())
        return summary
    except (FileNotFoundError, json.JSONDecodeError):
        return None


def evidence_scope(bundle: Path) -> str | None:
    try:
        collection = json.loads((bundle / "summary.json").read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return None
    device = collection.get("device")
    bundle_id = collection.get("bundle_id")
    if not isinstance(device, str) or not isinstance(bundle_id, str):
        return None
    return digest({"device": device, "bundle_id": bundle_id})[:16]


def auto_baseline(bundle: Path, scope: str | None) -> Path | None:
    if scope is None:
        return None
    siblings = sorted(p for p in bundle.parent.iterdir() if p.is_dir() and p < bundle)
    for sibling in reversed(siblings):
        candidate = sibling / "analysis" / "summary.json"
        try:
            if json.loads(candidate.read_text()).get("scope_hash") == scope:
                return sibling
        except (FileNotFoundError, json.JSONDecodeError):
            pass
    return None


def evidence_manifest(bundle: Path) -> dict[str, Any]:
    files = {}
    for path in sorted(p for p in bundle.rglob("*") if p.is_file() and "analysis" not in p.relative_to(bundle).parts):
        data = path.read_bytes()
        files[str(path.relative_to(bundle))] = {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
    return {"files": files, "total_bytes": sum(v["bytes"] for v in files.values())}


def summarize(bundle: Path, output: Path, baseline_path: Path | None) -> dict[str, Any]:
    sources = find_sources(bundle)
    rows = list(event_rows(bundle, sources))
    valid = [r for r in rows if not r["parse_error"]]
    parse_errors = len(rows) - len(valid)
    schema_errors = sum(1 for r in valid if r["schema_error"])
    by_name = collections.Counter(r["name"] for r in valid)
    by_category = collections.Counter(r["category"] for r in valid)
    strict_counts = collections.Counter(r["strict"] for r in valid)
    semantic_counts = collections.Counter(r["semantic"] for r in valid)
    strict = set(strict_counts)
    semantic = set(semantic_counts)

    baseline = load_baseline(baseline_path)
    scope = evidence_scope(bundle)
    manifest = evidence_manifest(bundle)
    prior_manifest = (baseline or {}).get("source_manifest", {}).get("files", {})
    current_manifest = manifest["files"]
    changed_evidence = [path for path, meta in current_manifest.items() if prior_manifest.get(path) != meta]
    removed_evidence = [path for path in prior_manifest if path not in current_manifest]
    baseline_fingerprints = (baseline or {}).get("fingerprints", {})
    raw_prior_strict = baseline_fingerprints.get("strict_counts", baseline_fingerprints.get("strict", []))
    raw_prior_semantic = baseline_fingerprints.get("semantic_counts", baseline_fingerprints.get("semantic", []))
    prior_strict_counts = collections.Counter(raw_prior_strict) if isinstance(raw_prior_strict, list) else collections.Counter(raw_prior_strict)
    prior_semantic_counts = collections.Counter(raw_prior_semantic) if isinstance(raw_prior_semantic, list) else collections.Counter(raw_prior_semantic)
    prior_strict = set(prior_strict_counts)
    prior_semantic = set(prior_semantic_counts)
    new_strict_counts = strict_counts - prior_strict_counts if baseline else strict_counts
    new_semantic_counts = semantic_counts - prior_semantic_counts if baseline else semantic_counts
    new_strict = strict - prior_strict if baseline else strict
    new_semantic = semantic - prior_semantic if baseline else semantic

    manifests = []
    for source in sources:
        data = source.read_bytes()
        manifests.append({
            "path": str(source.relative_to(bundle)),
            "bytes": len(data),
            "sha256": hashlib.sha256(data).hexdigest(),
        })

    summary = {
        "schema_version": 1,
        "bundle": bundle.name,
        "scope_hash": scope,
        "source_count": len(sources),
        "source_bytes": sum(item["bytes"] for item in manifests),
        "event_count": len(valid),
        "parse_errors": parse_errors,
        "schema_errors": schema_errors,
        "unique_strict_events": len(strict),
        "unique_semantic_events": len(semantic),
        "time_bounds": {
            "first": min((r["timestamp"] for r in valid if r["timestamp"]), default=None),
            "last": max((r["timestamp"] for r in valid if r["timestamp"]), default=None),
        },
        "counts": {
            "categories": dict(by_category.most_common(100)),
            "categories_omitted": max(0, len(by_category) - 100),
            "events": dict(by_name.most_common(100)),
            "events_omitted": max(0, len(by_name) - 100),
        },
        "baseline": {
            "bundle": (baseline or {}).get("bundle"),
            "new_strict_events": sum(new_strict_counts.values()),
            "new_strict_fingerprints": len(new_strict),
            "new_semantic_events": len(new_semantic),
            "new_semantic_event_instances": sum(new_semantic_counts.values()),
            "strict_overlap": sum((strict_counts & prior_strict_counts).values()) if baseline else 0,
            "semantic_overlap": sum((semantic_counts & prior_semantic_counts).values()) if baseline else 0,
            "changed_evidence_files": len(changed_evidence) if baseline else len(current_manifest),
            "removed_evidence_files": len(removed_evidence) if baseline else 0,
            "evidence_manifest_identical": bool(baseline) and not changed_evidence and not removed_evidence,
        },
        "sources": manifests,
    }

    representatives: dict[str, dict[str, Any]] = {}
    for row in valid:
        key = row["semantic"]
        current = representatives.get(key)
        if current is None:
            representatives[key] = {
                "semantic_fingerprint": key,
                "category": row["category"],
                "name": row["name"],
                "count": 1,
                "first_timestamp": row["timestamp"],
                "last_timestamp": row["timestamp"],
                "first_source": row["source"],
                "first_line": row["line"],
                "last_source": row["source"],
                "last_line": row["line"],
            }
        else:
            current["count"] += 1
            current["last_timestamp"] = row["timestamp"]
            current["last_source"] = row["source"]
            current["last_line"] = row["line"]

    compact = sorted(representatives.values(), key=lambda r: (-r["count"], r["name"]))
    all_novel_refs = []
    remaining_novel = new_strict_counts.copy()
    if baseline:
        for row in valid:
            if remaining_novel[row["strict"]] <= 0:
                continue
            all_novel_refs.append({k: row[k] for k in (
                "timestamp", "category", "name", "strict", "semantic", "source", "line"
            )})
            remaining_novel[row["strict"]] -= 1
    # This is an agent-facing novelty sample, not a replacement for the raw index.
    # Keep it bounded even when an entirely new pull contains thousands of events.
    novel_refs = all_novel_refs[:50]
    summary["baseline"]["novel_references_emitted"] = len(novel_refs)
    summary["baseline"]["novel_references_omitted"] = len(all_novel_refs) - len(novel_refs)
    summary["baseline"]["new_event_type_counts"] = dict(
        collections.Counter(r["name"] for r in all_novel_refs).most_common(50)
    )
    atomic_json(output / "summary.json", summary)
    atomic_json(output / "source-manifest.json", manifest)
    atomic_json(output / "fingerprints.json", {
        "strict_counts": dict(sorted(strict_counts.items())),
        "semantic_counts": dict(sorted(semantic_counts.items())),
    })
    atomic_jsonl(output / "compact-events.jsonl", compact)
    atomic_jsonl(output / "novel-events.jsonl", novel_refs)

    top = by_name.most_common(25)
    signal = [(name, count) for name, count in by_name.items() if any(t in name.casefold() for t in SIGNAL_TERMS)]
    signal.sort(key=lambda item: (-item[1], item[0]))
    omitted = max(0, len(by_name) - len(top))
    lines = [
        "# Labstream diagnostic triage",
        "",
        f"- Bundle: `{bundle.name}`",
        f"- Sources: {len(sources)} files, {summary['source_bytes']:,} bytes",
        f"- Parsed events: {len(valid):,}; parse errors: {parse_errors:,}",
        f"- Schema warnings: {schema_errors:,}",
        f"- Unique exact events: {len(strict):,}; semantic fingerprints: {len(semantic):,}",
    ]
    if not sources:
        lines.append("- Status: **INCOMPLETE — no supported app diagnostic JSONL sources were found**")
    if baseline:
        lines += [
            f"- Baseline: `{summary['baseline']['bundle']}`",
            f"- Delta: {sum(new_strict_counts.values()):,} new exact event instances; {len(new_semantic):,} new semantic fingerprints",
            f"- Other evidence files changed: {len(changed_evidence):,}; removed: {len(removed_evidence):,}",
        ]
        if not new_strict_counts:
            lines.append("- Diagnostic verdict: **no new app diagnostic events; do not re-ingest the raw JSONL logs**")
        if not changed_evidence and not removed_evidence:
            lines.append("- Bundle verdict: source manifest is identical to the baseline")
    else:
        lines.append("- Baseline: none (this is the first indexed pull)")
    lines += ["", "## Most frequent event types", ""]
    lines += [f"- `{name}`: {count:,}" for name, count in top]
    if omitted:
        lines.append(f"- _{omitted} additional event types omitted from this bounded brief_ ")
    lines += ["", "## High-signal event types", ""]
    lines += [f"- `{name}`: {count:,}" for name, count in signal[:30]] or ["- None classified by the deterministic rules."]
    lines += [
        "", "## Progressive disclosure", "",
        "Start with this file and `summary.json`. `compact-events.jsonl` contains field-free aggregates and source references.",
        "Use `novel-events.jsonl` only for a repeated pull. Open a bounded raw source window only when causal detail is required.",
        "Do not cat or paste the diagnostics directory into model context.", "",
    ]
    brief = "\n".join(lines)
    if len(brief.encode()) > 16_384:
        raise RuntimeError("generated brief exceeded 16 KiB budget")
    (output / "triage.md").write_text(brief)
    return summary


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--baseline", type=Path)
    parser.add_argument("--auto-baseline", action="store_true")
    args = parser.parse_args(argv)
    bundle = args.bundle.resolve()
    output = (args.output or bundle / "analysis").resolve()
    baseline = args.baseline.resolve() if args.baseline else (auto_baseline(bundle, evidence_scope(bundle)) if args.auto_baseline else None)
    summary = summarize(bundle, output, baseline)
    delta = summary["baseline"]
    print(f"Triage: {output / 'triage.md'}")
    print(f"Events: {summary['event_count']} ({delta['new_strict_events']} new exact; {delta['new_semantic_events']} new semantic)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
