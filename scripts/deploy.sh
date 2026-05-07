#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Production deploy on EC2.
#
# Pulls latest code in each project subdir, rebuilds images, runs migrations,
# and recreates app containers. Data containers (postgres, redis) and nginx
# are left untouched.
#
# Run from any directory:
#   /opt/jinx/deploy/scripts/deploy.sh
#
# Note: project source directories are still named bluemoon-{be,fe,admin}
# because that's the GitHub repo name. Images and runtime artifacts use
# the jinx-* prefix.
# -----------------------------------------------------------------------------
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEPLOY_DIR="${ROOT_DIR}/deploy"

echo "==> Pulling latest code"
for proj in bluemoon-be bluemoon-fe bluemoon-admin; do
  if [[ -d "${ROOT_DIR}/${proj}/.git" ]]; then
    git -C "${ROOT_DIR}/${proj}" pull --ff-only
  fi
done

cd "$DEPLOY_DIR"

if [[ ! -f .env ]]; then
  echo "ERROR: ${DEPLOY_DIR}/.env not found." >&2
  echo "       cp .env.prod.example .env && chmod 600 .env && \$EDITOR .env" >&2
  exit 1
fi
if grep -q '__CHANGE_ME__' .env; then
  echo "ERROR: ${DEPLOY_DIR}/.env still contains __CHANGE_ME__ placeholders." >&2
  exit 1
fi

# Tag images with current backend git SHA for easy rollback
TAG="$(git -C "${ROOT_DIR}/bluemoon-be" rev-parse --short HEAD 2>/dev/null || echo latest)"
export IMAGE_TAG="$TAG"

echo "==> Building images (tag: ${TAG})"
docker compose build --pull

echo "==> Running migrator"
docker compose run --rm migrator

echo "==> Recreating application containers"
docker compose up -d api worker fe admin nginx

echo "==> Pruning dangling images"
docker image prune -f

echo "==> Health"
sleep 5
docker compose ps
