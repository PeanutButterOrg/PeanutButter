# PeanutButter Backend

Rust / Axum GraphQL catalog API for [PeanutButter](https://github.com/PeanutButterOrg/PeanutButter).

## Docker image

```bash
docker build -t peanutbutter-api:0.2.0 .
# After CI publishes:
# docker pull ghcr.io/peanutbutterorg/peanutbutter-api:latest
```

## Run with Compose

Use the full stack compose from the main repo:

- [`docker-compose.server.yml`](https://github.com/PeanutButterOrg/PeanutButter/blob/main/docker-compose.server.yml)

Or build this image and point Portainer / CasaOS at `peanutbutter-api:0.2.0` / `ghcr.io/peanutbutterorg/peanutbutter-api:latest`.

## Local (without Docker)

See the main repo `docs/SERVER.md`. Requires Postgres + Meilisearch.
