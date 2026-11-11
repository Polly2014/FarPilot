# FarPilot MVP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a self-hosted FarPilot MVP that lets Mac OpenSSH and iPhone Moshi attach to persistent Herdr sessions on a native Windows 11 DevBox through an outbound-only WSS Host connection.

**Architecture:** A Rust workspace supplies a shared protocol crate, Linux Gateway, Windows Host, and cross-platform CLI. Linux system OpenSSH invokes a restricted `farpilot gateway attach` command; Gateway multiplexes that terminal stream over the authenticated Host's WSS control connection; Host bridges the stream to a fixed Herdr executable under Windows ConPTY.

**Tech Stack:** Rust stable, Tokio, Axum WebSockets/HTTP, rustls, Serde, Ed25519, SQLite/sqlx, portable-pty/Windows ConPTY, Clap, system OpenSSH, Caddy, PowerShell, cargo-nextest.

**Approved specification:** `X-Workspace/FarPilot/docs/specs/2026-11-11-farpilot-mvp-design.md`

**Execution workspace:** branch `feature/farpilot-mvp` in `/Users/polly/.config/superpowers/worktrees/www.polly.com/farpilot-mvp`

**Repository policy:** Do not create Git commits until the user explicitly authorizes commits. Each task ends with a diff/status checkpoint instead of an automatic commit.

---

## File map

```text
X-Workspace/FarPilot/
├── CLAUDE.md                         # Project commands, boundaries, architecture
├── AGENTS.md -> CLAUDE.md            # Cross-agent instruction compatibility
├── README.md                         # User-facing Stage 0 overview
├── Cargo.toml                        # Workspace and shared dependency versions
├── rust-toolchain.toml               # Stable toolchain and components
├── deny.toml                         # Dependency/license policy
├── crates/
│   ├── farpilot-core/
│   │   ├── Cargo.toml
│   │   ├── src/lib.rs
│   │   ├── src/limits.rs             # Protocol and queue limits
│   │   ├── src/frame.rs              # Versioned control/binary frame codec
│   │   ├── src/identity.rs           # Host/device keys and signatures
│   │   ├── src/pairing.rs            # Pairing-token creation and validation
│   │   └── tests/protocol.rs
│   ├── farpilot-gateway/
│   │   ├── Cargo.toml
│   │   ├── src/lib.rs
│   │   ├── src/config.rs             # Environment/file configuration
│   │   ├── src/store.rs              # SQLite hosts/devices/grants/audit repository
│   │   ├── src/pairing_http.rs       # Host enrollment and device-pairing HTTP routes
│   │   ├── src/host_ws.rs            # Host challenge/response WSS admission
│   │   ├── src/broker.rs             # Host/session registry and multiplexing
│   │   ├── src/attach.rs             # Restricted SSH forced-command bridge
│   │   ├── src/authorized_keys.rs    # Per-device restricted key rendering
│   │   ├── src/health.rs             # Liveness/readiness/metrics
│   │   └── tests/gateway_flow.rs
│   ├── farpilot-host/
│   │   ├── Cargo.toml
│   │   ├── src/lib.rs
│   │   ├── src/config.rs             # Windows paths and Gateway config
│   │   ├── src/identity_store.rs      # DPAPI/file-backed Host identity
│   │   ├── src/reconnect.rs           # Bounded exponential retry
│   │   ├── src/client.rs              # WSS auth/control loop
│   │   ├── src/pty.rs                 # PTY trait and portable-pty implementation
│   │   ├── src/herdr.rs               # Fixed executable/session launcher
│   │   ├── src/session.rs             # Channel-to-ConPTY lifecycle
│   │   └── tests/host_flow.rs
│   └── farpilot-cli/
│       ├── Cargo.toml
│       ├── src/main.rs                # Clap entry point
│       ├── src/host_cmd.rs            # host setup/start/status
│       ├── src/gateway_cmd.rs         # gateway serve/status/attach/enroll
│       ├── src/pair_cmd.rs            # Mac key enrollment and SSH profile
│       ├── src/device_cmd.rs          # devices/revoke
│       └── src/qr.rs                  # Console QR renderer
├── deploy/
│   ├── gateway/Caddyfile
│   ├── gateway/farpilot-gateway.service
│   ├── gateway/sshd_config.fragment
│   ├── gateway/install.sh
│   └── windows/install.ps1
├── tests/
│   ├── e2e/README.md
│   ├── e2e/gateway-host.sh
│   └── security/sshd_restrictions.sh
└── docs/
    ├── specs/2026-11-11-farpilot-mvp-design.md
    ├── plans/2026-11-11-farpilot-mvp-implementation.md
    └── stage0-runbook.md
```

