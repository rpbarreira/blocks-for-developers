//! MCP memory tools — PURE query builders + JSON shapers (Task 8).
//!
//! No SDK, no I/O. Each tool is two halves:
//!   1. `parseArgs*` — turn the tool's JSON `arguments` into a validated,
//!      bounded query spec (clamped limits, optional filters).
//!   2. A SQL string (+ a note on its bind params) the caller runs, and a
//!      `write*Row` / `begin*/end*` set that shapes the returned rows into
//!      the JSON text the tool returns (as MCP text content).
//!
//! `search_memory` additionally ranks vector hits; that ranking lives in
//! `embeddings.zig` (pure) and is invoked by the server's tools adapter,
//! which then calls the shapers here. Keeping SQL + JSON shaping here (and
//! the actual DB/effect calls in the server) means this file is unit-
//! tested by `native test` with zero I/O, exactly like `git.zig` /
//! `snapshots.zig` / `embeddings.zig`.

const std = @import("std");
const proto = @import("protocol.zig");

const JsonWriter = proto.JsonWriter;

// --------------------------------------------------------- arg parsing

/// Pull an optional integer field out of a tool's `arguments` JSON object.
/// Missing / wrong-typed => null. Accepts JSON integers and integral floats.
fn optInt(obj: std.json.ObjectMap, name: []const u8) ?i64 {
    const v = obj.get(name) orelse return null;
    return switch (v) {
        .integer => |n| n,
        .float => |f| @intFromFloat(f),
        else => null,
    };
}

