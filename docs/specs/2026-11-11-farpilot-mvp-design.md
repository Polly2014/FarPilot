# FarPilot MVP Design

**Status:** Architecture approved; written specification awaiting final review

**Date:** 2026-11-11

**Tagline:** *Pilot your agents from anywhere.*

## 1. Product decision

FarPilot is a secure connection layer between user-controlled terminals and persistent coding-agent sessions on machines that cannot accept inbound connections.

The first integration is Herdr on a native Windows 11 DevBox. FarPilot does not replace Herdr, build a new terminal emulator, or reproduce Orca's desktop/mobile suite. It reuses:

- Herdr for workspaces, panes, agent processes, and persistent sessions;
- macOS Terminal and OpenSSH for desktop access;
- Moshi and its SSH terminal for mobile access;
- a user-controlled Azure VM as the public rendezvous point.

The long-term abstraction is runtime-neutral: Herdr is the first adapter, not part of the FarPilot identity.

## 2. Goals

The MVP must let Polly:

1. Run Herdr and coding agents natively in PowerShell on a Windows 11 DevBox.
2. Reach that Herdr session from a Mac terminal through a public Azure VM.
3. Reach the same Herdr session from Moshi on iPhone.
4. Require no OpenSSH Server, public IP, VPN, Tailscale, or inbound firewall rule on the DevBox.
5. Keep Herdr panes and agents running when Mac or phone disconnects.
6. Pair and revoke each client device independently.
7. Prevent remote clients from obtaining an arbitrary PowerShell or Azure shell.
8. Operate first as a private single-user system and later as a self-hosted open-source tool without changing the Host protocol.

## 3. Non-goals

The MVP will not provide:

- a desktop GUI or native mobile app;
- a custom terminal emulator;
- file browsing, diff review, Git UI, or browser panes;
- arbitrary PowerShell command execution;
- a replacement for Herdr's session or agent model;
- Mosh or Eternal Terminal transport;
- multiple organizations, billing, or a public multi-tenant cloud;
- application-level end-to-end encryption beyond the user's self-hosted Gateway trust boundary;
- automatic Moshi profile import unless Moshi exposes a documented third-party import format.

## 4. Deployment stages

### Stage 0 — Polly private deployment

- Gateway: Polly's existing Azure VM.
- Host: Polly's company Windows 11 DevBox.
- Clients: Polly's MacBook and iPhone.
- Scope: one user, one Gateway, one primary DevBox, a small number of devices.
- Purpose: verify that FarPilot is useful in daily work before expanding scope.

### Stage 1 — Self-hosted open-source release

- Each user deploys FarPilot Gateway on a VM, VPS, NAS, or home server they control.
- Users install FarPilot Host on their own work machines.
- The same Host binary accepts a user-supplied Gateway URL.
- User terminal traffic remains inside infrastructure controlled by that user.

### Stage 2 — Optional hosted FarPilot Cloud

- FarPilot operates a public multi-tenant Gateway.
- Users install only FarPilot Host and pair clients.
- This stage requires a separate security, privacy, tenancy, abuse, availability, and billing design. It is not an incremental configuration switch for the MVP.

## 5. System architecture

```text
Mac Terminal                    iPhone Moshi
     | SSH                           | SSH
     +---------------+---------------+
                     v
              FarPilot Gateway
              - system OpenSSH
              - forced attach command
              - pairing API
              - host/device registry
              - WSS relay
              - revocation and audit
                     ^
                     | outbound WSS 443
                     |
          Windows 11 FarPilot Host
              - host identity
              - control/data channels
              - ConPTY bridge
              - fixed Herdr launcher
                     |
                   Herdr
              - server/session
              - panes/workspaces
              - coding agents
```

### 5.1 FarPilot Gateway

The Gateway runs on Linux and has five bounded responsibilities:

1. **SSH ingress:** accept standard SSH clients from Mac and Moshi.
2. **Pairing:** issue and consume short-lived, single-use enrollment tokens.
3. **Authorization:** map device public keys to allowed Host IDs.
4. **Relay:** connect an authorized SSH session to an online Host channel.
5. **Metadata:** persist hosts, devices, grants, revocations, and security audit events.

