# FarPilot SignPath Foundation Readiness Design

**Status:** Approved design; implementation and external application not started

**Date:** 2026-11-14

## 1. Product decision

FarPilot will pursue free open-source Windows Authenticode signing through SignPath Foundation rather than publish an unsigned stable Windows release.

The work is split into two trust phases:

1. **Readiness and application:** audit the private repository, make it public only after approval, publish policies and uninstall guidance, create an explicitly unsigned application prerelease, and submit the SignPath Foundation application manually.
2. **Approved signing integration:** after SignPath supplies real project configuration, add a protected signing stage, verify the final Authenticode signature and timestamp, then generate SHA-256 and the stable release manifest from the signed executable.

No code will contain fabricated SignPath identifiers, placeholder API secrets, or an unverified signing integration. The repository will not be made public, no prerelease will be published, and no SignPath form will be submitted without separate explicit authorization at the corresponding gate.

## 2. Current state

At design approval time:

- `Polly2014/FarPilot` is a private GitHub repository;
- the repository uses Apache-2.0;
- the project has no stable GitHub Release;
- the verified Release workflow can assemble five platform binaries and an exact nine-file dry-run artifact;
- the Windows executable is unsigned;
- the installer accepts an unsigned Stage 0 executable only when its required SHA-256 matches;
- the project has security and installer documentation but no dedicated code-signing policy or project privacy policy;
- Windows has installation and upgrade behavior but no approved uninstall mode;
- the project is maintained by one person, Polly (`Polly2014`).

SignPath Foundation's published conditions require a public, actively maintained OSS project under an OSI-approved license, a released artifact, documented behavior, uninstall guidance, MFA, named signing roles, a code-signing policy, privacy disclosure, verifiable automated builds, and manual approval for each signed release.

## 3. Goals

1. Determine whether the full repository and Git history are safe to publish.
2. Make every SignPath prerequisite explicit and testable before application.
3. Publish accurate code-signing and privacy policies.
4. Provide safe Windows uninstall and state-purge behavior.
5. Document uninstall procedures for macOS/Linux CLI and Linux Gateway.
6. Publish one clearly marked unsigned Windows prerelease solely for SignPath review.
7. Keep the unsigned prerelease outside the stable installer and latest-manifest path.
8. Prepare an application packet that Polly can review and submit manually.
9. Integrate SignPath only after real organization/project/artifact configuration is issued.
10. Ensure stable manifests and SHA-256 values are generated only after Windows signing.
11. Block stable publication if signature, publisher, timestamp, or approval verification fails.

## 4. Non-goals

This design does not:

- submit the SignPath application automatically;
- make the repository public automatically;
- rewrite Git history without explicit confirmation;
- create fictitious SignPath IDs or secrets;
- sign Linux or macOS binaries with the Windows code-signing certificate;
- use Polly's employer or any corporate certificate without formal authorization;
- replace SignPath with a self-signed or Private Trust certificate;
- claim that GitHub artifact attestations alone provide Windows Authenticode trust;
- publish an unsigned stable Windows release;
- enable automatic background updates;
- add telemetry or analytics.

## 5. Phase 0: Public-repository safety audit

### 5.1 Audit scope

Before changing GitHub visibility, audit both the current tree and all reachable Git history for:

- private keys, SSH keys, certificates, keystores, and PFX files;
- API tokens, passwords, client secrets, connection strings, and credentials;
- enrollment and pairing tokens;
- real Host identities, public keys, SSH key bodies, and device IDs;
- internal hostnames, public or private IP addresses, corporate domains, usernames, and machine names;
- company data, terminal content, prompts, repository content, screenshots, logs, databases, and environment files;
- GitHub Actions artifacts or caches accidentally committed to Git;
- large binaries and generated files that should not be source-controlled;
- author names or email addresses that the commit authors do not intend to publish.

Use at least two complementary scanning methods: a Git-aware secret scanner and targeted repository/history searches for FarPilot-specific prohibited data.

### 5.2 Audit output

The committed audit record contains only:

```text
scan date
tool names and versions
refs/range scanned
rule categories
finding counts
sanitized disposition
final public-readiness verdict
```

It must not reproduce secret values or sensitive file contents.

Raw scanner output stays outside the repository in a private temporary location.

### 5.3 Finding response

If a credential or secret is found:

1. revoke or rotate it first;
2. identify every exposed ref and artifact;
3. remove it from the current tree;
4. prepare a history-rewrite proposal;
5. obtain explicit approval before force-pushing rewritten history;
6. rescan the rewritten repository before publication.

A clean current tree is not sufficient when the secret remains in history.

If only nonsecret personal metadata is found, Polly decides whether it is acceptable to publish.

### 5.4 Public conversion gate

The repository can become Public only when:

- all scanners pass or every finding has a documented safe disposition;
- branch protections and security reporting instructions are ready;
- documentation contains no private infrastructure details;
- `git status`, tracked-file inventory, and release workflow are reviewed;
- Polly explicitly approves the visibility change.

## 6. Project roles and governance

FarPilot is initially a single-maintainer project.

```text
Author:   Polly / Polly2014
Reviewer: Polly / Polly2014
Approver: Polly / Polly2014
```

The code-signing policy must disclose this lack of role separation rather than imply an independent review.

Compensating controls are:

- MFA on GitHub and SignPath accounts;
- signed release requests only from a tag whose commit is on `main`;
- all tests and security gates must pass before signing;
- a protected GitHub Environment named `release-signing` requires manual approval;
- SignPath requires manual approval of each signing request;
- PR builds and unmerged branches cannot access signing credentials or request signatures;
- release assets are immutable after publication;
- signing workflow and policy changes receive an explicit self-review checklist and independent automated mutation tests.

Because Polly is the only maintainer, GitHub Environment self-review prevention cannot be enabled initially. If SignPath requires role separation or a second approver, signing integration remains blocked until a trusted person is added.

A future contributor does not automatically receive any signing role.

## 7. Code-signing policy

Create `docs/code-signing-policy.md` and link it from README and every Windows download/release page.

### 7.1 Signing scope

Initially sign only:

```text
farpilot-windows-x86_64.exe
```

Do not sign:

- third-party or upstream binaries;
- modified user forks;
- PR artifacts;
- unmerged branch artifacts;
- local developer builds;
- Linux or macOS binaries;
- installer scripts or documentation as if they were PE binaries.

### 7.2 Source requirements

A signed artifact must:

- originate from `Polly2014/FarPilot` after it becomes public;
- be built from a commit reachable from protected `main`;
- correspond to a reviewed tag whose version matches the workspace Cargo version;
- be produced by the committed GitHub Actions workflow;
- pass the full test, installer, security, lint, and release-assembly gates;
- have a recorded source commit, workflow run, SignPath request, approval, final digest, and Release URL.

### 7.3 Immutability and incident response

Published release assets are immutable. A defect requires a new patch version.

If the certificate, SignPath account, GitHub account, workflow, or published binary is suspected compromised:

1. stop new signing;
2. revoke or rotate affected credentials;
3. preserve audit evidence without exposing secrets;
4. contact SignPath about certificate/request revocation;
5. withdraw or clearly mark affected releases;
6. publish a security advisory;
7. rebuild and sign from a reviewed clean commit.

## 8. Privacy policy

Create `docs/privacy-policy.md`.

### 8.1 Project service data

FarPilot collects no project-operated telemetry:

- no analytics;
- no crash reporting;
- no usage counters;
- no installation tracking;
- no background update checks;
- no self-hosted instance data sent back to Polly or the FarPilot project.

### 8.2 Expected network operations

FarPilot software communicates only with services selected or required by the operator:

- GitHub Releases when the user explicitly installs or updates;
- the user's configured self-hosted Gateway;
- SSH, HTTPS, and WSS endpoints used by FarPilot;
- Certbot/Let's Encrypt when a Gateway operator requests certificate provisioning.

GitHub, certificate authorities, and infrastructure providers apply their own privacy policies.

### 8.3 Self-hosted Gateway data

The operator-controlled Gateway processes:

- Host and device identifiers;
- SSH public keys and fingerprints;
- authorization grants and revocations;
- audit timestamps/outcomes and coarse byte counts;
- source IP addresses in ordinary infrastructure logs;
- terminal plaintext in memory while relaying a live session.

The application does not persist terminal payloads, prompts, repository contents, environment values, private keys, or raw pairing tokens. Pairing token paths suppress access/error URI logging. The self-hosting operator controls infrastructure log retention and deletion.

Any future hosted FarPilot service requires a separate privacy, tenancy, retention, abuse, and compliance design.

## 9. Uninstall design

### 9.1 Windows automated uninstall

Extend `deploy/windows/install.ps1` with mutually exclusive modes:

```powershell
.\install.ps1 -Uninstall
.\install.ps1 -Uninstall -PurgeState
```

`-PurgeState` is invalid without `-Uninstall`.

Default uninstall removes only installer-owned executable state:

- managed `FarPilot Host` Scheduled Task;
- running FarPilot processes whose executable path is under the managed release root;
- current-user PATH entries owned by the installer;
- installer-owned `current` and `bin` junctions;
- versioned release directories;
- installer lock and stale staging/backup directories;
- empty installer-owned program directories.

Default uninstall preserves:

- Host identity;
- Host configuration;
- user-created files;
- unrelated SSH profiles and keys.

It prints a prominent instruction to revoke the Host/device grants on the Gateway before or immediately after uninstalling.

