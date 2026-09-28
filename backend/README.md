# PeanutButter Backend

Rust / Axum GraphQL catalog API for [PeanutButter](https://github.com/PeanutButterOrg/PeanutButter).

Serves metadata (TMDB / OMDb / AniList), local library Range playback, Jackett magnet resolution, device pairing, and the password-protected web console.

## Requirements

- Rust stable (edition 2021)
- PostgreSQL 16
- Meilisearch v1.11+

Or use Docker and skip local Postgres/Meili setup (see below).

## Docker image

```bash
cd backend
docker build -t peanutbutter-api:0.2.0 .
```

Published by CI ([`.github/workflows/backend-docker.yml`](../.github/workflows/backend-docker.yml)):

```bash
docker pull ghcr.io/peanutbutterorg/peanutbutter-api:latest
# tagged releases also push :0.2.0 (from tag v0.2.0)
```

Offline / CasaOS: download the `peanutbutter-api-image` workflow artifact (`.tar.gz`), then:

```bash
gunzip -c peanutbutter-api-0.2.0.tar.gz | docker load
```

Full stack compose lives in the repo root:

- [`docker-compose.server.yml`](../docker-compose.server.yml) — VPS / homelab
- [`docker-compose.casaos.yml`](../docker-compose.casaos.yml) — CasaOS / ZimaOS
- [`docker-compose.yml`](../docker-compose.yml) — local API + optional web UI

Install guide: [docs/SERVER.md](../docs/SERVER.md).

## Local (without Docker)

```bash
# From repo root — Postgres on 5433 + Meili on 7700 via compose services, or your own instances
cp .env.example .env
# set DATABASE_URL, MEILI_*, TMDB_API_KEY, PUBLIC_URL, BIND_ADDR=0.0.0.0:3001

cd backend
cargo run --release
```

Migrations are applied from `src/db/migrations/` on startup (`MIGRATIONS_DIR` overrides the path; Docker image uses `/app/migrations`).

Health: `GET /health` · Console: `GET /` · GraphQL: `POST /graphql`.

## CI artifacts

On `main`, tags `v*`, and workflow_dispatch:

| Artifact | Contents |
| --- | --- |
| `peanutbutter-api-linux-x86_64` | Stripped release binary + migrations (`.tar.gz`) |
| `peanutbutter-api-image` | `docker save` of `peanutbutter-api:<version>` (`.tar.gz`) |
| GHCR image | `ghcr.io/peanutbutterorg/peanutbutter-api` |

## Configuration

See root [`.env.example`](../.env.example) and [README.md](../README.md#environment-variables). Important:

| Variable | Notes |
| --- | --- |
| `DATABASE_URL` | Postgres connection string |
| `MEILI_URL` / `MEILI_MASTER_KEY` | Search |
| `PUBLIC_URL` | URL clients use (LAN IP or domain) |
| `MEDIA_PATH` | Library root |
| `ADMIN_PASSWORD` | Console password (generated if empty) |
| `API_KEY` | Optional fixed 6-digit pairing code |

## Tests

```bash
cargo test
```
