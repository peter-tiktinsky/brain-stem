-- hooks/lib/manifest-migrate.sql
-- Writer Manifest SQLite migration (v1).
-- Applied by hooks/lib/manifest-record.sh init.
-- The sqlite DDL the manifest writer applies.
--
-- Column shape mirrors schemas/writer-manifest-schema.json :: writes.items.properties
-- (12 fields, ordered to match the schema). CHECK constraints mirror the JSON
-- Schema enum constraints. WAL journal mode enables concurrent reader safety
-- alongside the single writer serialized by hooks/lib/manifest-record.sh
-- record-write lockf. user_version=1 enables future migration chaining.

PRAGMA journal_mode=WAL;
PRAGMA user_version=1;

CREATE TABLE IF NOT EXISTS writes (
  id               TEXT PRIMARY KEY,
  writer_id        TEXT NOT NULL,
  destination_path TEXT NOT NULL,
  ingestion_date   TEXT NOT NULL,
  source_id        TEXT,
  content_sha256   TEXT NOT NULL,
  raw_path         TEXT,
  status           TEXT NOT NULL CHECK (status IN ('active', 'superseded')),
  superseded_by    TEXT,
  write_bucket     TEXT NOT NULL CHECK (write_bucket IN ('create', 'modify-append', 'modify-amend')),
  packet_kind      TEXT CHECK (packet_kind IS NULL OR packet_kind IN ('writer-emit', 'amender-replacement', 'amender-conflict')),
  notes            TEXT
);

CREATE INDEX IF NOT EXISTS idx_writes_ingestion_date   ON writes(ingestion_date);
CREATE INDEX IF NOT EXISTS idx_writes_destination_path ON writes(destination_path);
CREATE INDEX IF NOT EXISTS idx_writes_source_id        ON writes(source_id);
CREATE INDEX IF NOT EXISTS idx_writes_writer_id        ON writes(writer_id);
