#!/usr/bin/env python3
"""List and upload Labstream's App Store screenshots through the App Store Connect API.

  scripts/asc-screenshots.py status
  scripts/asc-screenshots.py upload EXPORT_DIR [EXPORT_DIR ...]          # prints the plan
  scripts/asc-screenshots.py upload EXPORT_DIR [EXPORT_DIR ...] --yes    # replaces the sets

An export directory is the `export` folder of an app-store-screenshots.py session. The file-name
prefix names the capture target, which decides the platform and the screenshot set:

  iphone    -> iOS       APP_IPHONE_61           (6.3-inch class)
  iphone69  -> iOS       APP_IPHONE_67           (6.9-inch class)
  ipad      -> iOS       APP_IPAD_PRO_3GEN_129   (13-inch class)
  tvos      -> tvOS      APP_APPLE_TV
  visionos  -> visionOS  APP_APPLE_VISION_PRO
  macos     -> macOS     APP_DESKTOP

iPhone Duo exports are refused: no screenshot set for that display is confirmed yet.

`upload --yes` replaces every screenshot in each named set of the editable version's locale
(default en-US) with the directory's JPEGs in file-name order. It needs the release owner's
go-ahead, like every other App Store Connect write, and never submits anything for review.
Credentials reuse scripts/testflight-release.py; nothing secret is printed.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import pathlib
import subprocess
import sys
import urllib.error
import urllib.request
from typing import Any

REPO = pathlib.Path(__file__).resolve().parents[1]


def _load(name: str, file: str) -> Any:
    spec = importlib.util.spec_from_file_location(name, REPO / "scripts" / file)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


meta = _load("_asc_screenshots_metadata", "asc-metadata.py")
tf = meta.tf

# capture target -> (asc-metadata platform key, screenshotDisplayType, accepted pixel sizes)
TARGETS: dict[str, tuple[str, str, frozenset[tuple[int, int]]]] = {
    "iphone": ("ios", "APP_IPHONE_61", frozenset({(1206, 2622), (2622, 1206), (1179, 2556), (2556, 1179)})),
    "iphone69": ("ios", "APP_IPHONE_67", frozenset({(1320, 2868), (2868, 1320), (1290, 2796), (2796, 1290),
                                                    (1260, 2736), (2736, 1260)})),
    "ipad": ("ios", "APP_IPAD_PRO_3GEN_129", frozenset({(2064, 2752), (2752, 2064), (2048, 2732), (2732, 2048)})),
    "tvos": ("tvos", "APP_APPLE_TV", frozenset({(3840, 2160), (1920, 1080)})),
    "visionos": ("visionos", "APP_APPLE_VISION_PRO", frozenset({(3840, 2160)})),
    "macos": ("macos", "APP_DESKTOP", frozenset({(2560, 1600), (2880, 1800), (1440, 900), (1280, 800)})),
}


class ScreenshotError(RuntimeError):
    pass


def image_size(path: pathlib.Path) -> tuple[int, int, bool]:
    out = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", "-g", "hasAlpha", str(path)],
                         text=True, capture_output=True, check=True).stdout
    values = dict(line.strip().split(": ", 1) for line in out.splitlines() if ": " in line)
    return int(values["pixelWidth"]), int(values["pixelHeight"]), values["hasAlpha"] == "yes"


def plan(export_dirs: list[pathlib.Path]) -> dict[tuple[str, str], list[pathlib.Path]]:
    """Group each directory's JPEGs by (platform, display type); reject anything not uploadable."""
    sets: dict[tuple[str, str], list[pathlib.Path]] = {}
    for directory in export_dirs:
        files = sorted(directory.glob("*.jpg"))
        if not files:
            raise ScreenshotError(f"{directory}: no .jpg files")
        if not 1 <= len(files) <= 10:
            raise ScreenshotError(f"{directory}: a set holds one to ten screenshots, found {len(files)}")
        for file in files:
            target = max((t for t in TARGETS if file.name.startswith(t + "-")), key=len, default=None)
            if target is None:
                raise ScreenshotError(f"{file.name}: no screenshot set is mapped for this capture target")
            platform, display, sizes = TARGETS[target]
            width, height, alpha = image_size(file)
            if (width, height) not in sizes or alpha:
                raise ScreenshotError(f"{file.name}: {width}x{height}, alpha={alpha} is not accepted for {display}")
            sets.setdefault((platform, display), []).append(file)
    for (platform, display), files in sets.items():
        if len({f.parent for f in files}) > 1:
            raise ScreenshotError(f"{platform} {display}: more than one directory supplies this set")
    return sets


def localization(client: Any, platform: str, version: str | None, locale: str) -> dict[str, Any]:
    ver = meta.editable_version(client, meta.PLATFORMS[platform], version)
    if ver is None:
        raise ScreenshotError(f"{platform}: no editable App Store version")
    locs = client.request("GET", f"/v1/appStoreVersions/{ver['id']}/appStoreVersionLocalizations")["data"]
    for loc in locs:
        if loc["attributes"]["locale"] == locale:
            return {"id": loc["id"], "version": ver["attributes"]["versionString"]}
    raise ScreenshotError(f"{platform}: version {ver['attributes']['versionString']} has no {locale} localization")


