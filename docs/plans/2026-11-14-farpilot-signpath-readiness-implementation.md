# FarPilot SignPath Readiness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prepare FarPilot for SignPath Foundation review with a publish-safe repository audit, public policies, safe uninstall behavior, an isolated unsigned application prerelease workflow, and a reviewed application packet—while stopping at explicit external gates for repository visibility, prerelease publication, and application submission.

**Architecture:** Automated readiness work lives in normal source, docs, tests, and manually dispatched workflows. External state changes are isolated into three stop gates. Real SignPath signing integration is not implemented until approval supplies actual project configuration; the final readiness task creates a factual onboarding record and then requires a new post-approval implementation plan.

**Tech Stack:** Rust stable, Python 3 standard library, PowerShell 5.1+, Bash, Git, Gitleaks CLI, GitHub Actions, GitHub CLI.

**Approved specification:** `docs/specs/2026-11-14-farpilot-signpath-readiness-design.md`

**Repository policy:** Local commits require execution-session authorization. Do not push, rewrite history, change visibility, publish a prerelease, submit a SignPath form, or create signing secrets without the explicit gate authorization named in this plan.

---

## Scope decomposition

This plan implements **Phase A: readiness and application**. It does not invent the post-approval signing API.

After SignPath approval, use the actual onboarding documentation and issued identifiers to create a second design/plan for:

```text
SignPath request submission
manual signing approval
signed artifact download
Authenticode/publisher/EKU/timestamp verification
signed-file SHA/manifest assembly
stable Release publication gate
```

That second plan is blocked until real SignPath configuration exists.

---

## File map

```text
FarPilot/
├── .github/
│   ├── CODEOWNERS
│   └── workflows/
│       ├── ci.yml
│       └── signpath-application.yml
├── SECURITY.md
├── README.md
├── scripts/
│   └── public_readiness_audit.py
├── tests/
│   ├── security/test_public_readiness.py
│   └── release/signpath_application_workflow.sh
├── deploy/windows/
│   ├── install.ps1
│   └── test-install.ps1
├── docs/
│   ├── code-signing-policy.md
│   ├── privacy-policy.md
│   ├── uninstall.md
│   ├── installer-security.md
│   ├── stage0-runbook.md
│   ├── public-readiness-audit.md
│   └── signpath-application.md
└── tests/workspace_layout.sh
```

Raw scanner output must be written outside the repository. Only the sanitized audit summary is committed.

---

### Task 1: Sanitized public-readiness secret scanner and audit tooling

**Files:**
- Create: `scripts/public_readiness_audit.py`
- Create: `tests/security/test_public_readiness.py`
- Create: `docs/public-readiness-audit.md`
- Modify: `.gitignore`

- [ ] **Step 1: Write failing audit tests using a temporary Git repository**

Create `tests/security/test_public_readiness.py` with standard-library `unittest`. Each test initializes a temporary Git repository with synthetic identity, commits an obviously fake secret, removes it in a later commit, then invokes the scanner:

