//! Embeddings + vector search — PURE core (Task 7).
//!
//! Two responsibilities, both deterministic and unit-testable:
//!   1. Turn a piece of memory text into a fixed-dimension vector, and
//!      pack/unpack that vector to/from the `embeddings.vector` BLOB
//!      (raw little-endian f32, exactly as the schema documents).
//!   2. Rank stored vectors against a query vector by cosine similarity.
//!
//! **Embedder choice (v1):** a deterministic in-process HASHING embedder
//! (the "hashing trick" / feature hashing), model id `hash-v1`. It needs
//! no model download and no llama.cpp, so Task 7 does not block on Task 9
//! (local model management + llama.cpp runtime). Because it is one fixed
//! function of dim `dim`, the index never needs re-embedding — matching the
//! locked "ONE fixed embedding model" decision. When Task 9 lands a real
//! neural embedder, register it under a NEW `model` id (e.g.
//! `llama-<name>-v1`); the schema's UNIQUE(source_kind, source_id, model)
//! lets both coexist and lets a query pick which model's vectors to search.
//!
//! The effectful side (finding un-embedded rows, inserting vectors, running
//! the search query) lives in main.zig; nothing here spawns or touches a DB.

const std = @import("std");
const db = @import("db.zig");
const core = @import("embed_core.zig");

// The embedding math + hashing embedder + tokenizer + source-text builders
// + top-k ranking live in the SDK-free `embed_core.zig` so the standalone
// MCP server (which links libsqlite3, not `native_sdk`) can share the exact
// same embedder. Re-export them here so existing call sites and tests keep
// using `embeddings.<x>` unchanged.
pub const dim = core.dim;
pub const model_id = core.model_id;
pub const Vector = core.Vector;
pub const DecodeError = core.DecodeError;
pub const vectorBytes = core.vectorBytes;
pub const vectorFromBytes = core.vectorFromBytes;
pub const normalize = core.normalize;
pub const dot = core.dot;
pub const cosine = core.cosine;
pub const Tokenizer = core.Tokenizer;
pub const embed = core.embed;
pub const embedValue = core.embedValue;
pub const SourceKind = core.SourceKind;
pub const kindFromName = core.kindFromName;
pub const eventText = core.eventText;
pub const fileSnapshotText = core.fileSnapshotText;
pub const Hit = core.Hit;
pub const considerTopK = core.considerTopK;

// ------------------------------------------------ embeddings statements

pub const insert_sql =
    "INSERT INTO embeddings(source_kind, source_id, model, dim, vector, created_at) " ++
    "VALUES(?1, ?2, ?3, ?4, ?5, ?6);";

pub const insert_param_count = 6;

/// Fill a caller-owned param buffer for one embedding insert. The buffer
/// and the vector bytes MUST outlive the dbExec call (params copied at
/// call time). `vector_bytes` = `vectorBytes(&vec)`.
pub fn insertStatement(
    buf: *[insert_param_count]db.Value,
    kind: SourceKind,
    source_id: i64,
    vector_bytes: []const u8,
    now_ms: i64,
) db.Statement {
    buf.* = .{
        db.val.text(kind.name()),
        db.val.int(source_id),
        db.val.text(model_id),
        db.val.int(@intCast(dim)),
        db.val.blob(vector_bytes),
        db.val.int(now_ms),
    };
    return .{ .sql = insert_sql, .params = buf };
}

/// FTS insert (content-less external index): locate the origin row by
/// (ref_kind, ref_id) and index its `body` text for hybrid search.
pub const fts_insert_sql =
    "INSERT INTO memory_fts(ref_kind, ref_id, body) VALUES(?1, ?2, ?3);";

pub fn ftsInsertStatement(
    buf: *[3]db.Value,
    kind: SourceKind,
    source_id: i64,
    body: []const u8,
) db.Statement {
    buf.* = .{ db.val.text(kind.name()), db.val.int(source_id), db.val.text(body) };
    return .{ .sql = fts_insert_sql, .params = buf };
}

/// Find committed git-commit events that have no `hash-v1` embedding yet,
/// oldest first. `?1` = model id, `?2` = a row-limit.
pub const select_unembedded_events_sql =
    "SELECT e.id, e.subject, e.body FROM events e " ++
    "WHERE e.kind = 'commit' AND NOT EXISTS (" ++
    "  SELECT 1 FROM embeddings em WHERE em.source_kind = 'event' " ++
    "    AND em.source_id = e.id AND em.model = ?1) " ++
    "ORDER BY e.id LIMIT ?2;";

