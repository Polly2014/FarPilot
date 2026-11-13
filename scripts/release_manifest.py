#!/usr/bin/env python3
"""Generate a deterministic FarPilot release manifest from local artifacts."""

import argparse
import hashlib
import json
from pathlib import Path
import re

REQUIRED_TARGETS = {
    "linux-x86_64",
    "linux-aarch64",
    "macos-x86_64",
    "macos-aarch64",
    "windows-x86_64",
}
SEMVER = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
REPOSITORY = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def parse_mapping(values: list[str], option: str) -> dict[str, Path]:
    parsed: dict[str, Path] = {}
    for value in values:
        key, separator, raw_path = value.partition("=")
        if not separator or not key or not raw_path:
            raise SystemExit(f"{option} requires name=path")
        if key in parsed:
            raise SystemExit(f"{option} contains duplicate name: {key}")
        path = Path(raw_path).resolve()
        if not path.is_file() or path.is_symlink():
            raise SystemExit(f"{option} file does not exist or is not regular: {path}")
        parsed[key] = path
    return parsed


def asset_record(
    repository: str, tag: str, target: str, path: Path
) -> dict[str, str]:
    return {
        "url": f"https://github.com/{repository}/releases/download/{tag}/{path.name}",
        "sha256": digest(path),
        "format": "exe" if target == "windows-x86_64" else "binary",
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--asset", action="append", default=[])
    parser.add_argument("--installer", action="append", default=[])
    args = parser.parse_args()

    if not SEMVER.fullmatch(args.version):
        raise SystemExit("version must be a semantic version such as 0.2.0")
    if not REPOSITORY.fullmatch(args.repository):
        raise SystemExit("repository must use owner/name syntax")

    assets = parse_mapping(args.asset, "--asset")
    installers = parse_mapping(args.installer, "--installer")
    if set(assets) != REQUIRED_TARGETS:
        raise SystemExit(
            f"assets must be exactly: {', '.join(sorted(REQUIRED_TARGETS))}"
        )
    if set(installers) != {"gateway"}:
        raise SystemExit("installers must contain exactly gateway")

    tag = f"v{args.version}"
    manifest = {
        "schema_version": 1,
        "version": args.version,
        "tag": tag,
        "assets": {
            target: asset_record(args.repository, tag, target, path)
            for target, path in sorted(assets.items())
        },
        "installers": {
            "gateway": {
                "url": (
                    f"https://github.com/{args.repository}/releases/download/"
                    f"{tag}/{installers['gateway'].name}"
                ),
                "sha256": digest(installers["gateway"]),
            }
        },
    }
    args.output.write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )


if __name__ == "__main__":
    main()
