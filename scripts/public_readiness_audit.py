#!/usr/bin/env python3
"""Redacted Git history/tree audit for pre-publication review."""

from __future__ import annotations

import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile

SCANNER_VERSION = "1"
MAX_BLOB_BYTES = 8 * 1024 * 1024

PATTERNS = {
    "private_key": re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    "github_token": re.compile(r"\bgh[pousr]_[A-Za-z0-9]{20,}\b"),
    "aws_access_key": re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"),
    "credential_url": re.compile(r"https?://[^\s/:]+:[^\s/@]+@"),
    "secret_assignment": re.compile(
        r"(?i)\b(?:client_secret|api_key|password|token)\s*[:=]\s*[\"']?"
        r"(?![<{]|\$)[A-Za-z0-9_./+=-]{16,}"
    ),
    "private_ip": re.compile(r"\b(?:10\.|192\.168\.|172\.(?:1[6-9]|2[0-9]|3[01])\.)"),
    "internal_hostname": re.compile(r"(?i)\b[a-z0-9-]+\.internal(?:\.[a-z0-9.-]+)?\b"),
    "farpilot_identifier": re.compile(r"\b(?:host|device)_[0-9a-f]{32}\b"),
    "ssh_public_key_body": re.compile(r"\bssh-ed25519\s+[A-Za-z0-9+/]{40,}={0,3}\b"),
}

SEVERITY = {
    "private_key": "high",
    "github_token": "high",
    "aws_access_key": "high",
    "credential_url": "high",
    "secret_assignment": "high",
    "risky_filename": "high",
    "unsafe_tracked_path": "high",
    "private_ip": "review",
    "internal_hostname": "review",
    "farpilot_identifier": "review",
    "ssh_public_key_body": "review",
    "large_blob": "review",
}

RISKY_SUFFIXES = (".pfx", ".p12", ".sqlite", ".db")


def run_git(repo: Path, *args: str, binary: bool = False):
    result = subprocess.run(
        ["git", "-C", str(repo), *args],
        check=False,
        capture_output=True,
        text=not binary,
    )
    if result.returncode != 0:
        message = result.stderr.decode(errors="replace") if binary else result.stderr
        raise RuntimeError(f"git command failed: {message.strip()}")
    return result.stdout


