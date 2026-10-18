#!/usr/bin/env bash
# YOUPI PG — one-shot installer for a free Ubuntu VM
# (Oracle Cloud Always Free, Google Cloud e2-micro, or any Ubuntu 22.04/24.04 box).
#
# Installs Node.js 22 + Caddy, deploys the gateway as a systemd service and publishes
# the five public hostnames over HTTPS (Let's Encrypt, issued automatically by Caddy).
#
# Usage (run as a sudo-capable user on the VM):
#   curl -fsSL https://raw.githubusercontent.com/thinkdigital8/YouPI-PG-gateway/main/deploy/free-vm/setup.sh | sudo bash
#   # or, with your own domain whose DNS points at this VM (see docs/FREE_HOSTING.md):
#   sudo DOMAIN=example.com bash deploy/free-vm/setup.sh
#
# Environment overrides:
#   DOMAIN        base domain (default: <public-ip>.sslip.io — free, no registration)
#   PREFIX        hostname prefix (default: pay -> pay., pay-api., pay-admin., ...)
#   REPO_URL      git repository to deploy
#   BRANCH        git branch to deploy (default: main)
#   APP_DIR       install directory (default: /opt/youpi)
#   ACME_EMAIL    email for Let's Encrypt expiry notices (optional)
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/thinkdigital8/YouPI-PG-gateway.git}"
BRANCH="${BRANCH:-main}"
APP_DIR="${APP_DIR:-/opt/youpi}"
APP_USER="youpi"
PREFIX="${PREFIX:-pay}"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31m[ERROR] %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Run as root (use sudo)."
command -v apt-get >/dev/null || die "This installer supports Ubuntu/Debian only."

log "Installing base packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl git ca-certificates gnupg debian-keyring debian-archive-keyring apt-transport-https iptables-persistent

# node:sqlite (used by packages/db) needs Node.js >= 22.5
if ! command -v node >/dev/null || [ "$(node -p 'process.versions.node.split(".")[0]')" -lt 22 ]; then
  log "Installing Node.js 22"
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get install -y nodejs
fi

if ! command -v caddy >/dev/null; then
  log "Installing Caddy (automatic HTTPS)"
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -y
  apt-get install -y caddy
fi

if [ -z "${DOMAIN:-}" ]; then
  PUBLIC_IP="$(curl -fsS4 https://api.ipify.org || curl -fsS4 https://ifconfig.me)"
  [ -n "$PUBLIC_IP" ] || die "Could not detect the public IP. Re-run with DOMAIN=<your-domain>."
  DOMAIN="${PUBLIC_IP//./-}.sslip.io"
fi
DOMAIN="$(echo "$DOMAIN" | tr 'A-Z' 'a-z' | sed -E 's#^https?://##; s#/+$##')"
log "Public base domain: $DOMAIN (prefix: $PREFIX)"

id "$APP_USER" >/dev/null 2>&1 || useradd --system --create-home --shell /usr/sbin/nologin "$APP_USER"

log "Fetching application into $APP_DIR"
if [ -d "$APP_DIR/.git" ]; then
  sudo -u "$APP_USER" git -C "$APP_DIR" fetch origin "$BRANCH"
  sudo -u "$APP_USER" git -C "$APP_DIR" checkout "$BRANCH"
  sudo -u "$APP_USER" git -C "$APP_DIR" pull --ff-only origin "$BRANCH"
else
  mkdir -p "$APP_DIR"
  chown "$APP_USER:$APP_USER" "$APP_DIR"
  sudo -u "$APP_USER" git clone --branch "$BRANCH" "$REPO_URL" "$APP_DIR"
fi

ENV_FILE="$APP_DIR/.env"
if [ ! -f "$ENV_FILE" ]; then
  log "Writing $ENV_FILE with freshly generated secrets"
  ADMIN_PASSWORD="$(node -e "console.log(require('crypto').randomBytes(12).toString('base64url'))")"
  cat > "$ENV_FILE" <<EOF
NODE_ENV=production
YOUPI_MODE=production
CLOUDFLARE_DOMAIN=$DOMAIN
DEPLOYMENT_PREFIX=$PREFIX

