#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# One-time TLS certificate issuance via Let's Encrypt HTTP-01 challenge.
#
# Prerequisites (must all be true before running):
#   - DNS A records for app.<DOMAIN>, admin.<DOMAIN>, api.<DOMAIN>, <DOMAIN>
#     point at this server's public IP.
#   - Firewall allows inbound :80 from 0.0.0.0/0.
#   - deploy/.env populated with DOMAIN and CERTBOT_EMAIL set in the env.
#
# Usage:
#   CERTBOT_EMAIL=ops@example.com ./init-cert.sh
#   CERTBOT_EMAIL=ops@example.com STAGING=1 ./init-cert.sh   # dry-run first
# -----------------------------------------------------------------------------
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DEPLOY_DIR"

# shellcheck disable=SC1091
[[ -f .env ]] && set -a && source .env && set +a

: "${DOMAIN:?DOMAIN not set in .env}"
: "${CERTBOT_EMAIL:?CERTBOT_EMAIL env var not set (export it before running)}"

STAGING_FLAG=""
if [[ "${STAGING:-0}" == "1" ]]; then
  STAGING_FLAG="--staging"
  echo "==> Using Let's Encrypt STAGING environment (test certs, not trusted)"
fi

# Bring up nginx alone for the HTTP-01 challenge.
# It will fail to load the SSL server blocks until certs exist; we use a
# bootstrap config that only listens on :80.

echo "==> Writing bootstrap nginx config (HTTP-01 only)"
mkdir -p nginx/bootstrap
cat > nginx/bootstrap/default.conf <<'EOF'
server {
    listen 80 default_server;
    server_name _;
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }
    location / {
        return 200 'certbot bootstrap';
        add_header Content-Type text/plain;
    }
}
EOF

# Make sure the network and volumes exist
docker network create jinx-net 2>/dev/null || true
docker volume create jinx-certbot-www 2>/dev/null || true
docker volume create jinx-letsencrypt 2>/dev/null || true

echo "==> Starting nginx in bootstrap mode"
docker run --rm -d \
  --name jinx-nginx-bootstrap \
  --network jinx-net \
  -p 80:80 \
  -v "$(pwd)/nginx/bootstrap:/etc/nginx/conf.d:ro" \
  -v jinx-certbot-www:/var/www/certbot:ro \
  nginx:alpine

trap 'docker rm -f jinx-nginx-bootstrap >/dev/null 2>&1 || true' EXIT

echo "==> Requesting certificate for ${DOMAIN} (incl. app., admin., api.)"
docker run --rm \
  -v jinx-letsencrypt:/etc/letsencrypt \
  -v jinx-certbot-www:/var/www/certbot \
  certbot/certbot certonly \
  --webroot -w /var/www/certbot \
  --email "$CERTBOT_EMAIL" --agree-tos --no-eff-email \
  $STAGING_FLAG \
  -d "$DOMAIN" \
  -d "app.$DOMAIN" \
  -d "admin.$DOMAIN" \
  -d "api.$DOMAIN"

echo "==> Cert issued. Stopping bootstrap nginx; bring up the full stack with:"
echo "    cd ${DEPLOY_DIR} && docker compose up -d"
