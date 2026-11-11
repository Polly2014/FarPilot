#!/usr/bin/env bash
set -euxo pipefail

if [[ $(id -u) -ne 0 ]]; then
  echo "run as root" >&2
  exit 1
fi

root=$(cd "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d)
port=22222
user=farpilot
cleanup() {
  if [[ -f "$tmp/sshd.pid" ]]; then
    kill "$(cat "$tmp/sshd.pid")" 2>/dev/null || true
  fi
  userdel "$user" 2>/dev/null || true
  rm -rf "$tmp"
  rm -rf /var/lib/farpilot
  rm -f /usr/local/bin/farpilot
  rm -f /tmp/farpilot-command-injection
}
trap cleanup EXIT

cargo build --manifest-path "$root/Cargo.toml" -p farpilot-cli
install -m 0755 "$root/target/debug/farpilot" /usr/local/bin/farpilot
id "$user" >/dev/null 2>&1 || useradd -M -d /nonexistent -s /bin/sh "$user"
passwd -d "$user" >/dev/null
mkdir -p /run/sshd /var/lib/farpilot
ssh-keygen -q -t ed25519 -N '' -f "$tmp/host_key"
ssh-keygen -q -t ed25519 -N '' -f "$tmp/client_key"
device_id=device_0123456789abcdef0123456789abcdef
printf 'restrict,command="/usr/local/bin/farpilot gateway attach --device-id %s" %s FarPilot-%s\n' \
  "$device_id" "$(cat "$tmp/client_key.pub")" "$device_id" > /var/lib/farpilot/authorized_keys
chown "$user:$user" /var/lib/farpilot/authorized_keys
chmod 0600 /var/lib/farpilot/authorized_keys

cat > "$tmp/sshd_config" <<EOF
Port $port
ListenAddress 127.0.0.1
HostKey $tmp/host_key
PidFile $tmp/sshd.pid
UsePAM no
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitUserEnvironment no
LogLevel VERBOSE
StrictModes no
EOF
cat "$root/deploy/gateway/sshd_config.fragment" >> "$tmp/sshd_config"

/usr/sbin/sshd -t -f "$tmp/sshd_config"
effective=$(/usr/sbin/sshd -T -C user=$user,host=localhost,addr=127.0.0.1 -f "$tmp/sshd_config")
grep -qx 'allowtcpforwarding no' <<<"$effective"
grep -qx 'allowagentforwarding no' <<<"$effective"
grep -qx 'x11forwarding no' <<<"$effective"
grep -qx 'permituserenvironment no' <<<"$effective"
grep -qx 'gatewayports no' <<<"$effective"
grep -qx 'permittty yes' <<<"$effective"

/usr/sbin/sshd -D -e -f "$tmp/sshd_config" >"$tmp/sshd.log" 2>&1 &
sshd_pid=$!
printf '%s' "$sshd_pid" > "$tmp/sshd.pid"
for _ in $(seq 1 50); do
  if ssh-keyscan -p "$port" 127.0.0.1 >/dev/null 2>&1; then break; fi
  sleep 0.1
done

ssh_opts=(
  -i "$tmp/client_key"
  -p "$port"
  -o BatchMode=yes
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
)

set +e
output=$(ssh "${ssh_opts[@]}" "$user@127.0.0.1" 'touch /tmp/farpilot-command-injection' 2>&1)
status=$?
set -e
[[ $status -ne 0 ]]
[[ ! -e /tmp/farpilot-command-injection ]]
if grep -q 'Permission denied' <<<"$output"; then
  cat "$tmp/sshd.log" >&2
  echo "$output" >&2
  exit 1
fi
grep -q 'gateway.sock' <<<"$output"

set +e
timeout 3 ssh "${ssh_opts[@]}" -N -L 127.0.0.1:22333:127.0.0.1:22 "$user@127.0.0.1" >"$tmp/local-forward.log" 2>&1
local_status=$?
timeout 3 ssh "${ssh_opts[@]}" -N -R 127.0.0.1:22334:127.0.0.1:22 "$user@127.0.0.1" >"$tmp/remote-forward.log" 2>&1
remote_status=$?
set -e
[[ $local_status -ne 0 ]]
[[ $remote_status -ne 0 ]]
! grep -q 'Allocated port' "$tmp/remote-forward.log"

echo "FarPilot sshd restrictions verified"
