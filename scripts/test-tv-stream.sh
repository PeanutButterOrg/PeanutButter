#!/usr/bin/env bash
# Android TV emulator stream smoke test (Exo path).
# Usage: scripts/test-tv-stream.sh [SERIAL] [SERVER] [TOKEN]
set -euo pipefail

SERIAL="${1:-emulator-5554}"
SERVER="${2:-http://10.0.0.110:3001}"
TOKEN="${3:-204295}"
PKG=app.peanutbutter.peanutbutter
OUT_DIR="${TMPDIR:-/tmp}/pb-tv-stream-test"
mkdir -p "$OUT_DIR"
rm -f "$OUT_DIR"/*.png "$OUT_DIR"/*.xml 2>/dev/null || true
ADB=(adb -s "$SERIAL")

pass=0
fail=0
log() { printf '%s\n' "$*"; }
ok() { log "PASS: $*"; pass=$((pass + 1)); }
bad() { log "FAIL: $*"; fail=$((fail + 1)); }
shot() { "${ADB[@]}" exec-out screencap -p >"$OUT_DIR/$1.png"; }

in_app() {
  "${ADB[@]}" shell dumpsys window 2>/dev/null | grep -q "mCurrentFocus.*$PKG"
}

key() {
  "${ADB[@]}" shell input keyevent "$1"
  sleep 0.65
  if ! in_app; then
    log "WARN: left $PKG after keyevent $1"
    return 1
  fi
  return 0
}

log "==> backend pipeline first"
if /home/ali/Desktop/PeanutButter/scripts/test-stream-pipeline.sh "$SERVER" "$TOKEN" Inception; then
  ok "backend stream pipeline"
else
  bad "backend stream pipeline"
  exit 1
fi

log "==> launch $PKG"
"${ADB[@]}" shell am force-stop "$PKG" || true
sleep 0.6
"${ADB[@]}" logcat -c || true
"${ADB[@]}" shell am start -n "$PKG/.MainActivity" >/dev/null
for i in $(seq 1 20); do
  in_app && break
  sleep 0.5
done
sleep 3
shot 01-home
in_app && ok "app focused on launch" || bad "app not focused"

# Hero Details is focused on TV home — open it.
log "==> open Details"
key 23 || true
sleep 2
shot 02-details
in_app || { bad "left app opening details"; exit 1; }

# Detail screen: Play is usually primary autofocus — Select once.
log "==> Play"
key 23 || true
sleep 2
shot 03-picker-or-player
in_app || { bad "left app on Play"; exit 1; }

# If stream list is showing, Select the first result / start.
log "==> confirm stream pick"
key 23 || true
sleep 2
shot 04-after-pick
in_app || { bad "left app after pick"; exit 1; }

log "==> wait for HUD / video (90s), watch for ANR"
PROGRESS=0
ANR=0
for i in $(seq 1 45); do
  sleep 2
  if ! in_app; then
    bad "app lost focus at t=$((i*2))s"
    shot "fail-focus-$i"
    break
  fi
  if "${ADB[@]}" logcat -d | grep -q 'Input dispatching timed out'; then
    ANR=1
    shot "fail-anr-$i"
    break
  fi
  if "${ADB[@]}" logcat -d | grep -qE 'PeanutButter streamStatus.*(mbps=[1-9]|peers=[1-9]|status=ready)'; then
    PROGRESS=1
    shot "05-progress-$i"
    log "  streamStatus progressed at t=$((i*2))s"
    break
  fi
  if [[ $((i % 5)) -eq 0 ]]; then
    shot "tick-$i"
    log "  t=$((i*2))s waiting…"
  fi
done
shot 06-final

if [[ "$ANR" -eq 1 ]]; then
  bad "ANR while streaming"
else
  ok "no ANR"
fi

if [[ "$PROGRESS" -eq 1 ]]; then
  ok "HUD progressed past empty swarm"
elif in_app && [[ "$ANR" -eq 0 ]]; then
  # Fallback: large late screenshots usually mean decoded video frames.
  LATE=$(ls -1 "$OUT_DIR"/tick-*.png 2>/dev/null | tail -1 || true)
  if [[ -n "$LATE" ]]; then
    SZ=$(wc -c <"$LATE" | tr -d ' ')
    if [[ "$SZ" -gt 200000 ]]; then
      ok "playback frames present (${SZ}b screenshot, no ANR)"
    else
      bad "could not confirm stream progress"
    fi
  else
    bad "could not confirm stream progress"
  fi
else
  bad "could not confirm stream state"
fi

log ""
log "Artifacts: $OUT_DIR"
log "Results: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
