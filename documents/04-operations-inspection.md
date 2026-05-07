# Operations: Inspecting the Running System

Quick-reference for SSH'ing in and answering "what's it doing right now?"

All commands assume `cd /opt/jinx/deploy` first.

## At-a-glance health

```bash
docker compose ps
```

Every long-running service should be `running (healthy)`:

```
NAME            STATUS
jinx-postgres   running (healthy)
jinx-redis      running (healthy)
jinx-api        running (healthy)
jinx-worker     running
jinx-fe         running (healthy)
jinx-admin      running (healthy)
jinx-nginx      running
```

`jinx-worker` doesn't expose a health endpoint — its liveness is inferred from
queue throughput (see *Queues* below).

## Logs

### Tail everything

```bash
docker compose logs -f --tail=100
```

### Per-service

```bash
docker compose logs -f api
docker compose logs -f worker
docker compose logs -f fe
docker compose logs -f admin
docker compose logs -f nginx
docker compose logs -f postgres
docker compose logs -f redis
```

### Filter

```bash
# only errors from the API in the last hour
docker compose logs --since 1h api | grep -iE 'error|exception|fatal'

# crypto payment monitor
docker compose logs --since 6h worker | grep -i payment

# slow queries (Postgres logs slow queries when log_min_duration_statement is set)
docker compose logs postgres | grep -i 'duration:'
```

### Log rotation

All services use the `json-file` driver capped at **10 MB × 3 files** per
container. No manual rotation needed; old chunks are auto-deleted.

To inspect raw log files:

```bash
sudo ls -lh /var/lib/docker/containers/*/[!-]*.log
```

## Networking

### Container-to-container DNS

Services resolve each other by service name on the `jinx-net` bridge:
`postgres`, `redis`, `api`, `fe`, `admin`, `nginx`. From inside any container:

```bash
docker compose exec api ping -c1 postgres
docker compose exec api wget -qO- http://api:3001/health
```

### Inspect the bridge network

```bash
docker network inspect jinx-net
# shows IPAM, attached containers, IPs
```

### What's listening on the host?

```bash
sudo ss -tlnp
# you should see ONLY :80 and :443 from docker-proxy
# nothing else (5432/6379/3000/3001/3002 are intentionally container-only)
```

If you need to expose Postgres for an emergency external client (e.g. for a
restore drill), do it via SSH tunnel — never publish the port in the host firewall:

```bash
# from your laptop
ssh -L 5432:localhost:5432 ubuntu@<SERVER_IP>
docker compose exec postgres pg_isready
```

### Nginx upstreams

```bash
docker compose exec nginx nginx -t           # config syntax
docker compose exec nginx nginx -s reload    # graceful reload
docker compose exec nginx cat /etc/nginx/conf.d/api.conf   # rendered (post-envsubst) config
```

If certificate paths look wrong, `nginx -t` is the first thing to run; it
prints exactly what it tried to load.

## Performance

### Host metrics

```bash
htop                # CPU / memory by process
df -h               # disk
free -h             # memory
iostat -xz 2 5      # disk IO over 5 samples
```

### Per-container

```bash
docker stats --no-stream
# CPU%, MEM USAGE, NET I/O, BLOCK I/O per container
```

For continuous monitoring:

```bash
docker stats        # live
```

### What's eating CPU inside a container?

```bash
docker compose exec api sh -c 'top -bn1 | head -20'
```

For the API/worker (Node), get a flame graph or use `--inspect`:

```bash
docker compose exec api node --inspect=0.0.0.0:9229 dist/main &
ssh -L 9229:localhost:9229 ubuntu@<SERVER_IP>
# then chrome://inspect on your laptop
```

## Queues (Bull / Redis)

Bull queues are the worker's job source. Bull Board is intentionally **disabled
in production** — inspect queues via `redis-cli`:

```bash
docker compose exec redis redis-cli -a "$REDIS_PASSWORD"
```

Inside the prompt:

```
KEYS bull:*               # list all queue keys
LLEN bull:email:wait      # jobs waiting in 'email' queue
LLEN bull:email:active    # jobs actively processing
LLEN bull:email:failed    # failed jobs
LRANGE bull:email:failed 0 5    # peek at first 5 failures
```

Queue names in this stack:
- `email`
- `notification`
- `activity-log`
- `crypto-payment-verification`
- `crypto-payment-forwarding`

### Wake / drain workers

If queues are backing up:

```bash
docker compose logs --tail=200 worker | grep -iE 'error|stuck|stalled'
docker compose restart worker
```

Bull will redeliver stalled jobs automatically (configured via Bull's
`stalledInterval`).

### Drain a single queue (last resort)

```bash
docker compose exec redis redis-cli -a "$REDIS_PASSWORD" DEL bull:email:wait
```

Only do this with explicit consent — you're discarding pending jobs.

## Redis

```bash
docker compose exec redis redis-cli -a "$REDIS_PASSWORD" INFO memory
docker compose exec redis redis-cli -a "$REDIS_PASSWORD" INFO clients
docker compose exec redis redis-cli -a "$REDIS_PASSWORD" DBSIZE
docker compose exec redis redis-cli -a "$REDIS_PASSWORD" --bigkeys
```

The container is configured with `maxmemory 512mb` and `allkeys-lru` eviction —
if memory pressure hits, Redis evicts least-recently-used keys (cache only;
Bull queue keys won't be evicted because they're being touched).

To check eviction rate:

```bash
docker compose exec redis redis-cli -a "$REDIS_PASSWORD" INFO stats | grep evicted
```

## Postgres

### Open a psql shell

```bash
docker compose exec postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"
```

(Variables are expanded by your shell from the host's `.env` if you've
sourced it — otherwise hard-code values.)

### Connection counts

```sql
SELECT count(*), state
FROM pg_stat_activity
WHERE datname = current_database()
GROUP BY state;
```

### Slow / running queries

```sql
SELECT pid, now() - query_start AS runtime, state, left(query, 80)
FROM pg_stat_activity
WHERE state != 'idle'
ORDER BY runtime DESC NULLS LAST;
```

Cancel a runaway query:

```sql
SELECT pg_cancel_backend(<pid>);     -- polite
SELECT pg_terminate_backend(<pid>);  -- forceful
```

### Table sizes

```sql
SELECT
  schemaname || '.' || tablename AS table,
  pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS total
FROM pg_tables
WHERE schemaname NOT IN ('pg_catalog','information_schema')
ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC
LIMIT 20;
```

### Index usage

```sql
SELECT relname, idx_scan, seq_scan,
       round(100.0 * idx_scan / NULLIF(idx_scan + seq_scan, 0), 1) AS idx_pct
FROM pg_stat_user_tables
ORDER BY seq_scan DESC
LIMIT 20;
```

Tables with high `seq_scan` and low `idx_pct` are missing an index.

### Migrations history

```sql
SELECT migration_name, finished_at
FROM _prisma_migrations
ORDER BY finished_at DESC
LIMIT 10;
```

### One-off SQL from the host

```bash
docker compose exec -T postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
  -c "SELECT count(*) FROM \"Order\" WHERE \"createdAt\" > now() - interval '1 day';"
```

## Disk pressure

### Top space consumers

```bash
sudo du -h --max-depth=1 /var | sort -h
sudo du -h --max-depth=1 /var/lib/docker | sort -h
```

### Reclaim Docker space

```bash
docker system df                      # what's using space
docker image prune -a -f              # remove unused images (keep running)
docker volume ls                      # list — DO NOT prune blindly, pg_data lives here
docker builder prune -af              # build cache (safe to wipe)
```

> Never run `docker system prune --volumes` — it would delete `jinx-pg-data`.

### Postgres data growth

```bash
sudo du -sh /var/lib/docker/volumes/jinx-pg-data
```

If this is climbing fast, candidates are: the activity log table (oldest rows
should be archived), and unbounded crypto-payment-verification job logs.

## Reboot recovery

Containers have `restart: unless-stopped`, so after `sudo reboot`:

1. Docker daemon starts (`systemd`)
2. All containers come up in order (compose `depends_on` honored)
3. Cron jobs (backups, certbot renew) resume automatically

Verify after a reboot:

```bash
cd /opt/jinx/deploy && docker compose ps
curl -I https://api.jinx.to/health
```

## Investigating a 502 or 504

1. `docker compose ps` — is `api` `(healthy)`?
2. `docker compose logs --tail=200 api` — last requests, any panics
3. `docker compose logs --tail=200 nginx` — upstream errors, timeouts
4. `docker compose exec nginx wget -qO- http://api:3001/health` — direct
   container-to-container check, bypasses TLS

Most 502s are: API container restarting (Sentry catch-up after a panic),
DB connection pool exhausted, or a regression that's looping on startup.
