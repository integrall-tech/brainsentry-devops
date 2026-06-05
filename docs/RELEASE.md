# Release & upgrade guide

How to ship a new brainsentry version to the swarm. Read this before
your first upgrade — there is **one ordering gotcha** that will bite you
if you run the steps in the obvious-but-wrong order.

## TL;DR

```
1. tag the source repo          (CI builds + publishes the images)
2. update the BACKEND service    to the new tag
3. run migrations                (NOT before step 2 — see gotcha)
4. update the FRONTEND service   to the new tag
5. verify /api/version + a smoke check
```

## The ordering gotcha

`scripts/migrate.sh` reads the migration `.up.sql` files from **inside
the running backend container** (`/app/migrations`, baked into the
image), not from this repo. So:

- If you run `migrate.sh` **before** updating the backend, it applies the
  migrations from the **old** image — the new migration isn't there yet,
  and your new backend will then fail at runtime (e.g. an INSERT against
  a column that doesn't exist).
- The new backend **boots fine** without the migration (it only connects
  + serves; the missing column only breaks writes). That's what makes
  "update backend first, then migrate" safe: there's a brief window where
  writes would 500, but the migration closes it seconds later.

Therefore the correct order is **update backend → migrate → update
frontend**. The migration runs from the *new* image, which carries the
new `.up.sql`.

> Alternative if you don't want the write-error window: copy the
> migrations to the host and run `./scripts/migrate.sh /path/to/migrations`
> with an explicit directory **before** updating the backend. The repo
> doesn't ship the SQL, so you'd clone brainsentry.io for this. The
> in-image path above is simpler and is what we use.

## Full procedure

### 1. Tag the source repo

In `integrall-tech/brainsentry.io`, from `main`:

```bash
git tag -a v0.X.0 -m "v0.X.0 — <summary>"
git push origin v0.X.0
```

This fires the two GitHub Actions image builds. Wait for them to go green
(they publish `:0.X.0` + `:0.X` + `:latest` + `:<sha>`):

```bash
gh run list --repo integrall-tech/brainsentry.io --limit 4
```

### 2. Pin the tag + update the backend (on the swarm manager)

```bash
cd ~/apps/brainsentry-devops
sed -i 's/^BACKEND_IMAGE_TAG=.*/BACKEND_IMAGE_TAG=0.X.0/'  .env
sed -i 's/^FRONTEND_IMAGE_TAG=.*/FRONTEND_IMAGE_TAG=0.X.0/' .env

docker service update --with-registry-auth \
  --image ghcr.io/integrall-tech/brainsentry-backend:0.X.0 \
  brainsentry_brainsentry-backend
```

Wait for `1/1`:

```bash
docker service ls --filter name=brainsentry_brainsentry-backend
```

### 3. Run migrations (idempotent)

```bash
./scripts/migrate.sh
```

`migrate.sh` does `CREATE EXTENSION IF NOT EXISTS vector` then applies
every `000NNN_*.up.sql` in order. All migrations use
`IF NOT EXISTS`/`ADD COLUMN IF NOT EXISTS`, so re-running is safe — only
the genuinely-new migration changes anything. Confirm the change landed,
e.g. for the v0.2.0 provenance column:

```bash
docker exec $(docker ps -q -f name=brainsentry_brainsentry-postgres) \
  psql -U brainsentry -d brainsentry \
  -tc "SELECT column_name FROM information_schema.columns \
       WHERE table_name='memories' AND column_name='provenance';"
```

### 4. Update the frontend

```bash
docker service update --with-registry-auth \
  --image ghcr.io/integrall-tech/brainsentry-frontend:0.X.0 \
  brainsentry_brainsentry-frontend
```

### 5. Verify

```bash
B=$(docker ps -q -f name=brainsentry_brainsentry-backend)

# Version should report the new tag + the merge commit:
docker exec $B wget -qO- http://localhost:8081/api/version

# All dependencies healthy:
docker exec $B wget -qO- http://localhost:8081/api/v1/diagnostics

# Optional: full validation/benchmark from a machine with the source repo
cd /path/to/brainsentry.io/brain-sentry-explorer
BS_BASE_URL=http://<manager-ip>:8081/api npm run validate
BS_BASE_URL=http://<manager-ip>:8081/api npm run benchmark
```

Tell users to hard-reload the SPA (`Cmd/Ctrl+Shift+R`) so the browser
picks up the new frontend bundle instead of the cached one.

## Rollback

Re-point the services at the previous tag. Migrations are forward-only —
a rollback that needs a schema change must apply the matching
`*.down.sql` by hand (rare; most migrations are additive `ADD COLUMN`
that the older binary simply ignores).

```bash
docker service update --with-registry-auth \
  --image ghcr.io/integrall-tech/brainsentry-backend:0.<prev>.0 \
  brainsentry_brainsentry-backend
docker service update --with-registry-auth \
  --image ghcr.io/integrall-tech/brainsentry-frontend:0.<prev>.0 \
  brainsentry_brainsentry-frontend
```

Because v0.2.0's migration is an additive `ADD COLUMN provenance ...
DEFAULT ''`, rolling the backend back to v0.1.0 needs **no** DB change —
the old binary just doesn't select the column.

## Release checklist

- [ ] `main` green, all PRs for the release merged
- [ ] `git tag v0.X.0 && git push --tags`
- [ ] both image builds green on GHCR
- [ ] backend service updated to `:0.X.0` (1/1)
- [ ] `./scripts/migrate.sh` run, new schema object verified
- [ ] frontend service updated to `:0.X.0` (1/1)
- [ ] `/api/version` reports `0.X.0`
- [ ] `/api/v1/diagnostics` all `ok`
- [ ] (optional) `npm run validate` + `npm run benchmark` green
