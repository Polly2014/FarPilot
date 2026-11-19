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

This section records the server-rendered CRT pairing-page work separately from the original nine Stage 0 criteria and installer acceptance. The 2026-11-14 synthetic browser run used no live pairing material. A separately authorized live Window A on 2026-11-18–19 exercised real tokens and devices, but only sanitized outcomes are recorded; no real URL, token, Host metadata, fingerprint, public-key body, device ID, terminal content, or raw log is committed.

### Automated evidence

| Check | Result | Sanitized evidence |
|---|---|---|
| Pairing-page renderer and state contracts | Pass | Fourteen renderer tests cover token inventory, escaping, per-response CSP nonce, generic error states, CRT/accessibility markers, countdown/state-machine contracts, visible network errors, safe success rendering, and prototype-safe API error mapping |
| Pairing browser route integration | Pass | Eight HTTP tests cover valid themed pages, hostile metadata escaping, nonce/security headers, generic invalid/expired/consumed pages, rate limiting, internal/fallback pages, and unchanged JSON Claim behavior |
| Full Rust workspace regression | Pass | Eighty-seven workspace tests pass after the Stage 0.5 safety regressions; Rust formatting, Clippy with warnings denied, and documentation tests pass |
| Existing installer/security regressions | Pass | Release tooling, POSIX and Gateway installers, deployment assets, SSH restrictions, E2E harness, release workflow structure, and shell syntax checks pass |
| External-resource static contract | Pass | Compiled template tests reject external scripts, stylesheets, fonts, images, iframes, prefetches, absolute HTTP(S) resources, and dangerous DOM sinks |
| Live Gateway deployment | Pass | The reviewed static Linux candidate from successful public CI run `43676588975` was deployed with an atomic same-filesystem replacement and a private rollback copy; service, liveness, readiness, Host reconnect, and existing Mac attach passed without rollback |

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
| Natural `00:00` transition | Pass | A real five-minute token naturally reached `00:00`; the page transitioned to `SESSION EXPIRED`, and a browser refresh kept the token invalid without restoring the form |
| Interactive states | Pass | Ready, synthetic pending `AUTHORIZING...`, field error, visible Network error, intercepted synthetic Success, Expired, Invalid, RateLimited, and InternalError headings rendered coherently |
| Success data minimization | Pass | Synthetic `201` displayed `PAIRING COMPLETE`, `SESSION SEALED`, and allowlisted connection details; `device_id` and `host_id` were not shown |
| Reduced motion | Pass | Reduced-motion context disabled the default animation duration and constrained iteration to one |
| Browser network log | Pass | Request observers covered Ready, long-value 320 px, desktop, field error, pending Submitting, Success, Network Error, Expired, Invalid, RateLimited, InternalError, and reduced-motion states; no external or subresource requests occurred, and only the synthetic same-origin Claim request appeared during Success submission |
| Browser console | Pass | Console observers covered Ready, long-value 320 px, desktop, field error, pending Submitting, Success, Network Error, Expired, Invalid, RateLimited, InternalError, and reduced-motion states; every observed state produced zero console errors |
| CRT readability and layout | Pass | Ready, long-value, Success, and Expired screenshots were manually inspected and accepted for CRT style, readability, and layout |
| Keyboard tab order and semantic labels | Pass | A live desktop browser traversed device name, SSH key, and authorization button in both directions; empty submission displayed `INVALID DEVICE NAME` and returned focus to the device-name field |
| iPhone Safari software keyboard | Pass | Real iPhone Safari kept the authorization control reachable with both fields focused, the software keyboard visible, and portrait/landscape rotation |
| Live deployed QR/Moshi flow | Pass with remediation note | A new Moshi Ed25519 key paired through live Safari, entered Herdr, detached, and reattached to the same workspace. The Host process required one manual restart during the multi-connection pairing sequence; a deterministic loopback integration regression now covers persistent Host reconnection, while Windows startup lifecycle remediation remains pending real-machine verification |
| Live Moshi revocation and re-pair | Pass | The active Moshi session terminated, the revoked key failed reconnect, a new key paired successfully, and first/repeat Herdr attachment passed |
| Window A state and log invariants | Pass with repaired operator incident | Existing Mac access, immutable configuration/SSH/TLS hashes, database invariants, and sanitized log scans passed. An operator command initially ran outside the documented `sudo -u farpilot` context and changed `authorized_keys` ownership; production state was restored, and new fail-closed database/owner tests prevent the same misuse |

