# PeanutButter

Self-hosted media catalog for **your own legally owned files**. Metadata comes from official APIs:

- [TMDB](https://www.themoviedb.org/) — posters, trailers, genres, TMDB ratings
- [OMDb](http://www.omdbapi.com/) — IMDb ratings only (IMDb is never scraped)
- [AniList](https://anilist.co/) — anime metadata

Local library files are served from a directory you mount (`MEDIA_PATH`). Jackett magnets are resolved by the API; **each client** (desktop / Android TV) downloads and streams torrents itself via libtorrent.

## Architecture

| Piece | Role |
| --- | --- |
| **API** (Rust / Axum / async-graphql) | Catalog, ingest, Jackett, pairing, local file Range serving |
| **Postgres 16** | Titles, progress, torrent listings |
| **Meilisearch** | Typo-tolerant search |
| **Flutter client** (`frontend/`) | Linux / Windows / macOS desktop, plus a web build |
| **Native Android TV** (`android-native/`) | Leanback TV app (the only Android client) |

Clients pick a playback backend by device profile:

| Device | Default player |
| --- | --- |
| Linux / Windows / macOS | media_kit (libmpv) |
| Web | media_kit (browser `<video>`); no on-device torrents |
| Android TV (native Leanback) | LibVLC SurfaceView (`android-native/tv`) |

See [android-native/README.md](android-native/README.md) to build the Leanback TV app.

## Prerequisites

- Docker and Docker Compose v2 (server)
- Optional native clients: [Flutter stable](https://flutter.dev/docs/get-started/install)
- API keys (free): [TMDB](https://www.themoviedb.org/settings/api), [OMDb](http://www.omdbapi.com/apikey.aspx); AniList optional

## Quick start (server)

```bash
git clone https://github.com/PeanutButterOrg/PeanutButter.git
cd PeanutButter
cp .env.example .env   # local full stack only; server compose needs no .env
```

**Homelab / VPS (recommended):** see [docs/SERVER.md](docs/SERVER.md).

```bash
# Edit PUBLIC_URL in docker-compose.server.yml to your LAN IP or domain
docker compose -f docker-compose.server.yml up -d --build
curl http://127.0.0.1:3001/health
```

**Local full stack** (API + optional web UI):

```bash
docker compose up --build
```

On first boot the API applies migrations, configures Meilisearch, scans `MEDIA_PATH`, and starts metadata sync. Sync also runs on a cron (popular ~every 6h, stale nightly).

| URL | Purpose |
| --- | --- |
| `http://SERVER:3001/` | Console (password) — pairing + Jackett |
| `http://SERVER:3001/health` | Health |
| `http://SERVER:3001/graphql` | GraphQL |

## CI artifacts

GitHub Actions publishes:

| Workflow | Artifacts |
| --- | --- |
| [Platform Builds](.github/workflows/desktop-builds.yml) | Linux portable folder / `.deb` / AppImage, Windows portable folder / setup `.exe`, macOS `PeanutButter-macos-universal.zip` (ditto → `.app`), Android TV APK |
| [Backend & Docker](.github/workflows/backend-docker.yml) | Linux API binary (`.tar.gz`), Docker image `ghcr.io/peanutbutterorg/peanutbutter-api`, offline image `.tar.gz` |

On version tags (`v*`), images are tagged with the semver and `latest`. Pull:

```bash
docker pull ghcr.io/peanutbutterorg/peanutbutter-api:latest
# or pin: ghcr.io/peanutbutterorg/peanutbutter-api:0.2.0
```

Then point compose `image:` at the pulled tag (or keep `build:` for local builds).

## Desktop (Flutter) and Android TV clients

```bash
cd frontend
flutter pub get
flutter run -d linux          # or macos / windows / chrome
```

Android TV uses the native app in `android-native/` (`./scripts/update-apps.sh --tv` builds and installs it over adb). Set the server URL (or **Find server on LAN**), then enter the 6-digit pairing code from the console.

Before pushing, `./scripts/verify.sh` runs the same checks as CI (analyze, tests, builds).

More detail: [frontend/README.md](frontend/README.md) · [backend/README.md](backend/README.md) · [docs/DOCKER.md](docs/DOCKER.md)

## Environment variables

| Variable | Purpose |
| --- | --- |
| `DATABASE_URL` | PostgreSQL (host tools: port **5433**; Compose uses internal DNS) |
| `MEILI_URL` / `MEILI_MASTER_KEY` | Search |
| `TMDB_API_KEY` / `OMDB_API_KEY` / `ANILIST_CLIENT_ID` | Metadata |
| `MEDIA_PATH` | Your media folder (mounted into the API) |
| `STREAM_PATH` | Writable torrent cache (Docker default `/data/streams`) |
| `PUBLIC_URL` | Base URL clients use for playback links |
| `API_KEY` | Optional fixed 6-digit pairing code for the admin device (re-opened for 15 minutes on each boot) |
| `ADMIN_PASSWORD` | Initial web console password (empty = generated and logged; `ADMIN_PASSWORD_RESET=1` forces it) |
| `CORS_ORIGINS` | Extra browser origins allowed to call the API (comma-separated, `*` for any) |
| `PB_RUN_AS_ROOT` | `1` keeps the API container running as root (default: uid 10001) |
| `BIND_ADDR` | Listen address (`0.0.0.0:3001` on host; Compose maps `3001→8080`) |
| `JACKETT_URL` / `JACKETT_API_KEY` | Optional; prefer console after sign-in |
| `RUST_LOG` | Tracing filter |

## GraphQL (selected)

```graphql
query {
  catalog(filter: { kind: MOVIE, yearMin: 1990 }, sort: POPULARITY, page: 1) {
    totalCount
    items { id title year posterUrl ratings { tmdbVoteAverage imdbRating } }
  }
  title(id: "…") {
    synopsis genres trailers { youtubeKey } fileReferences { quality playbackUrl }
  }
  search(query: "matrix") { items { title year } }
  serverInfo { version libraryPath syncStatus { syncing totalTitles lastSyncAt } }
}

mutation { triggerSync { success message } }
```

## File scanning & playback

1. Put files in `MEDIA_PATH` as `Title.Year.Quality.ext` (episodes: `Title.Year.S01E01.Quality.ext`)
2. The watcher matches title + year (and `SxxExx`) to catalog rows
3. `playbackUrl` is `PUBLIC_URL/files/{id}` with HTTP **Range** for seeking
4. Jackett magnets stream on-device via libtorrent (3s seek settle + Range retarget)

Only files you own should live in `MEDIA_PATH`.

## Tests

```bash
cd backend && cargo test
cd frontend && flutter test
```

## Credits

This product uses the TMDB API but is not endorsed or certified by TMDB. IMDb ratings are provided by OMDb. Anime metadata is provided by AniList.
