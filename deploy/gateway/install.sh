#!/usr/bin/env bash
set -euo pipefail

PROGRAM=farpilot
SERVICE=farpilot-gateway.service
PACKAGES=(nginx openssh-server certbot python3-certbot-nginx ca-certificates curl)
TEST_MODE=${FARPILOT_INSTALLER_TEST_MODE:-0}
ROOT=${FARPILOT_ROOT:-}
DRY_RUN=0
MANIFEST=
DOMAIN=
EMAIL=
REQUESTED_VERSION=
TMP=
ROLLBACK_PHASE=0
LOCK_DIR=
LOCK_ACQUIRED=0
STAGED_BINARY=
CONFIG_TRANSACTION_ACTIVE=0
BINARY_TRANSACTION_ACTIVE=0
BINARY_PATH=
ROLLBACK_PATH=
OLD_BINARY=0
BINARY_ACTIVATED=0

log() { printf '  > %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*" >&2; }
die() { printf '  x %s\n' "$*" >&2; exit 1; }
cleanup() {
  if ((BINARY_TRANSACTION_ACTIVE)) && declare -F restore_binary >/dev/null 2>&1; then restore_binary >/dev/null 2>&1 || true; fi
  if ((CONFIG_TRANSACTION_ACTIVE)) && declare -F restore_configs >/dev/null 2>&1; then
    restore_configs >/dev/null 2>&1 || true
    if declare -F reload_configs >/dev/null 2>&1; then reload_configs >/dev/null 2>&1 || true; fi
  fi
  if [[ -n "$STAGED_BINARY" && -f "$STAGED_BINARY" && ! -L "$STAGED_BINARY" ]]; then rm -f -- "$STAGED_BINARY"; fi
  if ((LOCK_ACQUIRED)) && [[ -n "$LOCK_DIR" && -d "$LOCK_DIR" && ! -L "$LOCK_DIR" ]]; then rmdir "$LOCK_DIR" 2>/dev/null || true; fi
  if [[ -n "$TMP" && -d "$TMP" && ! -L "$TMP" ]]; then rm -rf -- "$TMP"; fi
}
trap cleanup EXIT

usage() {
  cat <<'EOF'
usage: install.sh --manifest PATH [--domain HOST] [--email ADDRESS] [--version X.Y.Z] [--dry-run]
EOF
}

while (($#)); do
  case "$1" in
    --manifest) (($# >= 2)) || die '--manifest requires a path'; MANIFEST=$2; shift 2 ;;
    --domain) (($# >= 2)) || die '--domain requires a hostname'; DOMAIN=$2; shift 2 ;;
    --email) (($# >= 2)) || die '--email requires an address'; EMAIL=$2; shift 2 ;;
    --version) (($# >= 2)) || die '--version requires X.Y.Z'; REQUESTED_VERSION=${2#v}; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ -n "$MANIFEST" ]] || die '--manifest is required'
[[ -f "$MANIFEST" && ! -L "$MANIFEST" ]] || die 'manifest must be a regular file'

if [[ "$TEST_MODE" == 1 ]]; then
  [[ -n "$ROOT" && "$ROOT" == /* && "$ROOT" != / ]] || die 'test mode requires an explicit absolute FARPILOT_ROOT'
  [[ ${FARPILOT_TEST_EUID:-1} == 0 ]] || die 'test mode requires FARPILOT_TEST_EUID=0'
else
  [[ -z "$ROOT" ]] || die 'FARPILOT_ROOT is allowed only in test mode'
  [[ $(id -u) -eq 0 ]] || die 'run as root'
fi

root_path() { printf '%s%s\n' "$ROOT" "$1"; }
record() {
  if [[ -n ${FARPILOT_TEST_COMMAND_LOG:-} ]]; then printf '%s\n' "$*" >> "$FARPILOT_TEST_COMMAND_LOG"; fi
}
require_safe_dir() {
  local path=$1
  if [[ -L "$path" || ( -e "$path" && ! -d "$path" ) ]]; then die "managed directory is unsafe: $path"; fi
}
require_safe_file() {
  local path=$1
  if [[ -L "$path" || ( -e "$path" && ! -f "$path" ) ]]; then die "managed file is unsafe: $path"; fi
}

is_semver() { [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; }
valid_domain() {
  local value=$1 label
  [[ ${#value} -le 253 && $value == *.* && $value != .* && $value != *. && $value != *..* ]] || return 1
  IFS=. read -r -a labels <<< "$value"
  for label in "${labels[@]}"; do
    [[ ${#label} -ge 1 && ${#label} -le 63 && $label =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
  done
}
valid_email() {
  local value=$1 local_part host
  [[ $value != *[[:space:]]* && $value == *@* && $value != *@*@* ]] || return 1
  local_part=${value%@*}; host=${value#*@}
  [[ -n "$local_part" && $local_part =~ ^[A-Za-z0-9.!#$%\&\'*+/=?^_\`{|}~-]+$ ]] || return 1
  valid_domain "$host"
}
require_https() { [[ $2 == https://* ]] || die "$1 URL must use HTTPS"; }

os_release=$(root_path /etc/os-release)
[[ -f "$os_release" && ! -L "$os_release" ]] || die 'supported Ubuntu /etc/os-release is required'
os_id=$(awk -F= '$1=="ID" {gsub(/^"|"$/, "", $2); print $2; exit}' "$os_release")
os_version=$(awk -F= '$1=="VERSION_ID" {gsub(/^"|"$/, "", $2); print $2; exit}' "$os_release")
[[ "$os_id" == ubuntu ]] || die "unsupported distribution: $os_id"
case "$os_version" in 20.04|22.04|24.04) ;; *) die "unsupported Ubuntu version: $os_version" ;; esac
if [[ "$TEST_MODE" == 1 ]]; then arch=${FARPILOT_TEST_ARCH:-$(uname -m)}; else arch=$(uname -m); fi
case "$arch" in x86_64|amd64) TARGET=linux-x86_64 ;; aarch64|arm64) TARGET=linux-aarch64 ;; *) die "unsupported architecture: $arch" ;; esac

# Parse only the deterministic manifest shape emitted by release_manifest.py.
parse_manifest() {
  local file=$1 selected=$2
  awk -v selected_target="$selected" '
    function fail(m){ print "manifest parse error: " m > "/dev/stderr"; bad=1; exit 1 }
    function key(s,v){ v=s; sub(/^"/,"",v); sub(/".*/,"",v); return v }
    function sval(s,v){ v=s; sub(/^[^:]*:[[:space:]]*"/,"",v); sub(/"[[:space:]]*,?[[:space:]]*$/,"",v); return v }
    function nval(s,v){ v=s; sub(/^[^:]*:[[:space:]]*/,"",v); sub(/[[:space:]]*,?[[:space:]]*$/,"",v); return v }
    BEGIN{ depth=0 }
    {
      line=$0; if(line~/^[[:space:]]*$/) next; match(line,/[^ ]/); indent=RSTART?RSTART-1:length(line); text=line; sub(/^ */,"",text)
      if(NR==1){ if(indent!=0||text!="{") fail("root must be object"); depth=1; next }
      if(closed) fail("content after root")
      if(text~/^},?[[:space:]]*$/){
        if(depth<1||indent!=2*(depth-1)) fail("malformed nesting")
        if(in_target&&depth==target_depth){in_target=0;target_depth=0}
        if(in_assets&&depth==assets_depth){in_assets=0;assets_depth=0}
        depth--; if(depth==0){if(text!="}")fail("root trailing comma");closed=1}; next
      }
      if(indent!=2*depth||text!~/^"[^"]+"[[:space:]]*:/) fail("malformed member")
      k=key(text)
      if(text~/^"[^"]+"[[:space:]]*:[[:space:]]*{$/){
        if(depth==1&&k=="assets"){assets_count++;if(assets_count>1)fail("duplicate assets");in_assets=1;assets_depth=depth+1}
        else if(in_assets&&depth==assets_depth&&k==selected_target){target_count++;if(target_count>1)fail("duplicate target");in_target=1;target_depth=depth+1}
        depth++;next
      }
      if(depth==1&&k=="schema_version"){sc++;if(sc>1)fail("duplicate schema");schema=nval(text)}
      else if(depth==1&&k=="version"){vc++;if(vc>1)fail("duplicate version");version=sval(text)}
      else if(depth==1&&k=="tag"){tc++;if(tc>1)fail("duplicate tag");tag=sval(text)}
      else if(depth==1&&k=="assets"){assets_count++;if(assets_count>1)fail("duplicate assets");fail("assets must be object")}
      else if(in_target&&depth==target_depth){
        if(k=="url"){uc++;if(uc>1)fail("duplicate url");url=sval(text)}
        else if(k=="sha256"){hc++;if(hc>1)fail("duplicate sha256");hash=sval(text)}
        else if(k=="format"){fc++;if(fc>1)fail("duplicate format");format=sval(text)}
      }
    }
    END{
      if(bad)exit 1; if(!closed||depth!=0)fail("unterminated root"); if(sc!=1||schema!="1")fail("schema must be 1")
      if(vc!=1||tc!=1||assets_count!=1||target_count!=1||uc!=1||hc!=1||fc!=1)fail("required manifest fields missing")
      print schema;print version;print tag;print url;print hash;print format
    }
  ' "$file"
}
TMP=$(mktemp -d)
manifest_output="$TMP/manifest.values"
parse_manifest "$MANIFEST" "$TARGET" > "$manifest_output" || die 'invalid release manifest'
[[ $(wc -l < "$manifest_output" | tr -d ' ') == 6 ]] || die 'invalid release manifest output'
schema=$(sed -n '1p' "$manifest_output")
version=$(sed -n '2p' "$manifest_output")
tag=$(sed -n '3p' "$manifest_output")
binary_url=$(sed -n '4p' "$manifest_output")
expected_sha=$(sed -n '5p' "$manifest_output" | tr '[:upper:]' '[:lower:]')
format=$(sed -n '6p' "$manifest_output")
is_semver "$version" || die 'manifest version must use X.Y.Z'
[[ "$tag" == "v$version" ]] || die 'manifest tag/version mismatch'
if [[ -n "$REQUESTED_VERSION" ]]; then
  is_semver "$REQUESTED_VERSION" || die '--version must use X.Y.Z'
  [[ "$version" == "$REQUESTED_VERSION" ]] || die 'requested version does not match manifest'
fi
require_https binary "$binary_url"
[[ "$expected_sha" =~ ^[0-9a-f]{64}$ ]] || die 'manifest SHA-256 is invalid'
[[ "$format" == binary ]] || die 'Gateway asset format must be binary'

# Existing configuration is read without sourcing shell content.
etc_dir=$(root_path /etc/farpilot)
require_safe_dir "$etc_dir"
env_file="$etc_dir/gateway.env"
read_env() {
  local key=$1 count value
  [[ -f "$env_file" && ! -L "$env_file" ]] || return 1
  count=$(grep -c "^${key}=" "$env_file" || true); [[ "$count" == 1 ]] || return 1
  value=$(grep "^${key}=" "$env_file" | cut -d= -f2-)
  printf '%s\n' "$value"
}
existing=0
if [[ -e "$env_file" || -L "$env_file" ]]; then
  require_safe_file "$env_file"; existing=1
  [[ -n "$DOMAIN" ]] || DOMAIN=$(read_env FARPILOT_PUBLIC_SSH_HOST) || die 'existing environment lacks public host'
  [[ -n "$EMAIL" ]] || EMAIL=$(read_env FARPILOT_CERTBOT_EMAIL) || die 'existing environment lacks Certbot email'
fi
[[ -n "$DOMAIN" ]] || die '--domain is required for first install'
[[ -n "$EMAIL" ]] || die '--email is required for first install'
valid_domain "$DOMAIN" || die 'invalid Gateway domain'
valid_email "$EMAIL" || die 'invalid Certbot email'
cert_fullchain=$(root_path "/etc/letsencrypt/live/$DOMAIN/fullchain.pem")
cert_privkey=$(root_path "/etc/letsencrypt/live/$DOMAIN/privkey.pem")
CERT_PRESENT=0
if [[ -e "$cert_fullchain" || -L "$cert_fullchain" || -e "$cert_privkey" || -L "$cert_privkey" ]]; then
  [[ -f "$cert_fullchain" && -f "$cert_privkey" ]] || die 'existing TLS certificate pair is incomplete'
  CERT_PRESENT=1
fi

if ((DRY_RUN)); then
  printf 'Dry run: Gateway %s (%s)\n' "$version" "$TARGET"
  printf '  manifest: %s\n  asset: %s\n  domain: %s\n' "$MANIFEST" "$binary_url" "$DOMAIN"
  printf '  would provision packages, account, configs, TLS, service, and health checks\n'
  exit 0
fi

downloaded="$TMP/farpilot"
curl -fsSL --retry 3 --connect-timeout 10 --max-time 120 "$binary_url" -o "$downloaded"
if command -v sha256sum >/dev/null 2>&1; then actual_sha=$(sha256sum "$downloaded" | awk '{print tolower($1)}')
elif command -v shasum >/dev/null 2>&1; then actual_sha=$(shasum -a 256 "$downloaded" | awk '{print tolower($1)}')
else actual_sha=$(openssl dgst -sha256 "$downloaded" | awk '{print tolower($NF)}'); fi
[[ "$actual_sha" == "$expected_sha" ]] || die 'downloaded Gateway checksum did not match'
chmod 0755 "$downloaded"
reported=$("$downloaded" --version 2>/dev/null || true)
[[ "$reported" == "farpilot $version" ]] || die 'downloaded Gateway version did not match manifest'

# Command boundaries: production invokes real tools; tests record deterministic operations.
package_installed() {
  local package=$1 installed
  if [[ "$TEST_MODE" == 1 ]]; then
    installed=" ${FARPILOT_TEST_INSTALLED_PACKAGES:-} "
    [[ "$installed" == *" $package "* ]]
  else
    dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -qx 'install ok installed'
  fi
}
run_apt() {
  local package
  local -a missing=()
  for package in "${PACKAGES[@]}"; do package_installed "$package" || missing+=("$package"); done
  ((${#missing[@]})) || return 0
  record "apt-get install ${missing[*]}"
  if [[ "$TEST_MODE" != 1 ]]; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"
  fi
}
ACCOUNT_CREATE_MODE=
preflight_account() {
  if [[ "$TEST_MODE" == 1 ]]; then
    case ${FARPILOT_TEST_ACCOUNT_STATE:-missing} in
      missing) ACCOUNT_CREATE_MODE=user-group ;;
      group-only) ACCOUNT_CREATE_MODE=existing-group ;;
      valid) ACCOUNT_CREATE_MODE= ;;
      mismatch-group|mismatch-home|mismatch-shell) die 'existing farpilot account/group is incompatible' ;;
      *) die 'invalid test account state' ;;
    esac
    return
  fi
  local group_exists=0
  getent group farpilot >/dev/null 2>&1 && group_exists=1
  if id farpilot >/dev/null 2>&1; then
    ((group_exists)) || die 'existing farpilot user has no same-name group'
    [[ $(id -gn farpilot) == farpilot ]] || die 'existing farpilot user primary group is incompatible'
    passwd_entry=$(getent passwd farpilot)
    [[ $(printf '%s' "$passwd_entry" | cut -d: -f6) == /var/lib/farpilot ]] || die 'existing farpilot user home is incompatible'
    [[ $(printf '%s' "$passwd_entry" | cut -d: -f7) == /bin/sh ]] || die 'existing farpilot user shell is incompatible'
    ACCOUNT_CREATE_MODE=
  elif ((group_exists)); then
    ACCOUNT_CREATE_MODE=existing-group
  else
    ACCOUNT_CREATE_MODE=user-group
  fi
}
apply_account() {
  case "$ACCOUNT_CREATE_MODE" in
    user-group)
      record 'useradd --system --user-group --home /var/lib/farpilot --shell /bin/sh farpilot'
      if [[ "$TEST_MODE" != 1 ]]; then useradd --system --user-group --home /var/lib/farpilot --shell /bin/sh farpilot; fi ;;
    existing-group)
      record 'useradd --system --gid farpilot --home /var/lib/farpilot --shell /bin/sh farpilot'
      if [[ "$TEST_MODE" != 1 ]]; then useradd --system --gid farpilot --home /var/lib/farpilot --shell /bin/sh farpilot; fi ;;
  esac
}
validate_configs() {
  record 'sshd -t'; [[ ${FARPILOT_TEST_FAIL_SSHD:-0} != 1 ]] || return 1
  record 'nginx -t'; [[ ${FARPILOT_TEST_FAIL_NGINX:-0} != 1 ]] || return 1
  record "systemd-analyze verify $SERVICE"; [[ ${FARPILOT_TEST_FAIL_SYSTEMD:-0} != 1 ]] || return 1
  if [[ "$TEST_MODE" != 1 ]]; then sshd -t; nginx -t; systemd-analyze verify "$(root_path /etc/systemd/system/$SERVICE)"; fi
}
service_cmd() {
  record "systemctl $*"
  if [[ "$TEST_MODE" == 1 ]]; then
    if [[ "$ROLLBACK_PHASE" == 1 && ${FARPILOT_TEST_FAIL_ROLLBACK_RESTART:-0} == 1 && "$1" == restart ]]; then return 1; fi
    if [[ "$1" == enable && ${FARPILOT_TEST_FAIL_ENABLE:-0} == 1 ]]; then return 1; fi
    if [[ "$ROLLBACK_PHASE" == 0 && "$1" == restart && ${FARPILOT_TEST_FAIL_RESTART:-0} == 1 ]]; then return 1; fi
    if [[ "$1" == is-active && ${FARPILOT_TEST_FAIL_ACTIVE:-0} == 1 ]]; then return 1; fi
    [[ ${FARPILOT_TEST_FAIL_SYSTEMCTL:-0} != 1 ]] || return 1
  else systemctl "$@"; fi
}
reload_configs() {
  record 'systemctl daemon-reload'
  record 'systemctl reload nginx'
  record 'systemctl reload ssh'
  if [[ "$TEST_MODE" == 1 ]]; then
    [[ ${FARPILOT_TEST_FAIL_RELOAD:-0} != 1 ]]
  else
    systemctl daemon-reload && systemctl reload nginx && systemctl reload ssh
  fi
}
obtain_certificate() {
  record "certbot --nginx --non-interactive --agree-tos --email $EMAIL -d $DOMAIN"
  if [[ "$TEST_MODE" == 1 ]]; then
    [[ ${FARPILOT_TEST_FAIL_CERTBOT:-0} != 1 ]]
  else
    certbot --nginx --non-interactive --agree-tos --email "$EMAIL" -d "$DOMAIN"
  fi
}
health_check() {
  local kind=$1 url=$2
  record "health $kind $url"
  if [[ "$TEST_MODE" == 1 ]]; then
    [[ "$kind" != live || ${FARPILOT_TEST_FAIL_LIVE:-0} != 1 ]] || return 1
    [[ "$kind" != ready || ${FARPILOT_TEST_FAIL_READY:-0} != 1 ]] || return 1
  else
    curl -fsS --retry 5 --connect-timeout 5 --max-time 15 "$url" | grep -Eq '"status"[[:space:]]*:[[:space:]]*"ok"'
  fi
}

