#!/usr/bin/env python3
"""Deterministic, loopback-only Emby-compatible browse/artwork fixture.

This is external measurement tooling, never an app-embedded fixture. It accepts no
credential, token, password, or public-bind configuration and records only aggregate
route/status counters. Raw paths, query values, and headers are never retained.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import ipaddress
import json
import os
import signal
import socket
import threading
import time
from collections import Counter
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlsplit


BIND = "127.0.0.1"
USER_ID = "fixture-user"
SERVER_ID = "fixture-server"
IMAGE_TAG = "fixture-image-v1"
AUTH_USERNAME = "benchmark-user"
AUTH_PASSWORD = "benchmark-pass-v1"
ACCESS_TOKEN = "benchmark-access-v1"
CONTROL_PREFIX = "/__fixture__"
ROUTE_IDS = frozenset({
    "server_info", "authenticate", "views", "items", "resume", "next_up", "latest", "image",
})
CONTROL_KEYS = frozenset({"route", "delay_ms", "status", "remaining"})
SECRET_KEYS = frozenset({"token", "password", "secret", "authorization", "api_key", "apikey"})
FAULT_STATUSES = frozenset({400, 429, 500, 503})
MAX_BODY_BYTES = 4096
MAX_DELAY_MS = 10_000
MAX_REMAINING = 1000
MAX_QUERY_INTEGER = 1_000_000
MAX_ACTIVE_HANDLERS = 8
CONNECTION_TIMEOUT_SECONDS = 2.0
MAX_LEDGER_COUNTER = (1 << 63) - 1

QUERY_KEYS = {
    "views": frozenset({"UserId", "IncludeExternalContent"}),
    "items": frozenset({
        "UserId", "ParentId", "Recursive", "StartIndex", "Limit", "SearchTerm",
        "NameStartsWith", "SortBy", "SortOrder", "IncludeItemTypes", "Fields",
        "EnableUserData", "AlbumArtistIds", "ArtistIds", "Filters",
    }),
    "resume": frozenset({
        "ParentId", "StartIndex", "Limit", "IncludeItemTypes", "Fields",
        "EnableUserData", "EnableImages",
    }),
    "next_up": frozenset({
        "UserId", "ParentId", "StartIndex", "Limit", "Fields", "EnableUserData",
        "EnableImages",
    }),
    "latest": frozenset({
        "ParentId", "Limit", "IncludeItemTypes", "Fields", "EnableUserData",
        "EnableImages", "GroupItems",
    }),
    "image": frozenset({"tag", "width", "height"}),
    "server_info": frozenset(),
}

PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUB"
    "AScY42YAAAAASUVORK5CYII="
)


def _item(identifier: str, name: str, kind: str, parent: str, index: int) -> dict[str, Any]:
    return {
        "Id": identifier,
        "ServerId": SERVER_ID,
        "Name": name,
        "SortName": name,
        "Type": kind,
        "ParentId": parent,
        "IsFolder": kind == "Series",
        "ProductionYear": 2000 + (index % 20),
        "RunTimeTicks": 54_000_000_000,
        "ImageTags": {"Primary": IMAGE_TAG},
        "UserData": {
            "Played": False,
            "PlaybackPositionTicks": index * 10_000_000,
        },
    }


VIEWS = (
    {"Id": "library-movies", "ServerId": SERVER_ID, "Name": "Fixture Movies",
     "SortName": "Fixture Movies", "Type": "CollectionFolder", "CollectionType": "movies",
     "IsFolder": True},
    {"Id": "library-shows", "ServerId": SERVER_ID, "Name": "Fixture Shows",
     "SortName": "Fixture Shows", "Type": "CollectionFolder", "CollectionType": "tvshows",
     "IsFolder": True},
)
MOVIES = tuple(
    _item(f"movie-{index:02d}", f"{chr(65 + index)} Fixture Movie", "Movie", "library-movies", index)
    for index in range(26)
)
SHOWS = tuple(
    _item(f"series-{index:02d}", f"{chr(65 + index)} Fixture Series", "Series", "library-shows", index)
    for index in range(8)
)
EPISODES = tuple(
    _item(f"episode-{index:02d}", f"Fixture Episode {index:02d}", "Episode",
          "library-shows", index)
    for index in range(8)
)
ALL_ITEMS = MOVIES + SHOWS + EPISODES
ITEM_BY_ID = {item["Id"]: item for item in ALL_ITEMS}

_CORPUS_CANONICAL = json.dumps(
    {"views": VIEWS, "items": ALL_ITEMS}, sort_keys=True, separators=(",", ":")
).encode()
CORPUS_SHA256 = hashlib.sha256(_CORPUS_CANONICAL).hexdigest()
FIXTURE_ID = f"fixture-{CORPUS_SHA256[:12]}"


class FixtureConfigurationError(ValueError):
    pass


def validate_bind(value: str) -> str:
    try:
        address = ipaddress.ip_address(value)
    except ValueError as error:
        raise FixtureConfigurationError("bind must be the literal IPv4 loopback address") from error
    if address.version != 4 or not address.is_loopback or value != BIND:
        raise FixtureConfigurationError("public, wildcard, hostname, and non-default binds are forbidden")
    return value


def _bounded_int(raw: str | None, default: int, *, maximum: int) -> int:
    if raw is None:
        return default
    try:
        value = int(raw)
    except ValueError as error:
        raise FixtureConfigurationError("query integer is invalid") from error
    if value < 0 or value > maximum:
        raise FixtureConfigurationError("query integer is outside the fixture bound")
    return value


@dataclass
class Behavior:
    delay_ms: int
    status: int | None
    remaining: int


class FixtureState:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.behaviors: dict[str, Behavior] = {}
        self.reset_ledger()

    def reset_ledger(self) -> None:
        with getattr(self, "lock", threading.Lock()):
            self.total = 0
            self.by_route: Counter[str] = Counter()
            self.by_status: Counter[str] = Counter()
            self.delayed = 0
            self.faulted = 0
            self.in_flight = 0
            self.max_in_flight = 0
            self.declared_response_bytes: Counter[str] = Counter()
            self.committed_response_bytes: Counter[str] = Counter()
            self.write_failures = 0
            self.client_disconnects = 0

    def reset(self) -> None:
        with self.lock:
            if self.in_flight:
                raise FixtureConfigurationError("reset requires zero in-flight data requests")
            self.behaviors.clear()
            self.total = 0
            self.by_route.clear()
            self.by_status.clear()
            self.delayed = 0
            self.faulted = 0
            self.in_flight = 0
            self.max_in_flight = 0
            self.declared_response_bytes.clear()
            self.committed_response_bytes.clear()
            self.write_failures = 0
            self.client_disconnects = 0

    def configure(self, document: Any) -> None:
        if not isinstance(document, dict) or set(document) != CONTROL_KEYS:
            raise FixtureConfigurationError("control document must contain exactly the closed keys")
        if any(str(key).lower() in SECRET_KEYS for key in document):
            raise FixtureConfigurationError("secret-bearing configuration is forbidden")
        route, delay_ms, status, remaining = (
            document["route"], document["delay_ms"], document["status"], document["remaining"]
        )
        if route not in ROUTE_IDS:
            raise FixtureConfigurationError("control route is not in the closed route set")
        if not isinstance(delay_ms, int) or isinstance(delay_ms, bool) or not 0 <= delay_ms <= MAX_DELAY_MS:
            raise FixtureConfigurationError("delay_ms is outside the fixture bound")
        if status is not None and status not in FAULT_STATUSES:
            raise FixtureConfigurationError("status is not null or an allowed deterministic failure")
        if status is None and delay_ms == 0:
            raise FixtureConfigurationError("control must request a delay or failure")
        if not isinstance(remaining, int) or isinstance(remaining, bool) or not 1 <= remaining <= MAX_REMAINING:
            raise FixtureConfigurationError("remaining is outside the fixture bound")
        with self.lock:
            self.behaviors[route] = Behavior(delay_ms, status, remaining)

    def begin(self, route: str) -> Behavior | None:
        with self.lock:
            self.in_flight += 1
            self.max_in_flight = max(self.max_in_flight, self.in_flight)
            behavior = self.behaviors.get(route)
            if behavior is None:
                return None
            selected = Behavior(behavior.delay_ms, behavior.status, behavior.remaining)
            behavior.remaining -= 1
            if behavior.remaining == 0:
                del self.behaviors[route]
            return selected

    def finish(self, route: str, status: int, behavior: Behavior | None,
               *, was_begun: bool = True) -> None:
        with self.lock:
            if was_begun:
                self.in_flight -= 1
            self.total += 1
            self.by_route[route] += 1
            self.by_status[str(status)] += 1
            if behavior and behavior.delay_ms:
                self.delayed += 1
            if behavior and behavior.status is not None:
                self.faulted += 1

    @staticmethod
    def _saturating_add(current: int, increment: int) -> int:
        return min(MAX_LEDGER_COUNTER, current + max(0, increment))

    def note_response(self, route: str, declared: int, committed: int,
                      *, write_failed: bool = False, disconnected: bool = False) -> None:
        with self.lock:
            self.declared_response_bytes[route] = self._saturating_add(
                self.declared_response_bytes[route], declared)
            self.committed_response_bytes[route] = self._saturating_add(
                self.committed_response_bytes[route], min(declared, committed))
            if write_failed:
                self.write_failures = self._saturating_add(self.write_failures, 1)
            if disconnected:
                self.client_disconnects = self._saturating_add(self.client_disconnects, 1)

    def ledger(self) -> dict[str, Any]:
        with self.lock:
            return {
                "schema_version": 1,
                "fixture_id": FIXTURE_ID,
                "fixture_sha256": CORPUS_SHA256,
                "total": self.total,
                "by_route": {key: self.by_route[key] for key in sorted(self.by_route)},
                "by_status": {key: self.by_status[key] for key in sorted(self.by_status)},
                "delayed": self.delayed,
                "faulted": self.faulted,
                "in_flight": self.in_flight,
                "max_in_flight": self.max_in_flight,
                "declared_response_bytes": {
                    key: self.declared_response_bytes[key]
                    for key in sorted(self.declared_response_bytes)
                },
                "committed_response_bytes": {
                    key: self.committed_response_bytes[key]
                    for key in sorted(self.committed_response_bytes)
                },
                "write_failures": self.write_failures,
                "client_disconnects": self.client_disconnects,
            }


def _route(path: str) -> tuple[str, str | None] | None:
    if path == "/System/Info/Public":
        return "server_info", None
    if path == f"/Users/{USER_ID}/Views":
        return "views", None
    if path == f"/Users/{USER_ID}/Items":
        return "items", None
    if path == f"/Users/{USER_ID}/Items/Resume":
        return "resume", None
    if path == "/Shows/NextUp":
        return "next_up", None
    if path == f"/Users/{USER_ID}/Items/Latest":
        return "latest", None
    parts = path.split("/")
    if len(parts) == 5 and parts[1] == "Items" and parts[3:] == ["Images", "Primary"]:
        return "image", parts[2]
    return None


class FixtureHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "LabstreamFixture/1"
    sys_version = ""
    current_route = "unclassified"

    @property
    def state(self) -> FixtureState:
        return self.server.fixture_state  # type: ignore[attr-defined]

    def log_message(self, _format: str, *_args: Any) -> None:
        # Never echo request targets or headers; the aggregate ledger is the only request log.
        return

    def _write(self, status: int, payload: bytes, content_type: str) -> None:
        declared = len(payload)
        committed = 0
        try:
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(declared))
            self.send_header("Cache-Control", "no-store")
            self.send_header("Connection", "close")
            self.end_headers()
            written = self.wfile.write(payload)
            committed = declared if written is None else written
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, TimeoutError, socket.timeout, OSError):
            if self.current_route in ROUTE_IDS:
                self.state.note_response(self.current_route, declared, committed,
                                         write_failed=True, disconnected=True)
            return
        if self.current_route in ROUTE_IDS:
            self.state.note_response(self.current_route, declared, committed)

    def _json(self, status: int, document: Any) -> None:
        self._write(status, json.dumps(document, sort_keys=True, separators=(",", ":")).encode(),
                    "application/json")

    def _read_json(self) -> Any:
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError as error:
            raise FixtureConfigurationError("invalid content length") from error
        if length <= 0 or length > MAX_BODY_BYTES:
            raise FixtureConfigurationError("control body length is outside the fixture bound")
        if self.headers.get_content_type() != "application/json":
            raise FixtureConfigurationError("control body must be application/json")
        try:
            return json.loads(self.rfile.read(length))
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise FixtureConfigurationError("control body is invalid JSON") from error

    def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        parsed = urlsplit(self.path)
        path = parsed.path
        try:
            if parsed.query:
                raise FixtureConfigurationError("control query is forbidden")
            if path == f"{CONTROL_PREFIX}/reset":
                self.current_route = "control_reset"
                if int(self.headers.get("Content-Length", "0")) != 0:
                    raise FixtureConfigurationError("reset body must be empty")
                self.state.reset()
                self._json(200, {"reset": True})
                return
            if path == f"{CONTROL_PREFIX}/configure":
                self.current_route = "control_configure"
                self.state.configure(self._read_json())
                self._json(200, {"configured": True})
                return
            if path == "/Users/AuthenticateByName":
                self.current_route = "authenticate"
                behavior = self.state.begin("authenticate")
                status = 500
                try:
                    if behavior and behavior.delay_ms:
                        time.sleep(behavior.delay_ms / 1000)
                    if behavior and behavior.status is not None:
                        status = behavior.status
                        self._json(status, {"error": "configured_failure"})
                        return
                    try:
                        document = self._read_json()
                    except FixtureConfigurationError:
                        status = 400
                        self._json(status, {"error": "invalid_auth_shape"})
                        return
                    if not isinstance(document, dict) or set(document) != {"Username", "Pw"}:
                        status = 400
                        self._json(status, {"error": "invalid_auth_shape"})
                    elif document["Username"] != AUTH_USERNAME or document["Pw"] != AUTH_PASSWORD:
                        status = 401
                        self._json(status, {"error": "unauthorized"})
                    else:
                        status = 200
                        self._json(status, {
                            "User": {"Id": USER_ID, "Name": "Fixture User"},
                            "AccessToken": ACCESS_TOKEN,
                            "ServerId": SERVER_ID,
                        })
                    return
                finally:
                    self.state.finish("authenticate", status, behavior)
            self.current_route = "unknown"
            self._json(404, {"error": "closed_route"})
        except (FixtureConfigurationError, ValueError):
            self._json(400, {"error": "invalid_control"})

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        parsed = urlsplit(self.path)
        if parsed.path == f"{CONTROL_PREFIX}/ledger":
            self.current_route = "control_ledger"
            if parsed.query:
                self._json(400, {"error": "closed_query"})
            else:
                self._json(200, self.state.ledger())
            return

        match = _route(parsed.path)
        route, item_id = match if match else ("unknown", None)
        self.current_route = route
        behavior = self.state.begin(route)
        status = 500
        try:
            if behavior and behavior.delay_ms:
                time.sleep(behavior.delay_ms / 1000)
            if behavior and behavior.status is not None:
                status = behavior.status
                self._json(status, {"error": "configured_failure"})
                return
            if match is None:
                status = 404
                self._json(status, {"error": "closed_route"})
                return
            query = parse_qs(parsed.query, keep_blank_values=True)
            if set(query) - QUERY_KEYS[route] or any(len(values) != 1 for values in query.values()):
                status = 400
                self._json(status, {"error": "closed_query"})
                return
            status, document, content_type = self._response(route, item_id, query)
            if content_type == "application/json":
                self._json(status, document)
            else:
                self._write(status, document, content_type)
        except FixtureConfigurationError:
            status = 400
            self._json(status, {"error": "invalid_query"})
        finally:
            self.state.finish(route, status, behavior)

    def _method_not_allowed(self) -> None:
        self._json(405, {"error": "method_not_allowed"})

    do_DELETE = _method_not_allowed
    do_HEAD = _method_not_allowed
    do_PATCH = _method_not_allowed
    do_PUT = _method_not_allowed

    def _response(self, route: str, item_id: str | None,
                  query: dict[str, list[str]]) -> tuple[int, Any, str]:
        if route == "views":
            return 200, {"Items": list(VIEWS), "TotalRecordCount": len(VIEWS)}, "application/json"
        if route == "server_info":
            return 200, {
                "ServerName": "Labstream Fixture", "Version": "4.8.0.0", "Id": SERVER_ID,
            }, "application/json"
        if route == "image":
            return (200, PNG, "image/png") if item_id in ITEM_BY_ID else (
                404, {"error": "unknown_item"}, "application/json")

        if route == "items":
            rows = list(ALL_ITEMS)
        elif route == "resume":
            rows = list(MOVIES[:4] + EPISODES[:4])
        elif route == "next_up":
            rows = list(EPISODES)
        elif route == "latest":
            rows = list(MOVIES[-4:] + EPISODES[-4:])
        else:
            raise AssertionError(route)

        parent = query.get("ParentId", [None])[0]
        if parent:
            rows = [item for item in rows if item.get("ParentId") == parent]
        item_types = query.get("IncludeItemTypes", [""])[0]
        if item_types:
            allowed = set(item_types.split(","))
            rows = [item for item in rows if item["Type"] in allowed]
        search = query.get("SearchTerm", [""])[0].casefold()
        if search:
            rows = [item for item in rows if search in item["Name"].casefold()]
        prefix = query.get("NameStartsWith", [""])[0].casefold()
        if prefix:
            rows = [item for item in rows if item["SortName"].casefold().startswith(prefix)]

        total = len(rows)
        start = _bounded_int(query.get("StartIndex", [None])[0], 0, maximum=MAX_QUERY_INTEGER)
        limit = _bounded_int(query.get("Limit", [None])[0], total, maximum=MAX_QUERY_INTEGER)
        rows = rows[start:start + limit]
        if route == "latest":
            return 200, rows, "application/json"
        return 200, {"Items": rows, "TotalRecordCount": total}, "application/json"


class FixtureServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = False

    def __init__(self, bind: str = BIND, port: int = 0, state: FixtureState | None = None,
                 *, max_handlers: int = MAX_ACTIVE_HANDLERS,
                 connection_timeout: float = CONNECTION_TIMEOUT_SECONDS) -> None:
        validate_bind(bind)
        if not isinstance(port, int) or isinstance(port, bool) or not 0 <= port <= 65535:
            raise FixtureConfigurationError("port must be in 0...65535")
        if not isinstance(max_handlers, int) or isinstance(max_handlers, bool) or not 1 <= max_handlers <= 64:
            raise FixtureConfigurationError("max_handlers is outside the fixture bound")
        if not isinstance(connection_timeout, (int, float)) or not 0.05 <= connection_timeout <= 10:
            raise FixtureConfigurationError("connection_timeout is outside the fixture bound")
        self.fixture_state = state or FixtureState()
        self.connection_timeout = float(connection_timeout)
        self._handler_slots = threading.BoundedSemaphore(max_handlers)
        self._handler_lock = threading.Lock()
        self._active_handlers = 0
        super().__init__((bind, port), FixtureHandler)

    @property
    def active_handlers(self) -> int:
        with self._handler_lock:
            return self._active_handlers

    def process_request(self, request: Any, client_address: Any) -> None:
        request.settimeout(self.connection_timeout)
        if not self._handler_slots.acquire(blocking=False):
            payload = b'{"error":"overloaded"}'
            response = (
                b"HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\n"
                + f"Content-Length: {len(payload)}\r\nConnection: close\r\n\r\n".encode()
                + payload
            )
            committed = 0
            try:
                request.sendall(response)
                committed = len(payload)
            except (BrokenPipeError, ConnectionResetError, TimeoutError, socket.timeout, OSError):
                self.fixture_state.note_response("overload", len(payload), committed,
                                                 write_failed=True, disconnected=True)
            else:
                self.fixture_state.note_response("overload", len(payload), committed)
            finally:
                self.fixture_state.finish("overload", 503, None, was_begun=False)
                self.close_request(request)
            return
        with self._handler_lock:
            self._active_handlers += 1
        try:
            super().process_request(request, client_address)
        except BaseException:
            with self._handler_lock:
                self._active_handlers -= 1
            self._handler_slots.release()
            raise

    def process_request_thread(self, request: Any, client_address: Any) -> None:
        try:
            super().process_request_thread(request, client_address)
        finally:
            with self._handler_lock:
                self._active_handlers -= 1
            self._handler_slots.release()

    def handle_error(self, _request: Any, _client_address: Any) -> None:
        # Client disconnects must not make BaseServer print request-adjacent diagnostics.
        return

    @property
    def base_url(self) -> str:
        return f"http://{BIND}:{self.server_port}"


class SafeArgumentParser(argparse.ArgumentParser):
    def error(self, _message: str) -> None:
        # argparse's default repeats unknown argument values, which could echo a mistakenly
        # supplied credential. Keep all configuration rejection deliberately content-free.
        self.exit(2, f"{self.prog}: fixture configuration rejected\n")


def parser() -> argparse.ArgumentParser:
    result = SafeArgumentParser(description=__doc__)
    result.add_argument("--bind", default=BIND)
    result.add_argument("--port", type=int, default=0)
    result.add_argument("--parent-pid", type=int)
    result.add_argument("--ready-file", type=Path)
    return result


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    if (args.parent_pid is not None
            and (args.parent_pid <= 1 or os.getppid() != args.parent_pid)):
        parser().error("invalid parent process")
    try:
        server = FixtureServer(args.bind, args.port)
    except FixtureConfigurationError as error:
        parser().error(str(error))
    ready = {
        "schema_version": 1,
        "base_url": server.base_url,
        "fixture_id": FIXTURE_ID,
        "fixture_sha256": CORPUS_SHA256,
        "user_id": USER_ID,
    }
    encoded = json.dumps(ready, sort_keys=True, separators=(",", ":")) + "\n"
    if args.ready_file:
        args.ready_file.write_text(encoded)
    else:
        print(encoded, end="", flush=True)

    stopping = threading.Event()
    for signum in (signal.SIGINT, signal.SIGTERM):
        signal.signal(signum, lambda *_args: stopping.set())
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        while not stopping.wait(0.2):
            if args.parent_pid is not None and os.getppid() != args.parent_pid:
                break
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
