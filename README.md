Deploy Bluemoon Stack to EC2

 Context

 The repo has three projects — bluemoon-be (NestJS + Prisma + Bull workers), bluemoon-fe (Next.js 16 SSR storefront),
 bluemoon-admin (Next.js 16 SSR dashboard) — currently developed locally. Goal: ship them to a single EC2 instance with a
 maintainable, version-controlled deployment that can be reproduced with git pull && docker compose up -d --build.

 User-confirmed topology: single EC2 + Docker Compose + self-hosted Postgres on EBS + Supabase Storage retained + Nginx (in
 Docker) + Let's Encrypt, with three subdomains:
 - api.<domain> → backend (:3001)
 - app.<domain> → storefront (:3000)
 - admin.<domain> → admin (:3002)

 The backend already has a working Dockerfile and a docker-compose.yml (Postgres + Redis + app); both will be reworked into a
 root-level production stack. Frontend and admin have no Dockerfile yet.

 Critical pre-flight: rotate committed secrets

 bluemoon-be/.env is committed and contains live Supabase service-role key, Resend API key, JWT signing secrets, crypto wallet
 mnemonics, and a hot-wallet ETH private key. Treat all of these as compromised. Before deployment:
 1. Rotate Supabase service-role key, Resend key, JWT access/refresh secrets, WALLET_ENCRYPTION_KEY.
 2. Generate fresh BIP39 mnemonics for any production crypto wallet (sweep funds off the leaked addresses first if any are in
 use).
 3. Add .env, .env.production, .env.local to .gitignore and git rm --cached them.
 4. Rewrite git history with git-filter-repo to purge the leaked values, force-push, invalidate any clones.

 Target Architecture

                          Internet  :443
                             │
                   ┌─────────▼──────────┐
                   │  Nginx (Docker)    │  TLS via Let's Encrypt
                   │  reverse proxy     │  certbot sidecar renews
                   └──┬────┬─────────┬──┘
        app.domain.com │    │ admin.  │ api.domain.com
                       │    │         │
       ┌───────────────▼┐  ┌▼────────┐ ┌▼──────────────┐
       │ bluemoon-fe    │  │ admin   │ │ bluemoon-be   │
       │ Next.js :3000  │  │ :3002   │ │ NestJS :3001  │  APP_ROLE=api
       └────────────────┘  └─────────┘ └───┬───────────┘
                                           │
                                   ┌───────▼────────┐
                                   │ bluemoon-be    │  APP_ROLE=worker
                                   │ Bull processors│  (same image)
                                   │ + cron jobs    │
                                   └───────┬────────┘
                                           │
                        ┌──────────────────┼──────────────────┐
                        │                  │                  │
               ┌────────▼────────┐ ┌───────▼───────┐ ┌────────▼────────┐
               │ Postgres 16     │ │ Redis 7       │ │ Supabase Storage│
               │ EBS volume      │ │ AOF on volume │ │ (external)      │
               │ nightly pg_dump │ │               │ │                 │
               └─────────────────┘ └───────────────┘ └─────────────────┘

 Key design decisions (from review):
 - Workers split from API: same image, two containers, gated by APP_ROLE env (api vs worker). API runs app.listen(); worker
 registers Bull processors and cron schedulers. Avoids HTTP latency spikes when a crypto-payment job hangs.
 - Migrations: one-shot migrator compose service runs prisma migrate deploy, with api and worker using depends_on: { migrator:
 { condition: service_completed_successfully } }.
 - Secrets: AWS SSM Parameter Store (SecureString) under /bluemoon/prod/*. EC2 instance profile grants ssm:GetParametersByPath.
  An entrypoint script materializes a tmpfs .env at container start; nothing on disk, nothing in the AMI snapshot.
 - Nginx in Docker: app ports stay off the host; one compose file owns everything; certbot sidecar handles renewals.

 Repo Changes

 1. New root-level deploy/ directory

 Create /Users/beiryu/Development/Echodzns/bluemoon/deploy/ containing the production stack:

 deploy/
 ├── docker-compose.yml         # full stack
 ├── .env.template              # documents required env (no values)
 ├── nginx/
 │   ├── nginx.conf             # core config
 │   └── conf.d/
 │       ├── api.conf           # api.<domain> server block
 │       ├── app.conf           # app.<domain> server block
 │       └── admin.conf         # admin.<domain> server block
 ├── scripts/
 │   ├── load-secrets.sh        # SSM → /run/secrets/.env (entrypoint helper)
 │   ├── pg-backup.sh           # nightly pg_dump → /var/backups/postgres
 │   └── deploy.sh              # git pull && compose pull && compose up -d
 └── certbot/
     └── init-cert.sh           # one-shot certificate issuance

 deploy/docker-compose.yml (skeleton)

 Services:
 - postgres — postgres:16-alpine, volume pg_data, health check, no published port (internal only).
 - redis — redis:7-alpine with --requirepass and AOF on volume redis_data, no published port.
 - migrator — built from bluemoon-be/Dockerfile, command yarn migrate:prod, restart: "no", depends on postgres healthy.
 - api — same image as migrator, APP_ROLE=api, command node dist/main, depends on migrator: service_completed_successfully and
 redis: service_healthy. Internal port 3001.
 - worker — same image, APP_ROLE=worker, command node dist/main, same depends_on. No published port.
 - fe — built from bluemoon-fe/Dockerfile, internal port 3000. Build arg NEXT_PUBLIC_API_URL=https://api.<domain>/v1.
 - admin — built from bluemoon-admin/Dockerfile, internal port 3002. Build arg
 NEXT_PUBLIC_BACKEND_API_URL=https://api.<domain>.
 - nginx — nginx:alpine, publishes :80 + :443, mounts nginx/conf.d read-only and letsencrypt volume for certs.
 - certbot — certbot/certbot, shared letsencrypt and certbot-www volumes, run on demand for renewals.

 All services on a single bluemoon-net bridge network. Logging driver json-file with max-size=10m, max-file=3 to prevent disk
 fill.

 2. bluemoon-be changes

 - Multi-stage Dockerfile (bluemoon-be/Dockerfile): replace existing single-stage build with builder stage (compiles + prisma
 generate) and runtime stage on node:20-alpine running as non-root node user, with only dist/, prisma/, node_modules/
 (production), and entrypoint script copied. This reduces image size and removes build toolchain from the running container.
 - Worker gating in bluemoon-be/src/main.ts: branch on process.env.APP_ROLE:
   - api → current bootstrap path (CORS, validation pipes, app.listen(HTTP_PORT)).
   - worker → bootstrap a WorkerAppModule that imports only WorkerModule (already exists at src/workers/worker.module.ts) plus
 shared CommonModule/PrismaModule. Don't call app.listen; call app.init() so DI runs.
 - Module gating in bluemoon-be/src/app.module.ts: only register WorkerModule when APP_ROLE !== 'worker' is unset OR move
 worker registration entirely out of AppModule and into a new WorkerAppModule. This prevents API container from also running
 cron schedulers.
 - Bull Board (src/main.ts:36-62): wrap the /admin/queues mount so it's only registered when APP_ROLE=api && APP_ENV !==
 'production'. In prod we don't want public queue introspection.
 - Healthcheck endpoint: confirm /v1/health returns 200; if missing, add a trivial HealthController that pings Prisma + Redis.
 Wire it into Nginx upstream healthcheck.

 3. bluemoon-fe changes

 - bluemoon-fe/next.config.ts: add output: 'standalone' so the Docker image can copy only .next/standalone and .next/static and
  run node server.js (~150MB image vs ~1GB).
 - New bluemoon-fe/Dockerfile: three stages (deps, builder, runner). Builder receives NEXT_PUBLIC_API_URL and
 NEXT_PUBLIC_WS_URL as build args (Next bakes NEXT_PUBLIC_* at build time). Runner runs as node user, exposes 3000, command
 node server.js.
 - .dockerignore: exclude .next, node_modules, .env*, .git, .vercel.
 - Drop .vercel/ from the repo if you're moving fully off Vercel; otherwise leave it (it's inert outside vercel CLI).

 4. bluemoon-admin changes

 Same pattern as bluemoon-fe:
 - Add output: 'standalone' to bluemoon-admin/next.config.mjs.
 - New bluemoon-admin/Dockerfile (3-stage, runner runs node server.js -p 3002).
 - .dockerignore.
 - Build arg NEXT_PUBLIC_BACKEND_API_URL=https://api.<domain>.

 5. Nginx config

 Three near-identical server blocks (one per subdomain). Each:
 - listen 443 ssl http2
 - ssl_certificate /etc/letsencrypt/live/<domain>/fullchain.pem
 - proxy_pass http://<service>:<port> (resolved on the compose network)
 - proxy_set_header Host $host; X-Real-IP $remote_addr; X-Forwarded-For $proxy_add_x_forwarded_for; X-Forwarded-Proto https;
 - WebSocket upgrade headers (frontend uses socket.io-client)
 - client_max_body_size 25M for image uploads
 - A :80 server block that ACME-challenges via /.well-known/acme-challenge/ and 301s everything else to https.

 6. Optional: GitHub Actions CI/CD

 Workflow .github/workflows/deploy.yml triggered on main push:
 1. Build all three images, tag with commit SHA, push to GHCR.
 2. SSH or AWS SSM Run-Command into EC2: cd /opt/bluemoon && git pull && docker compose pull && docker compose up -d.

 Skip this initially — manual deploys work fine for a single host. Add later when you're sure the topology is stable.

 EC2 Provisioning

 1. Instance: t3.large (8 GB RAM, 2 vCPU). Postgres + Redis + 3 Node processes + Nginx + worker = ~3-4 GB steady, leave
 headroom for build spikes. t3.medium works but builds will swap.
 2. AMI: Ubuntu 24.04 LTS (Amazon Linux 2023 also fine; commands below assume Ubuntu).
 3. Storage: 60 GB gp3 root volume. Postgres data lives at /var/lib/docker/volumes/pg_data — ensure docker root is on this
 volume (default).
 4. Security group: inbound :22 from your IP only, :80 and :443 from 0.0.0.0/0. No :3000-:3002, no :5432, no :6379 exposed.
 5. Elastic IP: allocate + associate so DNS doesn't break on stop/start.
 6. IAM instance profile: policy granting ssm:GetParametersByPath on arn:aws:ssm:<region>:<acct>:parameter/bluemoon/prod/* and
 kms:Decrypt on the SSM-default KMS key. Optional: s3:PutObject on a backup bucket.

 Host bootstrap (one-time)

 sudo apt update && sudo apt -y upgrade
 sudo apt -y install docker.io docker-compose-plugin git ufw fail2ban awscli
 sudo systemctl enable --now docker
 sudo usermod -aG docker ubuntu
 sudo ufw allow 22 && sudo ufw allow 80 && sudo ufw allow 443 && sudo ufw enable
 sudo mkdir -p /opt/bluemoon && sudo chown ubuntu:ubuntu /opt/bluemoon
 git clone <repo> /opt/bluemoon

 First Deploy

 1. Populate SSM Parameter Store with all values from rotated .env keys (script: loop over a list, aws ssm put-parameter --name
  /bluemoon/prod/<KEY> --type SecureString --value <val>).
 2. On EC2: cd /opt/bluemoon/deploy && ./scripts/load-secrets.sh > .env && chmod 600 .env.
 3. Issue certs (HTTP-01 challenge requires :80 reachable and DNS A records pointing at the EIP):
 docker compose up -d nginx
 docker compose run --rm certbot certonly --webroot -w /var/www/certbot \
   -d api.<domain> -d app.<domain> -d admin.<domain> --email <you> --agree-tos
 docker compose exec nginx nginx -s reload
 4. Bring up the data tier first: docker compose up -d postgres redis. Wait for healthy.
 5. Run migrator: docker compose run --rm migrator. It will exit 0 on success.
 6. Start the rest: docker compose up -d api worker fe admin.
 7. Seed if needed: docker compose exec api yarn seed:admin && yarn seed:products (etc.).

 Operations

 Backups

 Cron on host (crontab -e):
 0 3 * * * /opt/bluemoon/deploy/scripts/pg-backup.sh
 Script does docker compose exec -T postgres pg_dump -U postgres -Fc postgres > /var/backups/postgres/$(date +\%F).dump, prunes
  files older than 14 days, and aws s3 cp to a versioned bucket. Test restore quarterly: pg_restore -d postgres --clean <dump>
 against a throwaway DB.

 Updates

 cd /opt/bluemoon
 git pull
 cd deploy
 docker compose build --pull
 docker compose run --rm migrator
 docker compose up -d api worker fe admin nginx
 docker image prune -f
 Wrap as deploy.sh. Zero-downtime is not a goal here — Compose's recreate is ~5 s of API unavailability; if that's
 unacceptable, add a second api replica behind Nginx upstream.

 Logs

 docker compose logs -f --tail=100 api worker. Already wired to json-file driver with rotation. Sentry DSN is plumbed in .env —
  set it in SSM and errors flow there.

 Monitoring

 - Sentry already integrated (SENTRY_DSN).
 - Add CloudWatch agent to ship /var/log/syslog + Docker logs and emit a memory/disk metric (host-level).
 - Optional: Uptime Kuma container for blackbox checks of the three subdomains.

 Critical Files to Modify / Create

 Modify:
 - bluemoon-be/Dockerfile — multi-stage, non-root, slim runtime
 - bluemoon-be/src/main.ts — APP_ROLE branching, gate Bull Board on prod
 - bluemoon-be/src/app.module.ts — extract worker registration into WorkerAppModule
 - bluemoon-fe/next.config.ts — output: 'standalone'
 - bluemoon-admin/next.config.mjs — output: 'standalone'
 - bluemoon-be/.gitignore, root .gitignore — exclude .env*

 Create:
 - bluemoon-fe/Dockerfile, bluemoon-fe/.dockerignore
 - bluemoon-admin/Dockerfile, bluemoon-admin/.dockerignore
 - bluemoon-be/.dockerignore (if missing)
 - deploy/docker-compose.yml
 - deploy/.env.template
 - deploy/nginx/nginx.conf, deploy/nginx/conf.d/{api,app,admin}.conf
 - deploy/scripts/{load-secrets.sh,pg-backup.sh,deploy.sh}
 - deploy/certbot/init-cert.sh

 Delete (after history rewrite):
 - Committed bluemoon-be/.env (move to .env.example template only)

 Reuse, don't reinvent:
 - Existing bluemoon-be/src/workers/worker.module.ts already cleanly aggregates the worker bits — WorkerAppModule just imports
 it.
 - Existing bluemoon-be/docker-compose.yml (local-dev) stays for local development; production deploy/docker-compose.yml is
 separate. Don't merge them.

 Verification

 After first deploy:
 1. DNS: dig api.<domain> +short → EIP. Same for app. and admin..
 2. TLS: curl -I https://api.<domain>/v1/health → 200. Browser shows green padlock on all three.
 3. Backend boot: docker compose logs api | grep "Listening"; curl https://api.<domain>/v1/health.
 4. Worker boot: docker compose logs worker | grep -E "QueueProcessor|Bull"; queue a test job (e.g. trigger a registration
 email) and confirm worker logs the processor firing, not api.
 5. Storefront: visit https://app.<domain>, confirm products load (validates FE→BE CORS + DB seed).
 6. Admin: visit https://admin.<domain>/login, sign in with the seeded SEED_ADMIN_EMAIL.
 7. WebSocket: open admin dashboard, check browser devtools for a connected socket.io frame to wss://api.<domain>.
 8. Backup: run ./scripts/pg-backup.sh manually, verify a .dump lands in /var/backups/postgres and S3.
 9. Migration safety: make a no-op Prisma migration, deploy, confirm migrator runs and api/worker only start after.
 10. Restart resilience: sudo reboot the EC2 instance — all containers come back via restart: unless-stopped, certs persist, DB
  intact.
 11. Bull Board hidden: curl -I https://api.<domain>/admin/queues → 404 (since APP_ENV=production).
 12. Sec-group sanity: nmap -p 3000,3001,3002,5432,6379 <EIP> from outside → all closed/filtered.