# FarPilot One-Command Install Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish verified multi-platform FarPilot releases and provide short, repeatable commands for the latest stable or a pinned version of the macOS/Linux CLI, Windows Host, and full Ubuntu Gateway deployment.

**Architecture:** GitHub Releases hold immutable binaries, installer assets, and one generated `manifest.json`; `farpilot.polly.wang` exposes stable redirects to the latest installer and manifest. POSIX shell and PowerShell installers validate the manifest, SHA-256, and binary version before activation, while the Gateway installer adds idempotent system provisioning and health-checked rollback.

**Tech Stack:** Rust stable, GitHub Actions, Python 3 standard library for deterministic manifest generation, POSIX `sh`, PowerShell 5.1+, Nginx, systemd, OpenSSH, Certbot, GitHub Releases.

**Approved specification:** `docs/specs/2026-11-13-farpilot-one-command-install-design.md`

**Repository policy:** Commit and push steps require explicit user authorization in the execution session. If authorization is absent, stop at the corresponding status checkpoint without committing or publishing.

---

## File map

```text
FarPilot/
├── install.sh                                  # Public POSIX CLI installer and Gateway dispatcher
├── scripts/
│   ├── release_manifest.py                    # Deterministic manifest generator and validator
│   └── validate_release_assets.py             # Release-directory completeness and version check
├── tests/
│   ├── fixtures/install/
│   │   ├── farpilot-fixture.sh                # Synthetic executable reporting version 9.8.7
│   │   ├── manifest-template.json             # Fixture manifest source
│   │   └── fake-curl.sh                       # HTTPS URL-to-fixture download shim
│   ├── install/install_sh.sh                   # POSIX installer behavior and rollback tests
│   ├── install/gateway_installer.sh            # Ubuntu Gateway installer tests with command shims
│   └── release/test_release_manifest.py        # Manifest generator/validator unit tests
├── deploy/
│   ├── windows/
│   │   ├── install.ps1                        # Public Windows versioned installer
│   │   └── test-install.ps1                   # Plain PowerShell installer regression suite
│   └── gateway/
│       ├── install.sh                         # Public full Gateway installer (`install-gateway.sh` asset)
│       ├── farpilot-gateway.service
│       ├── farpilot.polly.wang.nginx
│       └── sshd_config.fragment
├── .github/workflows/
│   ├── ci.yml                                 # Add installer/static tests on normal changes
│   └── release.yml                            # Tag-gated build, manifest, and GitHub Release publication
├── docs/stage0-runbook.md                     # One-command install, upgrade, rollback, and trust notes
└── README.md                                  # Current status and short install commands
```

The manifest tools are release-only Python utilities. Python is not installed on Windows Hosts or required by end users.

---

### Task 1: Deterministic release manifest generation

**Files:**
- Create: `scripts/release_manifest.py`
- Create: `scripts/validate_release_assets.py`
- Create: `tests/release/test_release_manifest.py`

- [ ] **Step 1: Write failing manifest generator tests**

Create `tests/release/test_release_manifest.py` with standard-library `unittest` cases that build five temporary files, invoke the generator, and verify stable JSON, exact URLs, hashes, formats, and rejection behavior:

```python
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
GENERATOR = ROOT / "scripts" / "release_manifest.py"
VALIDATOR = ROOT / "scripts" / "validate_release_assets.py"
TARGETS = {
    "linux-x86_64": "farpilot-linux-x86_64",
    "linux-aarch64": "farpilot-linux-aarch64",
    "macos-x86_64": "farpilot-macos-x86_64",
    "macos-aarch64": "farpilot-macos-aarch64",
    "windows-x86_64": "farpilot-windows-x86_64.exe",
}

class ReleaseManifestTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.directory = Path(self.temp.name)
        for target, name in TARGETS.items():
            (self.directory / name).write_bytes((target + "\n").encode())
        (self.directory / "install-gateway.sh").write_text("#!/bin/sh\nexit 0\n")

    def tearDown(self):
        self.temp.cleanup()

    def command(self, version="0.2.0"):
        command = [
            sys.executable,
            str(GENERATOR),
            "--version", version,
            "--repository", "Polly2014/FarPilot",
            "--output", str(self.directory / "manifest.json"),
        ]
        for target, name in TARGETS.items():
            command.extend(["--asset", f"{target}={self.directory / name}"])
        command.extend([
            "--installer",
            f"gateway={self.directory / 'install-gateway.sh'}",
        ])
        return command

    def test_manifest_has_exact_assets_and_digests(self):
        subprocess.run(self.command(), check=True)
        manifest = json.loads((self.directory / "manifest.json").read_text())
        self.assertEqual(manifest["schema_version"], 1)
        self.assertEqual(manifest["version"], "0.2.0")
        self.assertEqual(manifest["tag"], "v0.2.0")
        self.assertEqual(set(manifest["assets"]), set(TARGETS))
        for target, name in TARGETS.items():
            expected = hashlib.sha256((self.directory / name).read_bytes()).hexdigest()
            self.assertEqual(manifest["assets"][target]["sha256"], expected)
            self.assertTrue(manifest["assets"][target]["url"].endswith(f"/v0.2.0/{name}"))
        self.assertEqual(manifest["assets"]["windows-x86_64"]["format"], "exe")
        self.assertEqual(manifest["assets"]["linux-x86_64"]["format"], "binary")

    def test_invalid_version_is_rejected(self):
        result = subprocess.run(self.command("release/latest"), capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("semantic version", result.stderr)

    def test_missing_required_target_is_rejected(self):
        command = self.command()
        missing = str(self.directory / TARGETS["linux-aarch64"])
        command[command.index(f"linux-aarch64={missing}")] = f"linux-aarch64={missing}.missing"
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not exist", result.stderr)

    def test_validator_rejects_binary_version_mismatch(self):
        subprocess.run(self.command(), check=True)
        result = subprocess.run([
            sys.executable,
            str(VALIDATOR),
            "--manifest", str(self.directory / "manifest.json"),
            "--release-dir", str(self.directory),
            "--reported-version", "0.2.1",
        ], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("version mismatch", result.stderr)

if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run the tests and verify RED**

Run:

```bash
python3 -m unittest tests/release/test_release_manifest.py -v
```

Expected: all four tests error or fail because the two scripts do not exist.

- [ ] **Step 3: Implement the manifest generator**

Create `scripts/release_manifest.py` with these public boundaries:

```python
#!/usr/bin/env python3
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

