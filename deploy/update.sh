#!/bin/sh

# Rebuilds the Layercake extract of one region on a loop and publishes it to
# /srv/layercake/$REGION, replacing the previous build's directory in one step.
#
# Environment: REGION (directory name), PBF_URL (source .osm.pbf), POLY_URL
# (region outline, default: PBF_URL's Geofabrik .poly),
# BUILD_INTERVAL (seconds between builds, default one day), RETRY_INTERVAL
# (seconds before retrying a failed build, default one hour), PROCESS_ARGS
# (extra process.sh flags).

set -eu

: "${REGION:?REGION is required}"
: "${PBF_URL:?PBF_URL is required}"
BUILD_INTERVAL="${BUILD_INTERVAL:-86400}"
RETRY_INTERVAL="${RETRY_INTERVAL:-3600}"

SERVE=/srv/layercake
# Inside the served volume so publishing is a rename, not a copy; the web
# server hides dot-directories.
WORK="${SERVE}/.build"

# Print the region's bounding box as a JSON array [xmin, ymin, xmax, ymax]:
# from the Geofabrik .poly outline next to the PBF when there is one, which
# is the exact region, otherwise from the extent of the built data, which
# spills past it where ways and relations cross the edge.
bounds() {
  if curl -fsSL --retry 3 -o "$WORK/region.poly" "${POLY_URL:-${PBF_URL%-latest.osm.pbf}.poly}"; then
    awk 'NF == 2 && $1 + 0 == $1 && $2 + 0 == $2 {
        x = $1 + 0; y = $2 + 0
        if (n++ == 0) { xmin = xmax = x; ymin = ymax = y }
        if (x < xmin) xmin = x; if (x > xmax) xmax = x
        if (y < ymin) ymin = y; if (y > ymax) ymax = y
      }
      END { if (n == 0) exit 1; printf "[%.5f,%.5f,%.5f,%.5f]", xmin, ymin, xmax, ymax }' \
      "$WORK/region.poly" && return
  fi
  duckdb -noheader -list -c "SELECT format('[{:.5f},{:.5f},{:.5f},{:.5f}]',
      min(bbox.xmin), min(bbox.ymin), max(bbox.xmax), max(bbox.ymax))
    FROM read_parquet('$WORK/out/*.parquet', union_by_name = true)"
}

build() {
  rm -rf "$WORK"
  mkdir -p "$WORK/out"
  echo "Downloading ${PBF_URL}"
  curl -fsSL --retry 3 -R -o "$WORK/input.osm.pbf" "$PBF_URL"
  # shellcheck disable=SC2086
  ./entrypoint.sh "$WORK/input.osm.pbf" "$WORK/out" ${PROCESS_ARGS:-}

  # The files the Layercake explorer reads besides the Parquet: each layer's
  # row count and schema, and when the OSM data was extracted and where it is.
  for parquet in "$WORK"/out/*.parquet; do
    sed "s|{{INPUT}}|${parquet}|g; s|{{OUTPUT}}|${parquet%.parquet}.description.json|g" \
      deploy/describe.sql | duckdb
  done
  source_modified="$(date -u -r "$WORK/input.osm.pbf" +%Y-%m-%dT%H:%M:%SZ)"
  printf '{"timestamp":"%s","bounds":%s}\n' "$source_modified" "$(bounds)" > "$WORK/out/metadata.json"
  printf '{"region":"%s","source":"%s","source_modified":"%s","built_at":"%s"}\n' \
    "$REGION" "$PBF_URL" "$source_modified" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$WORK/out/build.json"

  rm -rf "${SERVE}/.${REGION}.old"
  [ -d "${SERVE}/${REGION}" ] && mv "${SERVE}/${REGION}" "${SERVE}/.${REGION}.old"
  mv "$WORK/out" "${SERVE}/${REGION}"
  rm -rf "${SERVE}/.${REGION}.old" "$WORK"
  echo "Published ${SERVE}/${REGION}"
}

# Each build runs as its own process: errexit does not apply inside a
# function called as an `if` condition, so `if build` would carry on past a
# failed step.
if [ "${1:-}" = "--once" ]; then
  build
  exit
fi

while true; do
  if "$0" --once; then
    sleep "$BUILD_INTERVAL"
  else
    echo "Build failed; retrying in ${RETRY_INTERVAL}s" >&2
    sleep "$RETRY_INTERVAL"
  fi
done
