#!/usr/bin/env bash
# Rerunnable regional bring-up. Each step skips when its output already exists.
set -euo pipefail
cd "$(dirname "$0")/.."
ENV_FILE="${ENV_FILE:-.env.demo}"
if [ ! -f "$ENV_FILE" ]; then
  echo "[demo] missing $ENV_FILE" >&2
  exit 1
fi
set -a
# shellcheck disable=SC1090
. "./$ENV_FILE"
set +a

: "${DATA_DIR:?DATA_DIR required}"
: "${PLANET_URL:?PLANET_URL required}"
: "${OSM_TOKEN:?OSM_TOKEN required}"

mkdir -p "$DATA_DIR/planet-src"
DATA_DIR="$(cd "$DATA_DIR" && pwd)"
SRC="$DATA_DIR/planet-src"
dc() { docker compose --env-file "$ENV_FILE" "$@"; }

for tool in aria2c osmium jq curl; do
  command -v "$tool" >/dev/null || { echo "missing host tool: $tool" >&2; exit 1; }
done

if [ ! -f "$SRC/planet.osm.pbf" ] || [ -f "$SRC/planet.osm.pbf.aria2" ]; then
  curl -fsIL "$PLANET_URL" >/dev/null || { echo "unreachable: $PLANET_URL" >&2; exit 1; }
  bash scripts/host-download.sh "$PLANET_URL" "$SRC/planet.osm.pbf" \
    || { rm -f "$SRC/planet.osm.pbf" "$SRC/planet.osm.pbf.aria2"; exit 1; }
fi
if [ ! -f "$SRC/planet.osm.bz2" ]; then
  echo "[demo] convert pbf to osm.bz2 for Overpass"
  osmium cat -O -f osm.bz2 -o "$SRC/planet.osm.bz2.part" "$SRC/planet.osm.pbf"
  mv "$SRC/planet.osm.bz2.part" "$SRC/planet.osm.bz2"
fi

dc up -d nominatim overpass
if [ ! -s "$DATA_DIR/osrm/planet.osrm.mldgr" ]; then
  bash scripts/osrm-build.sh
fi
dc up -d osrm caddy

echo "[demo] waiting for imports"
deadline=$((SECONDS + 600))
until bash scripts/smoke.sh >/dev/null 2>&1; do
  if [ "$SECONDS" -ge "$deadline" ]; then
    bash scripts/smoke.sh || true
    echo "[demo] not ready after 600s. If osrm is up but smoke fails, Caddy cannot reach it (compose network)." >&2
    exit 1
  fi
  sleep 10
done
bash scripts/smoke.sh
echo "[demo] open http://127.0.0.1:8080/showcase/#token=$OSM_TOKEN"
