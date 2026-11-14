# Uninstall FarPilot

FarPilot uninstall is deliberately conservative. Revoke remote access first, remove only installer-owned program state, and preserve identities, SSH material, Gateway databases, and certificates unless you explicitly decide to purge them.

## Before uninstalling

1. Identify the Host, client device, or Gateway being removed.
2. Revoke affected devices and grants on the Gateway.
3. Confirm an independent administrative access path remains available.
4. Back up state before any optional purge.
5. Never paste secrets, private keys, pairing tokens, database contents, or environment-file values into support logs.

## Windows Host

Run from a normal, non-administrator PowerShell session. Download and inspect the installer before using its uninstall mode:

```powershell
irm https://farpilot.polly.wang/install.ps1 -OutFile install.ps1
Get-Content .\install.ps1
```

### Preview

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall -DryRun
```

Dry run shows the managed task, process, PATH, junction, release, and state actions without changing them.

### Default uninstall

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall
```

Default uninstall removes only installer-owned executable state:

- the managed `FarPilot Host` Scheduled Task;
- FarPilot processes whose executable path is under the managed release root;
- FarPilot-owned current-user PATH entries;
- installer-owned `current` and visible `bin` junctions;
- versioned release, staging, backup, lock, and install-state files;
- empty installer-owned program directories.

It preserves by default:

- `%LOCALAPPDATA%\FarPilot\host-identity.json`;
- `%LOCALAPPDATA%\FarPilot\host.json`;
- the exact supported legacy `%LOCALAPPDATA%\FarPilot\host-config.json` when present;
- unknown user-created files;
- unrelated tasks, processes, PATH entries, directories, junctions, and files.

SSH keys and profiles are preserved by default. The uninstall output lists retained FarPilot state and reminds you to revoke Gateway authorization.

The operation is idempotent: running default uninstall again is safe.

### Legacy custom install directory

Current installations persist their visible-bin path and discover it automatically. A pre-metadata installation created with a custom `-InstallDir` and `-NoStartupTask` may need an explicit recovery hint:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall -InstallDir 'C:\Tools\FarPilot'
```

The hint is accepted only when the path is a validated installer-owned junction into the managed FarPilot release root. External, regular, malformed, or unrelated paths are rejected before mutation.

Do not pass `-InstallDir` when managed install metadata or the managed Scheduled Task already identifies the visible-bin path.

### Purge identity and configuration

Only after backing up or intentionally abandoning the Host identity, run:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall -PurgeState
```

The installer requires the exact interactive confirmation:

```text
PURGE FARPILOT STATE
```

Confirmed purge removes only the exact known identity/configuration filenames after the normal uninstall transaction succeeds. Unknown files remain and are reported for manual review.

If sensitive-state cleanup cannot complete, the command exits nonzero, prints `purge incomplete`, and reports protected quarantine paths. It does not claim successful purge while identity material remains.

There is no public flag or environment variable that bypasses the typed confirmation.

### Failure behavior

Before mutation, the installer validates all managed aliases, release trees, staging/backup trees, reparse points, process paths, task state, PATH state, and install metadata.

Managed filesystem removal is staged through same-volume quarantine. If a pre-commit operation fails, quarantined files, task state, and PATH state are restored. Post-commit cleanup failure keeps safe quarantine paths and reports them instead of following links or deleting outside managed roots.

When uninstall fails, read the reported remaining managed paths and resolve the specific lock, permission, antivirus, or path-ownership issue before retrying. Do not manually delete broad `%LOCALAPPDATA%` trees.

## macOS and Linux CLI

### Locate the managed binary

```bash
command -v farpilot
```

The default installer path is:

```bash
$HOME/.local/bin/farpilot
```

If you used `FARPILOT_INSTALL_DIR`, inspect that exact directory instead.

### Remove the default binary

```bash
rm "$HOME/.local/bin/farpilot"
```

For a custom directory, replace the path with the exact reviewed managed binary path and keep it quoted. Do not remove the containing directory unless you verified it contains no unrelated files.

### Review pairing material

The Mac pairing flow can create these exact paths:

