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
