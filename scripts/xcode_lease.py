#!/usr/bin/env python3
"""Serialize cooperating Xcode/GUI lanes across worktrees with an inherited OS lock."""
import argparse
from contextlib import contextmanager
import fcntl
import json
import math
import os
from pathlib import Path
import secrets
import signal
import subprocess
import sys
import time

from bounded_process import terminate_process_group

FD_ENV = "LABSTREAM_XCODE_LEASE_FD"
TOKEN_ENV = "LABSTREAM_XCODE_LEASE_TOKEN"
PATH_ENV = "LABSTREAM_XCODE_LEASE_PATH"


def default_path():
    return Path(os.environ.get(PATH_ENV, str(Path.home() / ".cache/labstream/xcode.lease"))).expanduser().resolve()


def read_owner(path):
    try:
        data = json.loads(Path(str(path) + ".json").read_text())
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def inherited(path):
    try:
        fd = int(os.environ[FD_ENV])
        if not os.environ[TOKEN_ENV]:
            return None
        actual, expected = os.fstat(fd), path.stat()
        return fd if (actual.st_dev, actual.st_ino) == (expected.st_dev, expected.st_ino) and \
            secrets.compare_digest(read_owner(path).get("token", ""), os.environ[TOKEN_ENV]) else None
    except (KeyError, ValueError, OSError, TypeError):
        return None


def open_lock(path):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    return os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)


def status(path):
    if not path.exists():
        return {"active": False, "owner": None}
    fd = open_lock(path)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            owner = read_owner(path)
            owner.pop("token", None)
            started = owner.get("started_at")
            elapsed = round(max(0, time.time() - started), 1) if isinstance(started, (int, float)) and math.isfinite(started) else None
            return {"active": True, "owner": owner, "elapsed_seconds": elapsed}
        return {"active": False, "owner": None}
    finally:
        os.close(fd)


@contextmanager
def acquire(path, lane, timeout):
    existing = inherited(path)
    if existing is not None:
        yield existing
        return
    fd = open_lock(path)
    deadline = time.monotonic() + timeout
    try:
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise TimeoutError("Xcode lease is busy; inspect xcodebuild-lease.py status")
                time.sleep(min(.1, max(0, deadline - time.monotonic())))
        token = secrets.token_hex(24)
        owner = {"pid": os.getpid(), "lane": lane, "workspace": str(Path.cwd()),
                 "started_at": time.time(), "token": token}
        owner_path = Path(str(path) + ".json")
        owner_fd = os.open(owner_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
        with os.fdopen(owner_fd, "w") as handle:
            json.dump(owner, handle)
        previous = {key: os.environ.get(key) for key in (FD_ENV, TOKEN_ENV, PATH_ENV)}
        os.environ.update({FD_ENV: str(fd), TOKEN_ENV: token, PATH_ENV: str(path)})
        try:
            yield fd
        finally:
            for key, value in previous.items():
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value
    finally:
        os.close(fd)


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--lock", type=Path, default=default_path(), help="Use one common path across all cooperating lanes")
    sub = p.add_subparsers(dest="action", required=True)
    sub.add_parser("status")
    sub.add_parser("held")
    r = sub.add_parser("run")
    r.add_argument("--lane", default="xcodebuild")
    r.add_argument("--wait-timeout", type=float, default=900)
    r.add_argument("command", nargs=argparse.REMAINDER)
    args = p.parse_args(argv)
    path = args.lock.expanduser().resolve()
    try:
        if args.action == "status":
            print(json.dumps(status(path), indent=2))
            return 0
        if args.action == "held":
            return 0 if inherited(path) is not None else 1
        command = args.command[1:] if args.command[:1] == ["--"] else args.command
        if not command or not math.isfinite(args.wait_timeout) or args.wait_timeout < 0:
            p.error("a command and nonnegative wait timeout are required")
        def interrupted(signum, frame):
            raise KeyboardInterrupt
        signal.signal(signal.SIGTERM, interrupted)
        with acquire(path, args.lane, args.wait_timeout) as fd:
            child = subprocess.Popen(command, start_new_session=True, pass_fds=(fd,))
            try:
                code = child.wait()
            finally:
                # Also reap descendants if the leader exited, as Xcode diagnostics can outlive it.
                terminate_process_group(child)
            return code if code >= 0 else 128 - code
    except TimeoutError as exc:
        print(f"xcode-lease: {exc}", file=sys.stderr)
        return 75
    except KeyboardInterrupt:
        return 130
    except (OSError, ValueError) as exc:
        print(f"xcode-lease: {type(exc).__name__}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
