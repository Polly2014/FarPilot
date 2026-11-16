# FarPilot Public Readiness Audit

**Status:** PUBLIC — EXTERNAL GATES A, B, AND C COMPLETE; FOUNDATION APPLICATION NOT APPROVED AT THIS TIME

**Repository visibility:** Public

**Final private review date/revision:** 2026-11-15 at `98781cd`

**Public conversion verification:** 2026-11-15; anonymous access and public CI verified

**Unsigned prerelease verification:** 2026-11-15 at `v0.1.0-unsigned.1`; protected workflow, exact assets, digest, and metadata verified

This committed file records only sanitized counts and dispositions. Raw scanner output, matching values, private paths, identity documents, and credentials remain outside the repository in mode-0600 private job storage.

## Required checks

| Check | Status | Sanitized result |
|---|---|---|
| Current tracked tree scanner | Pass after review | One tracked nonregular-path finding is the intentional `AGENTS.md` instruction symlink |
| Full reachable Git history scanner | Pass after private disposition | All 6 high-severity and 27 review findings were privately inspected and classified as synthetic test/documentation material, public implementation test constants, numeric-version false positives, or the intentional instruction symlink; no actual sensitive value was identified |
| Gitleaks 8.30.1 | Pass after reviewed false positive | Redacted full-history scan returned one `private-key` rule finding. It is the intentionally synthetic marker in `docs/plans/2026-11-14-farpilot-signpath-readiness-implementation.md`, not key material. No other Gitleaks finding was reported |
| FarPilot-specific prohibited-data review | Pass after private disposition | All 11 FarPilot identifiers are synthetic test values; all 3 internal-hostname findings are scanner test fixtures; all 13 private-address findings are prefix-only numeric false positives with zero valid RFC1918 address found |
| Tracked large/generated-file review | Pass | 106 tracked entries; zero regular files over 1 MiB; largest tracked regular file was 73,923 bytes; no Git LFS pointer or submodule entry detected |
| Commit author/email review | Accepted and published | 106 reachable commits use one email domain (`qq.com`); Polly explicitly accepted public disclosure of that historical domain on 2026-11-15 |
| Dependency/license and advisory review | Pass | cargo-deny 0.20.2 advisories, licenses, sources, and bans pass under the reviewed duplicate-warning policy; patched SQLite is used and no package lacks a license expression |
| Proprietary-component review | Pass for current graph/artifact set | Cargo source/license policy passes, non-OSI root-data packages were removed, and the exact release assembly contains no third-party executable artifact |
| Malware/PUA behavior review | Pass for internal readiness; external classification pending | Source and behavior review found an authorized self-hosted terminal relay with explicit device grants, a fixed Herdr launcher, restricted Gateway account, no arbitrary shell/forwarding/scanning/exploitation/evasion, documented user-visible startup task/uninstall, and no project telemetry. Final no-hacking-tools classification remains SignPath Foundation's decision |
| Public documentation and workflow review | Pass after Public conversion | README, LICENSE, SECURITY, code-signing policy, privacy policy, uninstall guide, application packet, workflows, and source are anonymously accessible from `main` |
| Full regression evidence | Pass on public `main` | At `98781cd`, the final local readiness matrix passed; public CI run `43669176238` passed Windows, macOS, Ubuntu, OpenSSH security, formatting, lint, installer, audit, and dependency-policy jobs |

## Sanitized built-in scanner disposition

The built-in scanner completed against the current tracked tree and all reachable Git refs. Its raw heuristic verdict was `blocked`; private review produced these final dispositions:

| Category | Count | Final sanitized disposition |
|---|---:|---|
| `credential_url` | 3 | Synthetic credential-URL fixtures in scanner tests |
| `github_token` | 1 | Synthetic token-pattern example in implementation-plan prose; Gitleaks reported no token finding |
| `private_key` | 1 | Synthetic private-key marker in implementation-plan prose; independently matched and cleared by Gitleaks review |
| `farpilot_identifier` | 11 | Ten test-fixture occurrences and one source-embedded test occurrence; no production identity |
| `internal_hostname` | 3 | Synthetic scanner test fixtures |
| `private_ip` | 13 | Documentation/test/Cargo-lock numeric prefix matches; independent parsing found zero valid RFC1918 IPv4 address |
| `unsafe_tracked_path` | 1 | Intentional tracked `AGENTS.md` instruction symlink |

No actual sensitive/actionable finding remains from the built-in scanner. Raw scanner artifacts are not committed and their private locations are intentionally omitted.

## Repository metadata review