`-PurgeState` additionally deletes identity and configuration only after a second explicit confirmation. In noninteractive CI, a dedicated test-only confirmation adapter is required; production cannot bypass confirmation through a public test flag.

Uninstall is transactional where practical: failure to remove a task, process, or PATH entry stops destructive directory cleanup and reports the remaining managed paths.

### 9.2 macOS/Linux CLI uninstall documentation

Document manual removal:

```bash
rm "$HOME/.local/bin/farpilot"
```

If `FARPILOT_INSTALL_DIR` was used, remove that exact managed binary instead.

By default preserve:

- FarPilot SSH private/public key files;
- FarPilot-owned SSH include/profile;
- user pairing records.

Provide explicit inspection commands before optional deletion. Never use broad globs over `~/.ssh`.

### 9.3 Linux Gateway uninstall documentation

Document the administrator sequence:

1. list and revoke all devices;
2. stop and disable `farpilot-gateway.service`;
3. remove only FarPilot-managed systemd, sshd, and Nginx files;
4. validate `sshd -t`, `nginx -t`, and systemd state;
5. reload affected services;
6. remove `/usr/local/bin/farpilot`;
7. preserve `/var/lib/farpilot`, `/etc/farpilot/gateway.env`, SSH host keys, and certificates by default;
8. back up and explicitly confirm before deleting state.

Do not provide a remote one-line destructive purge command.

## 10. Unsigned SignPath application prerelease

### 10.1 Purpose

Create one public prerelease only after the repository is public and the policy/uninstall work is merged:

```text
v0.1.0-unsigned.1
```

It exists solely to demonstrate the artifact form and verifiable build that SignPath would sign.

### 10.2 Isolation from stable distribution

The prerelease:

- is marked GitHub `Prerelease`;
- is never selected by `/releases/latest`;
- does not update `latest.json`;
- is not referenced by `farpilot.polly.wang/install.sh` or `install.ps1`;
- does not modify the stable Release workflow;
- is not described as safe for normal installation.

The release body begins with:

```text
UNSIGNED SIGNPATH APPLICATION ARTIFACT
For code-signing review only.
Do not install on production systems.
```

### 10.3 Application artifact contents

Attach only the minimum review package:

```text
farpilot-windows-x86_64-unsigned.exe
SHA256SUMS
build-metadata.json
```

`build-metadata.json` contains:

```text
schema version
project/repository
source commit SHA
workflow run URL
Cargo version
Rust toolchain
runner image
artifact filename
SHA-256
unsigned=true
purpose=signpath-application
```

It contains no secret, token, private infrastructure, or runner credential.

### 10.4 Prerelease workflow

Create a separate `signpath-application.yml` with:

- manual `workflow_dispatch` only;
- exact `main` commit/ref validation;
- a protected `signpath-application` GitHub Environment;
- read-only repository permission plus the minimum Release write permission only in the final prerelease job;
- full tests and Windows installer checks;
- Windows x86_64 build only;
- SHA-256 and metadata generation;
- refusal to overwrite an existing prerelease/tag;
- `--prerelease` publication;
- mutation tests proving it cannot publish stable/latest assets.

Publishing the prerelease remains an explicit external gate requiring user approval.

## 11. SignPath application packet

Create `docs/signpath-application.md` containing reviewed, copy-ready answers for the external form:

- project name and public repository URL;
- Apache-2.0 license;
- maintainer and signing roles;
- concise product purpose;
- explanation that FarPilot is an authorized self-hosted SSH terminal relay, not an offensive tool;
- download/prerelease URL;
- code-signing policy URL;
- privacy policy URL;
- uninstall documentation URL;
- build workflow URL;
- security/testing summary;
- MFA confirmation;
- manual approval process;
- contact details represented as fields Polly fills immediately before submission.

The file must not contain government-ID data, private address, private telephone number, API token, or SignPath secret.

Polly manually reviews and submits the external application. Automation stops before form submission.

## 12. Post-approval signing integration

### 12.1 Configuration gate

Implementation begins only after SignPath supplies real values for its current integration, such as organization/project/artifact configuration, signing policy, and authentication method.

Store sensitive values only in protected GitHub Environment secrets. Store nonsecret identifiers in Environment variables. Do not copy secret values into issues, commits, logs, or chat.

### 12.2 Signing pipeline

The stable Windows release path becomes:

```text
build unsigned Windows EXE
        ↓
submit exact artifact to SignPath
        ↓
manual approval
        ↓
download signed EXE
        ↓
verify Authenticode status
        ↓
verify expected certificate subject
        ↓
verify code-signing EKU and timestamp
        ↓
rename/stage final Windows asset
        ↓
compute final SHA-256
        ↓
generate manifest and assemble release
```

The manifest generator must never hash the unsigned Windows artifact for a stable signed release.

### 12.3 Verification gate

On Windows, verify at minimum:

