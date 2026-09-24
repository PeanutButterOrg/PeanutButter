#!/usr/bin/env bash
# Auto-test: Jackett search → startStream → streamStatus ready → HTTP Range bytes → stop.
# Usage:
#   scripts/test-stream-pipeline.sh [SERVER_URL] [API_TOKEN] [QUERY]
# Defaults: http://10.0.0.110:3001  204295  Inception
set -euo pipefail

SERVER="${1:-http://10.0.0.110:3001}"
TOKEN="${2:-204295}"
QUERY="${3:-Inception}"
SERVER="${SERVER%/}"
OUT_DIR="${TMPDIR:-/tmp}/pb-stream-pipeline"
mkdir -p "$OUT_DIR"

pass=0
fail=0
log() { printf '%s\n' "$*"; }
ok() { log "PASS: $*"; pass=$((pass + 1)); }
bad() { log "FAIL: $*"; fail=$((fail + 1)); }

gql() {
  curl -sS -m 60 -X POST "$SERVER/graphql" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $TOKEN" \
    -H "X-Api-Key: $TOKEN" \
    -d @"$1"
}

log "==> health"
HEALTH=$(curl -sS -m 8 "$SERVER/health" || true)
echo "$HEALTH" | grep -q '"status":"ok"' && ok "health ok" || bad "health: $HEALTH"

log "==> streamingSearch($QUERY)"
python3 - <<PY >"$OUT_DIR/search.json"
import json
print(json.dumps({
  "query": "query(\$q:String!){ streamingSearch(query:\$q, kind: MOVIE){ title magnet seeders peers }}",
  "variables": {"q": """$QUERY"""},
}))
PY
SEARCH=$(gql "$OUT_DIR/search.json")
printf '%s' "$SEARCH" >"$OUT_DIR/search-result.json"
python3 - <<'PY' "$OUT_DIR/search-result.json" "$OUT_DIR/pick.json"
import json,sys
d=json.load(open(sys.argv[1]))
items=(d.get("data") or {}).get("streamingSearch") or []
items=sorted(items, key=lambda x: int(x.get("seeders") or 0), reverse=True)
if not items:
  json.dump({"magnet":"","seeders":0,"peers":0}, open(sys.argv[2],"w"))
else:
  m=items[0]
  json.dump({
    "magnet": m.get("magnet") or "",
    "seeders": int(m.get("seeders") or 0),
    "peers": int(m.get("peers") or 0),
    "title": m.get("title") or "",
  }, open(sys.argv[2],"w"))
PY
MAGNET=$(python3 -c 'import json; print(json.load(open("'"$OUT_DIR"'/pick.json"))["magnet"])')
SEEDERS=$(python3 -c 'import json; print(json.load(open("'"$OUT_DIR"'/pick.json"))["seeders"])')
PEERS=$(python3 -c 'import json; print(json.load(open("'"$OUT_DIR"'/pick.json"))["peers"])')

if [[ -z "$MAGNET" ]]; then
  bad "no magnet from streamingSearch"
  log "raw: $SEARCH"
  log "Results: $pass passed, $fail failed"
  exit 1
fi
ok "got magnet (seeders=$SEEDERS peers=$PEERS)"

python3 - <<PY >"$OUT_DIR/start.json"
import json
pick=json.load(open("$OUT_DIR/pick.json"))
print(json.dumps({
  "query": """mutation(\$magnet:String!,\$title:String!,\$seeders:Int,\$peers:Int){
    startStream(magnet:\$magnet,title:\$title,seeders:\$seeders,peers:\$peers){
      id status streamUrl progress seeders peers
    }
  }""",
  "variables": {
    "magnet": pick["magnet"],
    "title": """$QUERY""",
    "seeders": pick["seeders"],
    "peers": pick["peers"],
  },
}))
PY

log "==> startStream"
START=$(gql "$OUT_DIR/start.json")
printf '%s' "$START" >"$OUT_DIR/start-result.json"
SID=$(python3 -c 'import json; d=json.load(open("'"$OUT_DIR"'/start-result.json")); print(((d.get("data") or {}).get("startStream") or {}).get("id") or "")')
if [[ -z "$SID" ]]; then
  bad "startStream failed: $START"
  log "Results: $pass passed, $fail failed"
  exit 1
fi
ok "session $SID"

READY=0
STREAM_URL=""
STATUS=""
for i in $(seq 1 50); do
  python3 - <<PY >"$OUT_DIR/status.json"
import json
print(json.dumps({"query":"{ streamStatus(sessionId: \"$SID\") { id status streamUrl progress seeders peers downloadMbps bufferProgress } }"}))
PY
  ST=$(gql "$OUT_DIR/status.json")
  printf '%s' "$ST" >"$OUT_DIR/status-result.json"
  eval "$(python3 - <<'PY' "$OUT_DIR/status-result.json"
import json,sys
d=json.load(open(sys.argv[1]))
s=(d.get("data") or {}).get("streamStatus") or {}
def q(v):
  return "'" + str(v).replace("'", "'\\''") + "'"
print("STATUS="+q(s.get("status") or ""))
print("STREAM_URL="+q(s.get("streamUrl") or ""))
print("LIVE_PEERS="+str(int(s.get("peers") or 0)))
print("MBPS="+str(float(s.get("downloadMbps") or 0)))
print("PCT="+str(float(s.get("bufferProgress") or 0)*100))
PY
)"
  log "  t=$((i*2))s status=$STATUS peers=$LIVE_PEERS mbps=$MBPS pct=${PCT}%"
  if [[ "$STATUS" == "ready" && -n "$STREAM_URL" ]]; then
    READY=1
    break
  fi
  if [[ "$STATUS" == error* ]]; then
    bad "stream error: $STATUS"
    break
  fi
  sleep 2
done

if [[ "$READY" -eq 1 ]]; then
  ok "stream ready ($STREAM_URL)"
else
  bad "stream never became ready (last=$STATUS)"
fi

if [[ -n "$STREAM_URL" ]]; then
  log "==> HTTP Range fetch"
  CODE=$(curl -sS -m 30 -o "$OUT_DIR/head.bin" -w "%{http_code}" -r 0-262143 \
    -H "Authorization: Bearer $TOKEN" \
    -H "X-Api-Key: $TOKEN" \
    "$STREAM_URL" || echo "000")
  SIZE=$(wc -c <"$OUT_DIR/head.bin" | tr -d ' ')
  if { [[ "$CODE" == "206" ]] || [[ "$CODE" == "200" ]]; } && [[ "$SIZE" -gt 10000 ]]; then
    ok "fetched ${SIZE} bytes (HTTP $CODE)"
    FILE_INFO=$(file "$OUT_DIR/head.bin")
    echo "$FILE_INFO" | tee "$OUT_DIR/file.txt"
    echo "$FILE_INFO" | grep -qiE 'mp4|matroska|mpeg|media|iso|data' \
      && ok "payload looks like media" || bad "unexpected payload: $FILE_INFO"
  else
    bad "Range fetch failed (HTTP $CODE size=$SIZE)"
  fi
fi

log "==> stopStream"
python3 - <<PY >"$OUT_DIR/stop.json"
import json
print(json.dumps({"query":"mutation { stopStream(sessionId: \"$SID\") }"}))
PY
STOP=$(gql "$OUT_DIR/stop.json")
echo "$STOP" | grep -q 'true' && ok "stopped" || bad "stop failed: $STOP"

log ""
log "Results: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
