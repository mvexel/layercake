-- Writes the row count and schema of one layer as JSON, in the subset of the
-- format data.openstreetmap.us publishes as <layer>.description.json that the
-- Layercake explorer reads: Parquet-style fields with a logical annotation,
-- LIST and MAP payloads wrapped in a repeated group.
-- Run with {{INPUT}} replaced by the layer's Parquet file and {{OUTPUT}} by the
-- JSON file to write.

CREATE MACRO scalar_field(n, t) AS json_object(
  'name', n,
  'type', CASE
    WHEN t = 'VARCHAR' THEN 'binary'
    WHEN t IN ('BIGINT', 'UBIGINT') THEN 'int64'
    WHEN t IN ('INTEGER', 'UINTEGER') THEN 'int32'
    WHEN t = 'FLOAT' THEN 'float'
    WHEN t = 'DOUBLE' THEN 'double'
    WHEN t LIKE 'TIMESTAMP%' THEN 'int64'
    ELSE 'binary'
  END,
  'annotation', CASE
    WHEN t = 'VARCHAR' THEN 'string'
    WHEN t IN ('BIGINT', 'INTEGER') THEN 'int(signed)'
    WHEN t IN ('UBIGINT', 'UINTEGER') THEN 'int(unsigned)'
    WHEN t IN ('FLOAT', 'DOUBLE') THEN lower(t)
    WHEN t LIKE 'TIMESTAMP%' THEN 'timestamp'
  END
);

CREATE MACRO list_field(n, element) AS json_object(
  'name', n, 'annotation', 'list',
  'fields', [json_object('name', 'list', 'annotation', 'group', 'fields', [element])]
);

-- A scalar or a list of scalars: the most nesting a map value has in Layercake.
CREATE MACRO value_field(n, t) AS CASE
  WHEN t LIKE '%[]' THEN list_field(n, scalar_field('element', t[:-3]))
  ELSE scalar_field(n, t)
END;

CREATE MACRO column_field(n, t) AS CASE
  WHEN t LIKE 'MAP(%' THEN json_object(
    'name', n, 'annotation', 'map',
    'fields', [json_object('name', 'key_value', 'annotation', 'group', 'fields', [
      scalar_field('key', regexp_extract(t, '^MAP\((\w+), (.+)\)$', 1)),
      value_field('value', regexp_extract(t, '^MAP\((\w+), (.+)\)$', 2))
    ])]
  )
  WHEN t LIKE 'STRUCT(%' THEN json_object('name', n, 'annotation', 'group', 'fields', []::JSON[])
  ELSE value_field(n, t)
END;

COPY (
  SELECT
    (SELECT count(*) FROM '{{INPUT}}') AS rows,
    json_object('annotation', 'group', 'fields', list(column_field(column_name, column_type) ORDER BY ord)) AS schema
  FROM (SELECT row_number() OVER () AS ord, column_name, column_type FROM (DESCRIBE FROM '{{INPUT}}'))
) TO '{{OUTPUT}}' (FORMAT JSON);
