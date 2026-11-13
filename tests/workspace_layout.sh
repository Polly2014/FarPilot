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

test -f "$security"
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
