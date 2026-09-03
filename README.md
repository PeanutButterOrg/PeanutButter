# PeanutButter

Self-hosted media catalog for **your own legally owned files**. Metadata comes from official APIs:

- [TMDB](https://www.themoviedb.org/) — posters, trailers, genres, TMDB ratings
- [OMDb](http://www.omdbapi.com/) — IMDb ratings only (IMDb is never scraped)
- [AniList](https://anilist.co/) — anime metadata

Playback is served from a directory you mount (`MEDIA_PATH`) for local files. Jackett magnets are resolved by the API; each app (desktop / TV) streams torrents itself.

## Architecture

| Service | Role |
| --- | --- |
| `api` (Rust / Axum / async-graphql) | GraphQL catalog, ingest, Jackett magnets, pairing codes |
| `postgres` (16) | Titles, progress, saved torrent listings |
| `meilisearch` | Typo-tolerant search |

Pair devices at <http://localhost:3001/> (password-protected console) with 6-digit codes. GraphiQL is at <http://localhost:3001/graphql> after you sign in.

## Prerequisites

- Docker and Docker Compose v2
- For a native desktop/mobile client: [Flutter 3.24+](https://flutter.dev/docs/get-started/install)
- API keys (free):
  - **TMDB** — <https://www.themoviedb.org/settings/api>
  - **OMDb** — <http://www.omdbapi.com/apikey.aspx>
  - **AniList** — optional; public GraphQL works without a client id

## Setup

```bash
git clone <your-fork> peanutbutter
cd peanutbutter
cp .env.example .env
```

Edit `.env` and set at least `TMDB_API_KEY`. Point `MEDIA_PATH` at a folder of your own media:

```bash
# Expected filename pattern
#   Title.Year.Quality.ext
#   Title.Year.S01E01.Quality.ext
# Example:
#   The.Matrix.1999.1080p.mkv
mkdir -p media
```

## Run (Docker)

Local full stack (API + catalog web UI):

```bash
docker compose up --build
```

### Host the API on a server

**Full install guide:** [docs/SERVER.md](docs/SERVER.md)  
(Docker VPS, CasaOS/ZimaOS — **no `.env` required**, pairing, Jackett, firewall)

Short version:

```bash
# Optional: edit PUBLIC_URL in docker-compose.server.yml if IP ≠ 10.0.0.28
docker compose -f docker-compose.server.yml up -d --build
```

Pair TVs at `http://YOUR_SERVER_IP:3001/` after signing in. Point the app at that URL and type the 6-digit device code. Configure Jackett once in the console.

Health check: `http://YOUR_SERVER_IP:3001/health`.

If Jackett runs on the host, set `JACKETT_URL` / `JACKETT_API_KEY` in the compose `environment` block (or in the web console).

On first boot the API:

1. Applies `backend/src/db/migrations/001_initial.sql`
2. Configures the Meilisearch `titles` index
3. Scans `MEDIA_PATH`
4. Starts a metadata sync (popular/trending movies, TV, anime)

Then open:

- Pairing: <http://localhost:3001/>
- GraphQL: <http://localhost:3001/graphql>
- Health: <http://localhost:3001/health>

Sync also runs every 6 hours (popular/trending) and nightly (titles older than 7 days). You can trigger it from **Settings → Trigger metadata sync**.

## Native Flutter client

```bash
cd frontend
flutter create . --project-name peanutbutter --org app.peanutbutter
flutter pub get
flutter run -d linux          # or macos / windows / chrome / android
```

Set the server URL in Settings, or tap **Discover on LAN**. Discovery probes:

1. Saved URL in `shared_preferences`
2. `http://127.0.0.1:3001` (and `10.0.2.2` on Android emulator)
3. The local subnet (`192.168.x` / `10.0.0.x`)
4. Optional mDNS `_peanutbutter._tcp`

If nothing answers, the Settings screen stays available.

## Environment variables

| Variable | Purpose |
| --- | --- |
| `DATABASE_URL` | PostgreSQL connection string (host tools: port **5433**; Compose overrides this inside `api`) |
| `MEILI_URL` / `MEILI_MASTER_KEY` | Search backend |
| `TMDB_API_KEY` | TMDB metadata |
| `OMDB_API_KEY` | IMDb ratings via OMDb |
| `ANILIST_CLIENT_ID` | Optional AniList app id |
| `MEDIA_PATH` | Host folder of your media (mounted into the API container) |
| `STREAM_PATH` | Writable torrent cache (Docker default `/data/streams`) |
| `TORRENT_LISTEN_PORT` | BitTorrent listen port (Docker default `6881`) |
| `PUBLIC_URL` | Base URL used to build playback links |
| `API_KEY` | Optional 6-digit server pairing code |
| `ADMIN_PASSWORD` | Password for the web console at `/` |
| `BIND_ADDR` | API listen address (`0.0.0.0:3001` on the host; Compose maps host 3001 → container 8080) |
| `RUST_LOG` | Tracing filter |

LAN discovery fills the server address only. Devices must type the 6-digit code from the signed-in console. Jackett is configured there once for every device.

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

1. Drop files into `MEDIA_PATH` using `Title.Year.Quality.ext`
2. The watcher matches `title + year` (and `SxxExx` for episodes) to catalog rows
3. A `FileReference` is stored; `playbackUrl` is `PUBLIC_URL/files/{id}`
4. The player requests that URL with HTTP **Range** headers so seeking works

Only files that belong to you should be placed in `MEDIA_PATH`.

## Tests

```bash
cd backend && cargo test
cd frontend && flutter test
```

## Credits

This product uses the TMDB API but is not endorsed or certified by TMDB. IMDb ratings are provided by OMDb. Anime metadata is provided by AniList.