fn optString(obj: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const v = obj.get(name) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

/// The `arguments` object is nested under `params.arguments` for a
/// `tools/call`. Parse the full params and return just the arguments map
/// (or an empty object). The returned map borrows from `parsed`, which the
/// caller must keep alive (arena-backed).
pub fn parseCallArguments(parsed: *std.json.Parsed(std.json.Value)) ArgsError! Args {
    if (parsed.value != .object) return error.BadParams;
    const params = parsed.value.object;
    const name_v = params.get("name") orelse return error.MissingToolName;
    if (name_v != .string) return error.MissingToolName;
    const args: std.json.ObjectMap = if (params.get("arguments")) |a|
        (if (a == .object) a.object else return error.BadArguments)
    else
        .{}; // empty StringArrayHashMap (managed); no allocation needed
    return .{ .name = name_v.string, .arguments = args };
}

pub const ArgsError = error{ BadParams, MissingToolName, BadArguments };

pub const Args = struct {
    name: []const u8,
    arguments: std.json.ObjectMap,
};

// ------------------------------------------------------- get_commits

pub const CommitsQuery = struct {
    repo_id: ?i64 = null,
    limit: i64 = 20,
};

pub fn parseCommitsArgs(obj: std.json.ObjectMap) CommitsQuery {
    var q = CommitsQuery{};
    q.repo_id = optInt(obj, "repo_id");
    if (optInt(obj, "limit")) |l| q.limit = std.math.clamp(l, 1, 100);
    return q;
}

/// Most-recent-first commits with a repo name, optionally one repo. Bind
/// params depend on whether a repo filter is present:
///   filtered:   ?1 = repo_id, ?2 = limit
///   unfiltered: ?1 = limit
pub const commits_sql_all =
    "SELECT e.id, e.repo_id, r.name, e.commit_oid, e.author_name, e.subject, " ++
    "e.occurred_at, e.files_changed, e.insertions, e.deletions " ++
    "FROM events e JOIN repos r ON r.id = e.repo_id " ++
    "WHERE e.kind = 'commit' ORDER BY e.occurred_at DESC LIMIT ?1;";

pub const commits_sql_by_repo =
    "SELECT e.id, e.repo_id, r.name, e.commit_oid, e.author_name, e.subject, " ++
    "e.occurred_at, e.files_changed, e.insertions, e.deletions " ++
    "FROM events e JOIN repos r ON r.id = e.repo_id " ++
    "WHERE e.kind = 'commit' AND e.repo_id = ?1 ORDER BY e.occurred_at DESC LIMIT ?2;";

pub fn commitsSql(q: CommitsQuery) []const u8 {
    return if (q.repo_id != null) commits_sql_by_repo else commits_sql_all;
}

/// A decoded commit row for JSON shaping (values copied/borrowed by caller).
pub const CommitRow = struct {
    id: i64,
    repo_id: i64,
    repo_name: []const u8,
    oid: []const u8,
    author: []const u8,
    subject: []const u8,
    occurred_at: i64,
    files_changed: i64,
    insertions: i64,
    deletions: i64,
};

pub fn beginCommits(w: *JsonWriter) !void {
    try w.raw("{\"commits\":[");
}

pub fn writeCommitRow(w: *JsonWriter, first: bool, c: CommitRow) !void {
    if (!first) try w.raw(",");
    try w.raw("{");
    try w.key("id");
    try w.number(c.id);
    try w.raw(",");
    try w.key("repo_id");
    try w.number(c.repo_id);
    try w.raw(",");
    try w.key("repo");
    try w.string(c.repo_name);
    try w.raw(",");
    try w.key("oid");
    try w.string(c.oid);
    try w.raw(",");
    try w.key("author");
    try w.string(c.author);
    try w.raw(",");
    try w.key("subject");
    try w.string(c.subject);
    try w.raw(",");
    try w.key("occurred_at");
    try w.number(c.occurred_at);
    try w.raw(",");
    try w.key("files_changed");
    try w.number(c.files_changed);
    try w.raw(",");
    try w.key("insertions");
    try w.number(c.insertions);
    try w.raw(",");
    try w.key("deletions");
    try w.number(c.deletions);
    try w.raw("}");
}

pub fn endList(w: *JsonWriter) !void {
    try w.raw("]}");
}

// ------------------------------------------------------- get_activity

pub const ActivityQuery = struct {
    since_ms: ?i64 = null,
    until_ms: ?i64 = null,
    limit: i64 = 20,
};

pub fn parseActivityArgs(obj: std.json.ObjectMap) ActivityQuery {
    var q = ActivityQuery{};
    q.since_ms = optInt(obj, "since_ms");
    q.until_ms = optInt(obj, "until_ms");
    if (optInt(obj, "limit")) |l| q.limit = std.math.clamp(l, 1, 100);
    return q;
}

/// Unified recent activity across commits and file snapshots, newest
/// first. A UNION of the two tables normalized to a common shape:
///   kind, ref_id, repo_id, repo_name, title, occurred_at
/// The optional time window and limit bind as trailing params. To keep the
/// bind layout stable we always bind since/until using sentinels when a
/// bound is absent (min/max i64), so the SQL is single-shape.
///   ?1 = since_ms, ?2 = until_ms, ?3 = limit
pub const activity_sql =
    "SELECT * FROM (" ++
    "  SELECT 'commit' AS kind, e.id AS ref_id, e.repo_id AS repo_id, r.name AS repo_name, " ++
    "         e.subject AS title, e.occurred_at AS occurred_at " ++
    "  FROM events e JOIN repos r ON r.id = e.repo_id WHERE e.kind = 'commit' " ++
    "  UNION ALL " ++
    "  SELECT 'file_snapshot' AS kind, f.id AS ref_id, f.repo_id AS repo_id, r.name AS repo_name, " ++
    "         f.rel_path AS title, f.captured_at AS occurred_at " ++
    "  FROM file_snapshots f JOIN repos r ON r.id = f.repo_id" ++
    ") WHERE occurred_at >= ?1 AND occurred_at <= ?2 " ++
    "ORDER BY occurred_at DESC LIMIT ?3;";

/// The effective since/until bounds, substituting i64 min/max sentinels
/// for absent bounds so the single-shape SQL always has three binds.
pub fn activityBounds(q: ActivityQuery) struct { since: i64, until: i64, limit: i64 } {
    return .{
        .since = q.since_ms orelse std.math.minInt(i64),
        .until = q.until_ms orelse std.math.maxInt(i64),
        .limit = q.limit,
    };
}

pub const ActivityRow = struct {
    kind: []const u8,
    ref_id: i64,
    repo_id: i64,
    repo_name: []const u8,
    title: []const u8,
    occurred_at: i64,
};

pub fn beginActivity(w: *JsonWriter) !void {
    try w.raw("{\"activity\":[");
}

pub fn writeActivityRow(w: *JsonWriter, first: bool, a: ActivityRow) !void {
    if (!first) try w.raw(",");
    try w.raw("{");
    try w.key("kind");
    try w.string(a.kind);
    try w.raw(",");
    try w.key("ref_id");
    try w.number(a.ref_id);
    try w.raw(",");
    try w.key("repo_id");
    try w.number(a.repo_id);
    try w.raw(",");
    try w.key("repo");
    try w.string(a.repo_name);
    try w.raw(",");
    try w.key("title");
    try w.string(a.title);
    try w.raw(",");
    try w.key("occurred_at");
    try w.number(a.occurred_at);
    try w.raw("}");
}

// ------------------------------------------------------- search_memory

pub const SearchQuery = struct {
    query: []const u8,
    limit: i64 = 10,
};

pub const SearchArgsError = error{MissingQuery};

pub fn parseSearchArgs(obj: std.json.ObjectMap) SearchArgsError!SearchQuery {
    var q = SearchQuery{ .query = optString(obj, "query") orelse return error.MissingQuery };
    if (q.query.len == 0) return error.MissingQuery;
    if (optInt(obj, "limit")) |l| q.limit = std.math.clamp(l, 1, 50);
    return q;
}

/// After the server has resolved a ranked set of (kind, source_id) hits
/// (via `embeddings.rankPage` + the FTS arm) and fetched each hit's
/// display fields, it shapes them here. One hit maps to the origin's
/// searchable text plus locators.
pub const SearchHit = struct {
    kind: []const u8, // "event" | "file_snapshot"
    source_id: i64,
    repo_id: i64,
    repo_name: []const u8,
    title: []const u8, // commit subject or file rel_path
    snippet: []const u8, // body / content excerpt
    occurred_at: i64,
    score: f32,
};

pub fn beginSearch(w: *JsonWriter, query: []const u8) !void {
    try w.raw("{");
    try w.key("query");
    try w.string(query);
    try w.raw(",\"results\":[");
}

pub fn writeSearchHit(w: *JsonWriter, first: bool, h: SearchHit) !void {
    if (!first) try w.raw(",");
    try w.raw("{");
    try w.key("kind");
    try w.string(h.kind);
    try w.raw(",");
    try w.key("source_id");
    try w.number(h.source_id);
    try w.raw(",");
    try w.key("repo_id");
    try w.number(h.repo_id);
    try w.raw(",");
    try w.key("repo");
    try w.string(h.repo_name);
    try w.raw(",");
    try w.key("title");
    try w.string(h.title);
    try w.raw(",");
    try w.key("snippet");
    try w.string(h.snippet);
    try w.raw(",");
    try w.key("occurred_at");
    try w.number(h.occurred_at);
    try w.raw(",");
    try w.key("score");
    // Score with 4 decimals (JSON number).
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d:.4}", .{h.score}) catch "0";
    try w.raw(s);
    try w.raw("}");
}

