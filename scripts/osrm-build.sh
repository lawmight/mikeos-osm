#!/usr/bin/env bash
# Build (or refresh) the OSRM planet graph — MLD pipeline, car profile.
# Run this BEFORE `docker compose up -d osrm`, and again periodically (weekly cron) to refresh.
# OSRM has no live diff-updater, so refreshing = re-download planet + re-run this + restart osrm.
set -euo pipefail

: "${DATA_DIR:=/data}"
: "${PLANET_URL:=https://planet.openstreetmap.org/pbf/planet-latest.osm.pbf}"
IMG="ghcr.io/project-osrm/osrm-backend:latest"
OSRM_DIR="$DATA_DIR/osrm"

mkdir -p "$OSRM_DIR"
cd "$OSRM_DIR"

if [ ! -f planet.osm.pbf ]; then
  echo "[osrm] downloading planet.osm.pbf (~80 GB, resumable)…"
  curl -fL -C - "$PLANET_URL" -o planet.osm.pbf.partial
  mv planet.osm.pbf.partial planet.osm.pbf
fi

echo "[osrm] extract (car profile) — heavy, uses lots of RAM/NVMe temp…"
docker run --rm -t -v "$OSRM_DIR:/data" "$IMG" osrm-extract -p /opt/car.lua /data/planet.osm.pbf

echo "[osrm] partition…"
docker run --rm -t -v "$OSRM_DIR:/data" "$IMG" osrm-partition /data/planet.osrm

echo "[osrm] customize…"
docker run --rm -t -v "$OSRM_DIR:/data" "$IMG" osrm-customize /data/planet.osrm

echo "[osrm] done. Start/restart the service:  docker compose up -d osrm"