The Gateway does not run coding agents, persist terminal scrollback, inspect repositories, or provide a general shell.

The operating system OpenSSH daemon terminates client SSH. The dedicated `farpilot` account has no ordinary shell. Each authorized device key is restricted to a generated command equivalent to:

```text
farpilot gateway attach --device-id <opaque-id>
```

The attach command either opens the device's only permitted Host or presents a minimal text picker when the device has grants for multiple Hosts. It never evaluates user-provided shell syntax.

### 5.2 FarPilot Host

The Host is a native Windows user-space process. It:

- stores its identity under the current user's local application-data directory;
- establishes an outbound TLS WebSocket connection to the configured Gateway on port 443;
- authenticates by signing a Gateway challenge with its Host key;
- receives only typed terminal-session operations;
- starts a fixed Herdr executable under ConPTY;
- forwards terminal bytes and window-size changes;
- reports liveness and session exit status;
- rejects arbitrary executable paths, shell commands, and environment overrides.

The Host does not listen on a TCP port. It needs no administrator privileges or Windows service. Stage 0 starts it through a user-scoped Scheduled Task at logon; manual foreground startup remains the recovery path if policy blocks task creation.

### 5.3 Herdr adapter

The MVP adapter launches or attaches the default Herdr session. Each remote client becomes a normal Herdr TUI client connected to the DevBox-local Herdr server.

Herdr owns persistence. Disconnecting FarPilot closes only the remote TUI client; Herdr's server, panes, and coding-agent processes continue to run.

Named Herdr sessions, direct Socket API control, rich agent status, and non-interactive prompt injection are later adapter capabilities. They are not required for the terminal-first MVP.

## 6. User journeys

### 6.1 Gateway deployment

Stage 0 installs Gateway on Polly's Azure VM. Stage 1 packages the same service as a documented self-host deployment with:

- a dedicated Linux user;
- system OpenSSH configuration for the restricted `farpilot` account;
- HTTPS/WSS termination through Caddy or an equivalent reverse proxy;
- SQLite metadata storage;
- a system service and health endpoint.

### 6.2 DevBox enrollment

The user installs the signed Host binary and runs:

```powershell
farpilot host setup --gateway https://gateway.example.com
```

Setup performs the following:

1. Generate a Host key locally.
2. Register the Host public key with Gateway using a one-time operator enrollment code.
3. Assign a human-readable Host name.
4. Verify Gateway TLS identity and display the Gateway fingerprint/domain.
5. Establish the first outbound connection.
6. Offer to create the user-scoped startup task.
7. Print a client-pairing URL, short code, and QR code.

Host private keys never leave the DevBox.

### 6.3 Mac pairing and use

The Mac CLI flow is fully automatable:

```bash
farpilot pair <short-code>
ssh -t farpilot@gateway.example.com
```

`farpilot pair` generates a dedicated Ed25519 key if needed, submits only its public key, pins the Gateway SSH host key, and writes a named SSH profile after explicit confirmation.

A successful SSH login attaches to the permitted Herdr Host rather than an Azure shell.

### 6.4 Moshi pairing and use

Moshi is a standard SSH/Mosh/ET client and does not provide a generic session relay. In FarPilot it connects to the Gateway's SSH endpoint; Gateway bridges the terminal to the DevBox.

The reliable MVP flow is:

1. Scan FarPilot's QR code to open the Gateway pairing page.
2. In Moshi, create or select a device SSH key.
3. Copy the public key into the pairing page.
4. Confirm the Gateway host, username, SSH fingerprint, and target Host.
5. Save one Moshi SSH profile.
6. Connect and enter Herdr.

If Moshi later documents a third-party profile-import or pairing URL, FarPilot may add an **Open in Moshi** action. The MVP does not depend on undocumented QR formats.

## 7. Pairing and authorization

### 7.1 Pairing token

A pairing token is:

