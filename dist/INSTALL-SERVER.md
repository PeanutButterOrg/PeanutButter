# Install PeanutButter backend — no .env file needed

Compose files already include the current local config (passwords, PUBLIC_URL, Meili key, crons).
Containers use `restart: unless-stopped` so the API keeps running after reboot.

## One-shot (recommended)

```bash
cd peanutbutter
chmod +x scripts/run-server.sh
./scripts/run-server.sh              # build image + start stack
# optional: ./scripts/run-server.sh --save   # also write dist/peanutbutter-api-0.2.0.tar.gz
curl http://127.0.0.1:3001/health
```

Open `http://10.0.0.28:3001/` (or your server IP if you changed PUBLIC_URL).

## Docker Compose only

```bash
cd peanutbutter
# Optional: edit PUBLIC_URL in docker-compose.server.yml if this host is not 10.0.0.28
docker compose -f docker-compose.server.yml up -d --build
curl http://127.0.0.1:3001/health
```

## Load a pre-built API image (offline / CasaOS)

```bash
gunzip -c dist/peanutbutter-api-0.2.0.tar.gz | docker load
```

## CasaOS / ZimaOS

```bash
docker build -t peanutbutter-api:0.2.0 ./backend
# or load the tarball above
```

CasaOS → **Custom Install** → paste `docker-compose.casaos.yml` → Install.  
No environment form / no `.env`.

## After start

1. Console → set **Jackett** (URL + API key)  
2. Console → **Devices** → **New code**  
3. Pair the TV/desktop app with `http://YOUR_SERVER:3001` + the 6-digit code  

## Keep it running

```bash
docker compose -f docker-compose.server.yml ps
docker compose -f docker-compose.server.yml logs -f api
./scripts/run-server.sh --down    # stop
```

## Note about API keys

Your current local `.env` has **empty** `TMDB_API_KEY` and `OMDB_API_KEY`.  
Those are baked in as empty strings. To enable metadata sync, edit the `api` / `app` service in the compose and set:

```yaml
TMDB_API_KEY: "your_key_here"
OMDB_API_KEY: "your_key_here"
```

`ADMIN_PASSWORD` is also empty — on first boot the API prints a generated console password in the logs (`docker compose … logs api`).

Full guide: `docs/SERVER.md`
