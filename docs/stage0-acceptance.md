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

## CRT pairing page acceptance

This section records the server-rendered CRT pairing-page work separately from the original nine Stage 0 criteria and installer acceptance. No live pairing token, real Host metadata, SSH fingerprint, or public key was generated or recorded for this local verification.

### Automated evidence

| Check | Result | Sanitized evidence |
|---|---|---|
| Pairing-page renderer and state contracts | Pass | Fourteen renderer tests cover token inventory, escaping, per-response CSP nonce, generic error states, CRT/accessibility markers, countdown/state-machine contracts, visible network errors, safe success rendering, and prototype-safe API error mapping |
| Pairing browser route integration | Pass | Eight HTTP tests cover valid themed pages, hostile metadata escaping, nonce/security headers, generic invalid/expired/consumed pages, rate limiting, internal/fallback pages, and unchanged JSON Claim behavior |
| Full Rust workspace regression | Pass | Eighty-three workspace tests pass; Rust formatting, Clippy with warnings denied, and documentation tests pass |
| Existing installer/security regressions | Pass | Release tooling, POSIX and Gateway installers, deployment assets, SSH restrictions, E2E harness, release workflow structure, and shell syntax checks pass |
| External-resource static contract | Pass | Compiled template tests reject external scripts, stylesheets, fonts, images, iframes, prefetches, absolute HTTP(S) resources, and dangerous DOM sinks |
| Live Gateway deployment | Pending | CRT page has not been deployed to the public Gateway |

### Sanitized browser visual checklist

The approved preview fixture is `Example DevBox`, `gateway.example.com:22`, a synthetic SHA256 value, a five-minute synthetic expiry, and `/v1/pair/synthetic-token/claim`. No committed production debug route exists. On 2026-11-14, the coordinator rendered that fixture through a temporary uncommitted harness and inspected it with headless Chromium and Playwright. Screenshots were stored only in job-scoped temporary storage and were not committed.

| Visual check | Result | Sanitized observation |
|---|---|---|
| 320 px viewport | Pass | No horizontal scrolling; the long synthetic Host and submit control remained reachable |
| 390 px and desktop | Pass | The focused single-card hierarchy and CRT bezel remained intact at 390×844 and 1280×900; desktop shell stayed at or below 560 px |
| Long synthetic Host | Pass | Full synthetic text was present and wrapped without status or metadata overlap |
| Full synthetic fingerprint | Pass | Full synthetic value was present, wrapped without truncation, and its element had no horizontal overflow |
| Focus and touch target | Pass | Empty submission showed visible `INVALID DEVICE NAME`, focused the name field, and the submit control measured at least 44 px high |
| Countdown display | Pass | Ready state populated the `AUTH WINDOW` countdown from the synthetic expiry |
| Natural `00:00` transition | Pending | The rendered Expired state was inspected, but a real-time five-minute countdown-to-zero transition was not observed end to end |
| Interactive states | Pass | Ready, synthetic pending `AUTHORIZING...`, field error, visible Network error, intercepted synthetic Success, Expired, Invalid, RateLimited, and InternalError headings rendered coherently |
| Success data minimization | Pass | Synthetic `201` displayed `PAIRING COMPLETE`, `SESSION SEALED`, and allowlisted connection details; `device_id` and `host_id` were not shown |
| Reduced motion | Pass | Reduced-motion context disabled the default animation duration and constrained iteration to one |
| Browser network log | Pass | Request observers covered Ready, long-value 320 px, desktop, field error, pending Submitting, Success, Network Error, Expired, Invalid, RateLimited, InternalError, and reduced-motion states; no external or subresource requests occurred, and only the synthetic same-origin Claim request appeared during Success submission |
| Browser console | Pass | Console observers covered Ready, long-value 320 px, desktop, field error, pending Submitting, Success, Network Error, Expired, Invalid, RateLimited, InternalError, and reduced-motion states; every observed state produced zero console errors |
| CRT readability and layout | Pass | Ready, long-value, Success, and Expired screenshots were manually inspected and accepted for CRT style, readability, and layout |
| Keyboard tab order and semantic labels | Pending | Automated DOM contracts pass, but this was not manually traversed in the browser acceptance run |
| iPhone Safari software keyboard | Pending | Chromium viewport testing does not prove that the iPhone Safari software keyboard leaves the submit control reachable |
| Live deployed QR/Moshi flow | Pending | Requires an approved Gateway deployment and a separately authorized real-device pairing session |

Do not promote the remaining Pending rows from source inspection, Chromium viewport checks, or automated static contracts alone. Real public-device acceptance requires an approved deployment and must still use sanitized evidence.