state_dir=$(root_path /var/lib/farpilot); run_dir=$(root_path /run/farpilot)
service_file=$(root_path /etc/systemd/system/farpilot-gateway.service)
sshd_file=$(root_path /etc/ssh/sshd_config.d/90-farpilot.conf)
nginx_available=$(root_path "/etc/nginx/sites-available/$DOMAIN")
nginx_enabled=$(root_path "/etc/nginx/sites-enabled/$DOMAIN")
binary=$(root_path /usr/local/bin/farpilot)
authorized_keys="$state_dir/authorized_keys"
rollback="$state_dir/farpilot.rollback"
managed_dirs=("$state_dir" "$run_dir" "$etc_dir" "$(dirname "$service_file")" "$(dirname "$sshd_file")" "$(dirname "$nginx_available")" "$(dirname "$nginx_enabled")" "$(dirname "$binary")")
for dir in "${managed_dirs[@]}"; do require_safe_dir "$dir"; done
for path in "$env_file" "$service_file" "$sshd_file" "$nginx_available" "$binary" "$authorized_keys" "$rollback"; do require_safe_file "$path"; done
link_existed=0; old_link=
if [[ -L "$nginx_enabled" ]]; then
  link_existed=1; old_link=$(readlink "$nginx_enabled")
  [[ "$old_link" == "/etc/nginx/sites-available/$DOMAIN" ]] || die "managed Nginx enabled link points outside its site: $nginx_enabled"
