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
RUN touch src/main.rs && cargo build --release \
    && strip /app/target/release/peanutbutter

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates wget \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /app /media /data/streams

WORKDIR /app
COPY --from=builder /app/target/release/peanutbutter /usr/local/bin/peanutbutter
COPY src/db/migrations /app/migrations

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

CMD ["peanutbutter"]