- 256 bits of cryptographic randomness;
- valid for five minutes;
- single-use;
- scoped to one Host;
- invalidated immediately after success or explicit cancellation;
- stored server-side only as a hash.

The QR contains the HTTPS pairing URL, public Host ID, expiry, and display metadata. It never contains an SSH private key, Host private key, Gateway administrator credential, or reusable bearer token.

### 7.2 Device identity

Each Mac or phone has an independent Ed25519 SSH key. Gateway stores:

- public key and fingerprint;
- opaque device ID;
- user-selected device name;
- Host grants;
- creation, last-use, and revocation timestamps.

Revocation removes the key's effective authorization immediately and terminates active sessions for that device.

## 8. Transport protocol

The Host maintains one authenticated WSS control connection. Terminal sessions are multiplexed by opaque channel IDs.

Required frame families are:

- `host_hello` / `host_proof` / `host_ready`;
- `session_open` / `session_opened` / `session_refused`;
- `terminal_data`;
- `terminal_resize`;
- `ping` / `pong`;
- `session_close` / `session_exited`;
- `protocol_error`.

Protocol properties:

- every frame has a version, channel ID where applicable, bounded payload length, and typed body;
- terminal bytes use binary frames and are never interpreted as JSON text;
- control frames use versioned structured encoding;
- bounded per-channel queues apply backpressure instead of unbounded buffering;
- an unknown frame type or oversized payload closes the affected connection;
- reconnecting the Host does not silently replay terminal input whose delivery is ambiguous.

The Gateway does not queue sessions while a Host is offline. Clients receive an immediate, explicit offline response.

## 9. Security model

### 9.1 Trust boundary

In Stage 0 and Stage 1, the user owns the Gateway. SSH terminates at Gateway and the Gateway process forwards terminal plaintext over a separate TLS-protected WSS connection. The self-hosted Gateway is therefore inside the trusted computing boundary.

Application-level end-to-end encryption that hides terminal content from a hosted Gateway is required before Stage 2 and is outside the MVP.

### 9.2 Required controls

- DevBox accepts outbound WSS only; no inbound listener is created.
- Gateway's `farpilot` SSH account has no general shell, port forwarding, agent forwarding, X11 forwarding, or arbitrary commands.
- Host launches only the configured Herdr binary and fixed adapter arguments.
- Device authorization is deny-by-default and Host-scoped.
- Pairing endpoints are rate-limited and use short-lived tokens.
- Host and device private keys remain local to their devices.
- Terminal payloads, prompts, repository contents, and environment values are excluded from application logs.
- Audit records contain identities, action type, timestamps, outcome, and coarse byte counts only.
- Gateway and Host reject unsupported protocol versions explicitly.
- Corporate policy approval remains a deployment prerequisite; user-space installation is not treated as permission to bypass policy.

## 10. Failure handling

### Host offline

Gateway refuses new sessions with a clear `host_offline` result. Existing SSH clients receive a human-readable message and nonzero exit status.

### Gateway unavailable

Host retries with exponential backoff and jitter, bounded between a short initial retry and a two-minute maximum. It keeps Herdr running and does not restart panes.

### Client network loss

The SSH session ends. Gateway closes the matching relay channel. Host closes only that ConPTY client; the Herdr background server and agent panes continue.

### Host reconnect

Gateway reauthenticates Host identity before advertising it online. Old channels are never attached to the new transport implicitly. Users reconnect their SSH clients.

### Slow client or backpressure

Each direction has a bounded queue. If a client cannot consume output within the configured budget, FarPilot closes that client channel rather than consuming unbounded memory or stalling other clients.

### Expired or reused pairing token

Gateway returns the same generic invalid-pairing response for expired, consumed, and unknown tokens. No Host existence information is leaked.

### Herdr missing or incompatible

Host returns a typed setup error and does not download or replace Herdr automatically. Installation and updates remain explicit operator actions.

## 11. Observability

Gateway exposes:

- process health and readiness;
- current Host and client connection counts;
- connection/reconnect/error counters;
- aggregate byte counts;
- pairing success/failure counts;
- structured security audit events.

