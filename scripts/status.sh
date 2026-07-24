#!/usr/bin/env bash
# Best-effort import status for the three services. Ground truth = the gateway HTTP code (200 =
# serving/done); phase + % + ETA for in-progress work are approximate (imports aren't linear).
set -uo pipefail
cd /root/mikeos-osm 2>/dev/null || true
TOKEN=$(grep '^OSM_TOKEN=' .env 2>/dev/null | cut -d= -f2-)
G="https://osm.osmike.com"
now=$(date -u +%s)

elapsed() {  # container -> "Xh YYm"
  local s st d
  s=$(docker inspect "$1" --format '{{.State.StartedAt}}' 2>/dev/null) || { echo "-"; return; }
  st=$(date -u -d "$s" +%s 2>/dev/null) || { echo "-"; return; }
  d=$(( now - st )); printf '%dh %02dm' $((d/3600)) $(((d%3600)/60))
}
code() { curl -s -o /dev/null -w '%{http_code}' -m 8 -H "Authorization: Bearer $TOKEN" "$1" 2>/dev/null; }
dlpct() {  # parse the curl total-% from a container's log (carriage-return progress)
  docker logs --tail 4000 "$1" 2>&1 | tr '\r' '\n' | grep -oE '^ *[0-9]+ +[0-9.]+[GMk]' | tail -1 | awk '{print $1"%"}'
}
sz() { du -sh "$1" 2>/dev/null | awk '{print $1}'; }

echo "| service | phase | progress | elapsed | ~eta |"
echo "|---|---|---|---|---|"

# --- Nominatim ---
el=$(elapsed mikeos-nominatim)
if [ "$(code "$G/nominatim/search?q=paris&format=json&limit=1")" = "200" ]; then
  echo "| Nominatim | ✅ serving | 100% | $el | done |"
else
  pbf=$(docker exec mikeos-nominatim sh -c 'stat -c %s /nominatim/data.osm.pbf 2>/dev/null' 2>/dev/null)
  if [ -n "${pbf:-}" ] && [ "$pbf" -lt 82000000000 ] 2>/dev/null; then
    echo "| Nominatim | 1/3 downloading planet | $((pbf*100/82000000000))% of ~80GB | $el | +import ~12-20h |"
  else
    echo "| Nominatim | 2/3 import + index (db $(sz /data/nominatim)) | in progress | $el | ~6-16h |"
  fi
fi

# --- Overpass ---
el=$(elapsed mikeos-overpass)
if [ "$(code "$G/overpass/api/interpreter?data=%5Bout%3Ajson%5D%3Bout+1%3B")" = "200" ]; then
  echo "| Overpass | ✅ serving | 100% | $el | done |"
else
  dp=$(dlpct mikeos-overpass)
  if [ -n "${dp:-}" ]; then
    echo "| Overpass | 1/2 downloading planet | $dp of 87.5GB (db $(sz /data/overpass)) | $el | +init ~2-5h |"
  else
    echo "| Overpass | 2/2 building db ($(sz /data/overpass)) | in progress | $el | ~1-4h |"
  fi
fi

# --- OSRM ---
if docker ps --format '{{.Names}}' | grep -q '^mikeos-osrm$'; then
  el=$(elapsed mikeos-osrm)
  if [ "$(code "$G/route/route/v1/driving/2.29,48.85;2.35,48.86?overview=false")" = "200" ]; then
    echo "| OSRM | ✅ serving | 100% | $el | done |"
  else
    echo "| OSRM | building graph (extract→partition→customize) | see /data/osrm-build.log | $el | ~2-6h |"
  fi
elif ls /data/osrm/*.osrm >/dev/null 2>&1; then
  echo "| OSRM | graph built, service not started | ready | - | start it |"
else
  echo "| OSRM | ⏸ queued (starts after Nominatim import) | 0% | - | after Nominatim |"
fi

echo ""
echo "disk: $(df -h / | awk 'NR==2{print $3" / "$2" ("$5")"}')  ·  $(date -u '+%Y-%m-%d %H:%M UTC')"
