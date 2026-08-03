CREATE TABLE IF NOT EXISTS telemetry_batches (
  batch_id TEXT PRIMARY KEY,
  received_at TEXT NOT NULL,
  period TEXT NOT NULL,
  app_version TEXT NOT NULL,
  host_version TEXT,
  macos_major INTEGER NOT NULL,
  architecture TEXT NOT NULL,
  payload TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS telemetry_batches_period
  ON telemetry_batches (period);

CREATE INDEX IF NOT EXISTS telemetry_batches_version
  ON telemetry_batches (app_version);

-- Public community stats are built from these rollups, never from raw batch
-- rows. `sample_count` is the number of batches contributing the item;
-- `value_total` is used for percentages such as model shares and feature
-- adoption.
CREATE TABLE IF NOT EXISTS telemetry_periods (
  period TEXT PRIMARY KEY,
  batch_count INTEGER NOT NULL DEFAULT 0,
  last_received_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS telemetry_dimensions (
  period TEXT NOT NULL,
  dimension TEXT NOT NULL,
  item TEXT NOT NULL,
  sample_count INTEGER NOT NULL DEFAULT 0,
  value_total REAL NOT NULL DEFAULT 0,
  PRIMARY KEY (period, dimension, item)
);

CREATE INDEX IF NOT EXISTS telemetry_dimensions_period
  ON telemetry_dimensions (period);
