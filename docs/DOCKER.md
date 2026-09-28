# Host PeanutButter on a server (Docker)

**Full guide:** [SERVER.md](SERVER.md)

Compose for servers is **self-contained** — no `.env` required on the host.  
Containers use `restart: always` / `unless-stopped` so the stack survives reboots.

```bash
./scripts/run-server.sh
# or:
docker compose -f docker-compose.server.yml up -d --build
```

### Prebuilt image (CI / GHCR)

```bash
docker pull ghcr.io/peanutbutterorg/peanutbutter-api:latest
# pin: ghcr.io/peanutbutterorg/peanutbutter-api:0.2.0
```

Or load an offline artifact from the **Backend & Docker** workflow:

```bash
gunzip -c peanutbutter-api-0.2.0.tar.gz | docker load
```

CasaOS: use image `peanutbutter-api:0.2.0`, Custom Install → paste [`docker-compose.casaos.yml`](../docker-compose.casaos.yml).

Set `PUBLIC_URL` in the compose file (or via `PUBLIC_URL=… ./scripts/run-server.sh`) to the URL clients will use.
