#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"

command -v cargo-deny >/dev/null 2>&1 || {
  echo "cargo-deny is required" >&2
  exit 1
}

cargo deny check advisories
cargo deny check licenses
cargo deny check sources

# Duplicate transitive major versions are reviewed policy warnings. All other
# bans (including wildcard dependencies) remain hard failures.
cargo deny check bans --allow duplicate

metadata=$(cargo metadata --format-version 1 --locked)
printf '%s' "$metadata" | python3 -I -c '
import json, sys
metadata = json.load(sys.stdin)
packages = metadata["packages"]
sqlite = [p for p in packages if p["name"] == "libsqlite3-sys"]
if len(sqlite) != 1:
    raise SystemExit(f"expected one libsqlite3-sys package, found {len(sqlite)}")
current = sqlite[0]["version"]
version = tuple(int(part) for part in current.split(".")[:3])
if version < (0, 39, 0):
    raise SystemExit(f"libsqlite3-sys remains vulnerable: {current}")
if any(p["name"] == "webpki-roots" for p in packages):
    raise SystemExit("webpki-roots remains in the dependency graph")
'

python3 -I - "$root" <<'PY'
from pathlib import Path
import sys, tomllib
root = Path(sys.argv[1])
workspace = tomllib.loads((root / "Cargo.toml").read_text())
rust_version = tuple(int(part) for part in workspace["workspace"]["package"]["rust-version"].split("."))
if rust_version < (1, 94):
    raise SystemExit("workspace rust-version is too old for the patched SQLx revision")
sqlx = workspace["workspace"]["dependencies"]["sqlx"]
if sqlx.get("git") != "https://github.com/transact-rs/sqlx" or sqlx.get("rev") != "10462fa4414c6c7f1ed1d39bb31678e3b726878c":
    raise SystemExit("SQLx must be pinned to the reviewed official security revision")
if sqlx.get("version") != "=0.9.0" or sqlx.get("default-features", True):
    raise SystemExit("SQLx version/default feature policy is incorrect")
expected_sqlx_features = {"runtime-tokio", "sqlite-bundled", "migrate", "macros"}
actual_sqlx_features = set(sqlx.get("features", []))
if actual_sqlx_features != expected_sqlx_features:
    raise SystemExit(
        f"SQLx features must be exactly {sorted(expected_sqlx_features)}, "
        f"found {sorted(actual_sqlx_features)}"
    )
for forbidden in ("sqlite", "sqlite-deserialize", "sqlite-load-extension", "sqlite-unlock-notify"):
    if forbidden in actual_sqlx_features:
        raise SystemExit(f"SQLx forbidden feature enabled: {forbidden}")
for dependency in ("reqwest", "tokio-tungstenite"):
    features = workspace["workspace"]["dependencies"][dependency].get("features", [])
    if not any("native-roots" in feature for feature in features) or any("webpki" in feature for feature in features):
        raise SystemExit(f"{dependency} must use native roots without webpki roots")
for manifest in [root / "Cargo.toml", *sorted((root / "crates").glob("*/Cargo.toml"))]:
    data = tomllib.loads(manifest.read_text())
    for section in ("dependencies", "dev-dependencies", "build-dependencies"):
        for name, spec in data.get(section, {}).items():
            if isinstance(spec, dict) and "path" in spec and "version" not in spec:
                raise SystemExit(f"path dependency lacks version: {manifest.relative_to(root)}:{section}.{name}")
PY

grep -Eq '^multiple-versions = "warn"$' deny.toml
grep -Eq '^wildcards = "deny"$' deny.toml
! grep -Fq 'CDLA-Permissive-2.0' deny.toml
grep -Fq 'https://github.com/transact-rs/sqlx' deny.toml

printf '%s\n' "dependency policy verified"
