#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)

test -f "$root/CLAUDE.md"
test -L "$root/AGENTS.md"
test "$(readlink "$root/AGENTS.md")" = "CLAUDE.md"
test -f "$root/Cargo.toml"

for crate in farpilot-core farpilot-gateway farpilot-host farpilot-cli; do
  test -f "$root/crates/$crate/Cargo.toml"
done

readme="$root/README.md"
runbook="$root/docs/stage0-runbook.md"
security="$root/docs/installer-security.md"
signing_policy="$root/docs/code-signing-policy.md"
privacy_policy="$root/docs/privacy-policy.md"
security_policy="$root/SECURITY.md"
codeowners="$root/.github/CODEOWNERS"
uninstall_doc="$root/docs/uninstall.md"
signpath_application="$root/docs/signpath-application.md"

test -f "$security"
test -f "$signing_policy"
test -f "$privacy_policy"
test -f "$security_policy"
test -f "$codeowners"
grep -Fq 'curl -fsSL https://farpilot.polly.wang/install.sh | sh' "$readme"
grep -Fq 'irm https://farpilot.polly.wang/install.ps1 | iex' "$readme"
grep -Fq -- '--version v0.1.1' "$readme"
grep -Fq 'gateway --domain' "$runbook"
grep -Fq -- '--dry-run' "$runbook"
grep -Fq 'gateway --version v0.1.1' "$runbook"
grep -Fq 'conditional interrupted-transaction recovery' "$runbook"
grep -Fq 'SHA-256' "$security"
grep -Fq 'GitHub Release' "$security"
grep -Fq 'simultaneous compromise' "$security"
grep -Fq '[Code signing policy](docs/code-signing-policy.md)' "$readme"
grep -Fq '[Privacy policy](docs/privacy-policy.md)' "$readme"
grep -Fq '[Security](SECURITY.md)' "$readme"
grep -Fq 'Free code signing provided by SignPath.io, certificate by SignPath Foundation' "$signing_policy"
grep -Fq 'farpilot-windows-x86_64.exe' "$signing_policy"
grep -Fq 'Author: Polly / Polly2014' "$signing_policy"
grep -Fq 'Reviewer: Polly / Polly2014' "$signing_policy"
grep -Fq 'Approver: Polly / Polly2014' "$signing_policy"
grep -Fq 'single-maintainer' "$signing_policy"
grep -Fq 'multi-factor authentication' "$signing_policy"
grep -Fq 'manual approval' "$signing_policy"
grep -Fq 'immutable' "$signing_policy"
grep -Fq 'zero telemetry' "$privacy_policy"
grep -Fq 'GitHub Security Advisories' "$security_policy"
grep -Fq '* @Polly2014' "$codeowners"
grep -Fq '/.github/workflows/ @Polly2014' "$codeowners"
grep -Fq 'implemented on `main`' "$readme"
grep -Fq 'short installer endpoints and first stable GitHub Release are not live' "$readme"
grep -Fq 'SignPath readiness is in progress' "$readme"
if test -f "$uninstall_doc"; then
  grep -Fq '[Uninstall](docs/uninstall.md)' "$readme"
  if grep -Fq 'Uninstall readiness: planned' "$readme"; then
    echo 'README still marks uninstall as planned after documentation landed' >&2
    exit 1
  fi
else
  grep -Fq 'Uninstall readiness: planned' "$readme"
  grep -Fq 'planned readiness control' "$privacy_policy"
  grep -Fq 'current removal guidance remains manual' "$privacy_policy"
  if grep -Fq '[Uninstall](docs/uninstall.md)' "$readme" || grep -Fq '[Uninstall](uninstall.md)' "$privacy_policy"; then
    echo 'uninstall documentation must not be linked before Task 4 creates it' >&2
    exit 1
  fi
