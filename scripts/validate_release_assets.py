#!/usr/bin/env python3
"""Validate FarPilot release-manifest records against an assembled directory."""

import argparse
import hashlib
import json
from pathlib import Path
import re
from urllib.parse import unquote, urlparse

TARGETS = {
    "linux-x86_64",
    "linux-aarch64",
    "macos-x86_64",
    "macos-aarch64",
    "windows-x86_64",
}
HEX_DIGEST = re.compile(r"^[0-9a-f]{64}$")
SEMVER = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")


def sha256(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def checked_record(
    record: object, label: str, version: str, expected_format: str | None
) -> tuple[str, str]:
    if not isinstance(record, dict):
        raise SystemExit(f"{label} must be an object")
    url = record.get("url")
    expected_digest = record.get("sha256")
    parsed = urlparse(url) if isinstance(url, str) else None
    if (
        parsed is None
        or parsed.scheme != "https"
        or parsed.netloc != "github.com"
        or parsed.username is not None
        or parsed.password is not None
        or parsed.port is not None
        or parsed.query
        or parsed.fragment
    ):
        raise SystemExit(f"{label} URL must be an HTTPS github.com URL")
    if f"/releases/download/v{version}/" not in parsed.path:
        raise SystemExit(f"{label} URL must reference release v{version}")
    filename = unquote(Path(parsed.path).name)
    if not filename or filename in {".", ".."} or "/" in filename or "\\" in filename:
        raise SystemExit(f"{label} URL has an invalid filename")
    if not isinstance(expected_digest, str) or not HEX_DIGEST.fullmatch(
        expected_digest
    ):
        raise SystemExit(f"{label} has an invalid SHA-256")
    if expected_format is not None and record.get("format") != expected_format:
        raise SystemExit(f"{label} has an invalid format")
    return filename, expected_digest


def regular_file(directory: Path, filename: str, label: str) -> Path:
    path = directory / filename
    if path.is_symlink() or not path.is_file():
        raise SystemExit(f"{label} file is missing or not regular: {filename}")
    return path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--release-dir", type=Path, required=True)
    parser.add_argument("--reported-version", required=True)
    args = parser.parse_args()

    try:
        manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise SystemExit(f"manifest could not be read: {error}") from error
    if not isinstance(manifest, dict):
        raise SystemExit("manifest must be an object")
    if manifest.get("schema_version") != 1:
        raise SystemExit("unsupported manifest schema")
    version = manifest.get("version")
    if not isinstance(version, str) or not SEMVER.fullmatch(version):
        raise SystemExit("manifest version is invalid")
    if manifest.get("tag") != f"v{version}":
        raise SystemExit("manifest tag does not match version")
    if version != args.reported_version:
        raise SystemExit(
            f"version mismatch: manifest={version} reported={args.reported_version}"
        )

    assets = manifest.get("assets")
    if not isinstance(assets, dict) or set(assets) != TARGETS:
        raise SystemExit("manifest target set is incomplete")
    records: list[tuple[str, object, str | None]] = []
    for target, record in assets.items():
        expected_format = "exe" if target == "windows-x86_64" else "binary"
        records.append((f"asset {target}", record, expected_format))

    installers = manifest.get("installers")
    if not isinstance(installers, dict) or set(installers) != {"gateway"}:
        raise SystemExit("manifest gateway installer is missing")
    records.append(("gateway installer", installers["gateway"], None))

    for label, record, expected_format in records:
        filename, expected_digest = checked_record(
            record, label, version, expected_format
        )
        path = regular_file(args.release_dir, filename, label)
        actual_digest = sha256(path)
        if actual_digest != expected_digest:
            raise SystemExit(f"{label} digest mismatch: {filename}")


if __name__ == "__main__":
    main()