```python
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCANNER = ROOT / "scripts" / "public_readiness_audit.py"

class PublicReadinessAuditTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.repo = Path(self.temp.name) / "repo"
        self.repo.mkdir()
        subprocess.run(["git", "init", "-q"], cwd=self.repo, check=True)
        subprocess.run(["git", "config", "user.name", "Synthetic Tester"], cwd=self.repo, check=True)
        subprocess.run(["git", "config", "user.email", "synthetic@example.invalid"], cwd=self.repo, check=True)

    def tearDown(self):
        self.temp.cleanup()

    def commit(self, name: str, content: str):
        (self.repo / name).write_text(content)
        subprocess.run(["git", "add", name], cwd=self.repo, check=True)
        subprocess.run(["git", "commit", "-qm", name], cwd=self.repo, check=True)

    def run_audit(self):
        private = self.repo / "private.json"
        summary = self.repo / "summary.json"
        result = subprocess.run([
            sys.executable, "-I", str(SCANNER),
            "--repo", str(self.repo),
            "--private-report", str(private),
            "--summary", str(summary),
        ], capture_output=True, text=True)
        return result, json.loads(private.read_text()), json.loads(summary.read_text())

    def test_removed_history_secret_is_detected_without_echoing_value(self):
        fake = "ghp_abcdefghijklmnopqrstuvwxyzABCDEFGHIJ"
        self.commit("config.txt", f"token={fake}\n")
        self.commit("config.txt", "token=removed\n")
        result, private, summary = self.run_audit()
        self.assertNotEqual(result.returncode, 0)
        self.assertGreater(summary["counts"]["github_token"], 0)
        self.assertNotIn(fake, result.stdout + result.stderr + json.dumps(summary))
        self.assertNotIn(fake, json.dumps(private))

    def test_private_key_and_prohibited_farpilot_data_are_categorized(self):
        self.commit("fixture.txt", "-----BEGIN PRIVATE KEY-----\nPRIVATE\n")
        result, _, summary = self.run_audit()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(summary["counts"]["private_key"], 1)

    def test_clean_repository_produces_public_ready_summary(self):
        self.commit("README.md", "synthetic public documentation\n")
        result, _, summary = self.run_audit()
        self.assertEqual(result.returncode, 0)
        self.assertEqual(summary["verdict"], "ready")
```

Add tests for tracked filenames (`.env`, `.pfx`, SQLite), high-risk credential URL syntax, AWS-like keys, Azure/client-secret assignment, private IP/hostname allowlists, and output mode `0600`.

All tokens are fake and use `.invalid`/documentation address ranges.

- [ ] **Step 2: Run tests and verify RED**

Run:

```bash
python3 -m unittest tests/security/test_public_readiness.py -v
```

Expected: FAIL because `scripts/public_readiness_audit.py` does not exist.

- [ ] **Step 3: Implement the scanner with redacted findings**

Create a standard-library scanner with fixed categories:

```python
PATTERNS = {
    "private_key": re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    "github_token": re.compile(r"\bgh[pousr]_[A-Za-z0-9]{20,}\b"),
    "aws_access_key": re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"),
    "credential_url": re.compile(r"https?://[^\s/:]+:[^\s/@]+@"),
    "secret_assignment": re.compile(r"(?i)\b(?:client_secret|api_key|password|token)\s*[:=]\s*[^\s]+"),
    "private_ip": re.compile(r"\b(?:10\.|192\.168\.|172\.(?:1[6-9]|2[0-9]|3[01])\.)"),
}
```

Use `git rev-list --objects --all` plus `git cat-file --batch` or an equivalent binary-safe Git plumbing approach to scan reachable blobs once. Scan current tracked filenames separately.

Each finding contains only:

```json
{
  "category": "github_token",
  "source": "history",
  "object": "first 12 hex characters",
  "path_hash": "sha256 of path, first 16 hex characters"
}
```

Never persist the matching value or line. The committed summary contains category counts and verdict only. Create the private report with mode `0600`; refuse a private-report path inside the audited repository.

- [ ] **Step 4: Add Gitleaks as the complementary scanner boundary**

The Python tool must report whether `gitleaks` is available and record its version, but it does not download tools.

Document the operator command:

```bash
gitleaks git --redact --log-opts="--all" \
  --report-format json \
  --report-path "$CLAUDE_JOB_DIR/tmp/farpilot-gitleaks.json"
```

The raw Gitleaks report is never committed. A sanitized human disposition updates only counts and status in `docs/public-readiness-audit.md`.

- [ ] **Step 5: Add the sanitized audit summary template**

Create `docs/public-readiness-audit.md` with explicit states:

```text
Status: NOT RUN | BLOCKED | READY FOR VISIBILITY REVIEW
Repository visibility: Private
Tree scanner: Pending
History scanner: Pending
Gitleaks: Pending
Targeted FarPilot checks: Pending
Manual tracked-file review: Pending
Visibility change authorized: No
```

The template must not claim readiness until actual scans run.

