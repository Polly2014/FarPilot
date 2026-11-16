# FarPilot Stage 0.5 Live Acceptance Design

**Status:** Approved design; implementation not started

**Date:** 2026-11-16

## 1. Product decision

FarPilot will pause code-signing work and complete a bounded **Stage 0.5 Live Acceptance** milestone before adding product features or pursuing community growth.

The milestone has one purpose: convert every important self-use path that is not blocked by code signing from automated or synthetic evidence into sanitized evidence from Polly's real Windows DevBox, Azure Gateway, Mac, and iPhone.

The work runs in two separately authorized maintenance windows:

1. **Window A — Live Pairing:** deploy the reviewed CRT pairing page and close the remaining real-browser, QR, Moshi, revocation, and log-redaction checks.
2. **Window B — Installer and Rollback:** exercise production installers through loopback-only HTTPS harnesses, complete a fresh Mac install, perform a real Gateway upgrade, and prove automatic rollback with a controlled failing candidate.

Authorization for Window A does not authorize Window B.

## 2. Goals

Stage 0.5 must demonstrate:

1. the CRT pairing page is deployed on the live Gateway without breaking existing Host or Mac access;
2. a real five-minute pairing token naturally reaches `00:00` and becomes unusable;
3. desktop keyboard order and semantic labels work in a real browser;
4. the iPhone Safari software keyboard does not hide or strand the submit control;
5. a real QR-to-Safari-to-Moshi flow enters the same Herdr workspace;
6. revoking the Moshi device terminates its active session and blocks reconnect;
7. re-pairing the device restores access with a new device key;
8. a fresh Mac CLI install succeeds through a controlled HTTPS manifest without activating public stable endpoints;
9. a real Gateway candidate upgrades successfully while preserving required state;
10. a controlled candidate that reports the expected version but cannot start the Gateway triggers automatic rollback;
11. the previous Gateway binary and service recover after rollback;
12. no real token, key body, terminal content, private hostname, IP address, or private log is committed or pasted into a chat transcript.

## 3. Non-goals

Stage 0.5 will not:

- resume SignPath Foundation integration;
- purchase a signing subscription;
- publish a signed or unsigned stable Release;
- activate `/install.sh`, `/install.ps1`, or `/latest.json` public bootstrap routes;
- create a public preview Release;
- add multi-Host UX, notifications, a Web dashboard, file browsing, or Agent orchestration;
- change the terminal protocol or authorization model;
- optimize for stars, forks, or other community metrics;
- claim that controlled-preview installer evidence is equivalent to a public stable install.

`First stable Release published`, `Public latest endpoints deployed`, and `Fresh Mac install from public endpoint` remain Pending because they depend on a future signed stable channel.

## 4. Safety and evidence boundaries

### 4.1 Public evidence

Tracked documents may contain only:

- source commit and sanitized component versions;
- Pass, Fail, or Pending status;
- viewport class and client type;
- aggregate test counts;
- whether state invariants held;
- whether rollback restored service;
- coarse timing when it contains no operationally sensitive detail.

### 4.2 Private temporary evidence

The following remain in mode-0600 or mode-0700 temporary storage and are deleted after the acceptance checkpoint:

- real domains, public or private IP addresses, and internal hostnames;
- pairing URLs, tokens, Host IDs, device IDs, SSH fingerprints, and public-key bodies;
- environment files and their values;
- database copies, row values, and raw SQL output;
- Nginx, journald, systemd, browser-console, and packet-level raw logs;
- temporary CA keys, server keys, certificates, manifests, candidates, and rollback copies not already part of managed deployment state.

Private evidence is summarized, not copied, into `docs/stage0-acceptance.md`.

### 4.3 State-integrity semantics

Byte-for-byte hashing is required only for state that should remain immutable during a window:

- Gateway environment file;
- SSH host private/public keys;
- TLS certificate and account material;
- Windows Host identity and Host configuration;
- managed Nginx and systemd files unless the window explicitly upgrades them.

The Gateway database and `authorized_keys` are intentionally mutable during pairing and revocation. They are verified by logical invariants instead:

- all pre-existing Hosts remain present;
- all pre-existing unrelated devices and grants remain present;
- only the explicitly paired, revoked, and re-paired Moshi records may change;
- `authorized_keys` matches the expected effective device grants after each operation;
- no duplicate active grant or orphaned active key remains;
- rollback does not revert or erase authorized state changes that completed before the upgrade window.

## 5. Automated preflight gate

Both maintenance windows require a fresh run from the exact reviewed source commit:

```text
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --all-features -- -D warnings
cargo nextest run --workspace (or the documented cargo test fallback)
cargo test --doc --workspace
release manifest and asset tests
POSIX, Windows, and Gateway installer tests
OpenSSH restricted-account integration
E2E harness
deployment and shell static checks
CRT renderer, HTTP, CSP, and browser synthetic acceptance
Release workflow dry run and exact asset-set validation
```