elif [[ -e "$nginx_enabled" ]]; then
  die "managed Nginx enabled path is unsafe: $nginx_enabled"
fi
preflight_account
run_apt
apply_account
for dir in "${managed_dirs[@]}"; do mkdir -p "$dir"; done
chmod 0700 "$state_dir" "$run_dir" "$etc_dir"
if [[ "$TEST_MODE" != 1 ]]; then chown farpilot:farpilot "$state_dir" "$run_dir" "$etc_dir"; fi
LOCK_DIR="$state_dir/install.lock"
[[ ! -L "$LOCK_DIR" ]] || die 'Gateway install lock is unsafe'
if ! mkdir "$LOCK_DIR" 2>/dev/null; then die 'another Gateway installation is in progress'; fi
LOCK_ACQUIRED=1
if [[ ! -e "$state_dir/authorized_keys" ]]; then : > "$state_dir/authorized_keys"; fi
chmod 0600 "$state_dir/authorized_keys"
if [[ "$TEST_MODE" != 1 ]]; then chown farpilot:farpilot "$state_dir/authorized_keys"; fi

fingerprint=
if [[ "$TEST_MODE" == 1 ]]; then fingerprint=${FARPILOT_TEST_FINGERPRINT:-}; fi
if [[ -z "$fingerprint" ]]; then
  host_pub=$(root_path /etc/ssh/ssh_host_ed25519_key.pub)
  [[ -f "$host_pub" && ! -L "$host_pub" ]] || die 'Ed25519 SSH host key is required'
  fingerprint=$(ssh-keygen -lf "$host_pub" -E sha256 | awk '{print $2}')
