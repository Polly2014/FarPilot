# FarPilot Stage 0 Runbook

## Prerequisites

- A private Azure VM with DNS pointing to it.
- Azure NSG allows inbound TCP 22 and 443 only.
- Nginx, Certbot, and OpenSSH Server are installed on the VM.
- Native Windows 11 DevBox can make outbound WSS connections on TCP 443.
- Herdr is installed in the DevBox user's `PATH`.

Never place real IPs, tokens, private keys, or company data in this repository.

## One-command installer status

The installer implementation and verified release workflow are complete, but the public short commands remain pending until both of these operator actions finish:

1. publish the first stable GitHub Release with all nine required assets;
2. deploy and reload the reviewed Nginx bootstrap routes.

Do not present the short endpoints as live before completing and verifying those actions.

FarPilot never performs background automatic updates. Re-running an installer is an explicit install, upgrade, or downgrade action.

### CLI install, version pin, and dry run

```bash
# Latest stable macOS/Linux CLI
curl -fsSL https://farpilot.polly.wang/install.sh | sh

# Pin or deliberately downgrade
curl -fsSL https://farpilot.polly.wang/install.sh \
  | sh -s -- --version v0.1.1

# Inspect the plan without managed-state mutation
curl -fsSL https://farpilot.polly.wang/install.sh \
  | sh -s -- --dry-run
```

The default CLI path is `~/.local/bin/farpilot`. The installer does not edit shell profiles. If the command is not found after installation, add:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

### Gateway first install, upgrade, and dry run

```bash
# First install
curl -fsSL https://farpilot.polly.wang/install.sh \
  | sudo sh -s -- gateway --domain farpilot.example.com --email operator@example.com

# Explicit upgrade using existing managed domain/email state
curl -fsSL https://farpilot.polly.wang/install.sh \
  | sudo sh -s -- gateway

# Preview only
curl -fsSL https://farpilot.polly.wang/install.sh \
  | sudo sh -s -- gateway --dry-run
```

A failed service, liveness, or readiness check restores the prior binary and managed configuration. Verify the restored service and both health endpoints before retrying.

## Gateway

1. Confirm DNS resolves to the intended Ubuntu Gateway and ports 22/443 are the only required inbound application ports.
2. Run the first-install command above with the reviewed domain and Certbot email.
3. Confirm `/etc/farpilot/gateway.env` is mode 0600 and references the expected public host, SSH fingerprint, and SQLite path without printing secret values.
4. Run `sshd -t`, `nginx -t`, and `systemctl is-active farpilot-gateway.service`.
5. Verify `/health/live` and `/health/ready` over HTTPS.
6. Create a five-minute enrollment code against the deployed database with `sudo -u farpilot env FARPILOT_DATABASE_URL=sqlite:///var/lib/farpilot/farpilot.db /usr/local/bin/farpilot gateway enrollment create`.

### Gateway rollback

The installer automatically restores its previous binary and managed configuration when restart, liveness, or readiness fails. For manual recovery after an interrupted operator action:

```bash
sudo systemctl stop farpilot-gateway.service
sudo install -m 0755 /var/lib/farpilot/farpilot.rollback /usr/local/bin/farpilot
sudo sshd -t
sudo nginx -t
sudo systemctl daemon-reload
sudo systemctl restart farpilot-gateway.service
curl -fsS https://farpilot.example.com/health/live
curl -fsS https://farpilot.example.com/health/ready
```

Use the actual reviewed domain in the health commands. Never delete or overwrite SQLite, `authorized_keys`, SSH host keys, `/etc/farpilot/gateway.env`, or certificate state during rollback. If no rollback binary exists, restore the retained reviewed package rather than downloading an unpinned asset.

### Bootstrap installer endpoints

Before announcing the first one-command release, deploy the reviewed Nginx site containing the exact `/install.sh`, `/install.ps1`, and `/latest.json` locations, run `nginx -t`, and reload Nginx. Do not advertise these commands until a stable GitHub Release contains all three assets.

Verify the three redirects without following them:

