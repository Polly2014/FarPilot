#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
fragment="$root/deploy/gateway/sshd_config.fragment"

test -f "$fragment"
grep -Eq '^Match User farpilot$' "$fragment"
grep -Eq '^[[:space:]]+AuthenticationMethods publickey$' "$fragment"
grep -Eq '^[[:space:]]+PasswordAuthentication no$' "$fragment"
grep -Eq '^[[:space:]]+KbdInteractiveAuthentication no$' "$fragment"
grep -Eq '^[[:space:]]+AllowTcpForwarding no$' "$fragment"
grep -Eq '^[[:space:]]+AllowAgentForwarding no$' "$fragment"
grep -Eq '^[[:space:]]+X11Forwarding no$' "$fragment"
grep -Eq '^[[:space:]]+PermitTunnel no$' "$fragment"
grep -Eq '^[[:space:]]+GatewayPorts no$' "$fragment"
grep -Eq '^[[:space:]]+AuthorizedKeysFile /var/lib/farpilot/authorized_keys$' "$fragment"

if grep -Eq '^[[:space:]]*(ForceCommand|AllowTcpForwarding yes|AllowAgentForwarding yes)' "$fragment"; then
  echo "unsafe FarPilot sshd setting" >&2
  exit 1
fi
