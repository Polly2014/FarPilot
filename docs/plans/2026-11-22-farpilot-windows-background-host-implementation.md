# FarPilot Windows Background Host Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship an elevation-free, console-free, supervised Windows FarPilot Host using one ZIP package with `farpilot.exe` and `farpilot-host-runner.exe`, including sanitized status/logging and transactional installer/release support.

**Architecture:** A new Windows GUI-subsystem runner owns one current-user instance, a kill-on-close Job Object, child restart/backoff, bounded logs, and runner status. The existing CLI gains a fixed managed Host mode and atomic sanitized status; the Windows installer atomically activates an exact-two-file ZIP and points the current-user Scheduled Task at the runner. Linux/macOS packaging and FarPilot's network/command security boundaries remain unchanged.

**Tech Stack:** Rust 1.94, Tokio, `windows-sys` 0.61, PowerShell 5.1+, `System.IO.Compression.ZipArchive`, GitHub Actions Windows runners, PSScriptAnalyzer, standard-library Python release tooling.

**Approved specification:** `docs/specs/2026-11-22-farpilot-windows-background-host-design.md`

**Authorization policy:** Do not commit, push, create a PR, dispatch workflows, publish an artifact, change stable/latest, install on the real DevBox, stop the foreground Host, or modify Live Gateway state without the explicit checkpoint authorization named below. Spec/plan approval is not execution or deployment approval.

---

## File map

```text
FarPilot/
├── Cargo.toml
├── Cargo.lock
├── crates/
│   ├── farpilot-host/
│   │   ├── src/
│   │   │   ├── lib.rs
│   │   │   ├── managed_status.rs
│   │   │   └── reconnect.rs
│   │   └── tests/managed_status.rs
│   ├── farpilot-host-runner/
│   │   ├── Cargo.toml
│   │   ├── src/
│   │   │   ├── main.rs
│   │   │   ├── backoff.rs
│   │   │   ├── layout.rs
│   │   │   ├── log_rotation.rs
│   │   │   ├── status.rs
│   │   │   └── windows.rs
│   │   └── tests/
│   │       ├── portable.rs
│   │       └── windows_lifecycle.rs
│   └── farpilot-cli/
│       ├── Cargo.toml
│       ├── src/
│       │   ├── host_cmd.rs
│       │   └── main.rs
│       └── tests/cli.rs
├── deploy/windows/
│   ├── install.ps1
│   └── test-install.ps1
├── scripts/
│   ├── release_manifest.py
│   ├── validate_release_assets.py
│   └── acceptance/windows_background_host.ps1
├── tests/
│   ├── acceptance/
│   │   ├── test_windows_background_contract.py
│   │   └── test_windows_background_script.py
│   └── release/
│       ├── test_release_manifest.py
│       └── workflow_assets.sh
├── .github/workflows/
│   ├── ci.yml
│   └── release.yml
├── README.md
└── docs/
    ├── installer-security.md
    ├── stage0-acceptance.md
    ├── stage0-runbook.md
    ├── uninstall.md
    ├── plans/2026-11-22-farpilot-windows-background-host-implementation.md
    └── specs/2026-11-22-farpilot-windows-background-host-design.md
```

`farpilot-host` owns status semantics shared with the CLI. `farpilot-host-runner` owns supervision only. `farpilot-cli` remains the user command and Host data plane. PowerShell owns package activation, not runner behavior.

---

### Task 1: Freeze the design and create an implementation branch

**Files:**
- Create: `docs/specs/2026-11-22-farpilot-windows-background-host-design.md`
- Create: `docs/plans/2026-11-22-farpilot-windows-background-host-implementation.md`

- [ ] **Step 1: Verify the approved documents**

Run:

```bash
rg -n 'farpilot-host-runner.exe|JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE|farpilot-windows-x86_64.zip|Windows Background Host' \
  docs/specs/2026-11-22-farpilot-windows-background-host-design.md \
  docs/plans/2026-11-22-farpilot-windows-background-host-implementation.md
! rg -n 'TBD|TODO|FIXME|implement later|fill in' \
  docs/specs/2026-11-22-farpilot-windows-background-host-design.md
git diff --check
```

