# FarPilot Stage 0.5 Live Acceptance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close every self-use acceptance path that is not blocked by code signing across Polly's real Gateway, Windows DevBox, Mac, and iPhone, while proving live upgrade and rollback without publishing a stable or preview Release.

**Architecture:** Preparation is committed and verified before any live mutation. Window A deploys the reviewed CRT Gateway binary and closes real browser/Moshi acceptance; Window B uses loopback-only HTTPS manifests to exercise production installers, upgrades the live Gateway from committed version 0.1.0 to committed version 0.1.1, then injects a private test-only 0.1.2 startup failure to prove automatic rollback. Each window has a separate explicit authorization gate and fail-closed rollback rules.

**Tech Stack:** Rust stable, Cargo, Python 3 standard library, POSIX shell, OpenSSL, systemd, Nginx, OpenSSH, SQLite, GitHub Actions/CLI, Safari, Moshi.

**Approved specification:** `docs/specs/2026-11-16-farpilot-stage-0-5-live-acceptance-design.md`

**Repository policy:** Do not commit, push, dispatch workflows, copy artifacts to a live host, run `sudo`, restart services, mutate real devices, or delete private evidence unless the corresponding step has explicit execution-session authorization. Approval of this plan is not approval of Window A or Window B.

---

## File map

```text
FarPilot/
├── Cargo.toml
├── Cargo.lock
├── .github/workflows/
│   ├── ci.yml
│   └── release.yml
├── scripts/acceptance/
│   ├── __init__.py
│   ├── loopback_https.py
│   ├── make_failure_candidate.py
│   └── make_loopback_manifest.py
├── tests/acceptance/
│   ├── __init__.py
│   └── test_acceptance_tools.py
├── docs/
│   ├── code-signing-policy.md
│   ├── public-readiness-audit.md
│   ├── signpath-application.md
│   ├── stage0-acceptance.md
│   ├── stage0-runbook.md
│   ├── plans/
│   │   ├── 2026-11-14-farpilot-signpath-readiness-implementation.md
│   │   └── 2026-11-16-farpilot-stage-0-5-live-acceptance-implementation.md
│   └── specs/
│       └── 2026-11-16-farpilot-stage-0-5-live-acceptance-design.md
├── README.md
└── tests/workspace_layout.sh
```

Tracked acceptance scripts contain no deployment values. Every real hostname, IP, token, key, fingerprint, database copy, raw log, temporary certificate, and candidate artifact lives outside the repository under `$CLAUDE_JOB_DIR/tmp` locally or a mode-0700 root-owned directory on the Gateway.

---

### Task 1: Record the SignPath outcome and freeze the Stage 0.5 design

**Files:**
- Modify: `README.md`
- Modify: `docs/code-signing-policy.md`
- Modify: `docs/plans/2026-11-14-farpilot-signpath-readiness-implementation.md`
- Modify: `docs/public-readiness-audit.md`
- Modify: `docs/signpath-application.md`
- Modify: `docs/stage0-acceptance.md`
- Modify: `tests/workspace_layout.sh`
- Create: `docs/specs/2026-11-16-farpilot-stage-0-5-live-acceptance-design.md`
- Create: `docs/plans/2026-11-16-farpilot-stage-0-5-live-acceptance-implementation.md`

- [ ] **Step 1: Verify the current local outcome contract**

Run:

```bash
bash tests/workspace_layout.sh
git diff --check
rg -n 'External outcome: REJECTED — learned 2026-11-16|NOT APPROVED AT THIS TIME|NOT YET SUFFICIENT' \
  README.md docs tests/workspace_layout.sh \
  --glob '!**/2026-11-16-farpilot-stage-0-5-live-acceptance-implementation.md'
! rg -n 'External outcome: PENDING|SUBMITTED — EXTERNAL REVIEW PENDING|review is pending' \
  README.md docs tests/workspace_layout.sh \
  --glob '!**/2026-11-16-farpilot-stage-0-5-live-acceptance-implementation.md'
```

Expected: contract tests and diff checks pass; rejected/reapplication language exists; no stale pending status exists.

- [ ] **Step 2: Verify no private correspondence was copied**

Run:

```bash
! rg -n -i 'oss-support@|Phillip Deng|Your SignPath Foundation Team|change-subscription' \
  README.md docs tests/workspace_layout.sh \
  --glob '!**/2026-11-16-farpilot-stage-0-5-live-acceptance-implementation.md'
```

Expected: exit 0 because only sanitized outcome facts are tracked.

- [ ] **Step 3: Review the exact tracked scope**

Run:

```bash
git status --short
git diff --stat
git diff -- README.md docs tests/workspace_layout.sh
```

Expected: only the nine files listed above are in this checkpoint. No production code, secret, binary, raw report, or generated artifact is included.

- [ ] **Step 4: Authorization checkpoint for commit and push**

Stop and present:

```text
SignPath outcome files
Stage 0.5 design path
Stage 0.5 plan path
workspace_layout result
diff --check result
exact file list
```

Do not commit or push without explicit authorization.

If authorized, run:

```bash
git switch -c stage05/live-acceptance
git add README.md \
  docs/code-signing-policy.md \
  docs/plans/2026-11-14-farpilot-signpath-readiness-implementation.md \
  docs/public-readiness-audit.md \
  docs/signpath-application.md \
  docs/stage0-acceptance.md \
  docs/specs/2026-11-16-farpilot-stage-0-5-live-acceptance-design.md \
  docs/plans/2026-11-16-farpilot-stage-0-5-live-acceptance-implementation.md \
  tests/workspace_layout.sh
git commit -m "docs: record SignPath outcome and Stage 0.5 design"
git push -u origin stage05/live-acceptance
```