def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()

def parse_mapping(values: list[str], option: str) -> dict[str, Path]:
    parsed = {}
    for value in values:
        key, separator, raw_path = value.partition("=")
        if not separator or not key or not raw_path:
            raise SystemExit(f"{option} requires name=path")
        path = Path(raw_path).resolve()
        if not path.is_file():
            raise SystemExit(f"{option} file does not exist: {path}")
        parsed[key] = path
    return parsed

def asset_record(repository: str, tag: str, target: str, path: Path) -> dict[str, str]:
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
    assets = parse_mapping(args.asset, "--asset")
    installers = parse_mapping(args.installer, "--installer")
    if set(assets) != REQUIRED_TARGETS:
        raise SystemExit(f"assets must be exactly: {', '.join(sorted(REQUIRED_TARGETS))}")
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
                "url": f"https://github.com/{args.repository}/releases/download/{tag}/{installers['gateway'].name}",
                "sha256": digest(installers["gateway"]),
            }
        },
    }
    args.output.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")

if __name__ == "__main__":
    main()
```

Create `scripts/validate_release_assets.py`:

```python
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
HEX_DIGEST = re.compile(r"^[0-9a-f]{64}$")

def sha256(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()

def checked_record(record: object, label: str) -> tuple[str, str]:
    if not isinstance(record, dict):
        raise SystemExit(f"{label} must be an object")
    url = record.get("url")
    digest = record.get("sha256")
    parsed = urlparse(url) if isinstance(url, str) else None
    if parsed is None or parsed.scheme != "https" or parsed.netloc != "github.com":
        raise SystemExit(f"{label} URL must be an HTTPS github.com URL")
    if not isinstance(digest, str) or not HEX_DIGEST.fullmatch(digest):
        raise SystemExit(f"{label} has an invalid SHA-256")
    return Path(parsed.path).name, digest

def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--release-dir", type=Path, required=True)
    parser.add_argument("--reported-version", required=True)
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text())
    if manifest.get("schema_version") != 1:
        raise SystemExit("unsupported manifest schema")
    version = manifest.get("version")
    if version != args.reported_version:
        raise SystemExit(f"version mismatch: manifest={version} reported={args.reported_version}")
    assets = manifest.get("assets")
    if not isinstance(assets, dict) or set(assets) != TARGETS:
        raise SystemExit("manifest target set is incomplete")
    records = [(f"asset {target}", record) for target, record in assets.items()]
    installers = manifest.get("installers")
    if not isinstance(installers, dict) or set(installers) != {"gateway"}:
        raise SystemExit("manifest gateway installer is missing")
    records.append(("gateway installer", installers["gateway"]))
    for label, record in records:
        filename, expected = checked_record(record, label)
        path = args.release_dir / filename
        if not path.is_file():
            raise SystemExit(f"{label} file is missing: {filename}")
        actual = sha256(path)
        if actual != expected:
            raise SystemExit(f"{label} digest mismatch: {filename}")

if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Run generator tests and verify GREEN**

Run:

```bash
python3 -m unittest tests/release/test_release_manifest.py -v
```

Expected: 4 tests pass.

- [ ] **Step 5: Run formatting/static checks for release scripts**

Run:

```bash
python3 -m py_compile scripts/release_manifest.py scripts/validate_release_assets.py
python3 -m unittest discover -s tests/release -v
git diff --check
```

Expected: all commands exit 0.

- [ ] **Step 6: Commit checkpoint**

```bash
git add scripts/release_manifest.py scripts/validate_release_assets.py tests/release/test_release_manifest.py
git commit -m "feat: generate verified release manifests"
```

If commits are not authorized, show `git status --short` and stop at this checkpoint.

---

### Task 2: POSIX CLI installer platform and manifest selection

**Files:**
- Create: `install.sh`
- Create: `tests/fixtures/install/farpilot-fixture.sh`
- Create: `tests/fixtures/install/fake-curl.sh`
- Create: `tests/install/install_sh.sh`

- [ ] **Step 1: Create an executable synthetic FarPilot fixture**

Create `tests/fixtures/install/farpilot-fixture.sh`:

```sh
#!/bin/sh
set -eu
if [ "${1:-}" = "--version" ]; then
    printf '%s\n' 'farpilot 9.8.7'
    exit 0
fi
printf '%s\n' 'fixture invoked'
```

