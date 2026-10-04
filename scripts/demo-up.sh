#!/usr/bin/env bash
# Bring up mikeos-osm against a small Geofabrik extract (default: Monaco).
# Host downloads only. Order: download → Nominatim → Overpass → OSRM build → Caddy.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

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
: "${EXTRACT_PBF_URL:?EXTRACT_PBF_URL required}"
: "${OSM_TOKEN:?OSM_TOKEN required}"

COMPOSE=(docker compose -f docker-compose.yml -f docker-compose.demo.yml)
PBF="$DATA_DIR/planet-src/extract.osm.pbf"
BZ2="$DATA_DIR/planet-src/extract.osm.bz2"
OSRM_DIR="$DATA_DIR/osrm"
IMG="ghcr.io/project-osrm/osrm-backend:latest"
OSMIUM_IMG="ghcr.io/osmcode/osmium-tool:latest"

mkdir -p "$DATA_DIR/planet-src" "$DATA_DIR/overpass" "$DATA_DIR/nominatim" "$DATA_DIR/osrm" \
  "$DATA_DIR/caddy/data" "$DATA_DIR/caddy/config"

if [ ! -f "$PBF" ]; then
  bash scripts/host-download.sh "$EXTRACT_PBF_URL" "$PBF"
else
  echo "[demo] reuse $PBF"
fi
# Geofabrik no longer ships .osm.bz2 for tiny extracts. Convert on the host for Overpass.
if [ ! -f "$BZ2" ]; then
  echo "[demo] convert pbf → osm.bz2 for Overpass…"
  if command -v osmium >/dev/null 2>&1; then
    osmium cat -o "$BZ2" "$PBF"
  else
    docker run --rm -v "$DATA_DIR/planet-src:/data" "$OSMIUM_IMG" \
      osmium cat -o /data/extract.osm.bz2 /data/extract.osm.pbf
  fi
else
  echo "[demo] reuse $BZ2"
fi

echo "[demo] 1/4 Nominatim import…"
"${COMPOSE[@]}" up -d nominatim
echo "[demo] waiting for Nominatim search…"
for i in $(seq 1 180); do
  if curl -sf -m 5 "http://127.0.0.1:18080/search?q=monaco&format=json&limit=1" >/dev/null 2>&1 \
    || docker exec mikeos-nominatim curl -sf -m 5 \
      "http://127.0.0.1:8080/search?q=monaco&format=json&limit=1" >/dev/null 2>&1; then
    echo "[demo] Nominatim serving search"
    break
  fi
  if [ "$i" -eq 180 ]; then
    echo "[demo] Nominatim still importing — check: docker logs -f mikeos-nominatim" >&2
    exit 1
  fi
  sleep 10
done

echo "[demo] 2/4 Overpass init…"
"${COMPOSE[@]}" up -d overpass
for i in $(seq 1 120); do
  if docker exec mikeos-overpass test -f /db/init_done 2>/dev/null; then
    echo "[demo] Overpass init_done"
    break
  fi
  if [ "$i" -eq 120 ]; then
    echo "[demo] Overpass init timed out — docker logs mikeos-overpass" >&2
    exit 1
  fi
  sleep 10
done

echo "[demo] 3/4 OSRM graph (extract→partition→customize)…"
mkdir -p "$OSRM_DIR"
cd "$OSRM_DIR"
if [ ! -f extract.osm.pbf ]; then
  ln "$PBF" extract.osm.pbf 2>/dev/null || cp "$PBF" extract.osm.pbf
fi
if [ ! -f extract.osrm ]; then
  docker run --rm -t -v "$OSRM_DIR:/data" "$IMG" osrm-extract -p /opt/car.lua /data/extract.osm.pbf
  docker run --rm -t -v "$OSRM_DIR:/data" "$IMG" osrm-partition /data/extract.osrm
  docker run --rm -t -v "$OSRM_DIR:/data" "$IMG" osrm-customize /data/extract.osrm
else
  echo "[demo] reuse existing extract.osrm"
fi
cd "$ROOT"
"${COMPOSE[@]}" up -d osrm

echo "[demo] 4/4 Caddy gateway on :8080…"
"${COMPOSE[@]}" up -d caddy

echo "[demo] smoke…"
bash scripts/smoke.sh
echo "[demo] open http://127.0.0.1:8080/showcase/"
