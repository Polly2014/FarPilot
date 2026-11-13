# FarPilot Stage 0 Acceptance

**Status:** Stage 0 acceptance complete; commercial Windows signing remains a pre-release requirement

Record only sanitized evidence. Do not include public IPs, private hostnames, tokens, keys, terminal content, or company data.

| Criterion | Result | Sanitized evidence |
|---|---|---|
| Windows Host runs without elevation | Pass | Setup and Host ran from the normal Windows user PowerShell session |
| Host uses outbound WSS 443 only | Pass | DevBox process audit showed no listening socket and one outbound established connection to remote port 443 |
| Mac saved SSH profile opens Herdr | Pass | Generated SSH key/profile opened the same DevBox Herdr workspace and detached cleanly through the restricted Gateway account |
| Moshi saved SSH profile opens Herdr | Pass | Real iPhone SSH session rendered the DevBox Herdr TUI through the restricted Gateway account |
| UTF-8, ANSI, keyboard and resize work | Pass | Native Windows CI passed UTF-8/ANSI/resize; real Mac and Moshi sessions rendered ANSI TUI and accepted Herdr detach input |
| Agents continue after all clients disconnect | Pass | Moshi disconnected and reattached to the same DevBox Herdr workspace while the Host remained online |
| Revocation closes phone and blocks reconnect | Pass | Revocation removed the phone key, terminated its active Attach process, blocked reconnect, and required a new Ed25519 key for restoration |
| Gateway account denies shell and forwarding | Pass | Disposable OpenSSH integration rejects arbitrary commands and local/remote forwarding while permitting only PTY Attach |
| Logs exclude terminal data and private material | Pass | Automated schema/redaction checks passed; deployed journald and Nginx logs contained no terminal payloads, private keys, or SSH public-key bodies |

## Component versions

- Gateway FarPilot: `0.1.0`, deployed from `098c55f`
- Windows FarPilot: `0.1.0`, built from `220936c`
- Gateway OS: Ubuntu 20.04 x86_64
- Windows version: Windows 11 x86_64
- Herdr version: 0.9.5
- Moshi version: pending

## Rollback result

A full binary rollback was not required. Gateway restart recovery, Host automatic reconnect, device revocation, key rotation, and independent Mac fallback were verified. The previous Gateway binary and pre-PTY `authorized_keys` backup were retained during deployment for manual rollback.

## One-command installer acceptance

This section is separate from the nine completed Stage 0 criteria above. It records only evidence gathered for the new installer/release path; it does not retroactively change the original results.

### Automated evidence

| Check | Result | Sanitized evidence |
|---|---|---|
| Release manifest generation/validation | Pass | Standard-library generator and validator regression suite passes 20 tests, including path, symlink, duplicate asset, URL, and digest adversarial cases |
| POSIX CLI install/upgrade/rollback | Pass | Offline target matrix, checksum, version, atomic activation, lock, rollback, dry-run, and Gateway-dispatch suite passes under POSIX shell fixtures |
| Windows RED/GREEN installer TDD | Pass | GitHub Actions run `43444142945` failed at the expected missing local-package/versioned behavior; later runs `43455934371` and `43457837177` passed Windows installer tests, PSScriptAnalyzer, and all platform/security jobs |
| Gateway provisioning/rollback fixtures | Pass | Isolated Ubuntu-root command-boundary suite covers package/account/config/TLS/service/health success and injected rollback failures without real system mutation |
| Bootstrap route and workflow structure | Pass | Exact Nginx route, workflow permission, five-target matrix, exact asset-set, and tag-only publication mutation checks pass |
| First stable Release published | Pending | No tag or GitHub Release has been created |
| Public latest endpoints deployed | Pending | Reviewed Nginx redirects exist in source but have not been reloaded on the live Gateway |
| Fresh Mac install from public endpoint | Pending | Requires the first stable Release and live bootstrap route |
| Live Gateway upgrade and health rollback | Pending | Requires a disposable/live Ubuntu maintenance window and operator approval |

Do not mark the pending rows Pass from a dry-run artifact alone. Before public announcement, run the Release workflow with `dry_run=true`, inspect and validate its exact nine-file artifact, then complete fresh-device and live Gateway acceptance with sanitized evidence.
