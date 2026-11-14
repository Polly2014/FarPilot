# FarPilot Code Signing Policy

**Status:** SignPath readiness in progress. FarPilot has not yet been accepted by SignPath Foundation and no FarPilot certificate profile is active.

Free code signing provided by SignPath.io, certificate by SignPath Foundation

## Signed scope

The initial signing scope is limited to the project-built Windows executable:

```text
farpilot-windows-x86_64.exe
```

FarPilot does not use this signing process for:

- third-party or upstream binaries;
- user-modified forks;
- pull-request or unmerged-branch artifacts;
- local developer builds;
- Linux or macOS executables;
- files that are not produced from FarPilot's reviewed source and build workflow.

## Source and build requirements

A signed artifact must:

1. originate from the public `Polly2014/FarPilot` repository after the public-readiness gate is approved;
2. be built from a commit reachable from protected `main`;
3. correspond to a reviewed tag whose version matches the workspace Cargo version;
4. be produced by the committed GitHub Actions release workflow;
5. pass formatting, Clippy, tests, installer checks, OpenSSH security integration, and release-asset validation;
6. retain provenance linking source commit, workflow run, signing request, approval, final digest, and GitHub Release.

Pull requests and unmerged branches cannot access signing credentials or request production signatures.

## Team roles

FarPilot is currently a single-maintainer project with no independent human review.

```text
Author: Polly / Polly2014
Reviewer: Polly / Polly2014
Approver: Polly / Polly2014
```

These roles do not imply separation of duties. If SignPath Foundation requires a separate reviewer or approver, production signing remains blocked until a trusted person is added.

A future contributor does not automatically receive any signing role.

## Compensating controls

The single-maintainer model is constrained by:

- multi-factor authentication for GitHub and SignPath accounts;
- a protected GitHub `release-signing` Environment with manual approval;
- manual approval of every SignPath signing request;
- signing only reviewed tags whose commits are reachable from `main`;
- least-privilege workflow permissions;
- automated mutation tests for signing and release workflows;
- explicit self-review of signing-policy, workflow, and release-configuration changes;
- failure-closed verification of Authenticode status, certificate subject, Code Signing EKU, RFC3161 timestamp, binary version, and final SHA-256.

Because Polly is currently the only maintainer, GitHub Environment self-review prevention cannot be enabled. This limitation is disclosed rather than represented as independent approval.

## Artifact integrity and publication

The signed Windows executable is the only Windows artifact that may enter a stable release assembly. The release manifest and SHA-256 are generated after signing and verification.

Published release assets are immutable. FarPilot corrects a defective release with a new patch version and never replaces an asset under an existing tag.

Unsigned SignPath application artifacts are always GitHub prereleases, contain `unsigned` in the filename and release warning, and are excluded from stable installers and `latest.json`.

## Signing and release records

For each signed release, retain public or access-controlled records appropriate to their sensitivity:

- source commit and tag;
- GitHub Actions run;
- SignPath request and approval reference;
- certificate subject and thumbprint;
- timestamp-verification result;
- final SHA-256 and manifest;
- GitHub Release URL.

No signing token, API secret, identity document, or private correspondence is committed to the repository.

## Incident response

If a signing account, certificate, workflow, source commit, or artifact might be compromised:

1. stop new signing and stable publication;
2. revoke or rotate affected credentials;
3. preserve sanitized audit evidence;
4. contact SignPath about request or certificate revocation;
5. withdraw or clearly mark affected releases;
6. publish a GitHub Security Advisory when users may be affected;
7. rebuild and sign a new patch version from a reviewed clean commit.

Security concerns should follow [SECURITY.md](../SECURITY.md).