Create `tests/fixtures/install/fake-curl.sh`. It must parse `-o`/`--output`, ignore retry and timeout flags, require an HTTPS URL, and copy from a mapping directory named by `FARPILOT_TEST_DOWNLOADS`. Map the requested URL basename to a fixture file and fail when no mapping exists. This shim is test-only and is selected by prepending its directory to PATH.

- [ ] **Step 2: Write failing installer target-selection tests**

Create `tests/install/install_sh.sh`:

```sh
#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/downloads" "$tmp/home"
cp "$root/tests/fixtures/install/fake-curl.sh" "$tmp/bin/curl"
chmod +x "$tmp/bin/curl"
cp "$root/tests/fixtures/install/farpilot-fixture.sh" "$tmp/downloads/farpilot-macos-aarch64"
chmod +x "$tmp/downloads/farpilot-macos-aarch64"
sha=$(shasum -a 256 "$tmp/downloads/farpilot-macos-aarch64" | awk '{print $1}')
cat > "$tmp/downloads/latest.json" <<EOF
{
  "schema_version": 1,
  "version": "9.8.7",
  "tag": "v9.8.7",
  "assets": {
    "macos-aarch64": {
      "url": "https://downloads.example/farpilot-macos-aarch64",
      "sha256": "$sha",
      "format": "binary"
    }
  },
  "installers": {
    "gateway": {
      "url": "https://downloads.example/install-gateway.sh",
      "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    }
  }
}
EOF
FARPILOT_TEST_DOWNLOADS="$tmp/downloads" \
FARPILOT_UNAME_S=Darwin \
FARPILOT_UNAME_M=arm64 \
FARPILOT_MANIFEST_URL=https://downloads.example/latest.json \
FARPILOT_INSTALL_DIR="$tmp/home/bin" \
HOME="$tmp/home" \
PATH="$tmp/bin:/usr/bin:/bin" \
sh "$root/install.sh"
test -x "$tmp/home/bin/farpilot"
test "$("$tmp/home/bin/farpilot" --version)" = "farpilot 9.8.7"
```

The production installer may honor `FARPILOT_MANIFEST_URL` for controlled mirrors, but it must still enforce HTTPS. `FARPILOT_UNAME_S` and `FARPILOT_UNAME_M` are documented as test/packaging overrides and do not bypass target allowlists.

- [ ] **Step 3: Run the installer test and verify RED**

Run:

```bash
bash tests/install/install_sh.sh
```

Expected: FAIL because `install.sh` does not exist.

- [ ] **Step 4: Implement POSIX argument and platform handling**

Create `install.sh` with `set -eu`, functions `log`, `warn`, `die`, `need`, `normalize_version`, `detect_target`, `manifest_url`, and `download`. Required argument behavior:

```sh
role=cli
version=
dry_run=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        gateway) role=gateway; shift; break ;;
        --version) [ "$#" -ge 2 ] || die "--version requires a value"; version=$(normalize_version "$2"); shift 2 ;;
        --dry-run) dry_run=1; shift ;;
        --) shift; break ;;
        *) die "unknown argument: $1" ;;
    esac
done
```

`detect_target` maps only the four Unix combinations from the specification and rejects Android. `manifest_url` returns `${FARPILOT_MANIFEST_URL}` when set, otherwise `https://farpilot.polly.wang/latest.json` for latest or `https://github.com/Polly2014/FarPilot/releases/download/v${version}/manifest.json` for a pinned version.

Add bounded curl flags:

```sh
download() {
    url=$1
    destination=$2
    case "$url" in https://*) ;; *) die "download URL must use HTTPS: $url" ;; esac
    curl -fsSL --retry 3 --connect-timeout 10 --max-time 120 "$url" -o "$destination"
}
```

Parse the deterministic manifest with `awk` functions that enter the named target object and extract only `url`, `sha256`, and `format`. Validate schema version 1, exact requested version when pinned, a 64-character hexadecimal digest, `format=binary`, and HTTPS URL before downloading.

- [ ] **Step 5: Run target-selection tests and verify GREEN**

Run:

```bash
bash tests/install/install_sh.sh
```

Expected: the synthetic macOS arm64 binary installs and prints `farpilot 9.8.7`.

- [ ] **Step 6: Add negative target and manifest cases**

Extend `tests/install/install_sh.sh` with isolated subprocess cases for:

```text
Plan9/x86_64                 -> unsupported OS
Darwin/riscv64               -> unsupported architecture
http:// manifest override    -> HTTPS rejection
missing target object        -> release unavailable for target
nonhex or short SHA-256      -> manifest rejection
reported version 9.8.6       -> version mismatch
```

Each case asserts nonzero exit and that no `farpilot` file appears in the destination.

- [ ] **Step 7: Run installer tests**

Run:

```bash
bash tests/install/install_sh.sh
shellcheck install.sh tests/fixtures/install/fake-curl.sh tests/install/install_sh.sh
```

Expected: installer tests pass and ShellCheck reports no findings.

- [ ] **Step 8: Commit checkpoint**

```bash
git add install.sh tests/fixtures/install tests/install/install_sh.sh
git commit -m "feat: add verified Unix installer"
```

Without commit authorization, stop after `git diff --check`.

---

### Task 3: Unix atomic upgrade, pinned versions, dry run, and Gateway dispatch

**Files:**
- Modify: `install.sh`
- Modify: `tests/install/install_sh.sh`

- [ ] **Step 1: Write failing upgrade and rollback tests**

Extend `tests/install/install_sh.sh` with separate temporary homes that prove:

