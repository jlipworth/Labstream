from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest import mock
from _script_loader import load_script


ROOT = Path(__file__).resolve().parents[2]
asc = load_script("asc_screenshots", ROOT / "scripts" / "asc-screenshots.py")


class Client:
    """Records App Store Connect calls; one existing iPhone 6.3-inch set with one screenshot."""

    app_id = "app"

    def __init__(self) -> None:
        self.calls: list[tuple[str, str, object]] = []

    def request(self, method, path, params=None, body=None):
        self.calls.append((method, path, body))
        if path.endswith("/appStoreVersions"):
            return {"data": [{"id": "ver", "attributes": {"versionString": "1.8.0",
                                                          "appStoreState": "PREPARE_FOR_SUBMISSION"}}]}
        if path.endswith("/appStoreVersionLocalizations"):
            return {"data": [{"id": "loc", "attributes": {"locale": "en-US"}}]}
        if path.endswith("/appScreenshotSets") and method == "GET":
            return {"data": [{"id": "set61", "attributes": {"screenshotDisplayType": "APP_IPHONE_61"},
                              "relationships": {"appScreenshots": {"data": [{"id": "old"}]}}}],
                    "included": [{"type": "appScreenshots", "id": "old", "attributes": {"fileName": "old.jpg"}}]}
        if path == "/v1/appScreenshotSets":
            return {"data": {"id": "set67"}}
        if path == "/v1/appScreenshots":
            return {"data": {"id": "new", "attributes": {"uploadOperations": []}}}
        return {}


class ASCScreenshotTests(unittest.TestCase):
    def _export(self, root: Path, *names: str) -> Path:
        root.mkdir(parents=True)
        for name in names:
            (root / name).write_bytes(b"jpeg")
        return root

    def test_plan_maps_targets_and_rejects_unmapped_or_wrong_sized_files(self) -> None:
        with tempfile.TemporaryDirectory() as directory, \
                mock.patch.object(asc, "image_size", return_value=(1320, 2868, False)):
            large = self._export(Path(directory) / "a", "iphone69-01-home-1320x2868.jpg",
                                 "iphone69-02-library-1320x2868.jpg")
            sets = asc.plan([large])
            self.assertEqual(list(sets), [("ios", "APP_IPHONE_67")])
            self.assertEqual([f.name for f in sets[("ios", "APP_IPHONE_67")]],
                             ["iphone69-01-home-1320x2868.jpg", "iphone69-02-library-1320x2868.jpg"])
            # The same pixels under the 6.3-inch prefix are the wrong size for that set.
            with self.assertRaisesRegex(asc.ScreenshotError, "not accepted for APP_IPHONE_61"):
                asc.plan([self._export(Path(directory) / "b", "iphone-01-home-1320x2868.jpg")])
            with self.assertRaisesRegex(asc.ScreenshotError, "no screenshot set is mapped"):
                asc.plan([self._export(Path(directory) / "c", "duo-outer-01-home-1398x2034.jpg")])
        with tempfile.TemporaryDirectory() as directory, \
                mock.patch.object(asc, "image_size", return_value=(2560, 1600, True)):
            with self.assertRaisesRegex(asc.ScreenshotError, "alpha=True"):
                asc.plan([self._export(Path(directory) / "d", "macos-01-home-2560x1600.jpg")])

    def test_upload_without_yes_never_contacts_app_store_connect(self) -> None:
        with tempfile.TemporaryDirectory() as directory, \
                mock.patch.object(asc, "image_size", return_value=(1206, 2622, False)), \
                mock.patch.object(asc.meta, "with_client", side_effect=AssertionError("contacted")):
            export = self._export(Path(directory) / "a", "iphone-01-home-1206x2622.jpg")
            self.assertEqual(asc.main(["upload", str(export)]), 0)

    def test_upload_replaces_an_existing_set_and_creates_a_missing_one(self) -> None:
        client = Client()
        sizes = {"iphone-01-home-1206x2622.jpg": (1206, 2622, False),
                 "iphone69-01-home-1320x2868.jpg": (1320, 2868, False)}
        with tempfile.TemporaryDirectory() as directory, \
                mock.patch.object(asc, "image_size", side_effect=lambda path: sizes[path.name]), \
                mock.patch.object(asc.meta, "with_client", side_effect=lambda args, action: action(client)):
            small = self._export(Path(directory) / "a", "iphone-01-home-1206x2622.jpg")
            large = self._export(Path(directory) / "b", "iphone69-01-home-1320x2868.jpg")
            self.assertEqual(asc.main(["upload", str(small), str(large), "--yes"]), 0)
        writes = [(method, path) for method, path, _ in client.calls if method != "GET"]
        self.assertEqual(writes, [
            ("DELETE", "/v1/appScreenshots/old"),
            ("POST", "/v1/appScreenshots"), ("PATCH", "/v1/appScreenshots/new"),
            ("POST", "/v1/appScreenshotSets"),
            ("POST", "/v1/appScreenshots"), ("PATCH", "/v1/appScreenshots/new"),
        ])
        created = [body for method, path, body in client.calls if method == "POST" and path == "/v1/appScreenshots"]
        self.assertEqual([b["data"]["relationships"]["appScreenshotSet"]["data"]["id"] for b in created],
                         ["set61", "set67"])


if __name__ == "__main__":
    unittest.main()