Expected: required architecture terms exist, placeholder scan is empty, diff check passes.

- [ ] **Step 2: Commit/push authorization checkpoint**

Stop and show exact document diff. If authorized:

```bash
git switch -c feature/windows-background-host
git add docs/specs/2026-11-22-farpilot-windows-background-host-design.md \
  docs/plans/2026-11-22-farpilot-windows-background-host-implementation.md
git commit -m "docs: design Windows background Host"
git push -u origin feature/windows-background-host
```

Do not create a PR yet.

---

### Task 2: Add portable managed Host status with RED/GREEN tests

**Files:**
- Create: `crates/farpilot-host/src/managed_status.rs`
- Modify: `crates/farpilot-host/src/lib.rs`
- Create: `crates/farpilot-host/tests/managed_status.rs`

- [ ] **Step 1: Write failing status tests**

Create `crates/farpilot-host/tests/managed_status.rs` covering:

```rust
use std::time::Duration;
use farpilot_host::managed_status::{
    ErrorCategory, HostRuntimeState, ManagedStatus, StatusWriter,
};

#[test]
fn status_json_contains_only_allowlisted_fields() {
    let status = ManagedStatus::new(HostRuntimeState::Connecting, 7, 2, None);
    let value = serde_json::to_value(status).unwrap();
    let keys = value.as_object().unwrap().keys().cloned().collect::<Vec<_>>();
    assert_eq!(keys, vec![
        "schema_version", "state", "updated_at_ms", "connection_generation",
        "restart_count", "last_error_category",
    ]);
    let text = value.to_string();
    for forbidden in ["gateway", "host_id", "device", "token", "fingerprint", "key"] {
        assert!(!text.to_lowercase().contains(forbidden));
    }
}

#[test]
fn error_categories_are_closed_and_sanitized() {
    assert_eq!(ErrorCategory::classify("certificate verify failed at https://secret.example"), ErrorCategory::Tls);
    assert_eq!(ErrorCategory::classify("permission denied for C:\\private\\path"), ErrorCategory::Permission);
    assert_eq!(ErrorCategory::classify("unknown arbitrary detail"), ErrorCategory::Unknown);
}

#[test]
fn status_writer_atomically_replaces_a_regular_file() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("host-status.json");
    let writer = StatusWriter::new(path.clone()).unwrap();
    writer.write(&ManagedStatus::new(HostRuntimeState::Starting, 1, 0, None)).unwrap();
    writer.write(&ManagedStatus::new(HostRuntimeState::Online, 1, 0, None)).unwrap();
    let parsed: ManagedStatus = serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap();
    assert_eq!(parsed.state, HostRuntimeState::Online);
    assert!(!temp.path().join("host-status.tmp").exists());
}

#[test]
fn stale_status_is_not_reported_as_online() {
    let status = ManagedStatus::new_at(
        HostRuntimeState::Online, 1, 0, None, 1_000,
    );
    assert!(status.is_stale_at(1_000 + Duration::from_secs(121).as_millis() as u64));
}
```

- [ ] **Step 2: Run and verify RED**

```bash
cargo test -p farpilot-host --test managed_status
```

Expected: compile failure because `managed_status` does not exist.

- [ ] **Step 3: Implement the minimal status API**

Create:

```rust
#[derive(Clone, Copy, Debug, Deserialize, Serialize, Eq, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum HostRuntimeState {
    Starting, Connecting, Authenticated, Online, Backoff, PermanentError, Stopped,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, Eq, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum ErrorCategory {
    Dns, Connect, Tls, Authentication, Protocol, Configuration,
    Identity, HerdrNotFound, HerdrLaunch, Permission, Io, Unknown,
}

#[derive(Clone, Debug, Deserialize, Serialize, Eq, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct ManagedStatus {
    pub schema_version: u8,
    pub state: HostRuntimeState,
    pub updated_at_ms: u64,
    pub connection_generation: u64,
    pub restart_count: u32,
    pub last_error_category: Option<ErrorCategory>,
}
```

`StatusWriter::new` rejects symlink paths and paths outside its canonical parent. `write` creates `<name>.tmp`, writes UTF-8 JSON, flushes, sets user-only permissions where supported, and atomically renames.