- [ ] **Step 6: Run tests and verify GREEN**

Run:

```bash
python3 -m unittest tests/security/test_public_readiness.py -v
python3 -m py_compile scripts/public_readiness_audit.py
git diff --check
```

Expected: tests pass; no fake secret appears in test output.

- [ ] **Step 7: Commit checkpoint**

```bash
git add scripts/public_readiness_audit.py tests/security/test_public_readiness.py \
  docs/public-readiness-audit.md .gitignore
git commit -m "feat: add public readiness audit tooling"
```

---

### Task 2: Signing governance, privacy, and security policies

**Files:**
- Create: `docs/code-signing-policy.md`
- Create: `docs/privacy-policy.md`
- Create: `SECURITY.md`
- Create: `.github/CODEOWNERS`
- Modify: `README.md`
- Modify: `tests/workspace_layout.sh`

- [ ] **Step 1: Add failing policy assertions**

Extend `tests/workspace_layout.sh` to require:

```text
docs/code-signing-policy.md
docs/privacy-policy.md
docs/uninstall.md
SECURITY.md
.github/CODEOWNERS
```

Require README links named `Code signing policy`, `Privacy policy`, `Uninstall`, and `Security`.

Require the exact SignPath attribution:

```text
Free code signing provided by SignPath.io, certificate by SignPath Foundation
```

Require role names `Author`, `Reviewer`, `Approver`, the single-maintainer disclosure, MFA, manual approval, immutable release policy, and signed scope `farpilot-windows-x86_64.exe`.

- [ ] **Step 2: Run assertions and verify RED**

Run:

```bash
bash tests/workspace_layout.sh
```

Expected: FAIL because the policy files are absent.

- [ ] **Step 3: Write code-signing policy**

Implement the approved scope, source/tag/build requirements, roles, compensating controls, immutable release policy, incident response, and SignPath attribution.

State that Polly currently holds all three roles and that independent approval will be added if SignPath requires it. Do not claim SignPath acceptance or an active certificate.

- [ ] **Step 4: Write privacy policy**

Document zero project telemetry, explicit network operations, self-hosted Gateway metadata, in-memory terminal relay, prohibited persistence/log data, ordinary infrastructure IP logging, token-path log suppression, operator-controlled retention, GitHub/CA third-party policies, and a separate future hosted-cloud design.

- [ ] **Step 5: Write security reporting policy and ownership**

`SECURITY.md` defines supported versions, private vulnerability reporting through GitHub Security Advisories, no secrets in public issues, response expectations without guaranteed SLA, and signing incident handling.

`.github/CODEOWNERS` assigns all paths and signing-sensitive paths to `@Polly2014`:

```text
* @Polly2014
/.github/workflows/ @Polly2014
/scripts/ @Polly2014
/deploy/ @Polly2014
/docs/code-signing-policy.md @Polly2014
```

- [ ] **Step 6: Update README links and current status**

Add a Security and trust section. Say SignPath readiness is in progress and Windows stable binaries remain unsigned/unpublished. Do not imply certificate issuance.

- [ ] **Step 7: Run policy checks and verify GREEN**

Run:

```bash
bash tests/workspace_layout.sh
git diff --check
```

Expected: all assertions pass.

- [ ] **Step 8: Commit checkpoint**

```bash
git add README.md SECURITY.md .github/CODEOWNERS \
  docs/code-signing-policy.md docs/privacy-policy.md tests/workspace_layout.sh
git commit -m "docs: add signing and privacy policies"
```

---

### Task 3: Windows uninstall and purge behavior

**Files:**
- Modify: `deploy/windows/install.ps1`
- Modify: `deploy/windows/test-install.ps1`
- Modify: `.github/workflows/ci.yml` only if a separate uninstall test step is clearer

- [ ] **Step 1: Write failing uninstall tests**

Extend the existing temporary-`LOCALAPPDATA` Windows suite with scenarios:

