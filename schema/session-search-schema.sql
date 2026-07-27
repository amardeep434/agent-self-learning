-- session-search-schema.sql
--
-- BASE SQLite schema for cross-session search: the sessions/messages tables
-- and their plain indexes. Always applied, on every platform, regardless of
-- whether the local SQLite build has the FTS5 extension.
--
-- Full-text search itself (the messages_fts virtual table + sync triggers)
-- lives in the SIBLING file session-search-fts5.sql, applied only after a
-- functional probe (scripts/lib/session_db.py's probe_fts5()) confirms FTS5
-- is actually available -- not inferred from platform name. This split
-- exists because macOS's bundled `sqlite3` CLI is commonly built WITHOUT
-- FTS5 (`no such module: fts5`), which used to fail loudly mid-script and
-- then get silently absorbed by the old `sqlite3 db < schema.sql` CLI
-- invocation -- the base tables never got created either, on a platform
-- where a working Python sqlite3 module (with FTS5) was sitting right
-- there unused. See session_db.py's module docstring for the full story.
--
-- Tables:
--   sessions - one row per Claude Code session
--   messages - individual messages within sessions

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

-- Index for session lookup and chronological browsing
CREATE INDEX IF NOT EXISTS idx_sessions_last_active
    ON sessions(last_active DESC);
CREATE INDEX IF NOT EXISTS idx_sessions_project
    ON sessions(project_path, last_active DESC);
CREATE INDEX IF NOT EXISTS idx_messages_session
    ON messages(session_id, msg_index);