A warning or unavailable optional tool must be recorded with its documented fallback. A failing required check blocks the maintenance window.

The preflight report records the exact source SHA and tool versions but no private deployment values.

## 6. Window A — Live Pairing

### 6.1 Explicit authorization gate

Before Window A, Polly must explicitly authorize one live Gateway deployment and be available with:

- the Mac currently authorized for fallback access;
- the iPhone with Safari and Moshi;
- access to the Windows DevBox and its running FarPilot Host;
- the ability to stop the window if an organizational-policy concern appears.

### 6.2 Baseline and backup

Before mutation:

1. verify `/health/live` and `/health/ready`;
2. verify the existing Host is online;
3. attach from the existing Mac and detach cleanly;
4. record the deployed binary SHA and source provenance privately;
5. back up the current Gateway binary and every managed configuration file that might change;
6. back up the SQLite database and `authorized_keys` privately;
7. record immutable-state hashes and logical database/key invariants;
8. validate `sshd -t`, `nginx -t`, and the systemd unit;
9. verify the rollback binary can execute `--version`.

A missing backup, failed baseline, failed syntax check, or unavailable fallback Mac blocks deployment.

### 6.3 Deployment

Window A deploys only the reviewed Gateway binary containing the CRT pairing page. It does not activate public installer redirects.

The sequence is:

1. stage the candidate beside the managed binary;
2. verify candidate SHA and `--version`;
3. atomically replace the binary while retaining the rollback copy;
4. restart the service;
5. verify systemd active state, liveness, readiness, Host reconnect, and existing Mac attach;
6. proceed to real-device tests only after every baseline capability is restored.

If service, health, Host reconnect, or existing Mac attach fails, restore the prior binary and managed configuration immediately. Do not continue into browser testing.

### 6.4 Real-browser and real-device acceptance

Run these checks in order:

1. **Keyboard and semantics:** traverse the live Ready page by keyboard and verify labels, focus visibility, and submit behavior.
2. **Natural expiry:** create a real five-minute token, observe the countdown without clock manipulation, verify `00:00`, and verify the token cannot claim afterward.
3. **iPhone Safari:** open a fresh pairing URL, focus both fields, show the software keyboard, scroll and rotate as needed, and prove the submit control remains reachable.
4. **Real pairing:** create/select a Moshi Ed25519 device key, submit only its public key, confirm the success page exposes only allowlisted connection details, save the Moshi profile, and enter Herdr.
5. **Persistence:** disconnect Moshi and re-enter the same Herdr workspace while the Host remains online.
6. **Revocation:** revoke the Moshi device, prove the active session terminates, and prove reconnect fails.
7. **Recovery:** pair a new Moshi key and prove access returns.
8. **Mac regression:** reattach with the pre-existing Mac after the complete Moshi cycle.

### 6.5 Log and state review

After the device flow:

- inspect Nginx and journald privately for token, URL, public-key body, terminal payload, prompt, repository path, and environment-value leakage;
- compare immutable-state hashes;
- verify database and `authorized_keys` logical invariants;
- verify no external resource request occurred from the CRT page;
- delete browser screenshots or raw logs that contain real identifiers after sanitized conclusions are recorded.

A secret or private value in logs is a Fail, not a documentation issue. Rotate or invalidate the affected value before considering a retry.

### 6.6 Window A outcome

A service-level failure requires rollback. A browser-only UX failure may leave the healthy reviewed Gateway binary deployed, but the affected acceptance row remains Pending or Fail and Window A is not complete.

## 7. Window B — Installer and Rollback

### 7.1 Separate authorization gate

Window B requires a second explicit authorization because it includes:

- root-level Gateway mutation;
- one expected short service interruption;
- installation of a deliberately non-starting synthetic candidate to prove rollback.

Window A approval does not imply Window B approval.

### 7.2 Candidate provenance and versions

The successful Stage 0.5 candidate is built from a committed reviewed source SHA with workspace version `0.1.1`. It is not tagged or published as a GitHub Release.

The rollback-injection candidate is test-only version `0.1.2`. It must:

- be generated in private temporary storage;
- report `farpilot 0.1.2` for `--version`;
- fail immediately for Gateway service startup;
- implement no other command or capability;
- never be committed, tagged, uploaded, or retained after the test.

Using a higher test-only version ensures the installer cannot classify the rollback injection as an idempotent reinstall of `0.1.1`.

### 7.3 Loopback HTTPS harness

Mac and Gateway use separate temporary HTTPS harnesses bound only to `127.0.0.1`.

Each harness contains:

- an ephemeral self-signed test CA and server certificate with loopback SAN;
- one deterministic manifest;
- the exact candidate assets referenced by that manifest;
- a minimal static HTTPS server with request-body logging disabled;
- directory and key modes restrictive to the current user or root.

The installer receives:

```text
FARPILOT_MANIFEST_URL=https://127.0.0.1:<ephemeral-port>/manifest.json
CURL_CA_BUNDLE=<private-temporary-ca-certificate>
```

