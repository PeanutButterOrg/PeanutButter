# Install PeanutButter backend on your server

This guide installs the **catalog API + console** on a home lab or VPS.  
TV and desktop apps connect to it; they do not need to run on the same machine.

**No `.env` file is required** for [`docker-compose.server.yml`](../docker-compose.server.yml) / [`docker-compose.casaos.yml`](../docker-compose.casaos.yml). Set `PUBLIC_URL` to the URL clients use (LAN IP or domain), e.g. `http://192.168.1.10:3001`.

Containers restart automatically so the stack keeps running across reboots and crashes.

**What you get**

| URL | Purpose |
| --- | --- |
| `http://YOUR_SERVER:3001/` | Web console (password) — Jackett, device pairing codes |
| `http://YOUR_SERVER:3001/health` | Health check |
| `http://YOUR_SERVER:3001/graphql` | GraphQL API (apps use this) |

**Stack (Docker):** Postgres 16 · Meilisearch · PeanutButter API (`peanutbutter-api:0.2.0` or GHCR)

Pick one path:

1. [Quick start script](#1-quick-start-script)  
2. [Docker Compose](#2-docker-any-linux-server)  
3. [Prebuilt GHCR / CI image](#3-prebuilt-ghcr--ci-image)  
4. [CasaOS / ZimaOS](#4-casaos--zimaos)  
5. [After install](#5-after-install)  
6. [Troubleshooting](#6-troubleshooting)

---

## Before you start

- Linux host with **Docker** + **Docker Compose v2**
- Port **3001/tcp** open to your LAN
- Optional: Jackett (set in the web console after start)
- Optional: TMDB / OMDb keys — paste into the compose `environment` block if you want metadata sync

---

## 1. Quick start script

```bash
cd peanutbutter
chmod +x scripts/run-server.sh
PUBLIC_URL=http://YOUR_SERVER_IP:3001 ./scripts/run-server.sh   # build + start
./scripts/run-server.sh --save                                    # also write dist/*.tar.gz
curl http://127.0.0.1:3001/health
```

Stop later with `./scripts/run-server.sh --down`.

---

## 2. Docker (any Linux server)

```bash
cd peanutbutter
# Set PUBLIC_URL in docker-compose.server.yml (or export PUBLIC_URL=…)
docker compose -f docker-compose.server.yml up -d --build
curl http://127.0.0.1:3001/health
```

```bash
docker compose -f docker-compose.server.yml logs -f api
docker compose -f docker-compose.server.yml down
```

---

## 3. Prebuilt GHCR / CI image

From GitHub Actions (**Backend & Docker**) or the registry:

```bash
docker pull ghcr.io/peanutbutterorg/peanutbutter-api:0.2.0
# or: gunzip -c peanutbutter-api-0.2.0.tar.gz | docker load

# Point compose at the image (skip build) — image: peanutbutter-api:0.2.0
docker compose -f docker-compose.server.yml up -d
```

Linux binary-only (no Docker API container): download artifact `peanutbutter-api-linux-x86_64`, extract, set env (`MIGRATIONS_DIR`, `DATABASE_URL`, …), run `./peanutbutter`. You still need Postgres + Meilisearch.

---

## 4. CasaOS / ZimaOS

```bash
docker build -t peanutbutter-api:0.2.0 ./backend
# or: gunzip -c dist/peanutbutter-api-0.2.0.tar.gz | docker load
# or: docker pull ghcr.io/peanutbutterorg/peanutbutter-api:0.2.0
#     docker tag ghcr.io/peanutbutterorg/peanutbutter-api:0.2.0 peanutbutter-api:0.2.0
```

1. CasaOS → **App Store** → **Custom Install**
2. Paste [`docker-compose.casaos.yml`](../docker-compose.casaos.yml)
3. Edit `PUBLIC_URL` in the YAML if needed
4. Install — **do not** create a `.env`

Data: `/DATA/AppData/peanutbutter/`

---

## 5. After install

1. Open `http://YOUR_SERVER:3001/` and sign in (`ADMIN_PASSWORD` from compose, or generated password in API logs)
2. Configure Jackett in the console (optional)
3. Create a pairing code; enter it in the TV / desktop / phone app under Settings
4. Point the app at `http://YOUR_SERVER:3001`

Firewall: allow **3001/tcp** from your LAN.

---

## 6. Troubleshooting

| Symptom | Check |
| --- | --- |
| Health fails | `docker compose … ps` / logs / firewall |
| Unknown console password | `docker compose … logs api` |
| App unreachable | `PUBLIC_URL` must match app server address |
| No posters | Set `TMDB_API_KEY` in compose |
| No torrents | Jackett in console |

---

## Files

| File | Role |
| --- | --- |
| `scripts/run-server.sh` | Build image + start stack |
| `docker-compose.server.yml` | Homelab (baked config, auto-restart) |
| `docker-compose.casaos.yml` | CasaOS (baked config) |
| `backend/Dockerfile` | API image |
| `.github/workflows/backend-docker.yml` | Binary + GHCR + `docker save` artifacts |
| `dist/peanutbutter-api-0.2.0.tar.gz` | Optional offline image (via `--save` or CI) |