- [ ] **Step 4: Verify GREEN**

```bash
cargo test -p farpilot-host --test managed_status
cargo clippy -p farpilot-host --all-targets --all-features -- -D warnings
```

Expected: tests and Clippy pass.

- [ ] **Step 5: Commit checkpoint**

After authorization:

```bash
git add crates/farpilot-host/src/lib.rs \
  crates/farpilot-host/src/managed_status.rs \
  crates/farpilot-host/tests/managed_status.rs
git commit -m "feat: add sanitized Host runtime status"
```

---

### Task 3: Add `host run-managed` and status JSON

**Files:**
- Modify: `crates/farpilot-cli/src/main.rs`
- Modify: `crates/farpilot-cli/src/host_cmd.rs`
- Modify: `crates/farpilot-cli/tests/cli.rs`
- Create: `crates/farpilot-cli/tests/managed_host.rs`

- [ ] **Step 1: Write failing CLI surface tests**

Require:

```text
farpilot host run-managed --status-file PATH --event-log PATH
farpilot host status --json
```

Tests assert unknown flags fail, managed paths outside `%LOCALAPPDATA%\FarPilot\runtime` fail before network access, and `--json` contains no static Gateway URL, Host ID, or Herdr path.

- [ ] **Step 2: Verify RED**

```bash
cargo test -p farpilot-cli --test cli --test managed_host
```

Expected: missing variants/flags.

- [ ] **Step 3: Extract a reusable Host loop**

Refactor the existing Windows `start()` loop into an internal function that accepts:

```rust
struct ManagedRunOptions {
    status_writer: Option<StatusWriter>,
    event_log: Option<PathBuf>,
}
```

State transitions:

```text
load config/identity -> starting
before connect -> connecting
HostReady -> authenticated
enter runtime -> online
transient close -> backoff(category)
permanent error -> permanent_error(category)
shutdown -> stopped
```

The ordinary foreground `host start` passes no status/log options and preserves current behavior.

- [ ] **Step 4: Implement safe managed-path validation**

On Windows, canonical runtime parent is `%LOCALAPPDATA%\FarPilot\runtime`. Reject:

- relative paths;
- paths outside runtime;
- symlink/reparse parents;
- status/log path equality;
- existing directories where a file is expected.

- [ ] **Step 5: Implement `host status --json`**

Merge static config existence with runner/Host status files, but output only:

```json
{
  "runner_state": "not_running",
  "host_state": "stale",
  "restart_count": 0,
  "last_error_category": null,
  "updated_at_ms": 0
}
```

No Host ID, display name, endpoint, Herdr path, device data, or process ID.

- [ ] **Step 6: Verify GREEN**

```bash
cargo test -p farpilot-cli --all-targets
cargo clippy -p farpilot-cli --all-targets --all-features -- -D warnings
```

- [ ] **Step 7: Commit checkpoint**

After authorization:

```bash
git add crates/farpilot-cli crates/farpilot-host
git commit -m "feat: add managed Windows Host mode"
```

---

### Task 4: Create the runner crate and portable supervision core

**Files:**
- Modify: `Cargo.toml`
- Create: `crates/farpilot-host-runner/Cargo.toml`
- Create: `crates/farpilot-host-runner/src/lib.rs`
- Create: `crates/farpilot-host-runner/src/backoff.rs`
- Create: `crates/farpilot-host-runner/src/layout.rs`
- Create: `crates/farpilot-host-runner/src/log_rotation.rs`
- Create: `crates/farpilot-host-runner/src/status.rs`
- Create: `crates/farpilot-host-runner/tests/portable.rs`

- [ ] **Step 1: Write failing portable tests**

Cover:

```text
backoff sequence 1,2,4,8,16,32,60,60
60-second online interval resets backoff
release layout accepts only direct sibling farpilot.exe
external/symlink/missing sibling rejected
log rotation caps active at 1 MiB and keeps .1/.2
runner status JSON allowlist and atomic writes
raw child error text maps to category only
```

- [ ] **Step 2: Verify RED**

```bash
cargo test -p farpilot-host-runner --test portable
```