def ensure_git_repository(repo: Path) -> Path:
    if not repo.is_dir():
        raise ValueError("repo must be a Git repository directory")
    result = subprocess.run(
        ["git", "-C", str(repo), "rev-parse", "--show-toplevel"],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise ValueError("repo must be a Git repository")
    top = Path(result.stdout.strip()).resolve()
    if top != repo.resolve():
        raise ValueError("repo must name the Git repository root")
    return top


def inside(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def is_symlink_or_reparse(path: Path) -> bool:
    try:
        metadata = os.lstat(path)
    except FileNotFoundError:
        return False
    if stat.S_ISLNK(metadata.st_mode):
        return True
    reparse_flag = getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400)
    return bool(getattr(metadata, "st_file_attributes", 0) & reparse_flag)


def has_unsafe_output_symlink(path: Path) -> bool:
    absolute = path.expanduser().absolute()
    current = Path(absolute.anchor)
    for component in absolute.parts[1:]:
        current /= component
        if is_symlink_or_reparse(current):
            return True
        if not current.exists():
            break
    return False


def validate_output_path(path: Path, repo: Path) -> Path:
    if has_unsafe_output_symlink(path):
        raise ValueError("audit output path or parent must not be a symlink")
    resolved = path.resolve(strict=False)
    if inside(resolved, repo):
        raise ValueError("audit output must be outside the audited repository")
    return resolved


def path_hash(path: str) -> str:
    return hashlib.sha256(path.encode("utf-8", errors="surrogateescape")).hexdigest()[:16]


def finding(category: str, source: str, object_id: str, path: str) -> dict[str, str]:
    return {
        "category": category,
        "source": source,
        "object": object_id[:12],
        "path_hash": path_hash(path),
        "severity": SEVERITY[category],
    }


def reachable_blobs(repo: Path) -> dict[str, tuple[list[str], int]]:
    output = run_git(repo, "rev-list", "--objects", "--all")
    candidates: dict[str, set[str]] = {}
    for line in output.splitlines():
        object_id, separator, path = line.partition(" ")
        candidates.setdefault(object_id, set())
        if separator:
            candidates[object_id].add(path)
    object_ids = sorted(candidates)
    if not object_ids:
        return {}
    checked = subprocess.run(
        [
            "git",
            "-C",
            str(repo),
            "cat-file",
            "--batch-check=%(objectname) %(objecttype) %(objectsize)",
        ],
        input="\n".join(object_ids) + "\n",
        capture_output=True,
        text=True,
    )
    if checked.returncode != 0:
        raise RuntimeError(f"git cat-file --batch-check failed: {checked.stderr.strip()}")
    blobs: dict[str, tuple[list[str], int]] = {}
    for line in checked.stdout.splitlines():
        fields = line.split()
        if len(fields) != 3:
            raise RuntimeError("git cat-file --batch-check returned malformed metadata")
        object_id, object_type, raw_size = fields
        if object_type == "blob":
            blobs[object_id] = (sorted(candidates[object_id]) or ["<unknown>"], int(raw_size))
    return blobs


def scan_blob(
    data: bytes, object_id: str, paths: list[str], source: str
) -> list[dict[str, str]]:
    if b"\x00" in data:
        return []
    text = data.decode("utf-8", errors="replace")
    source_path = paths[0]
    results = []
    for category, pattern in PATTERNS.items():
        if pattern.search(text):
            results.append(finding(category, source, object_id, source_path))
    return results


def risky_filename(path: str) -> bool:
    lower = path.lower()
    name = Path(lower).name
    return name == ".env" or lower.endswith(".env") or lower.endswith(RISKY_SUFFIXES)


def scan_tracked_filenames(repo: Path) -> list[dict[str, str]]:
    raw = run_git(repo, "ls-files", "-z")
    results = []
    for path in raw.split("\0"):
        if not path or not risky_filename(path):
            continue
        try:
            object_id = run_git(repo, "hash-object", "--", path).strip()
        except RuntimeError:
            object_id = hashlib.sha256(path.encode()).hexdigest()
        results.append(finding("risky_filename", "tree", object_id, path))
    return results


def hash_worktree_blob(repo: Path, data: bytes) -> str:
    result = subprocess.run(
        ["git", "-C", str(repo), "hash-object", "--stdin"],
        input=data,
        capture_output=True,
    )
    if result.returncode != 0:
        raise RuntimeError("git hash-object failed while scanning tracked tree")
    return result.stdout.decode("ascii").strip()


def scan_tracked_content(
    repo: Path,
    history_blobs: dict[str, tuple[list[str], int]],
    max_blob_bytes: int,
) -> list[dict[str, str]]:
    raw = run_git(repo, "ls-files", "-z")
    results: list[dict[str, str]] = []
    for relative in sorted(path for path in raw.split("\0") if path):
        path = repo / relative
        try:
            metadata = os.lstat(path)
        except FileNotFoundError:
            results.append(
                finding(
                    "unsafe_tracked_path",
                    "tree",
                    hashlib.sha256(relative.encode()).hexdigest(),
                    relative,
                )
            )
            continue
        if not stat.S_ISREG(metadata.st_mode) or is_symlink_or_reparse(path):
            results.append(
                finding(
                    "unsafe_tracked_path",
                    "tree",
                    hashlib.sha256(relative.encode()).hexdigest(),
                    relative,
                )
            )
            continue
        if metadata.st_size > max_blob_bytes:
            object_id = run_git(repo, "hash-object", "--", relative).strip()
            if object_id not in history_blobs:
                results.append(finding("large_blob", "tree", object_id, relative))
            continue
        with path.open("rb") as source:
            data = source.read(max_blob_bytes + 1)
        if len(data) > max_blob_bytes:
            results.append(
                finding(
                    "large_blob",
                    "tree",
                    hashlib.sha256(relative.encode()).hexdigest(),
                    relative,
                )
            )
            continue
        object_id = hash_worktree_blob(repo, data)
        if object_id in history_blobs:
            continue
        results.extend(scan_blob(data, object_id, [relative], "tree"))
    return results


def deduplicate_findings(findings: list[dict[str, str]]) -> list[dict[str, str]]:
    unique = {
        (
            item["category"],
            item["source"],
            item["object"],
            item["path_hash"],
            item["severity"],
        ): item
        for item in findings
    }
    return [unique[key] for key in sorted(unique)]


def gitleaks_status() -> dict[str, object]:
    executable = shutil.which("gitleaks")
    if executable is None:
        return {"available": False, "version": None}
    result = subprocess.run([executable, "version"], capture_output=True, text=True)
    version = (result.stdout or result.stderr).strip().splitlines()
    return {
        "available": result.returncode == 0,
        "version": version[0][:120] if version else None,
    }


def create_private_parents(parent: Path) -> None:
    missing = []
    cursor = parent
    while not cursor.exists():
        missing.append(cursor)
        if cursor == cursor.parent:
            break
        cursor = cursor.parent
    for directory in reversed(missing):
        directory.mkdir(mode=0o700)
        os.chmod(directory, 0o700)


def atomic_json(path: Path, value: object) -> None:
    if has_unsafe_output_symlink(path):
        raise ValueError("audit output path or parent must not be a symlink")
    create_private_parents(path.parent)
    if has_unsafe_output_symlink(path):
        raise ValueError("audit output path or parent must not be a symlink")
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            json.dump(value, output, indent=2, sort_keys=True)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        if has_unsafe_output_symlink(path):
            raise ValueError("audit output path or parent changed to a symlink")
        os.replace(temporary, path)
        os.chmod(path, 0o600)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def audit(
    repo: Path, max_blob_bytes: int
) -> tuple[dict[str, object], dict[str, object]]:
    blobs = reachable_blobs(repo)
    findings: list[dict[str, str]] = []
    for object_id, (paths, size) in sorted(blobs.items()):
        if size > max_blob_bytes:
            findings.append(finding("large_blob", "history", object_id, paths[0]))
            continue
        data = run_git(repo, "cat-file", "blob", object_id, binary=True)
        if len(data) > max_blob_bytes:
            findings.append(finding("large_blob", "history", object_id, paths[0]))
            continue
        findings.extend(scan_blob(data, object_id, paths, "history"))
    findings.extend(scan_tracked_content(repo, blobs, max_blob_bytes))
    findings.extend(scan_tracked_filenames(repo))
    findings = deduplicate_findings(findings)
    counts = Counter(item["category"] for item in findings)
    severity_counts = Counter(item["severity"] for item in findings)
    if severity_counts["high"]:
        verdict = "blocked"
    elif severity_counts["review"]:
        verdict = "review_required"
    else:
        verdict = "ready"
    now = datetime.now(timezone.utc).replace(microsecond=0).isoformat()
    private = {
        "schema_version": 1,
        "scanner_version": SCANNER_VERSION,
        "findings": findings,
    }
    summary = {
        "schema_version": 1,
        "scanner_version": SCANNER_VERSION,
        "scanned_at": now,
        "refs": "all reachable Git refs",
        "objects_scanned": len(blobs),
        "counts": dict(sorted(counts.items())),
        "severity_counts": {
            "high": severity_counts["high"],
            "review": severity_counts["review"],
        },
        "gitleaks": gitleaks_status(),
        "verdict": verdict,
    }
    return private, summary


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True, type=Path)
    parser.add_argument("--private-report", required=True, type=Path)
    parser.add_argument("--summary", required=True, type=Path)
    parser.add_argument(
        "--max-blob-bytes",
        type=int,
        default=MAX_BLOB_BYTES,
        help=argparse.SUPPRESS,
    )
    arguments = parser.parse_args()
    try:
        if not 1 <= arguments.max_blob_bytes <= MAX_BLOB_BYTES:
            raise ValueError(f"max blob bytes must be between 1 and {MAX_BLOB_BYTES}")
        repo = ensure_git_repository(arguments.repo)
        private_path = validate_output_path(arguments.private_report, repo)
        summary_path = validate_output_path(arguments.summary, repo)
        if private_path == summary_path:
            raise ValueError("private report and summary must be different paths")
        private, summary = audit(repo, arguments.max_blob_bytes)
        atomic_json(private_path, private)
        atomic_json(summary_path, summary)
    except (OSError, ValueError, RuntimeError, json.JSONDecodeError) as error:
        print(f"public readiness audit failed: {error}", file=sys.stderr)
        return 3
    print(f"public readiness verdict: {summary['verdict']}")
    return {"ready": 0, "blocked": 1, "review_required": 2}[summary["verdict"]]


if __name__ == "__main__":
    raise SystemExit(main())
