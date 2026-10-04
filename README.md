# mikeos-osm

**MikeOS's self-hosted, planet-scale OpenStreetMap stack.** One box serves the whole world's geo
data — **search, geocoding, and routing** — with **no rate limits, no usage policy, full speed**.
It's the geo substrate under the whole fleet (MikeMaps search/routing today; the geo-AI layer next).

| Service | Image | What it gives us | Public path |
|---|---|---|---|
| **Overpass** | `wiktorn/overpass-api` | named-POI + tag/spatial search | `/overpass/api/interpreter` |
| **Nominatim** | `mediagis/nominatim` | geocoding + reverse-geocoding | `/nominatim/search`, `/nominatim/reverse` |
| **OSRM** (MLD, car) | `project-osrm/osrm-backend` | routing (route/table/match) | `/route/route/v1/driving/...` |
| **Caddy** | `caddy:2` | TLS + Bearer-token gate | — |

All three are behind Caddy on one HTTPS host; the app calls them with
`Authorization: Bearer <OSM_TOKEN>`.

## Demo (small extract)

Planet import needs ~128 GB RAM and terabytes of disk. To try the stack on a laptop or cloud agent,
use a Geofabrik extract (this repo ships Monaco as the default):

```bash
cp .env.demo .env.demo.local   # optional local overrides
set -a; . ./.env.demo; set +a
bash scripts/demo-up.sh        # download → convert → import → OSRM → Caddy :8080
bash scripts/smoke.sh          # Nominatim + Overpass + OSRM through the Bearer gate
open http://127.0.0.1:8080/showcase/
```

`docker-compose.demo.yml` + `Caddyfile.demo` serve HTTP on `:8080`, skip basemap, point every
service at host-downloaded `extract.osm.pbf` / `extract.osm.bz2`, and disable live diffs.

## Hardware

Target: **Hetzner** Ryzen 9 5950X · **128 GB ECC** · **≥3.84 TB NVMe** (datacenter). Fast NVMe is
what makes planet Nominatim viable; the 16 cores make the imports quick. Point `DATA_DIR` at the NVMe.
Rough steady-state disk: Nominatim ~1 TB, Overpass ~120 GB, OSRM ~30 GB, planet `.pbf` ~80 GB.

## Server prep (once)

```bash
# 1. Mount the NVMe (RAID0 for space / RAID1 for redundancy — OSM data is reproducible) at /data.
# 2. Install Docker + compose plugin.
# 3. Point a DNS A record for $OSM_DOMAIN at this box (Caddy needs it for the TLS cert).
git clone git@github.com:milkosten/mikeos-osm.git && cd mikeos-osm
cp .env.example .env && $EDITOR .env       # set OSM_DOMAIN, OSM_TOKEN (openssl rand -hex 32), etc.
set -a; . ./.env; set +a
```

## Import runbook (order matters)

The imports are big one-time jobs. Nominatim's is the RAM-hungry one (~128 GB), so do it **first and
alone**, then bring up the others.

```bash
# 1) NOMINATIM — planet import (hours→a day on NVMe; auto-updates via replication after).
docker compose up -d nominatim
docker compose logs -f nominatim            # watch until "Import finished"

# 2) OVERPASS — planet init + then hourly diffs (a few hours).
docker compose up -d overpass

# 3) OSRM — build the graph (extract→partition→customize), THEN start the server.
./scripts/osrm-build.sh                     # heavy; needs NVMe temp space + RAM
docker compose up -d osrm

# 4) CADDY — TLS + token gate + routing.
docker compose up -d caddy

# Optional basemap (needs ../mikeos-basemap checked out):
docker compose --profile basemap up -d basemap
```

Tuning: if the Nominatim import is tight on RAM, cap osm2pgsql's cache (see the mediagis docs). MLD
keeps OSRM's serving memory modest by memory-mapping off NVMe — do NOT switch to CH on 128 GB.

## Verify

```bash
BASE=https://$OSM_DOMAIN ; H="Authorization: Bearer $OSM_TOKEN"
curl -s -H "$H" "$BASE/nominatim/search?q=eiffel+tower&format=json&limit=1" | head -c 200
curl -s -H "$H" "$BASE/overpass/api/interpreter" --data 'data=[out:json];node[amenity=cafe](48.85,2.29,48.86,2.30);out 3;' | head -c 200
curl -s -H "$H" "$BASE/route/route/v1/driving/2.29,48.85;2.35,48.86?overview=false" | head -c 200
```

## Staying current

- **Overpass** and **Nominatim** self-update from `REPLICATION_URL` (minute/hourly diffs) — nothing to do.
- **OSRM** has no live updater. Refresh on a cron (e.g. weekly): re-download the planet, re-run
  `scripts/osrm-build.sh`, `docker compose up -d osrm`.

## Cutover (point the app here)

Set these and rebuild/redeploy:
- app `Geocoder`/`PoiSearch` → `https://$OSM_DOMAIN/nominatim` and `/overpass` (+ the Bearer token),
- `mikeos-trips-cloud` `OSRM_BASE_URL` env → `https://$OSM_DOMAIN/route`.

See `mikeos-architecture/docs/services/osm.md` for the fleet-level description + roadmap.
