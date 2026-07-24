#!/usr/bin/env bash
# Download a planet/data file ONCE, on the HOST — never inside a container. Resumable + verified.
#
#   Usage: host-download.sh <url> <dest>
#
# Why on the host: a container that owns its download re-pulls the whole planet on every failed
# init (wiktorn wipes /db and re-downloads). aria2 -x16 also runs ~11x faster than a single-stream
# curl (~110 MiB/s vs ~10 MB/s). Files land in /data/planet-src, mounted read-only into containers.
set -uo pipefail
URL="$1"; DEST="$2"
DIR="$(dirname "$DEST")"; BASE="$(basename "$DEST")"
mkdir -p "$DIR"

echo "[host-dl] $(date -u +%H:%M:%S) downloading $URL -> $DEST"
until aria2c -x16 -s16 -c --file-allocation=none --console-log-level=warn --summary-interval=30 \
        --auto-file-renaming=false --allow-overwrite=true -d "$DIR" -o "$BASE" "$URL"; do
  echo "[host-dl] interrupted — retrying in 15s (aria2 -c resumes)…"; sleep 15
done

echo "[host-dl] download complete, verifying…"
# Prefer the fast published md5 (reads the file once at disk speed, ~2-3 min for 164 GB). This is
# the checksum both the planet .osm.bz2 and .pbf publish at <url>.md5.
EXP="$(curl -fsSL "$URL.md5" 2>/dev/null | grep -oiE '^[0-9a-f]{32}' | head -1 || true)"
if [ -n "$EXP" ]; then
  GOT="$(md5sum "$DEST" | awk '{print $1}')"
  if [ "$GOT" = "$EXP" ]; then
    echo "[host-dl] md5 OK ($GOT)"
  else
    echo "[host-dl] CORRUPT: md5 mismatch (got $GOT, expected $EXP)"; exit 1
  fi
else
  # No published checksum — fall back to a format integrity test.
  case "$DEST" in
    *.bz2) bzip2 -t "$DEST" && echo "[host-dl] bzip2 integrity OK" || { echo "[host-dl] CORRUPT bz2"; exit 1; } ;;
    *.pbf) command -v osmium >/dev/null && { osmium fileinfo "$DEST" >/dev/null && echo "[host-dl] pbf OK"; } || echo "[host-dl] (no osmium — skipped pbf check)" ;;
  esac
fi
echo "[host-dl] DONE $(date -u +%H:%M:%S)  $(ls -lh "$DEST")"
