#!/usr/bin/env python3
import argparse
import hashlib
import json
from pathlib import Path
import re
from urllib.parse import urlparse

TARGETS = {
    "linux-x86_64",
    "linux-aarch64",
    "macos-x86_64",
    "macos-aarch64",
    "windows-x86_64",
}
SEMVER = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def checked_file(path: Path, label: str) -> Path:
    source = path.expanduser()
    if source.is_symlink():
        raise SystemExit(f"{label} must not be a symbolic link")
    try:
        resolved = source.resolve(strict=True)
    except OSError as error:
        raise SystemExit(f"{label} does not exist") from error
    if not resolved.is_file():
        raise SystemExit(f"{label} must be a regular file")
    return resolved


def validate_base_url(base_url: str) -> str:
    parsed = urlparse(base_url)
    if (
        parsed.scheme != "https"
        or parsed.hostname != "127.0.0.1"
        or parsed.port is None
        or parsed.path not in {"", "/"}
        or parsed.params
        or parsed.query
        or parsed.fragment
        or parsed.username
        or parsed.password
    ):
        raise SystemExit("base URL must be https://127.0.0.1:PORT/")
    return base_url.rstrip("/") + "/"


def build_manifest(
    version: str,
    base_url: str,
    assets: dict[str, Path],
    gateway_installer: Path,
) -> dict:
    if not SEMVER.fullmatch(version):
        raise SystemExit("version must use X.Y.Z")
    base_url = validate_base_url(base_url)
    if set(assets) != TARGETS:
        raise SystemExit("assets must contain the exact FarPilot target set")
    checked_assets = {
        target: checked_file(path, f"asset {target}")
        for target, path in assets.items()
    }
    checked_gateway = checked_file(gateway_installer, "Gateway installer")
    names = [path.name for path in checked_assets.values()] + [checked_gateway.name]
    if len(names) != len(set(names)):
        raise SystemExit("asset filenames must be unique")
    return {
        "schema_version": 1,
        "version": version,
        "tag": f"v{version}",
        "assets": {
            target: {
                "url": base_url + path.name,
                "sha256": digest(path),
                "format": "exe" if target == "windows-x86_64" else "binary",
            }
            for target, path in sorted(checked_assets.items())
        },
        "installers": {
            "gateway": {
                "url": base_url + checked_gateway.name,
                "sha256": digest(checked_gateway),
            }
        },
    }


def parse_mapping(values: list[str]) -> dict[str, Path]:
    result = {}
    for value in values:
        key, separator, raw = value.partition("=")
        if not separator or not key or not raw or key in result:
            raise SystemExit("--asset requires unique TARGET=PATH values")
        result[key] = Path(raw)
    return result


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True)
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--asset", action="append", default=[])
    parser.add_argument("--gateway-installer", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    manifest = build_manifest(
        args.version,
        args.base_url,
        parse_mapping(args.asset),
        args.gateway_installer,
    )
    args.output.write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )


if __name__ == "__main__":
    main()
