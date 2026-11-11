# PeanutButter server

The brain of [PeanutButter](../README.md). One Rust binary that serves:
- the catalog and search;
- stream sources;
- device pairing;
- app updates;
- a web console.

It's built on **Axum**, **async-graphql**, **Postgres** and **Meilisearch**.

It doesn't play or store torrents. The apps do that themselves. The server's job is to know what exists, where it can be found, and who is allowed to ask.

---

## What it does

| Area | How |
|---|---|
| **Catalog** | Syncs movies and series from TMDB on a schedule (popular titles about every 6 hours, stale ones nightly). OMDb adds IMDb and Rotten Tomatoes scores, and AniList adds anime data. Text is always English, with English fallbacks for titles from other countries. Adult content is blocked at ingest. |
| **Search** | Meilisearch, typo-tolerant, kept in sync with Postgres |
| **Streaming services** | Catalog add-ons ("Netflix", "HBO Max", …) mark titles with where they're streaming and feed the Trending row |
| **Stream sources** | Jackett and Stremio add-ons (Torrentio, MediaFusion, your own, …), queried in parallel and ranked. Jackett `.torrent` links are turned into magnets before results leave the server. |
| **Your files** | Scans `MEDIA_PATH`, matches files to titles (`Title.Year…`, `S01E01`), and serves them with HTTP Range so seeking is instant |
| **Extras** | Subtitles (OpenSubtitles, Wyzie, sidecar files), intro and credits timings (TheIntroDB), trailers, and new-episode alerts for followed series |
| **Pairing** | 6-digit codes, valid for 15 minutes, traded for a long random device key that's stored hashed |
| **Updates** | Mirrors signed app releases from GitHub so apps on your network update from the server. Updates itself through Watchtower from the console. |
| **Console** | Password-protected web pages at `/`: devices, streaming sources, keys, catalog, sync, updates |

---

## Endpoints

| Path | Who | What |
|---|---|---|
| `GET /` | Browser | Web console (sign in with the admin password) |
| `POST /graphql` | Apps (`X-Api-Key: pbk_…`) | The whole app API |
| `GET /graphql` | Console session | GraphiQL playground |
| `POST /pair` | Apps | `{"code":"482193"}` → `{"key":"pbk_…","deviceName":…}` |
| `GET /files/{id}` | Apps, players | Your media files, with Range support. External players may pass `?key=` |
| `GET /art/tmdb/{size}/{path}` · `/art/youtube/{id}` | Anyone | Image proxy for TVs that can't reach TMDB or YouTube directly |
| `GET /updates/latest` · `/updates/files/{tag}/{name}` | Apps | Signed update manifest and installers |
| `GET /health` | Anyone | Postgres and Meilisearch status |

Try the API in GraphiQL at `http://SERVER:3001/graphql` after signing in to the console:

```graphql
query {
  homeFeed(kind: MOVIE) { trending { title year posterUrl } continueWatching { title } }
  search(query: "the matrx") { items { title year } }
  serverInfo { version syncStatus { syncing totalTitles lastSyncAt } }
}
```

---

## Running it

**With Docker** (what most people want): use the compose files in the repo root. See the [server install guide](../docs/SERVER.md).

**On your machine, for development:**

```bash
# from the repo root: Postgres on 127.0.0.1:5433 and Meilisearch on :7700
docker compose up -d postgres meilisearch
cp .env.example .env          # add TMDB_API_KEY; the rest has working defaults

cd backend
cargo run                     # http://127.0.0.1:3001
```

On startup the server:
1. applies database migrations (see below);
2. sets up Meilisearch;
3. scans `MEDIA_PATH`;
4. starts a catalog sync if the catalog is thin.

The console password is printed in the log on first start, unless you set `ADMIN_PASSWORD`.

**Tests**

```bash
cargo test
```

CI builds with the toolchain pinned in the [Backend & Docker workflow](../.github/workflows/backend-docker.yml).

---

## Code map

| Path | What's inside |
|---|---|
| `src/main.rs` | Startup, routes, background jobs, CORS |
| `src/auth.rs`, `pin.rs`, `ratelimit.rs` | Device keys, pairing codes, failed-attempt limits |
| `src/admin.rs` | The web console (server-rendered HTML) |
| `src/graphql/` | Schema, queries, mutations, types, data loaders |
| `src/db/` | Postgres access and numbered SQL migrations |
| `src/ingest/` | TMDB, OMDb, AniList, Jikan, TVmaze and YTS ingest, plus the sync scheduler |
| `src/search/` | Meilisearch indexing and queries |
| `src/sources/`, `jackett.rs`, `providers.rs`, `torrent_links.rs`, `trackers.rs` | Finding and ranking stream sources |
| `src/addon_catalogs.rs` | Streaming-service lists from catalog add-ons |
| `src/media/` | Library scanner, file serving with Range, image proxy |
| `src/subtitles.rs`, `introdb.rs`, `follows.rs` | Subtitles, intro and credits timings, episode alerts |
| `src/updates.rs`, `server_update.rs` | App update mirror (signature-checked) and server self-update |
| `src/content_filter.rs` | The adult-content block |

### Migrations

Migrations are numbered SQL files in `src/db/migrations/`. They're embedded in the binary, applied in order on startup, and written to be safe to re-run (`IF NOT EXISTS`). The Docker image also ships them in `/app/migrations` (`MIGRATIONS_DIR`).

To add one:
1. Create the next `NNN_name.sql` file.
2. Register it in `src/db/mod.rs`.

---

## Security model

- **Apps** authenticate with a device key (`X-Api-Key` or `Authorization: Bearer`). The server stores only its SHA-256 hash. Keys are minted only by trading a live pairing code at `POST /pair`.
- **Admin rights:** one device is the admin. Server-wide changes in GraphQL (keys, settings, catalog edits) require it.
- **Console:** argon2 password and random session cookies stored hashed, so they can be revoked.
- **Failed attempts** are limited per client. Pairing is also capped server-wide.
- **Updates** are accepted only with a valid Ed25519 signature over a manifest of SHA-256 hashes. The public key is in `src/updates.rs` and `packaging/update-signing-public.pem`.

## Configuration

See the [configuration table](../README.md#configuration) in the main README. Most settings can also be changed live in the console.
