-- Append-only SQLite migration. Use STRICT tables so generated types stay honest.
-- This version may never be edited after it is shipped.
--
-- Blocks initial schema: the developer-memory store plus the app's own
-- chat/snippets data. All timestamps are Unix milliseconds (INTEGER).
--
-- Constraints imposed by the SDK migration runner (do NOT change):
--   * The whole file runs inside one runner-owned transaction — no
--     BEGIN/COMMIT/SAVEPOINT here.
--   * Runner-owned PRAGMAs (user_version, foreign_keys, journal_mode, …)
--     may not be set from a migration.
--   * CREATE VIRTUAL TABLE (FTS5) and triggers ARE permitted.
--
-- Note on foreign keys: we declare REFERENCES for documentation and to
-- enable ON DELETE CASCADE where the pragma is on, but the app also
-- deletes children explicitly so integrity holds regardless of the
-- session's foreign_keys setting.

-- ---------------------------------------------------------------------
-- Watched repositories
-- ---------------------------------------------------------------------
CREATE TABLE repos (
    id            INTEGER PRIMARY KEY,
    -- Absolute path to the repository working tree.
    path          TEXT NOT NULL UNIQUE,
    -- Display name (defaults to the trailing path component).
    name          TEXT NOT NULL,
    -- Whether capture is currently active for this repo.
    active        INTEGER NOT NULL DEFAULT 1,
    -- The last git commit OID indexed, so git capture is incremental.
    last_indexed_oid TEXT,
    -- Unix-ms bookkeeping.
    added_at      INTEGER NOT NULL,
    last_indexed_at INTEGER
) STRICT;

-- ---------------------------------------------------------------------
-- Git activity events: commits, branch create/delete, checkouts.
-- ---------------------------------------------------------------------
CREATE TABLE events (
    id            INTEGER PRIMARY KEY,
    repo_id       INTEGER NOT NULL REFERENCES repos(id) ON DELETE CASCADE,
    -- 'commit' | 'branch' | 'checkout'
    kind          TEXT NOT NULL,
    -- When the activity happened (author/commit time or observed time), Unix-ms.
    occurred_at   INTEGER NOT NULL,
    -- Commit-specific fields (NULL for non-commit kinds).
    commit_oid    TEXT,
    author_name   TEXT,
    author_email  TEXT,
    subject       TEXT,           -- first line of the commit message
    body          TEXT,           -- remaining message body
    -- Branch/checkout context (e.g. the ref name).
    ref_name      TEXT,
    -- Aggregate diff for a commit (unified diff text). May be large.
    diff          TEXT,
    files_changed INTEGER NOT NULL DEFAULT 0,
    insertions    INTEGER NOT NULL DEFAULT 0,
    deletions     INTEGER NOT NULL DEFAULT 0,
    created_at    INTEGER NOT NULL
) STRICT;

CREATE INDEX idx_events_repo_time ON events(repo_id, occurred_at);
CREATE INDEX idx_events_kind ON events(kind);
-- One row per commit per repo; NULL commit_oid rows (branch/checkout) are
-- exempt from the uniqueness constraint via the partial index.
CREATE UNIQUE INDEX idx_events_commit ON events(repo_id, commit_oid) WHERE commit_oid IS NOT NULL;

-- ---------------------------------------------------------------------
-- Working-tree file snapshots (debounced save capture, Task 5).
-- Stores full content plus a diff against the previous snapshot.
-- ---------------------------------------------------------------------
CREATE TABLE file_snapshots (
    id            INTEGER PRIMARY KEY,
    repo_id       INTEGER NOT NULL REFERENCES repos(id) ON DELETE CASCADE,
    -- Path relative to the repo root.
    rel_path      TEXT NOT NULL,
    -- Full file contents at capture time.
    content       TEXT NOT NULL,
    -- Unified diff vs the previous snapshot of this file ("" for the first).
    diff          TEXT NOT NULL DEFAULT '',
    -- SHA-256 (hex) of content, to skip storing unchanged saves.
    content_hash  TEXT NOT NULL,
    byte_len      INTEGER NOT NULL DEFAULT 0,
    captured_at   INTEGER NOT NULL
) STRICT;

