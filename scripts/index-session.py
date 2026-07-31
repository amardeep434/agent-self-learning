#!/usr/bin/env python3
"""
index-session.py
Parse a Claude Code session JSONL file and insert into the SQLite FTS5
search index.

Usage:
    python3 index-session.py <jsonl_path> <db_path> <project_path>

Arguments:
    jsonl_path    - Path to the session's JSONL file
    db_path       - Path to the SQLite search database
    project_path  - Relative project path (used for grouping)
"""

from __future__ import annotations

import json
import os
import sqlite3
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from isotime import now_iso  # noqa: E402  (fix round D: shared with skill-lifecycle.py, persist-proposal.py, coach-signals.py)


def parse_session(jsonl_path: str) -> dict:
    """Parse a JSONL session file into structured data.

    Handles multiple Claude Code JSONL message formats:
    - Nested message objects with content arrays (tool_use, tool_result, text)
    - Simple string content fields
    - Various timestamp field names (timestamp, ts)
    """
    messages = []
    session_start = None
    session_end = None
    title = None

    with open(jsonl_path, 'r') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue

            role = entry.get('type', entry.get('role', 'unknown'))
            content = ''

            # Extract text content from various message formats
            if isinstance(entry.get('message'), dict):
                msg = entry['message']
                role = msg.get('role', role)
                msg_content = msg.get('content', '')
                if isinstance(msg_content, str):
                    content = msg_content
                elif isinstance(msg_content, list):
                    text_parts = []
                    for block in msg_content:
                        if isinstance(block, dict):
                            if block.get('type') == 'text':
                                text_parts.append(block.get('text', ''))
                            elif block.get('type') == 'tool_use':
                                text_parts.append(
                                    f"[tool: {block.get('name', '?')}]"
                                )
                            elif block.get('type') == 'tool_result':
                                result = block.get('content', '')
                                if isinstance(result, list):
                                    result = ' '.join(
                                        b.get('text', '')
                                        for b in result
                                        if isinstance(b, dict)
                                    )
                                # Truncate large tool results to keep DB lean
                                if len(str(result)) > 500:
                                    result = str(result)[:500] + '...'
                                text_parts.append(str(result))
                        elif isinstance(block, str):
                            text_parts.append(block)
                    content = '\n'.join(text_parts)
            elif isinstance(entry.get('content'), str):
                content = entry['content']

            timestamp = entry.get('timestamp', entry.get('ts'))

            if not content.strip():
                continue

            if session_start is None and timestamp:
                session_start = timestamp
            if timestamp:
                session_end = timestamp

            # Use first user message as session title
            if title is None and role in ('user', 'human'):
                title = content[:80].replace('\n', ' ')

            messages.append({
                'index': len(messages),
                'role': role,
                'content': content,
                'timestamp': timestamp,
            })

    now = now_iso()
    return {
        'title': title or '(untitled session)',
        'started_at': session_start or now,
        'last_active': session_end or now,
        'message_count': len(messages),
        'messages': messages,
    }


def detect_parent_session(jsonl_path: str) -> str | None:
    """Detect parent session from a .meta.json sidecar file.

    If the session was created by context compression, a sidecar file
    <session-id>.meta.json will contain the parent_session_id.
    """
    meta_path = Path(jsonl_path).with_suffix('.meta.json')
    if meta_path.exists():
        try:
            with open(meta_path, 'r') as f:
                meta = json.load(f)
            return meta.get('parent_session_id')
        except (json.JSONDecodeError, OSError):
            pass
    return None


def index_session(jsonl_path: str, db_path: str, project_path: str) -> None:
    """Index a single session into the search database.

    Inserts session metadata and all messages. The FTS5 virtual table
    is kept in sync via SQLite triggers defined in the schema.
    """
    session_id = Path(jsonl_path).stem
    data = parse_session(jsonl_path)

    if data['message_count'] == 0:
        return

    parent_id = detect_parent_session(jsonl_path)

    conn = sqlite3.connect(db_path)
    # search.db carries full unredacted session text; never leave it at umask
    # default. chmod after connect (not umask before) so a pre-existing 0644 DB
    # from an older install is repaired on the next index run.
    os.chmod(db_path, 0o600)
    now = now_iso()

    try:
        # fix-p6: this used to be the shell wrapper's job (index-session.sh
        # SELECTed indexed_at via the `sqlite3` CLI, then issued two more
        # CLI DELETEs if a row already existed) -- folded in here so the
        # whole index path uses only Python's sqlite3 module, no `sqlite3`
        # CLI dependency at runtime. Unconditional and idempotent: a no-op
        # DELETE when session_id has never been indexed, and necessary (not
        # just belt-and-suspenders) when it HAS -- INSERT OR REPLACE alone
        # would leave stale trailing rows behind if a re-indexed session
        # now has FEWER messages than it did last time.
        conn.execute("DELETE FROM messages WHERE session_id = ?", (session_id,))

        conn.execute(
            """INSERT OR REPLACE INTO sessions
               (session_id, project_path, title, started_at, last_active,
                message_count, source, parent_id, indexed_at)
               VALUES (?, ?, ?, ?, ?, ?, 'interactive', ?, ?)""",
            (
                session_id, project_path, data['title'],
                data['started_at'], data['last_active'],
                data['message_count'], parent_id, now,
            ),
        )

        for msg in data['messages']:
            conn.execute(
                """INSERT OR REPLACE INTO messages
                   (session_id, msg_index, role, content, timestamp)
                   VALUES (?, ?, ?, ?, ?)""",
                (
                    session_id, msg['index'], msg['role'],
                    msg['content'], msg['timestamp'],
                ),
            )

        conn.commit()
    finally:
        conn.close()


if __name__ == '__main__':
    if len(sys.argv) != 4:
        print(f"Usage: {sys.argv[0]} <jsonl_path> <db_path> <project_path>",
              file=sys.stderr)
        sys.exit(1)
    index_session(sys.argv[1], sys.argv[2], sys.argv[3])