---

### Task 1: Project instructions and Rust workspace scaffold

**Files:**
- Create: `X-Workspace/FarPilot/CLAUDE.md`
- Create symlink: `X-Workspace/FarPilot/AGENTS.md -> CLAUDE.md`
- Create: `X-Workspace/FarPilot/README.md`
- Create: `X-Workspace/FarPilot/Cargo.toml`
- Create: `X-Workspace/FarPilot/rust-toolchain.toml`
- Create: `X-Workspace/FarPilot/deny.toml`
- Create: four crate manifests and minimal `src` entry points listed in the file map

- [x] **Step 1: Write the workspace validation test**

Create `X-Workspace/FarPilot/tests/workspace_layout.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
test -f "$root/CLAUDE.md"
test -L "$root/AGENTS.md"
test "$(readlink "$root/AGENTS.md")" = "CLAUDE.md"
test -f "$root/Cargo.toml"
for crate in farpilot-core farpilot-gateway farpilot-host farpilot-cli; do
  test -f "$root/crates/$crate/Cargo.toml"
done
```

- [x] **Step 2: Run the layout test and verify it fails**

Run:

```bash
bash X-Workspace/FarPilot/tests/workspace_layout.sh
```

Expected: nonzero exit at missing `CLAUDE.md`.

- [x] **Step 3: Create project instructions**

`CLAUDE.md` must state:

```markdown
# FarPilot

FarPilot securely connects standard SSH terminals to persistent Herdr sessions on outbound-only Windows hosts.

## Commands
- `cargo fmt --all -- --check`
- `cargo clippy --workspace --all-targets --all-features -- -D warnings`
- `cargo nextest run --workspace`
- `cargo test --doc --workspace`

## Architecture boundaries
- `farpilot-core` contains protocol/crypto types and has no network or database code.
- `farpilot-gateway` runs on Linux and owns SSH admission metadata, pairing, registry, and relay.
- `farpilot-host` runs on native Windows and may launch only the configured Herdr executable.
- `farpilot-cli` contains command parsing and delegates behavior to library crates.

## Security invariants
- DevBox exposes no inbound listener.
- Gateway's SSH account never provides a general shell or port forwarding.
- QR codes never contain private keys or reusable bearer credentials.
- Terminal payloads, prompts, repository contents, and environment values are never logged.
- Unknown protocol versions, oversized frames, and unauthorized Host/device combinations fail closed.
- Do not add arbitrary remote command execution; the MVP launches only Herdr.

## Development workflow
- Follow TDD: failing test, minimal implementation, verification.
- Run targeted tests before workspace-wide checks.
- Do not commit or push unless explicitly requested.
```

Create the symlink with:

```bash
ln -s CLAUDE.md X-Workspace/FarPilot/AGENTS.md
```

- [x] **Step 4: Create the workspace manifests**

Root `Cargo.toml`:

```toml
[workspace]
resolver = "2"
members = [
  "crates/farpilot-core",
  "crates/farpilot-gateway",
  "crates/farpilot-host",
  "crates/farpilot-cli",
]

[workspace.package]
version = "0.1.0"
edition = "2024"
license = "Apache-2.0"
rust-version = "1.85"

[workspace.dependencies]
anyhow = "1"
async-trait = "0.1"
axum = { version = "0.8", features = ["ws"] }
base64 = "0.22"
bytes = "1"
clap = { version = "4", features = ["derive", "env"] }
ed25519-dalek = { version = "2", features = ["rand_core"] }
futures-util = "0.3"
portable-pty = "0.9"
qrcode = "0.14"
rand = "0.8"
reqwest = { version = "0.12", default-features = false, features = ["json", "rustls-tls"] }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
sha2 = "0.10"
sqlx = { version = "0.8", features = ["runtime-tokio-rustls", "sqlite", "migrate"] }
subtle = "2"
thiserror = "2"
tokio = { version = "1", features = ["full"] }
tokio-tungstenite = { version = "0.28", features = ["rustls-tls-webpki-roots"] }
tower-http = { version = "0.6", features = ["limit", "request-id", "trace"] }
tracing = "0.1"
tracing-subscriber = { version = "0.3", features = ["env-filter", "json"] }
url = "2"
uuid = { version = "1", features = ["v4", "serde"] }
zeroize = { version = "1", features = ["derive"] }
```

