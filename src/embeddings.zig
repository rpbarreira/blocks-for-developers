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

/// Fixed embedding dimension for the v1 hashing embedder. Chosen small so
/// a vector is 1 KiB (256 × f32) — cheap to store and to score in-process.
pub const dim: usize = 256;

/// Identifier stored in `embeddings.model`, so a future embedder can be
/// distinguished and the two never collide on the UNIQUE index.
pub const model_id = "hash-v1";

/// A dim-length embedding vector.
pub const Vector = [dim]f32;

// ------------------------------------------------------- vector <-> blob

/// Reinterpret a vector as its raw little-endian byte blob for storage.
/// (x86/arm64 are little-endian, matching the schema's documented format.)
pub fn vectorBytes(vec: *const Vector) []const u8 {
    return std.mem.sliceAsBytes(vec[0..]);
}

pub const DecodeError = error{BadVectorBytes};

/// Decode a stored BLOB back into a vector. The blob must be exactly
/// `dim * 4` bytes.
pub fn vectorFromBytes(bytes: []const u8, out: *Vector) DecodeError!void {
    if (bytes.len != dim * @sizeOf(f32)) return error.BadVectorBytes;
    // Copy (the source may be unaligned page bytes) then bit-cast lanes.
    var i: usize = 0;
    while (i < dim) : (i += 1) {
        var lane: [4]u8 = undefined;
        @memcpy(&lane, bytes[i * 4 .. i * 4 + 4]);
        out[i] = @bitCast(std.mem.readInt(u32, &lane, .little));
    }
}

// ------------------------------------------------------- vector math

/// In-place L2 normalization. A zero vector is left as-is (all zeros).
pub fn normalize(vec: *Vector) void {
    var sum: f64 = 0;
    for (vec) |v| sum += @as(f64, v) * @as(f64, v);
    if (sum == 0) return;
    const inv: f32 = @floatCast(1.0 / @sqrt(sum));
    for (vec) |*v| v.* *= inv;
}

/// Dot product of two vectors. For L2-normalized vectors this equals the
/// cosine similarity in [-1, 1].
pub fn dot(a: *const Vector, b: *const Vector) f32 {
    var sum: f64 = 0;
    for (a, b) |x, y| sum += @as(f64, x) * @as(f64, y);
    return @floatCast(sum);
}

/// Cosine similarity of two (not necessarily normalized) vectors.
pub fn cosine(a: *const Vector, b: *const Vector) f32 {
    var na: f64 = 0;
    var nb: f64 = 0;
    var d: f64 = 0;
    for (a, b) |x, y| {
        na += @as(f64, x) * @as(f64, x);
        nb += @as(f64, y) * @as(f64, y);
        d += @as(f64, x) * @as(f64, y);
    }
    if (na == 0 or nb == 0) return 0;
    return @floatCast(d / (@sqrt(na) * @sqrt(nb)));
}

// ------------------------------------------------------- tokenization

/// Whether a byte is part of a token (letters, digits). Everything else
/// (whitespace, punctuation) is a separator. We also split on case
/// boundaries and underscores below so identifiers like `getUserName` and
/// `last_indexed_oid` contribute their sub-words.
fn isTokenByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c);
}

