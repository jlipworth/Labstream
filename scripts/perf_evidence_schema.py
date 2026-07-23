"""Shared closed schema for privacy-safe Labstream performance evidence."""
from __future__ import annotations

import json
import re
from dataclasses import dataclass
from typing import Any

SPAN_RE = re.compile(r"\bperf\.span\s+(?P<body>.*)$")
CAPTURE_RE = re.compile(r"\bperf\.capture\s+(?P<body>.*)$")
KEY_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_]{0,63}$")
SAFE_VALUE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
IP_RE = re.compile(r"(?<![A-Za-z0-9])(?:\d{1,3}\.){3}\d{1,3}(?![A-Za-z0-9])")
HOST_RE = re.compile(r"(?:^|[^A-Za-z0-9-])(?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,}(?:$|[^A-Za-z0-9-])")
SECRET_RE = re.compile(r"(?:token|api[_-]?key|authorization|bearer|password|client[_-]?identifier)", re.I)
RUN_ID_RE = re.compile(r"^run-[a-f0-9]{12}$")
WORKLOAD_ID_RE = re.compile(r"^workload-[a-f0-9]{12}$")
NONCE_RE = re.compile(r"^nonce-[a-f0-9]{16}$")
MAX_DURATION_MS = 86_400_000

KNOWN_RESULTS = {"success", "failure", "cancelled", "stale", "partial", "timeout", "superseded", "orphaned"}
KNOWN_BACKENDS = {"App", "Plex", "Jellyfin", "Emby"}
BACKEND_LABELS = {"plex": "Plex", "jellyfin": "Jellyfin", "emby": "Emby", "none": "App"}
PHASE_FIELDS: dict[str, set[str]] = {
    "runtime.composition": {"downloads_capable"},
    "runtime.download_manager": {"background_events"},
    "runtime.download_store": {"default_store"},
    "session.restore": {"restored"},
    "home.first_content": {"content_present", "rail_count", "item_count", "publication_count", "error"},
    "home.load": {
        "view_count", "rail_count", "pending_rail_count", "item_count", "degraded", "hub_count",
        "publication_count", "error",
    },
    "libraries.load": {"library_count", "error"},
    "library_grid.first_content": {
        "item_count", "total_count", "page_count", "publication_count", "collapse_mode", "error",
    },
    "library_grid.complete": {
        "item_count", "total_count", "page_count", "publication_count", "collapse_mode", "error",
    },
    "library_grid.initial_page": {"item_count", "total_count", "alphabet_count", "page_count", "error"},
    "library_grid.page": {"item_count", "page", "page_size", "attempt", "error"},
    "search.load": {"group_count", "item_count", "publication_count", "error"},
    "detail.metadata": {"media_count", "swr_refresh", "error"},
    "playback.resolve": {"path_mode", "play_method", "reason", "error"},
    "playback.startup": {"path_mode"},
    "playback.item_load": {"path_mode", "duration_seconds"},
    "artwork.load": {
        "attempts", "bytes", "status", "width", "height", "pixel_width", "pixel_height", "delivery",
        "scoped", "milestone",
    },
}
MEDIA_BACKENDS = {"Plex", "Jellyfin", "Emby"}
PHASE_BACKENDS: dict[str, set[str]] = {
    phase: ({"App"} if phase.startswith("runtime.") else MEDIA_BACKENDS)
    for phase in PHASE_FIELDS
}
REQUIRED_CORRECTNESS_FIELDS: dict[tuple[str, str], tuple[str, ...]] = {
    ("runtime.composition", "App"): ("downloads_capable",),
    ("runtime.download_manager", "App"): ("background_events",),
    ("runtime.download_store", "App"): ("default_store",),
    ("session.restore", "Plex"): ("restored",),
    ("session.restore", "Jellyfin"): ("restored",),
    ("session.restore", "Emby"): ("restored",),
    ("home.first_content", "Plex"): ("content_present",),
    ("home.first_content", "Jellyfin"): ("content_present",),
    ("home.first_content", "Emby"): ("content_present",),
    ("home.load", "Plex"): ("hub_count", "item_count"),
    ("home.load", "Jellyfin"): ("view_count", "rail_count", "item_count", "degraded"),
    ("home.load", "Emby"): ("view_count", "rail_count", "item_count", "degraded"),
    ("libraries.load", "Plex"): ("library_count",),
    ("libraries.load", "Jellyfin"): ("library_count",),
    ("libraries.load", "Emby"): ("library_count",),
    ("library_grid.first_content", "Plex"): ("item_count", "total_count", "page_count", "collapse_mode"),
    ("library_grid.first_content", "Jellyfin"): ("item_count", "total_count", "page_count", "collapse_mode"),
    ("library_grid.first_content", "Emby"): ("item_count", "total_count", "page_count", "collapse_mode"),
    ("library_grid.complete", "Plex"): ("item_count", "total_count", "page_count", "collapse_mode"),
    ("library_grid.complete", "Jellyfin"): ("item_count", "total_count", "page_count", "collapse_mode"),
    ("library_grid.complete", "Emby"): ("item_count", "total_count", "page_count", "collapse_mode"),
    ("library_grid.initial_page", "Plex"): ("item_count", "total_count"),
    ("library_grid.initial_page", "Jellyfin"): ("item_count", "total_count"),
    ("library_grid.initial_page", "Emby"): ("item_count", "total_count"),
    ("library_grid.page", "Plex"): ("item_count", "page", "page_size", "attempt"),
    ("library_grid.page", "Jellyfin"): ("item_count", "page", "page_size", "attempt"),
    ("library_grid.page", "Emby"): ("item_count", "page", "page_size", "attempt"),
    ("search.load", "Plex"): ("group_count", "item_count"),
    ("search.load", "Jellyfin"): ("group_count", "item_count"),
    ("search.load", "Emby"): ("group_count", "item_count"),
    ("detail.metadata", "Plex"): ("media_count",),
    ("detail.metadata", "Jellyfin"): ("media_count",),
    ("detail.metadata", "Emby"): ("media_count",),
    ("playback.resolve", "Plex"): ("path_mode",),
    ("playback.resolve", "Jellyfin"): ("path_mode", "play_method"),
    ("playback.resolve", "Emby"): ("path_mode", "play_method"),
    ("playback.startup", "Plex"): ("path_mode",),
    ("playback.startup", "Jellyfin"): ("path_mode",),
    ("playback.startup", "Emby"): ("path_mode",),
    ("playback.item_load", "Plex"): ("path_mode", "duration_seconds"),
    ("playback.item_load", "Jellyfin"): ("path_mode", "duration_seconds"),
    ("playback.item_load", "Emby"): ("path_mode", "duration_seconds"),
    ("artwork.load", "Plex"): ("attempts", "bytes", "status", "width", "height", "pixel_width", "pixel_height", "delivery"),
    ("artwork.load", "Jellyfin"): ("attempts", "bytes", "status", "width", "height", "pixel_width", "pixel_height", "delivery"),
    ("artwork.load", "Emby"): ("attempts", "bytes", "status", "width", "height", "pixel_width", "pixel_height", "delivery"),
}
ERROR_CATEGORIES = {
    "error_authentication", "error_configuration", "error_decoding", "error_other",
    "error_timeout", "error_transport", "error_unavailable",
}
INTEGER_FIELDS = {
    "view_count", "rail_count", "pending_rail_count", "publication_count", "group_count", "item_count",
    "hub_count", "library_count", "total_count", "page", "page_size", "attempt",
    "alphabet_count", "page_count", "media_count", "duration_seconds", "attempts", "bytes",
    "status", "width", "height", "pixel_width", "pixel_height",
}
BOOLEAN_FIELDS = {
    "background_events", "content_present", "default_store", "downloads_capable", "restored",
    "degraded", "swr_refresh", "scoped",
}
ENUM_FIELDS = {
    "path_mode": {"local_file", "remote_stream", "plex_stream"},
    "play_method": {"directPlay", "directStream", "transcode"},
    "reason": {"stale_metadata", "stale_open_success", "stale_open_failure"},
    "collapse_mode": {"sparse", "collapsed"},
    "delivery": {
        "network_decode", "compressed_cache_decode", "decoded_cache", "inflight_join", "local_file",
    },
    "milestone": {"library_first_poster"},
}
CORE_FIELDS = {"phase", "backend", "result", "duration_ms"}


