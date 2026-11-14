# FarPilot SignPath Foundation Application Readiness

**Status:** Application packet prepared for review; external form not submitted

```text
Repository visibility: PRIVATE
Application: NOT SUBMITTED
Unsigned prerelease: NOT PUBLISHED
Anonymous link access: NOT AVAILABLE
MFA: USER CONFIRMATION REQUIRED
```

This document contains public project answers and a pre-submission checklist. It does not contain private contact information, legal identity documents, addresses, telephone numbers, SignPath credentials, or API tokens.

## Private fields for the external form

Enter the following values directly in the SignPath form. Never commit them to this repository, paste them into an issue, or send them in a chat transcript.

```text
Primary contact email: [ENTER DIRECTLY IN SIGNPATH FORM — DO NOT COMMIT]
Private contact details: [ENTER DIRECTLY IN SIGNPATH FORM — DO NOT COMMIT]
SignPath account or tenant details: [ENTER DIRECTLY IN SIGNPATH FORM — DO NOT COMMIT]
```

## Project

**Project name:** FarPilot

**Repository:** `https://github.com/Polly2014/FarPilot`

**Current visibility:** Private; publication is blocked on the reviewed public-readiness gate

**License:** [Apache License 2.0](../LICENSE)

**Maintainer:** Polly (`Polly2014`)

FarPilot is an authorized self-hosted SSH terminal relay for reaching persistent Herdr coding-agent sessions on Windows Hosts that can make outbound connections but cannot accept inbound traffic.

FarPilot is not an offensive security tool. It does not provide arbitrary remote command execution, a general Gateway shell, SSH forwarding, credential testing, exploitation, evasion, scanning, or stealth, unauthorized, or offensive persistence. The Windows Host launches only the configured Herdr executable, and the Gateway SSH account is restricted to an explicitly authorized Host attachment.

FarPilot can optionally create a documented current-user logon Scheduled Task for Host startup. This startup mechanism is user-visible, runs without elevation, and is removable with `-Uninstall`; it is not a hidden persistence mechanism.

## Signing roles

FarPilot currently has one maintainer and no independent human separation of duties.

```text
Author: Polly / Polly2014
Reviewer: Polly / Polly2014
Approver: Polly / Polly2014
```

The single-maintainer limitation and compensating controls are documented in the [Code signing policy](code-signing-policy.md). If SignPath Foundation requires a separate reviewer or approver, production signing remains blocked until a trusted person is added.

## OSS eligibility review

The following SignPath Foundation conditions are not assumed from the Apache-2.0 project license alone. Each row remains a submission blocker until supported by public, reviewable evidence.

| SignPath OSS eligibility requirement | Current status | Evidence or remaining work |
|---|---|---|
| No malware or potentially unwanted applications | **PENDING** | Gitleaks 8.30.1 reported only one reviewed synthetic plan marker and no other finding; the built-in review categories and SignPath-specific manual behavior/PUA review remain incomplete. |
| OSI-approved project license | **IMPLEMENTED BUT NOT PUBLIC** | Apache-2.0 is present in the private repository; anonymous verification is not yet possible. |
| Dependency/license audit and no proprietary bundled components | **BLOCKED** | cargo-deny 0.20.2 reported 21 errors: duplicate/wildcard policy diagnostics, two `CDLA-Permissive-2.0` rejections for `webpki-roots` dependency versions, and `RUSTSEC-2026-0459` / `CVE-2026-119375` in `libsqlite3-sys`; remediation and clean rerun are required. |
| Active maintenance evidence | **IMPLEMENTED BUT NOT PUBLIC** | Current private evidence includes commit history, passing CI, current documentation, and recent release-readiness work; it is not anonymously accessible while the repository is Private. |
| Already released in signable form | **NOT SATISFIED** | The fixed unsigned application prerelease `v0.1.0-unsigned.1` is not published. |
| Documented functionality and download information | **IMPLEMENTED BUT NOT PUBLIC** | README, runbook, installer, security, and uninstall documentation exist on the readiness branch but are not yet public/merged. |
| Uninstall instructions or automation | **IMPLEMENTED BUT NOT PUBLIC** | Transactional Windows uninstall and conservative cross-platform guidance exist on the readiness branch. |
| No hacking tools | **EXTERNAL REVIEW REQUIRED** | FarPilot is designed as an authorized self-hosted terminal relay with strict command, shell, forwarding, and Host authorization boundaries; final classification remains SignPath Foundation's decision. |
| MFA and signing-role process | **USER CONFIRMATION REQUIRED** | GitHub MFA must be confirmed before submission; SignPath MFA becomes applicable only after account or invitation setup. |

Application readiness: **BLOCKED** while any eligibility row is `PENDING`, `NOT SATISFIED`, or `EXTERNAL REVIEW REQUIRED`.

## Code-signing scope

The requested initial signing scope is limited to the project-built Windows executable:

```text
farpilot-windows-x86_64.exe
```

FarPilot will not use the SignPath Foundation certificate for third-party binaries, upstream projects, pull-request builds, unmerged branches, local developer builds, modified forks, Linux binaries, or macOS binaries.

