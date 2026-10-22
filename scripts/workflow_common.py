"""Small read-only Git/GitHub helpers for workflow inspection commands."""
from __future__ import annotations

import json
import re
import subprocess
import time
from pathlib import Path
from urllib.parse import quote


class WorkflowError(RuntimeError):
    pass


class DeadlineExceeded(WorkflowError):
    pass


def run(command: list[str], *, cwd: Path | None = None, timeout: float = 30) -> str:
    try:
        result = subprocess.run(command, cwd=cwd, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise WorkflowError(f"{Path(command[0]).name} unavailable or timed out") from exc
    if result.returncode:
        # CLI stderr can contain URLs, auth details, and private response bodies.
        raise WorkflowError(f"{Path(command[0]).name} failed (exit {result.returncode})")
    return result.stdout


def git(*args: str, cwd: Path | None = None) -> str:
    return run(["git", *args], cwd=cwd).strip()


def repository_root() -> Path:
    return Path(git("rev-parse", "--show-toplevel"))


def repository_name(root: Path) -> str:
    url = git("remote", "get-url", "origin", cwd=root)
    match = re.fullmatch(r"(?:git@github\.com:|https://github\.com/)([\w.-]+/[\w.-]+?)(?:\.git)?", url)
    if not match:
        raise WorkflowError("origin must identify a GitHub owner/repository; use --repo")
    return match[1]


def validate_repository(value: str) -> str:
    if not re.fullmatch(r"[\w.-]+/[\w.-]+", value):
        raise WorkflowError("repository must be owner/name")
    return value


class GitHub:
    def __init__(self, repo: str):
        self.repo = validate_repository(repo)
        self.deadline = None

    def get(self, endpoint: str):
        remaining = 45 if self.deadline is None else self.deadline - time.monotonic()
        if remaining <= 0:
            raise DeadlineExceeded("CI wait deadline reached")
        try:
            result = run(["gh", "api", endpoint], timeout=min(45, remaining))
            if self.deadline is not None and time.monotonic() >= self.deadline:
                raise DeadlineExceeded("CI wait deadline reached")
            return json.loads(result)
        except WorkflowError:
            if self.deadline is not None and time.monotonic() >= self.deadline:
                raise DeadlineExceeded("CI wait deadline reached")
            raise
        except json.JSONDecodeError as exc:
            raise WorkflowError("GitHub returned invalid JSON") from exc

    def pages(self, endpoint: str, *, max_pages: int = 20) -> list:
        rows = []
        separator = "&" if "?" in endpoint else "?"
        for page in range(1, max_pages + 1):
            batch = self.get(f"{endpoint}{separator}per_page=100&page={page}")
            if not isinstance(batch, list):
                raise WorkflowError("GitHub returned an invalid page")
            rows.extend(batch)
            if len(batch) < 100:
                return rows
        raise WorkflowError("GitHub pagination limit reached; narrow the request")

    def issue(self, number: int, *, allow_pull_request: bool = False) -> dict:
        row = self.get(f"repos/{self.repo}/issues/{number}")
        if not isinstance(row, dict) or "number" not in row or ("pull_request" in row and not allow_pull_request):
            raise WorkflowError("not a GitHub issue")
        if "pull_request" in row:
            return row
        row["comments"] = self.pages(f"repos/{self.repo}/issues/{number}/comments")
        return row


def issue_summary(row: dict) -> dict:
    comments = row.get("comments", [])
    return {"number": row["number"], "title": row["title"], "state": row["state"],
            "url": row["html_url"], "body": row.get("body") or "",
            "labels": [x["name"] for x in row.get("labels", [])],
            "comments": [{"body": c.get("body") or "", "url": c.get("html_url"),
                          "updated_at": c.get("updated_at")} for c in comments] if isinstance(comments, list) else []}


def print_json(value) -> None:
    print(json.dumps(value, indent=2, sort_keys=True))


def text(value) -> str:
    # Remote issue/PR content is untrusted terminal text, not instructions.
    return "".join(c if c in "\n\t" or c.isprintable() else "?" for c in str(value))


def endpoint_component(value: str) -> str:
    return quote(value, safe="")


def source_fingerprint(root: Path) -> str:
    """Hash Git state without storing patches or private file contents in the receipt."""
    import hashlib
    import os
    digest = hashlib.sha256()
    digest.update(git("rev-parse", "HEAD", cwd=root).encode())
    digest.update(run(["git", "diff", "--binary", "HEAD"], cwd=root).encode())
    paths = run(["git", "ls-files", "--others", "--exclude-standard", "-z"], cwd=root).split("\0")
    for name in sorted(filter(None, paths)):
        digest.update(name.encode())
        path = root / name
        if path.is_symlink():
            digest.update(os.readlink(path).encode())
        elif path.is_file():
            with path.open("rb") as handle:
                for chunk in iter(lambda: handle.read(65536), b""):
                    digest.update(chunk)
    return digest.hexdigest()
