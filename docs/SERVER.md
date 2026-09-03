# Install PeanutButter backend on your server

This guide installs the **catalog API + console** on a home lab or VPS.  
TV and desktop apps connect to it; they do not need to run on the same machine.

**No `.env` file is required.**  
[`docker-compose.server.yml`](../docker-compose.server.yml) and [`docker-compose.casaos.yml`](../docker-compose.casaos.yml) already embed the current local config (`PUBLIC_URL=http://10.0.0.28:3001`, Postgres/Meili passwords, sync crons). Edit `PUBLIC_URL` in the YAML only if this server uses a different IP.

Containers use **`restart: unless-stopped`** so the stack keeps running across reboots and crashes.

**What you get**

| URL | Purpose |
| --- | --- |
| `http://YOUR_SERVER:3001/` | Web console (password) — Jackett, device pairing codes |
| `http://YOUR_SERVER:3001/health` | Health check |
| `http://YOUR_SERVER:3001/graphql` | GraphQL API (apps use this) |

**Stack (Docker):** Postgres 16 · Meilisearch · PeanutButter API (`peanutbutter-api:0.2.0`)

Pick one path:

1. [Quick start script](#1-quick-start-script)  
2. [Docker Compose](#2-docker-any-linux-server)  
3. [CasaOS / ZimaOS](#3-casaos--zimaos)  
4. [After install — pair devices & Jackett](#4-after-install)

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
./scripts/run-server.sh                 # build peanutbutter-api:0.2.0 + start
./scripts/run-server.sh --save          # also write dist/peanutbutter-api-0.2.0.tar.gz
curl http://127.0.0.1:3001/health
```

Stop later with `./scripts/run-server.sh --down`.

---

## 2. Docker (any Linux server)

```bash
cd peanutbutter
# Optional: edit PUBLIC_URL in docker-compose.server.yml if IP ≠ 10.0.0.28
docker compose -f docker-compose.server.yml up -d --build
curl http://127.0.0.1:3001/health
```

```bash
docker compose -f docker-compose.server.yml logs -f api
docker compose -f docker-compose.server.yml down
```

Load a saved image on another host:

```bash
gunzip -c dist/peanutbutter-api-0.2.0.tar.gz | docker load
docker compose -f docker-compose.server.yml up -d
```

---

## 3. CasaOS / ZimaOS

```bash
docker build -t peanutbutter-api:0.2.0 ./backend
# or: gunzip -c dist/peanutbutter-api-0.2.0.tar.gz | docker load
```

1. CasaOS → **App Store** → **Custom Install**
2. Paste [`docker-compose.casaos.yml`](../docker-compose.casaos.yml)
3. Edit `PUBLIC_URL` in the YAML if needed
4. Install — **do not** create a `.env`

Data: `/DATA/AppData/peanutbutter/`

---

## 4. After install

1. Open `http://YOUR_SERVER:3001/`
2. Console password: `ADMIN_PASSWORD` is empty, so first boot prints a generated password in API logs
3. Console → configure **Jackett**
4. Console → **Devices** → **New code** → pair the app

Firewall: publish **3001** only.

---

## 5. Troubleshooting

| Symptom | Check |
| --- | --- |
| Health fails | `docker compose … ps` / logs / firewall |
| Unknown console password | `docker compose … logs api` |
| App unreachable | `PUBLIC_URL` must match app server address |
| No posters | Set `TMDB_API_KEY` in compose |
| No torrents | Jackett in console |

---

## 6. Files

| File | Role |
| --- | --- |
| `scripts/run-server.sh` | Build image + start stack |
| `docker-compose.server.yml` | Homelab (baked config, auto-restart) |
| `docker-compose.casaos.yml` | CasaOS (baked config) |
| `backend/Dockerfile` | API image |
| `dist/INSTALL-SERVER.md` | Short install sheet |
| `dist/peanutbutter-api-0.2.0.tar.gz` | Optional offline image (via `--save`) |
