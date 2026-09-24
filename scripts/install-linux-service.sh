#!/usr/bin/env bash
# Install PeanutButter so it always comes back after reboot (systemd + Docker).
#
# On ZimaOS / CasaOS:
#   cd ~/PeanutButter
#   ./scripts/install-linux-service.sh --public-url=http://10.0.0.110:3001
#   # writing the unit needs sudo once; Docker itself runs as your user
#
# Commands:
#   ./scripts/install-linux-service.sh --public-url=http://10.0.0.110:3001
#   ./scripts/install-linux-service.sh --unit-only   # write/enable systemd only (no rebuild)
#   ./scripts/install-linux-service.sh --status
#   ./scripts/install-linux-service.sh --start
#   ./scripts/install-linux-service.sh --stop
#   ./scripts/install-linux-service.sh --uninstall
#   ./scripts/install-linux-service.sh --uninstall --purge
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVICE_NAME="peanutbutter"
UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
COMPOSE_FILE="docker-compose.server.yml"
IMAGE="peanutbutter-api:0.2.0"

PUBLIC_URL=""
DO_UNINSTALL=0
DO_PURGE=0
DO_STOP=0
DO_START=0
DO_STATUS=0
DO_UNIT_ONLY=0
INSTALL_ROOT="$ROOT"

die() { echo "error: $*" >&2; exit 1; }

resolve_docker_user() {
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    echo "${SUDO_USER}"
  elif [[ "${EUID}" -eq 0 ]]; then
    if id ali >/dev/null 2>&1; then echo ali; else echo root; fi
  else
    id -un
  fi
}

DOCKER_USER="$(resolve_docker_user)"
DOCKER_HOME="$(getent passwd "${DOCKER_USER}" | cut -d: -f6 2>/dev/null || echo "/DATA")"
DOCKER_CONFIG_DIR="${INSTALL_ROOT}/.docker-config"
mkdir -p "${DOCKER_CONFIG_DIR}" 2>/dev/null || {
  DOCKER_CONFIG_DIR="/DATA/AppData/peanutbutter/.docker-config"
  mkdir -p "${DOCKER_CONFIG_DIR}"
}
export DOCKER_CONFIG="${DOCKER_CONFIG_DIR}"

# ZimaOS owns docker.sock as root:samba — Group= must match.
docker_sock_group() {
  local sock g
  for sock in /var/run/docker.sock /run/docker.sock; do
    [[ -S "${sock}" ]] || continue
    g="$(stat -c '%G' "${sock}" 2>/dev/null || true)"
    if [[ -n "${g}" && "${g}" != "UNKNOWN" ]]; then
      echo "${g}"
      return 0
    fi
  done
  if getent group docker >/dev/null 2>&1; then
    echo docker
  else
    echo "${DOCKER_USER}"
  fi
}

as_docker_user() {
  local cmd=("$@")
  if [[ "$(id -un)" == "${DOCKER_USER}" ]]; then
    DOCKER_CONFIG="${DOCKER_CONFIG_DIR}" "${cmd[@]}"
  elif command -v runuser >/dev/null 2>&1; then
    runuser -u "${DOCKER_USER}" -- env DOCKER_CONFIG="${DOCKER_CONFIG_DIR}" HOME="${DOCKER_HOME}" "${cmd[@]}"
  else
    sudo -u "${DOCKER_USER}" env DOCKER_CONFIG="${DOCKER_CONFIG_DIR}" HOME="${DOCKER_HOME}" "${cmd[@]}"
  fi
}

detect_public_url() {
  local ip
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
  if [[ -z "${ip}" ]]; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
  echo "http://${ip:-127.0.0.1}:3001"
}

compose() {
  as_docker_user docker compose -f "${INSTALL_ROOT}/${COMPOSE_FILE}" "$@"
}

