# FarPilot Security Policy

## Supported versions

FarPilot is currently a private Stage 0 project under active development. The `main` branch is the only supported source line. No signed stable Windows release has been published.

After public releases begin, this section will list supported release versions and security-fix policy. Older development artifacts receive no guaranteed updates.

## Report a vulnerability privately

Use GitHub's **Report a vulnerability** flow to open a private report through GitHub Security Advisories for `Polly2014/FarPilot`.

Do not place vulnerabilities, credentials, private keys, live pairing/enrollment tokens, internal hostnames, company data, or exploit details in a public issue or discussion.

If GitHub private reporting is unavailable, contact the repository owner through the public profile without including sensitive details in the first message.

## What to include

Provide, when safe:

- affected commit or version;
- component and deployment role;
- sanitized reproduction steps;
- security impact;
- whether the issue is already public or exploited;
- suggested mitigation.

Use synthetic identifiers, addresses, keys, and payloads. Never send a production secret merely to prove that it exists.

## Response process

FarPilot will attempt to:

1. acknowledge a private report;
2. reproduce and assess it;
3. coordinate a fix and regression test;
4. prepare a new immutable patch release when releases exist;
5. publish an advisory when users need to act.

As a single-maintainer open-source project, FarPilot does not promise a response or resolution SLA.

## Signing incidents

Suspected compromise of a GitHub account, SignPath account, signing request, certificate, workflow, tag, or released binary is treated as a security incident.

FarPilot will stop signing and publication, rotate or revoke affected credentials, contact SignPath when certificate/request revocation may be required, preserve sanitized evidence, withdraw or mark affected releases, and publish a reviewed replacement version and advisory when appropriate.

See the [Code signing policy](docs/code-signing-policy.md) for signing scope and release controls.

## Security boundaries

FarPilot is for authorized access to user-controlled Hosts and Gateways. Reports about bypassing device authorization, obtaining an arbitrary Gateway/Windows shell, forwarding prohibited traffic, exposing private material, leaking pairing tokens, or persisting terminal content are in scope.

Denial-of-service reports should include a bounded, non-destructive reproduction. Do not test against infrastructure or devices you do not own or have explicit permission to assess.