`rust-toolchain.toml`:

```toml
[toolchain]
channel = "stable"
components = ["clippy", "rustfmt"]
profile = "minimal"
```

Each library crate starts with `pub fn crate_ready() -> bool { true }`; CLI prints `farpilot 0.1.0` for `--version`.

- [x] **Step 5: Run the layout and Rust baseline checks**

Run:

```bash
bash X-Workspace/FarPilot/tests/workspace_layout.sh
cargo test --manifest-path X-Workspace/FarPilot/Cargo.toml --workspace
```

Expected: layout exits 0; all four crate smoke tests pass.

- [x] **Step 6: Review checkpoint**

Run:

```bash
git status --short -- X-Workspace/FarPilot
git diff -- X-Workspace/FarPilot/CLAUDE.md X-Workspace/FarPilot/Cargo.toml
```

Expected: only FarPilot files are new; no commit is created.

---

### Task 2: Versioned protocol frames and limits

**Files:**
- Create: `crates/farpilot-core/src/limits.rs`
- Create: `crates/farpilot-core/src/frame.rs`
- Modify: `crates/farpilot-core/src/lib.rs`
- Test: `crates/farpilot-core/tests/protocol.rs`

- [x] **Step 1: Write failing protocol tests**

```rust
use farpilot_core::frame::{ControlFrame, FrameCodec, ProtocolError};
use farpilot_core::limits::MAX_CONTROL_FRAME_BYTES;
use uuid::Uuid;

#[test]
fn control_frame_round_trips() {
    let frame = ControlFrame::Ping { nonce: 42 };
    let bytes = FrameCodec::encode_control(&frame).unwrap();
    assert_eq!(FrameCodec::decode_control(&bytes).unwrap(), frame);
}

#[test]
fn oversized_control_frame_is_rejected() {
    let bytes = vec![b'x'; MAX_CONTROL_FRAME_BYTES + 1];
    assert_eq!(FrameCodec::decode_control(&bytes), Err(ProtocolError::FrameTooLarge));
}

#[test]
fn terminal_data_requires_channel_id() {
    let channel_id = Uuid::new_v4();
    let bytes = FrameCodec::encode_terminal(channel_id, b"hello").unwrap();
    let decoded = FrameCodec::decode_terminal(&bytes).unwrap();
    assert_eq!(decoded.channel_id, channel_id);
    assert_eq!(&decoded.payload[..], b"hello");
}
```

- [x] **Step 2: Verify failure**

Run:

```bash
cargo test --manifest-path X-Workspace/FarPilot/Cargo.toml -p farpilot-core --test protocol
```

Expected: compile failure because `frame` and `limits` modules do not exist.

- [x] **Step 3: Implement typed frames**

Define constants:

```rust
pub const PROTOCOL_VERSION: u16 = 1;
pub const MAX_CONTROL_FRAME_BYTES: usize = 64 * 1024;
pub const MAX_TERMINAL_FRAME_BYTES: usize = 256 * 1024;
pub const MAX_CHANNELS_PER_HOST: usize = 16;
pub const MAX_PENDING_BYTES_PER_CHANNEL: usize = 1024 * 1024;
```

Define `ControlFrame` variants matching the spec: `HostHello`, `HostChallenge`, `HostProof`, `HostReady`, `SessionOpen`, `SessionOpened`, `SessionRefused`, `TerminalResize`, `Ping`, `Pong`, `SessionClose`, `SessionExited`, and `ProtocolError`. Every session variant carries `Uuid channel_id`. Encode control frames as JSON with explicit `version`; encode terminal frames as `version:u16 | channel_uuid:16 bytes | payload`.

- [x] **Step 4: Add negative tests**

Cover unsupported versions, malformed UUID headers, oversized terminal payloads, and unknown JSON frame types. Expected result for every malformed input: a typed `ProtocolError`, never panic.

- [x] **Step 5: Run core tests**

```bash
cargo test --manifest-path X-Workspace/FarPilot/Cargo.toml -p farpilot-core
```

Expected: all protocol tests pass.

- [x] **Step 6: Review checkpoint**

```bash
git diff --stat -- X-Workspace/FarPilot/crates/farpilot-core
```

---

### Task 3: Host identity, signatures, and one-time pairing tokens

**Files:**
- Create: `crates/farpilot-core/src/identity.rs`
- Create: `crates/farpilot-core/src/pairing.rs`
- Modify: `crates/farpilot-core/src/lib.rs`
- Test: `crates/farpilot-core/tests/identity_pairing.rs`