/// Find file snapshots with no `hash-v1` embedding yet, oldest first.
pub const select_unembedded_snapshots_sql =
    "SELECT f.id, f.rel_path, f.content FROM file_snapshots f " ++
    "WHERE NOT EXISTS (" ++
    "  SELECT 1 FROM embeddings em WHERE em.source_kind = 'file_snapshot' " ++
    "    AND em.source_id = f.id AND em.model = ?1) " ++
    "ORDER BY f.id LIMIT ?2;";

/// Load all stored vectors for a model for in-process cosine ranking.
/// `?1` = model id. (Shared with the standalone MCP server via embed_core.)
pub const select_vectors_sql = core.select_vectors_sql;

// ------------------------------------------------------- ranking
//
// `Hit`, `considerTopK`, and `kindFromName` live in `embed_core.zig` and
// are re-exported above. `rankPage` stays here because it decodes the SDK
// `db.PageReader` wire format (DB-coupled).

/// Rank a query vector against the stored vectors in a `select_vectors_sql`
/// result page (columns: source_kind TEXT, source_id INT, vector BLOB),
/// filling the top-`hits.len` results by cosine similarity. `count` is the
/// running fill count (pass 0 for the first page; the returned value for
/// subsequent pages of the same query). Rows with a malformed vector or an
/// unknown kind are skipped.
///
/// The query vector should be L2-normalized (as `embed` returns) and the
/// stored vectors are normalized too, so cosine reduces to a dot product.
pub fn rankPage(
    hits: []Hit,
    count: usize,
    query: *const Vector,
    page_bytes: []const u8,
) usize {
    var reader = db.PageReader.init(page_bytes) catch return count;
    var n = count;
    var row: [3]db.ColumnValue = undefined;
    var scratch: Vector = undefined;
    while (reader.next(&row) catch null) |cols| {
        if (cols.len < 3) continue;
        const kind_name = cols[0].asText() orelse continue;
        const kind = kindFromName(kind_name) orelse continue;
        const source_id = cols[1].asInt() orelse continue;
        const blob = cols[2].asBlob() orelse continue;
        vectorFromBytes(blob, &scratch) catch continue;
        const score = dot(query, &scratch);
        n = considerTopK(hits, n, .{ .kind = kind, .source_id = source_id, .score = score });
    }
    return n;
}

/// The FTS5 query that finds memory rows whose body matches `?1` (an FTS5
/// MATCH expression), best matches first. Used for the hybrid/keyword arm.
pub const fts_search_sql =
    "SELECT ref_kind, ref_id, rank FROM memory_fts WHERE memory_fts MATCH ?1 ORDER BY rank LIMIT ?2;";

// --------------------------------------------------------------- tests
//
// The pure embedder/tokenizer/vector-math/top-k tests live in
// `embed_core.zig`. Here we test the DB-coupled statement builders,
// `rankPage`, and the real-database integration paths.

const testing = std.testing;

test "insertStatement carries the vector blob + model + dim" {
    var vec = embedValue("hello world");
    const bytes = vectorBytes(&vec);
    var buf: [insert_param_count]db.Value = undefined;
    const stmt = insertStatement(&buf, .event, 42, bytes, 999);
    try testing.expectEqualStrings("event", stmt.params[0].text);
    try testing.expectEqual(@as(i64, 42), stmt.params[1].integer);
    try testing.expectEqualStrings(model_id, stmt.params[2].text);
    try testing.expectEqual(@as(i64, @intCast(dim)), stmt.params[3].integer);
    try testing.expectEqual(bytes.len, stmt.params[4].blob.len);
    try testing.expectEqual(@as(i64, 999), stmt.params[5].integer);
}

test "kindFromName round-trips the source kinds" {
    try testing.expectEqual(SourceKind.event, kindFromName("event").?);
    try testing.expectEqual(SourceKind.file_snapshot, kindFromName("file_snapshot").?);
    try testing.expect(kindFromName("bogus") == null);
}

// ---- Real-database integration tests ----

const native_sdk = @import("native_sdk");
const relational_store = native_sdk.runtime.relational_store;
const IntMsg = union(enum) { db: native_sdk.EffectDbResult };
const IntFx = native_sdk.Effects(IntMsg);