/// Fetch a single event's display fields for a search hit.
///   ?1 = event id
pub const search_event_row_sql =
    "SELECT e.repo_id, r.name, e.subject, e.body, e.occurred_at " ++
    "FROM events e JOIN repos r ON r.id = e.repo_id WHERE e.id = ?1;";

/// Fetch a single file snapshot's display fields for a search hit.
///   ?1 = file_snapshot id
pub const search_snapshot_row_sql =
    "SELECT f.repo_id, r.name, f.rel_path, f.content, f.captured_at " ++
    "FROM file_snapshots f JOIN repos r ON r.id = f.repo_id WHERE f.id = ?1;";

/// Truncate a text field to at most `max` bytes on a UTF-8-safe-ish
/// boundary (we cut on the last byte < 0x80 or a space) for the snippet.
pub fn excerpt(text: []const u8, max: usize) []const u8 {
    if (text.len <= max) return text;
    var end = max;
    // Back off to a space if one is near, for a cleaner cut.
    var i = max;
    while (i > 0 and max - i < 32) : (i -= 1) {
        if (text[i - 1] == ' ' or text[i - 1] == '\n') {
            end = i - 1;
            break;
        }
    }
    // Avoid slicing mid multi-byte codepoint: back up over continuation bytes.
    while (end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
    return text[0..end];
}

// --------------------------------------------------------------- tests

const testing = std.testing;

fn objFrom(arena: std.mem.Allocator, json: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, arena, json, .{});
}

test "parseCommitsArgs clamps limit and reads repo_id" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = try objFrom(arena.allocator(), "{\"repo_id\":3,\"limit\":9999}");
    defer p.deinit();
    const q = parseCommitsArgs(p.value.object);
    try testing.expectEqual(@as(i64, 3), q.repo_id.?);
    try testing.expectEqual(@as(i64, 100), q.limit); // clamped
    try testing.expectEqualStrings(commits_sql_by_repo, commitsSql(q));

    var p2 = try objFrom(arena.allocator(), "{}");
    defer p2.deinit();
    const q2 = parseCommitsArgs(p2.value.object);
    try testing.expect(q2.repo_id == null);
    try testing.expectEqual(@as(i64, 20), q2.limit); // default
    try testing.expectEqualStrings(commits_sql_all, commitsSql(q2));
}

