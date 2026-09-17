//! Embedding math + the deterministic hashing embedder — PURE, std-only
//! (extracted from embeddings.zig in Task 8).
//!
//! This half has NO dependency on the SDK or the DB layer, so it can be
//! compiled into the standalone MCP server binary (which links libsqlite3
//! directly and never sees `native_sdk`). `embeddings.zig` re-exports
//! everything here and adds the DB-coupled statement builders + page
//! ranking on top. Keeping the embedder in one place means the app runtime
//! and the sidecar produce byte-identical vectors for the same text — the
//! index is never re-embedded across the process boundary.

const std = @import("std");

/// Fixed embedding dimension for the v1 hashing embedder. Small so a
/// vector is 1 KiB (256 × f32) — cheap to store and score in-process.
pub const dim: usize = 256;

/// Identifier stored in `embeddings.model`.
pub const model_id = "hash-v1";

/// Load all stored vectors for a model, for in-process cosine ranking.
/// `?1` = model id. (A plain SQL string, shared by the app runtime and the
/// standalone MCP server so both rank against the same query.)
pub const select_vectors_sql =
    "SELECT source_kind, source_id, vector FROM embeddings WHERE model = ?1;";

/// A dim-length embedding vector.
pub const Vector = [dim]f32;

// ------------------------------------------------------- vector <-> blob

/// Reinterpret a vector as its raw little-endian byte blob for storage.
pub fn vectorBytes(vec: *const Vector) []const u8 {
    return std.mem.sliceAsBytes(vec[0..]);
}

pub const DecodeError = error{BadVectorBytes};

/// Decode a stored BLOB back into a vector. Must be exactly `dim*4` bytes.
pub fn vectorFromBytes(bytes: []const u8, out: *Vector) DecodeError!void {
    if (bytes.len != dim * @sizeOf(f32)) return error.BadVectorBytes;
    var i: usize = 0;
    while (i < dim) : (i += 1) {
        var lane: [4]u8 = undefined;
        @memcpy(&lane, bytes[i * 4 .. i * 4 + 4]);
        out[i] = @bitCast(std.mem.readInt(u32, &lane, .little));
    }
}

// ------------------------------------------------------- vector math

/// In-place L2 normalization. A zero vector is left as-is.
pub fn normalize(vec: *Vector) void {
    var sum: f64 = 0;
    for (vec) |v| sum += @as(f64, v) * @as(f64, v);
    if (sum == 0) return;
    const inv: f32 = @floatCast(1.0 / @sqrt(sum));
    for (vec) |*v| v.* *= inv;
}

/// Dot product. For L2-normalized vectors this equals cosine in [-1, 1].
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

fn isTokenByte(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch);
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

    pub fn next(self: *Tokenizer, buf: []u8) ?[]const u8 {
        while (self.at < self.text.len and !isTokenByte(self.text[self.at])) : (self.at += 1) {}
        if (self.at >= self.text.len) return null;

        const start = self.at;
        var end = self.at;
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
        for (raw[0..n], 0..) |ch, i| buf[i] = std.ascii.toLower(ch);
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

/// Embed `text` into `out` using the deterministic hashing embedder.
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

/// Source kinds we embed. Matches `embeddings.source_kind` / `memory_fts.ref_kind`.
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

pub fn kindFromName(s: []const u8) ?SourceKind {
    if (std.mem.eql(u8, s, "event")) return .event;
    if (std.mem.eql(u8, s, "file_snapshot")) return .file_snapshot;
    if (std.mem.eql(u8, s, "message")) return .message;
    if (std.mem.eql(u8, s, "snippet")) return .snippet;
    return null;
}

/// Build the text to embed for a git commit event (subject + body).
pub fn eventText(buf: []u8, subject: []const u8, body: []const u8) []const u8 {
    return join2(buf, subject, body);
}

/// Build the text to embed for a file snapshot (rel_path + content).
pub fn fileSnapshotText(buf: []u8, rel_path: []const u8, content: []const u8) []const u8 {
    return join2(buf, rel_path, content);
}

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

// ------------------------------------------------------- ranking

/// One scored candidate produced by ranking.
pub const Hit = struct {
    kind: SourceKind,
    source_id: i64,
    score: f32,
};

/// Insert `candidate` into a fixed-size top-k `hits` buffer kept sorted by
/// descending score. `count` = filled slots (<= k); returns the new count.
pub fn considerTopK(hits: []Hit, count: usize, candidate: Hit) usize {
    const k = hits.len;
    if (k == 0) return 0;
    if (count < k) {
        hits[count] = candidate;
        bubbleUp(hits, count);
        return count + 1;
    }
    if (candidate.score <= hits[k - 1].score) return k;
    hits[k - 1] = candidate;
    bubbleUp(hits, k - 1);
    return k;
}

fn bubbleUp(hits: []Hit, start: usize) void {
    var i = start;
    while (i > 0 and hits[i].score > hits[i - 1].score) : (i -= 1) {
        const tmp = hits[i - 1];
        hits[i - 1] = hits[i];
        hits[i] = tmp;
    }
}

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

test "embed is deterministic and normalized" {
    const a = embedValue("nginx deployment configuration");
    const b = embedValue("nginx deployment configuration");
    try testing.expectEqualSlices(f32, a[0..], b[0..]);
    var mag: f64 = 0;
    for (a) |x| mag += @as(f64, x) * @as(f64, x);
    try testing.expectApproxEqAbs(@as(f64, 1.0), mag, 1e-4);
}

test "similar texts score higher than unrelated ones" {
    const q = embedValue("fix nginx config for the deployment");
    const related = embedValue("nginx deployment configuration change");
    const unrelated = embedValue("banana smoothie recipe with mango");
    try testing.expect(cosine(&q, &related) > cosine(&q, &unrelated));
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

test "considerTopK keeps the highest scores in descending order" {
    var hits: [3]Hit = undefined;
    var n: usize = 0;
    const scores = [_]f32{ 0.1, 0.9, 0.5, 0.95, 0.2, 0.7 };
    for (scores, 0..) |s, i| {
        n = considerTopK(&hits, n, .{ .kind = .event, .source_id = @intCast(i), .score = s });
    }
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectApproxEqAbs(@as(f32, 0.95), hits[0].score, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.7), hits[2].score, 1e-6);
}

test "kindFromName round-trips the source kinds" {
    try testing.expectEqual(SourceKind.event, kindFromName("event").?);
    try testing.expectEqual(SourceKind.file_snapshot, kindFromName("file_snapshot").?);
    try testing.expect(kindFromName("bogus") == null);
}
