# FarPilot

FarPilot securely connects standard SSH terminals to persistent Herdr sessions on outbound-only Windows hosts.

## Project status

FarPilot is in MVP development. The approved design is in `docs/specs/2026-11-11-farpilot-mvp-design.md`, and the implementation plan is in `docs/plans/2026-11-11-farpilot-mvp-implementation.md`.

## Commands

Run commands from this directory unless a command supplies `--manifest-path`.

- `cargo fmt --all -- --check`
- `cargo clippy --workspace --all-targets --all-features -- -D warnings`
- `cargo nextest run --workspace`
- `cargo test --doc --workspace`

## Architecture boundaries

- `farpilot-core` contains protocol and cryptographic types and has no network or database code.
- `farpilot-gateway` runs on Linux and owns SSH admission metadata, pairing, registry, and relay behavior.
- `farpilot-host` runs on native Windows and may launch only the configured Herdr executable.
- `farpilot-cli` contains command parsing and delegates behavior to library crates.

Keep units focused. Protocol rules belong in core, persistence belongs in Gateway, Windows terminal behavior belongs in Host, and CLI modules must not duplicate business logic.

## Security invariants

- The DevBox exposes no inbound listener.
- The Gateway SSH account never provides a general shell or port forwarding.
- QR codes never contain private keys or reusable bearer credentials.
- Terminal payloads, prompts, repository contents, and environment values are never logged.
- Unknown protocol versions, oversized frames, and unauthorized Host/device combinations fail closed.
- Do not add arbitrary remote command execution; the MVP launches only Herdr.
- Device authorization is deny-by-default and scoped to explicit Host grants.
- Host and device private keys remain on their originating devices.
- Corporate policy approval is a deployment prerequisite; user-space installation is not permission to bypass policy.

## Development workflow

- Follow TDD: write a failing test, run it, implement the minimum behavior, and verify it passes.
- Run targeted tests before workspace-wide checks.
- Keep Windows-specific behavior behind testable interfaces so portable tests run on macOS/Linux.
- Never log or add test fixtures containing real credentials, hostnames, IP addresses, tokens, terminal content, or company data.
- Do not commit or push unless explicitly requested.
