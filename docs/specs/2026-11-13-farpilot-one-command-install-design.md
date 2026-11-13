# FarPilot One-Command Install Design

**Status:** Approved design; implementation not started

**Date:** 2026-11-13

## 1. Product decision

FarPilot will publish stable, versioned binaries through GitHub Releases and expose short installation entry points under `https://farpilot.polly.wang`.

The primary user experience is:

```bash
curl -fsSL https://farpilot.polly.wang/install.sh | sh
```

for macOS and ordinary Linux CLI installs, and:

```powershell
irm https://farpilot.polly.wang/install.ps1 | iex
```

for the Windows Host.

A full Linux Gateway deployment uses the same shell entry point with an explicit role:

```bash
curl -fsSL https://farpilot.polly.wang/install.sh \
  | sudo sh -s -- gateway \
      --domain farpilot.example.com \
      --email operator@example.com
```

GitHub Releases remain the binary source of truth. The `farpilot.polly.wang` endpoints are stable bootstrap URLs, not a second artifact store.

The design follows the strongest relevant patterns in Herdr's direct installer: a public latest-release manifest, POSIX shell portability, OS and architecture detection, mandatory SHA-256 verification, bounded downloads, temporary staging, and versioned Windows release directories. FarPilot retains separate behavior for CLI, Host, and Gateway roles instead of copying Herdr's single-role assumptions.

## 2. Goals

1. Eliminate manual GitHub ZIP downloads for Windows Host, macOS CLI, and Linux Gateway installation and upgrades.
2. Make the latest stable release installable with one short command.
3. Support installing or downgrading to a specific stable version.
4. Keep upgrades explicit and user-initiated; no background automatic update is added.
5. Require SHA-256 verification before any downloaded binary is activated.
6. Preserve Host identity, client keys, Gateway configuration, SQLite data, certificates, and `authorized_keys` across upgrades.
7. Roll back automatically when activation or Gateway health verification fails.
8. Keep Windows installation user-scoped and elevation-free.
9. Keep full Gateway deployment idempotent and safe to rerun.

## 3. Non-goals

The first release will not provide:

- background automatic updates;
- an in-process `farpilot update` command;
- Homebrew, Winget, Scoop, APT, Nix, or mise packages;
- preview/nightly release channels;
- mandatory Authenticode enforcement before a commercial certificate is available;
- Cosign or GitHub Artifact Attestation enforcement;
- automatic DNS record creation;
- destructive uninstallation or data deletion.

Package-manager distribution and signed artifact attestations may be added later without changing the release manifest or asset naming conventions defined here.

## 4. User journeys

### 4.1 macOS or Linux CLI latest stable install

```bash
curl -fsSL https://farpilot.polly.wang/install.sh | sh
```

The installer detects the platform, selects the matching asset from `latest.json`, verifies its digest and reported version, then atomically installs `farpilot` under `~/.local/bin` by default.

### 4.2 macOS or Linux CLI pinned version

```bash
curl -fsSL https://farpilot.polly.wang/install.sh \
  | sh -s -- --version v0.1.1
```

The installer accepts `v0.1.1` or `0.1.1`, normalizes it to the tag `v0.1.1`, and fetches that release's immutable `manifest.json`.

### 4.3 Windows Host latest stable install

```powershell
irm https://farpilot.polly.wang/install.ps1 | iex
```

The installer uses only the current Windows user profile, installs a versioned release, adds the managed active release to the user PATH, and creates the current-user `FarPilot Host` logon task by default.

### 4.4 Windows Host pinned version

```powershell
$installer = irm https://farpilot.polly.wang/install.ps1
& ([scriptblock]::Create($installer)) -Version v0.1.1
```

`-NoStartupTask` disables startup-task creation on a fresh install. An existing task is preserved unless explicitly disabled.

### 4.5 Linux Gateway first install

```bash
curl -fsSL https://farpilot.polly.wang/install.sh \
  | sudo sh -s -- gateway \
      --domain farpilot.example.com \
      --email operator@example.com
```

The first install provisions the dedicated account, binary, state directories, environment file, systemd service, restricted sshd configuration, Nginx site, and TLS certificate. It validates every generated configuration before enabling the service.