Expected: package missing.

- [ ] **Step 3: Add workspace crate**

Add member and focused dependencies:

```toml
[package]
name = "farpilot-host-runner"
version.workspace = true
edition.workspace = true
license.workspace = true
rust-version.workspace = true

[lib]
name = "farpilot_host_runner"
path = "src/lib.rs"

[[bin]]
name = "farpilot-host-runner"
path = "src/main.rs"

[dependencies]
anyhow.workspace = true
serde.workspace = true
serde_json.workspace = true
thiserror.workspace = true

[target.'cfg(windows)'.dependencies]
windows-sys.workspace = true
```

- [ ] **Step 4: Implement portable core**

Implement pure backoff/layout/log/status functions before Windows process code. No function accepts arbitrary child arguments.

- [ ] **Step 5: Verify GREEN**

```bash
cargo test -p farpilot-host-runner --test portable
cargo clippy -p farpilot-host-runner --all-targets --all-features -- -D warnings
```

- [ ] **Step 6: Commit checkpoint**

After authorization:

```bash
git add Cargo.toml Cargo.lock crates/farpilot-host-runner
git commit -m "feat: add Windows Host runner core"
```

---

### Task 5: Implement Windows mutex, Job Object, hidden child, and restart loop

**Files:**
- Modify: `Cargo.toml` (`windows-sys` features)
- Create: `crates/farpilot-host-runner/src/main.rs`
- Create: `crates/farpilot-host-runner/src/windows.rs`
- Create: `crates/farpilot-host-runner/tests/windows_lifecycle.rs`

- [ ] **Step 1: Expand only required Windows APIs**

Add features for Foundation handles/errors, process/thread creation, Job Objects, synchronization/mutex, security token/SID lookup, and filesystem process flags. Do not enable broad Windows feature sets.

- [ ] **Step 2: Write Windows-only failing tests**

Under `#[cfg(windows)]`, test:

```text
GetConsoleWindow() is null in runner process
second runner exits AlreadyRunning
fixture child is assigned to Job Object
runner termination kills child
child exit 42 restarts with expected delay
stable child resets restart count
external sibling path rejected
runner --version equals workspace package version
```

Tests use a dedicated fixture executable built in the same test package; they do not start FarPilot or access real `%LOCALAPPDATA%`.

- [ ] **Step 3: Verify RED on Windows CI or authorized local Windows runner**

Stop before dispatch. After explicit authorization, run the Windows test job only. Expected: compile/test failures for missing Windows runner implementation.

- [ ] **Step 4: Implement minimal Windows lifecycle**

Required API behavior:

```text
CreateMutexW: current-user SID-derived name
CreateJobObjectW + SetInformationJobObject: KILL_ON_JOB_CLOSE
CommandExt::creation_flags(CREATE_NO_WINDOW)
child stdin null; stdout/stderr managed log files
AssignProcessToJobObject before accepted running state
WaitForSingleObject / child wait
Ctrl/task termination closes handles and child
```

Use RAII wrappers for every raw handle. Treat invalid/failed handles as fatal.

- [ ] **Step 5: Compile runner as GUI subsystem**

At the runner binary root:

```rust
#![cfg_attr(windows, windows_subsystem = "windows")]
```

Non-Windows invocation exits with an unsupported-platform message; portable tests remain runnable.

- [ ] **Step 6: Verify GREEN on Windows**

After explicit authorization:

```text
cargo test -p farpilot-host-runner --all-targets
cargo clippy -p farpilot-host-runner --all-targets --all-features -- -D warnings
```

- [ ] **Step 7: Commit checkpoint**

After tests and commit authorization:

```bash
git add Cargo.toml Cargo.lock crates/farpilot-host-runner
git commit -m "feat: supervise Windows Host without a console"
```

---

### Task 6: Extend release manifests for the Windows ZIP

**Files:**
- Modify: `scripts/release_manifest.py`
- Modify: `scripts/validate_release_assets.py`
- Modify: `tests/release/test_release_manifest.py`

- [ ] **Step 1: Write failing ZIP manifest tests**

Change expected Windows record to:

```json
{"format": "zip"}
```