# Server-side calls stay on the loopback interface; browsers use the public URLs.
BASE_PAYMENT_API_URL=http://127.0.0.1:6100
BASE_CHECKOUT_URL=https://$PREFIX.$DOMAIN
COIN_STORE_PUBLIC_URL=https://$PREFIX-store.$DOMAIN

ENCRYPTION_MASTER_KEY=$(node -e "console.log(require('crypto').randomBytes(32).toString('hex'))")
JWT_SECRET=$(node -e "console.log(require('crypto').randomBytes(32).toString('hex'))")
ANDROID_ENROLLMENT_SECRET=$(node -e "console.log(require('crypto').randomBytes(32).toString('hex'))")
INITIAL_ADMIN_EMAIL=admin@$DOMAIN
INITIAL_ADMIN_PASSWORD=$ADMIN_PASSWORD

GMAIL_REDIRECT_URI=https://$PREFIX-gmail.$DOMAIN/oauth/callback
EOF
  chown "$APP_USER:$APP_USER" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
else
  log "Keeping existing $ENV_FILE"
fi

log "Installing dependencies and initialising the database"
cd "$APP_DIR"
sudo -u "$APP_USER" npm ci --omit=dev --no-audit --no-fund
sudo -u "$APP_USER" npm run db:setup

log "Registering systemd service youpi.service"
cat > /etc/systemd/system/youpi.service <<EOF
[Unit]
Description=YOUPI PG payment gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$APP_USER
WorkingDirectory=$APP_DIR
ExecStart=$(command -v node) scripts/start.js
Restart=always
RestartSec=5
KillSignal=SIGTERM
TimeoutStopSec=20

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now youpi.service

log "Configuring Caddy reverse proxy"
GLOBAL_OPTS=""
[ -n "${ACME_EMAIL:-}" ] && GLOBAL_OPTS="{
	email $ACME_EMAIL
}
"
# The control center (:8090) stays private on purpose — reach it with an SSH tunnel.
cat > /etc/caddy/Caddyfile <<EOF
${GLOBAL_OPTS}$PREFIX.$DOMAIN {
	reverse_proxy 127.0.0.1:7000
}
$PREFIX-api.$DOMAIN {
	reverse_proxy 127.0.0.1:6100 {
		flush_interval -1
	}
}
$PREFIX-admin.$DOMAIN {
	reverse_proxy 127.0.0.1:6001
}
$PREFIX-gmail.$DOMAIN {
	reverse_proxy 127.0.0.1:6003
}
$PREFIX-store.$DOMAIN {
	reverse_proxy 127.0.0.1:5000
}
EOF
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
systemctl enable caddy
systemctl reload caddy || systemctl restart caddy

log "Opening ports 80/443 in the host firewall"
# Oracle Cloud Ubuntu images ship an iptables REJECT rule; insert ACCEPTs ahead of it.
for port in 80 443; do
  iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || iptables -I INPUT 5 -p tcp --dport "$port" -j ACCEPT
done
netfilter-persistent save >/dev/null 2>&1 || true
if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
  ufw allow 80/tcp && ufw allow 443/tcp
fi

log "Waiting for the gateway to come up"
for _ in $(seq 1 30); do
  curl -fsS http://127.0.0.1:6100/health >/dev/null 2>&1 && break
  sleep 2
done
curl -fsS http://127.0.0.1:6100/health >/dev/null 2>&1 || die "Gateway did not start. Check: journalctl -u youpi -n 100"

cat <<EOF

====================================================================
 YOUPI PG is live
====================================================================
 Checkout + youpi.js : https://$PREFIX.$DOMAIN/youpi.js
 Payment API         : https://$PREFIX-api.$DOMAIN/health
 Merchant Admin      : https://$PREFIX-admin.$DOMAIN
 Gmail OAuth         : https://$PREFIX-gmail.$DOMAIN
 Demo Store          : https://$PREFIX-store.$DOMAIN

 Admin credentials   : grep INITIAL_ADMIN $ENV_FILE
 Logs                : journalctl -u youpi -f
 Control Center      : ssh -L 8090:127.0.0.1:8090 <vm>  ->  http://localhost:8090

 First HTTPS request per hostname can take ~30s while certificates are issued.
 If the URLs time out, open TCP 80 and 443 in your cloud firewall
 (Oracle: VCN > Security List > Ingress Rules). See docs/FREE_HOSTING.md.
====================================================================
EOF