### 4.6 Linux Gateway upgrade

```bash
curl -fsSL https://farpilot.polly.wang/install.sh \
  | sudo sh -s -- gateway
```

An existing installation obtains its domain and service configuration from `/etc/farpilot/gateway.env` and the managed deployment files. It upgrades only managed program and deployment assets and preserves all mutable state.

### 4.7 Dry run

All installers support a no-mutation preview:

```bash
curl -fsSL https://farpilot.polly.wang/install.sh | sh -s -- --dry-run
```

```powershell
$installer = irm https://farpilot.polly.wang/install.ps1
& ([scriptblock]::Create($installer)) -DryRun
```

Gateway mode accepts `--dry-run` after the `gateway` role.

## 5. Release architecture

### 5.1 Stable release assets

Each stable GitHub Release contains:

```text
farpilot-linux-x86_64
farpilot-linux-aarch64
farpilot-macos-x86_64
farpilot-macos-aarch64
farpilot-windows-x86_64.exe
manifest.json
install.sh
install.ps1
install-gateway.sh
```

The release workflow may package Windows support files in a ZIP later. If the Windows asset format changes, `manifest.json` declares the format explicitly so the installer does not infer unsafe extraction behavior from a filename alone.

### 5.2 Release manifest

`manifest.json` is generated from built artifacts, never handwritten. Its minimum schema is:

```json
{
  "schema_version": 1,
  "version": "0.1.1",
  "tag": "v0.1.1",
  "assets": {
    "linux-x86_64": {
      "url": "https://github.com/Polly2014/FarPilot/releases/download/v0.1.1/farpilot-linux-x86_64",
      "sha256": "64 lowercase hexadecimal characters",
      "format": "binary"
    },
    "linux-aarch64": {
      "url": "https://github.com/Polly2014/FarPilot/releases/download/v0.1.1/farpilot-linux-aarch64",
      "sha256": "64 lowercase hexadecimal characters",
      "format": "binary"
    },
    "macos-x86_64": {
      "url": "https://github.com/Polly2014/FarPilot/releases/download/v0.1.1/farpilot-macos-x86_64",
      "sha256": "64 lowercase hexadecimal characters",
      "format": "binary"
    },
    "macos-aarch64": {
      "url": "https://github.com/Polly2014/FarPilot/releases/download/v0.1.1/farpilot-macos-aarch64",
      "sha256": "64 lowercase hexadecimal characters",
      "format": "binary"
    },
    "windows-x86_64": {
      "url": "https://github.com/Polly2014/FarPilot/releases/download/v0.1.1/farpilot-windows-x86_64.exe",
      "sha256": "64 lowercase hexadecimal characters",
      "format": "exe"
    }
  },
  "installers": {
    "gateway": {
      "url": "https://github.com/Polly2014/FarPilot/releases/download/v0.1.1/install-gateway.sh",
      "sha256": "64 lowercase hexadecimal characters"
    }
  }
}
```

Installers reject unknown schema versions, missing required fields, malformed hashes, non-HTTPS URLs, unsupported formats, and a mismatch between the requested tag, manifest version, and installed binary version.

### 5.3 Stable bootstrap endpoints

The public Gateway Nginx configuration exposes exact-match redirects:

```text
/install.sh  -> GitHub latest release install.sh
/install.ps1 -> GitHub latest release install.ps1
/latest.json -> GitHub latest release manifest.json
```

The redirect target is GitHub's `/releases/latest/download/<asset>` endpoint. GitHub selects only a published, non-draft, non-prerelease release as latest. `curl -L` and `Invoke-WebRequest` follow the redirects.

These routes are static and require no release-time SSH upload to the Azure VM. They must not shadow `/pair`, `/v1`, `/health`, or `/ws/host`.

### 5.4 Release workflow

A new `.github/workflows/release.yml` runs only for tags matching `v*` and uses least-privilege `contents: write` permission only in the publishing job.

The workflow:

1. verifies that the tag version matches the workspace package version;
2. runs formatting, Clippy, workspace tests, documentation tests, deployment checks, and OpenSSH security integration;
3. builds all declared target binaries;
4. runs `farpilot --version` for native build targets;
5. computes SHA-256 from the exact files to publish;
6. generates and validates `manifest.json`;
7. attaches the binaries, manifest, and installer scripts to one stable GitHub Release;
8. fails without publishing if any required asset or check is missing.

A release is immutable by policy. Correcting a bad release requires a new patch version rather than replacing an already published binary under the same tag.

## 6. Unix CLI installer

`install.sh` is POSIX `sh`, not Bash. It uses `set -eu` and avoids `eval`.

### 6.1 Platform detection

Supported mappings are:

| `uname -s` | `uname -m` | Target |
|---|---|---|
| `Darwin` | `arm64` or `aarch64` | `macos-aarch64` |
| `Darwin` | `x86_64` or `amd64` | `macos-x86_64` |
| `Linux` | `aarch64` or `arm64` | `linux-aarch64` |
| `Linux` | `x86_64` or `amd64` | `linux-x86_64` |

Android and every unrecognized OS or architecture fail with a clear error before downloading an asset.

### 6.2 Download and verification

The script requires `curl` plus one of `sha256sum`, `shasum`, or `openssl`. Downloads use bounded retries, connection timeout, and total timeout. A unique temporary directory is removed through a trap.

The sequence is:

1. fetch the latest or pinned manifest;
2. validate schema, version, URL, format, and digest syntax;
3. download the selected asset into the temporary directory;
4. verify SHA-256;
5. mark the staged binary executable;
6. run the staged binary with `--version` and compare it with the manifest;
7. atomically activate it in the install directory.

### 6.3 Install location and PATH

The default is:

```text
${FARPILOT_INSTALL_DIR:-$HOME/.local/bin}/farpilot
```

The installer creates the directory but does not edit shell startup files. If the directory is absent from PATH, it prints the exact export command the user should add. This mirrors Herdr's non-invasive Unix behavior.

### 6.4 Upgrade and rollback

The old binary is renamed to a temporary backup in the same filesystem before activation. If activation or post-install `--version` verification fails, the old binary is restored. The backup is deleted only after successful verification.

Running the same command with the already installed version is idempotent and reports that no replacement is needed.

## 7. Windows Host installer

### 7.1 Layout

Windows uses versioned release directories to avoid overwriting a running executable:

```text
%LOCALAPPDATA%\FarPilot\
├── releases\
│   ├── 0.1.1-x86_64-pc-windows-msvc\
│   └── 0.1.2-x86_64-pc-windows-msvc\
├── current  -> releases\0.1.2-x86_64-pc-windows-msvc\
├── bin      -> releases\0.1.2-x86_64-pc-windows-msvc\
├── install.lock
├── host-identity.json
└── host-config.json
```

`current` and `bin` are installer-owned directory junctions. The installer refuses to replace a regular file, a nonempty unmanaged directory, or a junction whose target is outside the managed releases directory.

### 7.2 Installation and activation

The PowerShell installer:

1. accepts latest or `-Version` manifest selection;
2. downloads to a unique staging directory;
3. validates SHA-256;
4. validates Authenticode when a signature is present and rejects an explicitly invalid signature;
5. runs staged `farpilot.exe --version`;
6. moves the complete staging directory into the versioned releases directory;
7. atomically retargets the managed junctions;
8. adds the active versioned release directory to the current-user PATH;
9. broadcasts the Windows environment change;
10. retains the current release plus the two most recent prior releases.

An unsigned Stage 0 binary is accepted only when its required SHA-256 matches. Once the project declares commercial signing mandatory, the policy becomes a manifest field and old installers fail closed for releases that require a signature.

### 7.3 Running Host process

The versioned layout makes download and activation independent of a running old EXE. To run the new release immediately, the installer:

- stops the managed `FarPilot Host` Scheduled Task if it is running;
- stops only `farpilot.exe` processes whose executable path is inside the installer-owned FarPilot releases directory;
- retargets `bin` and `current`;
- restores or creates the current-user startup task according to the selected option;
- starts the task when it was running before the upgrade.

No unrelated process named `farpilot.exe` outside the managed root is terminated.

### 7.4 Concurrency and migration