```text
install -> -Uninstall
install -> upgrade -> -Uninstall
-Uninstall repeated twice
-Uninstall -PurgeState without confirmation
-Uninstall -PurgeState with injected confirmation
partial Scheduled Task removal failure
partial PATH removal failure
unmanaged same-name process/file/path preservation
```

Assertions for default uninstall:

```text
managed task absent
managed process stopped
installer PATH entries absent
current/bin junctions absent
release directories absent
identity/config byte-identical
unrelated files/tasks/processes/PATH entries unchanged
revocation warning emitted
```

Assertions for confirmed purge:

```text
identity/config removed
only exact known state files removed
unrelated files preserved
```

- [ ] **Step 2: Run Windows tests and verify RED**

Run in Windows CI:

```powershell
$env:FARPILOT_TEST_BINARY = (Resolve-Path target\release\farpilot.exe)
.\deploy\windows\test-install.ps1
```

Expected: new uninstall tests fail because parameters/behavior do not exist.

If no Windows environment is available locally, use the previously approved RED/GREEN feature-branch CI process; do not claim RED from static inspection.

- [ ] **Step 3: Add mutually exclusive parameters**

Add:

```powershell
[switch]$Uninstall,
[switch]$PurgeState,
[switch]$ConfirmPurge
```

`-PurgeState` requires `-Uninstall`. Production interactive purge asks for a typed confirmation such as `PURGE FARPILOT STATE`. `-ConfirmPurge` is accepted only when the guarded installer test mode is active; a normal user cannot bypass the prompt with it.

Installation-only parameters are rejected in uninstall mode.

- [ ] **Step 4: Implement safe default uninstall**

Reuse existing managed path, process, task, junction, and PATH adapters. Capture state before mutation. Stop/remove the managed task and managed processes first; remove installer PATH entries; remove only installer-owned junctions/releases/staging/backups/lock.

Before every recursive deletion, require canonical containment under `%LOCALAPPDATA%\FarPilot` and reject reparse escapes. Never follow a junction target during deletion.

If task/process/PATH cleanup fails, stop before recursive release deletion and print exact remaining managed paths.

- [ ] **Step 5: Implement explicit purge**

After default uninstall succeeds and confirmation is valid, delete only the known Host identity/config files and empty managed state directories. Do not delete arbitrary files found in the state directory; report them for manual review.

- [ ] **Step 6: Verify uninstall lifecycle GREEN**

Run Windows CI tests, PSScriptAnalyzer, and normal installer tests. Add a dedicated source assertion that production confirmation cannot be bypassed outside guarded test mode.

- [ ] **Step 7: Commit checkpoint**

```bash
git add deploy/windows/install.ps1 deploy/windows/test-install.ps1 .github/workflows/ci.yml
git commit -m "feat: add safe Windows uninstall"
```

---

### Task 4: Cross-platform uninstall documentation

**Files:**
- Create: `docs/uninstall.md`
- Modify: `docs/stage0-runbook.md`
- Modify: `docs/installer-security.md`
- Modify: `README.md`
- Modify: `tests/workspace_layout.sh`

- [ ] **Step 1: Add failing uninstall documentation assertions**

Require docs to contain exact safe commands and preservation warnings:

```text
rm "$HOME/.local/bin/farpilot"
systemctl stop farpilot-gateway.service
systemctl disable farpilot-gateway.service
sshd -t
nginx -t
-Uninstall
-PurgeState
```

Require text saying SSH keys/profiles and Gateway state/certificates are preserved by default.

- [ ] **Step 2: Run assertions and verify RED**

Run `bash tests/workspace_layout.sh`; expect failure.

- [ ] **Step 3: Write macOS/Linux CLI uninstall instructions**

Use exact managed binary paths, `FARPILOT_INSTALL_DIR`, `command -v`, and safe inspection of FarPilot SSH files. Never use broad `rm ~/.ssh/*` or an unquoted glob.

- [ ] **Step 4: Write Gateway uninstall instructions**

Document revoke, stop/disable, exact managed config removal, `sshd -t`, `nginx -t`, daemon reload, binary removal, preserved state, backup, and optional explicit state deletion.

