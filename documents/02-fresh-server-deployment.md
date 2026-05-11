# Fresh Server Deployment

End-to-end walkthrough: bare VPS host → fully running production. Allow
~60 minutes for a first run.

## 1. Provision the VPS host

| Setting | Value |
|---|---|
| AMI | Ubuntu 24.04 LTS (x86_64) |
| Host size | 2 vCPU, 8 GB RAM (or higher) |
| Storage | 60 GB SSD root volume |
| Firewall inbound | `22` from your IP, `80` and `443` from `0.0.0.0/0` |
| Static IP | recommended (so DNS doesn't break on reboot/redeploy) |

## 2. DNS

Point four A records (TTL 300) at the server public IP, **before** running certbot:

```
jinx.to         A  <SERVER_IP>
www.jinx.to     A  <SERVER_IP>
admin.jinx.to   A  <SERVER_IP>
api.jinx.to     A  <SERVER_IP>
```

Wait until `dig +short jinx.to` returns the server IP from a remote machine.

## 3. Bootstrap the host (one-time)

SSH in as `ubuntu`:

```bash
# system updates
sudo apt update && sudo apt -y upgrade
sudo apt -y install ca-certificates curl gnupg ufw fail2ban git

# Docker (official repo — gives you compose v2)
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
  sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt update
sudo apt -y install docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker
sudo usermod -aG docker ubuntu
newgrp docker

# firewall
sudo ufw allow 22 && sudo ufw allow 80 && sudo ufw allow 443
sudo ufw --force enable

# install dir
sudo mkdir -p /opt/jinx && sudo chown ubuntu:ubuntu /opt/jinx
```

## 4. Clone the four repos

The `deploy/` repo references the three project repos by relative path
(`../jinx-be`, `../jinx-fe`, `../jinx-admin`), so they must be siblings under
`/opt/jinx/`.

```bash
cd /opt/jinx
git clone <git-remote>:<org>/jinx-be.git
git clone <git-remote>:<org>/jinx-fe.git
git clone <git-remote>:<org>/jinx-admin.git
git clone <git-remote>:<org>/deploy.git
```

## 5. Create `.env`

`.env` is the **single source of truth** for runtime configuration. It is
gitignored and lives only on the host.

```bash
cd /opt/jinx/deploy
cp .env.prod.example .env
chmod 600 .env
${EDITOR:-vim} .env
```

Fill in **every** `__CHANGE_ME__`. Generate strong values:

```bash
# 32-byte random secrets (JWT, WALLET_ENCRYPTION_KEY)
openssl rand -base64 32

# fresh BIP39 mnemonics (one per chain)
docker run --rm -it --entrypoint /bin/sh node:20-alpine -c \
  'npx --yes bip39-cli generate'

# strong passwords (POSTGRES_PASSWORD, REDIS_PASSWORD, SEED_ADMIN_PASSWORD)
openssl rand -base64 24 | tr -d '/+=' | cut -c1-32
```

Required keys (anything else is optional):

- `DOMAIN` — e.g. `jinx.to`
- `NEXT_PUBLIC_*` — public URLs (`https://jinx.to`, `https://api.jinx.to/v1`, etc.)
- `CENTRAL_LICENSE_KEY` — required at Docker build for `jinx-fe` and `jinx-admin` (`npm ci` / `@central-icons-react`)
- `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`
- `DATABASE_URL` — must encode the password from `POSTGRES_PASSWORD` and use the service hostname `postgres`
- `REDIS_PASSWORD`
- `AUTH_ACCESS_TOKEN_SECRET`, `AUTH_REFRESH_TOKEN_SECRET`
- `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`
- `RESEND_API_KEY`, `RESEND_FROM_EMAIL`, `RESEND_FROM_NAME`
- `TATUM_API_KEY`
- All five `SYSTEM_MNEMONIC_*`
- `HOT_WALLET_ETH_PRIVATE_KEY`, `WALLET_ENCRYPTION_KEY`
- `SEED_ADMIN_EMAIL`, `SEED_ADMIN_PASSWORD`
- `APP_ENV=production`

The deploy script refuses to run if any `__CHANGE_ME__` is left.

## 6. Issue TLS certificates

> Run **staging first** — Let's Encrypt has aggressive rate limits on the
> production endpoint. Staging certs are not browser-trusted but prove the
> pipeline works.

```bash
cd /opt/jinx/deploy
CERTBOT_EMAIL=ops@jinx.to STAGING=1 ./certbot/init-cert.sh
```

If that succeeded, **delete the staging cert** and re-run for real:

```bash
docker compose run --rm --entrypoint certbot certbot delete --cert-name jinx.to
CERTBOT_EMAIL=ops@jinx.to ./certbot/init-cert.sh
```

> **Why `--entrypoint certbot`?** The `certbot` service in `docker-compose.yml`
> uses a `sh -c` entrypoint to keep the container alive for renewals; without
> the override, the shell consumes `delete` as if it were a shell builtin and
> errors with `delete: not found`.

Verify you got production certs (issuer should NOT contain "STAGING"):

```bash
openssl s_client -connect api.jinx.to:443 -servername api.jinx.to </dev/null \
  | grep -E "issuer=|Verify return"
```

## 7. First boot

```bash
cd /opt/jinx/deploy

# data tier first
docker compose up -d postgres redis
docker compose ps   # both must reach (healthy) within ~30s

# migrations (one-shot; exits 0 on success)
docker compose run --rm migrator

# the rest — this also builds images first time
docker compose up -d --build

# follow boot logs
docker compose logs -f api worker fe admin nginx
```

You should see, in order:
- `api`: `Server running on: http://[::1]:3001`
- `worker`: `Worker process started — listening for queue jobs`
- `nginx`: starts cleanly, no `ssl_certificate ... cannot load` errors

## 8. Seed initial data

The production image is `dist/` only (no `src/`), so `nestjs-command` needs the
compiled CLI path:

```bash
docker compose exec -e CLI_PATH=./dist/cli.js api yarn seed:admin
docker compose exec -e CLI_PATH=./dist/cli.js api yarn seed:products
# or everything:
docker compose exec -e CLI_PATH=./dist/cli.js api yarn seed:all
```

## 9. Verify

```bash
# DNS + TLS
curl -I https://api.jinx.to/health        # → 200
curl -I https://jinx.to                   # → 200
curl -I https://www.jinx.to               # → 301 → https://jinx.to
curl -I https://admin.jinx.to             # → 200

# Bull Board NOT exposed in prod
curl -I https://api.jinx.to/admin/queues  # → 404

# internal services not exposed
nmap -p 3000,3001,3002,5432,6379 <SERVER_IP>    # all closed/filtered
```

In the browser:
- `https://jinx.to` — storefront renders, products visible (validates FE→BE→DB chain)
- `https://admin.jinx.to/login` — sign in with `SEED_ADMIN_EMAIL` / `SEED_ADMIN_PASSWORD`

## 10. Schedule cron jobs

```bash
crontab -e
```

Add:

```cron
# nightly Postgres dump
0 3 * * * /opt/jinx/deploy/scripts/pg-backup.sh >> /var/log/pg-backup.log 2>&1

# Let's Encrypt renewal — twice daily per certbot guidance
17 3,15 * * * /opt/jinx/deploy/scripts/renew-cert.sh >> /var/log/certbot-renew.log 2>&1
```

Pre-create the log files so cron doesn't fail on permissions:

```bash
sudo touch /var/log/pg-backup.log /var/log/certbot-renew.log
sudo chown ubuntu:ubuntu /var/log/pg-backup.log /var/log/certbot-renew.log
```

## Known first-run gotchas

These all came up during the actual rollout — keep this list as a checklist:

| Symptom | Fix |
|---|---|
| `network jinx-net was found but has incorrect label` | `docker compose down && docker network rm jinx-net && docker compose up -d` |
| `path "/opt/jinx/bluemoon-be" not found` | `x-be-build.context` must match the on-disk repo dir name (`../jinx-be`) |
| `Central Icons license key is not set` during FE or admin image build | `CENTRAL_LICENSE_KEY` in `deploy/.env` and build `ARG` in `jinx-fe` / `jinx-admin` Dockerfiles (compose passes it for both) |
| `Your lockfile needs to be updated, but yarn was run with --frozen-lockfile` | `jinx-fe`/`jinx-admin` use **npm**; their Dockerfile must check `package-lock.json` before `yarn.lock`. If both are present, delete `yarn.lock` |
| `Not found file: /app/src/cli.ts` when seeding | Add `-e CLI_PATH=./dist/cli.js` to `docker compose exec` for any `nestjs-command` invocation |
| Browser says "certificate not trusted" | Issuer contains `(STAGING)` — re-issue without `STAGING=1` (see step 6) |
| `--cert-name: line 0: delete: not found` | Use `--entrypoint certbot` flag, not `--rm certbot delete ...` (the service entrypoint is `sh -c`) |
| `volume "jinx-letsencrypt" already exists but was not created by Docker Compose` | Cosmetic warning; safe to ignore |
