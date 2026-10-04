#!/usr/bin/env bash
# Prove the gateway answers geocode, Overpass, and route with real Monaco values.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -z "${OSM_TOKEN:-}" ]; then
  set -a
  # shellcheck disable=SC1090
  . "./${ENV_FILE:-.env.demo}"
  set +a
fi
: "${OSM_TOKEN:?OSM_TOKEN required}"
BASE="${SMOKE_BASE:-http://127.0.0.1:8080}"
fail=0

api() { curl -sS -m 30 -H "Authorization: Bearer $OSM_TOKEN" -H 'Accept: application/json' "$@"; }
expect() {
  local name=$1 filter=$2
  shift 2
  if api "$@" | jq -e "$filter" >/dev/null 2>&1; then
    echo "ok $name"
  else
    echo "FAIL $name" >&2
    fail=1
  fi
}

code="$(curl -s -m 10 -o /dev/null -w '%{http_code}' "$BASE/route/" || true)"
if [ "$code" = 401 ]; then
  echo "ok gate"
else
  echo "FAIL gate, got $code, want 401" >&2
  fail=1
fi

expect nominatim '.[0].display_name | startswith("Casino de Monte Carlo")' \
  "$BASE/nominatim/search?q=Casino+de+Monte+Carlo&countrycodes=mc&format=json&limit=1"
expect overpass '.elements[0].tags.amenity == "casino"' "$BASE/overpass/api/interpreter" \
  --data-urlencode 'data=[out:json];nwr["name"="Casino de Monte Carlo"](43.72,7.40,43.76,7.44);out tags 1;'
expect osrm '.code == "Ok" and .routes[0].distance > 500 and .routes[0].distance < 800' \
  "$BASE/route/route/v1/driving/7.4246,43.7384;7.4275,43.7400?overview=false"

exit "$fail"
