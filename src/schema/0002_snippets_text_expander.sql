-- Append-only SQLite migration. Use STRICT tables so generated types stay honest.
-- This version may never be edited after it is shipped.
--
-- Task 12 (Materials): add the "Text Expander" field shown in the materials
-- mockup's "All Context" panel, alongside the existing free-form `annotation`.
-- Stored as a NOT NULL TEXT with a constant '' default so the ALTER is legal
-- on the STRICT `snippets` table and every existing row gets a well-defined
-- value (no backfill needed).
--
-- Constraints imposed by the SDK migration runner (unchanged from 0001):
--   * The whole file runs inside one runner-owned transaction — no
--     BEGIN/COMMIT/SAVEPOINT here.
--   * Runner-owned PRAGMAs (user_version, foreign_keys, …) may not be set here.

ALTER TABLE snippets ADD COLUMN text_expander TEXT NOT NULL DEFAULT '';