fi
[[ "$fingerprint" == SHA256:* ]] || die 'invalid SSH host fingerprint'
if ((existing == 0)); then
  cat > "$TMP/gateway.env" <<EOF
FARPILOT_DATABASE_URL=sqlite:///var/lib/farpilot/farpilot.db
FARPILOT_PUBLIC_SSH_HOST=$DOMAIN
FARPILOT_PUBLIC_SSH_PORT=22
FARPILOT_SSH_HOST_FINGERPRINT=$fingerprint
FARPILOT_CERTBOT_EMAIL=$EMAIL
EOF
  install -m 0600 "$TMP/gateway.env" "$env_file"
fi
chmod 0600 "$env_file"
if [[ "$TEST_MODE" != 1 ]]; then chown farpilot:farpilot "$env_file"; fi

cat > "$TMP/service" <<'EOF'
[Unit]
Description=FarPilot Gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=farpilot
Group=farpilot
EnvironmentFile=/etc/farpilot/gateway.env
ExecStart=/usr/local/bin/farpilot gateway serve --bind 127.0.0.1:8787 --socket /run/farpilot/gateway.sock
Restart=on-failure
RestartSec=2s
RuntimeDirectory=farpilot
RuntimeDirectoryMode=0700
StateDirectory=farpilot
StateDirectoryMode=0700
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
MemoryDenyWriteExecute=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
ReadWritePaths=/var/lib/farpilot /run/farpilot

