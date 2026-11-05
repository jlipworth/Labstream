"""Host side of the UI-test checkpoint handshake (see `UITestCheckpoint.swift`).

A UI test that reaches a named screen writes `<name>.ready` into the directory named by its
`LABSTREAM_UI_CHECKPOINT_DIR` runner variable and waits for `<name>.done`. This module runs the
test command, calls a capture callback for each checkpoint while the app is held on that screen,
and acknowledges it. A callback that raises writes `fail: <reason>` so the test fails instead of
moving on.

The test command's output can contain private live values (for example XCUITest's "Type '…'"
activity lines), so output is never echoed: every line is redacted against the caller's secret
values before it reaches the private log file.
"""
from __future__ import annotations

import os
import re
import selectors
import subprocess
import time
from pathlib import Path
from typing import Callable, Iterable, Mapping

CHECKPOINT_ENV = "LABSTREAM_UI_CHECKPOINT_DIR"
_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$")


class CheckpointError(RuntimeError):
    pass


def redactor(secrets: Iterable[str]) -> Callable[[str], str]:
    """Return a function that replaces every non-trivial secret value with `<redacted>`."""
    values = sorted({value for value in secrets if value and len(value) >= 3}, key=len, reverse=True)

    def redact(text: str) -> str:
        for value in values:
            text = text.replace(value, "<redacted>")
        return text

    return redact


def runner_environment(values: Mapping[str, str]) -> dict[str, str]:
    """Map test-runner variables to xcodebuild's `TEST_RUNNER_` pass-through names."""
    return {f"TEST_RUNNER_{key}": value for key, value in values.items()}


def run(command: list[str], *, checkpoint_dir: Path, on_checkpoint: Callable[[str], None],
        log_path: Path, env: Mapping[str, str] | None = None, secrets: Iterable[str] = (),
        cwd: Path | None = None, timeout: float = 1800) -> tuple[int, list[str]]:
    """Run `command`, servicing checkpoints in order. Returns (exit code, checkpoint names)."""
    checkpoint_dir.mkdir(parents=True, exist_ok=True)
    for stale in checkpoint_dir.glob("*.ready"):
        stale.unlink()
    for stale in checkpoint_dir.glob("*.done"):
        stale.unlink()
    redact = redactor(secrets)
    seen: list[str] = []
    full_env = {**os.environ, **(env or {})}
    log_path.parent.mkdir(parents=True, exist_ok=True)
    deadline = time.monotonic() + timeout
    with log_path.open("w") as log:
        process = subprocess.Popen(command, cwd=cwd, env=full_env, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, text=True, bufsize=1,
                                   start_new_session=True)
        assert process.stdout is not None
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)
        try:
            open_stream = True
            while True:
                for ready in sorted(checkpoint_dir.glob("*.ready"), key=lambda p: p.stat().st_mtime):
                    name = ready.stem
                    ready.unlink()
                    done = checkpoint_dir / f"{name}.done"
                    if not _NAME.match(name):
                        done.write_text("fail: invalid checkpoint name")
                        continue
                    try:
                        on_checkpoint(name)
                    except Exception as error:  # surfaced to the test, which then fails
                        done.write_text(f"fail: {redact(str(error))[:300]}")
                        log.write(f"[checkpoint] {name}: capture failed: {redact(str(error))}\n")
                        continue
                    seen.append(name)
                    log.write(f"[checkpoint] {name}: captured\n")
                    done.write_text("ok")
                if open_stream:
                    if selector.select(timeout=0.25):
                        line = process.stdout.readline()
                        if line == "":
                            open_stream = False
                            selector.unregister(process.stdout)
                        else:
                            log.write(redact(line))
                else:
                    time.sleep(0.25)
                if not open_stream and process.poll() is not None:
                    break
                if time.monotonic() > deadline:
                    raise CheckpointError(f"test command exceeded {int(timeout)}s")
        finally:
            if process.poll() is None:
                from bounded_process import terminate_process_group
                terminate_process_group(process)
            selector.close()
            process.stdout.close()
    return process.returncode, seen