/// Iterates lowercased sub-word tokens out of arbitrary text/code. Splits
/// on non-alphanumerics, on lower→upper camelCase boundaries, and emits a
/// lowercased copy into the caller-provided scratch buffer.
pub const Tokenizer = struct {
    text: []const u8,
    at: usize = 0,

    pub fn init(text: []const u8) Tokenizer {
        return .{ .text = text };
    }

    /// Write the next token (lowercased) into `buf`, returning the used
    /// slice, or null at end. Tokens longer than `buf` are truncated.
    pub fn next(self: *Tokenizer, buf: []u8) ?[]const u8 {
        // Skip separators.
        while (self.at < self.text.len and !isTokenByte(self.text[self.at])) : (self.at += 1) {}
        if (self.at >= self.text.len) return null;

        const start = self.at;
        var end = self.at;
        // Consume a run, breaking at a lower→upper camelCase boundary so
        // `getUser` yields `get` then `user`.
        while (end < self.text.len and isTokenByte(self.text[end])) : (end += 1) {
            if (end > start and
                std.ascii.isLower(self.text[end - 1]) and
                std.ascii.isUpper(self.text[end]))
            {
                break;
            }
        }
        self.at = end;
        const raw = self.text[start..end];
        const n = @min(raw.len, buf.len);
        for (raw[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
        return buf[0..n];
    }
};

// ------------------------------------------------------- hashing embedder

const max_token_bytes = 64;

fn hashToken(token: []const u8, salt: u64) u64 {
    var h = std.hash.Wyhash.init(salt);
    h.update(token);
    return h.final();
}

/// Embed `text` into `out` using the deterministic hashing embedder:
/// each token is hashed to a bucket in [0, dim) and a sign bit, then
/// accumulated; the result is L2-normalized. Empty/whitespace text yields
/// the zero vector.
pub fn embed(text: []const u8, out: *Vector) void {
    @memset(out, 0);
    var tok = Tokenizer.init(text);
    var buf: [max_token_bytes]u8 = undefined;
    var count: usize = 0;
    while (tok.next(&buf)) |token| {
        if (token.len == 0) continue;
        count += 1;
        const h = hashToken(token, 0x9E3779B97F4A7C15);
        const bucket = h % dim;
        // Low bit of a second hash gives a stable ±1 sign, so unrelated
        // tokens can cancel instead of only ever adding.
        const sign_bit = hashToken(token, 0xD1B54A32D192ED03) & 1;
        const sign: f32 = if (sign_bit == 0) 1.0 else -1.0;
        out[bucket] += sign;
    }
    if (count == 0) return;
    normalize(out);
}

/// Convenience: embed and return the vector by value.
pub fn embedValue(text: []const u8) Vector {
    var v: Vector = undefined;
    embed(text, &v);
    return v;
}

// --------------------------------------------- source-text extraction

/// Source kinds we embed. Matches the `embeddings.source_kind` domain and
/// the `memory_fts.ref_kind` values.
pub const SourceKind = enum {
    event,
    file_snapshot,
    message,
    snippet,

    pub fn name(self: SourceKind) []const u8 {
        return switch (self) {
            .event => "event",
            .file_snapshot => "file_snapshot",
            .message => "message",
            .snippet => "snippet",
        };
    }
};

/// Build the text to embed for a git commit event, into `buf`. Combines
/// subject + body (+ a little author context). Returns the used slice.
pub fn eventText(buf: []u8, subject: []const u8, body: []const u8) []const u8 {
    return join2(buf, subject, body);
}

/// Build the text to embed for a file snapshot: the relative path (so path
/// terms are searchable) plus the file content. Content dominates; the path
/// is cheap context.
pub fn fileSnapshotText(buf: []u8, rel_path: []const u8, content: []const u8) []const u8 {
    return join2(buf, rel_path, content);
}

/// Join two strings with a space into `buf` (truncating to fit).
fn join2(buf: []u8, a: []const u8, b: []const u8) []const u8 {
    var n: usize = 0;
    n += copyInto(buf[n..], a);
    if (n < buf.len and a.len > 0 and b.len > 0) {
        buf[n] = ' ';
        n += 1;
    }
    n += copyInto(buf[n..], b);
    return buf[0..n];
}

fn copyInto(dst: []u8, src: []const u8) usize {
    const n = @min(dst.len, src.len);
    @memcpy(dst[0..n], src[0..n]);
    return n;
}

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
/// `?1` = model id.
pub const select_vectors_sql =
    "SELECT source_kind, source_id, vector FROM embeddings WHERE model = ?1;";

// ------------------------------------------------------- ranking

/// One scored candidate produced by ranking.
pub const Hit = struct {
    kind: SourceKind,
    source_id: i64,
    score: f32,
};

/// Insert `candidate` into a fixed-size top-k `hits` buffer kept sorted by
/// descending score. `count` is how many slots are currently filled (<= k);
/// returns the new count. Lets the caller rank a stream of stored vectors
/// with no allocation.
pub fn considerTopK(hits: []Hit, count: usize, candidate: Hit) usize {
    const k = hits.len;
    if (k == 0) return 0;

    if (count < k) {
        // Not full yet: append, then bubble up into sorted position.
        hits[count] = candidate;
        bubbleUp(hits, count);
        return count + 1;
    }
    // Full: only keep the candidate if it beats the current minimum (last).
    if (candidate.score <= hits[k - 1].score) return k;
    hits[k - 1] = candidate;
    bubbleUp(hits, k - 1);
    return k;
}

/// Move hits[i] toward the front while it outscores its predecessor.
fn bubbleUp(hits: []Hit, start: usize) void {
    var i = start;
    while (i > 0 and hits[i].score > hits[i - 1].score) : (i -= 1) {
        const tmp = hits[i - 1];
        hits[i - 1] = hits[i];
        hits[i] = tmp;
    }
}

pub fn kindFromName(s: []const u8) ?SourceKind {
    if (std.mem.eql(u8, s, "event")) return .event;
    if (std.mem.eql(u8, s, "file_snapshot")) return .file_snapshot;
    if (std.mem.eql(u8, s, "message")) return .message;
    if (std.mem.eql(u8, s, "snippet")) return .snippet;
    return null;
}

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

const testing = std.testing;

test "vector <-> blob round-trips exactly" {
    var v: Vector = undefined;
    for (&v, 0..) |*x, i| x.* = @as(f32, @floatFromInt(i)) * 0.5 - 3.0;
    const bytes = vectorBytes(&v);
    try testing.expectEqual(dim * @sizeOf(f32), bytes.len);
    var back: Vector = undefined;
    try vectorFromBytes(bytes, &back);
    try testing.expectEqualSlices(f32, v[0..], back[0..]);
}

test "vectorFromBytes rejects a wrong-sized blob" {
    var out: Vector = undefined;
    try testing.expectError(error.BadVectorBytes, vectorFromBytes("short", &out));
}

test "normalize yields unit length (or leaves zero alone)" {
    var v: Vector = @splat(0);
    v[0] = 3;
    v[1] = 4;
    normalize(&v);
    // 3-4-5 triangle -> 0.6, 0.8.
    try testing.expectApproxEqAbs(@as(f32, 0.6), v[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.8), v[1], 1e-6);

    var z: Vector = @splat(0);
    normalize(&z);
    for (z) |x| try testing.expectEqual(@as(f32, 0), x);
}

test "embed is deterministic and normalized" {
    const a = embedValue("nginx deployment configuration");
    const b = embedValue("nginx deployment configuration");
    try testing.expectEqualSlices(f32, a[0..], b[0..]);
    // Unit length.
    var mag: f64 = 0;
    for (a) |x| mag += @as(f64, x) * @as(f64, x);
    try testing.expectApproxEqAbs(@as(f64, 1.0), mag, 1e-4);
}

test "embed empty text is the zero vector" {
    const v = embedValue("   \n\t  ");
    for (v) |x| try testing.expectEqual(@as(f32, 0), x);
}

test "similar texts score higher than unrelated ones" {
    const q = embedValue("fix nginx config for the deployment");
    const related = embedValue("nginx deployment configuration change");
    const unrelated = embedValue("banana smoothie recipe with mango");
    const s_rel = cosine(&q, &related);
    const s_unrel = cosine(&q, &unrelated);
    try testing.expect(s_rel > s_unrel);
}

test "tokenizer splits camelCase, underscores, and punctuation" {
    var tok = Tokenizer.init("getUserName last_indexed_oid, HELLO.world");
    var buf: [max_token_bytes]u8 = undefined;
    const expected = [_][]const u8{ "get", "user", "name", "last", "indexed", "oid", "hello", "world" };
    for (expected) |want| {
        const got = tok.next(&buf) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings(want, got);
    }
    try testing.expect(tok.next(&buf) == null);
}

test "eventText / fileSnapshotText join their parts" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("subject body", eventText(&buf, "subject", "body"));
    try testing.expectEqualStrings("subject", eventText(&buf, "subject", ""));
    try testing.expectEqualStrings("src/a.zig const x = 1;", fileSnapshotText(&buf, "src/a.zig", "const x = 1;"));
}

test "considerTopK keeps the highest scores in descending order" {
    var hits: [3]Hit = undefined;
    var n: usize = 0;
    const scores = [_]f32{ 0.1, 0.9, 0.5, 0.95, 0.2, 0.7 };
    for (scores, 0..) |s, i| {
        n = considerTopK(&hits, n, .{ .kind = .event, .source_id = @intCast(i), .score = s });
    }
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectApproxEqAbs(@as(f32, 0.95), hits[0].score, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.9), hits[1].score, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.7), hits[2].score, 1e-6);
}

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