def screenshot_sets(client: Any, localization_id: str) -> dict[str, dict[str, Any]]:
    data = client.request("GET", f"/v1/appStoreVersionLocalizations/{localization_id}/appScreenshotSets",
                          {"include": "appScreenshots", "limit": "50", "limit[appScreenshots]": "50"})
    shots = {item["id"]: item for item in data.get("included", []) if item["type"] == "appScreenshots"}
    out = {}
    for item in data["data"]:
        ids = [ref["id"] for ref in item["relationships"]["appScreenshots"]["data"]]
        out[item["attributes"]["screenshotDisplayType"]] = {
            "id": item["id"], "screenshots": [shots[i] for i in ids if i in shots]}
    return out


def cmd_status(args: argparse.Namespace) -> int:
    def action(client: Any) -> int:
        for platform in args.platform or sorted(meta.PLATFORMS):
            try:
                loc = localization(client, platform, args.version, args.locale)
            except ScreenshotError as error:
                print(f"{platform}: {error}")
                continue
            sets = screenshot_sets(client, loc["id"])
            print(f"{platform} {loc['version']} ({args.locale}): {len(sets)} screenshot set(s)")
            for display, value in sorted(sets.items()):
                print(f"  {display}: {len(value['screenshots'])}")
                for shot in value["screenshots"]:
                    attributes = shot["attributes"]
                    state = (attributes.get("assetDeliveryState") or {}).get("state")
                    print(f"    {attributes.get('fileName')}  {state}")
        return 0
    return meta.with_client(args, action)


def upload_file(client: Any, set_id: str, file: pathlib.Path) -> None:
    payload = file.read_bytes()
    created = client.request("POST", "/v1/appScreenshots", body={"data": {
        "type": "appScreenshots",
        "attributes": {"fileName": file.name, "fileSize": len(payload)},
        "relationships": {"appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": set_id}}}}})["data"]
    for operation in created["attributes"]["uploadOperations"]:
        chunk = payload[operation["offset"]:operation["offset"] + operation["length"]]
        request = urllib.request.Request(operation["url"], data=chunk, method=operation["method"])
        for header in operation.get("requestHeaders") or []:
            request.add_header(header["name"], header["value"])
        try:
            with urllib.request.urlopen(request, timeout=300):
                pass
        except urllib.error.HTTPError as error:
            raise ScreenshotError(f"{file.name}: upload part refused (HTTP {error.code})") from None
    client.request("PATCH", f"/v1/appScreenshots/{created['id']}", body={"data": {
        "type": "appScreenshots", "id": created["id"],
        "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(payload).hexdigest()}}})


def cmd_upload(args: argparse.Namespace) -> int:
    sets = plan([pathlib.Path(d) for d in args.export_dirs])
    for (platform, display), files in sorted(sets.items()):
        print(f"{platform} {display}: replace with {len(files)} from {files[0].parent}")
        for file in files:
            print(f"    {file.name}")
    if not args.yes:
        print("Plan only. Re-run with --yes to replace these sets in App Store Connect.")
        return 0

    def action(client: Any) -> int:
        for (platform, display), files in sorted(sets.items()):
            loc = localization(client, platform, args.version, args.locale)
            existing = screenshot_sets(client, loc["id"]).get(display)
            if existing is None:
                set_id = client.request("POST", "/v1/appScreenshotSets", body={"data": {
                    "type": "appScreenshotSets", "attributes": {"screenshotDisplayType": display},
                    "relationships": {"appStoreVersionLocalization": {
                        "data": {"type": "appStoreVersionLocalizations", "id": loc["id"]}}}}})["data"]["id"]
            else:
                set_id = existing["id"]
                for shot in existing["screenshots"]:
                    client.request("DELETE", f"/v1/appScreenshots/{shot['id']}")
            for file in files:
                upload_file(client, set_id, file)
            print(f"uploaded {platform} {display}: {len(files)}")
        return 0
    return meta.with_client(args, action)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    for name, handler in (("status", cmd_status), ("upload", cmd_upload)):
        p = sub.add_parser(name)
        p.add_argument("--version", help="marketing version (default: each platform's editable version)")
        p.add_argument("--locale", default="en-US")
        p.set_defaults(handler=handler)
    sub.choices["status"].add_argument("--platform", action="append", choices=sorted(meta.PLATFORMS))
    sub.choices["upload"].add_argument("export_dirs", nargs="+")
    sub.choices["upload"].add_argument("--yes", action="store_true", help="replace the sets (owner go-ahead)")
    args = parser.parse_args(argv)
    try:
        return args.handler(args)
    except (ScreenshotError, meta.MetadataError, tf.ReleaseError) as error:
        print(f"asc-screenshots: {meta.scrub(str(error))}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
