# syntax=docker/dockerfile:1

FROM rust:1-bookworm AS builder
WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends pkg-config ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY Cargo.toml Cargo.lock ./
RUN mkdir -p src && echo "fn main() {}" > src/main.rs \
    && cargo build --release \
    && rm -rf src

COPY src ./src
# Release version from CI (vX.Y.Z tag); the console compares it with the
# latest GitHub release to offer server updates. Empty = Cargo.toml version.
ARG PB_VERSION=""
ENV PB_SERVER_VERSION=${PB_VERSION}
RUN touch src/main.rs && cargo build --release \
    && strip /app/target/release/peanutbutter

FROM debian:bookworm-slim
# postgresql-client-16 (PGDG) matches the postgres:16 server, for the backup
# taken before every self-update.
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates wget \
    && install -d /usr/share/postgresql-common/pgdg \
    && wget -qO /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc https://www.postgresql.org/media/keys/ACCC4CF8.asc \
    && echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] http://apt.postgresql.org/pub/repos/apt bookworm-pgdg main" > /etc/apt/sources.list.d/pgdg.list \
    && apt-get update && apt-get install -y --no-install-recommends postgresql-client-16 \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /app /media /data/streams /data/backups /data/control \
    && useradd --system --uid 10001 --user-group --home-dir /app --no-create-home pb \
    && chown -R pb:pb /data

WORKDIR /app
COPY --from=builder /app/target/release/peanutbutter /usr/local/bin/peanutbutter
COPY src/db/migrations /app/migrations
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

ENV MIGRATIONS_DIR=/app/migrations \
    BIND_ADDR=0.0.0.0:8080 \
    MEDIA_PATH=/media \
    STREAM_PATH=/data/streams \
    TORRENT_LISTEN_PORT=6881 \
    RUST_LOG=peanutbutter=info,tower_http=info

EXPOSE 8080 6881/tcp 6881/udp
VOLUME ["/media", "/data/streams"]

HEALTHCHECK --interval=10s --timeout=5s --start-period=20s --retries=12 \
    CMD wget --no-verbose --tries=1 --spider http://127.0.0.1:8080/health || exit 1

# Starts as root only to fix /data ownership on existing volumes, then runs
# as uid 10001 (PB_RUN_AS_ROOT=1 opts out).
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["peanutbutter"]
