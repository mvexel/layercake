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
  printf '{"region":"%s","source":"%s","source_modified":"%s","built_at":"%s"}\n' \
    "$REGION" "$PBF_URL" \
    "$(date -u -r "$WORK/input.osm.pbf" +%Y-%m-%dT%H:%M:%SZ)" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$WORK/out/build.json"

  rm -rf "${SERVE}/.${REGION}.old"
  [ -d "${SERVE}/${REGION}" ] && mv "${SERVE}/${REGION}" "${SERVE}/.${REGION}.old"
  mv "$WORK/out" "${SERVE}/${REGION}"
  rm -rf "${SERVE}/.${REGION}.old" "$WORK"
  echo "Published ${SERVE}/${REGION}"
}

while true; do
  if build; then
    sleep "$BUILD_INTERVAL"
  else
    echo "Build failed; retrying in ${RETRY_INTERVAL}s" >&2
    sleep "$RETRY_INTERVAL"
  fi
done
