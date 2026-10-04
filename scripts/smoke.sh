#!/usr/bin/env bash
# Prove the demo (or production gateway) answers geocode, Overpass, and route.
# Exit 0 only when all three return HTTP 200 with a non-empty body.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [ -f .env.demo ] && [ -z "${OSM_TOKEN:-}" ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env.demo
  set +a
elif [ -f .env ] && [ -z "${OSM_TOKEN:-}" ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

: "${OSM_TOKEN:?OSM_TOKEN required}"
BASE="${SMOKE_BASE:-http://127.0.0.1:8080}"
H="Authorization: Bearer $OSM_TOKEN"
fail=0

check() {
  local name="$1" url="$2" extra=("${@:3}")
  local tmp code body
  tmp=$(mktemp)
  code=$(curl -sS -o "$tmp" -w '%{http_code}' -m 30 -H "$H" "${extra[@]}" "$url" || echo "000")
  body=$(head -c 240 "$tmp" | tr '\n' ' ')
  rm -f "$tmp"
  if [ "$code" = "200" ] && [ -n "$body" ]; then
    echo "OK  $name  ($code)  ${body:0:120}"
  else
    echo "FAIL $name  ($code)  ${body:0:120}" >&2
    fail=1
  fi
}

echo "smoke against $BASE"
check "gateway" "$BASE/"
check "nominatim" "$BASE/nominatim/search?q=Casino+de+Monaco&format=json&limit=1"
check "overpass" "$BASE/overpass/api/interpreter" \
  --data 'data=[out:json][timeout:25];node["amenity"="cafe"](43.72,7.40,43.75,7.45);out 3;'
check "osrm" "$BASE/route/route/v1/driving/7.4246,43.7384;7.4275,43.7400?overview=false"

if [ "$fail" -ne 0 ]; then
  echo "smoke FAILED" >&2
  exit 1
fi
echo "smoke PASSED"
