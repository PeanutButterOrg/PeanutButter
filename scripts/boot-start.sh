#!/usr/bin/env bash
# Bring PeanutButter up after boot. Retries until Docker + /DATA are ready.
# Used by peanutbutter.service (ZimaOS starts docker *after* multi-user.target).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.server.yml}"
DOCKER_BIN="$(command -v docker || echo /usr/bin/docker)"
LOG="${ROOT}/boot-start.log"
MAX_ATTEMPTS="${PB_BOOT_ATTEMPTS:-40}"
SLEEP_SECS="${PB_BOOT_SLEEP:-3}"

export DOCKER_CONFIG="${DOCKER_CONFIG:-${ROOT}/.docker-config}"
export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-peanutbutter}"
export PUBLIC_URL="${PUBLIC_URL:-http://10.0.0.110:3001}"

mkdir -p "$(dirname "$LOG")" "${DOCKER_CONFIG}" 2>/dev/null || true
exec >>"$LOG" 2>&1
echo "==== $(date -Is) boot-start begin root=${ROOT} ===="

if [[ ! -f "${ROOT}/${COMPOSE_FILE}" ]]; then
  echo "error: missing ${ROOT}/${COMPOSE_FILE}"
  exit 1
fi

cd "$ROOT" || exit 1

attempt=1
while (( attempt <= MAX_ATTEMPTS )); do
  if [[ ! -S /var/run/docker.sock && ! -S /run/docker.sock ]]; then
    echo "[$attempt/$MAX_ATTEMPTS] waiting for docker.sock…"
    sleep "$SLEEP_SECS"
    attempt=$((attempt + 1))
    continue
  fi

  if ! "$DOCKER_BIN" info >/dev/null 2>&1; then
    echo "[$attempt/$MAX_ATTEMPTS] docker not ready yet…"
    sleep "$SLEEP_SECS"
    attempt=$((attempt + 1))
    continue
  fi

  echo "[$attempt/$MAX_ATTEMPTS] docker compose up -d…"
  if "$DOCKER_BIN" compose -f "$COMPOSE_FILE" up -d --remove-orphans; then
    echo "==== $(date -Is) boot-start OK ===="
    exit 0
  fi
  ec=$?
  echo "[$attempt/$MAX_ATTEMPTS] compose failed (exit ${ec}); retrying…"
  sleep "$SLEEP_SECS"
  attempt=$((attempt + 1))
done

echo "==== $(date -Is) boot-start FAILED after ${MAX_ATTEMPTS} attempts ===="
exit 255