Add rejection tests for unexpected format/extension mismatch and exact repository/tag/filename semantics.

- [ ] **Step 2: Verify RED**

```bash
python3 -m unittest tests.release.test_release_manifest -v
```

Expected: current `exe` format assertion fails.

- [ ] **Step 3: Implement Windows ZIP format**

Generator uses `zip` only for `windows-x86_64`; validator accepts `binary` for Unix and `zip` for Windows and still enforces exact assets/digests/URLs.

- [ ] **Step 4: Verify GREEN**

```bash
python3 -m unittest tests.release.test_release_manifest -v
python3 -m py_compile scripts/release_manifest.py scripts/validate_release_assets.py
```

- [ ] **Step 5: Commit checkpoint**

After authorization:

```bash
git add scripts/release_manifest.py scripts/validate_release_assets.py tests/release/test_release_manifest.py
git commit -m "feat: describe Windows two-binary ZIP releases"
```

---

### Task 7: Add fail-closed Windows ZIP extraction

**Files:**
- Modify: `deploy/windows/install.ps1`
- Modify: `deploy/windows/test-install.ps1`
- Modify: `docs/installer-security.md`

- [ ] **Step 1: Add RED archive fixtures**

The PowerShell suite creates ZIPs for:

```text
valid exact two files
missing runner
missing CLI
extra file
directory entry
../ traversal
absolute/drive path
nested path
case-insensitive duplicate
reparse/symlink external attributes
oversized entry/aggregate
version mismatch between binaries
```

Every invalid fixture must fail before task/process/PATH/junction/release mutation.

- [ ] **Step 2: Verify RED on Windows**

After explicit workflow authorization, run `deploy/windows/test-install.ps1`; expected failure at unsupported ZIP/local package behavior.

- [ ] **Step 3: Implement `Expand-VerifiedFarPilotPackage`**

Use `System.IO.Compression.ZipArchive` in read mode. Validate the complete central directory before writing any file. Extract only by opening each accepted entry stream and copying bytes to installer-created regular destination files named exactly `farpilot.exe` and `farpilot-host-runner.exe`.

Do not call `Expand-Archive`.

- [ ] **Step 4: Validate both binaries**

Require exact matching version and independent Authenticode policy for both. Existing single-EXE local package injection remains supported only for migration/tests until the first ZIP release, and cannot enter the stable ZIP path.

- [ ] **Step 5: Verify GREEN on Windows**

```powershell
Invoke-ScriptAnalyzer -Path deploy/windows/install.ps1 -ExcludeRule PSUseApprovedVerbs
deploy/windows/test-install.ps1
```

- [ ] **Step 6: Commit checkpoint**

After authorization:

```bash
git add deploy/windows/install.ps1 deploy/windows/test-install.ps1 docs/installer-security.md
git commit -m "feat: install exact Windows FarPilot ZIP packages"
```

---

### Task 8: Point installer task/lifecycle at the runner

**Files:**
- Modify: `deploy/windows/install.ps1`
- Modify: `deploy/windows/test-install.ps1`
- Modify: `docs/uninstall.md`

- [ ] **Step 1: Write failing task/migration/rollback tests**

Assert:

```text
Scheduled Task executable is bin\farpilot-host-runner.exe
arguments exactly run
Limited current-user AtLogOn
single-EXE legacy release migrates without mutation
runner and CLI processes under releases/bin/current stop
external same-name processes survive
failed online deadline restores prior package and task
uninstall removes runtime logs/status but preserves identity/config
PurgeState removes known identity/config after confirmation
retention never keeps incomplete release directories
```

- [ ] **Step 2: Verify RED on Windows**

Expected current direct-CLI task assertions fail.

- [ ] **Step 3: Implement transaction changes**

Capture previous task/process/runtime state; stop task; wait bounded time for runner/job child; clean remaining managed processes; activate exact release; register runner task; start when previous task or managed Host existed; poll sanitized status files for fresh `online`; roll back all state on failure.

- [ ] **Step 4: Verify GREEN on Windows**

Run installer tests and PSScriptAnalyzer.

- [ ] **Step 5: Commit checkpoint**

After authorization:

```bash
git add deploy/windows/install.ps1 deploy/windows/test-install.ps1 docs/uninstall.md
git commit -m "feat: manage Windows Host through the runner"
```

---

### Task 9: Build and package both Windows executables in CI/Release

**Files:**
- Modify: `.github/workflows/ci.yml`
- Modify: `.github/workflows/release.yml`
- Modify: `tests/release/workflow_assets.sh`
- Modify: `tests/workspace_layout.sh`

- [ ] **Step 1: Write failing workflow contracts**

Require:

```text
Windows CI builds both --bin farpilot and --bin farpilot-host-runner
native --version on both
runner lifecycle tests
release stages exact two-file ZIP
ZIP artifact name farpilot-windows-x86_64.zip
manifest validation after ZIP creation
publish job never uploads loose Windows EXEs
```

- [ ] **Step 2: Verify RED locally**

```bash
bash tests/release/workflow_assets.sh
bash tests/workspace_layout.sh
```

Expected missing runner/ZIP assertions fail.

- [ ] **Step 3: Implement deterministic package assembly**

Use PowerShell/.NET ZIP APIs with deterministic filenames and no extra entries. Release validation inspects the produced ZIP central directory and both native versions before upload.

- [ ] **Step 4: Verify static contracts GREEN**

Run the two shell contract suites and `git diff --check`.

- [ ] **Step 5: Workflow authorization checkpoint**

Stop before push/PR/workflow. Present exact workflow permissions, matrix, local tests, and expected Windows artifacts.

---

### Task 10: Full local review and PR

**Files:** all changed files

- [ ] **Step 1: Run full local portable gates**

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
bash tests/release/workflow_assets.sh
bash tests/e2e/gateway-host.sh
git diff --check
```

- [ ] **Step 2: Independent security/correctness review**

Review Windows handle ownership, Job Object cleanup, mutex scope, archive extraction, task lifecycle, rollback, log sanitization, process path boundaries, and package/version/signature ordering. Fix only verified findings and rerun all gates.

- [ ] **Step 3: Commit/push/PR authorization checkpoint**

Stop and present commits, test matrix, known platform gaps, and exact diff. Do not push or create PR without explicit authorization.

- [ ] **Step 4: Run PR CI after authorization**

Require Format/lint, OpenSSH, Ubuntu, macOS, and Windows jobs. The Windows job must run native runner/installer integration tests. Do not merge if any job is skipped unexpectedly, pending indefinitely, cancelled, or failed.

- [ ] **Step 5: Merge authorization checkpoint**

Present all checks and review outcome. Merge only after explicit authorization.

---

### Task 11: Real DevBox acceptance

**Files:**
- Create/modify after acceptance: `scripts/acceptance/windows_background_host.ps1`
- Modify after acceptance: `docs/stage0-acceptance.md`
- Modify after acceptance: `docs/stage0-runbook.md`
- Modify after acceptance: `README.md`

- [ ] **Step 1: Build a single signed-or-explicitly-unsigned reviewed candidate**

Use the PR's successful Windows artifact. Verify source SHA, ZIP SHA, exact two entries, both versions, and signing status. Do not publish stable/latest.

- [ ] **Step 2: Create one pinned acceptance script**

The script downloads one fixed artifact/installer commit, validates hashes, installs, verifies task/runner/child/status/logs, performs child-kill recovery, stops/starts task, and outputs one sanitized JSON object. It never prints Host/Gateway/device/key/fingerprint data.

- [ ] **Step 3: DevBox authorization checkpoint**

Ask once for permission to run the pinned script. This is the only required user command.

- [ ] **Step 4: Automated post-install verification**

From Mac/Gateway, verify one logical Host, health, Mac/Moshi Herdr, no inbound listener, child restart, task stop/start, and sanitized logs. A DevBox logoff/logon remains a physical user action but is requested only after every other result passes.

- [ ] **Step 5: Record sanitized acceptance and update docs**

Mark background Host accepted only if every spec criterion passes. Otherwise restore the foreground mode, keep docs Pending, and record the precise failure class.

- [ ] **Step 6: Final commit/push authorization checkpoint**

Do not publish acceptance claims without Polly's confirmation of the physical logon/no-window observations.