See the [Code signing policy](code-signing-policy.md).

## Privacy and data handling

FarPilot software sends no project telemetry, analytics, crash reports, custom installation events, or background update checks. Self-hosted Gateway state remains under the operator's control. Terminal plaintext is relayed in memory and is not persisted by FarPilot.

GitHub may expose aggregate release-asset download counts under GitHub's policy, but the installer sends no custom tracking data and FarPilot receives no downloader identity from those counts.

See the [Privacy policy](privacy-policy.md).

## Security reporting

Security reports are accepted privately through GitHub Security Advisories after the repository becomes public. Credentials, keys, live pairing tokens, internal hostnames, company data, and exploit details must not be posted in public issues.

See the [Security policy](../SECURITY.md).

## Installation and uninstall

FarPilot implements verified direct-installer code for Windows, macOS, Linux, and the self-hosted Ubuntu Gateway, together with a tested five-platform release assembly. Public stable installer endpoints remain inactive until a signed stable Release exists and the reviewed Nginx configuration is deployed. When activated, every direct installer requires the release manifest's SHA-256 digest and verifies the staged binary version before activation.

Windows provides transactional `-Uninstall` and confirmed `-PurgeState` modes. macOS/Linux CLI and Linux Gateway removal instructions use exact managed paths and preserve SSH material, Gateway databases, configuration, and certificates by default.

See the [Uninstall guide](uninstall.md).

## Build and release provenance

FarPilot uses GitHub Actions for source-controlled builds and tests. Current gates include:

- Rust formatting and Clippy with warnings denied;
- workspace and documentation tests;
- protocol, pairing, authorization, relay, Host lifecycle, and ConPTY tests;
- restricted OpenSSH integration;
- POSIX, Windows, and Gateway installer tests;
- ShellCheck and PSScriptAnalyzer;
- release-manifest generation and digest validation;
- exact release-asset-set validation;
- workflow mutation tests for permission and publication boundaries.

The stable Release workflow builds Linux x86_64/aarch64, macOS Intel/Apple silicon, and Windows x86_64 artifacts. Release manifests and SHA-256 values are generated from the exact final files selected for publication.

The separate [Unsigned application workflow](../.github/workflows/signpath-application.yml) is manual-only, main-only, and designed to create the fixed application prerelease `v0.1.0-unsigned.1` after the public-repository and prerelease gates are explicitly approved.

## Unsigned application prerelease

```text
Tag: v0.1.0-unsigned.1
Status: NOT PUBLISHED
Purpose: SignPath Foundation application review only
Stable/latest impact: None
```

The prerelease is designed to contain exactly:

```text
farpilot-windows-x86_64-unsigned.exe
SHA256SUMS
build-metadata.json
```

Its release body begins with `UNSIGNED SIGNPATH APPLICATION ARTIFACT` and warns users not to install it on production systems. It does not contain stable manifests or installer assets and cannot become the latest stable Release.

## Manual approval and repository security

Before any production signing is enabled, FarPilot requires:

- multi-factor authentication for GitHub and SignPath accounts;
- a protected GitHub `release-signing` Environment with manual approval;
- manual approval for every SignPath signing request;
- signing only a reviewed tag whose commit is reachable from `main`;
- least-privilege workflow permissions;
- verification of Authenticode status, certificate subject, Code Signing EKU, RFC3161 timestamp, binary version, and final SHA-256;
- generation of the stable manifest only after signed-file verification.

SignPath has not approved FarPilot, the `release-signing` Environment is not configured, and no signing certificate is active.

## Pre-submission checklist

| Requirement | Current status |
|---|---|
| Repository Public | **NO — currently Private** |
| Anonymous source and policy links accessible | **NOT AVAILABLE** |
| Apache-2.0 license present | **YES in repository; not yet anonymously accessible** |
| Code signing policy prepared | **YES on readiness branch; not yet public/merged** |
| Privacy policy prepared | **YES on readiness branch; not yet public/merged** |
| Security reporting policy prepared | **YES on readiness branch; not yet public/merged** |
| Uninstall implementation and guide prepared | **YES on readiness branch; not yet public/merged** |
| Public-readiness tree/history audit | **BLOCKED — built-in scan completed; remaining FarPilot-specific review categories need private disposition** |
| Complementary Gitleaks audit | **COMPLETED — one synthetic plan marker reviewed as a false positive; no other finding** |
| Dependency/license policy audit | **BLOCKED — cargo-deny found 21 policy/advisory errors, including RUSTSEC-2026-0459 / CVE-2026-119375** |
| GitHub MFA enabled | **USER CONFIRMATION REQUIRED** |
| SignPath MFA enabled | **NOT APPLICABLE UNTIL ACCOUNT/INVITATION EXISTS** |
| Unsigned prerelease `v0.1.0-unsigned.1` | **NOT PUBLISHED** |
| Prerelease workflow run successful | **NOT DISPATCHED** |
| Terms rechecked | **Reviewed 2026-11-14: https://signpath.org/terms** |
| Application submitted | **NOT SUBMITTED** |

Do not submit the external application until every public-readiness item is complete and Polly has explicitly approved External Gates A, B, and C in the implementation plan.
