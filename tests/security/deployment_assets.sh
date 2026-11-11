#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
service="$root/deploy/gateway/farpilot-gateway.service"
caddy="$root/deploy/gateway/Caddyfile"
windows="$root/deploy/windows/install.ps1"

grep -q '127.0.0.1:8787' "$service"
grep -q 'NoNewPrivileges=true' "$service"
grep -q 'PrivateTmp=true' "$service"
grep -q 'ProtectSystem=strict' "$service"
grep -q 'ReadWritePaths=/var/lib/farpilot /run/farpilot' "$service"
grep -q 'reverse_proxy 127.0.0.1:8787' "$caddy"
grep -q 'Get-FileHash -Algorithm SHA256' "$windows"
grep -q 'Get-AuthenticodeSignature' "$windows"
grep -q 'RunLevel Limited' "$windows"
if grep -Eqi 'New-NetFirewallRule|netsh.*firewall|0\.0\.0\.0' "$windows"; then
  echo 'Windows installer must not create inbound network exposure' >&2
  exit 1
fi
