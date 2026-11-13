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
REPOSITORY_COMPONENT = re.compile(r"^[A-Za-z0-9_.-]+$")


def sha256(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def valid_repository_component(component: str) -> bool:
    return (
        component not in {"", ".", ".."}
        and REPOSITORY_COMPONENT.fullmatch(component) is not None
    )


def checked_record(
    record: object, label: str, version: str, expected_format: str | None
) -> tuple[str, str, str, tuple[str, str]]:
    if not isinstance(record, dict):
        raise SystemExit(f"{label} must be an object")
    expected_keys = {"url", "sha256"}
    if expected_format is not None:
        expected_keys.add("format")
    if set(record) != expected_keys:
        raise SystemExit(f"{label} fields are invalid")

    url = record.get("url")
    expected_digest = record.get("sha256")
    parsed = urlparse(url) if isinstance(url, str) else None
    try:
        parsed_port = parsed.port if parsed is not None else None
    except ValueError:
        parsed_port = -1
    if (
        parsed is None
        or parsed.scheme != "https"
        or parsed.hostname != "github.com"
        or parsed.username is not None
        or parsed.password is not None
        or parsed_port is not None
        or parsed.query
        or parsed.fragment
    ):
        raise SystemExit(f"{label} URL must be an HTTPS github.com URL")

    raw_path = parsed.path
    raw_path_lower = raw_path.lower()
    if (
        "%2f" in raw_path_lower
        or "%5c" in raw_path_lower
        or "\\" in raw_path
    ):
        raise SystemExit(f"{label} has an invalid release URL path")
    decoded_path = unquote(raw_path)
    segments = decoded_path.split("/")
    if (
        len(segments) != 7
        or segments[0] != ""
        or segments[3:5] != ["releases", "download"]
        or segments[5] != f"v{version}"
        or not valid_repository_component(segments[1])
        or not valid_repository_component(segments[2])
        or segments[6] in {"", ".", ".."}
        or "\\" in segments[6]
    ):
        raise SystemExit(f"{label} has an invalid release URL path")
    filename = segments[6]

    if not isinstance(expected_digest, str) or not HEX_DIGEST.fullmatch(
        expected_digest
    ):
        raise SystemExit(f"{label} has an invalid SHA-256")
    if expected_format is not None and record.get("format") != expected_format:
        raise SystemExit(f"{label} has an invalid format")
    return filename, expected_digest, url, (segments[1], segments[2])


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
    asset_records: list[tuple[str, str, str, tuple[str, str], str]] = []
    for target, record in assets.items():
        expected_format = "exe" if target == "windows-x86_64" else "binary"
        filename, expected_digest, url, repository = checked_record(
            record, f"asset {target}", version, expected_format
        )
        asset_records.append(
            (filename, expected_digest, url, repository, f"asset {target}")
        )

    asset_urls = [record[2] for record in asset_records]
    if len(asset_urls) != len(set(asset_urls)):
        raise SystemExit("asset records must use a unique asset URL")
    asset_filenames = [record[0] for record in asset_records]
    if len(asset_filenames) != len(set(asset_filenames)):
        raise SystemExit("asset records must use a unique asset filename")

    installers = manifest.get("installers")
    if not isinstance(installers, dict) or set(installers) != {"gateway"}:
        raise SystemExit("manifest gateway installer is missing")
    gateway_filename, gateway_digest, gateway_url, gateway_repository = checked_record(
        installers["gateway"], "gateway installer", version, None
    )
    if gateway_filename in set(asset_filenames):
        raise SystemExit("gateway installer collides with asset filename")
    if gateway_url in set(asset_urls):
        raise SystemExit("gateway installer collides with asset URL")

    repositories = {record[3] for record in asset_records}
    repositories.add(gateway_repository)
    if len(repositories) != 1:
        raise SystemExit("release records must use a consistent owner/repository")

    records = [
        (filename, expected_digest, label)
        for filename, expected_digest, _url, _repository, label in asset_records
    ]
    records.append((gateway_filename, gateway_digest, "gateway installer"))
    for filename, expected_digest, label in records:
        path = regular_file(args.release_dir, filename, label)
        actual_digest = sha256(path)
        if actual_digest != expected_digest:
            raise SystemExit(f"{label} digest mismatch: {filename}")


if __name__ == "__main__":
    main()
