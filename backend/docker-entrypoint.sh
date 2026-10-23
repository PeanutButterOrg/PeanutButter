#!/bin/sh
# Drop root before starting the API. Only /data (stream scratch space) is
# re-owned; the media library at /media is never touched and must be
# readable by uid 10001 (or set PB_RUN_AS_ROOT=1).
set -e
if [ "$(id -u)" = "0" ] && [ "${PB_RUN_AS_ROOT:-0}" != "1" ]; then
  mkdir -p /data/streams /data/backups /data/control
  chown -R pb:pb /data 2>/dev/null || true
  exec setpriv --reuid=pb --regid=pb --init-groups -- "$@"
fi
exec "$@"
