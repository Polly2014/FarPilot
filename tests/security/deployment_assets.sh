#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
service="$root/deploy/gateway/farpilot-gateway.service"
nginx="$root/deploy/gateway/farpilot.polly.wang.nginx"
windows="$root/deploy/windows/install.ps1"
runbook="$root/docs/stage0-runbook.md"
gateway_installer="$root/deploy/gateway/install.sh"

assert_installer_redirects() {
  python3 - "$1" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
text = re.sub(r"(?m)#.*$", "", text)
expected = {
    "/install.sh": "https://github.com/Polly2014/FarPilot/releases/latest/download/install.sh",
    "/install.ps1": "https://github.com/Polly2014/FarPilot/releases/latest/download/install.ps1",
    "/latest.json": "https://github.com/Polly2014/FarPilot/releases/latest/download/manifest.json",
}
locations = re.findall(r"location\s+([^\{]+?)\s*\{([^{}]*)\}", text, re.S)
for route, target in expected.items():
    exact = [(spec.strip(), body) for spec, body in locations if spec.strip() == f"= {route}"]
    if len(exact) != 1:
        raise SystemExit(f"{path}: expected one exact location for {route}, found {len(exact)}")
    returns = re.findall(r"(?m)^\s*return\s+302\s+(\S+);\s*$", exact[0][1])
    if returns != [target]:
        raise SystemExit(f"{path}: invalid redirect for {route}: {returns}")
allowed_specs = {f"= {route}" for route in expected}
conflicting = []
for spec, _ in locations:
    normalized = spec.strip().replace("\\", "")
    if spec.strip() not in allowed_specs and ("/install" in normalized or "/latest" in normalized):
        conflicting.append(spec.strip())
if conflicting:
    raise SystemExit(f"{path}: non-exact installer locations found: {conflicting}")
PY
}

assert_installer_redirects "$nginx"

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
grep -Fq 'Before announcing the first one-command release' "$runbook"
grep -Fq 'curl -fsSI https://farpilot.polly.wang/install.sh' "$runbook"
grep -Fq 'curl -fsSI https://farpilot.polly.wang/install.ps1' "$runbook"
grep -Fq 'curl -fsSL https://farpilot.polly.wang/latest.json' "$runbook"
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