Do not provide a one-line remote purge.

- [ ] **Step 5: Link Windows automated uninstall**

Document default preservation, explicit purge confirmation, and Gateway revocation warning.

- [ ] **Step 6: Run assertions and commit**

```bash
bash tests/workspace_layout.sh
git diff --check
git add docs/uninstall.md docs/stage0-runbook.md docs/installer-security.md README.md tests/workspace_layout.sh
git commit -m "docs: add FarPilot uninstall guidance"
```

---

### Task 5: Unsigned SignPath application prerelease workflow

**Files:**
- Create: `.github/workflows/signpath-application.yml`
- Create: `tests/release/signpath_application_workflow.sh`
- Modify: `.github/workflows/ci.yml`
- Modify: `tests/release/workflow_assets.sh` only to assert separation from stable Release

- [ ] **Step 1: Write failing structural and mutation tests**

Use Ruby standard YAML parsing to require:

```text
workflow_dispatch only
protected environment signpath-application
main ref/commit validation
full quality + Windows installer prerequisites
Windows x86_64 build only
exact three assets
prerelease publication
unsigned warning
no stable manifest/installers/latest update
existing tag/release refusal
```

Mutation fixtures must reject push/tag/PR triggers, missing environment, stable publication, extra assets, missing warning, `latest` manipulation, or broadened write permissions.

- [ ] **Step 2: Run test and verify RED**

Run:

```bash
bash tests/release/signpath_application_workflow.sh
```

Expected: FAIL because the workflow is absent.

- [ ] **Step 3: Create manual-only workflow**

Inputs are fixed to the reviewed application version or strictly validate:

```text
version = 0.1.0
application_tag = v0.1.0-unsigned.1
```

The workflow verifies it is running against the exact current `main` commit. It uses `contents: read` globally; only the final prerelease job gets `contents: write` and the protected environment.

- [ ] **Step 4: Build and verify application artifact**

Run all quality/security/installer tests, build Windows x86_64 on a supported Windows runner, verify `farpilot 0.1.0`, calculate SHA-256, and create `build-metadata.json` with the approved fields.

The exact asset set is:

```text
farpilot-windows-x86_64-unsigned.exe
SHA256SUMS
build-metadata.json
```

- [ ] **Step 5: Publish only a GitHub prerelease**

The final job refuses an existing tag or release, uses `gh release create --prerelease --target "$GITHUB_SHA"`, and supplies the fixed warning body. It does not upload `manifest.json`, `install.sh`, `install.ps1`, or Gateway assets.

- [ ] **Step 6: Add normal CI structure checks**

Normal CI runs the workflow mutation test but cannot publish.

- [ ] **Step 7: Verify and commit**

Run structure/mutation tests, complete local suites, YAML parse, and diff checks.

```bash
git add .github/workflows/signpath-application.yml .github/workflows/ci.yml \
  tests/release/signpath_application_workflow.sh tests/release/workflow_assets.sh
git commit -m "ci: add SignPath application prerelease gate"
```

Do not dispatch the workflow in this task.

---

### Task 6: SignPath application packet

**Files:**
- Create: `docs/signpath-application.md`
- Modify: `tests/workspace_layout.sh`
- Modify: `README.md`

- [ ] **Step 1: Add failing application-packet assertions**

Require the packet to link the repository, license, policy, privacy, uninstall, workflow, security, and unsigned prerelease sections. Require placeholders only for private form-entry fields and forbid values resembling tokens, addresses, government IDs, or telephone numbers.

- [ ] **Step 2: Write copy-ready public answers**

Explain product purpose, self-hosted trust boundary, defensive/non-offensive use, release provenance, manual approval, team roles, testing, uninstall, and privacy.

Private submission fields are represented as prompts Polly fills directly in the external form; they are not committed values.

- [ ] **Step 3: Add pre-submission checklist**

Include:

```text
repository Public
MFA enabled
policies public
uninstall released
unsigned prerelease URL present
workflow run successful
all links anonymously accessible
SignPath terms rechecked
```