1. an existing `farpilot 9.8.6` is replaced by 9.8.7;
2. an already installed 9.8.7 exits 0 without replacing the inode;
3. `--version v9.8.7` and `--version 9.8.7` fetch `v9.8.7/manifest.json`;
4. checksum mismatch leaves the old binary byte-for-byte unchanged;
5. staged `--version` failure leaves the old binary unchanged;
6. `--dry-run` creates no install directory;
7. a missing PATH entry prints `export PATH="<dir>:$PATH"` without editing shell files;
8. `gateway` downloads `install-gateway.sh`, verifies its digest, and forwards `--domain`, `--email`, `--version`, and `--dry-run` arguments.

Use the fake curl request log to assert exact URLs rather than making network requests.

- [ ] **Step 2: Run tests and verify RED**

Run:

```bash
bash tests/install/install_sh.sh
```

Expected: new assertions fail because backup, dry-run, pinned-version, and Gateway dispatch behavior is absent.

- [ ] **Step 3: Implement checksum selection and atomic activation**

Add SHA tool selection equivalent to:

```sh
if command -v sha256sum >/dev/null 2>&1; then
    hash_file() { sha256sum "$1" | awk '{print tolower($1)}'; }
elif command -v shasum >/dev/null 2>&1; then
    hash_file() { shasum -a 256 "$1" | awk '{print tolower($1)}'; }
elif command -v openssl >/dev/null 2>&1; then
    hash_file() { openssl dgst -sha256 "$1" | awk '{print tolower($NF)}'; }
else
    die "SHA-256 verification requires sha256sum, shasum, or openssl"
fi
```

For CLI activation, create a private temporary directory, download and verify there, run staged `--version`, then activate in the destination filesystem:

```sh
backup="${target}.backup.$$"
staged="${target}.staged.$$"
cp "$downloaded" "$staged"
chmod 0755 "$staged"
if [ -e "$target" ]; then mv "$target" "$backup"; fi
if mv "$staged" "$target" && "$target" --version >/dev/null 2>&1; then
    rm -f "$backup"
else
    rm -f "$target" "$staged"
    if [ -e "$backup" ]; then mv "$backup" "$target"; fi
    die "activation failed; previous FarPilot was restored"
fi
```

A trap removes temporary paths without following symlinks. Reject a destination that is a symlink or a non-regular existing file.

- [ ] **Step 4: Implement dry run and Gateway delegation**

Dry run prints target, manifest URL, selected asset URL, version, destination, and role, but performs no directory creation, binary download, installer download, or execution.

Gateway mode extracts `installers.gateway.url` and `.sha256`, verifies the downloaded script exactly like a binary, then executes:

```sh
exec sh "$gateway_script" --manifest "$manifest_path" "$@"
```

The delegated script receives the already selected and verified manifest file, preventing a second latest-version race.

- [ ] **Step 5: Run and stress installer tests**

Run:

```bash
for run in 1 2 3 4 5; do bash tests/install/install_sh.sh; done
shellcheck install.sh tests/install/install_sh.sh
git diff --check
```

Expected: five consecutive passes, no ShellCheck findings, clean diff check.

- [ ] **Step 6: Commit checkpoint**

```bash
git add install.sh tests/install/install_sh.sh
git commit -m "feat: make Unix installs atomic and repeatable"
```

---

### Task 4: Versioned Windows Host installer

**Files:**
- Replace: `deploy/windows/install.ps1`
- Create: `deploy/windows/test-install.ps1`
- Modify: `.github/workflows/ci.yml`

- [ ] **Step 1: Write failing PowerShell layout and checksum tests**

Create `deploy/windows/test-install.ps1` as a plain PowerShell regression suite requiring no Pester module. It creates a temporary `LOCALAPPDATA`, a synthetic `farpilot.exe` fixture built by copying the current test binary, a local manifest object, and calls the installer through local-package parameters:

```powershell
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Installer = Join-Path $PSScriptRoot 'install.ps1'
$Temp = Join-Path ([IO.Path]::GetTempPath()) ('farpilot-install-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $Temp | Out-Null
try {
    $env:LOCALAPPDATA = Join-Path $Temp 'LocalAppData'
    $Package = Join-Path $Temp 'farpilot.exe'
    Copy-Item $env:FARPILOT_TEST_BINARY $Package
    $Sha = (Get-FileHash -Algorithm SHA256 $Package).Hash.ToLowerInvariant()
    & $Installer -LocalPackagePath $Package -LocalPackageVersion '0.2.0' -LocalPackageSha256 $Sha -NoStartupTask
    $Release = Join-Path $env:LOCALAPPDATA 'FarPilot\releases\0.2.0-x86_64-pc-windows-msvc\farpilot.exe'
    if (-not (Test-Path $Release -PathType Leaf)) { throw 'versioned release was not installed' }
    $Bin = Join-Path $env:LOCALAPPDATA 'FarPilot\bin'
    if ((Get-Item $Bin -Force).LinkType -ne 'Junction') { throw 'bin is not a junction' }
    & $Installer -LocalPackagePath $Package -LocalPackageVersion '0.2.0' -LocalPackageSha256 ('0' * 64) -NoStartupTask 2>$null
    throw 'checksum mismatch unexpectedly succeeded'
} catch {
    if ($_.Exception.Message -notmatch 'checksum') { throw }
} finally {
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $Temp
}
```