- [x] **Step 1: Write failing identity and token tests**

```rust
use farpilot_core::identity::{HostIdentity, HostProof};
use farpilot_core::pairing::{PairingToken, PairingTokenStore};
use std::time::{Duration, SystemTime};

#[test]
fn host_proof_binds_challenge_and_host_id() {
    let identity = HostIdentity::generate();
    let challenge = [7u8; 32];
    let proof = identity.sign_challenge("host_123", &challenge);
    HostProof::verify(identity.public_key(), "host_123", &challenge, &proof).unwrap();
    assert!(HostProof::verify(identity.public_key(), "host_other", &challenge, &proof).is_err());
}

#[test]
fn pairing_token_is_single_use_and_expires() {
    let now = SystemTime::UNIX_EPOCH + Duration::from_secs(1_000);
    let mut store = PairingTokenStore::new();
    let token = PairingToken::generate("host_123", now, Duration::from_secs(300));
    store.insert(token.record());
    assert!(store.consume(token.secret(), now).is_ok());
    assert!(store.consume(token.secret(), now).is_err());
}
```

- [x] **Step 2: Verify failure**

Run the test and expect missing module/type errors.

- [x] **Step 3: Implement identity primitives**

`HostIdentity` wraps an Ed25519 signing key and exposes only generation, serialization for local persistence, public-key export, and domain-separated challenge signing. The signed transcript is exactly:

```text
farpilot-host-proof/v1\0<host-id>\0<32-byte-challenge>
```

Use constant-time verification paths supplied by `ed25519-dalek`; zeroize private-key buffers after serialization.

- [x] **Step 4: Implement pairing tokens**

Generate 32 random bytes, expose URL-safe base64 without padding, store only SHA-256 digest plus Host ID, creation, expiry, and consumed timestamp. `consume` must atomically distinguish success internally while returning one public `InvalidPairingToken` error for unknown, expired, and consumed values.

- [x] **Step 5: Run tests and property loop**

```bash
cargo test --manifest-path X-Workspace/FarPilot/Cargo.toml -p farpilot-core --test identity_pairing
```

Add a test generating 10,000 tokens and assert all secrets are unique and 43 characters long.

- [x] **Step 6: Review checkpoint**

Check that no `Debug` implementation prints private key bytes or raw pairing secrets.

---

### Task 4: Gateway SQLite registry and audit repository

**Files:**
- Create: `crates/farpilot-gateway/migrations/0001_init.sql`
- Create: `crates/farpilot-gateway/src/store.rs`
- Modify: `crates/farpilot-gateway/src/lib.rs`
- Test: `crates/farpilot-gateway/tests/store.rs`

- [x] **Step 1: Write failing repository tests**

Tests create `sqlite::memory:` and verify:

```rust
let host = store.enroll_host("Company DevBox", public_key).await?;
let device = store.add_device("Baoli MacBook", ssh_public_key).await?;
store.grant_device(&device.id, &host.id).await?;
assert!(store.device_can_access(&device.id, &host.id).await?);
store.revoke_device(&device.id).await?;
assert!(!store.device_can_access(&device.id, &host.id).await?);
```

Also verify audit rows store action/outcome/IDs but contain no terminal text or raw token.

- [x] **Step 2: Verify failure**

Expected: missing migration and `GatewayStore`.

- [x] **Step 3: Create normalized schema**

Tables: `hosts`, `devices`, `device_host_grants`, `pairing_tokens`, `host_enrollment_tokens`, `audit_events`. Use opaque UUID text primary keys, unique public-key fingerprints, foreign keys, revocation timestamps, and indexes for active-token lookup.

- [x] **Step 4: Implement transactional operations**

`consume_pairing_token_and_add_device` must run in one SQLite transaction: atomically mark token consumed, insert/upsert device, add grant, and append audit event.

- [x] **Step 5: Run tests**

```bash
cargo test --manifest-path X-Workspace/FarPilot/Cargo.toml -p farpilot-gateway --test store
```

Expected: all repository and transaction-race tests pass.

- [x] **Step 6: Review checkpoint**

Run `rg -n 'token_secret|terminal_data|prompt' crates/farpilot-gateway/src/store.rs migrations` and verify no schema stores those values.

---

### Task 5: Gateway enrollment and device-pairing HTTP API