An exclusive `install.lock` serializes installation attempts. The first versioned installer recognizes the legacy `%LOCALAPPDATA%\FarPilot\bin\farpilot.exe` layout, migrates only the known managed binary, and refuses to replace unexpected user files.

Host identity and configuration files remain outside release directories and are never migrated, logged, or removed by an upgrade.

## 8. Linux Gateway installer

### 8.1 Role dispatch

When `install.sh` receives `gateway` as its first positional argument, it fetches `install-gateway.sh` from the same selected manifest, verifies its SHA-256, then executes it with the remaining arguments. The ordinary CLI path never performs privileged Gateway actions.

### 8.2 First install

Full Gateway provisioning supports Ubuntu 20.04, 22.04, and 24.04 on x86_64 or aarch64. On another Linux distribution, the ordinary CLI installer remains available, but `gateway` mode exits before mutation with manual deployment guidance.

First installation requires:

- root privileges;
- `--domain` with a validated DNS hostname;
- `--email` for noninteractive Certbot registration;
- existing DNS that resolves to the Gateway;
- `apt-get`; the installer uses it only for missing Nginx, OpenSSH Server, Certbot, and required system utilities.

It then:

1. creates the restricted `farpilot` account;
2. installs the verified binary at `/usr/local/bin/farpilot`;
3. creates `/var/lib/farpilot`, `/run/farpilot`, and `/etc/farpilot` with restrictive ownership and modes;
4. computes the local Ed25519 SSH host fingerprint;
5. writes `/etc/farpilot/gateway.env` only if it does not exist, including `FARPILOT_PUBLIC_SSH_HOST`, `FARPILOT_PUBLIC_SSH_PORT`, `FARPILOT_SSH_HOST_FINGERPRINT`, `FARPILOT_DATABASE_URL`, and `FARPILOT_CERTBOT_EMAIL`;
6. renders systemd, sshd, and Nginx assets from validated parameters;
7. validates `sshd -t`, `nginx -t`, and the systemd unit;
8. obtains or reuses the TLS certificate;
9. enables and starts the Gateway;
10. verifies `/health/live` and `/health/ready` over HTTPS.

### 8.3 Upgrade

On upgrade, domain and email are read from existing managed state. The installer never overwrites:

- `/etc/farpilot/gateway.env`;
- `/var/lib/farpilot/farpilot.db`;
- `/var/lib/farpilot/authorized_keys`;
- SSH host keys;
- Let's Encrypt accounts or certificates.

Managed deployment templates may be updated only after local backups are created and syntax validation succeeds.

The binary upgrade sequence is:

1. download and verify the new binary;
2. copy the current binary to a rollback path;
3. atomically install the new binary;
4. restart the service;
5. check systemd active state, liveness, and readiness;
6. restore the old binary and restart if any check fails.

Rollback failure is reported prominently and never hidden by the original error.

## 9. Security model

### 9.1 Trust boundary

The Stage 0 direct-install trust boundary is:

- HTTPS for `farpilot.polly.wang`;
- GitHub Release hosting;
- the release manifest;
- SHA-256 verification in the installer.

SHA-256 detects download corruption and mismatch but does not defend against simultaneous compromise of the hosting account and manifest. Cosign or GitHub Artifact Attestation is a planned strengthening, not represented as a property of the first implementation.

### 9.2 Required controls

- Download URLs must be absolute HTTPS URLs.
- SHA-256 is mandatory and has no bypass flag.
- Manifest strings are data and are never evaluated as shell or PowerShell code.
- Version, target, hostname, email, and path inputs use strict allowlists.
- Archive extraction, if introduced, rejects absolute paths, traversal, links, and unexpected files.
- Installer logs exclude Host identities, private keys, pairing tokens, database contents, and environment-file values.
- Temporary files use unique private directories and are removed on success and failure.
- Managed-file replacement checks ownership boundaries before changing an existing path.
- Windows installation remains current-user scoped.
- Gateway privilege is isolated to the explicit `gateway` role.
- `--dry-run` performs no filesystem, service, package, certificate, or network mutation beyond fetching public installer metadata when necessary.

## 10. Failure handling

