#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Nightly Postgres backup.
#
# Dumps the postgres container's database to /var/backups/postgres, prunes
# files older than $BACKUP_RETENTION_DAYS, and (optionally) uploads to S3.
#
# Schedule from host crontab:
#   0 3 * * * /opt/jinx/deploy/scripts/pg-backup.sh >> /var/log/pg-backup.log 2>&1
# -----------------------------------------------------------------------------
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DEPLOY_DIR"

# shellcheck disable=SC1091
[[ -f .env.prod ]] && set -a && source .env.prod && set +a

BACKUP_DIR="${BACKUP_DIR:-/var/backups/postgres}"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-14}"
TS="$(date +%Y-%m-%d_%H%M%S)"
DUMP_FILE="${BACKUP_DIR}/jinx_${TS}.dump"

mkdir -p "$BACKUP_DIR"

echo "[$(date -Is)] dumping ${POSTGRES_DB:-jinx} → ${DUMP_FILE}"
docker compose exec -T postgres pg_dump \
  -U "${POSTGRES_USER:-jinx}" \
  -d "${POSTGRES_DB:-jinx}" \
  -Fc \
  --no-owner \
  > "$DUMP_FILE"

# Sanity-check size
size=$(stat -c%s "$DUMP_FILE" 2>/dev/null || stat -f%z "$DUMP_FILE")
if (( size < 1024 )); then
  echo "ERROR: dump file is suspiciously small (${size} bytes)" >&2
  exit 1
fi

# Optional S3 upload
if [[ -n "${BACKUP_S3_BUCKET:-}" ]]; then
  echo "[$(date -Is)] uploading to s3://${BACKUP_S3_BUCKET}/postgres/"
  aws s3 cp "$DUMP_FILE" "s3://${BACKUP_S3_BUCKET}/postgres/$(basename "$DUMP_FILE")" \
    --storage-class STANDARD_IA
fi

# Prune local
find "$BACKUP_DIR" -type f -name 'jinx_*.dump' -mtime "+${RETENTION_DAYS}" -delete

echo "[$(date -Is)] backup complete (${size} bytes)"
