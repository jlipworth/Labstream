import concurrent.futures
import contextlib
import io
import importlib.util
import json
import os
import pathlib
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request


SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "perf-emby-browse-fixture.py"
SPEC = importlib.util.spec_from_file_location("perf_emby_browse_fixture", SCRIPT)
FIXTURE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = FIXTURE
SPEC.loader.exec_module(FIXTURE)


class PerfEmbyBrowseFixtureTests(unittest.TestCase):
    def setUp(self):
        self.server = FIXTURE.FixtureServer()
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def request(self, path, *, method="GET", document=None, headers=None):
        data = None if document is None else json.dumps(document).encode()
        request = urllib.request.Request(self.server.base_url + path, data=data, method=method,
                                         headers=headers or {})
        if document is not None:
            request.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(request, timeout=2) as response:
                return response.status, response.headers, response.read()
        except urllib.error.HTTPError as error:
            try:
                return error.code, error.headers, error.read()
            finally:
                error.close()

    def json_request(self, path, **kwargs):
        status, _headers, payload = self.request(path, **kwargs)
        return status, json.loads(payload)

    def test_loopback_and_control_configuration_fail_closed(self):
        for bind in ("0.0.0.0", "localhost", "192.0.2.1", "::1"):
            with self.subTest(bind=bind), self.assertRaises(FIXTURE.FixtureConfigurationError):
                FIXTURE.FixtureServer(bind=bind)

        status, payload = self.json_request("/__fixture__/configure", method="POST", document={
            "route": "items", "delay_ms": 0, "status": 503, "remaining": 1,
            "token": "must-never-be-configurable",
        })
        self.assertEqual((status, payload), (400, {"error": "invalid_control"}))

    def test_parent_watchdog_stops_orphaned_fixture(self):
        with tempfile.TemporaryDirectory() as temporary:
            ready = pathlib.Path(temporary) / "ready.json"
            code = (
                "import os,subprocess,sys; "
                "p=subprocess.Popen([sys.executable,sys.argv[1],'--ready-file',sys.argv[2],"
                "'--parent-pid',str(os.getpid())],stdout=subprocess.DEVNULL,"
                "stderr=subprocess.DEVNULL); print(p.pid,flush=True)"
            )
            pid = int(subprocess.check_output(
                [sys.executable, "-c", code, str(SCRIPT), str(ready)], text=True).strip())
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                try:
                    os.kill(pid, 0)
                except ProcessLookupError:
                    break
                time.sleep(0.05)
            else:
                os.kill(pid, 9)
                self.fail("orphaned fixture did not stop after its parent exited")
        self.assertEqual(self.json_request(f"/Users/{FIXTURE.USER_ID}/Items", method="DELETE")[0], 405)
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr), self.assertRaises(SystemExit):
            FIXTURE.parser().parse_args(["--token", "must-not-be-echoed"])
        self.assertNotIn("must-not-be-echoed", stderr.getvalue())
        status, payload = self.json_request("/__fixture__/configure", method="POST", document={
            "route": "playback", "delay_ms": 0, "status": 503, "remaining": 1,
        })
        self.assertEqual((status, payload), (400, {"error": "invalid_control"}))

    def test_closed_corpus_routes_paging_search_and_artwork(self):
        self.assertEqual(FIXTURE.ROUTE_IDS,
                         {"server_info", "authenticate", "views", "items", "resume",
                          "next_up", "latest", "image"})
        self.assertEqual(FIXTURE.FIXTURE_ID, "fixture-c7e220a53061")
        self.assertEqual(FIXTURE.CORPUS_SHA256,
                         "c7e220a5306189014d97303c016fda8ac404c9a639332c01c9a201d97dd19267")
        status, views = self.json_request(f"/Users/{FIXTURE.USER_ID}/Views?IncludeExternalContent=false")
        self.assertEqual(status, 200)
        self.assertEqual([row["Id"] for row in views["Items"]],
                         ["library-movies", "library-shows"])

        status, page = self.json_request(
            f"/Users/{FIXTURE.USER_ID}/Items?ParentId=library-movies&StartIndex=2&Limit=3"
        )
        self.assertEqual(status, 200)
        self.assertEqual(page["TotalRecordCount"], 26)
        self.assertEqual([row["Id"] for row in page["Items"]],
                         ["movie-02", "movie-03", "movie-04"])

        production_query = (
            "IncludeItemTypes=Movie&Fields=PrimaryImageAspectRatio,ImageTags&"
            "EnableUserData=true&SortBy=SortName&SortOrder=Ascending&ParentId=library-movies&"
            "Recursive=true&StartIndex=0&Limit=200"
        )
        status, production_page = self.json_request(
            f"/Users/{FIXTURE.USER_ID}/Items?{production_query}")
        self.assertEqual(status, 200)
        self.assertEqual((len(production_page["Items"]), production_page["TotalRecordCount"]),
                         (26, 26))
        status, beyond = self.json_request(
            f"/Users/{FIXTURE.USER_ID}/Items?{production_query.replace('StartIndex=0', 'StartIndex=200')}")
        self.assertEqual((status, beyond), (200, {"Items": [], "TotalRecordCount": 26}))

        status, search = self.json_request(
            f"/Users/{FIXTURE.USER_ID}/Items?SearchTerm=Z%20Fixture&IncludeItemTypes=Movie"
        )
        self.assertEqual(status, 200)
        self.assertEqual([row["Id"] for row in search["Items"]], ["movie-25"])
        status, prefix = self.json_request(
            f"/Users/{FIXTURE.USER_ID}/Items?ParentId=library-movies&NameStartsWith=A&Limit=1"
        )
        self.assertEqual((status, prefix["TotalRecordCount"]), (200, 1))

        for path, envelope in (
            (f"/Users/{FIXTURE.USER_ID}/Items/Resume?Limit=2", True),
            (f"/Shows/NextUp?UserId={FIXTURE.USER_ID}&Limit=2", True),
            (f"/Users/{FIXTURE.USER_ID}/Items/Latest?Limit=2", False),
        ):
            status, payload = self.json_request(path)
            self.assertEqual(status, 200)
            self.assertEqual(len(payload["Items"] if envelope else payload), 2)

        status, headers, image = self.request(
            f"/Items/movie-00/Images/Primary?tag={FIXTURE.IMAGE_TAG}&width=200&height=300")
        self.assertEqual((status, headers.get_content_type(), image), (200, "image/png", FIXTURE.PNG))
        self.assertEqual(self.json_request(
            "/Items/movie-00/Images/Primary?Tag=x&Width=200&Height=300")[0], 400)
        self.assertEqual(self.json_request("/not-a-route")[0], 404)
        self.assertEqual(self.json_request(f"/Users/{FIXTURE.USER_ID}/Items?api_key=secret")[0], 400)
        self.assertEqual(self.json_request(
            f"/Users/{FIXTURE.USER_ID}/Items?Limit=1&Limit=2")[0], 400)

    def test_fault_delay_reset_and_ledger_are_aggregate_and_privacy_safe(self):
        status, payload = self.json_request("/__fixture__/configure", method="POST", document={
            "route": "items", "delay_ms": 80, "status": 503, "remaining": 1,
        })
        self.assertEqual((status, payload), (200, {"configured": True}))
        started = time.monotonic()
        status, _ = self.json_request(
            f"/Users/{FIXTURE.USER_ID}/Items?SearchTerm=private-value",
            headers={"Authorization": "secret-header-value"},
        )
        self.assertEqual(status, 503)
        self.assertGreaterEqual(time.monotonic() - started, 0.06)
        self.assertEqual(self.json_request(f"/Users/{FIXTURE.USER_ID}/Items")[0], 200)

        self.assertEqual(self.json_request("/__fixture__/configure", method="POST", document={
            "route": "views", "delay_ms": 10, "status": None, "remaining": 1,
        })[0], 200)
        self.assertEqual(self.json_request(f"/Users/{FIXTURE.USER_ID}/Views")[0], 200)

        status, ledger = self.json_request("/__fixture__/ledger")
        self.assertEqual(status, 200)
        self.assertEqual(ledger["by_route"], {"items": 2, "views": 1})
        self.assertEqual(ledger["by_status"], {"200": 2, "503": 1})
        self.assertEqual((ledger["faulted"], ledger["delayed"]), (1, 2))
        encoded = json.dumps(ledger)
        for forbidden in ("private-value", "secret-header-value", "SearchTerm", "Authorization"):
            self.assertNotIn(forbidden, encoded)

        self.assertEqual(self.json_request("/__fixture__/reset", method="POST")[0], 200)
        self.assertEqual(self.json_request("/__fixture__/ledger")[1]["total"], 0)
        self.assertEqual(self.json_request(f"/Users/{FIXTURE.USER_ID}/Items")[0], 200)

    def test_production_authentication_shapes_use_only_fixed_synthetic_credentials(self):
        status, info = self.json_request("/System/Info/Public")
        self.assertEqual(status, 200)
        self.assertEqual(info, {
            "Id": FIXTURE.SERVER_ID, "ServerName": "Labstream Fixture", "Version": "4.8.0.0",
        })
        status, auth = self.json_request(
            "/Users/AuthenticateByName", method="POST",
            document={"Username": FIXTURE.AUTH_USERNAME, "Pw": FIXTURE.AUTH_PASSWORD},
            headers={"Authorization": "Emby Client=fixture"},
        )
        self.assertEqual(status, 200)
        self.assertEqual(auth, {
            "AccessToken": FIXTURE.ACCESS_TOKEN,
            "ServerId": FIXTURE.SERVER_ID,
            "User": {"Id": FIXTURE.USER_ID, "Name": "Fixture User"},
        })
        self.assertEqual(self.json_request(
            "/Users/AuthenticateByName", method="POST",
            document={"Username": "wrong", "Pw": "wrong"})[0], 401)
        ledger = self.json_request("/__fixture__/ledger")[1]
        self.assertEqual(ledger["by_route"], {"authenticate": 2, "server_info": 1})
        encoded = json.dumps(ledger)
        self.assertNotIn(FIXTURE.AUTH_PASSWORD, encoded)
        self.assertNotIn(FIXTURE.ACCESS_TOKEN, encoded)

    def test_handler_limit_timeout_and_overload_are_deterministic(self):
        limited = FIXTURE.FixtureServer(max_handlers=2, connection_timeout=0.2)
        thread = threading.Thread(target=limited.serve_forever, daemon=True)
        thread.start()
        holders = []
        try:
            for _ in range(2):
                sock = socket.create_connection((FIXTURE.BIND, limited.server_port), timeout=1)
                holders.append(sock)
            deadline = time.monotonic() + 1
            while limited.active_handlers != 2 and time.monotonic() < deadline:
                time.sleep(0.005)
            self.assertEqual(limited.active_handlers, 2)
            with socket.create_connection((FIXTURE.BIND, limited.server_port), timeout=1) as client:
                client.sendall(b"GET /System/Info/Public HTTP/1.1\r\nHost: fixture\r\n\r\n")
                response = client.recv(4096)
            self.assertIn(b"503 Service Unavailable", response)
            deadline = time.monotonic() + 1
            while limited.active_handlers and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertEqual(limited.active_handlers, 0)
            ledger = limited.fixture_state.ledger()
            self.assertEqual(ledger["by_route"], {"overload": 1})
            self.assertEqual(ledger["by_status"], {"503": 1})
        finally:
            for sock in holders:
                sock.close()
            limited.shutdown()
            limited.server_close()
            thread.join()

    def test_response_byte_ledger_and_forced_disconnect_are_aggregate(self):
        self.assertEqual(self.json_request("/__fixture__/configure", method="POST", document={
            "route": "latest", "delay_ms": 100, "status": None, "remaining": 1,
        })[0], 200)
        client = socket.create_connection((FIXTURE.BIND, self.server.server_port), timeout=1)
        client.sendall(
            f"GET /Users/{FIXTURE.USER_ID}/Items/Latest?Limit=2 HTTP/1.1\r\n"
            "Host: fixture\r\nConnection: close\r\n\r\n".encode()
        )
        client.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
        client.close()
        deadline = time.monotonic() + 2
        ledger = {}
        while time.monotonic() < deadline:
            ledger = self.json_request("/__fixture__/ledger")[1]
            if ledger["client_disconnects"]:
                break
            time.sleep(0.02)
        self.assertGreaterEqual(ledger["write_failures"], 1)
        self.assertGreaterEqual(ledger["client_disconnects"], 1)
        self.assertGreater(ledger["declared_response_bytes"]["latest"], 0)
        self.assertLessEqual(ledger["committed_response_bytes"]["latest"],
                             ledger["declared_response_bytes"]["latest"])
        encoded = json.dumps(ledger)
        self.assertNotIn("Items/Latest", encoded)

    def test_delay_ledger_observes_bounded_concurrency_without_request_details(self):
        self.assertEqual(self.json_request("/__fixture__/configure", method="POST", document={
            "route": "image", "delay_ms": 60, "status": 429, "remaining": 4,
        })[0], 200)
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
            statuses = list(executor.map(
                lambda _: self.request("/Items/movie-00/Images/Primary")[0], range(4)
            ))
        self.assertEqual(statuses, [429] * 4)
        ledger = self.json_request("/__fixture__/ledger")[1]
        self.assertEqual(ledger["by_route"], {"image": 4})
        self.assertGreaterEqual(ledger["max_in_flight"], 2)


if __name__ == "__main__":
    unittest.main()