The final implementation may add helper assertions, but every test failure must throw and set a nonzero process exit.

- [ ] **Step 2: Run the Windows test and verify RED**

On Windows CI or DevBox, run:

```powershell
$env:FARPILOT_TEST_BINARY = (Resolve-Path target\release\farpilot.exe)
powershell -NoProfile -ExecutionPolicy Bypass -File deploy\windows\test-install.ps1
```

Expected: FAIL because the existing installer requires `BinaryUrl` and `Sha256` and has no versioned layout.

- [ ] **Step 3: Implement manifest and local-package inputs**

Replace the parameter block with:

```powershell
[CmdletBinding()]
param(
    [string]$Version,
    [string]$ManifestUrl,
    [string]$InstallDir,
    [switch]$NoStartupTask,
    [switch]$DryRun,
    [int]$Retain = 3,
    [string]$LocalPackagePath,
    [string]$LocalPackageVersion,
    [string]$LocalPackageSha256
)
```

Require all three local-package fields together. Otherwise fetch latest or pinned manifest over HTTPS, require schema 1, target `windows-x86_64`, format `exe`, a valid hash, and an HTTPS URL. Normalize `vX.Y.Z` to `X.Y.Z`.

- [ ] **Step 4: Implement safe download and verification**

Use `curl.exe` with `--fail --silent --show-error --location --proto =https --tlsv1.2`, connection timeout, and stalled-transfer timeout. Verify SHA-256 with .NET or `Get-FileHash`. Authenticode policy is:

```powershell
$signature = Get-AuthenticodeSignature $Package
if ($signature.Status -notin @('Valid', 'NotSigned')) {
    throw "FarPilot Authenticode signature is $($signature.Status)"
}
```

Run the staged executable with `--version`, require exit code 0, and parse exactly `farpilot <manifest-version>`.

- [ ] **Step 5: Implement lock, releases, junctions, and PATH**

Use an exclusive file stream at `%LOCALAPPDATA%\FarPilot\install.lock`. Stage under `releases\.staging.<release>.<pid>`, move only a complete release into `releases\<version>-x86_64-pc-windows-msvc`, and create installer-owned `current` and `bin` junctions. Before retargeting a junction, verify its existing target is inside the managed releases root.

Update the current-user PATH to put the active versioned release first and remove stale installer-owned release entries. Broadcast `WM_SETTINGCHANGE`. Keep the active release and two most recently used prior release directories.

- [ ] **Step 6: Implement managed process and startup-task behavior**

Before activation, stop the `FarPilot Host` task when running. Stop only processes whose executable path is under `%LOCALAPPDATA%\FarPilot\releases`. After activation, create or update the current-user, limited-run-level task pointing to `%LOCALAPPDATA%\FarPilot\bin\farpilot.exe host start` unless `-NoStartupTask`; restart it only when it was previously running or on a fresh default install.

Never remove `host-identity.json`, `host-config.json`, or any other file outside installer-owned release and junction paths.

- [ ] **Step 7: Add migration, rollback, retention, and dry-run tests**

Extend `deploy/windows/test-install.ps1` to verify:

```text
legacy bin/farpilot.exe migrates once
unmanaged nonempty bin directory is refused
junction outside managed root is refused
failed staged --version preserves current junction
running managed process is stopped; same-name unmanaged process is not
startup task is idempotent
four releases retain only active plus two prior
DryRun creates no FarPilot root
```

Use only temporary current-user paths and synthetic processes; never touch the developer's real `%LOCALAPPDATA%\FarPilot`.

- [ ] **Step 8: Run Windows tests and static checks**

Run:

```powershell
cargo build --release -p farpilot-cli
$env:FARPILOT_TEST_BINARY = (Resolve-Path target\release\farpilot.exe)
powershell -NoProfile -ExecutionPolicy Bypass -File deploy\windows\test-install.ps1
Invoke-ScriptAnalyzer deploy\windows\install.ps1,deploy\windows\test-install.ps1 -EnableExit
```

Expected: all tests pass and PSScriptAnalyzer exits 0.

- [ ] **Step 9: Add the Windows installer test to CI**

Add a Windows-only CI step after the release build:

```yaml
- name: Test Windows installer
  if: runner.os == 'Windows'
  shell: pwsh
  run: |
    $env:FARPILOT_TEST_BINARY = (Resolve-Path target/release/farpilot.exe)
    ./deploy/windows/test-install.ps1
```

Add a pinned PSScriptAnalyzer installation step and run it only against repository scripts.

- [ ] **Step 10: Commit checkpoint**

```bash
git add deploy/windows/install.ps1 deploy/windows/test-install.ps1 .github/workflows/ci.yml
git commit -m "feat: add versioned Windows installer"
```

---

### Task 5: Full Ubuntu Gateway installer and rollback

**Files:**
- Replace: `deploy/gateway/install.sh`
- Create: `tests/install/gateway_installer.sh`
- Modify: `tests/security/deployment_assets.sh`

- [ ] **Step 1: Write a failing command-shim Gateway test**

Create `tests/install/gateway_installer.sh`. It runs the installer against an isolated root via `FARPILOT_ROOT`, prepends shims for `id`, `useradd`, `install`, `systemctl`, `sshd`, `nginx`, `certbot`, `curl`, `apt-get`, and `ssh-keygen`, and records every command. The first test invokes:

```sh
FARPILOT_ROOT="$tmp/root" \
FARPILOT_TEST_EUID=0 \
PATH="$tmp/shims:/usr/bin:/bin" \
sh deploy/gateway/install.sh \
  --manifest "$tmp/manifest.json" \
  --domain gateway.example.com \
  --email operator@example.com
```

Assert generated state includes:

```text
/etc/farpilot/gateway.env mode 0600
/var/lib/farpilot/authorized_keys mode 0600
/etc/systemd/system/farpilot-gateway.service
/etc/ssh/sshd_config.d/90-farpilot.conf
/etc/nginx/sites-available/gateway.example.com
```

Assert the environment file contains synthetic values only and includes `FARPILOT_CERTBOT_EMAIL=operator@example.com`.

- [ ] **Step 2: Run the Gateway test and verify RED**

Run:

```bash
bash tests/install/gateway_installer.sh
```

Expected: FAIL because the current script accepts only a local binary path and cannot perform full provisioning.

- [ ] **Step 3: Implement strict arguments and supported-system detection**

The installer accepts:

```text
--manifest PATH
--domain HOSTNAME
--email ADDRESS
--version VERSION
--dry-run
```

On an existing install, domain and email are optional and loaded from `/etc/farpilot/gateway.env`. Require root unless `--dry-run`. Read `/etc/os-release` and accept only Ubuntu versions 20.04, 22.04, and 24.04. Validate domain with labels containing only ASCII letters, digits, and interior hyphens; validate email as one non-whitespace local part, `@`, and a DNS hostname.

- [ ] **Step 4: Implement verified binary selection**

Read target `linux-x86_64` or `linux-aarch64` from the already downloaded manifest passed by `install.sh`. Revalidate schema, version, HTTPS URL, format, and SHA-256. Download with bounded curl flags, verify digest, make executable, and require `farpilot --version` to equal the manifest version.

Never trust a binary path passed through an environment variable in production mode. Test mode redirects filesystem roots and command boundaries but still verifies the fixture digest.

- [ ] **Step 5: Implement idempotent first-install provisioning**

Use `apt-get` only for missing packages from this fixed set:

```text
nginx openssh-server certbot python3-certbot-nginx ca-certificates curl
```

Create the dedicated account and directories with existing restrictive modes. Compute the SSH Ed25519 host fingerprint with:

```bash
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub -E sha256 | awk '{print $2}'
```

Write `gateway.env` only when absent. Render Nginx with the validated domain rather than the Stage 0 hardcoded hostname. Preserve a preexisting environment file byte-for-byte.

Validate `sshd -t`, `nginx -t`, and `systemd-analyze verify` before reload or enable. Obtain a certificate noninteractively only when no matching certificate exists.

- [ ] **Step 6: Implement binary health rollback**

Before replacing `/usr/local/bin/farpilot`, copy it to a mode-0755 rollback path in `/var/lib/farpilot`. Install the new binary atomically, restart the service, then require:

```text
systemctl is-active --quiet farpilot-gateway.service
curl -fsS https://<domain>/health/live returns status ok
curl -fsS https://<domain>/health/ready returns status ok
```

On failure, restore the prior binary, restart, and report both the original health error and any rollback error. On a first install with no prior binary, stop and disable the failed service without deleting state.

- [ ] **Step 7: Add preservation, validation, rollback, and dry-run tests**

Extend the shim test to verify:

```text
second install leaves gateway.env byte-identical
SQLite and authorized_keys fixtures remain byte-identical
SSH keys and certificate directories are not removed
invalid domain/email fail before mutation
unsupported Ubuntu version fails before apt-get
sshd/nginx validation failure prevents reload
readiness failure restores old binary
rollback restart failure reports both failures
DryRun runs no install/systemctl/certbot/apt-get mutation command
```

- [ ] **Step 8: Run Gateway installer/security tests**

Run:

```bash
bash tests/install/gateway_installer.sh
bash tests/security/deployment_assets.sh
bash tests/security/sshd_restrictions.sh
shellcheck deploy/gateway/install.sh tests/install/gateway_installer.sh
git diff --check
```

Expected: all checks pass.

- [ ] **Step 9: Commit checkpoint**

```bash
git add deploy/gateway/install.sh tests/install/gateway_installer.sh tests/security/deployment_assets.sh
git commit -m "feat: add one-command Gateway deployment"
```

---

### Task 6: Stable bootstrap redirects

**Files:**
- Modify: `deploy/gateway/farpilot.polly.wang.nginx`
- Modify: `tests/security/deployment_assets.sh`
- Modify: `docs/stage0-runbook.md`

- [ ] **Step 1: Add failing exact-route deployment checks**

Extend `tests/security/deployment_assets.sh` to require exact locations and exact GitHub latest targets:

```bash
for asset in install.sh install.ps1 latest.json; do
  grep -Fq "location = /$asset" "$nginx"
  grep -Fq "https://github.com/Polly2014/FarPilot/releases/latest/download/$asset" "$nginx"
done
```

Also fail if a prefix or regex installer location can match `/pair`, `/v1`, `/health`, or `/ws/host`.

- [ ] **Step 2: Run the deployment check and verify RED**

Run:

```bash
bash tests/security/deployment_assets.sh
```

Expected: FAIL because bootstrap routes do not exist.

- [ ] **Step 3: Add exact Nginx redirects**

Add above the catch-all proxy:

```nginx
location = /install.sh {
    return 302 https://github.com/Polly2014/FarPilot/releases/latest/download/install.sh;
}

location = /install.ps1 {
    return 302 https://github.com/Polly2014/FarPilot/releases/latest/download/install.ps1;
}

location = /latest.json {
    return 302 https://github.com/Polly2014/FarPilot/releases/latest/download/manifest.json;
}
```

No query parameters are reflected, no local file path is accepted, and existing security headers remain inherited.

- [ ] **Step 4: Run Nginx and route checks**

Run:

```bash
bash tests/security/deployment_assets.sh
nginx -t -c "$(pwd)/deploy/gateway/farpilot.polly.wang.nginx"
```

If local `nginx -t` cannot use the standalone site fragment, run the repository's disposable Ubuntu/Nginx fixture instead of weakening the config.

- [ ] **Step 5: Document bootstrap deployment order**

Update `docs/stage0-runbook.md` to install the new site config and reload Nginx before announcing the first one-command release. Include three `curl -I` checks proving the redirects and a `curl -fsSL https://farpilot.polly.wang/latest.json` schema check after the first stable Release exists.

- [ ] **Step 6: Commit checkpoint**

```bash
git add deploy/gateway/farpilot.polly.wang.nginx tests/security/deployment_assets.sh docs/stage0-runbook.md
git commit -m "feat: expose stable installer endpoints"
```

---

### Task 7: Tag-gated multi-platform Release workflow

**Files:**
- Create: `.github/workflows/release.yml`
- Modify: `.github/workflows/ci.yml`
- Create: `tests/release/workflow_assets.sh`

- [ ] **Step 1: Write failing workflow asset checks**

Create `tests/release/workflow_assets.sh` to assert that `release.yml`:

- triggers only on `v*` tags and manual dry-run dispatch;
- gives `contents: write` only to the publish job;
- builds the five exact target names;
- runs the existing format, Clippy, tests, docs, deployment, and SSH security checks before publish;
- invokes `scripts/release_manifest.py` and `scripts/validate_release_assets.py`;
- uploads `install.sh`, `deploy/windows/install.ps1` as `install.ps1`, and `deploy/gateway/install.sh` as `install-gateway.sh`;
- creates a non-prerelease GitHub Release only from a tag ref.

Use YAML-aware parsing with Ruby's standard `yaml` library on CI rather than grep-only structural assertions.

- [ ] **Step 2: Run the workflow check and verify RED**

Run:

```bash
bash tests/release/workflow_assets.sh
```

Expected: FAIL because `.github/workflows/release.yml` does not exist.

- [ ] **Step 3: Create quality and security prerequisite jobs**

Create `release.yml` with:

```yaml
name: Release
on:
  push:
    tags: ['v*']
  workflow_dispatch:
    inputs:
      dry_run:
        description: Build and verify assets without publishing
        type: boolean
        default: true
permissions:
  contents: read
```

Reuse exact commands from `ci.yml`; do not call one workflow from another with broader permissions. The SSH integration job installs OpenSSH Server and uses the existing disposable test.

- [ ] **Step 4: Add five native build jobs**

Use this matrix shape:

```yaml
strategy:
  fail-fast: false
  matrix:
    include:
      - runner: ubuntu-24.04
        target: x86_64-unknown-linux-musl
        asset: farpilot-linux-x86_64
      - runner: ubuntu-24.04-arm
        target: aarch64-unknown-linux-musl
        asset: farpilot-linux-aarch64
      - runner: macos-15-intel
        target: x86_64-apple-darwin
        asset: farpilot-macos-x86_64
      - runner: macos-15
        target: aarch64-apple-darwin
        asset: farpilot-macos-aarch64
      - runner: windows-2025
        target: x86_64-pc-windows-msvc
        asset: farpilot-windows-x86_64.exe
```

Linux jobs install musl tools and the requested target. Each job builds `farpilot-cli --release`, copies only the binary into an artifact directory under the exact asset name, runs native `--version` where the runner can execute the target, and uploads an Actions artifact with 1-day retention.

- [ ] **Step 5: Add manifest assembly and validation**

A Linux assembly job downloads all build artifacts, copies installer scripts under their release asset names, derives the version from `GITHUB_REF_NAME` after strict semver validation, invokes the generator with five `--asset` arguments and `--installer gateway=release/install-gateway.sh`, then invokes the validator against the assembled directory.

Upload the complete release directory as one Actions artifact. Assert no extra executable or archive is present.

- [ ] **Step 6: Add least-privilege publish job**

The publish job has:

```yaml
permissions:
  contents: write
```

It runs only when `github.ref_type == 'tag'` and manual `dry_run` is not true. Use `gh release create "$GITHUB_REF_NAME" release/* --verify-tag --title "FarPilot $version" --notes-from-tag`, with `GH_TOKEN: ${{ github.token }}`. Refuse an existing release rather than replacing assets.

- [ ] **Step 7: Add installer checks to normal CI**

Extend `ci.yml` with:

```text
Python manifest unit tests
POSIX installer tests on Ubuntu and macOS
Gateway command-shim tests on Ubuntu
Windows installer tests on Windows
ShellCheck and PSScriptAnalyzer
workflow asset structure test
```

Normal CI never publishes or requests `contents: write`.

- [ ] **Step 8: Run all local workflow/release checks**

Run:

```bash
python3 -m unittest discover -s tests/release -v
bash tests/release/workflow_assets.sh
bash tests/install/install_sh.sh
bash tests/install/gateway_installer.sh
bash tests/security/deployment_assets.sh
cargo test --workspace
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --all-features -- -D warnings
git diff --check
```

