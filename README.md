# FarPilot

> Pilot your agents from anywhere.

FarPilot is a secure connection layer for attaching standard SSH terminals to persistent Herdr sessions on Windows machines that can make outbound connections but cannot accept inbound traffic.

## Stage 0 target

The first deployment connects:

```text
Mac OpenSSH / iPhone Moshi
            |
            v
   FarPilot Gateway on Azure
            ^
            | outbound WSS 443
            |
   FarPilot Host on Windows 11
            |
          Herdr
```

FarPilot is currently at the project-scaffold stage. Protocol, Gateway, Host, pairing, and deployment behavior are specified but not yet implemented.

## Design

- [Approved MVP specification](docs/specs/2026-11-11-farpilot-mvp-design.md)
- [Implementation plan](docs/plans/2026-11-11-farpilot-mvp-implementation.md)

## Security boundary

The DevBox must expose no inbound listener. Gateway SSH access is restricted to attaching an authorized device to Herdr and must never provide an arbitrary shell, forwarding, or remote command execution.

## License

Licensed under [Apache-2.0](LICENSE).
