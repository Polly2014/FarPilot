#!/usr/bin/env python3
import argparse
from pathlib import Path
import re

SEMVER = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
MODES = {"gateway-start", "cli-post-activation"}


def write_candidate(path: Path, version: str, mode: str) -> None:
    if not SEMVER.fullmatch(version):
        raise SystemExit("version must use X.Y.Z")
    if mode not in MODES:
        raise SystemExit("unsupported candidate mode")
    source = f'''#!/bin/sh
set -eu
mode={mode!r}
version={version!r}
if [ "${{1:-}}" = "--version" ]; then
    if [ "$mode" = "cli-post-activation" ] \
       && [ "${{FARPILOT_ACCEPTANCE_FAIL_AFTER_ACTIVATION:-0}}" = 1 ] \
       && [ -n "${{FARPILOT_ACCEPTANCE_TARGET:-}}" ] \
       && [ "$0" = "$FARPILOT_ACCEPTANCE_TARGET" ]; then
        exit 42
    fi
    printf 'farpilot %s\n' "$version"
    exit 0
fi
printf '%s\n' 'synthetic Stage 0.5 failure candidate' >&2
exit 42
'''
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(source, encoding="utf-8")
    path.chmod(0o755)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True)
    parser.add_argument("--mode", choices=sorted(MODES), required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    write_candidate(args.output, args.version, args.mode)


if __name__ == "__main__":
    main()
