-- Week-over-week retention as three counters per week. Fresh installs get
-- these from schema.sql; existing D1 databases apply this file.
--
-- The Mac derives its own cohort from the last period it submitted, so the
-- intake never receives a cross-week identifier. Weeks recorded before this
-- shipped keep 0 in all three, which publishes as "unknown" rather than zero.
ALTER TABLE telemetry_periods ADD COLUMN new_macs INTEGER NOT NULL DEFAULT 0;
ALTER TABLE telemetry_periods ADD COLUMN returning_macs INTEGER NOT NULL DEFAULT 0;
ALTER TABLE telemetry_periods ADD COLUMN reactivated_macs INTEGER NOT NULL DEFAULT 0;
