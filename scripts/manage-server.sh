#!/usr/bin/env bash
# PeanutButter server manager — Docker stack on ZimaOS / CasaOS / Linux.
#
# Run ON the server (as your normal user, NOT root):
#   cd /DATA/AppData/peanutbutter
#   ./scripts/manage-server.sh <command>
#
# Or from your PC:
#   ./scripts/manage-server.sh --remote ali@10.0.0.110 update
#   ./scripts/manage-server.sh --remote ali@10.0.0.110 reinstall
#
# Commands:
#   push         Build API image on THIS machine, copy to remote, restart (fast)
#   update       Build image on the target host (cache OK) and restart — keeps catalog DB
#   reinstall    Rebuild image with --no-cache and restart — keeps catalog DB
#   enable       Install/fix systemd unit so stack auto-starts on every reboot
#   start        Start existing stack (no rebuild)
#   stop         Stop containers (keeps them for next boot — does NOT delete)
#   restart      Restart containers — no rebuild
#   status       Show compose ps + health
#   logs         Follow API logs (Ctrl+C to stop)
#   uninstall    Remove containers + API image — keeps catalog volumes
#   purge        DANGEROUS: uninstall + delete Postgres/Meili volumes (wipes catalog)
#   help         Show this help
#
# From your PC (preferred — builds locally, pushes to Zima):
#   ./scripts/manage-server.sh --remote zima push
#
# Environment:
#   PB_APP_DIR=/DATA/AppData/peanutbutter
#   PB_PUBLIC_URL=http://10.0.0.110:3001
#   PB_DOCKER_CONFIG=/DATA/AppData/peanutbutter/.docker-config
#   COMPOSE_FILE=docker-compose.server.yml
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="peanutbutter-api:0.2.0"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.server.yml}"
remote=""
cmd=""

usage() {
  sed -n '2,36p' "$0"
}

die() { echo "error: $*" >&2; exit 1; }

# Parse flags + command
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help|help)
      usage
      exit 0
      ;;
    --remote)
      [[ $# -ge 2 ]] || die "--remote needs host (e.g. ali@10.0.0.110)"
      remote="$2"
      shift 2
      ;;
    --remote=*)
      remote="${1#--remote=}"
      shift
      ;;
    -*)
      die "unknown flag: $1 (try: help)"
      ;;
    *)
      cmd="$1"
      shift
      break
      ;;
  esac
done

# Legacy flag aliases when no subcommand given
if [[ -z "$cmd" ]]; then
  cmd="update"
fi
# Allow trailing args ignored for now
extra=("$@")

detect_lan_ip() {
  if command -v ip >/dev/null 2>&1; then
    ip -4 route get 1.1.1.1 2>/dev/null \
      | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}'
    return 0
  fi
  hostname -I 2>/dev/null | awk '{print $1}'
}

ensure_public_url() {
  # Never sed the compose file (often owned by root / not writable).
  # docker-compose.server.yml reads ${PUBLIC_URL} from the environment.
  local url="${PB_PUBLIC_URL:-${PUBLIC_URL:-}}"
  if [[ -z "$url" ]]; then
    local ip
    ip="$(detect_lan_ip || true)"
    if [[ -n "$ip" ]]; then
      url="http://${ip}:3001"
    else
      url="http://127.0.0.1:3001"
    fi
  fi
  export PUBLIC_URL="$url"
  echo "PUBLIC_URL → $PUBLIC_URL"
}

setup_docker_config() {
  local cfg="${PB_DOCKER_CONFIG:-}"
  if [[ -z "$cfg" && -d /DATA/AppData/peanutbutter ]]; then
    cfg="/DATA/AppData/peanutbutter/.docker-config"
  fi
  if [[ -n "$cfg" ]]; then
    mkdir -p "$cfg"
    export DOCKER_CONFIG="$cfg"
    echo "DOCKER_CONFIG=$DOCKER_CONFIG"
  fi
}

compose() {
  docker compose -f "$COMPOSE_FILE" "$@"
}

wait_health() {
  echo "Waiting for health…"
  local ok=0
  for _ in $(seq 1 60); do
    if curl -fsS "http://127.0.0.1:3001/health" >/dev/null 2>&1; then
      ok=1
      break
    fi
    sleep 1
  done
  compose ps
  if [[ "$ok" -eq 1 ]]; then
    curl -fsS "http://127.0.0.1:3001/health" && echo
    local ip
    ip="$(detect_lan_ip 2>/dev/null || echo YOUR_SERVER)"
    echo
    echo "Console:  http://${ip}:3001/"
    echo "Force sync from the web console when you want a full catalog refresh."
  else
    echo "API not healthy yet — check: docker compose -f $COMPOSE_FILE logs -f api" >&2
    return 1
  fi
}

build_image() {
  local no_cache="${1:-0}"
  local args=(build -t "$IMAGE")
  if [[ "$no_cache" -eq 1 ]]; then
    args+=(--no-cache)
  fi
  args+=(./backend)
  echo "==> Building $IMAGE$([ "$no_cache" -eq 1 ] && echo ' (no cache)' || true)"
  docker "${args[@]}"
}