CREATE INDEX idx_snapshots_repo_path_time ON file_snapshots(repo_id, rel_path, captured_at);

-- ---------------------------------------------------------------------
-- Chats + messages (Task 10/11).
-- ---------------------------------------------------------------------
CREATE TABLE chats (
    id            INTEGER PRIMARY KEY,
    title         TEXT NOT NULL,
    -- One-line preview shown under the title in the sidebar.
    preview       TEXT NOT NULL DEFAULT '',
    -- 'chat' for normal chats; 'day_recap' | 'top_of_mind' | 'standup' for
    -- single-click summaries (each still lives as a chat in the list).
    kind          TEXT NOT NULL DEFAULT 'chat',
    created_at    INTEGER NOT NULL,
    updated_at    INTEGER NOT NULL
) STRICT;

CREATE INDEX idx_chats_updated ON chats(updated_at);

CREATE TABLE messages (
    id            INTEGER PRIMARY KEY,
    chat_id       INTEGER NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
    -- 'user' | 'assistant' | 'system'
    role          TEXT NOT NULL,
    content       TEXT NOT NULL,
    -- Ordering within a chat (monotonic per chat).
    seq           INTEGER NOT NULL,
    created_at    INTEGER NOT NULL
) STRICT;

CREATE INDEX idx_messages_chat_seq ON messages(chat_id, seq);

-- ---------------------------------------------------------------------
-- Snippets ("materials", Task 12), cross-linked with chats.
-- ---------------------------------------------------------------------
CREATE TABLE snippets (
    id            INTEGER PRIMARY KEY,
    title         TEXT NOT NULL,
    -- Source code / material body.
    content       TEXT NOT NULL,
    -- Programming language tag for syntax highlighting + language filter.
    language      TEXT NOT NULL DEFAULT '',
    -- Free-form annotation ("All Context" panel in the mockup).
    annotation    TEXT NOT NULL DEFAULT '',
    -- Optional origin: the chat/message a snippet was saved from
    -- ("Save to Snippets"). NULL when created directly.
    origin_chat_id    INTEGER REFERENCES chats(id) ON DELETE SET NULL,
    origin_message_id INTEGER REFERENCES messages(id) ON DELETE SET NULL,
    created_at    INTEGER NOT NULL,
    updated_at    INTEGER NOT NULL
) STRICT;

CREATE INDEX idx_snippets_lang ON snippets(language);
CREATE INDEX idx_snippets_updated ON snippets(updated_at);

-- ---------------------------------------------------------------------
-- Embeddings for semantic search (Task 7). One row per embedded item.
-- The vector is stored as a raw little-endian f32 BLOB; `dim` records the
-- length. `source_kind` + `source_id` point back at the origin row.
-- ---------------------------------------------------------------------
CREATE TABLE embeddings (
    id            INTEGER PRIMARY KEY,
    -- 'event' | 'file_snapshot' | 'message' | 'snippet'
    source_kind   TEXT NOT NULL,
    source_id     INTEGER NOT NULL,
    -- The embedding model identifier the vector was produced with, so a
    -- model change can re-embed cleanly.
    model         TEXT NOT NULL,
    dim           INTEGER NOT NULL,
    vector        BLOB NOT NULL,
    created_at    INTEGER NOT NULL
) STRICT;

CREATE UNIQUE INDEX idx_embeddings_source ON embeddings(source_kind, source_id, model);

-- ---------------------------------------------------------------------
-- Full-text search over searchable memory text (Task 7/8 hybrid search).
-- FTS5 external-content table backed by a UNION of the searchable columns.
-- We keep it simple with a content-less FTS index that the app fills
-- alongside inserts; `ref_kind`/`ref_id` locate the origin row.
-- (FTS5 tables cannot be STRICT.)
-- ---------------------------------------------------------------------
CREATE VIRTUAL TABLE memory_fts USING fts5(
    ref_kind UNINDEXED,
    ref_id UNINDEXED,
    body
);
