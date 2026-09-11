#!/usr/bin/env bash
# Thin wrapper kept for older docs / muscle memory.
# Prefer: ./scripts/manage-server.sh update|reinstall|uninstall|…
#
# Maps:
#   ./scripts/update-server.sh              → manage-server.sh update
#   ./scripts/update-server.sh --rebuild    → manage-server.sh reinstall
#   ./scripts/update-server.sh --status     → manage-server.sh status
#   ./scripts/update-server.sh --logs       → manage-server.sh logs
#   ./scripts/update-server.sh --down       → manage-server.sh stop
#   ./scripts/update-server.sh --purge-data → manage-server.sh purge
#   ./scripts/update-server.sh --remote H   → manage-server.sh --remote H …
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MGR="$ROOT/scripts/manage-server.sh"
[[ -x "$MGR" ]] || chmod +x "$MGR"

remote=""
cmd="update"
args=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rebuild) cmd="reinstall"; shift ;;
    --status) cmd="status"; shift ;;
    --logs) cmd="logs"; shift ;;
    --down) cmd="stop"; shift ;;
    --purge-data) cmd="purge"; shift ;;
    --remote)
      remote="$2"
      shift 2
      ;;
    --remote=*)
      remote="${1#--remote=}"
      shift
      ;;
    -h|--help)
      exec "$MGR" help
      ;;
    update|reinstall|start|stop|restart|status|logs|uninstall|purge|help)
      cmd="$1"
      shift
      ;;
    *)
      args+=("$1")
      shift
      ;;
  esac
done

if [[ -n "$remote" ]]; then
  exec "$MGR" --remote "$remote" "$cmd" "${args[@]:-}"
else
  exec "$MGR" "$cmd" "${args[@]:-}"
fi