@dataclass(frozen=True)
class SpanRecord:
    phase: str
    backend: str
    result: str
    duration_ms: int
    fields: dict[str, str]


def event_message(line: str) -> str:
    stripped = line.strip()
    if not stripped:
        return ""
    if stripped.startswith("{"):
        try:
            obj = json.loads(stripped)
        except json.JSONDecodeError:
            return stripped
        if not isinstance(obj, dict):
            return stripped
        for key in ("eventMessage", "message", "composedMessage"):
            value = obj.get(key)
            if isinstance(value, str):
                return value
    return stripped


def _tokens(body: str) -> tuple[dict[str, str] | None, str | None]:
    if not body:
        return None, "empty_record"
    parsed: dict[str, str] = {}
    for token in body.split():
        if token.count("=") != 1:
            return None, "unparsed_text"
        key, value = token.split("=", 1)
        if KEY_RE.fullmatch(key) is None or not value:
            return None, "invalid_token"
        if key in parsed:
            return None, "duplicate_field"
        parsed[key] = value
    return parsed, None


def _safe_public_token(value: str) -> bool:
    return (SAFE_VALUE_RE.fullmatch(value) is not None and IP_RE.search(value) is None
            and HOST_RE.search(value) is None and SECRET_RE.search(value) is None
            and not value.lower().startswith(("http:", "https:", "file:")))


