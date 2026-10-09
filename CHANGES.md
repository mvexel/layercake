# How this fork differs from Layercake

This is an unofficial fork of [osmus/layercake](https://github.com/osmus/layercake),
not the OpenStreetMap US Layercake. For the official extracts and explorer, see
[openstreetmap.us/our-work/layercake](https://openstreetmap.us/our-work/layercake/).

Forked from upstream `main` at
[`0d40503`](https://github.com/osmus/layercake/commit/0d405033d6fb8f5232d64efb520954fd5a202965)
(Release v0.4.0). Full diff of this branch against that commit:
[`0d40503...osm.lol`](https://github.com/mvexel/layercake/compare/0d405033d6fb8f5232d64efb520954fd5a202965...osm.lol).

A daily build of Utah from this branch is served at
[layercake.osm.lol](https://layercake.osm.lol), with
[the fork's explorer](https://github.com/mvexel/layercake.openstreetmap.us/blob/osm-lol/CHANGES.md)
at [/explore/](https://layercake.osm.lol/explore/).

## Data: `other_tags` on every layer

Branch [`other-tags`](https://github.com/mvexel/layercake/tree/other-tags) holds
only this change.

- Every layer gains an `other_tags` column, a `MAP(VARCHAR, VARCHAR)` holding
  each tag that is neither a column nor part of a prefix map (`names`,
  `alt_names`, ...). No tag of a selected element is dropped.
- `process.sh` reads which tags are promoted from the layer's own column list:
  every `tags['key']` and every `prefix_map('prefix:', ...)` in the outer
  `SELECT`. Adding, renaming or removing a column needs no second list to keep
  in sync. The `other_tags` macro is in `sql/macros.sql`.
- Checked on the Geofabrik Utah extract: in all nine layers every source tag
  lands in exactly one place. Relation areas lack the relation's `type` tag,
  which osmium's area assembler drops before Layercake sees it.
- Output is otherwise unchanged; files grow by 0 to 5 percent.

## Deployment (`deploy/`)

Not in upstream, which publishes to data.openstreetmap.us by other means.

- `deploy/compose.yaml` runs two services. `builder` downloads one region's PBF
  (`LAYERCAKE_REGION`, `LAYERCAKE_PBF_URL`; default Utah), runs the pipeline and
  publishes the result to a volume every 24 hours, retrying hourly after a
  failure. `layercake` serves the volume with Caddy.
- `deploy/update.sh` also writes the files the explorer reads from
  data.openstreetmap.us: `<layer>.description.json` (row count and schema, via
  `deploy/describe.sql`) and `metadata.json` (OSM data date; `bounds`, the region's bounding box from the Geofabrik
  `.poly` outline or else the data's extent; and `outline`, that `.poly` as a
  GeoJSON MultiPolygon, when there is one). `build.json` records the source and build time.
- Caddy (`deploy/Caddyfile`) sends CORS and range-request headers so DuckDB,
  including duckdb-wasm in a browser, can read the Parquet files remotely, and
  `Cache-Control: no-cache` because files are replaced in place each day.
- The Caddyfile and scripts are baked into the images (`deploy/web.Dockerfile`,
  and `COPY deploy` in the root `Dockerfile`) so that a redeploy recreates the
  containers.
- `CHANGES.md` (this file).
