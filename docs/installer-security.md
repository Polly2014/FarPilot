# FarPilot Installer Security

## Scope and trust boundary

The direct installers trust two HTTPS origins:

1. `farpilot.polly.wang` for the stable bootstrap script and latest-manifest redirect;
2. GitHub Release hosting for immutable versioned manifests and release assets.

The release manifest names one asset per supported target and includes its mandatory SHA-256 digest. The installer refuses non-HTTPS URLs, malformed manifests, unsupported targets, missing or duplicate fields, checksum mismatches, and staged binaries that report a different version.

SHA-256 detects corruption and a binary that does not match the selected manifest. It does **not** protect against simultaneous compromise of both the GitHub Release asset and its manifest, or compromise of the bootstrap origin. GitHub Artifact Attestation or Cosign verification is a future strengthening, not a property claimed by the initial release.

## Platform boundaries

### macOS and Linux CLI

The CLI installer defaults to `~/.local/bin`, does not require root, and does not edit shell startup files. It stages and verifies the binary before an atomic replacement. A bounded installer-owned lock serializes activation, and a failed post-install verification restores the prior binary.

### Windows Host

The Windows installer is current-user scoped. Releases live under `%LOCALAPPDATA%\FarPilot\releases`; installer-owned `current` and `bin` junctions activate a verified version. Existing junctions, release directories, process paths, PATH entries, and Scheduled Tasks must remain inside installer-owned boundaries.

SHA-256 is mandatory. An unsigned Stage 0 binary is accepted only when its required digest matches. If Authenticode is present, the installer accepts `Valid` and rejects invalid signature states. A later release may declare signatures mandatory.

Host identity and configuration remain outside release directories and are never deleted during an upgrade. Default `-Uninstall` also preserves them; only `-Uninstall -PurgeState` after exact typed confirmation removes known identity/configuration files. Uninstall preflights managed trees, quarantines removals transactionally, and refuses external or reparse-point paths.

### Linux Gateway

Only the explicit `gateway` role crosses the root boundary. The standalone Gateway installer supports a fixed Ubuntu and package allowlist, validates all parameters, preflights every managed path, and refuses symlinks or nonregular files where managed state is expected.

The installer preserves:

- `/etc/farpilot/gateway.env`;
- `/var/lib/farpilot/farpilot.db`;
- `/var/lib/farpilot/authorized_keys`;
- SSH host keys;
- Certbot accounts and certificates.

Managed systemd, sshd, and Nginx changes remain in one restoration transaction through binary activation, service restart, and HTTPS liveness/readiness checks. A failed upgrade restores the prior configuration and binary. Rollback errors are reported alongside the original error.

## Managed data and logs

Installer output may include public versions, target names, domains, paths, and coarse operation results. It must not print:

- private keys or Host identity material;
- pairing or enrollment tokens;
- SSH public-key bodies;
- environment-file contents;
- SQLite contents;
- terminal payloads, prompts, or repository data.

Temporary files use private unique directories. Cleanup and rollback refuse to follow links outside managed roots.

## Release and update policy

Direct installs use the latest stable GitHub Release by default. A pinned version is explicit, and a downgrade receives the same checksum and version verification as an upgrade. Updates are manual and user-initiated; FarPilot does not silently replace itself in the background.

A published release is immutable by policy. A broken release is corrected with a new patch version, not by replacing assets under an existing tag.

## Inspect before executing

The short pipe commands are convenient, but an operator can download and inspect the installer first.

### POSIX shell

```bash
curl -fsSLo install.sh https://farpilot.polly.wang/install.sh
less install.sh
sh install.sh
```

Pinned version:

```bash
sh install.sh --version v0.1.1
```

Gateway:

```bash
sudo sh install.sh gateway --domain farpilot.example.com --email operator@example.com
```

### PowerShell

```powershell
irm https://farpilot.polly.wang/install.ps1 -OutFile install.ps1
Get-Content .\install.ps1
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

Pinned version:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Version v0.1.1
```

## Incident response

If a manifest digest, binary version, path ownership, configuration validation, signature policy, or health check fails:

1. do not bypass the check;
2. preserve the previous working installation;
3. record only sanitized error output;
4. inspect the GitHub Release and workflow run;
5. revoke or rotate credentials only when compromise is suspected;
6. publish a new patch release after review rather than mutating an existing release.