[Install]
WantedBy=multi-user.target
EOF
cat > "$TMP/sshd" <<'EOF'
Match User farpilot
    AuthenticationMethods publickey
    PubkeyAuthentication yes
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    PermitEmptyPasswords no
    AuthorizedKeysFile /var/lib/farpilot/authorized_keys
    AllowTcpForwarding no
    AllowAgentForwarding no
    X11Forwarding no
    PermitTunnel no
    GatewayPorts no
    PermitTTY yes
EOF
tls_directives=
if ((CERT_PRESENT)); then
  printf -v tls_directives '%s\n%s\n%s' \
    '    listen 443 ssl;' \
    "    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;" \
    "    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;"
fi
cat > "$TMP/nginx" <<EOF
limit_req_zone \$binary_remote_addr zone=farpilot_pair:10m rate=5r/m;
limit_conn_zone \$binary_remote_addr zone=farpilot_conn:10m;
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
${tls_directives}
    client_max_body_size 16k;
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location = /health/live { proxy_pass http://127.0.0.1:8787; proxy_set_header Host \$host; }
    location = /health/ready { proxy_pass http://127.0.0.1:8787; proxy_set_header Host \$host; }
    location = /ws/host {
        limit_conn farpilot_conn 64;
        proxy_pass http://127.0.0.1:8787;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }
    location ~ ^/(pair/|v1/pair/) {
        limit_req zone=farpilot_pair burst=5 nodelay;
        access_log off;
        error_log /dev/null crit;
        proxy_pass http://127.0.0.1:8787;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
    location / { proxy_pass http://127.0.0.1:8787; proxy_set_header Host \$host; }
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "no-referrer" always;
    add_header Permissions-Policy "camera=(), microphone=(), geolocation=()" always;
    access_log /var/log/nginx/$DOMAIN.access.log;
    error_log /var/log/nginx/$DOMAIN.error.log;
}
EOF

# Save every prior config/link before the first candidate write.
service_existed=0; sshd_existed=0; nginx_existed=0
if [[ -e "$service_file" ]]; then cp -p "$service_file" "$TMP/service.old"; service_existed=1; fi
if [[ -e "$sshd_file" ]]; then cp -p "$sshd_file" "$TMP/sshd.old"; sshd_existed=1; fi
if [[ -e "$nginx_available" ]]; then cp -p "$nginx_available" "$TMP/nginx.old"; nginx_existed=1; fi
restore_configs() {
  if ((service_existed)); then cp -p "$TMP/service.old" "$service_file"; else rm -f "$service_file"; fi
  if ((sshd_existed)); then cp -p "$TMP/sshd.old" "$sshd_file"; else rm -f "$sshd_file"; fi
  if ((nginx_existed)); then cp -p "$TMP/nginx.old" "$nginx_available"; else rm -f "$nginx_available"; fi
  if ((link_existed)); then ln -sfn "$old_link" "$nginx_enabled"; else rm -f "$nginx_enabled"; fi
}
apply_configs() {
  install -m 0644 "$TMP/service" "$service_file" || return 1
  install -m 0644 "$TMP/sshd" "$sshd_file" || return 1
  install -m 0644 "$TMP/nginx" "$nginx_available" || return 1
  ln -sfn "/etc/nginx/sites-available/$DOMAIN" "$nginx_enabled" || return 1
}
CONFIG_TRANSACTION_ACTIVE=1
if ! apply_configs; then
  restore_configs || true
  CONFIG_TRANSACTION_ACTIVE=0
  die 'Gateway configuration activation failed; previous configuration restored'
fi
if ! validate_configs; then
  restore_configs || true
  CONFIG_TRANSACTION_ACTIVE=0
  die 'Gateway configuration validation failed'
fi
if ! reload_configs; then
  restore_configs || true
  reload_configs >/dev/null 2>&1 || true
  CONFIG_TRANSACTION_ACTIVE=0
  die 'Gateway configuration reload failed; previous configuration restored'
fi

if ((CERT_PRESENT == 0)); then
  if ! obtain_certificate; then
    restore_configs || true
    reload_configs >/dev/null 2>&1 || true
    CONFIG_TRANSACTION_ACTIVE=0
    die 'Certbot failed; previous Gateway configuration restored'
  fi
  if [[ "$TEST_MODE" != 1 && ( ! -f "$cert_fullchain" || ! -f "$cert_privkey" ) ]]; then
    restore_configs || true
    reload_configs >/dev/null 2>&1 || true
    CONFIG_TRANSACTION_ACTIVE=0
    die 'Certbot completed without a complete certificate pair'
  fi
  if ! validate_configs || ! reload_configs; then
    restore_configs || true
    reload_configs >/dev/null 2>&1 || true
    CONFIG_TRANSACTION_ACTIVE=0
    die 'final TLS configuration validation failed; previous configuration restored'
  fi
fi

BINARY_PATH="$binary"; ROLLBACK_PATH="$state_dir/farpilot.rollback"
require_safe_file "$ROLLBACK_PATH"
restore_binary() {
  if ((BINARY_ACTIVATED)); then
    if ((OLD_BINARY)) && [[ -f "$ROLLBACK_PATH" && ! -L "$ROLLBACK_PATH" ]]; then
      local restore_stage="${BINARY_PATH}.restore.$$"
      install -m 0755 "$ROLLBACK_PATH" "$restore_stage" || return 1
      mv "$restore_stage" "$BINARY_PATH" || return 1
    else
      rm -f "$BINARY_PATH" || return 1
    fi
  fi
  if [[ -n "$STAGED_BINARY" && -f "$STAGED_BINARY" && ! -L "$STAGED_BINARY" ]]; then rm -f "$STAGED_BINARY" || return 1; fi
  if ((BINARY_ACTIVATED == 0)) && [[ -f "$ROLLBACK_PATH" && ! -L "$ROLLBACK_PATH" ]]; then rm -f "$ROLLBACK_PATH" || return 1; fi
  BINARY_ACTIVATED=0
  return 0
}
rollback_before_service() {
  local message=$1 notes=
  restore_binary || notes='; binary restore failed'
  restore_configs || notes="$notes; configuration restore failed"
  reload_configs >/dev/null 2>&1 || notes="$notes; configuration reload failed"
  BINARY_TRANSACTION_ACTIVE=0; CONFIG_TRANSACTION_ACTIVE=0
  die "$message$notes"
}
BINARY_TRANSACTION_ACTIVE=1
if [[ -e "$BINARY_PATH" ]]; then
  [[ -f "$BINARY_PATH" && ! -L "$BINARY_PATH" ]] || rollback_before_service 'existing FarPilot binary is unsafe'
  if [[ "$TEST_MODE" == 1 && ${FARPILOT_TEST_FAIL_BACKUP_COPY:-0} == 1 ]]; then
    rollback_before_service 'Gateway binary backup failed'
  fi
  if ! cp -p "$BINARY_PATH" "$ROLLBACK_PATH" || ! chmod 0755 "$ROLLBACK_PATH"; then
    rollback_before_service 'Gateway binary backup failed'
  fi
  OLD_BINARY=1
fi
STAGED_BINARY="${BINARY_PATH}.staged.$$"
[[ ! -e "$STAGED_BINARY" && ! -L "$STAGED_BINARY" ]] || rollback_before_service 'staged binary path already exists'
if [[ "$TEST_MODE" == 1 && ${FARPILOT_TEST_FAIL_STAGE_INSTALL:-0} == 1 ]]; then
  rollback_before_service 'Gateway binary staging failed'
fi
if ! install -m 0755 "$downloaded" "$STAGED_BINARY"; then rollback_before_service 'Gateway binary staging failed'; fi
if [[ "$TEST_MODE" == 1 && ${FARPILOT_TEST_FAIL_ACTIVATION_MOVE:-0} == 1 ]]; then
  rollback_before_service 'Gateway binary activation failed'
fi
if ! mv "$STAGED_BINARY" "$BINARY_PATH"; then rollback_before_service 'Gateway binary activation failed'; fi
STAGED_BINARY=; BINARY_ACTIVATED=1
if ! service_cmd enable "$SERVICE" || ! service_cmd restart "$SERVICE" || ! service_cmd is-active --quiet "$SERVICE" || ! health_check live "https://$DOMAIN/health/live" || ! health_check ready "https://$DOMAIN/health/ready"; then
  original='Gateway readiness verification failed'; rollback_notes=
  restore_binary || rollback_notes='; binary restore failed'
  restore_configs || rollback_notes="$rollback_notes; configuration restore failed"
  reload_configs >/dev/null 2>&1 || rollback_notes="$rollback_notes; configuration reload failed"
  if ((OLD_BINARY)); then
    ROLLBACK_PHASE=1
    if ! service_cmd restart "$SERVICE"; then
      BINARY_TRANSACTION_ACTIVE=0; CONFIG_TRANSACTION_ACTIVE=0
      printf '  x %s; rollback restart failed%s\n' "$original" "$rollback_notes" >&2
      exit 1
    fi
    ROLLBACK_PHASE=0
  else
    service_cmd stop "$SERVICE" || true
    service_cmd disable "$SERVICE" || true
  fi
  BINARY_TRANSACTION_ACTIVE=0; CONFIG_TRANSACTION_ACTIVE=0
  die "$original; previous binary and configuration restored$rollback_notes"
fi
BINARY_TRANSACTION_ACTIVE=0; CONFIG_TRANSACTION_ACTIVE=0
if [[ -e "$ROLLBACK_PATH" ]]; then rm -f "$ROLLBACK_PATH" 2>/dev/null || warn 'installed successfully; rollback cleanup incomplete'; fi
log "FarPilot Gateway $version installed successfully for $DOMAIN"
