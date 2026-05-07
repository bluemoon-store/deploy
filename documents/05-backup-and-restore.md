# Backup & Restore

Postgres is the only stateful tier we own — everything else is rebuildable.
This doc covers what we back up, where it goes, and how to restore.

## What's backed up

| Data | Where | Owner |
|---|---|---|
| Postgres database | `pg_dump -Fc` of `jinx` schema, nightly | `scripts/pg-backup.sh` |
| Let's Encrypt certs | `jinx-letsencrypt` Docker volume | certbot (auto-renewed) |
| Redis state | not backed up — cache + queues are recreatable | n/a |
| User-uploaded files | Supabase Storage | Supabase (their durability) |
| Application code | Git remotes | GitHub / your Git host |
| `.env` (secrets) | **NOT** auto-backed up | you — copy securely to a password manager |

Redis isn't backed up by design: it holds caches (rebuild on demand) and Bull
queues (in-flight jobs are short-lived and idempotent). If you ever need
Redis backups for compliance, AOF files live in the `jinx-redis-data` volume
and can be `tar`-ed offline.

## Schedule

```cron
# /etc/crontab on the VPS host
0 3 * * * /opt/jinx/deploy/scripts/pg-backup.sh >> /var/log/pg-backup.log 2>&1
```

Runs at 03:00 UTC every day. Each run:

1. `docker compose exec -T postgres pg_dump -Fc -U $POSTGRES_USER -d $POSTGRES_DB`
2. Writes to `/var/backups/postgres/jinx_<YYYY-MM-DD_HHMMSS>.dump`
3. Sanity-checks size > 1 KB (otherwise errors out — likely a connection failure)
4. Deletes local files older than `BACKUP_RETENTION_DAYS` (default 14)

## On-demand backup

```bash
/opt/jinx/deploy/scripts/pg-backup.sh
```

Use this before:
- A risky migration
- A version upgrade of Postgres itself
- Any DDL you're hand-running outside the migration system
- Handing the system off to another team

## Verify backups exist

```bash
ls -lh /var/backups/postgres/
tail -20 /var/log/pg-backup.log
```

## Restore drill (do this quarterly)

The only way to know your backups work is to actually restore one. Pick the
latest dump and restore into a throwaway container:

```bash
DUMP=/var/backups/postgres/jinx_$(date +%F)*.dump
ls -lh $DUMP                             # confirm exactly one match

# spin up a disposable Postgres
docker run --rm -d --name pg-restore-test \
  -e POSTGRES_PASSWORD=test \
  postgres:16-alpine

# wait for ready
until docker exec pg-restore-test pg_isready -U postgres; do sleep 1; done

# restore
docker exec -i pg-restore-test pg_restore \
  -U postgres -d postgres --clean --if-exists --no-owner < $DUMP

# spot-check
docker exec pg-restore-test psql -U postgres -d postgres -c \
  'SELECT count(*) FROM "User";'

# clean up
docker rm -f pg-restore-test
```

If the dump fails to restore, the production backup is broken. Investigate
**immediately** — don't wait until you actually need it.

## Real restore (production has gone wrong)

This is the disaster recovery procedure. Stop the world, restore, restart.

### 1. Stop application traffic

```bash
cd /opt/jinx/deploy
docker compose stop api worker fe admin
```

Nginx stays up so users see a clean error page rather than a connection refused.
(Optionally, swap in a maintenance page in `nginx/conf.d/` and reload.)

### 2. Snapshot the current (broken) DB

Even if it's wrong, we want forensics:

```bash
./scripts/pg-backup.sh    # creates a fresh dump named with the current timestamp
```

### 3. Drop and recreate the database

```bash
# from inside Postgres — keep the role, drop the DB
docker compose exec postgres psql -U "$POSTGRES_USER" -d postgres -c \
  "DROP DATABASE IF EXISTS \"$POSTGRES_DB\" WITH (FORCE);"
docker compose exec postgres psql -U "$POSTGRES_USER" -d postgres -c \
  "CREATE DATABASE \"$POSTGRES_DB\" OWNER \"$POSTGRES_USER\";"
```

### 4. Restore the chosen dump

```bash
# pick the dump (most recent good one, NOT the one you just took in step 2)
DUMP=/var/backups/postgres/jinx_2026-05-06_030000.dump

cat $DUMP | docker compose exec -T postgres pg_restore \
  -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
  --clean --if-exists --no-owner --single-transaction
```

`--single-transaction` means the restore is all-or-nothing.

### 5. Re-run any forward migrations not in the backup

If the backup pre-dates a migration that's already in the deployed code, the
app will refuse to start until the schema is current. Run the migrator:

```bash
docker compose run --rm migrator
```

### 6. Bring the app back

```bash
docker compose up -d api worker fe admin
docker compose logs -f api worker
```

Verify:

```bash
curl -I https://api.jinx.to/health        # 200
curl -I https://app.jinx.to               # 200
```

### 7. Communicate

Restoring drops every write between the backup time and now. Whoever owns
customer comms needs to know:
- What time the restore was taken (= cutoff for lost writes)
- What's safely persisted (Supabase Storage uploads survive — they're not in pg)
- Whether any orders / payments need manual reconciliation against on-chain
  data (use Tatum to query confirmed transactions)

## Off-site backups

For true disaster recovery (host failure), local `/var/backups/postgres/` alone
is not enough because backups live on the same server. Mirror dumps to a second
location outside this host (for example: another server via `rsync`, object
storage from your VPS provider, or encrypted archives in your backup system).

## Recovering from a lost VPS host

If the host itself is gone (terminated, provider outage, disk failure):

1. Provision a fresh instance per `02-fresh-server-deployment.md`
2. Skip step 7 (first boot) — instead, before starting `api`/`worker`,
   copy your latest off-site dump to the new server and restore it:
   ```bash
   # restore (DB already exists fresh from postgres container init)
   cat /tmp/restore.dump | docker compose exec -T postgres pg_restore \
     -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists --no-owner --single-transaction
   ```
3. Run migrator (in case the dump is older than current code)
4. Start the rest

Total RTO: ~30 min if the AMI/secrets/dump are all available.

## What NOT to do

- ❌ `docker system prune --volumes` — deletes `jinx-pg-data`. Use targeted
  prunes: `docker image prune -a -f`, `docker builder prune -af`.
- ❌ Editing rows in production to "unstick" something without taking a backup
  first. **Always backup before manual SQL.**
- ❌ Restoring a dump into the live `$POSTGRES_DB` while the app is running.
  The app holds open connections; restore will fight them.
- ❌ Trusting backups you've never tested. Run the drill quarterly.
