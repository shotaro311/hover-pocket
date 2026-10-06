CREATE TABLE IF NOT EXISTS sync_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS sync_events(revision TEXT PRIMARY KEY, entity_key TEXT NOT NULL, body TEXT NOT NULL, disposition TEXT NOT NULL, exported INTEGER NOT NULL DEFAULT 0);
CREATE INDEX IF NOT EXISTS sync_events_entity ON sync_events(entity_key,disposition);
CREATE TABLE IF NOT EXISTS sync_heads(entity_key TEXT PRIMARY KEY, revision TEXT NOT NULL, snapshot TEXT NOT NULL);
