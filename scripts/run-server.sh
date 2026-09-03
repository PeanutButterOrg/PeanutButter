#!/usr/bin/env bash
# Build the PeanutButter API image and start the full stack (keeps running).
#
# Usage:
#   ./scripts/run-server.sh              # build + up -d
#   ./scripts/run-server.sh --rebuild    # force rebuild
#   ./scripts/run-server.sh --save       # also write dist/peanutbutter-api-0.2.0.tar.gz
#   ./scripts/run-server.sh --down       # stop stack
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

COMPOSE=(docker compose -f docker-compose.server.yml)
IMAGE="peanutbutter-api:0.2.0"
TAG="0.2.0"

do_down=0
do_rebuild=0
do_save=0
for arg in "$@"; do
  case "$arg" in
    --down) do_down=1 ;;
    --rebuild) do_rebuild=1 ;;
    --save) do_save=1 ;;
    -h|--help)
      sed -n '2,10p' "$0"
      exit 0
      ;;
  esac
done

if [[ "$do_down" -eq 1 ]]; then
  "${COMPOSE[@]}" down
  echo "Stopped."
  exit 0
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required" >&2
  exit 1
fi

mkdir -p media dist

build_args=(build)
if [[ "$do_rebuild" -eq 1 ]]; then
  build_args+=(--no-cache)
fi
build_args+=(-t "$IMAGE" ./backend)

echo "==> Building $IMAGE"
docker "${build_args[@]}"

echo "==> Starting stack (restart: unless-stopped)"
"${COMPOSE[@]}" up -d --remove-orphans

if [[ "$do_save" -eq 1 ]]; then
  out="dist/peanutbutter-api-${TAG}.tar.gz"
  echo "==> Saving $IMAGE → $out"
  docker save "$IMAGE" | gzip -1 >"$out"
  ls -lh "$out"
fi

echo
echo "API console:  http://127.0.0.1:3001/"
echo "Health:       http://127.0.0.1:3001/health"
echo "Logs:         ${COMPOSE[*]} logs -f api"
echo "Stop:         ./scripts/run-server.sh --down"
echo
"${COMPOSE[@]}" ps
curl -fsS "http://127.0.0.1:3001/health" && echo