Expected: the branch is pushed; `main` is unchanged unless Polly separately authorizes merge.

---

### Task 2: Add loopback-only acceptance tooling with TDD

**Files:**
- Create: `scripts/acceptance/__init__.py`
- Create: `scripts/acceptance/make_loopback_manifest.py`
- Create: `scripts/acceptance/make_failure_candidate.py`
- Create: `scripts/acceptance/loopback_https.py`
- Create: `tests/acceptance/__init__.py`
- Create: `tests/acceptance/test_acceptance_tools.py`
- Modify: `.github/workflows/ci.yml`
- Modify: `.github/workflows/release.yml`

- [ ] **Step 1: Write failing acceptance-tool tests**

Create `tests/acceptance/test_acceptance_tools.py`:

```python
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "acceptance"))

import make_failure_candidate
import make_loopback_manifest

TARGETS = {
    "linux-x86_64": "farpilot-linux-x86_64",
    "linux-aarch64": "farpilot-linux-aarch64",
    "macos-x86_64": "farpilot-macos-x86_64",
    "macos-aarch64": "farpilot-macos-aarch64",
    "windows-x86_64": "farpilot-windows-x86_64.exe",
}


class AcceptanceManifestTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.assets = {}
        for target, name in TARGETS.items():
            path = self.root / name
            path.write_bytes((target + "\n").encode())
            self.assets[target] = path
        self.gateway = self.root / "install-gateway.sh"
        self.gateway.write_text("#!/bin/sh\nexit 0\n")

    def tearDown(self):
        self.temp.cleanup()

    def test_manifest_uses_only_loopback_https_urls_and_exact_digests(self):
        manifest = make_loopback_manifest.build_manifest(
            "0.1.1",
            "https://127.0.0.1:18443/",
            self.assets,
            self.gateway,
        )
        self.assertEqual(manifest["schema_version"], 1)
        self.assertEqual(manifest["version"], "0.1.1")
        self.assertEqual(manifest["tag"], "v0.1.1")
        self.assertEqual(set(manifest["assets"]), set(TARGETS))
        for target, path in self.assets.items():
            record = manifest["assets"][target]
            self.assertEqual(
                record["sha256"], hashlib.sha256(path.read_bytes()).hexdigest()
            )
            self.assertEqual(
                record["url"], f"https://127.0.0.1:18443/{path.name}"
            )
        self.assertEqual(
            manifest["installers"]["gateway"]["url"],
            "https://127.0.0.1:18443/install-gateway.sh",
        )

    def test_non_loopback_or_non_https_base_url_is_rejected(self):
        for url in [
            "http://127.0.0.1:18443/",
            "https://localhost:18443/",
            "https://example.com/",
            "https://127.0.0.2:18443/",
        ]:
            with self.subTest(url=url), self.assertRaises(SystemExit):
                make_loopback_manifest.build_manifest(
                    "0.1.1", url, self.assets, self.gateway
                )

    def test_manifest_rejects_missing_target_and_symlink(self):
        incomplete = dict(self.assets)
        incomplete.pop("linux-aarch64")
        with self.assertRaises(SystemExit):
            make_loopback_manifest.build_manifest(
                "0.1.1", "https://127.0.0.1:18443/", incomplete, self.gateway
            )
        link = self.root / "linked"
        link.symlink_to(self.assets["linux-x86_64"])
        linked = dict(self.assets)
        linked["linux-x86_64"] = link
        with self.assertRaises(SystemExit):
            make_loopback_manifest.build_manifest(
                "0.1.1", "https://127.0.0.1:18443/", linked, self.gateway
            )


class FailureCandidateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def test_gateway_candidate_reports_version_then_fails_startup(self):
        path = self.root / "farpilot"
        make_failure_candidate.write_candidate(path, "0.1.2", "gateway-start")
        version = subprocess.run(
            [path, "--version"], check=True, capture_output=True, text=True
        )
        self.assertEqual(version.stdout, "farpilot 0.1.2\n")
        started = subprocess.run([path, "gateway", "serve"], capture_output=True)
        self.assertEqual(started.returncode, 42)

    def test_cli_candidate_fails_only_after_activation(self):
        staged = self.root / "staged-farpilot"
        target = self.root / "bin" / "farpilot"
        target.parent.mkdir()
        make_failure_candidate.write_candidate(staged, "0.1.2", "cli-post-activation")
        env = os.environ | {
            "FARPILOT_ACCEPTANCE_TARGET": str(target),
            "FARPILOT_ACCEPTANCE_FAIL_AFTER_ACTIVATION": "1",
        }
        self.assertEqual(
            subprocess.run(
                [staged, "--version"], env=env, check=True, capture_output=True, text=True
            ).stdout,
            "farpilot 0.1.2\n",
        )
        target.write_bytes(staged.read_bytes())
        target.chmod(0o755)
        self.assertEqual(subprocess.run([target, "--version"], env=env).returncode, 42)


if __name__ == "__main__":
    unittest.main()
```

Create empty `scripts/acceptance/__init__.py` and `tests/acceptance/__init__.py`.

- [ ] **Step 2: Run tests and verify RED**

Run:

```bash
python3 -m unittest discover -s tests/acceptance -p 'test_*.py' -v
```

Expected: import errors because the three acceptance scripts do not exist.

- [ ] **Step 3: Implement the loopback manifest generator**

