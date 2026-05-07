# Feature Rollout & Re-deployment

The day-2 process: shipping new commits to production.

## TL;DR

```bash
cd /opt/jinx/deploy
./scripts/deploy.sh
```

That script:
1. Pulls `main` in `jinx-be`, `jinx-fe`, `jinx-admin` (fast-forward only)
2. Refuses to run if `.env` is missing or still has `__CHANGE_ME__`
3. Builds new images tagged with the current backend git short SHA
4. Runs `migrator` (Prisma migrate deploy) — fails the deploy if a migration errors
5. Recreates `api`, `worker`, `fe`, `admin`, `nginx`
6. Prunes dangling images

Total downtime per deploy is ~5–10 s (no zero-downtime rollover; not a goal at
this stage).

## Pre-deploy checklist

- [ ] All three repos: PR merged into `main`
- [ ] If you changed `package.json` / `yarn.lock` / `package-lock.json`,
      verify the lockfile committed matches: backend uses **yarn**, FE & admin
      use **npm**
- [ ] If a migration is included, eyeball it — Prisma `migrate deploy` runs
      it unattended on the prod DB
- [ ] If `.env.prod.example` gained new keys, also add them to the on-host
      `.env` first (`scp` or edit in place); deploys without will fail at boot

## What gets rebuilt

`deploy.sh` calls `docker compose build --pull`, which rebuilds **all** services
that have a `build:` block. Postgres, Redis, and Nginx use stock images and are
not rebuilt — they keep running through the deploy.

Build cache is per-service and per-`Dockerfile`, so an FE-only PR will only
re-run FE's `yarn install` step if `package-lock.json` changed.

## Image tagging

Every deploy stamps `IMAGE_TAG` to the backend's `git rev-parse --short HEAD`
(e.g. `a1b2c3d`). After 5 deploys you'll see:

```bash
docker images jinx-be
# REPOSITORY  TAG       IMAGE ID
# jinx-be     latest    sha256:...
# jinx-be     a1b2c3d   sha256:...
# jinx-be     9e8f7a6   sha256:...
```

Old SHA-tagged images stay around for instant rollback. `docker image prune -f`
(run by `deploy.sh`) only removes **dangling** images, not tagged ones.

## Rollback

To revert to a previous backend SHA:

```bash
cd /opt/jinx/jinx-be
git log --oneline -10            # find the good SHA
git checkout <good-sha>
cd /opt/jinx/deploy
./scripts/deploy.sh
```

If only one of the projects regressed, check out the bad commit in just that
repo and run `deploy.sh`. The other two will be no-ops because git is already
at HEAD.

To roll back **without rebuilding** (faster, uses an existing SHA-tagged image):

```bash
cd /opt/jinx/deploy
IMAGE_TAG=a1b2c3d docker compose up -d api worker
```

## Targeted re-deploys

Sometimes you don't want a full rebuild:

```bash
# rebuild only the backend
docker compose build api worker
docker compose up -d api worker

# rebuild only the FE
docker compose build fe
docker compose up -d fe

# rebuild FE without using cache (e.g. after changing CENTRAL_LICENSE_KEY)
docker compose build --no-cache fe
docker compose up -d fe

# run migrations only (no app rebuild)
docker compose run --no-deps --rm migrator
```

## Migration safety

Migrations run **before** `api` and `worker` start (compose `depends_on:
migrator: service_completed_successfully`). If `prisma migrate deploy` exits
non-zero:
- the `migrator` container shows the error in `docker compose logs migrator`
- `api` and `worker` will not start at all
- the previous `api`/`worker` containers stay up — production is uninterrupted

Resolution: fix the migration in the repo, push, deploy again. Never try to
"unstick" a half-applied migration by editing rows in `_prisma_migrations`
without a verified backup first.

## Adding a new env var

1. Add the key with a sensible default (or `__CHANGE_ME__`) to `deploy/.env.prod.example`
2. On the server: `vim /opt/jinx/deploy/.env`, add the value
3. If the key is `NEXT_PUBLIC_*`, also add it to the relevant `build.args` in
   `docker-compose.yml` (FE bakes `NEXT_PUBLIC_*` at build time)
4. If the key needs to be available at install time (rare — `CENTRAL_LICENSE_KEY`
   is one), expose it as `ARG` in the relevant Dockerfile **before** the
   `RUN npm ci` / `yarn install` line
5. Deploy

## CI/CD (not yet implemented)

Manual `deploy.sh` is fine for a single-host stack. If/when this graduates to
multi-environment or multi-host, the recommended path is:

1. GitHub Actions on push to `main` → build images, push to GHCR with SHA tag
2. SSH into the VPS host: `git pull` + `docker compose pull` +
   `docker compose up -d`

Until then, `./scripts/deploy.sh` is the single source of deploy truth.

## Common rollout problems

| Symptom | Likely cause |
|---|---|
| Build fails on `npm ci` lockfile mismatch | Package was added to `package.json` but lockfile wasn't regenerated. Run `npm install` locally, commit the new lockfile. |
| `prisma migrate deploy` reports "drift detected" | A migration was applied manually outside Prisma. Don't `--force` past it; investigate first. |
| Containers up but app returns 502 | API failed health check. `docker compose logs api` — usually a missing env var or DB connection issue. |
| FE rebuilds but new env vars don't take effect | `NEXT_PUBLIC_*` is baked at build time. After changing `.env`, run `docker compose build --no-cache fe`. |
| `deploy.sh` says "still contains __CHANGE_ME__" | A new placeholder was added to `.env.prod.example` and pulled into your `.env`. Find and fill it. |