```text
Get-AuthenticodeSignature.Status == Valid
SignerCertificate subject matches the SignPath-approved publisher
certificate has Code Signing EKU
signtool verify /pa /v succeeds
RFC3161 timestamp is present and valid
binary reports the expected FarPilot version
```

The exact expected subject is captured from the approved SignPath configuration and stored as a nonsecret protected Environment variable. It is not guessed before onboarding.

### 12.4 Workflow security

- signing credentials are unavailable to PR workflows;
- signing runs only from a reviewed tag on `main`;
- third-party contributions cannot alter signing input without merge and tag review;
- cache entries are not trusted as a signing boundary;
- signing action/tool versions are pinned according to repository policy;
- unsigned artifacts and signed artifacts have distinct names and jobs;
- assembly depends only on the verified signed-Windows job;
- a missing approval, secret, identifier, signature, publisher, or timestamp blocks publication.

## 13. Failure handling

| Failure | Required behavior |
|---|---|
| Secret/history scan finding | Rotate first; do not make repository public |
| Public conversion not approved | Stop before visibility change |
| Unsigned prerelease workflow failure | Do not create prerelease |
| Existing application prerelease/tag | Refuse overwrite |
| SignPath application rejected | Keep stable release blocked; address stated gaps |
| Signing request fails | No stable manifest or Release |
| Manual signing approval denied/times out | No stable manifest or Release |
| Signed file origin/name mismatch | Reject |
| Authenticode not `Valid` | Reject |
| Publisher subject mismatch | Reject |
| Timestamp/EKU verification failure | Reject |
| SignPath/GitHub secret appears in logs | Revoke/rotate and investigate |
| Signing certificate/request revoked | Withdraw affected release and publish advisory |

## 14. Testing strategy

### 14.1 Public-readiness tests

- secret scanners cover current tree and Git history;
- targeted prohibited-data patterns run against history;
- tracked-file and large-file inventory is reviewed;
- audit summary contains no raw findings;
- repository remains private until the explicit visibility gate.

### 14.2 Policy documentation tests

Require README and release/download documentation to link:

```text
Code signing policy
Privacy policy
Uninstall instructions
Security reporting
```

Require the policy to contain the exact SignPath Foundation attribution required by its terms:

```text
Free code signing provided by SignPath.io, certificate by SignPath Foundation
```

Require role names, privacy statement, manual approval, immutable release policy, and signed scope.

### 14.3 Uninstall tests

Windows CI covers:

- default uninstall removes only managed executable state;
- identity/config remain byte-identical;
- unrelated PATH/task/process/files remain;
- `-PurgeState` requires explicit confirmation;
- confirmed purge removes only known state;
- partial failure does not proceed to broader deletion;
- repeat uninstall is idempotent;
- install → upgrade → uninstall lifecycle;
- dry-run or test adapters do not bypass production confirmation.

Static/manual checks cover CLI and Gateway uninstall documentation.

### 14.4 Application-prerelease tests

- workflow is manual-only and main-only;
- all quality gates precede publication;
- Release is always prerelease;
- asset set is exact;
- artifact name contains `unsigned`;
- release body contains the warning;
- no installer/latest manifest assets are published;
- existing tag/release cannot be overwritten;
- mutation tests reject stable publication or broadened triggers.

### 14.5 Post-approval signing tests

After real SignPath onboarding:

- a non-release dry-run exercises request, manual approval, signed download, and verification;
- unsigned Windows artifact cannot enter stable assembly;
- wrong publisher, missing timestamp, wrong version, and invalid signature fixtures fail;
- final manifest digest matches the signed file;
- signed installer acceptance succeeds for an ordinary Windows user;
- uninstall succeeds while preserving state by default;
- stable Release cannot publish when any signing gate is skipped.

## 15. Acceptance criteria

The readiness phase is complete when:

1. repository/history audit passes with a sanitized report;
2. Polly explicitly approves and completes Public conversion;
3. code-signing, privacy, security, and uninstall documents are public;
4. Authors/Reviewers/Approvers and single-maintainer limitations are disclosed;
5. Windows `-Uninstall` and `-PurgeState` pass CI;
6. macOS/Linux and Gateway uninstall instructions are complete;
7. `v0.1.0-unsigned.1` prerelease is created only after explicit approval and is isolated from latest/stable installers;
8. SignPath application packet is complete and Polly manually submits it;
9. no stable unsigned Windows Release is published.

The signing phase is complete only after SignPath approval and when:

1. protected signing configuration uses real issued values;
2. each signing request receives manual approval;
3. Authenticode, publisher, EKU, timestamp, and version verification pass;
4. SHA-256 and manifest are generated from the signed Windows file;
5. all stable release assets and installers pass end-to-end acceptance;
6. the first signed stable Release is published without mutable asset replacement.
