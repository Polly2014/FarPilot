#!/usr/bin/env bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/../.." && pwd)
installer="$repo/deploy/gateway/install.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_file() { [[ -f "$1" ]] || fail "missing file $1"; }
assert_dir() { [[ -d "$1" ]] || fail "missing directory $1"; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "$1 missing: $2"; }
assert_not_contains() { [[ ! -e "$1" ]] || ! grep -Fq -- "$2" "$1" || fail "$1 unexpectedly contains: $2"; }
assert_eq() { [[ "$1" == "$2" ]] || fail "expected [$2], got [$1]"; }
mode_of() {
  if stat -c '%a' "$1" >/dev/null 2>&1; then stat -c '%a' "$1"; else stat -f '%Lp' "$1"; fi
}
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi
}

make_binary() {
  local version=$1 path=$2
  cat > "$path" <<EOF
#!/bin/sh
if [ "\${1:-}" = "--version" ]; then printf '%s\\n' 'farpilot $version'; exit 0; fi
exit 0
EOF
  chmod 0755 "$path"
}

write_manifest() {
  local path=$1 version=$2 target=$3 binary=$4
  local name hash
  name=$(basename "$binary")
  hash=$(sha256_of "$binary")
  cat > "$path" <<EOF
{
  "schema_version": 1,
  "version": "$version",
  "tag": "v$version",
  "assets": {
    "$target": {
      "url": "https://downloads.example/$name",
      "sha256": "$hash",
      "format": "binary"
    }
  },
  "installers": {
    "gateway": {
      "url": "https://downloads.example/install-gateway.sh",
      "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    }
  }
}
EOF
}

new_case() {
  local name=$1
  CASE="$tmp/$name"
  ROOT="$CASE/root"
  DOWNLOADS="$CASE/downloads"
  LOG="$CASE/commands.log"
  mkdir -p "$ROOT/etc" "$DOWNLOADS" "$CASE/bin"
  cat > "$ROOT/etc/os-release" <<EOF
ID=ubuntu
VERSION_ID="24.04"
EOF
  make_binary 9.8.7 "$DOWNLOADS/farpilot-linux-x86_64"
  write_manifest "$CASE/manifest.json" 9.8.7 linux-x86_64 "$DOWNLOADS/farpilot-linux-x86_64"
  cp "$repo/tests/fixtures/install/fake-curl.sh" "$CASE/bin/curl"
  chmod +x "$CASE/bin/curl"
}

run_gateway() {
  FARPILOT_INSTALLER_TEST_MODE=1 \
  FARPILOT_ROOT="$ROOT" \
  FARPILOT_TEST_EUID=0 \
  FARPILOT_TEST_ARCH="${TEST_ARCH:-x86_64}" \
  FARPILOT_TEST_FINGERPRINT=SHA256:test-fingerprint \
  FARPILOT_TEST_COMMAND_LOG="$LOG" \
  FARPILOT_TEST_CURL_LOG="$CASE/curl.log" \
  FARPILOT_TEST_DOWNLOADS="$DOWNLOADS" \
  PATH="$CASE/bin:/usr/bin:/bin" \
  bash "$installer" --manifest "$CASE/manifest.json" "$@"
}

run_gateway_failure() {
  local setting=$1
  shift
  env "$setting" \
    FARPILOT_INSTALLER_TEST_MODE=1 FARPILOT_ROOT="$ROOT" FARPILOT_TEST_EUID=0 \
    FARPILOT_TEST_ARCH="${TEST_ARCH:-x86_64}" FARPILOT_TEST_FINGERPRINT=SHA256:test-fingerprint \
    FARPILOT_TEST_COMMAND_LOG="$LOG" FARPILOT_TEST_CURL_LOG="$CASE/curl.log" \
    FARPILOT_TEST_DOWNLOADS="$DOWNLOADS" PATH="$CASE/bin:/usr/bin:/bin" \
    bash "$installer" --manifest "$CASE/manifest.json" "$@"
}

# First install: managed files, permissions, hardening, package allowlist, and health.
new_case first
run_gateway --domain gateway.example.com --email operator@example.com
assert_file "$ROOT/usr/local/bin/farpilot"
assert_eq "$("$ROOT/usr/local/bin/farpilot" --version)" 'farpilot 9.8.7'
assert_dir "$ROOT/var/lib/farpilot"
assert_dir "$ROOT/etc/farpilot"
assert_file "$ROOT/etc/farpilot/gateway.env"
assert_eq "$(mode_of "$ROOT/etc/farpilot/gateway.env")" 600
assert_file "$ROOT/var/lib/farpilot/authorized_keys"
assert_eq "$(mode_of "$ROOT/var/lib/farpilot/authorized_keys")" 600
assert_contains "$ROOT/etc/farpilot/gateway.env" 'FARPILOT_DATABASE_URL=sqlite:///var/lib/farpilot/farpilot.db'
assert_contains "$ROOT/etc/farpilot/gateway.env" 'FARPILOT_PUBLIC_SSH_HOST=gateway.example.com'
assert_contains "$ROOT/etc/farpilot/gateway.env" 'FARPILOT_CERTBOT_EMAIL=operator@example.com'
assert_contains "$ROOT/etc/systemd/system/farpilot-gateway.service" 'NoNewPrivileges=true'
assert_contains "$ROOT/etc/systemd/system/farpilot-gateway.service" 'ProtectSystem=strict'
assert_contains "$ROOT/etc/systemd/system/farpilot-gateway.service" 'RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6'
assert_contains "$ROOT/etc/ssh/sshd_config.d/90-farpilot.conf" 'AllowTcpForwarding no'
assert_contains "$ROOT/etc/ssh/sshd_config.d/90-farpilot.conf" 'AllowAgentForwarding no'
assert_contains "$ROOT/etc/nginx/sites-available/gateway.example.com" 'proxy_pass http://127.0.0.1:8787'
assert_contains "$ROOT/etc/nginx/sites-available/gateway.example.com" 'access_log off;'
assert_contains "$ROOT/etc/nginx/sites-available/gateway.example.com" 'error_log /dev/null crit;'
assert_contains "$LOG" 'apt-get install nginx openssh-server certbot python3-certbot-nginx ca-certificates curl'
assert_contains "$LOG" 'sshd -t'
assert_contains "$LOG" 'nginx -t'
assert_contains "$LOG" 'systemd-analyze verify'
assert_contains "$LOG" 'certbot --nginx --non-interactive --agree-tos'
assert_contains "$LOG" 'systemctl enable farpilot-gateway.service'
assert_contains "$LOG" 'health live https://gateway.example.com/health/live'
assert_contains "$LOG" 'health ready https://gateway.example.com/health/ready'

# Existing install preserves mutable state byte-for-byte and no longer needs domain/email.
printf 'database-sentinel' > "$ROOT/var/lib/farpilot/farpilot.db"
printf 'authorized-sentinel' > "$ROOT/var/lib/farpilot/authorized_keys"
mkdir -p "$ROOT/etc/ssh" "$ROOT/etc/letsencrypt/accounts" "$ROOT/etc/letsencrypt/live/gateway.example.com"
printf 'host-key' > "$ROOT/etc/ssh/ssh_host_ed25519_key"
printf 'cert-account' > "$ROOT/etc/letsencrypt/accounts/sentinel"
printf 'cert' > "$ROOT/etc/letsencrypt/live/gateway.example.com/fullchain.pem"
cp "$ROOT/etc/farpilot/gateway.env" "$CASE/env.before"
: > "$LOG"
run_gateway
cmp "$CASE/env.before" "$ROOT/etc/farpilot/gateway.env"
assert_eq "$(cat "$ROOT/var/lib/farpilot/farpilot.db")" database-sentinel
assert_eq "$(cat "$ROOT/var/lib/farpilot/authorized_keys")" authorized-sentinel
assert_eq "$(cat "$ROOT/etc/ssh/ssh_host_ed25519_key")" host-key
assert_eq "$(cat "$ROOT/etc/letsencrypt/accounts/sentinel")" cert-account
assert_not_contains "$LOG" 'certbot --nginx'

# Strict test/root guards.
new_case guards
if FARPILOT_ROOT="$ROOT" FARPILOT_TEST_EUID=0 bash "$installer" --manifest "$CASE/manifest.json" --domain gateway.example.com --email operator@example.com >/dev/null 2>&1; then fail 'root redirect worked without test mode'; fi
if FARPILOT_INSTALLER_TEST_MODE=1 FARPILOT_TEST_EUID=0 bash "$installer" --manifest "$CASE/manifest.json" --domain gateway.example.com --email operator@example.com >/dev/null 2>&1; then fail 'test mode worked without explicit root'; fi

# Supported platform checks precede mutation.
for version in 20.04 22.04 24.04; do
  new_case "ubuntu-${version}"
  printf 'ID=ubuntu\nVERSION_ID="%s"\n' "$version" > "$ROOT/etc/os-release"
  run_gateway --domain gateway.example.com --email operator@example.com >/dev/null
done
new_case arm64
mv "$DOWNLOADS/farpilot-linux-x86_64" "$DOWNLOADS/farpilot-linux-aarch64"
write_manifest "$CASE/manifest.json" 9.8.7 linux-aarch64 "$DOWNLOADS/farpilot-linux-aarch64"
TEST_ARCH=aarch64 run_gateway --domain gateway.example.com --email operator@example.com >/dev/null
new_case unsupported-arch
if TEST_ARCH=riscv64 run_gateway --domain gateway.example.com --email operator@example.com >/dev/null 2>&1; then fail 'unsupported architecture succeeded'; fi
[[ ! -e "$ROOT/usr/local/bin/farpilot" ]] || fail 'unsupported architecture mutated root'
new_case unsupported
printf 'ID=debian\nVERSION_ID="12"\n' > "$ROOT/etc/os-release"
if run_gateway --domain gateway.example.com --email operator@example.com >/dev/null 2>&1; then fail 'unsupported distro succeeded'; fi
[[ ! -e "$ROOT/usr/local/bin/farpilot" ]] || fail 'unsupported distro mutated root'

# Invalid public inputs fail before mutation.
for domain in '-bad.example' 'bad..example' 'bad;touch.example' 'bad_example.com'; do
  new_case "domain-${RANDOM}"
  if run_gateway --domain "$domain" --email operator@example.com >/dev/null 2>&1; then fail "invalid domain succeeded: $domain"; fi
  [[ ! -e "$ROOT/usr/local/bin/farpilot" ]] || fail 'invalid domain mutated root'
done
for email in 'bad' 'a b@example.com' 'a@bad..example' ';@example.com'; do
  new_case "email-${RANDOM}"
  if run_gateway --domain gateway.example.com --email "$email" >/dev/null 2>&1; then fail "invalid email succeeded: $email"; fi
done

# Manifest/digest failures do not execute or install.
new_case bad-hash
python3 - "$CASE/manifest.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d['assets']['linux-x86_64']['sha256']='0'*64; open(p,'w').write(json.dumps(d,indent=2)+'\n')
PY
if run_gateway --domain gateway.example.com --email operator@example.com >/dev/null 2>&1; then fail 'checksum mismatch succeeded'; fi
[[ ! -e "$ROOT/usr/local/bin/farpilot" ]] || fail 'checksum mismatch installed binary'

for field in bad-url bad-format bad-version duplicate-version; do
  new_case "manifest-$field"
  python3 - "$CASE/manifest.json" "$field" <<'PY'
import json,sys
p,case=sys.argv[1:]; d=json.load(open(p))
if case == 'bad-url': d['assets']['linux-x86_64']['url']='http://downloads.example/farpilot-linux-x86_64'
elif case == 'bad-format': d['assets']['linux-x86_64']['format']='zip'
elif case == 'bad-version': d['tag']='v9.8.8'
text=json.dumps(d,indent=2)+'\n'
if case == 'duplicate-version': text=text.replace('  "version": "9.8.7",','  "version": "9.8.7",\n  "version": "9.8.7",')
open(p,'w').write(text)
PY
  if run_gateway --domain gateway.example.com --email operator@example.com >/dev/null 2>&1; then fail "invalid manifest succeeded: $field"; fi
  [[ ! -e "$ROOT/usr/local/bin/farpilot" ]] || fail "invalid manifest mutated root: $field"
done
new_case manifest-duplicate-target
python3 - "$CASE/manifest.json" <<'PY'
import sys
p=sys.argv[1]; text=open(p).read(); marker='    "linux-x86_64": {'
start=text.index(marker); end=text.index('\n    }\n  },', start)+len('\n    }'); block=text[start:end]
open(p,'w').write(text[:end]+',\n'+block+text[end:])
PY
if run_gateway --domain gateway.example.com --email operator@example.com >/dev/null 2>&1; then fail 'duplicate target manifest succeeded'; fi
new_case manifest-malformed
python3 - "$CASE/manifest.json" <<'PY'
import sys
p=sys.argv[1]; text=open(p).read(); open(p,'w').write(text.rsplit('}',1)[0])
PY
if run_gateway --domain gateway.example.com --email operator@example.com >/dev/null 2>&1; then fail 'malformed manifest succeeded'; fi

new_case shadow
python3 - "$CASE/manifest.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d={'schema_version':1,'version':'9.8.7','tag':'v9.8.7','shadow':d['assets'],'assets':d['assets'],'installers':d['installers']}; open(p,'w').write(json.dumps(d,indent=2)+'\n')
PY
run_gateway --domain gateway.example.com --email operator@example.com >/dev/null

# Config validation failure restores prior managed config and does not reload.
new_case validation
run_gateway --domain gateway.example.com --email operator@example.com >/dev/null
printf 'previous-nginx' > "$ROOT/etc/nginx/sites-available/gateway.example.com"
: > "$LOG"
if FARPILOT_TEST_FAIL_NGINX=1 run_gateway >/dev/null 2>&1; then fail 'nginx validation failure succeeded'; fi
assert_eq "$(cat "$ROOT/etc/nginx/sites-available/gateway.example.com")" previous-nginx
assert_not_contains "$LOG" 'systemctl reload nginx'
for validator in SSHD SYSTEMD; do
  new_case "validation-${validator}"
  if env "FARPILOT_TEST_FAIL_${validator}=1" \
      FARPILOT_INSTALLER_TEST_MODE=1 FARPILOT_ROOT="$ROOT" FARPILOT_TEST_EUID=0 \
      FARPILOT_TEST_ARCH=x86_64 FARPILOT_TEST_FINGERPRINT=SHA256:test-fingerprint \
      FARPILOT_TEST_COMMAND_LOG="$LOG" FARPILOT_TEST_CURL_LOG="$CASE/curl.log" \
      FARPILOT_TEST_DOWNLOADS="$DOWNLOADS" PATH="$CASE/bin:/usr/bin:/bin" \
      bash "$installer" --manifest "$CASE/manifest.json" --domain gateway.example.com --email operator@example.com >/dev/null 2>&1; then
    fail "$validator validation failure succeeded"
  fi
  assert_not_contains "$LOG" 'systemctl reload nginx'
done
new_case reload-failure
if run_gateway_failure FARPILOT_TEST_FAIL_RELOAD=1 --domain gateway.example.com --email operator@example.com >/dev/null 2>&1; then fail 'configuration reload failure succeeded'; fi
[[ ! -e "$ROOT/etc/nginx/sites-available/gateway.example.com" ]] || fail 'reload failure left new Nginx config'
new_case certbot-failure
if run_gateway_failure FARPILOT_TEST_FAIL_CERTBOT=1 --domain gateway.example.com --email operator@example.com >/dev/null 2>&1; then fail 'Certbot failure succeeded'; fi
[[ ! -e "$ROOT/etc/nginx/sites-available/gateway.example.com" ]] || fail 'Certbot failure left new Nginx config'
assert_file "$ROOT/etc/farpilot/gateway.env"

# Upgrade health failure restores old binary and attempts restart.
new_case rollback
mkdir -p "$ROOT/usr/local/bin"
make_binary 9.8.6 "$ROOT/usr/local/bin/farpilot"
run_gateway --domain gateway.example.com --email operator@example.com >/dev/null
make_binary 9.8.8 "$DOWNLOADS/farpilot-linux-x86_64"
write_manifest "$CASE/manifest.json" 9.8.8 linux-x86_64 "$DOWNLOADS/farpilot-linux-x86_64"
: > "$LOG"
if FARPILOT_TEST_FAIL_READY=1 run_gateway >/dev/null 2>"$CASE/error"; then fail 'readiness failure succeeded'; fi
assert_eq "$("$ROOT/usr/local/bin/farpilot" --version)" 'farpilot 9.8.7'
assert_contains "$LOG" 'systemctl restart farpilot-gateway.service'
for failure in LIVE ACTIVE ENABLE RESTART; do
  new_case "rollback-${failure}"
  run_gateway --domain gateway.example.com --email operator@example.com >/dev/null
  make_binary 9.8.8 "$DOWNLOADS/farpilot-linux-x86_64"
  write_manifest "$CASE/manifest.json" 9.8.8 linux-x86_64 "$DOWNLOADS/farpilot-linux-x86_64"
  if run_gateway_failure "FARPILOT_TEST_FAIL_${failure}=1" >/dev/null 2>&1; then fail "$failure failure succeeded"; fi
  assert_eq "$("$ROOT/usr/local/bin/farpilot" --version)" 'farpilot 9.8.7'
done

# Rollback restart failure reports both failure classes.
make_binary 9.8.8 "$DOWNLOADS/farpilot-linux-x86_64"
write_manifest "$CASE/manifest.json" 9.8.8 linux-x86_64 "$DOWNLOADS/farpilot-linux-x86_64"
if FARPILOT_TEST_FAIL_READY=1 FARPILOT_TEST_FAIL_ROLLBACK_RESTART=1 run_gateway >/dev/null 2>"$CASE/both-error"; then fail 'rollback restart failure succeeded'; fi
assert_contains "$CASE/both-error" 'readiness'
assert_contains "$CASE/both-error" 'rollback restart'

# First install failure stops/disables but keeps state.
new_case first-fail
if FARPILOT_TEST_FAIL_READY=1 run_gateway --domain gateway.example.com --email operator@example.com >/dev/null 2>&1; then fail 'first health failure succeeded'; fi
assert_file "$ROOT/etc/farpilot/gateway.env"
assert_contains "$LOG" 'systemctl stop farpilot-gateway.service'
assert_contains "$LOG" 'systemctl disable farpilot-gateway.service'

# Dry run performs no managed mutation and no binary/cert/health download.
new_case dry-run
run_gateway --dry-run --domain gateway.example.com --email operator@example.com > "$CASE/dry-output"
[[ ! -e "$ROOT/usr" && ! -e "$ROOT/var" && ! -e "$ROOT/etc/farpilot" ]] || fail 'dry-run mutated managed root'
assert_not_contains "$LOG" 'apt-get '
assert_not_contains "$LOG" 'certbot --nginx'
assert_not_contains "$LOG" 'health '
assert_not_contains "$CASE/curl.log" 'farpilot-linux-x86_64'
assert_contains "$CASE/dry-output" 'Dry run'

# Symlink managed paths fail closed.
new_case symlink
mkdir -p "$ROOT/var/lib" "$CASE/outside"
ln -s "$CASE/outside" "$ROOT/var/lib/farpilot"
if run_gateway --domain gateway.example.com --email operator@example.com >/dev/null 2>&1; then fail 'symlink state path succeeded'; fi
[[ -L "$ROOT/var/lib/farpilot" ]] || fail 'symlink path was replaced'

printf 'gateway installer tests passed\n'
