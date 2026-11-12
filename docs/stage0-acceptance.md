# FarPilot Stage 0 Acceptance

**Status:** Stage 0 mobile path operational; persistence, revocation, and Mac acceptance remain pending

Record only sanitized evidence. Do not include public IPs, private hostnames, tokens, keys, terminal content, or company data.

| Criterion | Result | Sanitized evidence |
|---|---|---|
| Windows Host runs without elevation | Pass | Setup and Host ran from the normal Windows user PowerShell session |
| Host uses outbound WSS 443 only | Partial | Azure observed the authenticated WSS channel; DevBox listener audit remains pending |
| Mac saved SSH profile opens Herdr | Pending | |
| Moshi saved SSH profile opens Herdr | Pass | Real iPhone SSH session rendered the DevBox Herdr TUI through the restricted Gateway account |
| UTF-8, ANSI, keyboard and resize work | Partial | Native Windows CI passed UTF-8/ANSI/resize; real Moshi screen rendered ANSI TUI, interactive input/resize remain to record |
| Agents continue after all clients disconnect | Pending | |
| Revocation closes phone and blocks reconnect | Pending | |
| Gateway account denies shell and forwarding | Pass | Disposable OpenSSH integration rejects arbitrary commands and local/remote forwarding while permitting only PTY Attach |
| Logs exclude terminal data and private material | Partial | Automated schema/redaction checks pass; deployed log inspection remains pending |

## Component versions

- Gateway FarPilot: `0.1.0`, deployed from `f468d32`
- Windows FarPilot: `0.1.0`
- Gateway OS: Ubuntu 20.04 x86_64
- Windows version: Windows 11 x86_64
- Herdr version: 0.9.5
- Moshi version: pending

## Rollback result

Pending.
