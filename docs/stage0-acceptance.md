# FarPilot Stage 0 Acceptance

**Status:** Pending real Azure VM, Windows DevBox, Mac, and Moshi validation

Record only sanitized evidence. Do not include public IPs, private hostnames, tokens, keys, terminal content, or company data.

| Criterion | Result | Sanitized evidence |
|---|---|---|
| Windows Host runs without elevation | Pending | |
| Host uses outbound WSS 443 only | Pending | |
| Mac saved SSH profile opens Herdr | Pending | |
| Moshi saved SSH profile opens Herdr | Pending | |
| UTF-8, ANSI, keyboard and resize work | Pending | GitHub Windows ConPTY CI covers the isolated PTY layer |
| Agents continue after all clients disconnect | Pending | |
| Revocation closes phone and blocks reconnect | Pending | |
| Gateway account denies shell and forwarding | Pending | OpenSSH integration CI covers disposable Linux sshd |
| Logs exclude terminal data and private material | Pending | Automated schema/redaction checks cover code paths |

## Component versions

- FarPilot commit: pending
- Gateway OS: pending
- Windows version: pending
- Herdr version: pending
- Moshi version: pending

## Rollback result

Pending.
