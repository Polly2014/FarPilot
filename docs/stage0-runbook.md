# FarPilot Stage 0 Runbook

## Prerequisites

- A private Azure VM with DNS pointing to it.
- Azure NSG allows inbound TCP 22 and 443 only.
- Nginx, Certbot, and OpenSSH Server are installed on the VM.
- Native Windows 11 DevBox can make outbound WSS connections on TCP 443.
- Herdr is installed in the DevBox user's `PATH`.

Never place real IPs, tokens, private keys, or company data in this repository.

## Gateway

1. Build the Linux `farpilot` binary from a reviewed commit.
2. Run `sudo deploy/gateway/install.sh target/release/farpilot`.
3. Set `FARPILOT_PUBLIC_SSH_HOST`, SSH fingerprint, and database URL in `/etc/farpilot/gateway.env`.
4. Install `deploy/gateway/farpilot.polly.wang.nginx` under `/etc/nginx/sites-available/` and enable it.
5. Run `sshd -t` and `nginx -t`, then use `certbot --nginx -d farpilot.polly.wang`.
6. Reload Nginx and enable `farpilot-gateway.service`.
7. Verify `/health/live` and `/health/ready` over HTTPS.
8. Create a five-minute enrollment code against the deployed database with `sudo -u farpilot env FARPILOT_DATABASE_URL=sqlite:///var/lib/farpilot/farpilot.db /usr/local/bin/farpilot gateway enrollment create`.

Rollback: stop FarPilot, restore previous binary/config, run `sshd -t`, then restart sshd and reload Nginx. Preserve SQLite and `authorized_keys` backups with mode 0600.

## Windows DevBox

1. Download the signed Windows artifact and published SHA256.
2. Run `deploy/windows/install.ps1` as the normal DevBox user; elevation is not required.
3. Run `farpilot host setup --gateway https://<gateway-domain> --enrollment-code <code> --name "Company DevBox"`.
4. Confirm the printed pairing URL belongs to the expected Gateway domain.
5. Optionally install the current-user startup task.
6. Verify `Get-NetTCPConnection -State Listen` shows no FarPilot listener.
7. Verify outbound connection targets only the configured Gateway on 443.

Rollback: revoke paired devices on Gateway, unregister the startup task, stop FarPilot, and remove `%LOCALAPPDATA%\FarPilot`. Identity removal requires re-enrollment.

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