cmd_update() {
  mkdir -p media
  ensure_public_url
  build_image 0
  echo "==> Starting stack (volumes preserved)"
  compose up -d --remove-orphans
  ensure_boot_service
  wait_health
}

cmd_reinstall() {
  echo "==> Reinstall: no-cache rebuild → start (catalog volumes kept)"
  # Prefer stop over down so systemd/boot still has container definitions if rebuild fails mid-way.
  compose stop 2>/dev/null || true
  mkdir -p media
  ensure_public_url
  build_image 1
  compose up -d --remove-orphans
  ensure_boot_service
  wait_health
}

cmd_start() {
  mkdir -p media
  ensure_public_url
  if systemctl cat peanutbutter.service >/dev/null 2>&1; then
    sudo systemctl reset-failed peanutbutter.service 2>/dev/null || true
    sudo systemctl start peanutbutter.service || compose up -d --remove-orphans
  else
    compose up -d --remove-orphans
  fi
  wait_health
}

cmd_stop() {
  # Never "down" here — that deletes containers and breaks reboot autostart.
  if systemctl cat peanutbutter.service >/dev/null 2>&1; then
    sudo systemctl stop peanutbutter.service 2>/dev/null || compose stop
  else
    compose stop
  fi
  echo "Stopped (containers kept for next boot; volumes / catalog kept)."
}

cmd_restart() {
  if systemctl cat peanutbutter.service >/dev/null 2>&1; then
    sudo systemctl restart peanutbutter.service || compose restart
  else
    compose restart
  fi
  wait_health
}

cmd_enable() {
  ensure_public_url
  local installer="$ROOT/scripts/install-linux-service.sh"
  [[ -f "$installer" ]] || die "missing $installer"
  chmod +x "$installer"
  echo "==> Enabling PeanutButter to start on every reboot"
  # Image already on host after push/update — only write/enable the systemd unit.
  "$installer" --public-url="${PUBLIC_URL}" --root="$(pwd)" --unit-only
}

# Refresh systemd unit if present; otherwise install it so reboot brings the stack up.
ensure_boot_service() {
  ensure_public_url
  if ! systemctl cat peanutbutter.service >/dev/null 2>&1; then
    echo "==> Installing peanutbutter.service for boot autostart"
    cmd_enable
    return 0
  fi
  # Keep PUBLIC_URL in the unit in sync without a full image rebuild.
  if [[ -n "${PUBLIC_URL:-}" ]] && command -v sudo >/dev/null 2>&1; then
    if sudo grep -q '^Environment=PUBLIC_URL=' /etc/systemd/system/peanutbutter.service 2>/dev/null; then
      sudo sed -i -E "s|^Environment=PUBLIC_URL=.*|Environment=PUBLIC_URL=${PUBLIC_URL}|" \
        /etc/systemd/system/peanutbutter.service 2>/dev/null || true
      sudo systemctl daemon-reload 2>/dev/null || true
    fi
  fi
  sudo systemctl reset-failed peanutbutter.service 2>/dev/null || true
  sudo systemctl enable peanutbutter.service 2>/dev/null || true
  sudo systemctl restart peanutbutter.service 2>/dev/null \
    || compose up -d --remove-orphans
}

cmd_status() {
  compose ps
  echo
  curl -fsS "http://127.0.0.1:3001/health" && echo || echo "health: unreachable"
}

cmd_logs() {
  compose logs -f --tail=200 api
}

cmd_uninstall() {
  echo "==> Uninstall: remove containers + API image (catalog volumes kept)"
  compose down --remove-orphans
  docker image rm -f "$IMAGE" 2>/dev/null || true
  echo "Uninstalled. Catalog volumes remain."
  echo "To wipe the catalog too: ./scripts/manage-server.sh purge"
}

cmd_purge() {
  echo "WARNING: this deletes Postgres + Meilisearch volumes (full catalog wipe)."
  read -r -p "Type YES to purge data and remove the stack: " ans
  [[ "$ans" == "YES" ]] || die "aborted"
  compose down -v --remove-orphans
  docker image rm -f "$IMAGE" 2>/dev/null || true
  echo "Purged containers, volumes, and API image."
}

remote_run() {
  local host="$1"
  local remote_dir="${PB_APP_DIR:-/DATA/AppData/peanutbutter}"

  # Local build → transfer image → remote restart (much faster than building on Zima).
  if [[ "$cmd" == "push" ]]; then
    remote_push "$host" "$remote_dir"
    return
  fi

  echo "==> Syncing repo → ${host}:${remote_dir}"
  ssh -o BatchMode=yes "$host" "mkdir -p '$remote_dir'"
  # Anchor excludes with / so only repo-root paths match (plain "media/"
  # also deleted backend/src/media/ and broke the Docker build).
  rsync -az --delete \
    --exclude '/.git/' \
    --exclude '/frontend/build/' \
    --exclude '/backend/target/' \
    --exclude '/dist/*.tar.gz' \
    --exclude '/media/' \
    --exclude '/.dart_tool/' \
    --exclude '/node_modules/' \
    --exclude '/frontend/.dart_tool/' \
    --exclude '/frontend/node_modules/' \
    "$ROOT/" "${host}:${remote_dir}/"
  echo "==> Running on $host: manage-server.sh $cmd"
  # Prefer login shell so PATH/docker group apply; never use sudo docker on Zima.
  ssh -t "$host" "cd '$remote_dir' && chmod +x scripts/manage-server.sh && ./scripts/manage-server.sh $cmd"
}

