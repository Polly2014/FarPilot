# FarPilot SignPath Foundation Application Readiness

**Status:** Application packet prepared for review; external form not submitted

```text
Repository visibility: PUBLIC
Application: NOT SUBMITTED
Unsigned prerelease: PUBLISHED — v0.1.0-unsigned.1
Anonymous link access: VERIFIED 2026-11-15
GitHub MFA: USER CONFIRMED 2026-11-15
SignPath MFA: NOT APPLICABLE UNTIL ACCOUNT/INVITATION EXISTS
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

**Current visibility:** Public; External Gate A completed and anonymous source/policy access verified

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
| No malware or potentially unwanted applications | **PASS FOR INTERNAL READINESS** | Gitleaks reported only one reviewed synthetic plan marker; all built-in scanner findings were privately dispositioned as synthetic/intentional/false positive; production behavior review found an authorized relay with no credential testing, exploitation, scanning, evasion, stealth persistence, or project telemetry. SignPath retains final classification authority. |
| OSI-approved project license | **PASS** | Apache-2.0 is anonymously accessible in the Public repository. |
| Dependency/license audit and no proprietary bundled components | **PASS** | cargo-deny advisories, licenses, sources, and bans pass under the reviewed duplicate-warning policy; patched `libsqlite3-sys` 0.39.1 is used, wildcard path dependencies are versioned, non-OSI `webpki-roots` packages were removed, and the exact release assembly includes no third-party executable artifact. |
| Active maintenance evidence | **PASS** | Public commit history, current documentation, and successful public CI run `43669176238` provide anonymously reviewable maintenance evidence. |
| Already released in signable form | **PASS** | The reviewed unsigned application prerelease `v0.1.0-unsigned.1` is publicly available with exact artifact, digest, metadata, source-commit, and workflow provenance. |
| Documented functionality and download information | **PASS** | README, runbook, installer, security, and uninstall documentation are available on Public `main`; stable signed downloads remain intentionally unavailable. |
| Uninstall instructions or automation | **PASS** | Transactional Windows uninstall and conservative cross-platform guidance are publicly available. |
| No hacking tools | **EXTERNAL REVIEW REQUIRED** | FarPilot is designed as an authorized self-hosted terminal relay with strict command, shell, forwarding, and Host authorization boundaries; final classification remains SignPath Foundation's decision. |
| MFA and signing-role process | **PARTIAL PASS** | Polly confirmed GitHub MFA on 2026-11-15; SignPath MFA becomes applicable and mandatory only after account or invitation setup. |

Application readiness: **READY FOR EXTERNAL GATE C USER REVIEW**. All internally verifiable eligibility items pass; SignPath Foundation's no-hacking-tools classification is intentionally an external application outcome. Private contact fields and SignPath MFA are completed directly during the external process.

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
Status: PUBLISHED PRERELEASE
Release: https://github.com/Polly2014/FarPilot/releases/tag/v0.1.0-unsigned.1
Source commit: 35d58c6cf0df06a91942f6996ee543794f1cbdca
Workflow run: 43674439627
Purpose: SignPath Foundation application review only
Stable/latest impact: None
```

The published prerelease contains exactly:

```text
farpilot-windows-x86_64-unsigned.exe
SHA256SUMS
build-metadata.json
```

Its release body begins with `UNSIGNED SIGNPATH APPLICATION ARTIFACT` and warns users not to install it on production systems. It does not contain stable manifests or installer assets and did not become the latest stable Release. Publication required manual approval through the protected `signpath-application` Environment; `Polly2014` was the configured reviewer, self-review prevention was disabled for the single-maintainer project, and the Environment deployment policy was restricted to `main`.

The downloaded private verification copy contained exactly the three named assets. `SHA256SUMS` matched the unsigned executable, and `build-metadata.json` was verified for schema version 1, repository, source SHA, Cargo version `0.1.0`, artifact filename/hash, `unsigned=true`, and `purpose=signpath-application`.

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
| Repository Public | **YES — External Gate A completed 2026-11-15** |
| Anonymous source and policy links accessible | **YES — API/raw access verified** |
| Apache-2.0 license present | **YES — anonymously accessible** |
| Code signing policy prepared | **YES — public on `main`** |
| Privacy policy prepared | **YES — public on `main`** |
| Security reporting policy prepared | **YES — public on `main`** |
| Uninstall implementation and guide prepared | **YES — public on `main`** |
| Public-readiness tree/history audit | **PASS — External Gate A completed; built-in findings privately dispositioned and Gitleaks complementary scan reviewed** |
| Historical author-email disclosure | **ACCEPTED — Polly confirmed on 2026-11-15 that the `qq.com` author domain in existing commits may be public** |
| Complementary Gitleaks audit | **COMPLETED — one synthetic plan marker reviewed as a false positive; no other finding** |
| Dependency/license policy audit | **PASS — cargo-deny advisories/licenses/sources/bans pass; patched SQLite 3.54.1 is used, wildcard path dependencies are versioned, and non-OSI webpki root-data dependencies were removed** |
| GitHub MFA enabled | **YES — USER CONFIRMED 2026-11-15** |
| SignPath MFA enabled | **NOT APPLICABLE UNTIL ACCOUNT/INVITATION EXISTS** |
| Unsigned prerelease `v0.1.0-unsigned.1` | **PUBLISHED — [review artifact](https://github.com/Polly2014/FarPilot/releases/tag/v0.1.0-unsigned.1)** |
| Prerelease workflow run successful | **YES — run `43674439627`, exact three assets and metadata verified** |
| Terms rechecked | **Reviewed 2026-11-14: https://signpath.org/terms** |
| Application submitted | **NOT SUBMITTED** |

External Gates A and B are complete. Do not submit the external application until Polly explicitly approves External Gate C in the implementation plan.