**Files:**
- Create: `crates/farpilot-gateway/src/config.rs`
- Create: `crates/farpilot-gateway/src/pairing_http.rs`
- Create: `crates/farpilot-gateway/src/health.rs`
- Modify: `crates/farpilot-gateway/src/lib.rs`
- Test: `crates/farpilot-gateway/tests/pairing_http.rs`

- [x] **Step 1: Write failing HTTP tests**

Using `tower::ServiceExt`, test:

- `POST /v1/hosts/enroll` consumes an operator-generated enrollment token and returns Host ID.
- `GET /pair/:secret` returns generic 404 for invalid/expired/consumed tokens.
- `POST /v1/pair/:secret/claim` accepts device name plus OpenSSH Ed25519 public key.
- request bodies over 16 KiB return 413.
- more than five failed pairing attempts from one address in one minute returns 429.

- [x] **Step 2: Verify failure**

Expected: routes do not exist.

- [x] **Step 3: Implement request schemas and validation**

Use strict Serde request structs with `deny_unknown_fields`. Accept only `ssh-ed25519` keys whose decoded blob parses and whose comment is discarded. Device names are trimmed UTF-8, 1–64 scalar values, with control characters rejected.

- [x] **Step 4: Implement pairing page fallback**

Render server-side HTML containing Host display name, Gateway SSH hostname, verified SSH fingerprint, expiry countdown, public-key textarea, device-name input, and explicit confirmation. No JavaScript framework is introduced.

- [x] **Step 5: Add health endpoints**

`/health/live` checks process liveness; `/health/ready` checks SQLite migration state and broker initialization. Neither endpoint exposes Host/device details.

- [x] **Step 6: Run tests**

```bash
cargo test --manifest-path X-Workspace/FarPilot/Cargo.toml -p farpilot-gateway --test pairing_http
```

Expected: all API, limit, and redaction tests pass.

---

### Task 6: Authenticated Host WSS connection and reconnect policy

**Files:**
- Create: `crates/farpilot-gateway/src/host_ws.rs`
- Create: `crates/farpilot-host/src/identity_store.rs`
- Create: `crates/farpilot-host/src/reconnect.rs`
- Create: `crates/farpilot-host/src/client.rs`
- Modify: both crate `lib.rs` files
- Test: `crates/farpilot-host/tests/connection.rs`

- [x] **Step 1: Write failing challenge-response test**

Start an in-process Axum WSS endpoint, send `HostHello`, assert Gateway returns a random `HostChallenge`, send a valid `HostProof`, and assert `HostReady`. Repeat with a proof for another Host ID and expect policy close.

- [x] **Step 2: Write failing retry test with paused Tokio time**

Assert retry delays begin near 1 second, double with bounded jitter, never exceed 120 seconds, and reset only after 60 seconds of authenticated stability.

- [x] **Step 3: Implement Host identity storage**

On Windows use `%LOCALAPPDATA%\FarPilot\host-identity.json` with ACL inherited from the user profile and private key material protected using Windows DPAPI. Non-Windows test builds use an injected `IdentityStore` trait backed by a temporary file.

- [x] **Step 4: Implement WSS admission**

Gateway issues a fresh 32-byte challenge with a 10-second deadline. It verifies enrolled Host public key, transcript signature, protocol version, and one active control connection per Host. A replacement connection closes the stale transport only after authentication succeeds.

- [x] **Step 5: Implement reconnect loop**

Host validates HTTPS/WSS URL, uses rustls roots, sends no private credential in URL query parameters, and classifies permanent enrollment/protocol failures separately from transient network failures.

- [x] **Step 6: Run tests**

```bash
cargo test --manifest-path X-Workspace/FarPilot/Cargo.toml -p farpilot-host --test connection
cargo test --manifest-path X-Workspace/FarPilot/Cargo.toml -p farpilot-gateway host_ws
```

Expected: authentication, takeover, timeout, and retry tests pass.

---

### Task 7: Gateway broker and bounded terminal multiplexing

**Files:**
- Create: `crates/farpilot-gateway/src/broker.rs`
- Create: `crates/farpilot-host/src/session.rs`
- Test: `crates/farpilot-gateway/tests/broker.rs`
- Test: `crates/farpilot-host/tests/session.rs`

- [x] **Step 1: Write failing broker lifecycle tests**

Test online/offline registration, unauthorized device refusal, maximum channels, unique channel IDs, Host disconnect closing all channels, and no implicit channel replay after Host reconnect.

- [x] **Step 2: Write failing backpressure tests**

Use a client that stops reading. Fill the per-channel queue beyond `MAX_PENDING_BYTES_PER_CHANNEL`; assert only that channel receives `SessionClose { reason: SlowConsumer }` and the Host control connection remains online.