# Build the API image on this machine, ship it to the remote host, restart stack.
remote_push() {
  local host="$1"
  local remote_dir="$2"

  if ! command -v docker >/dev/null 2>&1; then
    die "docker is required on this machine for push"
  fi

  echo "==> Syncing compose/scripts → ${host}:${remote_dir}"
  ssh -o BatchMode=yes "$host" "mkdir -p '$remote_dir'"
  rsync -az --delete \
    --exclude '/.git/' \
    --exclude '/frontend/build/' \
    --exclude '/backend/target/' \
    --exclude '/dist/*.tar.gz' \
    --exclude '/media/' \
    --exclude '/.dart_tool/' \
    --exclude '/node_modules/' \
    --exclude '/frontend/.dart_tool/' \
    --exclude '/frontend/node_modules/' \
    "$ROOT/" "${host}:${remote_dir}/"

  echo "==> Building $IMAGE locally (this is the slow step — once)"
  (cd "$ROOT" && docker build -t "$IMAGE" ./backend)

  echo "==> Transferring image → $host (docker save | ssh load)"
  docker save "$IMAGE" | gzip -1 | ssh -o BatchMode=yes "$host" \
    "mkdir -p '${remote_dir}/.docker-config' && DOCKER_CONFIG='${remote_dir}/.docker-config' gunzip | DOCKER_CONFIG='${remote_dir}/.docker-config' docker load"

  local public_url="${PB_PUBLIC_URL:-${PUBLIC_URL:-http://10.0.0.110:3001}}"
  echo "==> Restarting stack on $host (force-recreate api with new image)"
  # Avoid bash -lc (login profile can confuse cwd). Use a non-interactive remote shell.
  # Health can lag a few seconds after recreate — wait instead of failing the push.
  ssh -o BatchMode=yes "$host" \
    "export DOCKER_CONFIG='${remote_dir}/.docker-config' PUBLIC_URL='$public_url'; \
     cd '$remote_dir' && \
     chmod +x scripts/manage-server.sh scripts/install-linux-service.sh && \
     docker compose -f '$COMPOSE_FILE' up -d --no-build --force-recreate --remove-orphans api && \
     docker compose -f '$COMPOSE_FILE' up -d --no-build --remove-orphans && \
     for i in \$(seq 1 40); do \
       if curl -fsS http://127.0.0.1:3001/health >/dev/null 2>&1; then \
         curl -fsS http://127.0.0.1:3001/health && echo && exit 0; \
       fi; \
       sleep 2; \
     done; \
     echo 'warning: health not ready yet' >&2; exit 0"

  echo "==> Enabling systemd autostart on boot ($host)"
  # Uses sudo when available, else Docker mount + nsenter (ZimaOS / no passwordless sudo).
  ssh -o BatchMode=yes "$host" \
    "export DOCKER_CONFIG='${remote_dir}/.docker-config' PUBLIC_URL='$public_url' PB_APP_DIR='$remote_dir'; \
     cd '$remote_dir' && \
     chmod +x scripts/manage-server.sh scripts/install-linux-service.sh && \
     ./scripts/manage-server.sh enable" \
    || echo "warning: enable failed. Containers still have restart: always."

  echo
  echo "Pushed $IMAGE to $host. Console: $public_url/"
  echo "Boot: peanutbutter.service should be enabled (systemctl is-enabled peanutbutter)."
}

local_run() {
  if [[ "$(id -u)" -eq 0 ]]; then
    die "do not run as root on ZimaOS (Docker config is read-only for root). Run as your normal user (e.g. ali)."
  fi
  if ! command -v docker >/dev/null 2>&1; then
    die "docker is required"
  fi

  setup_docker_config

  local app_dir="${PB_APP_DIR:-$ROOT}"
  cd "$app_dir"
  [[ -f "$COMPOSE_FILE" ]] || die "missing $COMPOSE_FILE in $app_dir"
  [[ -d backend ]] || die "missing backend/ in $app_dir"

  case "$cmd" in
    push)
      die "push needs --remote HOST (builds here, loads there). Example: ./scripts/manage-server.sh --remote zima push"
      ;;
    update)     cmd_update ;;
    reinstall)  cmd_reinstall ;;
    enable|install-service) cmd_enable ;;
    start)      cmd_start ;;
    stop|down)  cmd_stop ;;
    restart)    cmd_restart ;;
    status)     cmd_status ;;
    logs)       cmd_logs ;;
    uninstall)  cmd_uninstall ;;
    purge|purge-data) cmd_purge ;;
    *)
      die "unknown command: $cmd (try: help)"
      ;;
  esac
}

# Silence unused when no extras
: "${extra[@]:-}"

if [[ -n "$remote" ]]; then
  remote_run "$remote"
else
  local_run
fi