/// Insert an embedding for a source id from freshly embedded text.
fn insertEmbedded(fx: *IntFx, key: u64, kind: SourceKind, source_id: i64, text: []const u8) !void {
    var vec = embedValue(text);
    const bytes = vectorBytes(&vec);
    var params: [insert_param_count]db.Value = undefined;
    fx.dbExec(.{ .key = key, .statements = &.{insertStatement(&params, kind, source_id, bytes, 100)}, .on_result = IntFx.dbMsg(.db) });
    try testing.expectEqual(native_sdk.EffectDbOutcome.ok, fx.takeMsg().?.db.outcome);
}

test "vector search ranks the most similar stored source first" {
    const open_result = try relational_store.Database.openMemoryMigrated(testing.allocator, &db.migrations);
    try testing.expectEqual(relational_store.OpenOutcome.ok, open_result.outcome);
    var database = open_result.database.?;
    defer database.deinit();
    var fx = IntFx.init(testing.allocator);
    defer fx.deinit();
    fx.bindRelationalStore(database.binding());

    // Repo + a few commit events to reference (FK-clean, though embeddings
    // don't FK to sources).
    fx.dbExec(.{ .key = 1, .statements = &.{
        .{ .sql = "INSERT INTO repos(id, path, name, added_at) VALUES(1,'/r','r',1);" },
    }, .on_result = IntFx.dbMsg(.db) });
    try testing.expectEqual(native_sdk.EffectDbOutcome.ok, fx.takeMsg().?.db.outcome);

    // Three distinct memories, embedded with the real embedder.
    try insertEmbedded(&fx, 2, .event, 10, "add nginx reverse proxy config for the staging deployment");
    try insertEmbedded(&fx, 3, .event, 20, "refactor the sqlite migration runner and page reader");
    try insertEmbedded(&fx, 4, .event, 30, "write a banana smoothie recipe generator in the demo app");

    // Search for something clearly about the first memory.
    var query = embedValue("nginx deployment proxy configuration");

    fx.dbQuery(.{ .key = 5, .sql = select_vectors_sql, .params = &.{db.val.text(model_id)}, .on_result = IntFx.dbMsg(.db) });
    var top: [3]Hit = undefined;
    var n: usize = 0;
    // Drain page(s) then the terminal .done.
    while (true) {
        const r = fx.takeMsg().?.db;
        if (r.kind == .done) break;
        try testing.expectEqual(native_sdk.EffectDbResultKind.page, r.kind);
        n = rankPage(&top, n, &query, r.bytes);
    }
    try testing.expectEqual(@as(usize, 3), n);
    // The nginx/deployment memory (source_id 10) must rank first.
    try testing.expectEqual(SourceKind.event, top[0].kind);
    try testing.expectEqual(@as(i64, 10), top[0].source_id);
    // And it should out-score the unrelated smoothie memory.
    try testing.expect(top[0].score > top[2].score);
}

test "FTS hybrid arm finds a memory by keyword" {
    const open_result = try relational_store.Database.openMemoryMigrated(testing.allocator, &db.migrations);
    try testing.expectEqual(relational_store.OpenOutcome.ok, open_result.outcome);
    var database = open_result.database.?;
    defer database.deinit();
    var fx = IntFx.init(testing.allocator);
    defer fx.deinit();
    fx.bindRelationalStore(database.binding());

    // Fill memory_fts as the embedding pass would.
    var p1: [3]db.Value = undefined;
    var p2: [3]db.Value = undefined;
    fx.dbExec(.{ .key = 1, .statements = &.{
        ftsInsertStatement(&p1, .event, 10, "add nginx reverse proxy config"),
        ftsInsertStatement(&p2, .event, 20, "sqlite migration runner refactor"),
    }, .on_result = IntFx.dbMsg(.db) });
    try testing.expectEqual(native_sdk.EffectDbOutcome.ok, fx.takeMsg().?.db.outcome);

    fx.dbQuery(.{ .key = 2, .sql = fts_search_sql, .params = &.{ db.val.text("nginx"), db.val.int(10) }, .on_result = IntFx.dbMsg(.db) });
    const page = fx.takeMsg().?.db;
    try testing.expectEqual(native_sdk.EffectDbResultKind.page, page.kind);
    var reader = try db.PageReader.init(page.bytes);
    try testing.expectEqual(@as(usize, 1), reader.rowCount());
    var row: [3]db.ColumnValue = undefined;
    const cols = (try reader.next(&row)).?;
    try testing.expectEqualStrings("event", cols[0].asText().?);
    try testing.expectEqual(@as(i64, 10), cols[1].asInt().?);
    _ = fx.takeMsg(); // .done
}
