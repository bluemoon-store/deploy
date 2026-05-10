# Customer Handover Guide

A non-technical overview of the jinx.to production system: what runs, where it
runs, who owns what, and what to do when something goes wrong.

## What's running

| Surface | URL | Purpose |
|---|---|---|
| Storefront | `https://jinx.to` | Customer-facing shop |
| Admin dashboard | `https://admin.jinx.to` | Operator console (orders, products, users) |
| API | `https://api.jinx.to` | Backend; not browsed directly |

All three live on a single Ubuntu VPS behind one Nginx reverse proxy with
free Let's Encrypt TLS certificates that auto-renew.

## What's where

```
VPS host (Ubuntu 24.04)
├── Nginx (TLS termination, routing by Host header)
├── jinx-fe        → jinx.to
├── jinx-admin     → admin.jinx.to
├── jinx-api       → api.jinx.to
├── jinx-worker    → background jobs (emails, crypto payment monitoring)
├── jinx-postgres  → primary database (on host volume, nightly backups)
└── jinx-redis     → cache + job queue
```

External services still in use:
- **Supabase Storage** — user uploads, public assets
- **NiceNIC** — transactional email via SMTP (mailbox-style host, no delivery webhooks)
- **Tatum** — blockchain RPC for crypto payments
- **Sentry** *(optional)* — error tracking

## Domains & DNS

DNS is managed in the registrar's control panel (record the registrar in your
ops doc). Four A records all point at the VPS public IP:

- `jinx.to` → public IP
- `www.jinx.to` → public IP (301-redirects to `jinx.to`)
- `admin.jinx.to` → public IP
- `api.jinx.to` → public IP

If the server public IP ever changes, update all four.

## Logging in

| Account | Where | Default |
|---|---|---|
| Server SSH | `ssh ubuntu@<SERVER_IP>` (key-based, no password) | provisioning-time SSH key |
| Admin dashboard | `https://admin.jinx.to/login` | `SEED_ADMIN_EMAIL` from `.env` |

The admin password is set during the first deploy via `SEED_ADMIN_PASSWORD` in
`/opt/jinx/deploy/.env`. Change it from the dashboard after first login.

## Routine operations

These run automatically — no human action needed:

- **Database backups** — nightly at 03:00 UTC. Files in `/var/backups/postgres/`,
  retained for `BACKUP_RETENTION_DAYS` (default 14).
- **TLS renewal** — certbot runs twice daily (03:17, 15:17 UTC) via cron. Certs
  are renewed automatically when they have <30 days left.
- **Container restart** — every container has `restart: unless-stopped`, so
  Docker brings them back after host reboot, OOM, or crash.

## Something is wrong — what now?

| Symptom | First thing to check |
|---|---|
| "Site is down" (any subdomain) | SSH in, run `docker compose ps` in `/opt/jinx/deploy` — every container should be `(healthy)`. Restart any that aren't. |
| "Browser says cert is invalid" | `docker compose exec nginx nginx -t`; check certbot logs at `/var/log/certbot-renew.log`. See *operations* doc for re-issuance. |
| "Orders aren't sending email" | Worker container is the email processor. `docker compose logs worker \| grep -i email`. Verify `SMTP_HOST`/`SMTP_USER`/`SMTP_PASSWORD` in `.env`, that the sender mailbox exists on NiceNIC, and that SPF/DKIM/DMARC are published for the sending domain. Also check the Bull `failed` set for stuck jobs (`email_queue` retries 5× with exponential backoff before failing). |
| "Crypto payment not confirming" | Worker logs again. Check Tatum API quota and `TATUM_API_KEY`. |
| "Database is slow" | See the *operations* doc → Postgres section. |

For step-by-step procedures, see `04-operations-inspection.md` in this folder.

## What's NOT in scope of this stack

These are intentionally outside the VPS box and require their own runbooks:

- DNS / domain registrar
- Supabase project (storage buckets, dashboard access)
- NiceNIC mailbox account (sending mailbox, per-mailbox send quota, DKIM key issued by NiceNIC, SPF/DMARC published on the sending domain)
- Tatum / Kraken API accounts
- VPS provider account (billing and server console)
External SaaS (Supabase, NiceNIC, Tatum, Sentry) bills separately.

### Email DNS records (publish on the sending domain)

The NiceNIC mailbox host signs and relays mail, but the receiving domain owner
(you) must publish these DNS records on the sending domain (e.g. `jinx.to`,
`rom-consult.com`) for Gmail / Outlook / Yahoo to accept the mail:

- **SPF** — `TXT @ "v=spf1 include:<host given by NiceNIC> -all"` (replace any
  prior `include:sendpulse.com`).
- **DKIM** — publish the selector + public key from the NiceNIC control panel
  (typical record name: `<selector>._domainkey`).
- **DMARC** — `TXT _dmarc "v=DMARC1; p=none; rua=mailto:dmarc@<domain>"` to
  start; tighten to `p=quarantine` after a week of clean reports.

Verify with `dig TXT <domain>`, `dig TXT <selector>._domainkey.<domain>`,
`dig TXT _dmarc.<domain>` and an external checker (mxtoolbox / mail-tester).

## Handover checklist

When transferring ownership of this system, hand over:

- [ ] VPS provider account access
- [ ] Server SSH key
- [ ] Domain registrar credentials
- [ ] Supabase project access
- [ ] NiceNIC mailbox credentials, Tatum, Kraken, Sentry accounts
- [ ] Git repo access for `jinx-be`, `jinx-fe`, `jinx-admin`, `deploy`
- [ ] Contents of `/opt/jinx/deploy/.env` (transferred securely — encrypted file or password manager, never email/Slack)
- [ ] Most recent Postgres dump (`/var/backups/postgres/jinx_*.dump`)