Create `scripts/acceptance/make_loopback_manifest.py`:

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
```

- [ ] **Step 4: Implement deterministic failure candidates**

Create `scripts/acceptance/make_failure_candidate.py`:

```python
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
    printf 'farpilot %s\\n' "$version"
    exit 0
fi
printf '%s\\n' 'synthetic Stage 0.5 failure candidate' >&2
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
```

- [ ] **Step 5: Implement the no-log loopback HTTPS server**

Create `scripts/acceptance/loopback_https.py`:

```python
#!/usr/bin/env python3
import argparse
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import ssl


def checked_file(path: Path, label: str) -> Path:
    if path.is_symlink():
        raise SystemExit(f"{label} must not be a symbolic link")
    try:
        resolved = path.resolve(strict=True)
    except OSError as error:
        raise SystemExit(f"{label} does not exist") from error
    if not resolved.is_file():
        raise SystemExit(f"{label} must be a regular file")
    return resolved


def checked_root(path: Path) -> Path:
    if path.is_symlink():
        raise SystemExit("root must not be a symbolic link")
    resolved = path.resolve(strict=True)
    if not resolved.is_dir():
        raise SystemExit("root must be a directory")
    return resolved


class QuietStaticHandler(SimpleHTTPRequestHandler):
    def log_message(self, format: str, *args: object) -> None:
        return

    def list_directory(self, path: str):
        self.send_error(403, "directory listing disabled")
        return None


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--cert", type=Path, required=True)
    parser.add_argument("--key", type=Path, required=True)
    parser.add_argument("--port", type=int, required=True)
    args = parser.parse_args()
    if not 1024 <= args.port <= 65535:
        raise SystemExit("port must be between 1024 and 65535")
    root = checked_root(args.root)
    cert = checked_file(args.cert, "certificate")
    key = checked_file(args.key, "private key")
    handler = partial(QuietStaticHandler, directory=str(root))
    server = ThreadingHTTPServer(("127.0.0.1", args.port), handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(cert, key)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    print(f"READY https://127.0.0.1:{args.port}/", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
```

- [ ] **Step 6: Run acceptance-tool tests and verify GREEN**

Run:

```bash
python3 -m unittest discover -s tests/acceptance -p 'test_*.py' -v
python3 -m py_compile scripts/acceptance/*.py
```

Expected: five tests pass; Python compilation exits 0.

- [ ] **Step 7: Wire the tests into CI and Release quality gates**

In `.github/workflows/ci.yml`, add immediately after `Test release tooling`:

```yaml
      - name: Test live-acceptance tooling
        run: python3 -m unittest discover -s tests/acceptance -p 'test_*.py' -v
```

In `.github/workflows/release.yml`, add immediately after `Test release manifest tools`:

```yaml
      - name: Test live-acceptance tooling
        run: python3 -m unittest discover -s tests/acceptance -p 'test_*.py' -v
```

- [ ] **Step 8: Run the complete local preflight**

Run:

```bash
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --all-features -- -D warnings
cargo test --workspace --all-targets
cargo test --doc --workspace
python3 -m unittest discover -s tests/release -p 'test_*.py' -v
python3 -m unittest discover -s tests/acceptance -p 'test_*.py' -v
bash tests/install/install_sh.sh
bash tests/install/gateway_installer.sh
bash tests/workspace_layout.sh
bash tests/security/deployment_assets.sh
bash tests/security/sshd_restrictions.sh
bash tests/e2e/gateway-host.sh
git diff --check
```

Expected: every command exits 0.

- [ ] **Step 9: Authorization checkpoint for acceptance-tool commit and push**

Stop with the test evidence and exact diff. Do not commit or push without explicit authorization.

If authorized:

```bash
git add scripts/acceptance tests/acceptance .github/workflows/ci.yml .github/workflows/release.yml
git commit -m "test: add private live-acceptance tooling"
git push
```

---

### Task 3: Build and verify the Window A 0.1.0 candidate

**Files:**
- No tracked changes
- Private output: `$CLAUDE_JOB_DIR/tmp/farpilot-stage05-window-a/`

- [ ] **Step 1: Confirm branch CI and source version**

Run:

```bash
test "$(git status --porcelain | wc -l | tr -d ' ')" = 0
test "$(git rev-parse HEAD)" = "$(git rev-parse @{upstream})"
rg -n '^version = "0\.1\.0"$' Cargo.toml
gh run list -R Polly2014/FarPilot --branch "$(git branch --show-current)" --limit 5
```

Expected: clean tree, pushed HEAD, workspace version 0.1.0, latest branch CI success.

- [ ] **Step 2: External-action authorization checkpoint**

Stop and request explicit authorization to dispatch a GitHub Release dry run. State that it builds artifacts but publishes no tag or Release.

- [ ] **Step 3: Dispatch and monitor the 0.1.0 dry run**

If authorized:

```bash
started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
gh workflow run release.yml -R Polly2014/FarPilot \
  --ref "$(git branch --show-current)" \
  -f dry_run=true \
  -f version=0.1.0
run_id=
for attempt in $(seq 1 30); do
  run_id=$(gh run list -R Polly2014/FarPilot \
    --workflow Release \
    --branch "$(git branch --show-current)" \
    --event workflow_dispatch \
    --limit 10 \
    --json databaseId,createdAt \
    --jq "map(select(.createdAt >= \"$started\"))[0].databaseId // empty")
  [ -z "$run_id" ] || break
  sleep 2
done
[ -n "$run_id" ] || { printf '%s\n' 'new Release dry run not found' >&2; exit 1; }
gh run watch "$run_id" -R Polly2014/FarPilot --exit-status
```

Expected: every quality/build/assembly job succeeds and the publish job is skipped.

- [ ] **Step 4: Download and validate the exact artifact privately**

Run:

```bash
window_a="$CLAUDE_JOB_DIR/tmp/farpilot-stage05-window-a"
rm -rf "$window_a"
install -d -m 700 "$window_a"
gh run download "$run_id" -R Polly2014/FarPilot -n release-complete -D "$window_a/release"
python3 scripts/validate_release_assets.py \
  --manifest "$window_a/release/manifest.json" \
  --release-dir "$window_a/release" \
  --reported-version 0.1.0
find "$window_a/release" -maxdepth 1 -type f -print | sort
```

Expected: exact nine-file release assembly, valid digests, reported version 0.1.0. Do not paste filenames with private paths into public documents.

- [ ] **Step 5: Stop before Window A**

Present source SHA, run URL, artifact validation, and private directory mode. Do not connect to or modify the Gateway without separate Window A authorization.

---

### Task 4: Prepare Window A private baseline and rollback bundle

**Files:**
- No tracked changes
- Local private evidence: `$CLAUDE_JOB_DIR/tmp/farpilot-stage05-window-a/`
- Gateway private evidence: `/root/.cache/farpilot-stage05-window-a/`

- [ ] **Step 1: Require private environment variables without printing them**

In the local shell, require:

```bash
: "${FARPILOT_ACCEPTANCE_SSH_HOST:?set privately}"
: "${FARPILOT_ACCEPTANCE_SSH_PROFILE:?set privately}"
: "${FARPILOT_ACCEPTANCE_DOMAIN:?set privately}"
```

These values must not be written to repository files, shell history exports committed to disk, or chat output.

- [ ] **Step 2: Collect the non-mutating live baseline**

Run privately:

```bash
curl -fsS --max-time 10 "https://$FARPILOT_ACCEPTANCE_DOMAIN/health/live" >/dev/null
curl -fsS --max-time 10 "https://$FARPILOT_ACCEPTANCE_DOMAIN/health/ready" >/dev/null
ssh -o BatchMode=yes -o ConnectTimeout=10 "$FARPILOT_ACCEPTANCE_SSH_PROFILE" true
ssh "$FARPILOT_ACCEPTANCE_SSH_HOST" \
  'sudo systemctl is-active --quiet farpilot-gateway.service && sudo /usr/local/bin/farpilot --version'
```

Expected: both health checks pass, existing Mac access works, service is active, version is recorded privately.

- [ ] **Step 3: Create the root-private backup and invariant report**

Run one quoted remote script through SSH. It must:

```text
umask 077
create /root/.cache/farpilot-stage05-window-a with mode 0700
copy /usr/local/bin/farpilot
copy /etc/farpilot/gateway.env
copy /var/lib/farpilot/farpilot.db
copy /var/lib/farpilot/authorized_keys
copy managed systemd, sshd, and Nginx files
record SHA-256 for immutable files, SSH host keys, and TLS material
record logical counts and opaque hashed identifiers for active Hosts/devices/grants
record an authorized_keys normalized fingerprint set without key bodies
run sshd -t, nginx -t, and systemd-analyze verify
```

The private report path is `/root/.cache/farpilot-stage05-window-a/baseline.json`, mode 0600. The command must print only `BASELINE_OK` or a generic failure.

- [ ] **Step 4: Verify rollback binary and candidate privately**

Copy the Window A `farpilot-linux-x86_64` candidate to the private Gateway directory, then run:

```bash
ssh "$FARPILOT_ACCEPTANCE_SSH_HOST" \
  'sudo chmod 0700 /root/.cache/farpilot-stage05-window-a && \
   sudo /root/.cache/farpilot-stage05-window-a/farpilot-linux-x86_64 --version && \
   sudo /root/.cache/farpilot-stage05-window-a/farpilot.before --version'
```

Expected: both report `farpilot 0.1.0` and source SHA provenance is retained privately.

- [ ] **Step 5: Window A authorization checkpoint**

Present only:

```text
source SHA
dry-run run URL
health baseline Pass
existing Mac baseline Pass
backup Pass
syntax validation Pass
candidate/rollback version Pass
private evidence locations and modes
expected short service restart
rollback command prepared
```

Stop. Do not replace the binary or restart the service until Polly explicitly authorizes Window A.

---

### Task 5: Execute Window A live deployment and real-device acceptance

**Files:**
- No tracked changes during live execution

- [ ] **Step 1: Atomically deploy the Window A candidate**

After explicit authorization, execute a remote script that:

```text
copies the current binary to a rollback path on the same filesystem
installs the candidate to /usr/local/bin/farpilot.stage05
fsyncs and renames it over /usr/local/bin/farpilot
restarts farpilot-gateway.service
checks systemd active, /health/live, and /health/ready
checks Host online state
```

If any service-level check fails, restore the backup binary, restart, verify live/ready, print only `ROLLED_BACK`, and stop Window A.

- [ ] **Step 2: Re-run the existing Mac regression**

Run:

```bash
ssh -o BatchMode=yes -o ConnectTimeout=10 "$FARPILOT_ACCEPTANCE_SSH_PROFILE" true
```

Expected: existing authorized Mac still attaches. Failure triggers binary rollback before any new pairing token is created.

- [ ] **Step 3: Manually verify desktop keyboard and semantics**

With a fresh real pairing token in a desktop browser:

```text
Tab order reaches device name, public-key field, and submit button once each
visible focus ring is present
labels are announced or exposed correctly by browser accessibility inspection
empty submit focuses device name and shows INVALID DEVICE NAME
```

Record only Pass/Fail and browser family/version.

- [ ] **Step 4: Observe a natural five-minute expiry**

Create a new real token and do not modify clocks or expiry data. Observe the live page until `00:00`, then submit syntactically valid test data.

Expected: the page transitions to Expired and the claim is rejected. Record only duration class and Pass/Fail; delete the real URL/token from private notes after the check.

- [ ] **Step 5: Verify iPhone Safari software-keyboard reachability**

On the real iPhone:

```text
open a fresh pairing URL in Safari
focus device name and public-key fields
show the software keyboard
verify the submit control remains reachable in portrait
rotate to landscape and back
return to portrait and submit only after reachability is proven
```

Record iOS/Safari major version, viewport orientation, and Pass/Fail only.

- [ ] **Step 6: Complete the real QR → Safari → Moshi flow**

```text
create/select a new Moshi Ed25519 key
copy only its public key into Safari
use a non-sensitive synthetic device display name
submit and verify PAIRING COMPLETE
verify only allowlisted host/port/user/fingerprint information appears
save the Moshi profile
connect to Herdr, detach, and reconnect to the same workspace
```

Do not paste the QR, token, fingerprint, key, device ID, Host ID, terminal content, or screenshot into chat or tracked files.

- [ ] **Step 7: Verify revocation and re-pair**

```text
revoke the Moshi device through the existing operator command
verify its active Attach process terminates
verify reconnect fails
create/select a new Moshi key
pair again with a new token
verify Herdr access returns
verify the original Mac still works
```

Expected: old key remains denied; new key works; unrelated Mac authorization remains unchanged.

- [ ] **Step 8: Review logs and logical state privately**

Privately inspect Nginx and journald for:

```text
pairing token or full pairing URL
SSH public-key body
terminal payload or prompt
repository path
private environment value
```

Compare immutable hashes and logical state invariants against `baseline.json`, allowing only the explicit Moshi pair/revoke/re-pair changes.

Any leak or unrelated state change is Fail. Invalidate affected values before cleanup.

- [ ] **Step 9: Window A completion checkpoint**

Report only sanitized results. Do not commit them until Polly confirms the Window A observations are accurate.

---

### Task 6: Record Window A and prepare version 0.1.1

**Files:**
- Modify: `docs/stage0-acceptance.md`
- Modify: `docs/stage0-runbook.md`
- Modify: `Cargo.toml`
- Modify: `Cargo.lock`
- Create: `tests/acceptance/test_version_contract.py`

- [ ] **Step 1: Write the sanitized Window A result**

Update `docs/stage0-acceptance.md` only with:

```text
source SHA and semantic version
Window A date
Pass/Fail for live CRT deployment
Pass/Fail for natural 00:00 transition
Pass/Fail for keyboard/semantics
Pass/Fail for iPhone Safari keyboard
Pass/Fail for real QR/Moshi
Pass/Fail for revocation/re-pair
Pass/Fail for logs and state invariants
whether rollback was needed
```

Update `docs/stage0-runbook.md` with repeatable stop conditions and sanitized operator steps. Do not add real commands containing deployment values.

- [ ] **Step 2: Write a failing version contract**

Create `tests/acceptance/test_version_contract.py`:

```python
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]


class Stage05VersionContract(unittest.TestCase):
    def test_workspace_version_is_stage05_candidate(self):
        cargo = (ROOT / "Cargo.toml").read_text()
        self.assertRegex(cargo, r'(?m)^version = "0\.1\.1"$')
        lock = (ROOT / "Cargo.lock").read_text()
        for crate in [
            "farpilot-cli",
            "farpilot-core",
            "farpilot-gateway",
            "farpilot-host",
        ]:
            self.assertRegex(
                lock,
                rf'(?s)name = "{re.escape(crate)}"\nversion = "0\.1\.1"',
            )


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 3: Run the version test and verify RED**

Run:

```bash
python3 -m unittest tests.acceptance.test_version_contract -v
```

Expected: FAIL because the workspace and lockfile still contain 0.1.0.

- [ ] **Step 4: Bump the committed candidate version**

Change `Cargo.toml` workspace version from `0.1.0` to `0.1.1`, then run:

```bash
cargo check --workspace
```

Expected: Cargo updates all four workspace-package entries in `Cargo.lock` to 0.1.1.

- [ ] **Step 5: Run the version test and full suite GREEN**

Run the complete preflight from Task 2 Step 8 plus:

```bash
python3 -m unittest tests.acceptance.test_version_contract -v
```

Expected: all commands pass.

- [ ] **Step 6: Commit/push authorization checkpoint**

Stop with Window A sanitized diff, version diff, tests, and exact file list. Do not commit or push without explicit authorization.

If authorized:

```bash
git add docs/stage0-acceptance.md docs/stage0-runbook.md \
  Cargo.toml Cargo.lock tests/acceptance/test_version_contract.py
git commit -m "test: complete live pairing acceptance"
git push
```

---

### Task 7: Build and validate the Window B 0.1.1 candidate

**Files:**
- No tracked changes
- Private output: `$CLAUDE_JOB_DIR/tmp/farpilot-stage05-window-b/`

- [ ] **Step 1: Require clean pushed source and successful CI**

Run:

```bash
test "$(git status --porcelain | wc -l | tr -d ' ')" = 0
test "$(git rev-parse HEAD)" = "$(git rev-parse @{upstream})"
python3 -m unittest tests.acceptance.test_version_contract -v
gh run list -R Polly2014/FarPilot --branch "$(git branch --show-current)" --limit 5
```

Expected: clean pushed 0.1.1 source and green CI.

- [ ] **Step 2: External-action authorization checkpoint**

Stop and request explicit authorization to dispatch the 0.1.1 Release dry run.

- [ ] **Step 3: Dispatch, monitor, download, and validate**

If authorized:

```bash
started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
gh workflow run release.yml -R Polly2014/FarPilot \
  --ref "$(git branch --show-current)" \
  -f dry_run=true \
  -f version=0.1.1
run_id=
for attempt in $(seq 1 30); do
  run_id=$(gh run list -R Polly2014/FarPilot \
    --workflow Release \
    --branch "$(git branch --show-current)" \
    --event workflow_dispatch \
    --limit 10 \
    --json databaseId,createdAt \
    --jq "map(select(.createdAt >= \"$started\"))[0].databaseId // empty")
  [ -z "$run_id" ] || break
  sleep 2
done
[ -n "$run_id" ] || { printf '%s\n' 'new Release dry run not found' >&2; exit 1; }
gh run watch "$run_id" -R Polly2014/FarPilot --exit-status
window_b="$CLAUDE_JOB_DIR/tmp/farpilot-stage05-window-b"
rm -rf "$window_b"
install -d -m 700 "$window_b"
gh run download "$run_id" -R Polly2014/FarPilot -n release-complete -D "$window_b/release"
python3 scripts/validate_release_assets.py \
  --manifest "$window_b/release/manifest.json" \
  --release-dir "$window_b/release" \
  --reported-version 0.1.1
```

Expected: exact validated 0.1.1 assembly and no GitHub Release.

---

### Task 8: Complete the controlled Mac installer acceptance

**Files:**
- No tracked changes
- Private output: `$CLAUDE_JOB_DIR/tmp/farpilot-stage05-window-b/mac/`

- [ ] **Step 1: Create the loopback TLS material**

Run in a mode-0700 private directory:

```bash
mac_root="$CLAUDE_JOB_DIR/tmp/farpilot-stage05-window-b/mac"
install -d -m 700 "$mac_root/server" "$mac_root/home" "$mac_root/install"
cat > "$mac_root/openssl.cnf" <<'EOF'
[req]
prompt = no
distinguished_name = dn
x509_extensions = v3
[dn]
CN = FarPilot Stage 0.5 Loopback
[v3]
subjectAltName = IP:127.0.0.1
basicConstraints = critical,CA:TRUE
keyUsage = critical,digitalSignature,keyEncipherment,keyCertSign
extendedKeyUsage = serverAuth
EOF
openssl req -x509 -newkey rsa:3072 -nodes -days 1 \
  -config "$mac_root/openssl.cnf" \
  -keyout "$mac_root/server.key" \
  -out "$mac_root/server.crt"
chmod 600 "$mac_root/server.key" "$mac_root/server.crt"
```

Expected: one-day loopback-only certificate and private key.

- [ ] **Step 2: Stage the 0.1.1 assets and manifest**

Copy the exact `release-complete` files into `$mac_root/server`, then generate:

```bash
python3 scripts/acceptance/make_loopback_manifest.py \
  --version 0.1.1 \
  --base-url https://127.0.0.1:18443/ \
  --asset linux-x86_64="$mac_root/server/farpilot-linux-x86_64" \
  --asset linux-aarch64="$mac_root/server/farpilot-linux-aarch64" \
  --asset macos-x86_64="$mac_root/server/farpilot-macos-x86_64" \
  --asset macos-aarch64="$mac_root/server/farpilot-macos-aarch64" \
  --asset windows-x86_64="$mac_root/server/farpilot-windows-x86_64.exe" \
  --gateway-installer "$mac_root/server/install-gateway.sh" \
  --output "$mac_root/server/manifest.json"
```

- [ ] **Step 3: Start the loopback server and prove it is loopback-only**

Run the server in a harness-tracked background process:

```bash
python3 scripts/acceptance/loopback_https.py \
  --root "$mac_root/server" \
  --cert "$mac_root/server.crt" \
  --key "$mac_root/server.key" \
  --port 18443
```

Verify from another command:

```bash
CURL_CA_BUNDLE="$mac_root/server.crt" \
  curl -fsS https://127.0.0.1:18443/manifest.json >/dev/null
lsof -nP -iTCP:18443 -sTCP:LISTEN
```

Expected: listener is only `127.0.0.1:18443`.

- [ ] **Step 4: Run fresh install and idempotence**

Run:

```bash
HOME="$mac_root/home" \
FARPILOT_INSTALL_DIR="$mac_root/install" \
FARPILOT_MANIFEST_URL=https://127.0.0.1:18443/manifest.json \
CURL_CA_BUNDLE="$mac_root/server.crt" \
PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
sh install.sh
"$mac_root/install/farpilot" --version
before=$(stat -f '%i' "$mac_root/install/farpilot")
HOME="$mac_root/home" \
FARPILOT_INSTALL_DIR="$mac_root/install" \
FARPILOT_MANIFEST_URL=https://127.0.0.1:18443/manifest.json \
CURL_CA_BUNDLE="$mac_root/server.crt" \
PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
sh install.sh
after=$(stat -f '%i' "$mac_root/install/farpilot")
test "$before" = "$after"
```

Expected: version 0.1.1 and idempotent inode preservation.

- [ ] **Step 5: Prove post-activation rollback**

Generate one test-only candidate, copy it to unique private filenames for the exact manifest target set, and build the failure manifest:

```bash
python3 scripts/acceptance/make_failure_candidate.py \
  --version 0.1.2 \
  --mode cli-post-activation \
  --output "$mac_root/server/farpilot-cli-fail-base"
for name in \
  farpilot-linux-x86_64-fail \
  farpilot-linux-aarch64-fail \
  farpilot-macos-x86_64-fail \
  farpilot-macos-aarch64-fail \
  farpilot-windows-x86_64-fail.exe; do
  cp "$mac_root/server/farpilot-cli-fail-base" "$mac_root/server/$name"
  chmod 755 "$mac_root/server/$name"
done
python3 scripts/acceptance/make_loopback_manifest.py \
  --version 0.1.2 \
  --base-url https://127.0.0.1:18443/ \
  --asset linux-x86_64="$mac_root/server/farpilot-linux-x86_64-fail" \
  --asset linux-aarch64="$mac_root/server/farpilot-linux-aarch64-fail" \
  --asset macos-x86_64="$mac_root/server/farpilot-macos-x86_64-fail" \
  --asset macos-aarch64="$mac_root/server/farpilot-macos-aarch64-fail" \
  --asset windows-x86_64="$mac_root/server/farpilot-windows-x86_64-fail.exe" \
  --gateway-installer "$mac_root/server/install-gateway.sh" \
  --output "$mac_root/server/manifest-0.1.2-cli-fail.json"
```

Record the installed 0.1.1 hash, run the production installer, and prove exact restoration:

```bash
old_hash=$(shasum -a 256 "$mac_root/install/farpilot" | cut -d ' ' -f 1)
set +e
HOME="$mac_root/home" \
FARPILOT_INSTALL_DIR="$mac_root/install" \
FARPILOT_MANIFEST_URL=https://127.0.0.1:18443/manifest-0.1.2-cli-fail.json \
FARPILOT_ACCEPTANCE_TARGET="$mac_root/install/farpilot" \
FARPILOT_ACCEPTANCE_FAIL_AFTER_ACTIVATION=1 \
CURL_CA_BUNDLE="$mac_root/server.crt" \
PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
sh install.sh >"$mac_root/failure.stdout" 2>"$mac_root/failure.stderr"
status=$?
set -e
test "$status" -ne 0
rg -F 'previous version was restored' "$mac_root/failure.stderr"
test "$(shasum -a 256 "$mac_root/install/farpilot" | cut -d ' ' -f 1)" = "$old_hash"
test "$("$mac_root/install/farpilot" --version)" = 'farpilot 0.1.1'
```

Expected: installer exits nonzero with `previous version was restored`; installed binary hash and version remain exactly 0.1.1.

- [ ] **Step 6: Clean the Mac harness**

Stop the tracked server process, then:

```bash
rm -rf "$mac_root"
test ! -e "$mac_root"
```

Record only sanitized Pass/Fail, tool versions, and source SHA.

---

### Task 9: Prepare and authorize Window B live Gateway mutation

**Files:**
- No tracked changes
- Gateway private directory: `/root/.cache/farpilot-stage05-window-b/`

- [ ] **Step 1: Repeat the live baseline and backup**

Repeat Window A health, Host, Mac, Moshi, immutable hash, database/grant invariant, syntax validation, and backup checks in a new mode-0700 root directory.

Expected: all current services and all three existing access paths pass before mutation.

- [ ] **Step 2: Stage the loopback HTTPS bundle privately**

Copy only:

```text
0.1.1 release-complete assets
install.sh
scripts/acceptance tools
one-day loopback certificate and key
0.1.1 loopback manifest
```

The server binds `127.0.0.1:19443`. Verify no non-loopback listener exists.

- [ ] **Step 3: Generate the private 0.1.2 Gateway failure candidate**

Run on the Gateway private directory and generate a complete private failure manifest:

```bash
private=/root/.cache/farpilot-stage05-window-b
python3 "$private/tools/make_failure_candidate.py" \
  --version 0.1.2 \
  --mode gateway-start \
  --output "$private/server/farpilot-gateway-fail-base"
for name in \
  farpilot-linux-x86_64-gateway-fail \
  farpilot-linux-aarch64-gateway-fail \
  farpilot-macos-x86_64-gateway-fail \
  farpilot-macos-aarch64-gateway-fail \
  farpilot-windows-x86_64-gateway-fail.exe; do
  cp "$private/server/farpilot-gateway-fail-base" "$private/server/$name"
  chmod 755 "$private/server/$name"
done
python3 "$private/tools/make_loopback_manifest.py" \
  --version 0.1.2 \
  --base-url https://127.0.0.1:19443/ \
  --asset linux-x86_64="$private/server/farpilot-linux-x86_64-gateway-fail" \
  --asset linux-aarch64="$private/server/farpilot-linux-aarch64-gateway-fail" \
  --asset macos-x86_64="$private/server/farpilot-macos-x86_64-gateway-fail" \
  --asset macos-aarch64="$private/server/farpilot-macos-aarch64-gateway-fail" \
  --asset windows-x86_64="$private/server/farpilot-windows-x86_64-gateway-fail.exe" \
  --gateway-installer "$private/server/install-gateway.sh" \
  --output "$private/server/manifest-0.1.2-fail.json"
test "$("$private/server/farpilot-linux-x86_64-gateway-fail" --version)" = 'farpilot 0.1.2'
set +e
"$private/server/farpilot-linux-x86_64-gateway-fail" gateway serve >/dev/null 2>&1
status=$?
set -e
test "$status" -eq 42
```

Expected: the selected Linux candidate reports 0.1.2, Gateway startup exits 42, every URL remains loopback HTTPS, and the candidate never leaves the mode-0700 private directory.

- [ ] **Step 4: Window B authorization checkpoint**

Present:

```text
Window A status
Mac controlled install status
0.1.1 source SHA and dry-run URL
live baseline status
backup status
loopback-only listener proof
0.1.1 manifest validation
0.1.2 failure-candidate behavior
expected short outage
automatic and manual rollback commands
```

Stop. Do not run the Gateway installer until Polly explicitly authorizes Window B.

---

### Task 10: Execute Window B upgrade and injected rollback

**Files:**
- No tracked changes during live execution

- [ ] **Step 1: Run the production Gateway installer for 0.1.1**

After explicit authorization, run privately on the Gateway:

```bash
FARPILOT_MANIFEST_URL=https://127.0.0.1:19443/manifest-0.1.1.json \
CURL_CA_BUNDLE=/root/.cache/farpilot-stage05-window-b/server.crt \
bash /root/.cache/farpilot-stage05-window-b/install.sh gateway
```

Expected: installer reports successful Gateway 0.1.1 install.

- [ ] **Step 2: Verify successful upgrade state**

Verify:

```text
/usr/local/bin/farpilot --version is 0.1.1
systemd active
health/live and health/ready pass
Host reconnects
existing Mac attaches
existing Moshi attaches
immutable hashes match
logical database/key invariants hold
```

Failure triggers the documented manual restore and stops Window B.

- [ ] **Step 3: Run the 0.1.2 injected failure**

Run:

```bash
set +e
FARPILOT_MANIFEST_URL=https://127.0.0.1:19443/manifest-0.1.2-fail.json \
CURL_CA_BUNDLE=/root/.cache/farpilot-stage05-window-b/server.crt \
bash /root/.cache/farpilot-stage05-window-b/install.sh gateway \
  >/root/.cache/farpilot-stage05-window-b/injected.stdout \
  2>/root/.cache/farpilot-stage05-window-b/injected.stderr
status=$?
set -e
test "$status" -ne 0
```

Expected: readiness fails, previous binary/configuration restore is reported, and command exits nonzero.

- [ ] **Step 4: Verify automatic rollback**

Verify:

```text
/usr/local/bin/farpilot --version is 0.1.1
systemd active
health/live and health/ready pass
Host reconnects
existing Mac attaches
existing Moshi attaches
immutable hashes match
logical database/key invariants hold
no 0.1.2 candidate remains active
```

If automatic rollback fails, do not clean the private directory. Recover service manually and preserve private evidence until the incident is understood.

- [ ] **Step 5: Inspect failure output privately**

Confirm the installer reports both the original readiness failure and successful restore without printing environment values, tokens, keys, database rows, or raw private identifiers.

- [ ] **Step 6: Clean Window B private artifacts**

After all invariants pass:

```text
stop loopback HTTPS server
remove one-day CA/server keys
remove 0.1.2 failure candidate and manifests
remove raw logs after sanitized result is written
retain only managed production state and the normal installer-owned rollback policy
prove no listener remains on 19443
```

---

### Task 11: Record Stage 0.5 results and complete the branch

**Files:**
- Modify: `docs/stage0-acceptance.md`
- Modify: `docs/stage0-runbook.md`
- Modify: `README.md` only if Stage 0.5 status is publicly useful

- [ ] **Step 1: Write sanitized Window B results**

Record Pass/Fail for:

```text
Controlled preview fresh Mac install
Mac idempotence
Mac post-activation rollback
Live Gateway 0.1.1 upgrade
Injected 0.1.2 readiness failure
Automatic restoration to 0.1.1
Post-upgrade Host/Mac/Moshi access
Post-rollback Host/Mac/Moshi access
Immutable-state checks
Logical database/authorized_keys invariants
Private evidence cleanup
```

Keep stable/latest/public-endpoint rows Pending.

- [ ] **Step 2: Run final full verification**

Run the complete Task 2 preflight, plus:

```bash
python3 -m unittest tests.acceptance.test_version_contract -v
rg -n 'Stage 0.5|Controlled preview|automatic rollback' docs/stage0-acceptance.md docs/stage0-runbook.md
! rg -n -i 'BEGIN .*PRIVATE KEY|ssh-ed25519 [A-Za-z0-9+/]{40,}|([0-9]{1,3}\.){3}[0-9]{1,3}|token=[A-Za-z0-9_-]+' \
  docs/stage0-acceptance.md docs/stage0-runbook.md
git diff --check
```

Expected: all automated checks pass and tracked evidence contains no live values.

- [ ] **Step 3: Verify private cleanup**

Locally and remotely verify the acceptance temporary directories, loopback listeners, one-day keys, candidates, and raw logs are absent. Do not delete managed production backups required by the normal runbook.

- [ ] **Step 4: Final code review**

Request an independent review of:

```text
acceptance tools and tests
CI wiring
version bump
sanitized acceptance claims
rollback evidence boundaries
stable/latest still blocked
```

Fix only verified findings and rerun the full suite.

- [ ] **Step 5: Final commit/push authorization checkpoint**

Stop and present:

```text
Window A matrix
Window B matrix
full verification output
private cleanup proof
review findings and outcomes
exact tracked diff
```

Do not commit, merge, or push without explicit authorization.

If authorized:

```bash
git add docs/stage0-acceptance.md docs/stage0-runbook.md README.md
git commit -m "test: complete FarPilot Stage 0.5 live acceptance"
git push
```

Do not merge to `main` unless separately authorized.
