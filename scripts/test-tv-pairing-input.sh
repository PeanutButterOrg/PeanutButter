#!/usr/bin/env bash
# Automated Android TV emulator test: D-pad navigation + pairing input.
# Usage:
#   scripts/test-tv-pairing-input.sh [SERIAL] [SERVER_URL] [PAIRING_CODE]
# Defaults: emulator-5554  http://10.0.0.110:3001/  204295
# Note: PeanutButter serves /health on :3001 (not :80). Port 80 on the NAS
# is a different site and will fail probeHealth → "Cannot reach …".
set -euo pipefail

SERIAL="${1:-emulator-5554}"
SERVER_URL="${2:-http://10.0.0.110:3001/}"
PAIRING_CODE="${3:-204295}"
PAIRING_CODE="${PAIRING_CODE// /}"
PKG=app.peanutbutter.peanutbutter
OUT_DIR="${TMPDIR:-/tmp}/pb-tv-input-test"
mkdir -p "$OUT_DIR"
rm -f "$OUT_DIR"/*.png "$OUT_DIR"/*.txt 2>/dev/null || true

ADB=(adb -s "$SERIAL")
pass=0
fail=0

log() { printf '%s\n' "$*"; }
ok() { log "PASS: $*"; pass=$((pass + 1)); }
bad() { log "FAIL: $*"; fail=$((fail + 1)); }

shot() {
  local name="$1"
  "${ADB[@]}" exec-out screencap -p >"$OUT_DIR/$name.png"
}

focus_pkg() {
  "${ADB[@]}" shell dumpsys window 2>/dev/null | grep mCurrentFocus | head -1 || true
}

wait_focus() {
  local i
  for i in $(seq 1 25); do
    if focus_pkg | grep -q "$PKG"; then return 0; fi
    sleep 0.4
  done
  return 1
}

key() {
  "${ADB[@]}" shell input keyevent "$1"
  sleep 0.4
}

# Type ASCII via adb input text. Spaces -> %s. Shell-escape the rest.
type_text() {
  local raw="$1"
  local encoded
  encoded=$(python3 -c 'import sys; s=sys.argv[1]; print(s.replace(" ", "%s").replace("\\", "\\\\").replace("\"", "\\\"").replace("'\''", "'\''\\'\'''\''").replace("(", "\\(").replace(")", "\\)").replace("&", "\\&").replace("<", "\\<").replace(">", "\\>").replace(";", "\\;").replace("|", "\\|"))' "$raw")
  "${ADB[@]}" shell input text "$encoded"
  sleep 0.5
}

# Clear the focused TextField (saved URL may already be present).
clear_field() {
  # Jump to end, then backspace a generous amount.
  "${ADB[@]}" shell input keyevent KEYCODE_MOVE_END >/dev/null 2>&1 || true
  local i
  for i in $(seq 1 96); do
    "${ADB[@]}" shell input keyevent KEYCODE_DEL >/dev/null 2>&1 || true
  done
  sleep 0.2
}

type_digits() {
  local digits="$1" d
  for ((i = 0; i < ${#digits}; i++)); do
    d="${digits:i:1}"
    case "$d" in
      0) key KEYCODE_0 ;;
      1) key KEYCODE_1 ;;
      2) key KEYCODE_2 ;;
      3) key KEYCODE_3 ;;
      4) key KEYCODE_4 ;;
      5) key KEYCODE_5 ;;
      6) key KEYCODE_6 ;;
      7) key KEYCODE_7 ;;
      8) key KEYCODE_8 ;;
      9) key KEYCODE_9 ;;
      *) type_text "$d" ;;
    esac
  done
}

launch_app() {
  # Clear prefs so a stale URL without :3001 isn't prepended by input text.
  "${ADB[@]}" shell pm clear "$PKG" >/dev/null 2>&1 || true
  sleep 0.3
  "${ADB[@]}" logcat -c
  "${ADB[@]}" shell am start -n "$PKG/.MainActivity" >/dev/null
  sleep 7
  wait_focus
}

log "=== TV pairing input test ==="
log "device=$SERIAL url=$SERVER_URL code=$PAIRING_CODE"
"${ADB[@]}" shell input keyevent KEYCODE_HOME >/dev/null 2>&1 || true
sleep 0.5

if launch_app; then ok "app focused"; else bad "app not focused: $(focus_pkg)"; fi
shot 00-launch
sleep 1
shot 01-initial

# --- D-pad navigation sweep ---
log "--- D-pad navigation ---"
key KEYCODE_DPAD_DOWN
shot 10-after-down-1
key KEYCODE_DPAD_DOWN
shot 11-after-down-2
key KEYCODE_DPAD_DOWN
shot 12-after-down-3
key KEYCODE_DPAD_UP
shot 13-after-up-1
key KEYCODE_DPAD_UP
shot 14-after-up-2
key KEYCODE_DPAD_UP
shot 15-after-up-3

soft_nav=$("${ADB[@]}" logcat -d 2>/dev/null | grep -c SHOW_SOFT_INPUT || true)
if [[ "${soft_nav:-0}" -eq 0 ]]; then
  ok "no soft keyboard during D-pad nav"
else
  bad "soft keyboard opened during nav ($soft_nav)"
fi

# Land on URL field
for _ in 1 2 3 4 5; do key KEYCODE_DPAD_UP; done
shot 20-url-ready

# --- Enter server URL ---
log "--- input server URL: $SERVER_URL ---"
key KEYCODE_DPAD_CENTER
sleep 0.7
clear_field
type_text "$SERVER_URL"
shot 30-url-typed

# Leave edit / move to pairing code
key KEYCODE_DPAD_DOWN
sleep 0.5
shot 31-on-token

# --- Enter pairing code ---
log "--- input pairing code: $PAIRING_CODE ---"
key KEYCODE_DPAD_CENTER
sleep 0.7
clear_field
# Prefer digit keyevents (reliable on TV); fallback to input text
if [[ "$PAIRING_CODE" =~ ^[0-9]+$ ]]; then
  type_digits "$PAIRING_CODE"
else
  type_text "$PAIRING_CODE"
fi
shot 40-code-typed

key KEYCODE_DPAD_DOWN
sleep 0.5
shot 41-on-connect

# --- Connect ---
log "--- Connect ---"
"${ADB[@]}" logcat -c
key KEYCODE_DPAD_CENTER
sleep 10
shot 50-after-connect

if focus_pkg | grep -q "$PKG"; then
  ok "still in app after Connect"
else
  bad "left app after Connect: $(focus_pkg)"
fi

LOGS=$("${ADB[@]}" logcat -d 2>/dev/null | grep -iE 'PeanutButter|pair|GraphQL|Unauthorized|connected|Exception|ErrorWidget|Origin|FATAL' | tail -50 || true)
printf '%s\n' "$LOGS" >"$OUT_DIR/logcat-snippet.txt"
log "--- log snippet ---"
printf '%s\n' "$LOGS"

soft_total=$("${ADB[@]}" logcat -d 2>/dev/null | grep -c SHOW_SOFT_INPUT || true)
if [[ "${soft_total:-0}" -eq 0 ]]; then
  ok "no soft keyboard for whole run"
else
  log "NOTE: SHOW_SOFT_INPUT count=${soft_total}"
fi

# Verify fields changed visually (no OCR required)
diff_out=$(python3 - "$OUT_DIR" <<'PY'
import math, sys
from pathlib import Path
from PIL import Image, ImageChops

out = Path(sys.argv[1])

def rms(a, b):
    d = ImageChops.difference(Image.open(a).convert("RGB"), Image.open(b).convert("RGB"))
    h = d.histogram()
    sq = sum(v * (i % 256) ** 2 for i, v in enumerate(h))
    return math.sqrt(sq / (d.size[0] * d.size[1]))

checks = [
    ("01-initial.png", "30-url-typed.png", "URL field changed after input", 2.0),
    ("30-url-typed.png", "40-code-typed.png", "pairing code field changed after input", 2.0),
    ("40-code-typed.png", "50-after-connect.png", "UI changed after Connect", 1.0),
]
failed = 0
for a, b, label, thr in checks:
    r = rms(out / a, out / b)
    status = "PASS" if r >= thr else "FAIL"
    print(f"{status}: {label} (rms={r:.1f})")
    if status == "FAIL":
        failed += 1
raise SystemExit(failed)
PY
) || true
while IFS= read -r line; do
  log "$line"
  case "$line" in
    PASS:*) pass=$((pass + 1)) ;;
    FAIL:*) fail=$((fail + 1)) ;;
  esac
done <<<"$diff_out"
# OCR check if available
if command -v tesseract >/dev/null 2>&1; then
  url_ocr=$(tesseract "$OUT_DIR/30-url-typed.png" stdout 2>/dev/null | tr '\n' ' ' || true)
  code_ocr=$(tesseract "$OUT_DIR/40-code-typed.png" stdout 2>/dev/null | tr '\n' ' ' || true)
  after_ocr=$(tesseract "$OUT_DIR/50-after-connect.png" stdout 2>/dev/null | tr '\n' ' ' || true)
  log "OCR url field shot: $url_ocr"
  log "OCR code field shot: $code_ocr"
  log "OCR after connect: $after_ocr"
  if echo "$url_ocr" | grep -Eqi '10\.0\.0\.110|:3001|http'; then
    ok "OCR saw server URL"
  else
    bad "OCR did not see server URL in 30-url-typed.png"
  fi
  if echo "$code_ocr" | grep -Eq '204.?295|204295'; then
    ok "OCR saw pairing code"
  else
    bad "OCR did not see pairing code in 40-code-typed.png"
  fi
  if echo "$after_ocr" | grep -Eqi 'Cannot reach|pairing code|accepted|Movies|Series|home|catalog'; then
    ok "OCR saw post-Connect UI change"
  fi
fi

# Stronger success signal from logcat / final screenshot state:
# After a good Connect we should leave pairing OR show a pairing-code error
# (reachable server) — not "Cannot reach" for a wrong port.
if [[ -f "$OUT_DIR/50-after-connect.png" ]]; then
  # Host-side proof the URL under test is healthy (helps diagnose emulator fails).
  base="${SERVER_URL%/}"
  if curl -fsS --max-time 3 "$base/health" >/dev/null 2>&1; then
    ok "host can reach $base/health"
  else
    bad "host cannot reach $base/health (wrong URL/port or server down)"
  fi
fi


log "=== screenshots: $OUT_DIR ==="
ls -la "$OUT_DIR"/*.png 2>/dev/null | awk '{print $5, $NF}'

log "=== RESULT: $pass passed, $fail failed ==="
[[ "$fail" -eq 0 ]]