Expected: all commands pass. Run Windows installer tests on Windows CI before considering the task complete.

- [ ] **Step 9: Commit checkpoint**

```bash
git add .github/workflows/ci.yml .github/workflows/release.yml tests/release/workflow_assets.sh
git commit -m "ci: publish verified multi-platform releases"
```

---

### Task 8: User documentation and full closeout verification

**Files:**
- Modify: `README.md`
- Modify: `docs/stage0-runbook.md`
- Modify: `docs/specs/2026-11-13-farpilot-one-command-install-design.md` only if implementation discovers a factual mismatch
- Create: `docs/installer-security.md`

- [ ] **Step 1: Write documentation assertions**

Add checks to `tests/workspace_layout.sh` requiring README and runbook to contain:

```text
curl -fsSL https://farpilot.polly.wang/install.sh | sh
irm https://farpilot.polly.wang/install.ps1 | iex
--version v0.1.1
gateway --domain
--dry-run
SHA-256
```

Require `docs/installer-security.md` to name the Stage 0 trust boundary and state that SHA-256 does not protect against simultaneous hosting-account and manifest compromise.

- [ ] **Step 2: Run documentation assertions and verify RED**

Run:

```bash
bash tests/workspace_layout.sh
```

Expected: FAIL because README and the security document do not yet contain the required text.

- [ ] **Step 3: Update README and runbook**

Replace the obsolete README statement that FarPilot is only scaffolded. Add concise latest-install commands, pinned versions, Windows parameters, Gateway first install and upgrade, dry run, supported platforms, and links to the detailed runbook/security document.

Update the runbook with:

- bootstrap endpoint deployment order;
- full first-install command;
- parameter-free Gateway upgrade command;
- version pin/downgrade examples;
- health rollback behavior;
- manual binary rollback command;
- Windows versioned release locations;
- PATH troubleshooting;
- no-background-update statement.

- [ ] **Step 4: Write installer security documentation**

Create `docs/installer-security.md` covering:

```text
HTTPS and GitHub Release trust boundary
mandatory manifest SHA-256
what SHA-256 does and does not prove
Windows optional Authenticode behavior
managed path ownership checks
Gateway root boundary
secret/log exclusions
rollback guarantees
future Artifact Attestation/Cosign enhancement
safe alternative: download installer, inspect it, then execute locally
```

Include non-piped equivalents:

```bash
curl -fsSLo install.sh https://farpilot.polly.wang/install.sh
less install.sh
sh install.sh
```

```powershell
irm https://farpilot.polly.wang/install.ps1 -OutFile install.ps1
Get-Content .\install.ps1
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

- [ ] **Step 5: Run the complete local verification matrix**

Run:

```bash
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --all-features -- -D warnings
cargo test --workspace
cargo test --doc --workspace
python3 -m unittest discover -s tests/release -v
bash tests/workspace_layout.sh
bash tests/install/install_sh.sh
bash tests/install/gateway_installer.sh
bash tests/security/deployment_assets.sh
bash tests/security/sshd_restrictions.sh
bash tests/e2e/gateway-host.sh
bash tests/release/workflow_assets.sh
shellcheck install.sh deploy/gateway/install.sh tests/install/*.sh tests/release/*.sh
```

On Windows run:

```powershell
cargo test --workspace --all-targets
cargo build --release -p farpilot-cli
$env:FARPILOT_TEST_BINARY = (Resolve-Path target\release\farpilot.exe)
.\deploy\windows\test-install.ps1
Invoke-ScriptAnalyzer .\deploy\windows\install.ps1,.\deploy\windows\test-install.ps1 -EnableExit
```

Expected: zero failures and zero warnings.

- [ ] **Step 6: Perform release dry run without publishing**

Run the `Release` workflow through `workflow_dispatch` with `dry_run=true`. Verify the assembled artifact contains exactly the five binaries, three installer scripts, and `manifest.json`. Download the artifact into a new empty directory and run `scripts/validate_release_assets.py` against it without executing downloaded binaries from inside that directory.

Expected: assembly and validation succeed; no GitHub Release is created.

- [ ] **Step 7: Perform real-device acceptance before the first tag**

Use synthetic version `0.2.0-rc` local packages or the dry-run artifact to verify:

```text
Apple Silicon Mac fresh install and pinned reinstall
Windows ordinary-user fresh install
Windows running-Host upgrade and Scheduled Task restart
Ubuntu Stage 0 Gateway upgrade with database/config hashes unchanged
Gateway simulated readiness failure and automatic rollback
Mac and Moshi reconnect after Gateway recovery
```

Record sanitized evidence in `docs/stage0-acceptance.md` without hostnames, addresses, tokens, terminal content, or private material.

- [ ] **Step 8: Final independent review**

Request an independent code and security review of the complete diff against the approved design. Fix every confirmed Critical or Important issue with a failing regression test and rerun Step 5.

- [ ] **Step 9: Commit checkpoint**

```bash
git add README.md docs/stage0-runbook.md docs/installer-security.md tests/workspace_layout.sh docs/stage0-acceptance.md
git commit -m "docs: publish one-command installation guide"
```

- [ ] **Step 10: Stop before external release publication**

Show:

```bash
git status --short --branch
git log --oneline --decorate -10
gh release list --repo Polly2014/FarPilot --limit 5
```

Do not create a tag, push a tag, or publish a Release without a new explicit user instruction naming the intended version.