- [x] **Step 3: Implement broker interfaces**

Define `HostRegistry`, `SessionBroker`, and `AttachHandle`. Use bounded Tokio MPSC channels. Broker authorizes every open against current SQLite grant state rather than cached pairing state.

- [x] **Step 4: Implement typed session routing**

Route `SessionOpen`, terminal binary frames, resize, close, and exit by channel UUID. Reject frames for unknown channels without creating state.

- [x] **Step 5: Run tests**

```bash
cargo test --manifest-path X-Workspace/FarPilot/Cargo.toml -p farpilot-gateway --test broker
cargo test --manifest-path X-Workspace/FarPilot/Cargo.toml -p farpilot-host --test session
```

Expected: lifecycle and pressure tests pass without leaked tasks.

---

### Task 8: Windows ConPTY and fixed Herdr launcher

**Files:**
- Create: `crates/farpilot-host/src/pty.rs`
- Create: `crates/farpilot-host/src/herdr.rs`
- Modify: `crates/farpilot-host/src/session.rs`
- Test: `crates/farpilot-host/tests/host_flow.rs`

- [x] **Step 1: Define a testable PTY boundary**

```rust
#[async_trait]
pub trait PtySession: Send {
    async fn write_input(&mut self, bytes: &[u8]) -> anyhow::Result<()>;
    async fn read_output(&mut self, buf: &mut [u8]) -> anyhow::Result<usize>;
    async fn resize(&mut self, cols: u16, rows: u16) -> anyhow::Result<()>;
    async fn close(&mut self) -> anyhow::Result<()>;
}

#[async_trait]
pub trait PtyFactory: Send + Sync {
    async fn spawn_herdr(&self, request: HerdrLaunch) -> anyhow::Result<Box<dyn PtySession>>;
}
```

Write a fake PTY test proving data, resize, and close are routed correctly.

- [x] **Step 2: Verify fake-flow test fails**

Expected: missing traits/session implementation.

- [x] **Step 3: Implement strict Herdr configuration**

`HerdrLaunch` contains only validated executable path, optional fixed session name from local config, columns, and rows. Reject network-provided executable paths, arguments, working directories, environment variables, and shell fragments.

- [x] **Step 4: Implement Windows PTY adapter**

Use `portable-pty` on Windows to spawn the configured Herdr executable directly, never through `powershell -Command` or `cmd /C`. Wire reader/writer, resize, child exit, and cancellation. Non-Windows builds expose only the trait/fake needed by Gateway tests.

- [x] **Step 5: Add Windows validation script**

Create a PowerShell test that launches a deterministic console fixture through FarPilot Host, sends CJK text, ANSI alternate-screen control, and resize events, and verifies echoed output and exit status.

- [x] **Step 6: Run portable tests and record Windows command**

Mac/Linux:

```bash
cargo test --manifest-path X-Workspace/FarPilot/Cargo.toml -p farpilot-host --test host_flow
```

Windows DevBox acceptance command:

```powershell
cargo test -p farpilot-host --features windows-conpty --test windows_conpty
```

Expected: portable fake tests pass now; real Windows test is required before Task 13 completion.

---

### Task 9: Restricted OpenSSH forced-command attachment

**Files:**
- Create: `crates/farpilot-gateway/src/authorized_keys.rs`
- Create: `crates/farpilot-gateway/src/attach.rs`
- Create: `crates/farpilot-cli/src/gateway_cmd.rs`
- Test: `crates/farpilot-gateway/tests/ssh_attach.rs`

- [x] **Step 1: Write failing authorized-key rendering test**

Expected line shape:

```text
restrict,command="/usr/local/bin/farpilot gateway attach --device-id dev_123" ssh-ed25519 AAAA... FarPilot-device
```

Test shell metacharacters cannot enter device IDs, comments, or commands; only opaque UUID-derived IDs are accepted.

- [x] **Step 2: Write failing attach tests**

Inject fake stdin/stdout/resize source and fake broker. Verify attach identifies device from fixed CLI argument, displays Host picker only for authorized online Hosts, opens one channel, forwards bytes, forwards resize, and exits nonzero for offline/revoked devices.

- [x] **Step 3: Implement atomic `authorized_keys` writer**

Render all active device keys to a temporary file with mode 0600, `fsync`, and atomic rename. Preserve no unmanaged lines because the dedicated account's file is FarPilot-owned.

