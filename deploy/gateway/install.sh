#!/usr/bin/env bash
set -euo pipefail

if [[ $(id -u) -ne 0 ]]; then echo "run as root" >&2; exit 1; fi
binary=${1:?usage: install.sh /path/to/farpilot}
test -x "$binary"

id farpilot >/dev/null 2>&1 || useradd --system --home /var/lib/farpilot --shell /bin/sh farpilot
install -m 0755 "$binary" /usr/local/bin/farpilot
install -d -o farpilot -g farpilot -m 0700 /var/lib/farpilot /etc/farpilot
install -m 0600 /dev/null /var/lib/farpilot/authorized_keys
install -m 0644 "$(dirname "$0")/farpilot-gateway.service" /etc/systemd/system/farpilot-gateway.service
install -m 0644 "$(dirname "$0")/sshd_config.fragment" /etc/ssh/sshd_config.d/90-farpilot.conf

if [[ ! -f /etc/farpilot/gateway.env ]]; then
  cat > /etc/farpilot/gateway.env <<'EOF'
FARPILOT_DATABASE_URL=sqlite:///var/lib/farpilot/farpilot.db
FARPILOT_PUBLIC_SSH_HOST=CHANGE_ME
FARPILOT_PUBLIC_SSH_PORT=22
FARPILOT_SSH_HOST_FINGERPRINT=CHANGE_ME
EOF
  chown farpilot:farpilot /etc/farpilot/gateway.env
  chmod 0600 /etc/farpilot/gateway.env
fi

sshd -t
systemctl daemon-reload
echo "Edit /etc/farpilot/gateway.env, configure Caddy, then enable farpilot-gateway.service"