```text
~/.ssh/farpilot_ed25519
~/.ssh/farpilot_ed25519.pub
~/.ssh/farpilot_known_hosts
~/.ssh/farpilot_config
```

SSH keys and profiles are preserved by default. Before deleting anything, inspect only the exact FarPilot paths without printing key contents:

```bash
test ! -e "$HOME/.ssh/farpilot_ed25519" || ls -ld -- "$HOME/.ssh/farpilot_ed25519"
test ! -e "$HOME/.ssh/farpilot_ed25519.pub" || ls -ld -- "$HOME/.ssh/farpilot_ed25519.pub"
test ! -e "$HOME/.ssh/farpilot_known_hosts" || ls -ld -- "$HOME/.ssh/farpilot_known_hosts"
test ! -e "$HOME/.ssh/farpilot_config" || ls -ld -- "$HOME/.ssh/farpilot_config"
```

The pairing flow can also add this exact include line to `~/.ssh/config`. Inspect the reference without displaying any private-key body:

```bash
grep -F 'farpilot_config' "$HOME/.ssh/config"
```

The stored Include line normally contains an expanded absolute home path. Review only the matching line and confirm it references the exact FarPilot profile before editing the file.

After revoking the device on the Gateway, backing up any material you intend to retain, and confirming each path above is the expected FarPilot regular file, optional exact removal is:

```bash
rm -- "$HOME/.ssh/farpilot_ed25519"
rm -- "$HOME/.ssh/farpilot_ed25519.pub"
rm -- "$HOME/.ssh/farpilot_known_hosts"
rm -- "$HOME/.ssh/farpilot_config"
```

Remove only the matching FarPilot Include line from `~/.ssh/config` with a reviewed editor or a separately backed-up exact-line edit. Never use an unquoted wildcard or broad deletion command under `~/.ssh`.

## Linux Gateway

Gateway removal requires root privileges and an independent administrative connection. Replace `<domain>` with the reviewed managed Gateway domain.

### 1. Revoke access

List and revoke all active devices before stopping the Gateway:

```bash
sudo -u farpilot env \
  FARPILOT_DATABASE_URL=sqlite:///var/lib/farpilot/farpilot.db \
  /usr/local/bin/farpilot devices
```

Use the reviewed device IDs with the existing revoke command and confirm that active sessions close.

### 2. Stop and disable the service

```bash
sudo systemctl stop farpilot-gateway.service
sudo systemctl disable farpilot-gateway.service
```

### 3. Remove exact managed deployment files

After backing them up for inspection:

```bash
sudo rm /etc/systemd/system/farpilot-gateway.service
sudo rm /etc/ssh/sshd_config.d/90-farpilot.conf
sudo rm "/etc/nginx/sites-enabled/<domain>"
sudo rm "/etc/nginx/sites-available/<domain>"
```

Do not substitute a wildcard for `<domain>`. Verify every path is the FarPilot-managed regular file or symlink before removal.

### 4. Validate and reload infrastructure

```bash
sudo sshd -t
sudo nginx -t
sudo systemctl daemon-reload
sudo systemctl reload sshd
sudo systemctl reload nginx
```

Use the service names appropriate to the reviewed Ubuntu installation if they differ. Do not reload after a failed syntax check.

### 5. Remove the binary

```bash
sudo rm /usr/local/bin/farpilot
```

### Preserved Gateway state

Gateway environment, database, authorized keys, SSH host keys, and certificates are preserved by default.

Specifically, do not delete these during normal uninstall:

```text
/etc/farpilot/gateway.env
/var/lib/farpilot/farpilot.db
/var/lib/farpilot/authorized_keys
/etc/ssh/ssh_host_* keys
/etc/letsencrypt accounts and certificates
```

Do not run `userdel -r farpilot` during normal uninstall because the service account's home/state can contain preserved Gateway data.

If you later choose to delete Gateway state, first create and verify an offline backup, inspect every exact path, and obtain explicit operator confirmation. Remove state and the dedicated account/group only as a separate destructive operation.

There is intentionally no remote one-line uninstall or purge command for the Gateway.
