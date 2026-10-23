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

1. Open `http://YOUR_SERVER:3001/` and sign in. With `ADMIN_PASSWORD` empty, the first boot generates a password and prints it in `docker compose … logs api`. Change it in the console's Settings tab.
2. Configure Jackett in the console (optional)
3. Under Devices, add a device to get a 6-digit pairing code and type it into the TV / desktop / phone app **within 15 minutes**. The app trades it for its own long-lived key; the code is not a password. Use **New code** on a device to add another screen to the same profile, and **Remove** to sign all of that device's apps out.
4. Point the app at `http://YOUR_SERVER:3001`

### Security notes

- Pairing codes, API keys and the console password are rate-limited per IP (10 wrong codes or passwords, or 30 bad keys, per 15 minutes).
- Only the **Admin** device (the first one) can change catalog keys or the media folder from an app. Everything else is done in the console.
- Browsers may only call the API from `PUBLIC_URL`'s origin. If you serve the web build elsewhere, add its origin to `CORS_ORIGINS` (comma-separated).
- The API container runs as uid 10001. Your media folder must be readable by it (normal `755`/`644` permissions are fine), or set `PB_RUN_AS_ROOT=1`.
- **Upgrading from 6-digit codes:** codes that existed before this update keep working for 30 days. Updated apps swap them for a key automatically on next launch; apps still on old codes after that must re-pair.

Firewall: allow **3001/tcp** from your LAN.

### App updates (desktop + TV)

Every `vX.Y.Z` tag makes CI publish a GitHub release with the installers, plus a `manifest.json` that has been Ed25519-signed with the `UPDATE_SIGNING_KEY` secret. The server checks that release every 6 hours (`UPDATE_CHECK_HOURS`). It verifies the signature and each file's SHA-256, then keeps a copy in the `updates_data` volume, so devices download over your LAN, not from GitHub. Use **Settings → App updates → Check now** in the console to check right away.

Apps ask the server after launch and then every 12 hours. They install only builds whose manifest carries a valid signature from the key built into the app:

| Platform | Install |
| --- | --- |
| Windows | Silent installer, then the app restarts |
| Linux AppImage | Replaces the AppImage in place, then restarts |
| Linux .deb | `pkexec apt-get install` (asks for your password) |
| macOS | Unpacks to `~/Downloads/PeanutButter <version>`; drag it into Applications |
| Android TV | Android's own "Update?" screen (allow "Install unknown apps" once); Settings → Check for updates |

Environment: `UPDATES_ENABLED=0` turns updates off, `UPDATES_REPO` sets the source repository (default `PeanutButterOrg/PeanutButter`), and `UPDATES_INCLUDE_PRERELEASE=1` also offers `-rc` tags.

### Server updates from the console

Every `vX.Y.Z` tag makes CI publish the server image as `ghcr.io/peanutbutterorg/peanutbutter-api:stable`. The console is served by the server, so it updates together with it. Switch to the CI image once, in the folder with your compose file:

```bash
docker compose -f docker-compose.server.yml -f docker-compose.autoupdate.yml pull api
docker compose -f docker-compose.server.yml -f docker-compose.autoupdate.yml up -d
```

From then on, **Settings → Server** in the console shows the running version and any newer release:

- **Update to vX.Y.Z** backs up Postgres, then asks Watchtower to pull the new image and restart the `api` container only. The page reloads itself when the new version is up, and you stay signed in.
- **Update automatically** does the same by itself after a release appears, once no stream is running through the server.

Details:

- Before each update the database is dumped to the `backups_data` volume (`pre-update-<version>-<time>.sql.gz`; the newest five are kept).
- Watchtower never polls on its own; it only acts when the console asks. Postgres and Meilisearch are never updated automatically.
- The token the server and Watchtower share is created on first start in the `control_data` volume. There's nothing to configure.
- Watchtower needs Docker 25 or newer by default. On older Docker, set `WATCHTOWER_DOCKER_API_VERSION` (for example `1.43`).
- The GHCR package must be public, or the host must run `docker login ghcr.io` with a token that has `read:packages`, plus `- /root/.docker/config.json:/config.json:ro` in the `watchtower` volumes.
- Don't pass `--build` with this file. To go back to local builds, run `docker compose -f docker-compose.server.yml up -d --build`.

---

## 6. Troubleshooting

| Symptom | Check |
| --- | --- |
| Health fails | `docker compose … ps` / logs / firewall |
| Unknown console password | `docker compose … logs api`; to reset, set `ADMIN_PASSWORD` and `ADMIN_PASSWORD_RESET=1` for one restart |
| "Too many attempts" | Wait 15 minutes (per-IP limit on codes / passwords) |
| Pairing code rejected | Codes expire after 15 minutes: click **New code** in the console |
| App unreachable | `PUBLIC_URL` must match app server address |
| No posters | Set `TMDB_API_KEY` in compose |
| No torrents | Jackett in console |

---

## Files

| File | Role |
| --- | --- |
| `docker-compose.autoupdate.yml` | CI image + Watchtower, for server updates from the console |
| `scripts/run-server.sh` | Build image + start stack |
| `docker-compose.server.yml` | Homelab (baked config, auto-restart) |
| `docker-compose.casaos.yml` | CasaOS (baked config) |
| `backend/Dockerfile` | API image |
| `.github/workflows/backend-docker.yml` | Binary + GHCR + `docker save` artifacts |
| `dist/peanutbutter-api-0.2.0.tar.gz` | Optional offline image (via `--save` or CI) |
