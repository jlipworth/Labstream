#!/usr/bin/env python3
"""Enforce the trust boundary for the native Woodpecker workflow."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


REQUIRED_LABELS = {
    "platform": "darwin/arm64",
    "backend": "local",
    "purpose": "mac-ci",
}


def block(lines: list[str], name: str) -> list[str]:
    start = next(
        (index for index, line in enumerate(lines) if line.rstrip() == f"{name}:"),
        None,
    )
    if start is None:
        raise ValueError(f"missing top-level {name}: block")
    result: list[str] = []
    for line in lines[start + 1 :]:
        if line.strip() and not line.startswith((" ", "\t", "#")):
            break
        result.append(line)
    return result


def scalar_map(lines: list[str]) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in lines:
        match = re.match(r"^  ([A-Za-z0-9_-]+):\s*(.*?)\s*$", line)
        if match:
            values[match.group(1)] = match.group(2).strip("'\"")
    return values


def inline_list(value: str) -> list[str]:
    match = re.fullmatch(r"\[\s*(.*?)\s*\]", value)
    if not match:
        raise ValueError("event must use an explicit inline list")
    return [item.strip().strip("'\"") for item in match.group(1).split(",") if item.strip()]


def validate(path: Path, default_branch: str) -> None:
    lines = path.read_text(encoding="utf-8").splitlines()
    labels = scalar_map(block(lines, "labels"))
    if labels != REQUIRED_LABELS:
        raise ValueError(f"labels must be exactly {REQUIRED_LABELS}, got {labels}")

    conditions = block(lines, "when")
    if any(re.match(r"^\s+-\s+", line) for line in conditions):
        raise ValueError("when must be one restrictive condition, not alternatives")
    when = scalar_map(conditions)
    events = inline_list(when.get("event", ""))
    if events != ["manual"]:
        raise ValueError(f"event must be manual-only; got {events}")
    if when.get("branch") != default_branch:
        raise ValueError(f"branch must be {default_branch!r}; got {when.get('branch')!r}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("pipeline", type=Path)
    parser.add_argument("--default-branch", required=True)
    args = parser.parse_args()
    try:
        validate(args.pipeline, args.default_branch)
    except (OSError, ValueError) as error:
        parser.error(str(error))
    print(f"macOS Woodpecker policy passed: {args.pipeline}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