# Prefer a small local image already present (avoids pulls on every enable).
docker_helper_image() {
  local img
  for img in alpine:3.20 alpine:latest debian:bookworm-slim; do
    if docker image inspect "$img" >/dev/null 2>&1; then
      echo "$img"
      return 0
    fi
  done
  echo "alpine:3.20"
}

can_write_systemd_via_sudo() {
  [[ -d /etc/systemd/system ]] || return 1
  if [[ "${EUID}" -eq 0 ]]; then
    touch /etc/systemd/system/.pb-write-test 2>/dev/null || return 1
    rm -f /etc/systemd/system/.pb-write-test
    return 0
  fi
  sudo -n true 2>/dev/null || return 1
  sudo touch /etc/systemd/system/.pb-write-test 2>/dev/null || return 1
  sudo rm -f /etc/systemd/system/.pb-write-test
  return 0
}

# ZimaOS / CasaOS: user is in docker group but often lacks passwordless sudo.
# Mount /etc/systemd/system into a helper container to install the unit.
can_write_systemd_via_docker() {
  command -v docker >/dev/null 2>&1 || return 1
  [[ -d /etc/systemd/system ]] || return 1
  local img
  img="$(docker_helper_image)"
  docker run --rm -v /etc/systemd/system:/sysd "$img" \
    sh -c 'echo ok > /sysd/.pb-write-test && rm -f /sysd/.pb-write-test' >/dev/null 2>&1
}

can_write_systemd() {
  can_write_systemd_via_sudo || can_write_systemd_via_docker
}

# Run systemctl on the host via privileged nsenter when sudo is unavailable.
sys_via_docker() {
  local img
  img="$(docker_helper_image)"
  docker run --rm --privileged --pid=host "$img" \
    nsenter -t 1 -m -u -i -n systemctl "$@"
}

# Critical: ExecStop uses "stop" NOT "down".
# "down" deletes containers on reboot/shutdown → nothing left if next boot races Docker.
#
# ZimaOS note: docker.service often becomes active *after* multi-user.target, so a
# plain WantedBy=multi-user unit can be skipped entirely. We also install a
# docker.service.d drop-in (Wants=peanutbutter) so compose runs once dockerd is up.
write_unit() {
  local docker_bin unit_group url unit_file boot_script drop_in_dir drop_in
  docker_bin="$(command -v docker)" || die "docker not found"
  unit_group="$(docker_sock_group)"
  url="${PUBLIC_URL}"
  boot_script="${INSTALL_ROOT}/scripts/boot-start.sh"
  unit_file="$(mktemp)"
  drop_in_dir="/etc/systemd/system/docker.service.d"
  drop_in="${drop_in_dir}/peanutbutter.conf"

  chmod +x "${INSTALL_ROOT}/scripts/boot-start.sh" 2>/dev/null || true

  cat >"$unit_file" <<EOF
[Unit]
Description=PeanutButter catalog API (Docker Compose)
Documentation=file://${INSTALL_ROOT}/docs/SERVER.md
# Soft dep: Requires= cancelled this unit when dockerd restarted mid-boot on ZimaOS.
Wants=docker.service network-online.target
After=docker.service docker.socket network-online.target
RequiresMountsFor=${INSTALL_ROOT}
StartLimitIntervalSec=0

[Service]
Type=oneshot
RemainAfterExit=yes
User=${DOCKER_USER}
Group=${unit_group}
WorkingDirectory=${INSTALL_ROOT}
Environment=COMPOSE_PROJECT_NAME=peanutbutter
Environment=DOCKER_CONFIG=${DOCKER_CONFIG_DIR}
Environment=HOME=${DOCKER_HOME}
Environment=PUBLIC_URL=${url}
Environment=PB_BOOT_ATTEMPTS=40
Environment=PB_BOOT_SLEEP=3
ExecStart=${boot_script}
# stop (not down): containers stay defined so Docker restart policy + next boot work
ExecStop=${docker_bin} compose -f ${COMPOSE_FILE} stop
TimeoutStartSec=0
TimeoutStopSec=120

[Install]
WantedBy=multi-user.target
WantedBy=docker.service
EOF

  if [[ "${EUID}" -eq 0 ]]; then
    cp "$unit_file" "${UNIT_PATH}"
    mkdir -p "$drop_in_dir"
    printf '%s\n' '[Unit]' 'Wants=peanutbutter.service' 'After=docker.service' >"$drop_in"
  elif can_write_systemd_via_sudo; then
    sudo cp "$unit_file" "${UNIT_PATH}"
    sudo mkdir -p "$drop_in_dir"
    printf '%s\n' '[Unit]' 'Wants=peanutbutter.service' | sudo tee "$drop_in" >/dev/null
  else
    local img
    img="$(docker_helper_image)"
    docker run --rm \
      -v "$unit_file":/unit.service:ro \
      -v /etc/systemd/system:/sysd \
      "$img" \
      sh -c "cp /unit.service /sysd/${SERVICE_NAME}.service && chmod 644 /sysd/${SERVICE_NAME}.service && mkdir -p /sysd/docker.service.d && printf '%s\\n' '[Unit]' 'Wants=peanutbutter.service' > /sysd/docker.service.d/peanutbutter.conf && chmod 644 /sysd/docker.service.d/peanutbutter.conf"
  fi
  rm -f "$unit_file"
  echo "==> Wrote ${UNIT_PATH} (User=${DOCKER_USER} Group=${unit_group})"
  echo "==> Wrote ${drop_in} (docker.service → Wants peanutbutter)"
  echo "==> PUBLIC_URL=${url}"
  echo "==> Boot script: ${boot_script}"
}