```bash
curl -fsSI https://farpilot.polly.wang/install.sh \
  | grep -Fi 'location: https://github.com/Polly2014/FarPilot/releases/latest/download/install.sh'
curl -fsSI https://farpilot.polly.wang/install.ps1 \
  | grep -Fi 'location: https://github.com/Polly2014/FarPilot/releases/latest/download/install.ps1'
curl -fsSI https://farpilot.polly.wang/latest.json \
  | grep -Fi 'location: https://github.com/Polly2014/FarPilot/releases/latest/download/manifest.json'
```

After the first stable Release exists, follow the manifest redirect and validate its minimum schema:

```bash
curl -fsSL https://farpilot.polly.wang/latest.json \
  | python3 -c 'import json,sys; value=json.load(sys.stdin); assert value["schema_version"] == 1; assert value["version"]; assert value["assets"]'
```

Re-run the existing `/pair`, `/v1`, `/health`, and `/ws/host` checks after reloading Nginx; the exact installer locations must not change those routes.

## Windows DevBox

1. Open a normal non-administrator PowerShell session.
2. Run `irm https://farpilot.polly.wang/install.ps1 | iex` after the endpoint and first stable Release are verified. Use the pinned-version command from README when reproducing or rolling back a deployment.
3. Confirm the managed layout exists under `%LOCALAPPDATA%\FarPilot\releases` and that `%LOCALAPPDATA%\FarPilot\current` and `bin` point to the selected complete release.
4. Run `farpilot host setup --gateway https://<gateway-domain> --enrollment-code <code> --name "Company DevBox"`.
5. Confirm the printed pairing URL belongs to the expected Gateway domain.
6. Confirm the current-user `FarPilot Host` task uses limited run level and points to `bin\farpilot.exe host start`.
7. Verify `Get-NetTCPConnection -State Listen` shows no FarPilot listener.
8. Verify outbound connection targets only the configured Gateway on 443.

### Windows rollback and PATH troubleshooting

Install a previously reviewed version explicitly; the versioned installer retargets the managed junctions without overwriting Host identity or configuration:

```powershell
$installer = irm https://farpilot.polly.wang/install.ps1
& ([scriptblock]::Create($installer)) -Version v0.1.1
```

Open a new PowerShell window after PATH changes. Diagnose command resolution with:

```powershell
Get-Command farpilot -All
[Environment]::GetEnvironmentVariable('Path', 'User')
```

Do not remove `%LOCALAPPDATA%\FarPilot\host-identity.json` or `host-config.json` during binary rollback. Identity removal is a separate destructive action that requires re-enrollment.

## Mac pairing

1. Run `farpilot pair <pairing-url>`.
2. Compare the displayed SSH fingerprint with the Gateway operator's fingerprint.
3. Confirm profile creation only after the fingerprint matches.
4. Connect with `ssh farpilot-<host-id>`.

## Moshi pairing

1. Open the HTTPS pairing page from the QR code.
2. Generate/select an Ed25519 key in Moshi.
3. Paste only its public key into the page.
4. Create an SSH profile using Gateway hostname, port, user `farpilot`, and pinned fingerprint.
5. Connect; Gateway must open Herdr, not a Linux shell.

## Revocation drill

1. Run `sudo -u farpilot env FARPILOT_DATABASE_URL=sqlite:///var/lib/farpilot/farpilot.db /usr/local/bin/farpilot devices` on Gateway and verify the device fingerprint.
2. Run `sudo -u farpilot env FARPILOT_DATABASE_URL=sqlite:///var/lib/farpilot/farpilot.db /usr/local/bin/farpilot revoke <device-id> --yes`.
3. Confirm the active phone session closes and reconnection fails.
4. Confirm an independently authorized Mac still connects.

## Logs

- Gateway: `journalctl -u farpilot-gateway`.
- Nginx: `/var/log/nginx/farpilot.polly.wang.*.log`.
- Host: `%LOCALAPPDATA%\FarPilot` status/config only.

Logs must not contain terminal payloads, prompts, repository content, private keys, or raw pairing tokens.