- [x] **Step 4: Implement attach bridge**

Read raw stdin and write raw stdout without interpreting terminal bytes. Observe Unix `SIGWINCH`, read terminal size, and send `TerminalResize`. Never invoke a shell or parse `SSH_ORIGINAL_COMMAND` as shell syntax.

- [x] **Step 5: Run tests**

```bash
cargo test --manifest-path X-Workspace/FarPilot/Cargo.toml -p farpilot-gateway --test ssh_attach
```

Expected: key restriction and attach tests pass.

- [ ] **Step 6: Verify generated sshd restrictions in a disposable Linux container/VM**

Attempt shell, `-L`, `-R`, agent forwarding, X11 forwarding, and arbitrary remote command. Every attempt must fail; plain interactive attachment must reach fake Herdr.

---

### Task 10: CLI setup, QR, pair, device list, and revocation

**Files:**
- Create: `crates/farpilot-cli/src/host_cmd.rs`
- Create: `crates/farpilot-cli/src/pair_cmd.rs`
- Create: `crates/farpilot-cli/src/device_cmd.rs`
- Create: `crates/farpilot-cli/src/qr.rs`
- Modify: `crates/farpilot-cli/src/main.rs`
- Test: `crates/farpilot-cli/tests/cli.rs`

- [x] **Step 1: Write failing Clap contract tests**

Use `assert_cmd` to verify these commands and required arguments:

```text
farpilot host setup --gateway <https-url> --enrollment-code <code> --name <name>
farpilot host start
farpilot host status
farpilot gateway serve
farpilot gateway enrollment create
farpilot pair <code-or-url>
farpilot devices
farpilot revoke <device-id>
```

Unknown flags and HTTP Gateway URLs must fail before network access.

- [x] **Step 2: Implement `host setup`**

Generate/protect Host identity, enroll over HTTPS, write local config atomically, connect once, request a five-minute client pairing token over authenticated WSS, and render URL + short code + Unicode QR.

- [x] **Step 3: Implement Mac `pair`**

Generate a dedicated Ed25519 key using `ssh-keygen` only when no FarPilot key exists; show fingerprint; claim token; retrieve Gateway SSH host fingerprint; require explicit confirmation before writing a `Host farpilot-<host-slug>` block to a FarPilot-owned include file. Do not edit unrelated SSH config lines.

- [x] **Step 4: Implement devices and revoke**

List only metadata. Revoke asks for confirmation unless `--yes`, calls Gateway, rewrites `authorized_keys`, closes active channels, and prints the affected device fingerprint and Host grants.

- [x] **Step 5: Run CLI tests**

```bash
cargo test --manifest-path X-Workspace/FarPilot/Cargo.toml -p farpilot-cli --test cli
```

Expected: parsing, file atomicity, confirmation, and redaction tests pass.

---

### Task 11: Gateway and Windows deployment assets

**Files:**
- Create: `deploy/gateway/Caddyfile`
- Create: `deploy/gateway/farpilot-gateway.service`
- Create: `deploy/gateway/sshd_config.fragment`
- Create: `deploy/gateway/install.sh`
- Create: `deploy/windows/install.ps1`
- Create: `docs/stage0-runbook.md`
- Test: `tests/security/sshd_restrictions.sh`

- [x] **Step 1: Write deployment static checks**

Shell test verifies:

- Caddy exposes only HTTPS/WSS public application traffic;
- Gateway app binds loopback;
- systemd uses dedicated unprivileged user, `NoNewPrivileges=true`, `PrivateTmp=true`, and writable paths limited to FarPilot state;
- sshd Match block disables forwarding, X11, agent forwarding, and TTY-less arbitrary commands;
- Windows installer writes only under user-local app data and creates no firewall rule/listener.

- [x] **Step 2: Verify static checks fail**

Expected: missing deployment files.

- [x] **Step 3: Create Gateway service assets**

Caddy routes `/v1/*`, `/pair/*`, `/health/*`, and `/ws/host` to `127.0.0.1:8787`. systemd starts `farpilot gateway serve` with an environment file readable only by the service user. OpenSSH dedicated account uses the generated authorized-keys file and no password authentication.

- [x] **Step 4: Create Windows installer**

PowerShell verifies Authenticode/checksum, installs `farpilot.exe` under `%LOCALAPPDATA%\FarPilot\bin`, writes no machine-wide PATH entry, and optionally creates a current-user logon Scheduled Task running `farpilot host start`. Uninstall removes only FarPilot task/binary/config after explicit confirmation and preserves a revocation warning.