sys() {
  if [[ "${EUID}" -eq 0 ]]; then
    systemctl "$@"
  elif can_write_systemd_via_sudo; then
    sudo systemctl "$@"
  else
    sys_via_docker "$@"
  fi
}

show_status() {
  if systemctl cat "${SERVICE_NAME}.service" >/dev/null 2>&1; then
    sys --no-pager --full status "${SERVICE_NAME}.service" || true
    echo
    echo "enabled: $(sys is-enabled "${SERVICE_NAME}.service" 2>/dev/null || true)"
    echo
  else
    echo "(no systemd unit installed)"
  fi
  compose ps || true
  echo
  local url="${PUBLIC_URL:-$(detect_public_url)}"
  echo "Health (${url%/}/health):"
  curl -fsS --max-time 5 "${url%/}/health" && echo || curl -fsS --max-time 5 "http://127.0.0.1:3001/health" && echo || echo "(not reachable yet)"
}

for arg in "$@"; do
  case "$arg" in
    --uninstall) DO_UNINSTALL=1 ;;
    --purge) DO_PURGE=1 ;;
    --stop) DO_STOP=1 ;;
    --start) DO_START=1 ;;
    --status) DO_STATUS=1 ;;
    --unit-only) DO_UNIT_ONLY=1 ;;
    --public-url=*) PUBLIC_URL="${arg#*=}" ;;
    --public-url) die "use --public-url=http://IP:3001" ;;
    --root=*) INSTALL_ROOT="${arg#*=}" ;;
    -h|--help)
      sed -n '2,18p' "$0"
      exit 0
      ;;
    *) die "unknown argument: $arg (see --help)" ;;
  esac
done

command -v docker >/dev/null 2>&1 || die "docker is required"
[[ -f "${INSTALL_ROOT}/${COMPOSE_FILE}" ]] || die "compose file not found: ${INSTALL_ROOT}/${COMPOSE_FILE}"
mkdir -p "${INSTALL_ROOT}/media" "${DOCKER_CONFIG_DIR}"

echo "==> Docker user: ${DOCKER_USER}"
echo "==> DOCKER_CONFIG: ${DOCKER_CONFIG_DIR}"
echo "==> Install root: ${INSTALL_ROOT}"

