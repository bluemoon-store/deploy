#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Renew Let's Encrypt certificates and reload nginx.
#
# Schedule from host crontab (twice a day is the certbot recommendation):
#   17 3,15 * * * /opt/jinx/deploy/scripts/renew-cert.sh >> /var/log/certbot-renew.log 2>&1
# -----------------------------------------------------------------------------
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DEPLOY_DIR"

echo "[$(date -Is)] renewing certs"
docker run --rm \
  -v jinx-letsencrypt:/etc/letsencrypt \
  -v jinx-certbot-www:/var/www/certbot \
  certbot/certbot renew --webroot -w /var/www/certbot --quiet

# Reload nginx if it's running (renew is no-op if no certs are due)
if docker ps --format '{{.Names}}' | grep -q '^jinx-nginx$'; then
  docker exec jinx-nginx nginx -s reload
fi

echo "[$(date -Is)] renew complete"