| Failure | Required result |
|---|---|
| Unsupported OS or architecture | Exit before artifact download |
| Manifest unavailable | Retry within bounds, then exit without mutation |
| Invalid manifest or URL | Exit without artifact execution |
| Checksum mismatch | Delete staged artifact and preserve current install |
| Staged binary version mismatch | Preserve current install |
| Concurrent installer | Wait with a bounded message or fail clearly; never interleave activation |
| Windows junction activation failure | Leave previous junction target active |
| PATH update failure | Keep installed binary and print its absolute path plus repair steps |
| Gateway config validation failure | Restore managed config backup; do not reload service |
| Gateway health failure | Restore prior binary and restart prior service |
| Rollback failure | Return nonzero and report both original and rollback errors |

No failure path deletes user identity, authorization, database, or certificate state.

## 11. Testing strategy

### 11.1 Installer unit and static tests

Tests cover:

- OS and architecture normalization;
- latest and pinned-version manifest selection;
- tag/version normalization;
- schema and field validation;
- HTTPS-only URL enforcement;
- digest syntax and mismatch behavior;
- download timeout and retry behavior;
- temporary-directory cleanup;
- install-directory overrides;
- dry-run no-mutation guarantees;
- PATH-present and PATH-missing output;
- concurrent-install locking;
- idempotent reinstall of the current version.

Shell scripts pass `shellcheck`. PowerShell scripts pass PSScriptAnalyzer. Test fixtures use synthetic public URLs, keys, hostnames, and digests only.

### 11.2 Windows tests

Windows CI uses local-package injection so installer behavior is tested without executing an untrusted network response. Tests cover:

- legacy-layout migration;
- staging verification;
- junction ownership checks;
- active release switching;
- running managed process restart;
- refusal to kill an unmanaged same-name process;
- startup-task creation and preservation;
- current-user PATH idempotence;
- old-release retention;
- failed activation preserving the old release.

### 11.3 Unix tests

macOS and Linux CI install into temporary directories and cover:

- native target selection;
- executable permissions;
- atomic replacement;
- backup restoration;
- missing PATH guidance;
- pinned-version install and downgrade.

### 11.4 Gateway tests

Static and disposable Ubuntu integration tests cover:

- first-install permissions;
- repeated install without state loss;
- systemd, sshd, and Nginx validation;
- exact bootstrap redirects;
- certificate-command construction with a fake Certbot boundary;
- database and `authorized_keys` preservation;
- binary rollback after simulated readiness failure;
- restricted SSH account invariants after upgrade.

Real Stage 0 acceptance verifies the live domain, Certbot flow, Azure service restart, and an existing paired Mac/phone after Gateway upgrade.

### 11.5 Release smoke tests

Before announcing a release:

- Windows x86_64 fresh install and running-Host upgrade succeed;
- macOS Apple Silicon fresh and pinned-version installs succeed;
- macOS Intel artifact passes build and installer fixture checks;
- Linux x86_64 Gateway first install, upgrade, and rollback succeed;
- Linux aarch64 artifact passes build and installer fixture checks;
- every installed target reports exactly the manifest version.

## 12. Acceptance criteria

The feature is complete when all of the following are demonstrated:

1. `curl -fsSL https://farpilot.polly.wang/install.sh | sh` installs the latest stable FarPilot CLI on supported macOS and Linux systems without a manual GitHub download.
2. `irm https://farpilot.polly.wang/install.ps1 | iex` installs the latest stable Windows Host without elevation.
3. Both installers support an explicit stable version and a deliberate downgrade.
4. A checksum mismatch prevents activation on every platform.
5. Re-running the command upgrades or reports an idempotent current install.
6. A running Windows Host is moved to the new release without attempting to overwrite its active EXE.
7. The Gateway command performs a complete first install and a parameter-free subsequent upgrade.
8. Gateway upgrade preserves the database, environment configuration, `authorized_keys`, SSH keys, and certificates.
9. Gateway health failure restores the previous binary and service.
10. `--dry-run` produces no managed-state mutation.
11. The short bootstrap endpoints do not interfere with pairing, health, API, or Host WebSocket routes.
12. Documentation includes the short commands, pinned versions, Gateway role, PATH guidance, trust boundary, and manual rollback instructions.
