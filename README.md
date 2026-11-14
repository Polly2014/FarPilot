# FarPilot

> Pilot your agents from anywhere.

FarPilot securely connects standard SSH terminals to persistent Herdr sessions on outbound-only Windows hosts. A Linux Gateway accepts restricted SSH clients, while the Windows Host reaches it over outbound WSS 443 and exposes no inbound listener.

## Stage 0 status

The private Stage 0 deployment has passed its nine acceptance criteria on Windows, macOS, and iPhone. Protocol, Gateway, Host, pairing, revocation, restricted SSH attachment, deployment assets, and regression tests are implemented.

One-command installers and the verified release workflow are implemented on `main`, but the short installer endpoints and first stable GitHub Release are not live until a signed Release is published and the reviewed Nginx routes are deployed.

## Architecture

```text
Mac OpenSSH / iPhone Moshi
            |
            v
   FarPilot Gateway on Linux
            ^
            | outbound WSS 443
            |
   FarPilot Host on Windows 11
            |
          Herdr
```

## One-command installation

### macOS or Linux CLI

Latest stable release:

```bash
curl -fsSL https://farpilot.polly.wang/install.sh | sh
```

Pinned version or deliberate downgrade:

```bash
curl -fsSL https://farpilot.polly.wang/install.sh \
  | sh -s -- --version v0.1.1
```

Preview without changing managed files:

```bash
curl -fsSL https://farpilot.polly.wang/install.sh \
  | sh -s -- --dry-run
```

The default destination is `~/.local/bin/farpilot`. Set `FARPILOT_INSTALL_DIR` to use another user-owned directory. The installer does not edit shell startup files; if needed, add:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

### Windows Host

Latest stable release, from a normal non-administrator PowerShell session:

```powershell
irm https://farpilot.polly.wang/install.ps1 | iex
```

Pinned version:

```powershell
$installer = irm https://farpilot.polly.wang/install.ps1
& ([scriptblock]::Create($installer)) -Version v0.1.1
```

Preview or skip startup-task creation:

```powershell
$installer = irm https://farpilot.polly.wang/install.ps1
& ([scriptblock]::Create($installer)) -DryRun
& ([scriptblock]::Create($installer)) -NoStartupTask
```

Windows releases are installed under `%LOCALAPPDATA%\FarPilot\releases`; managed `current` and `bin` junctions activate a verified version without overwriting a running executable.

### Ubuntu Gateway

First install on supported Ubuntu:

```bash
curl -fsSL https://farpilot.polly.wang/install.sh \
  | sudo sh -s -- gateway --domain farpilot.example.com --email operator@example.com
```

Subsequent explicit upgrade:

```bash
curl -fsSL https://farpilot.polly.wang/install.sh \
  | sudo sh -s -- gateway
```

Gateway dry run:

```bash
curl -fsSL https://farpilot.polly.wang/install.sh \
  | sudo sh -s -- gateway --dry-run
```

Gateway mode supports Ubuntu 20.04, 22.04, and 24.04 on x86_64 or aarch64. It preserves the environment file, SQLite database, `authorized_keys`, SSH host keys, and certificates. Failed readiness checks restore the previous binary and configuration.

## Supported direct-install targets

| Role | Platforms |
|---|---|
| CLI | macOS Intel/Apple silicon; Linux x86_64/aarch64 |
| Host | Windows 11 x86_64; Windows ARM64 through x86_64 emulation |
| Gateway | Ubuntu 20.04/22.04/24.04 x86_64/aarch64 |

Updates are explicit and user-initiated. FarPilot does not perform background automatic updates.

## Verification and trust

Every direct installer requires the release manifest's SHA-256 digest and verifies the staged binary version before activation. Windows also enforces Authenticode policy when a signature is present. SHA-256 protects against corruption or a mismatched asset; it does not protect against simultaneous compromise of the release host and manifest.

Read [Installer security](docs/installer-security.md) for the trust boundary, rollback guarantees, and inspect-before-execute commands.

## Security and project policies

SignPath readiness is in progress. FarPilot is preparing for public open-source review and SignPath Foundation code signing. The repository has not yet been accepted by SignPath, no certificate is active, and no signed stable Windows release has been published.

- [Code signing policy](docs/code-signing-policy.md)
- [Privacy policy](docs/privacy-policy.md)
- [Security](SECURITY.md)
- Uninstall readiness: planned; current role-specific removal guidance remains in the Stage 0 runbook until the dedicated uninstall task lands.

FarPilot currently has one maintainer. Signing-related source, workflow, and release changes remain subject to automated security gates and explicit manual approval.

## Operations and design

- [Stage 0 runbook](docs/stage0-runbook.md)
- [Stage 0 acceptance](docs/stage0-acceptance.md)
- [Approved MVP specification](docs/specs/2026-11-11-farpilot-mvp-design.md)
- [One-command install design](docs/specs/2026-11-13-farpilot-one-command-install-design.md)
- [One-command install implementation plan](docs/plans/2026-11-13-farpilot-one-command-install-implementation.md)

## Security boundary

The DevBox exposes no inbound listener. The dedicated Gateway SSH account can attach an explicitly authorized device to Herdr, but cannot provide an arbitrary shell, forwarding, or remote command execution. Terminal contents, prompts, repository data, private keys, and pairing tokens are excluded from logs.

## License

Licensed under [Apache-2.0](LICENSE).
