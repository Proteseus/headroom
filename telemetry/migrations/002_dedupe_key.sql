-- Week-scoped install dedupe. Fresh installs get this from schema.sql;
-- existing D1 databases apply this file via wrangler d1 execute.
ALTER TABLE telemetry_batches ADD COLUMN dedupe_key TEXT;

-- Pre-dedupe rows keep counting once via batch_id as a stand-in key.
UPDATE telemetry_batches
SET dedupe_key = batch_id
WHERE dedupe_key IS NULL OR dedupe_key = '';

CREATE UNIQUE INDEX IF NOT EXISTS telemetry_batches_period_dedupe
  ON telemetry_batches (period, dedupe_key);