```text
Tracked entries: 106
Files over 1 MiB: 0
Largest tracked regular file: 73,923 bytes
Local/remote branch refs observed: 5
Tags observed: 0
Submodule entries: 0
Git LFS pointer candidates: 0
Workflow secret references: 0
Commit email domains: qq.com only (106 reachable commits)
```

Polly explicitly accepted publication of the historical `qq.com` author-email domain on 2026-11-15. This acceptance covers only existing Git author metadata and does not itself authorize a repository visibility change.

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

- moved HTTPS/WSS clients from bundled WebPKI root data to operating-system native roots, removing non-OSI `CDLA-Permissive-2.0` root-data packages;
- versioned every internal path dependency, removing wildcard dependency findings;
- resolved `libsqlite3-sys` to patched 0.39.1, which bundles SQLite 3.54.1 and clears `RUSTSEC-2026-0459` / `CVE-2026-119375`;
- pinned SQLx to official merged upstream commit `10462fa4414c6c7f1ed1d39bb31678e3b726878c` until an equivalent crates.io patch release is available;
- changed blanket duplicate-version denial into an explicit warning/review policy because the remaining duplicates are transitive major-version splits rather than unresolved direct dependency specifications.

The official SQLx Git source and exact revision are locked and allowlisted. Replacing the temporary pin with a published patch release remains a maintenance follow-up, not a visibility blocker.

## Malware/PUA and no-hacking-tools review

The internal review covered production code, deployment assets, installers, security tests, and documented behavior:

- Windows Host opens no inbound listener and uses outbound authenticated WSS;
- Host accepts typed terminal-session operations and launches only configured Herdr, not arbitrary commands;
- Gateway SSH accounts use forced attachment commands and deny shell, forwarding, agent forwarding, and X11;
- authorization is explicit, Host-scoped, independently revocable, and deny-by-default;
- pairing tokens are short-lived, single-use, hashed, and excluded from logs;
- installers and the optional current-user startup task are documented, visible, current-user scoped, and removable;
- FarPilot does not include credential testing, exploitation, scanning, stealth, persistence evasion, or project-operated telemetry.

This internal evidence clears the malware/PUA readiness item. SignPath Foundation retains sole authority to classify the project under its no-hacking-tools policy.

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

## Completed visibility gate

External Gate A was explicitly authorized and completed on 2026-11-15:

1. reviewed readiness commits were merged to `main` and pushed;
2. repository visibility changed from Private to Public;
3. anonymous API/raw access was verified for README, LICENSE, SECURITY, code-signing policy, privacy policy, uninstall guide, application packet, workflows, and source;
4. secret scanning, push protection, and Dependabot security updates were enabled;
5. public CI run `43669176238` completed successfully.

Polly explicitly chose not to enable `main` branch protection at this time. This is an accepted/deferred governance decision, not an enabled control; signing and prerelease workflows retain their own manual Environment and permission gates.

## Completed unsigned prerelease gate

External Gate B was explicitly authorized and completed on 2026-11-15:

1. protected GitHub Environment `signpath-application` required manual approval by `Polly2014` and was restricted to `main`;
2. workflow run `43674439627` completed successfully after manual approval;
3. prerelease tag `v0.1.0-unsigned.1` points to reviewed commit `35d58c6cf0df06a91942f6996ee543794f1cbdca`;
4. the GitHub Release is a prerelease, not a draft, and contains the required unsigned warning;
5. the exact three assets are `farpilot-windows-x86_64-unsigned.exe`, `SHA256SUMS`, and `build-metadata.json`;
6. the downloaded private verification copy matched `SHA256SUMS`, and metadata schema, repository, source SHA, Cargo version, filename, hash, unsigned flag, and purpose were verified;
7. GitHub `/releases/latest` remained absent, so no stable Release or installer channel was activated.

Release: https://github.com/Polly2014/FarPilot/releases/tag/v0.1.0-unsigned.1

## Completed application gate and external outcome

External Gate C was completed manually on 2026-11-15. On 2026-11-16, FarPilot learned that SignPath Foundation would not approve the application at this time because the project did not yet show enough external public-trust and visibility signals. SignPath identified community adoption, independent references or discussions, institutional backing, and sustained activity and engagement as the relevant external signals, emphasized that the decision was not a judgment on quality or potential, and invited a future reapplication.

This outcome does not activate a certificate, signing tenant, or production signing workflow. A regular paid subscription was offered as an alternative, but no subscription or signing-route decision is recorded here. Private correspondence and contact information remain outside the repository.
