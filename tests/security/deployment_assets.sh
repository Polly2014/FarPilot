#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
service="$root/deploy/gateway/farpilot-gateway.service"
nginx="$root/deploy/gateway/farpilot.polly.wang.nginx"
windows="$root/deploy/windows/install.ps1"
runbook="$root/docs/stage0-runbook.md"

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
if grep -Eqi 'New-NetFirewallRule|netsh.*firewall|0\.0\.0\.0' "$windows"; then
  echo 'Windows installer must not create inbound network exposure' >&2
  exit 1
fi
