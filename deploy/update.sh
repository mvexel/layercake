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

# Download the region's Geofabrik .poly outline next to the PBF, if there is
# one (POLY_URL overrides where it is looked for).
fetch_poly() {
  rm -f "$WORK/region.poly"
  curl -fsSL --retry 3 -o "$WORK/region.poly" "${POLY_URL:-${PBF_URL%-latest.osm.pbf}.poly}" \
    || rm -f "$WORK/region.poly"
}

# Print the region's bounding box as a JSON array [xmin, ymin, xmax, ymax]:
# from the .poly outline when there is one, which is the exact region,
# otherwise from the extent of the built data, which spills past it where
# ways and relations cross the edge.
bounds() {
  if [ -f "$WORK/region.poly" ]; then
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

# Print the .poly outline as a GeoJSON MultiPolygon, or nothing without one.
# In the .poly format each section is a ring: an outer ring starts a polygon,
# and a section whose name starts with ! is a hole in the polygon before it.
outline() {
  [ -f "$WORK/region.poly" ] || return 0
  awk 'NR == 1 { next }
    !inring {
      if ($1 == "END") exit
      inring = 1; hole = ($1 ~ /^!/); ring = ""; first = ""; last = ""
      next
    }
    $1 == "END" {
      inring = 0
      if (last != first) ring = ring "," first
      if (hole && n > 0) poly[n] = poly[n] ",[" ring "]"
      else if (!hole) poly[++n] = "[" ring "]"
      next
    }
    {
      point = sprintf("[%.5f,%.5f]", $1, $2)
      ring = ring (ring == "" ? "" : ",") point
      if (first == "") first = point
      last = point
    }
    END {
      if (n == 0) exit 1
      printf "{\"type\":\"MultiPolygon\",\"coordinates\":["
      for (i = 1; i <= n; i++) printf "%s[%s]", (i > 1 ? "," : ""), poly[i]
      printf "]}"
    }' "$WORK/region.poly" || true
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
  fetch_poly
  region_outline="$(outline)"
  printf '{"timestamp":"%s","bounds":%s%s}\n' "$source_modified" "$(bounds)" \
    "${region_outline:+,\"outline\":$region_outline}" > "$WORK/out/metadata.json"
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
