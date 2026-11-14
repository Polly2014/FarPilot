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
| Commit author/email review | Accepted for publication | 94 commits use one email domain (`qq.com`); Polly explicitly accepted public disclosure of that historical domain on 2026-11-15 |
| Cargo metadata review | Pass | 300 packages, zero missing license expressions, 25 unique license expressions; no `webpki-roots` package remains |
| cargo-deny 0.20.2 | Pass with reviewed duplicate policy | Advisories, licenses, sources, and bans pass. Wildcard path dependencies were versioned; duplicate transitive major versions are policy warnings reviewed separately (27 package names / 57 version entries), not hidden errors |
| Vulnerability gate | Pass with temporary upstream pin | `libsqlite3-sys` resolves to patched 0.39.1 (SQLite 3.54.1); `RUSTSEC-2026-0459` / `CVE-2026-119375` is clear. SQLx is pinned to official merged commit `10462fa4414c6c7f1ed1d39bb31678e3b726878c` until an equivalent crates.io patch release is available |
| Proprietary-component review | Pass for current Cargo/release graph | cargo-deny licenses and sources pass, every Cargo package has a license expression, non-OSI `webpki-roots` data packages were removed, and exact release assembly includes no third-party executable artifact |
| Malware/PUA behavior review | BLOCKED | Automated security tests pass, but the SignPath-specific behavior/PUA eligibility review remains incomplete |
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

Polly explicitly accepted publication of the historical `qq.com` author-email domain on 2026-11-15. This acceptance covers only existing Git author metadata and does not authorize the repository visibility change itself.

## Dependency, license, and advisory review

The remediated Cargo graph passes the authoritative policy checks:

```text
cargo-deny version: 0.20.2
Advisories: pass
Licenses: pass
Sources: pass
Bans: pass with duplicate-version warnings explicitly allowed for review
Cargo packages: 300
Missing license expressions: 0
Unique license expressions: 25
libsqlite3-sys: 0.39.1
webpki-roots packages: 0
Reviewed duplicate package names: 27 (57 version entries)
```

The dependency changes:

- moved HTTPS/WSS clients from bundled WebPKI root data to operating-system native roots, removing both non-OSI `CDLA-Permissive-2.0` `webpki-roots` packages;
- added versions to every internal path dependency, removing wildcard dependency findings;
- resolved `libsqlite3-sys` to patched 0.39.1, which bundles SQLite 3.54.1 and clears `RUSTSEC-2026-0459` / `CVE-2026-119375`;
- pinned SQLx to official merged upstream commit `10462fa4414c6c7f1ed1d39bb31678e3b726878c`, which widens the supported `libsqlite3-sys` range, until an equivalent crates.io patch release is available;
- changed blanket duplicate-version denial into an explicit warning/review policy because the remaining duplicates are transitive major-version splits rather than unresolved direct dependency specifications.

The official SQLx Git source and exact revision are locked and allowlisted; replacing the temporary pin with a published patch release remains a maintenance follow-up, not a visibility blocker.

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

1. Privately review and disposition every remaining FarPilot identifier, internal-hostname, and private-address finding.
2. Complete the SignPath-specific malware/PUA behavior review.
3. Record Polly's confirmation that the historical `qq.com` author-email domain is acceptable for public disclosure.
4. Record Polly's GitHub MFA confirmation.
5. Rerun both scanners, cargo-deny, and the full verification matrix at the final visibility candidate commit.

## Visibility gate

**Visibility change authorized:** No

Permitted final states:

- `NOT RUN`
- `BLOCKED`
- `READY FOR VISIBILITY REVIEW`

The current state is `BLOCKED`. Do not run `gh repo edit --visibility public`, publish the unsigned prerelease, or submit the SignPath application from this audit result.
