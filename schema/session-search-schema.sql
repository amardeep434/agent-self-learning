-- session-search-schema.sql
--
-- SQLite schema for cross-session full-text search.
-- Initialized by install.sh or index-session.sh on first use.
--
-- Tables:
--   sessions     - one row per Claude Code session
--   messages     - individual messages within sessions
--   messages_fts - FTS5 virtual table for full-text search
--
-- Triggers keep messages_fts in sync with the messages table
-- automatically on insert, update, and delete.

CREATE TABLE IF NOT EXISTS sessions (
    session_id    TEXT PRIMARY KEY,
    project_path  TEXT NOT NULL,
    title         TEXT,           -- first user message, truncated
    started_at    TEXT NOT NULL,  -- ISO 8601
    last_active   TEXT NOT NULL,  -- ISO 8601
    message_count INTEGER DEFAULT 0,
    source        TEXT DEFAULT 'interactive',  -- interactive|cron|subagent|tool
    parent_id     TEXT,           -- lineage tracking
    indexed_at    TEXT NOT NULL   -- when this session was indexed
);

CREATE TABLE IF NOT EXISTS messages (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id  TEXT NOT NULL REFERENCES sessions(session_id),
    msg_index   INTEGER NOT NULL, -- position within session (0-based)
    role        TEXT NOT NULL,     -- user|assistant|tool_call|tool_result
    content     TEXT NOT NULL,
    timestamp   TEXT,              -- ISO 8601 if available
    UNIQUE(session_id, msg_index)
);

-- FTS5 virtual table for full-text search
CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
    content,                       -- searchable text
    content=messages,              -- content table
    content_rowid=id,              -- rowid mapping
    tokenize='porter unicode61'    -- stemming + unicode support
);

-- Triggers to keep FTS5 in sync with messages table
CREATE TRIGGER IF NOT EXISTS messages_ai AFTER INSERT ON messages BEGIN
    INSERT INTO messages_fts(rowid, content) VALUES (new.id, new.content);
END;

CREATE TRIGGER IF NOT EXISTS messages_ad AFTER DELETE ON messages BEGIN
    INSERT INTO messages_fts(messages_fts, rowid, content)
        VALUES('delete', old.id, old.content);
END;

CREATE TRIGGER IF NOT EXISTS messages_au AFTER UPDATE ON messages BEGIN
    INSERT INTO messages_fts(messages_fts, rowid, content)
        VALUES('delete', old.id, old.content);
    INSERT INTO messages_fts(rowid, content) VALUES (new.id, new.content);
END;

-- Index for session lookup and chronological browsing
CREATE INDEX IF NOT EXISTS idx_sessions_last_active
    ON sessions(last_active DESC);
CREATE INDEX IF NOT EXISTS idx_sessions_project
    ON sessions(project_path, last_active DESC);
CREATE INDEX IF NOT EXISTS idx_messages_session
    ON messages(session_id, msg_index);
