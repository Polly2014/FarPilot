# FarPilot Public Readiness Audit

**Status:** BLOCKED

**Repository visibility:** Private

**Built-in audit date/revision:** 2026-11-14 at `44422aea2c7a`

**Complementary tool follow-up:** 2026-11-15 at `1a8ff413bd10`

This committed file records only sanitized counts and dispositions. Raw scanner output, matching values, private paths, identity documents, and credentials remain outside the repository in mode-0600 private job storage.

## Required checks

| Check | Status | Sanitized result |
|---|---|---|
| Current tracked tree scanner | Reviewed | One tracked nonregular-path finding was confirmed as the intentional `AGENTS.md` instruction symlink |
| Full reachable Git history scanner | Review incomplete | Built-in scanner found 6 high-severity and 26 review findings. Obvious high-severity examples in test/plan prose were privately classified as synthetic; FarPilot identifiers, internal-hostname patterns, and private-address patterns still require private per-finding disposition |
| Gitleaks 8.30.1 | Completed; reviewed false positive | Redacted full-history scan returned one `private-key` rule finding. It was privately confirmed as the intentionally synthetic marker in `docs/plans/2026-11-14-farpilot-signpath-readiness-implementation.md`, not key material. No other Gitleaks findings were reported |
| FarPilot-specific prohibited-data review | BLOCKED pending private disposition | Review categories remain: 11 FarPilot identifiers, 3 internal-hostname patterns, and 12 private-address patterns in reachable history |
| Tracked large/generated-file review | Pass | 105 tracked entries; zero regular files over 1 MiB; largest tracked regular file was 75,432 bytes; no Git LFS pointer or submodule entry detected |
| Commit author/email review | USER CONFIRMATION REQUIRED | 94 commits use one email domain (`qq.com`). Polly must confirm that publishing this domain through Git history is acceptable |
| Cargo metadata review | Preliminary pass | 305 packages, zero missing license expressions, 26 unique license expressions |
| cargo-deny 0.20.2 | BLOCKED | Completed with 21 errors: 15 duplicate-version diagnostics, 3 wildcard dependency groups, 2 rejected `CDLA-Permissive-2.0` license diagnostics in `webpki-roots` dependency versions, and 1 vulnerability |
| Vulnerability gate | BLOCKED | `RUSTSEC-2026-0459` / `CVE-2026-119375` affects `libsqlite3-sys` bundled SQLite before 3.54.0; remediation and a clean cargo-deny rerun are required before Public conversion |
| Malware/PUA and proprietary-component review | BLOCKED | Automated security tests pass, but SignPath-specific behavior/PUA and bundled proprietary-component review remains incomplete |
| Public documentation and workflow review | Prepared, not public | Signing, privacy, security, uninstall, prerelease, and application documents exist on the readiness branch; anonymous access is unavailable while the repository remains Private |
| Full local regression | Pass | Rust formatting and Clippy passed; 84 workspace tests and doc tests passed; audit tests 17/17 and release tooling tests 20/20 passed; installer, Gateway, deployment, SSH restriction, E2E, workflow-structure, SignPath-workflow, and shell syntax checks passed |

## Sanitized built-in scanner summary

The built-in scanner completed against the current tracked tree and all reachable Git refs.

| Category | Count | Severity | Disposition |
|---|---:|---|---|
| `credential_url` | 3 | High | Privately classified to synthetic test material; Gitleaks reported no corresponding credential finding |
| `github_token` | 1 | High | Privately classified to synthetic documentation/test material; Gitleaks reported no token finding |
| `private_key` | 1 | High | Privately confirmed by Gitleaks as the synthetic marker in the public implementation-plan prose, not key material |
| `farpilot_identifier` | 11 | Review | Requires private per-finding disposition before publication |
| `internal_hostname` | 3 | Review | Requires private per-finding disposition before publication |
| `private_ip` | 12 | Review | Requires private per-finding disposition before publication |
| `unsafe_tracked_path` | 1 | High | Intentional tracked instruction symlink; reviewed as expected repository structure |

The built-in scanner's raw verdict was `blocked`. Gitleaks cleared the obvious high-severity synthetic patterns, but the remaining review categories keep the overall readiness status blocked.

Raw scanner artifacts are not committed and their job-scoped locations are intentionally omitted.

## Repository metadata review

```text
Tracked entries: 105
Files over 1 MiB: 0
Largest tracked regular file: 75,432 bytes
Local/remote branch refs observed: 5
Tags observed: 0
Submodule entries: 0
Git LFS pointer candidates: 0
Workflow secret references: 0
Commit email domains: qq.com only (94 commits)
```

The email-domain result is not approval to publish. Polly must explicitly accept the Git-history identity exposure before the visibility gate.

## Dependency, license, and advisory review

Preliminary Cargo metadata found no missing license expression. The authoritative `cargo deny` run did not pass:

```text
cargo-deny version: 0.20.2
Total errors: 21
Duplicate-version diagnostics: 15
Wildcard dependency groups: 3
Rejected CDLA-Permissive-2.0 diagnostics: 2
Security advisories: 1
```

The rejected license diagnostics are associated with `webpki-roots` dependency versions. They require an explicit license-policy decision or dependency resolution; they must not be blanket-allowed without review.

The advisory is public:

```text
RUSTSEC-2026-0459
CVE-2026-119375
Package: libsqlite3-sys
Affected bundled SQLite: before 3.54.0
```

The vulnerable dependency must be upgraded or otherwise remediated, followed by a clean cargo-deny run. Duplicate and wildcard diagnostics require explicit dependency/policy resolution rather than indiscriminate upgrades or allowlist exceptions.

## Scanner invocation boundary

The built-in scanner writes both reports outside the repository:

```bash
python3 -I scripts/public_readiness_audit.py \
  --repo "$PWD" \
  --private-report "$CLAUDE_JOB_DIR/tmp/farpilot-public-audit-private.json" \
  --summary "$CLAUDE_JOB_DIR/tmp/farpilot-public-audit-summary.json"
```

The complementary scan uses:

```bash
gitleaks git --redact --log-opts="--all" \
  --report-format json \
  --report-path "$CLAUDE_JOB_DIR/tmp/farpilot-gitleaks.json"
```

Do not commit either raw report. Update this document with category counts and dispositions only after reviewing them privately.

## Remaining blockers before visibility review

1. Remediate `RUSTSEC-2026-0459` / `CVE-2026-119375` and rerun cargo-deny cleanly.
2. Resolve or explicitly review cargo-deny duplicate-version, wildcard, and `CDLA-Permissive-2.0` policy diagnostics.
3. Privately review and disposition every remaining FarPilot identifier, internal-hostname, and private-address finding.
4. Complete SignPath-specific malware/PUA and proprietary-component review.
5. Confirm that the historical `qq.com` author-email domain is acceptable for public disclosure.
6. Rerun both scanners and the full verification matrix at the final visibility candidate commit.

## Visibility gate

**Visibility change authorized:** No

Permitted final states:

- `NOT RUN`
- `BLOCKED`
- `READY FOR VISIBILITY REVIEW`

The current state is `BLOCKED`. Do not run `gh repo edit --visibility public`, publish the unsigned prerelease, or submit the SignPath application from this audit result.