fi
test -f "$uninstall_doc"
grep -Fq 'rm "$HOME/.local/bin/farpilot"' "$uninstall_doc"
grep -Fq 'systemctl stop farpilot-gateway.service' "$uninstall_doc"
grep -Fq 'systemctl disable farpilot-gateway.service' "$uninstall_doc"
grep -Fq 'sshd -t' "$uninstall_doc"
grep -Fq 'nginx -t' "$uninstall_doc"
grep -Fq -- '-Uninstall' "$uninstall_doc"
grep -Fq -- '-PurgeState' "$uninstall_doc"
grep -Fq 'SSH keys and profiles are preserved by default' "$uninstall_doc"
grep -Fq 'Gateway environment, database, authorized keys, SSH host keys, and certificates are preserved by default' "$uninstall_doc"
grep -Fq "powershell -ExecutionPolicy Bypass -File .\\install.ps1 -Uninstall -InstallDir 'C:\\Tools\\FarPilot'" "$uninstall_doc"
if awk '
  /^```powershell[[:space:]]*$/ { in_powershell = 1; next }
  in_powershell && /^```/ { in_powershell = 0; next }
  in_powershell && /\\[[:space:]]*$/ { bad = 1 }
  END { exit(bad ? 0 : 1) }
' "$uninstall_doc"; then
  echo 'PowerShell fenced block uses a POSIX backslash continuation' >&2
  exit 1
fi
for ssh_path in farpilot_ed25519 farpilot_ed25519.pub farpilot_known_hosts farpilot_config; do
  grep -Fq "test ! -e \"\$HOME/.ssh/$ssh_path\" || ls -ld -- \"\$HOME/.ssh/$ssh_path\"" "$uninstall_doc"
  grep -Fq "rm -- \"\$HOME/.ssh/$ssh_path\"" "$uninstall_doc"
done
grep -Fq "grep -F 'farpilot_config' \"\$HOME/.ssh/config\"" "$uninstall_doc"
if grep -Eqi 'rm[[:space:]]+(-[^[:space:]]+[[:space:]]+)*[^\n]*\.ssh/\*|curl[^\n|]*\|[^\n]*(uninstall|purge)' "$uninstall_doc"; then
  echo 'uninstall guide contains a broad SSH glob or remote destructive pipeline' >&2
  exit 1
fi
grep -Fq 'SignPath is not approved' "$signing_policy"
grep -Fq '`release-signing` Environment is not configured' "$signing_policy"
grep -Fq 'no signing certificate is active' "$signing_policy"
grep -Fq 'Required future attribution after SignPath approval:' "$signing_policy"
grep -Fq 'does not indicate current SignPath sponsorship or signing' "$signing_policy"
grep -Fq 'FarPilot software sends no telemetry' "$privacy_policy"
grep -Fq 'aggregate release-asset download counts' "$privacy_policy"
grep -Fq 'no downloader identity' "$privacy_policy"
test -f "$signpath_application"
grep -Fq '[SignPath application readiness](docs/signpath-application.md)' "$readme"
for required in \
  'Repository visibility: PRIVATE' \
  'Application: NOT SUBMITTED' \
  'Unsigned prerelease: NOT PUBLISHED' \
  'Anonymous link access: NOT AVAILABLE' \
  'MFA: USER CONFIRMATION REQUIRED' \
  'v0.1.0-unsigned.1' \
  'Author: Polly / Polly2014' \
  'Reviewer: Polly / Polly2014' \
  'Approver: Polly / Polly2014' \
  'authorized self-hosted SSH terminal relay' \
  'not an offensive security tool' \
  '[Code signing policy](code-signing-policy.md)' \
  '[Privacy policy](privacy-policy.md)' \
  '[Uninstall guide](uninstall.md)' \
  '[Security policy](../SECURITY.md)' \
  '[Unsigned application workflow](../.github/workflows/signpath-application.yml)' \
  '[ENTER DIRECTLY IN SIGNPATH FORM — DO NOT COMMIT]'; do
  grep -Fq "$required" "$signpath_application"
done
if grep -Eqi 'gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[A-Z0-9]{16}|(api[_-]?token|client[_-]?secret)[[:space:]]*[:=][[:space:]]*[^[][^[:space:]]+' "$signpath_application"; then
  echo 'SignPath application packet contains a token-like committed value' >&2
  exit 1
fi
if grep -Eqi '(home|street|postal|legal)[[:space:]_-]*(address|name)[[:space:]]*:[[:space:]]*[A-Za-z0-9]' "$signpath_application"; then
  echo 'SignPath application packet contains real-looking private identity data' >&2
  exit 1
fi
