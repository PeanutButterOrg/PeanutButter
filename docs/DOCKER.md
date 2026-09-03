# Host PeanutButter on a server (Docker)

**Full guide:** [SERVER.md](SERVER.md)

Compose is **self-contained** — no `.env` on the server.  
`restart: unless-stopped` keeps the API running after reboot.

```bash
./scripts/run-server.sh
# or:
docker compose -f docker-compose.server.yml up -d --build
```

CasaOS: build/load `peanutbutter-api:0.2.0`, Custom Install → paste `docker-compose.casaos.yml`.

Edit `PUBLIC_URL` in the YAML if the host is not `10.0.0.28`.