Host exposes a local status command with Gateway reachability, authenticated state, active channel count, configured Herdr path, and last error. Neither component logs terminal content.

## 12. Technology choice

FarPilot is a Rust workspace so Host, Gateway, protocol types, CLI, and cross-platform utilities share one strongly typed codebase.

The all-Rust MVP is an explicit product decision. The native Windows Host needs reliable ConPTY lifecycle management, bounded WSS streams, low idle overhead, and single-binary distribution without requiring Python or Node.js on a managed DevBox. Keeping Gateway and Host in one language also lets both sides share protocol enums, limits, identities, and compatibility tests directly. Python would accelerate business API development but would add runtime/PyInstaller complexity on Windows; a Python control plane may be introduced only in Stage 2 if hosted-account, billing, or administration requirements justify a second stack. The terminal data plane and Windows Host remain Rust.

Planned binaries:

```text
farpilot
  host setup|start|status
  gateway serve|status
  pair
  connect
  devices
  revoke
```

Planned supporting technologies:

- Tokio for asynchronous runtime;
- a Rust WebSocket/TLS stack for outbound Host transport;
- Windows ConPTY bindings for the Host terminal adapter;
- system OpenSSH on Gateway for Mac/Moshi compatibility;
- SQLite for Gateway metadata;
- Caddy for public TLS in the self-hosted deployment.

Exact crate selection belongs in the implementation plan and must be validated against current Windows and OpenSSH behavior before code is written.

## 13. Testing strategy

### Unit tests

- token generation, expiry, hashing, and single-use semantics;
- device grants and revocation;
- frame encode/decode and size limits;
- channel state machine and ambiguous-delivery behavior;
- backoff and backpressure;
- command/argument allowlists;
- audit redaction.

### Integration tests

- Linux Gateway plus simulated Host and SSH client;
- Windows 11 Host plus real ConPTY and Herdr process;
- multiple simultaneous SSH clients attached to one Herdr server;
- Host disconnect/reconnect while Herdr agents continue;
- device revocation terminating an active connection;
- Gateway restart with SQLite state preserved;
- Unicode, CJK, colors, alternate screen, keyboard control sequences, and resize.

### Manual acceptance

- Mac Terminal can attach, detach, and reattach.
- Moshi can connect with a saved SSH profile and operate Herdr on a narrow screen.
- DevBox exposes no inbound listener.
- Azure login never yields an ordinary shell.
- A revoked phone cannot reconnect.
- Herdr panes continue after every client disconnects.

## 14. MVP acceptance criteria

The MVP is complete only when all of the following are demonstrated on the real devices:

1. FarPilot Host runs on the native Windows 11 DevBox without administrator privileges.
2. Host reaches Gateway using only outbound WSS on TCP 443.
3. Mac enters the DevBox's Herdr TUI through one saved SSH profile.
4. Moshi enters the same Herdr server through one saved SSH profile.
5. Terminal input, output, CJK text, colors, and resize work correctly.
6. Disconnecting all clients leaves Herdr agents running; reconnecting reattaches successfully.
7. Revoking the phone key prevents reconnection and terminates its active session.
8. The Gateway SSH account cannot execute arbitrary commands, open port forwards, or provide a shell.
9. No terminal contents or private keys appear in Gateway or Host logs.

## 15. Repository shape after spec approval

```text
X-Workspace/FarPilot/
├── CLAUDE.md
├── AGENTS.md -> CLAUDE.md
├── Cargo.toml
├── crates/
│   ├── farpilot-core/
│   ├── farpilot-gateway/
│   ├── farpilot-host/
│   └── farpilot-cli/
├── deploy/
│   ├── gateway/
│   └── windows/
└── docs/
    └── specs/
        └── 2026-11-11-farpilot-mvp-design.md
```

Only this specification is created before final written-spec review. Project scaffolding, `CLAUDE.md`, the `AGENTS.md` symlink, Cargo workspace files, deployment files, and implementation wait until that review is approved.
