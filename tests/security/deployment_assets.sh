#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
service="$root/deploy/gateway/farpilot-gateway.service"
nginx="$root/deploy/gateway/farpilot.polly.wang.nginx"
windows="$root/deploy/windows/install.ps1"
runbook="$root/docs/stage0-runbook.md"
gateway_installer="$root/deploy/gateway/install.sh"

grep -q '127.0.0.1:8787' "$service"
grep -q 'NoNewPrivileges=true' "$service"
grep -q 'PrivateTmp=true' "$service"
grep -q 'ProtectSystem=strict' "$service"
grep -q 'ReadWritePaths=/var/lib/farpilot /run/farpilot' "$service"
grep -q 'proxy_pass http://127.0.0.1:8787' "$nginx"
grep -q 'proxy_set_header Upgrade $http_upgrade' "$nginx"
grep -q 'proxy_set_header Connection "upgrade"' "$nginx"
grep -q 'proxy_read_timeout 86400s' "$nginx"
grep -q 'limit_req zone=farpilot_pair' "$nginx"
grep -A 10 'location ~ \^/(pair/|v1/pair/)' "$nginx" | grep -q 'access_log off;'
grep -A 10 'location ~ \^/(pair/|v1/pair/)' "$nginx" | grep -q 'error_log /dev/null crit;'
grep -q 'Get-FileHash -Algorithm SHA256' "$windows"
grep -q 'Get-AuthenticodeSignature' "$windows"
grep -q 'RunLevel Limited' "$windows"
grep -q 'FARPILOT_DATABASE_URL=sqlite:///var/lib/farpilot/farpilot.db' "$runbook"
grep -q 'NoNewPrivileges=true' "$gateway_installer"
grep -q 'ProtectSystem=strict' "$gateway_installer"
grep -q 'RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6' "$gateway_installer"
grep -q 'AllowTcpForwarding no' "$gateway_installer"
grep -q 'AllowAgentForwarding no' "$gateway_installer"
grep -q 'access_log off;' "$gateway_installer"
grep -q 'error_log /dev/null crit;' "$gateway_installer"
grep -q 'FARPILOT_CERTBOT_EMAIL=' "$gateway_installer"
if grep -Eqi 'New-NetFirewallRule|netsh.*firewall|0\.0\.0\.0' "$windows"; then
  echo 'Windows installer must not create inbound network exposure' >&2
  exit 1
fi