test "parseActivityArgs substitutes sentinels for absent bounds" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = try objFrom(arena.allocator(), "{\"since_ms\":1000}");
    defer p.deinit();
    const q = parseActivityArgs(p.value.object);
    const b = activityBounds(q);
    try testing.expectEqual(@as(i64, 1000), b.since);
    try testing.expectEqual(std.math.maxInt(i64), b.until);
    try testing.expectEqual(@as(i64, 20), b.limit);
}

test "parseSearchArgs requires a non-empty query and clamps limit" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = try objFrom(arena.allocator(), "{\"query\":\"nginx\",\"limit\":80}");
    defer p.deinit();
    const q = try parseSearchArgs(p.value.object);
    try testing.expectEqualStrings("nginx", q.query);
    try testing.expectEqual(@as(i64, 50), q.limit);

    var p2 = try objFrom(arena.allocator(), "{}");
    defer p2.deinit();
    try testing.expectError(error.MissingQuery, parseSearchArgs(p2.value.object));

    var p3 = try objFrom(arena.allocator(), "{\"query\":\"\"}");
    defer p3.deinit();
    try testing.expectError(error.MissingQuery, parseSearchArgs(p3.value.object));
}

test "parseCallArguments pulls tool name and arguments map" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = try objFrom(arena.allocator(),
        \\{"name":"get_commits","arguments":{"limit":5}}
    );
    defer p.deinit();
    const a = try parseCallArguments(&p);
    try testing.expectEqualStrings("get_commits", a.name);
    try testing.expectEqual(@as(i64, 5), optInt(a.arguments, "limit").?);
}

test "parseCallArguments tolerates a missing arguments object" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p = try objFrom(arena.allocator(),
        \\{"name":"get_activity"}
    );
    defer p.deinit();
    const a = try parseCallArguments(&p);
    try testing.expectEqualStrings("get_activity", a.name);
    try testing.expectEqual(@as(usize, 0), a.arguments.count());
}

test "writeCommitRow + list framing produces valid JSON" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    var w = JsonWriter.init(&out, testing.allocator);
    try beginCommits(&w);
    try writeCommitRow(&w, true, .{
        .id = 1, .repo_id = 2, .repo_name = "blocks", .oid = "abc123",
        .author = "Rui", .subject = "Add tray", .occurred_at = 1000,
        .files_changed = 3, .insertions = 40, .deletions = 5,
    });
    try writeCommitRow(&w, false, .{
        .id = 2, .repo_id = 2, .repo_name = "blocks", .oid = "def456",
        .author = "Rui", .subject = "Fix \"quote\"", .occurred_at = 2000,
        .files_changed = 1, .insertions = 2, .deletions = 0,
    });
    try endList(&w);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), out.items, .{});
    defer parsed.deinit();
    const commits = parsed.value.object.get("commits").?.array;
    try testing.expectEqual(@as(usize, 2), commits.items.len);
    try testing.expectEqualStrings("Fix \"quote\"", commits.items[1].object.get("subject").?.string);
}

test "writeActivityRow framing produces valid JSON" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    var w = JsonWriter.init(&out, testing.allocator);
    try beginActivity(&w);
    try writeActivityRow(&w, true, .{ .kind = "commit", .ref_id = 1, .repo_id = 1, .repo_name = "r", .title = "t", .occurred_at = 5 });
    try endList(&w);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), out.items, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.value.object.get("activity").?.array.items.len);
}

test "writeSearchHit framing produces valid JSON with a score" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    var w = JsonWriter.init(&out, testing.allocator);
    try beginSearch(&w, "nginx config");
    try writeSearchHit(&w, true, .{
        .kind = "event", .source_id = 10, .repo_id = 1, .repo_name = "ops",
        .title = "add nginx config", .snippet = "reverse proxy for staging",
        .occurred_at = 123, .score = 0.8765,
    });
    try endList(&w);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), out.items, .{});
    defer parsed.deinit();
    const results = parsed.value.object.get("results").?.array;
    try testing.expectEqual(@as(usize, 1), results.items.len);
    try testing.expectEqualStrings("event", results.items[0].object.get("kind").?.string);
}

test "excerpt truncates long text and passes short text through" {
    try testing.expectEqualStrings("short", excerpt("short", 100));
    const long = "aaaaaaaaaa bbbbbbbbbb cccccccccc dddddddddd";
    const cut = excerpt(long, 25);
    try testing.expect(cut.len <= 25);
}
