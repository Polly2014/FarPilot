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
grep -Fq '[Uninstall](docs/uninstall.md)' "$readme"
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
