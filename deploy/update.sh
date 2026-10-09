#!/bin/sh

# Rebuilds the Layercake extract of one region on a loop and publishes it to
# /srv/layercake/$REGION, replacing the previous build's directory in one step.
#
# Environment: REGION (directory name), PBF_URL (source .osm.pbf),
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

build() {
  rm -rf "$WORK"
  mkdir -p "$WORK/out"
  echo "Downloading ${PBF_URL}"
  curl -fsSL --retry 3 -R -o "$WORK/input.osm.pbf" "$PBF_URL"
  # shellcheck disable=SC2086
  ./entrypoint.sh "$WORK/input.osm.pbf" "$WORK/out" ${PROCESS_ARGS:-}

  # The files the Layercake explorer reads besides the Parquet: each layer's
  # row count and schema, and when the OSM data was extracted.
  for parquet in "$WORK"/out/*.parquet; do
    sed "s|{{INPUT}}|${parquet}|g; s|{{OUTPUT}}|${parquet%.parquet}.description.json|g" \
      deploy/describe.sql | duckdb
  done
  source_modified="$(date -u -r "$WORK/input.osm.pbf" +%Y-%m-%dT%H:%M:%SZ)"
  printf '{"timestamp":"%s"}\n' "$source_modified" > "$WORK/out/metadata.json"
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
