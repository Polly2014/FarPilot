# FarPilot Public Readiness Audit

**Status:** BLOCKED

**Repository visibility:** Private

**Audit date:** 2026-11-14

**Audited branch/revision:** `feature/signpath-readiness` at `44422aea2c7a`

This committed file records only sanitized counts and dispositions. Raw scanner output, matching values, private paths, identity documents, and credentials remain outside the repository in a mode-0600 private job directory.

## Required checks

| Check | Status | Sanitized result |
|---|---|---|
| Current tracked tree scanner | Review complete with blocker disposition | One tracked nonregular-path finding was confirmed as the intentional `AGENTS.md` instruction symlink; no raw path/value was recorded by the scanner |
| Full reachable Git history scanner | BLOCKED pending private disposition | Scanner found 6 high-severity and 26 review findings. High-severity categories were limited to credential-pattern examples in tests/docs during sanitized bucket review, but values were not cleared for publication and require a second private scanner/manual disposition |
| Gitleaks `git --redact --log-opts="--all"` | BLOCKED | `gitleaks` is not installed in the audit environment; it was not downloaded automatically |
| FarPilot-specific prohibited-data review | BLOCKED pending private disposition | Review categories: 11 FarPilot identifiers, 3 internal hostnames, and 12 private-address patterns in reachable history; no matched value or path is committed |
| Tracked large/generated-file review | Pass | 105 tracked entries; zero regular files over 1 MiB; largest tracked regular file was 75,432 bytes; no Git LFS pointer or submodule entry detected |
| Commit author/email review | USER CONFIRMATION REQUIRED | 94 commits use one email domain (`qq.com`); no full email address is recorded here. Polly must confirm that publishing this domain through Git history is acceptable |
| Dependency/license review | BLOCKED | Preliminary Cargo metadata: 305 packages, zero missing license expressions, 26 unique expressions. `cargo-deny` is unavailable, so allowlist, advisories, bans, and source-policy checks are not complete |
| Malware/PUA and proprietary-component review | BLOCKED | Automated tests and code/security reviews pass, but SignPath-specific malware/PUA and bundled proprietary-component disposition is not yet complete |
| Public documentation and workflow review | Prepared, not public | Signing, privacy, security, uninstall, prerelease, and application documents exist on the readiness branch; anonymous access is unavailable while the repository remains Private |
| Full local regression | Pass | Rust formatting and Clippy passed; 84 workspace tests and doc tests passed; audit tests 17/17 and release tooling tests 20/20 passed; installer, Gateway, deployment, SSH restriction, E2E, workflow-structure, SignPath-workflow, and shell syntax checks passed |

## Sanitized scanner summary

The built-in scanner completed against the current tracked tree and all reachable Git refs.

| Category | Count | Severity | Disposition |
|---|---:|---|---|
| `credential_url` | 3 | High | Reachable history; privately classified to test material, but complementary scanner review remains required |
| `github_token` | 1 | High | Reachable history; privately classified to documentation/test material, but complementary scanner review remains required |
| `private_key` | 1 | High | Reachable history; privately classified to documentation/test material, but complementary scanner review remains required |
| `farpilot_identifier` | 11 | Review | Requires private per-finding disposition before publication |
| `internal_hostname` | 3 | Review | Requires private per-finding disposition before publication |
| `private_ip` | 12 | Review | Requires private per-finding disposition before publication |
| `unsafe_tracked_path` | 1 | High | Intentional tracked instruction symlink; reviewed as expected repository structure |

Scanner result: `blocked`.

Raw scanner artifacts are not committed and their job-scoped location is intentionally omitted.

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

## Dependency/license preliminary review

Cargo metadata reported no package with a missing license expression. This is preliminary only: expressions containing alternatives or licenses outside the current `deny.toml` allowlist require `cargo deny` evaluation. Because `cargo-deny` was unavailable, dependency/license readiness remains blocked.

## Scanner invocation boundary

The repository scanner writes both reports outside the repository:

```bash
python3 -I scripts/public_readiness_audit.py \
  --repo "$PWD" \
  --private-report "$CLAUDE_JOB_DIR/tmp/farpilot-public-audit-private.json" \
  --summary "$CLAUDE_JOB_DIR/tmp/farpilot-public-audit-summary.json"
```

Run the complementary scanner privately:

```bash
gitleaks git --redact --log-opts="--all" \
  --report-format json \
  --report-path "$CLAUDE_JOB_DIR/tmp/farpilot-gitleaks.json"
```

Do not commit either raw report. Update this document with category counts and dispositions only after reviewing them privately.

## Remaining blockers before visibility review

1. Install or otherwise provide a reviewed `gitleaks` binary, then scan all reachable history with redaction.
2. Install or otherwise provide a reviewed `cargo-deny` binary, then run advisories/licenses/bans/sources checks.
3. Privately review and disposition every remaining history finding without copying values into commits or issues.
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