Do not promote the remaining Pending rows from source inspection, Chromium viewport checks, or automated static contracts alone. Real public-device acceptance requires an approved deployment and must still use sanitized evidence.

## SignPath public-readiness acceptance

This section is separate from Stage 0 product acceptance. It records only sanitized evidence for the future public-repository and SignPath application gates.

| Check | Result | Sanitized evidence |
|---|---|---|
| Built-in tracked-tree/history audit | Pass after private disposition | Scanner covered the tracked tree and all reachable refs; all 6 high-severity and 27 review findings were privately classified as synthetic fixtures/examples, numeric-version false positives, or the intentional instruction symlink. Raw matches and paths are not committed |
| Complementary Gitleaks audit | Pass with reviewed false positive | Gitleaks 8.30.1 scanned all history with redaction and reported one synthetic private-key marker in the public SignPath implementation-plan prose; no key material or other finding was reported |
| Dependency/license audit | Pass with reviewed duplicate policy | cargo-deny advisories/licenses/sources/bans pass; `libsqlite3-sys` resolves to patched 0.39.1, wildcard path dependencies are versioned, non-OSI `webpki-roots` packages were removed, and remaining transitive duplicate major versions are reviewed warnings |
| Tracked-file review | Pass | 106 tracked entries, no regular file over 1 MiB, no submodule, and no Git LFS pointer candidate |
| Author identity review | Accepted | One historical email domain is present across 106 commits; Polly accepted public disclosure of the `qq.com` domain on 2026-11-15 |
| SignPath proprietary-component review | Pass for current graph | Cargo license/source policy passes and the exact release assembly contains no third-party executable artifact |
| SignPath malware/PUA behavior review | Pass for internal readiness | Production source and behavior were reviewed as an authorized self-hosted relay with explicit grants, fixed Herdr launch, restricted SSH ingress, removable user-visible startup, and no scanning/exploitation/evasion or project telemetry; SignPath retains final no-hacking-tools classification authority |
| Full local regression | Pass | Rust formatting, Clippy, workspace/doc tests, audit 17/17, release 20/20, installers, deployment, SSH restriction, E2E, workflow mutation, and shell syntax checks passed |
| Repository visibility change | Pass | External Gate A was explicitly approved; `Polly2014/FarPilot` is Public and anonymous source/policy access was verified on 2026-11-15 |
| Public repository security settings | Pass | Secret scanning, push protection, and Dependabot security updates are enabled |
| Public `main` CI | Pass | Run `43669176238` completed successfully across Windows, macOS, Ubuntu, OpenSSH security, formatting, lint, installer, audit, and dependency-policy jobs |
| `main` branch protection | Deferred by owner | Polly explicitly chose not to enable branch protection at this time; no protection is claimed |
| Unsigned application prerelease | Pass | External Gate B was explicitly approved; protected workflow run `43674439627` published prerelease [`v0.1.0-unsigned.1`](https://github.com/Polly2014/FarPilot/releases/tag/v0.1.0-unsigned.1) from commit `35d58c6cf0df06a91942f6996ee543794f1cbdca` with the exact three review assets, verified digest, and validated metadata; stable/latest remained inactive |
| SignPath application | Not approved at this time | External Gate C was completed manually on 2026-11-15. On 2026-11-16, FarPilot learned that the Foundation program required stronger external public-trust and visibility signals; reapplication was invited after broader recognition. No certificate or signing configuration was issued. |

External Gates A, B, and C are complete. Foundation signing remains blocked; the project may build external adoption and reapply later, evaluate a regular paid subscription, or investigate another authorized public-trust signing route.