- [x] **Step 5: Write Stage 0 runbook**

Include DNS/TLS prerequisites, Azure NSG ports (22 and 443 only), Gateway installation, enrollment-token creation, DevBox setup, Mac pairing, Moshi manual key/profile flow, revocation drill, log locations, rollback, and verification that DevBox has no listening socket.

- [x] **Step 6: Run static checks**

```bash
bash X-Workspace/FarPilot/tests/workspace_layout.sh
bash X-Workspace/FarPilot/tests/security/sshd_restrictions.sh
shellcheck X-Workspace/FarPilot/deploy/gateway/install.sh
```

Expected: all checks pass.

---

### Task 12: End-to-end and security regression suite

**Files:**
- Create: `tests/e2e/gateway-host.sh`
- Create: `tests/e2e/README.md`
- Expand: crate integration tests

- [x] **Step 1: Build an in-process end-to-end fixture**

Fixture starts temporary SQLite Gateway, fake Host with fake PTY, enrolls Host, pairs device, opens attach, sends bytes/resize, disconnects, reconnects, and revokes device.

- [x] **Step 2: Add adversarial protocol cases**

Test malformed frames, duplicate channel IDs, unauthorized Host IDs, replayed Host proofs, expired tokens, token races, oversized input, slow consumers, Host takeover, and reconnect with stale channel frames.

- [x] **Step 3: Add log-redaction test**

Send a unique sentinel as terminal payload and pairing secret, capture structured logs, and assert neither sentinel appears while connection IDs/outcomes do.

- [x] **Step 4: Add resource cleanup assertions**

After every test, assert broker channel count is zero, Host task count returns to baseline, temporary PTY is closed, and SQLite transactions are complete.

- [x] **Step 5: Run full automated checks**

```bash
cargo fmt --manifest-path X-Workspace/FarPilot/Cargo.toml --all -- --check
cargo clippy --manifest-path X-Workspace/FarPilot/Cargo.toml --workspace --all-targets --all-features -- -D warnings
cargo nextest run --manifest-path X-Workspace/FarPilot/Cargo.toml --workspace
cargo test --manifest-path X-Workspace/FarPilot/Cargo.toml --doc --workspace
```

Expected: zero failures and zero warnings.

---

### Task 13: Real Stage 0 deployment and acceptance

**Files:**
- Update: `docs/stage0-runbook.md` with observed evidence only
- Create: `docs/stage0-acceptance.md`

- [ ] **Step 1: Deploy Gateway to Polly's Azure VM**

Follow the runbook. Do not reuse root or Polly's normal SSH account. Verify Caddy TLS, WSS upgrade, SQLite location, service sandbox, and dedicated restricted SSH user.

- [ ] **Step 2: Install Host on Windows DevBox**

Run setup as the ordinary `baoliwang` user. Verify no elevation prompt, no Windows service, no firewall rule, and no listening TCP socket. Confirm only outbound 443 reaches Gateway.

- [ ] **Step 3: Complete Mac acceptance**

Pair a dedicated Mac key, connect with saved SSH profile, verify Herdr alternate-screen rendering, CJK, colors, keyboard controls, resize, detach, and reconnect.

- [ ] **Step 4: Complete Moshi acceptance**

Create/select a Moshi key, pair through the HTTPS page, pin Gateway SSH fingerprint, save profile, connect, use narrow-screen Herdr, disconnect, change networks, and reconnect. Record whether Moshi offers a documented profile-import path; do not reverse engineer an undocumented format for MVP.

- [ ] **Step 5: Verify persistence and revocation**

Start a long Herdr agent task, disconnect all clients, wait, reconnect, and confirm continuation. Revoke the phone, confirm its active session closes and reconnection fails while Mac remains authorized.

- [ ] **Step 6: Verify security boundaries**

From Mac and Moshi attempt shell commands, SSH port forwarding, agent forwarding, and access to another ungranted Host. All attempts must fail. Inspect Gateway/Host logs for absence of terminal content and private material.

- [ ] **Step 7: Record acceptance evidence**

`docs/stage0-acceptance.md` contains date, component versions, commands executed, pass/fail for all nine specification criteria, observed limitations, and rollback status. No secrets, private hostnames, public IPs, tokens, or terminal content are recorded.

- [ ] **Step 8: Final verification checkpoint**

Run automated checks again, show `git status --short`, and compare implementation against every numbered requirement in the approved spec. Report any unmet criterion plainly; do not call the MVP complete while one remains.