- [ ] **Step 4: Verify and commit**

```bash
bash tests/workspace_layout.sh
git diff --check
git add docs/signpath-application.md README.md tests/workspace_layout.sh
git commit -m "docs: prepare SignPath application packet"
```

---

### Task 7: Full readiness verification and audit execution

**Files:**
- Modify: `docs/public-readiness-audit.md` with sanitized results only
- Modify: `docs/stage0-acceptance.md`

- [ ] **Step 1: Run complete automated verification**

Run Rust, installer, release, security, E2E, workflow mutation, PSScriptAnalyzer/ShellCheck CI, documentation assertions, and diff checks.

- [ ] **Step 2: Run the private audit tools**

Run the Python scanner against the full repository and history, then Gitleaks with `--all` and `--redact`. Store raw reports outside the repository with mode `0600`.

- [ ] **Step 3: Review tracked files and Git metadata**

Inspect tracked large files, commit authors/emails, branches/tags, Actions workflow references, and repository visibility. Do not expose raw sensitive findings in terminal summaries.

- [ ] **Step 4: Update sanitized audit status**

Set `READY FOR VISIBILITY REVIEW` only when both scanners and manual review pass. If any finding remains, use `BLOCKED` and a sanitized category/disposition.

- [ ] **Step 5: Independent final review**

Review all readiness code/docs against SignPath terms and the approved design. Fix confirmed issues with regressions.

- [ ] **Step 6: Commit checkpoint**

```bash
git add docs/public-readiness-audit.md docs/stage0-acceptance.md
git commit -m "security: record public readiness audit"
```

---

## External Gate A: Repository visibility

Stop and present:

```text
sanitized audit summary
full test/CI status
current private visibility
exact files and commits to publish
```

Do not run `gh repo edit --visibility public` until the user explicitly authorizes this gate.

After authorization:

1. push the reviewed branch and merge through the chosen workflow;
2. verify `main` CI;
3. change visibility;
4. verify anonymous access to README, license, policies, workflow, and source;
5. enable/verify GitHub security features and branch protections;
6. rerun public-readiness links and scanner checks.

If visibility change fails or reveals unexpected content, stop before prerelease publication.

---

## External Gate B: Unsigned application prerelease

After Public conversion and another successful CI run, stop and present:

```text
exact tag v0.1.0-unsigned.1
exact three assets and hashes
warning body
workflow permissions/environment
no-latest proof
```

Do not dispatch the prerelease workflow until the user explicitly authorizes this gate.

After authorization, monitor the protected Environment approval, workflow, tag, and prerelease. Download the artifact into a new empty directory, validate hashes/metadata without executing it, and verify GitHub still reports no stable/latest Release.

---

## External Gate C: SignPath application submission

After the public prerelease exists, stop and provide the reviewed `docs/signpath-application.md` packet.

Polly must manually submit the SignPath form. Do not automate browser form submission or handle identity/private contact information.

Record only public application status:

```text
NOT SUBMITTED
SUBMITTED
ACTION REQUIRED
APPROVED
REJECTED
```

Do not commit private correspondence or identity documents.

---

## Conditional Phase B: Post-approval planning gate

If and only if SignPath status is `APPROVED`:

1. collect the current official SignPath integration documentation supplied for the approved project;
2. identify which values are secrets and which are public identifiers;
3. place no values in code yet;
4. create a new design and detailed implementation plan using the real request/upload/approval/download contract;
5. require explicit authorization before setting GitHub Environment secrets or dispatching a signing dry-run.

The new plan must include:

```text
protected release-signing Environment
exact SignPath adapter/action/API version
manual approval behavior
signed artifact origin binding
Authenticode Valid check
expected publisher subject
Code Signing EKU
timestamp verification
signed-file version
signed-file SHA/manifest ordering
unsigned artifact exclusion
stable Release publication gate
revocation/incident procedure
```

No post-approval signing implementation occurs under this Phase A plan.