if [[ "$DO_STATUS" -eq 1 ]]; then
  show_status
  exit 0
fi

if [[ "$DO_STOP" -eq 1 ]]; then
  if systemctl cat "${SERVICE_NAME}.service" >/dev/null 2>&1; then
    sys stop "${SERVICE_NAME}.service" || true
  else
    compose stop || true
  fi
  echo "Stopped (containers kept for next boot)."
  exit 0
fi

if [[ "$DO_START" -eq 1 ]]; then
  if [[ -z "$PUBLIC_URL" ]]; then PUBLIC_URL="$(detect_public_url)"; fi
  export PUBLIC_URL
  if systemctl cat "${SERVICE_NAME}.service" >/dev/null 2>&1; then
    sys reset-failed "${SERVICE_NAME}.service" 2>/dev/null || true
    sys start "${SERVICE_NAME}.service"
  else
    compose up -d --remove-orphans
  fi
  show_status
  exit 0
fi

if [[ "$DO_UNINSTALL" -eq 1 ]]; then
  echo "==> Stopping / disabling ${SERVICE_NAME}"
  if systemctl cat "${SERVICE_NAME}.service" >/dev/null 2>&1; then
    sys disable --now "${SERVICE_NAME}.service" 2>/dev/null || true
    if [[ "${EUID}" -eq 0 ]]; then
      rm -f "${UNIT_PATH}" /etc/systemd/system/docker.service.d/peanutbutter.conf
    elif can_write_systemd_via_sudo; then
      sudo rm -f "${UNIT_PATH}" /etc/systemd/system/docker.service.d/peanutbutter.conf
    else
      local img
      img="$(docker_helper_image)"
      docker run --rm -v /etc/systemd/system:/sysd "$img" \
        sh -c "rm -f /sysd/${SERVICE_NAME}.service /sysd/docker.service.d/peanutbutter.conf" || true
    fi
    sys daemon-reload || true
  fi
  if [[ "$DO_PURGE" -eq 1 ]]; then
    echo "==> Removing containers + volumes"
    compose down -v --remove-orphans || true
  else
    compose down --remove-orphans || true
  fi
  echo "Uninstalled."
  exit 0
fi

# --- install / enable ---
if [[ -z "$PUBLIC_URL" ]]; then
  PUBLIC_URL="$(detect_public_url)"
fi
export PUBLIC_URL

if [[ "$DO_UNIT_ONLY" -eq 0 ]]; then
  echo "==> Building API image ${IMAGE} (if needed)"
  as_docker_user docker build -t "${IMAGE}" "${INSTALL_ROOT}/backend"
fi

# Bring stack up first so health works even before unit is written.
echo "==> Starting compose stack"
compose up -d --remove-orphans

if can_write_systemd || [[ "${EUID}" -eq 0 ]]; then
  write_unit
  sys daemon-reload
  sys enable "${SERVICE_NAME}.service"
  sys reset-failed "${SERVICE_NAME}.service" 2>/dev/null || true
  sys restart "${SERVICE_NAME}.service" || sys start "${SERVICE_NAME}.service"
  echo
  echo "PeanutButter enabled on boot as systemd service '${SERVICE_NAME}'."
  echo "  (ExecStop uses compose stop — not down — so reboot keeps the stack.)"
else
  echo
  echo "Could not write systemd unit (need sudo or Docker write to /etc/systemd/system)."
  echo "Stack is running now with Docker restart: always."
  echo "To enable on boot, re-run with sudo:"
  echo "  sudo ./scripts/install-linux-service.sh --public-url=${PUBLIC_URL} --root=${INSTALL_ROOT} --unit-only"
fi

echo "  Console:  ${PUBLIC_URL}/"
echo "  Health:   ${PUBLIC_URL}/health"
echo "  Status:   $0 --status"
echo "  Stop:     $0 --stop"
echo
show_status
