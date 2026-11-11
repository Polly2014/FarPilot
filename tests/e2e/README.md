# FarPilot end-to-end checks

`gateway-host.sh` runs the protocol, identity, enrollment, pairing, authorization, relay, backpressure, reconnect, Attach IPC, and fake-PTY suites as one deterministic regression gate.

The CI matrix adds two environment-specific checks that cannot be reproduced fully on macOS:

- `windows-latest` runs native DPAPI and ConPTY UTF-8/ANSI/resize validation.
- `ubuntu-latest` starts a disposable OpenSSH server and verifies forced-command and forwarding restrictions.

No test logs terminal payloads, private keys, real hostnames, public IPs, or raw production tokens.
