-- session-search-fts5.sql
--
-- FTS5 full-text search index for the `messages` table defined in the
-- sibling session-search-schema.sql. Applied ONLY after
-- scripts/lib/session_db.py's probe_fts5() confirms the local SQLite build
-- actually supports FTS5 (a functional probe, not a version/platform
-- guess) -- macOS's bundled `sqlite3` CLI commonly lacks this extension
-- even though Python's own bundled SQLite usually has it. When FTS5 is
-- unavailable, this file is never applied and session_db.py's search()
-- falls back to a `content LIKE '%...%'` substring query against the same
-- `messages` table -- slower and unranked, but never a silently empty
-- index.

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