def canonicalize_fields(phase: str, fields: dict[str, str], *, raw: bool) -> dict[str, str]:
    if phase not in PHASE_FIELDS or set(fields) - PHASE_FIELDS[phase]:
        raise ValueError("unexpected_phase_field")
    canonical: dict[str, str] = {}
    for key, value in fields.items():
        if not isinstance(key, str) or not isinstance(value, str):
            raise ValueError("invalid_field_type")
        if key == "error":
            if raw:
                if SAFE_VALUE_RE.fullmatch(value) is None:
                    raise ValueError("unsafe_field_value")
                lowered = value.lower()
                if any(fragment in lowered for fragment in ("auth", "unauthorized", "forbidden")):
                    canonical[key] = "error_authentication"
                elif any(fragment in lowered for fragment in ("timeout", "timedout")):
                    canonical[key] = "error_timeout"
                elif any(fragment in lowered for fragment in ("decode", "decoding", "parse")):
                    canonical[key] = "error_decoding"
                elif any(fragment in lowered for fragment in ("network", "urlerror", "connection", "http")):
                    canonical[key] = "error_transport"
                elif any(fragment in lowered for fragment in ("missing", "configuration")):
                    canonical[key] = "error_configuration"
                elif "unavailable" in lowered:
                    canonical[key] = "error_unavailable"
                else:
                    canonical[key] = "error_other"
            elif value in ERROR_CATEGORIES:
                canonical[key] = value
            else:
                raise ValueError("noncanonical_error_category")
        elif key in BOOLEAN_FIELDS:
            if value not in {"0", "1"}:
                raise ValueError("invalid_boolean_field")
            canonical[key] = value
        elif key in INTEGER_FIELDS:
            if re.fullmatch(r"0|[1-9][0-9]{0,15}", value) is None:
                raise ValueError("invalid_integer_field")
            if key == "status" and not 0 <= int(value) <= 599:
                raise ValueError("invalid_status_field")
            canonical[key] = value
        elif key in ENUM_FIELDS:
            if value not in ENUM_FIELDS[key]:
                raise ValueError("invalid_enum_field")
            canonical[key] = value
        else:
            raise ValueError("unexpected_phase_field")
        if key != "error" and not _safe_public_token(canonical[key]):
            raise ValueError("unsafe_field_value")
    return canonical


def validate_selector_fields(phase: str, fields: dict[str, str]) -> dict[str, str]:
    if not isinstance(fields, dict) or "error" in fields:
        raise ValueError("invalid_selector_fields")
    return canonicalize_fields(phase, fields, raw=False)


def validate_correctness_fields(phase: str, backend: str, fields: Any) -> tuple[str, ...]:
    required = REQUIRED_CORRECTNESS_FIELDS.get((phase, backend))
    if required is None or not isinstance(fields, list) or set(fields) != set(required) or len(fields) != len(required):
        raise ValueError("correctness_fields_must_match_closed_phase_backend_profile")
    return required


def parse_span_line_diagnostic(line: str) -> tuple[SpanRecord | None, str | None]:
    match = SPAN_RE.search(event_message(line))
    if not match:
        return None, None
    parsed, error = _tokens(match.group("body").strip())
    if error:
        return None, error
    assert parsed is not None
    if not CORE_FIELDS.issubset(parsed):
        return None, "missing_core_field"
    phase, backend, result, duration_raw = (parsed.pop(key) for key in ("phase", "backend", "result", "duration_ms"))
    if phase not in PHASE_FIELDS:
        return None, "unknown_phase"
    if backend not in KNOWN_BACKENDS:
        return None, "unknown_backend"
    if backend not in PHASE_BACKENDS[phase]:
        return None, "unexpected_phase_backend"
    if result not in KNOWN_RESULTS:
        return None, "unknown_result"
    try:
        duration = int(duration_raw)
    except ValueError:
        return None, "invalid_duration"
    if duration < 0:
        return None, "negative_duration"
    if duration > MAX_DURATION_MS or str(duration) != duration_raw:
        return None, "invalid_duration"
    try:
        fields = canonicalize_fields(phase, parsed, raw=True)
    except ValueError as validation:
        return None, str(validation)
    return SpanRecord(phase, backend, result, duration, fields), None


def parse_capture_line_diagnostic(line: str) -> tuple[dict[str, str] | None, str | None]:
    match = CAPTURE_RE.search(event_message(line))
    if not match:
        return None, None
    parsed, error = _tokens(match.group("body").strip())
    if error:
        return None, f"capture_{error}"
    assert parsed is not None
    if set(parsed) != {"run_id", "workload_id", "launch_nonce"}:
        return None, "capture_fields"
    if (RUN_ID_RE.fullmatch(parsed["run_id"]) is None
            or WORKLOAD_ID_RE.fullmatch(parsed["workload_id"]) is None
            or NONCE_RE.fullmatch(parsed["launch_nonce"]) is None):
        return None, "capture_value"
    return parsed, None
