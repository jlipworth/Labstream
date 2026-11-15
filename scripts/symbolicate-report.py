#!/usr/bin/env python3
"""Resolve the crash frames in a Labstream diagnostic report against a build's dSYM.

A report's MetricKit section lists the crashed thread as `Binary +0x<offset>` lines, where the
offset is the position inside that binary's text segment, plus an `app binary UUID` line.
MetricKit supplies no symbol names, so this turns the app's own frames into function names with
`atos`. System frames (SwiftUI, libswiftCore, …) are left as they are.

Find the dSYM in the Xcode archive for the reported build (Organizer ▸ Show in Finder ▸ Show
Package Contents ▸ dSYMs), or pass the .xcarchive and the script picks the app's dSYM.

Examples:
  pbpaste | scripts/symbolicate-report.py --archive ~/Library/Developer/Xcode/Archives/…/Labstream.xcarchive
  scripts/symbolicate-report.py report.txt --dsym Labstream.app.dSYM --binary Labstream
"""
from __future__ import annotations

import argparse
import pathlib
import re
import subprocess
import sys

FRAME = re.compile(r"^(?P<indent>\s+)(?P<binary>\S+) \+0x(?P<offset>[0-9a-fA-F]+)\s*$")
UUID_LINE = re.compile(r"app binary UUID:\s*([0-9A-Fa-f-]{36})")


def dwarf_file(dsym: pathlib.Path) -> pathlib.Path:
    files = sorted((dsym / "Contents" / "Resources" / "DWARF").glob("*"))
    if not files:
        raise SystemExit(f"no DWARF file inside {dsym}")
    return files[0]


def dsym_in_archive(archive: pathlib.Path, binary: str | None) -> pathlib.Path:
    found = sorted((archive / "dSYMs").glob("*.app.dSYM"))
    if binary:
        found = [path for path in found if dwarf_file(path).name == binary] or found
    if not found:
        raise SystemExit(f"no .app.dSYM under {archive}/dSYMs")
    return found[0]


def text_vmaddr(dwarf: pathlib.Path, arch: str) -> int:
    """The __TEXT segment's link-time address: an offset into the segment is relative to it."""
    out = subprocess.run(["otool", "-arch", arch, "-l", str(dwarf)], capture_output=True, text=True).stdout
    match = re.search(r"segname __TEXT\s+vmaddr (0x[0-9a-fA-F]+)", out)
    return int(match.group(1), 16) if match else 0


def dsym_uuids(dwarf: pathlib.Path) -> set[str]:
    out = subprocess.run(["dwarfdump", "--uuid", str(dwarf)], capture_output=True, text=True).stdout
    return {match.upper() for match in re.findall(r"UUID: ([0-9A-Fa-f-]{36})", out)}


def frame_addresses(lines: list[str], binary: str, base: int) -> dict[int, str]:
    """Line index -> unslid address, for frames belonging to `binary`."""
    out = {}
    for index, line in enumerate(lines):
        match = FRAME.match(line)
        if match and match.group("binary") == binary:
            out[index] = hex(base + int(match.group("offset"), 16))
    return out


def symbolicate(lines: list[str], binary: str, dwarf: pathlib.Path, arch: str) -> list[str]:
    addresses = frame_addresses(lines, binary, text_vmaddr(dwarf, arch))
    if not addresses:
        return lines
    result = subprocess.run(["atos", "-arch", arch, "-o", str(dwarf), *addresses.values()],
                            capture_output=True, text=True)
    names = result.stdout.splitlines()
    if result.returncode or len(names) != len(addresses):
        raise SystemExit(f"atos failed: {result.stderr.strip()[:200]}")
    out = list(lines)
    for (index, _), name in zip(addresses.items(), names):
        out[index] = f"{lines[index].rstrip()}  →  {name}"
    return out


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("report", nargs="?", help="report text file; stdin when omitted")
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--dsym", type=pathlib.Path)
    source.add_argument("--archive", type=pathlib.Path)
    parser.add_argument("--binary", help="app executable name; default: the dSYM's DWARF file name")
    parser.add_argument("--arch", default="arm64")
    args = parser.parse_args(argv)

    text = pathlib.Path(args.report).read_text() if args.report else sys.stdin.read()
    dsym = args.dsym or dsym_in_archive(args.archive, args.binary)
    dwarf = dwarf_file(dsym)
    binary = args.binary or dwarf.name
    reported = {match.upper() for match in UUID_LINE.findall(text)}
    have = dsym_uuids(dwarf)
    if reported and not reported & have:
        print(f"warning: the report's app binary UUID is not in this dSYM ({', '.join(sorted(have)) or 'none read'}); "
              "the names below are probably wrong — use the archive for the reported build", file=sys.stderr)
    sys.stdout.write("\n".join(symbolicate(text.splitlines(), binary, dwarf, args.arch)) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
