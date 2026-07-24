#!/usr/bin/env bash
# Build (or refresh) the OSRM planet graph — MLD pipeline, car profile.
# Run this BEFORE `docker compose up -d osrm`, and again periodically (weekly cron) to refresh.
# OSRM has no live diff-updater, so refreshing = re-download planet + re-run this + restart osrm.
set -euo pipefail

: "${DATA_DIR:=/data}"
IMG="ghcr.io/project-osrm/osrm-backend:latest"
OSRM_DIR="$DATA_DIR/osrm"
PLANET_SRC="$DATA_DIR/planet-src/planet.osm.pbf"   # downloaded ONCE on the host, shared

mkdir -p "$OSRM_DIR"
cd "$OSRM_DIR"

# The planet .pbf is downloaded ON THE HOST (never in a container):
#   scripts/host-download.sh https://planet.openstreetmap.org/pbf/planet-latest.osm.pbf "$PLANET_SRC"
# Here we just hardlink it into the OSRM dir (same filesystem → zero copy, zero download) so
# osrm-extract can write the .osrm outputs alongside it.
if [ ! -f "$PLANET_SRC" ]; then
  echo "[osrm] ERROR: $PLANET_SRC not found. Download it on the host first:"
  echo "  bash scripts/host-download.sh https://planet.openstreetmap.org/pbf/planet-latest.osm.pbf $PLANET_SRC"
  exit 1
fi
if [ ! -f planet.osm.pbf ]; then
  ln "$PLANET_SRC" planet.osm.pbf 2>/dev/null || cp "$PLANET_SRC" planet.osm.pbf
  echo "[osrm] linked host planet.osm.pbf into $OSRM_DIR (no download)"
fi

echo "[osrm] extract (car profile) — heavy, uses lots of RAM/NVMe temp…"
docker run --rm -t -v "$OSRM_DIR:/data" "$IMG" osrm-extract -p /opt/car.lua /data/planet.osm.pbf

echo "[osrm] partition…"
docker run --rm -t -v "$OSRM_DIR:/data" "$IMG" osrm-partition /data/planet.osrm

echo "[osrm] customize…"
docker run --rm -t -v "$OSRM_DIR:/data" "$IMG" osrm-customize /data/planet.osrm

echo "[osrm] done. Start/restart the service:  docker compose up -d osrm"
