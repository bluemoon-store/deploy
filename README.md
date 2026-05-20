# jinx.to — `deploy`

Production deployment for the jinx.to stack. One Docker Compose file owns the
whole runtime: Postgres, Redis, the NestJS API + worker, the Next.js storefront,
the Next.js admin, and an Nginx reverse proxy with Let's Encrypt TLS.

## Layout

```
/opt/jinx/                            ← install root on the VPS host
├── jinx-be/        (sibling repo, NestJS API + workers)
├── jinx-fe/        (sibling repo, Next.js storefront)
├── jinx-admin/     (sibling repo, Next.js admin)
└── deploy/         ← this repo
    ├── docker-compose.yml
    ├── .env.prod.example     committed template
    ├── .env                  populated on the host (gitignored)
    ├── nginx/
    │   ├── nginx.conf
    │   └── conf.d/*.conf.template   ${DOMAIN} substituted at boot
    ├── certbot/init-cert.sh         one-time TLS issuance
    ├── scripts/
    │   ├── deploy.sh                pull + build + migrate + recreate
    │   ├── pg-backup.sh             nightly Postgres dump
    │   └── renew-cert.sh            twice-daily certbot renew
    └── documents/                   operational runbooks (read these)
```

## Architecture

```
                    Internet :443
                         │
                  ┌──────▼──────┐
                  │   Nginx     │  TLS / routing by Host header
                  └──┬──┬──┬────┘
            jinx.to  │  │  │  api.jinx.to
                     │  │  │
              ┌──────▼┐ │ ┌▼──────────┐
              │  fe   │ │ │   api     │  APP_ROLE=api
              │ :3000 │ │ │ :3001     │
              └───────┘ │ └─────┬─────┘
        admin.jinx.to   │       │
              ┌─────────▼┐    ┌─▼──────────┐
              │ admin    │    │  worker    │  APP_ROLE=worker
              │ :3002    │    │ Bull jobs  │  (same image as api)
              └──────────┘    │  + crons   │
                              └──┬─────────┘
                                 │
                  ┌──────────────┼──────────────┐
                  │              │              │
            ┌─────▼────┐  ┌──────▼─────┐  ┌─────▼──────────┐
            │ Postgres │  │   Redis    │  │ Supabase       │
            │ host vol │  │ AOF vol    │  │ Storage (ext.) │
            └──────────┘  └────────────┘  └────────────────┘
```

API and worker share one image; the boot path branches on `APP_ROLE`. Bull
processors and `@Cron` schedulers only register when `APP_ROLE=worker` (or
unset, for local dev) — see `jinx-be/src/common/utils/role.util.ts`.

## Documentation

The `documents/` folder is the runbook set. Read them in order if you're new:

1. `01-customer-handover.md` — non-technical overview, accounts, "what's running"
2. `02-fresh-server-deployment.md` — bare VPS host → live in ~60 min
3. `03-feature-rollout.md` — re-deploy on commits, rollback
4. `04-operations-inspection.md` — logs, networking, queues, Postgres, Redis
5. `05-backup-and-restore.md` — backup schedule, restore drill, DR

## Quick reference

| Task | Command (run from `/opt/jinx/deploy`) |
|---|---|
| Deploy latest commits | `./scripts/deploy.sh` |
| One-off backup | `./scripts/pg-backup.sh` |
| Tail logs | `docker compose logs -f api worker` |
| Health | `docker compose ps` |
| Open psql | `docker compose exec postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"` |
| Open redis-cli | `docker compose exec redis redis-cli -a "$REDIS_PASSWORD"` |
| Reload nginx | `docker compose exec nginx nginx -s reload` |
| Re-issue TLS | `CERTBOT_EMAIL=… ./certbot/init-cert.sh` |
| Seed admin user | `docker compose exec -e CLI_PATH=./dist/cli.js api yarn seed:admin` |
| Seed crypto wallet indexes | `docker compose exec -e CLI_PATH=./dist/cli.js api yarn seed:crypto-wallets` |

## What's intentionally NOT in this repo

- The three application repos (`jinx-be`, `jinx-fe`, `jinx-admin`) — pulled
  separately as siblings.
- Real `.env` — populated on the host only, gitignored, `chmod 600`.
- Persistent data (`pg_data`, `redis_data`, `letsencrypt`, `certbot_www`) —
  Docker named volumes, separate from the repo.
