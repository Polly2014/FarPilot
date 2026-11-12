#!/usr/bin/env bash
set -euo pipefail

if [[ $(id -u) -ne 0 ]]; then echo "run as root" >&2; exit 1; fi
binary=${1:?usage: install.sh /path/to/farpilot}
test -x "$binary"

id farpilot >/dev/null 2>&1 || useradd --system --home /var/lib/farpilot --shell /bin/sh farpilot
install -m 0755 "$binary" /usr/local/bin/farpilot
install -d -o farpilot -g farpilot -m 0700 /var/lib/farpilot /etc/farpilot
if [[ ! -f /var/lib/farpilot/authorized_keys ]]; then
  install -o farpilot -g farpilot -m 0600 /dev/null /var/lib/farpilot/authorized_keys
fi
install -m 0644 "$(dirname "$0")/farpilot-gateway.service" /etc/systemd/system/farpilot-gateway.service
install -m 0644 "$(dirname "$0")/sshd_config.fragment" /etc/ssh/sshd_config.d/90-farpilot.conf
if [[ ! -f /etc/nginx/sites-available/farpilot.polly.wang ]]; then
  install -m 0644 "$(dirname "$0")/farpilot.polly.wang.nginx" /etc/nginx/sites-available/farpilot.polly.wang
fi
ln -sfn /etc/nginx/sites-available/farpilot.polly.wang /etc/nginx/sites-enabled/farpilot.polly.wang

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
nginx -t
systemctl daemon-reload
systemctl reload nginx
echo "Edit /etc/farpilot/gateway.env, run certbot --nginx -d farpilot.polly.wang, then enable farpilot-gateway.service"