The production installer still exercises HTTPS, manifest parsing, SHA-256, staged `--version`, locking, atomic activation, readiness, and rollback. No public endpoint or permanent trust-store entry is created.

The harness, CA, keys, manifests, and candidates are removed after evidence is summarized.

### 7.4 Mac acceptance

Use an isolated temporary `HOME` and `FARPILOT_INSTALL_DIR` so the existing CLI remains untouched.

The sequence is:

1. run a fresh `0.1.1` install from the loopback manifest;
2. verify executable mode, SHA, and `farpilot --version`;
3. verify the PATH guidance without modifying shell startup files;
4. repeat the same install and verify idempotence;
5. in a separate isolated install directory, seed a valid prior binary and run a candidate that fails staged or post-activation verification;
6. prove the prior binary remains or is restored;
7. remove the isolated HOME, install directory, harness, and CA.

This is recorded as `Controlled preview fresh Mac install`, not `Fresh Mac install from public endpoint`.

### 7.5 Successful live Gateway upgrade

Before mutation, repeat the baseline, backup, immutable hash, and logical invariant checks from Window A.

Then:

1. start the root-private loopback HTTPS harness;
2. run the production Gateway installer against the `0.1.1` manifest;
3. verify binary version and SHA;
4. verify systemd active state, liveness, readiness, Host reconnect, existing Mac attach, and existing Moshi attach;
5. verify immutable-state hashes and database/key logical invariants;
6. retain the pre-upgrade binary until the injected rollback test is complete.

### 7.6 Injected rollback acceptance

Run the production Gateway installer against the test-only `0.1.2` manifest.

Expected behavior:

1. manifest, SHA, and staged `--version` checks pass;
2. the synthetic candidate is atomically installed;
3. systemd restart or readiness fails;
4. the installer restores `0.1.1` and restarts the service;
5. liveness and readiness recover;
6. Host, existing Mac, and existing Moshi reconnect;
7. immutable-state hashes and logical database/key invariants still hold;
8. the installer exits nonzero and reports both the original readiness failure and rollback result without exposing private values.

If rollback itself fails, stop immediately. Do not perform cleanup that would destroy diagnostic evidence until service recovery is explicitly controlled.

## 8. Failure handling

| Failure | Required result |
|---|---|
| Automated preflight failure | Do not open a maintenance window |
| Backup or baseline missing | Do not deploy |
| Syntax validation failure | Restore staged config; do not reload |
| Post-deploy health failure in Window A | Restore prior binary and configuration |
| Existing Host or Mac regression | Roll back before real-device testing |
| Browser UX failure with healthy service | Keep service only if safe; affected row remains Pending/Fail |
| Real token, key, or terminal data appears in logs | Fail, invalidate affected value, preserve private evidence, then clean |
| Successful upgrade changes immutable state | Fail and restore; do not treat service health as success |
| Pairing changes unrelated device/grant state | Fail and restore from private backup |
| Injected candidate unexpectedly remains active | Stop and restore `0.1.1` manually |
| Automatic rollback fails | Stop all later work and recover service before cleanup |
| Cleanup cannot prove test CA/key removal | Window remains incomplete |

## 9. Acceptance matrix updates

On success, `docs/stage0-acceptance.md` adds or updates sanitized rows for:

```text
Live Gateway CRT deployment
Natural five-minute countdown-to-zero transition
Manual keyboard order and semantic labels
iPhone Safari software-keyboard reachability
Live QR / Safari / Moshi flow
Live Moshi revocation and re-pair
Controlled preview fresh Mac install
Live Gateway upgrade
Injected health-failure automatic rollback
Post-upgrade and post-rollback state invariants
Private temporary evidence cleanup
```

These rows remain unchanged and Pending:

```text
First stable Release published
Public latest endpoints deployed
Fresh Mac install from public endpoint
Signed Windows stable release
```

`docs/stage0-runbook.md` documents the repeatable acceptance commands and stop conditions without including real deployment values.

## 10. Completion criteria

Stage 0.5 is complete only when:

1. every Window A real-device row passes;
2. controlled Mac fresh install, idempotence, and local rollback pass;
3. the live `0.1.1` Gateway upgrade passes;
4. the `0.1.2` injected failure automatically restores `0.1.1`;
5. the original Host, Mac, and Moshi work after successful upgrade and rollback;
6. immutable files remain byte-identical unless explicitly changed;
7. mutable database and `authorized_keys` state satisfy the defined logical invariants;
8. all private temporary harnesses, CAs, keys, candidates, backups not required for managed rollback, screenshots, and raw logs are removed;
9. tracked evidence is sanitized and contains no live identifiers;
10. stable/latest and code-signing claims remain blocked or Pending;
11. Polly explicitly confirms both maintenance-window outcomes.

Only after Stage 0.5 closes should FarPilot choose among Community Preview, multi-Host support, notifications, or a Web control surface.
