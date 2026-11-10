PRAGMA foreign_keys = ON;

CREATE TABLE hosts (
    id TEXT PRIMARY KEY NOT NULL,
    display_name TEXT NOT NULL,
    public_key BLOB NOT NULL UNIQUE,
    fingerprint TEXT NOT NULL UNIQUE,
    enrolled_at_ms INTEGER NOT NULL,
    revoked_at_ms INTEGER
);

CREATE TABLE devices (
    id TEXT PRIMARY KEY NOT NULL,
    display_name TEXT NOT NULL,
    ssh_public_key TEXT NOT NULL UNIQUE,
    fingerprint TEXT NOT NULL UNIQUE,
    created_at_ms INTEGER NOT NULL,
    last_used_at_ms INTEGER,
    revoked_at_ms INTEGER
);

CREATE TABLE device_host_grants (
    device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    host_id TEXT NOT NULL REFERENCES hosts(id) ON DELETE CASCADE,
    created_at_ms INTEGER NOT NULL,
    revoked_at_ms INTEGER,
    PRIMARY KEY (device_id, host_id)
);

CREATE TABLE pairing_tokens (
    digest BLOB PRIMARY KEY NOT NULL,
    host_id TEXT NOT NULL REFERENCES hosts(id) ON DELETE CASCADE,
    created_at_ms INTEGER NOT NULL,
    expires_at_ms INTEGER NOT NULL,
    consumed_at_ms INTEGER
);

CREATE INDEX pairing_tokens_active_idx
    ON pairing_tokens(expires_at_ms, consumed_at_ms);

CREATE TABLE host_enrollment_tokens (
    digest BLOB PRIMARY KEY NOT NULL,
    created_at_ms INTEGER NOT NULL,
    expires_at_ms INTEGER NOT NULL,
    consumed_at_ms INTEGER
);

CREATE INDEX host_enrollment_tokens_active_idx
    ON host_enrollment_tokens(expires_at_ms, consumed_at_ms);

CREATE TABLE audit_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    occurred_at_ms INTEGER NOT NULL,
    actor_type TEXT NOT NULL,
    actor_id TEXT,
    action TEXT NOT NULL,
    target_type TEXT,
    target_id TEXT,
    outcome TEXT NOT NULL,
    bytes_in INTEGER NOT NULL DEFAULT 0,
    bytes_out INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX audit_events_occurred_idx ON audit_events(occurred_at_ms);
