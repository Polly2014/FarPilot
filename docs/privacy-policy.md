# FarPilot Privacy Policy

**Effective date:** 2026-11-14

## Zero telemetry

FarPilot uses a zero telemetry model. The FarPilot project does not collect or receive:

- analytics or usage statistics;
- crash reports;
- installation or update counts;
- background-update checks;
- self-hosted Gateway records;
- terminal contents, prompts, repository contents, or environment values.

FarPilot does not operate a project call-home service.

## Expected network operations

FarPilot communicates only when a user or operator requests or configures the relevant operation:

- GitHub Releases when a user explicitly installs or updates FarPilot;
- the user's configured self-hosted Gateway over HTTPS/WSS;
- standard SSH connections from an authorized client to that Gateway;
- Certbot and Let's Encrypt when a Gateway operator requests certificate provisioning.

GitHub, hosting providers, certificate authorities, and network operators process data under their own privacy policies. FarPilot does not receive GitHub downloader identity from the installer.

## Self-hosted Gateway data

A Gateway controlled by its operator stores the minimum metadata required for authentication and authorization:

- opaque Host and device identifiers;
- Host public keys;
- normalized SSH public keys and fingerprints;
- Host grants and revocations;
- enrollment and pairing-token hashes and expiry/consumption state;
- audit timestamps, action types, outcomes, identifiers, and coarse byte counts.

Terminal plaintext passes through the operator-controlled Gateway memory while a live session is relayed. FarPilot does not persist terminal payloads or scrollback.

FarPilot application logs must not contain:

- terminal content or prompts;
- repository content or environment values;
- private keys or Host identity material;
- raw pairing or enrollment tokens;
- SSH public-key bodies.

Pairing-token paths suppress access/error URI logging. Ordinary infrastructure logs may record source IP addresses and coarse request metadata. The self-hosting operator determines infrastructure log access, retention, and deletion.

## Device and Host storage

Host private keys remain on the originating Windows Host. Client SSH private keys remain on the originating client. Removing or revoking a device does not cause FarPilot to receive its private key.

Uninstall and purge behavior is documented in [Uninstall](uninstall.md). Default Windows uninstall preserves Host identity and configuration to avoid accidental loss; explicit purge is required to remove them.

## Security and disclosure

Security reports should follow [SECURITY.md](../SECURITY.md) and must not include live credentials or private keys in public issues.

## Future hosted service

A future hosted FarPilot cloud would require a separate privacy, tenancy, retention, abuse, availability, and compliance design. This policy does not authorize or describe a hosted multi-tenant service.

## Policy changes

Material changes are published in the repository and apply only to future software versions or services as stated. FarPilot will not silently enable telemetry through a policy update.
