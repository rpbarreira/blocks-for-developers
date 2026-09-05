//! Watched-repositories data layer: typed statement builders and row
//! decoding over the `repos` table, plus helpers for validating and
//! naming a repository path.
//!
//! Statement builders return `db.Statement` / SQL + params that the app
//! runs through `fx.dbExec` / `fx.dbQuery`. Row decoding turns a
//! PageReader row into a typed `Repo`. Path helpers (git validation,
//! default name) are pure and unit-tested.

const std = @import("std");
const db = @import("db.zig");

pub const Repo = struct {
    id: i64,
    path: []const u8,
    name: []const u8,
    active: bool,
    added_at: i64,

    /// Decode one row of `SELECT id, path, name, active, added_at`.
    /// Slices borrow from the page bytes; copy what outlives the result.
    pub fn fromRow(cols: []const db.ColumnValue) ?Repo {
        if (cols.len < 5) return null;
        return .{
            .id = cols[0].asInt() orelse return null,
            .path = cols[1].asText() orelse return null,
            .name = cols[2].asText() orelse return null,
            .active = (cols[3].asInt() orelse 0) != 0,
            .added_at = cols[4].asInt() orelse return null,
        };
    }
};

/// Model-owned copy of a repo row with inline string storage, so the
/// loaded list survives across updates without an allocator (the DB page
/// bytes a query returns are only valid during the receiving update).
pub const max_path_bytes = 1024;
pub const max_name_bytes = 256;

pub const RepoEntry = struct {
    id: i64 = 0,
    active: bool = true,
    path_buf: [max_path_bytes]u8 = undefined,
    path_len: usize = 0,
    name_buf: [max_name_bytes]u8 = undefined,
    name_len: usize = 0,

    pub fn path(self: *const RepoEntry) []const u8 {
        return self.path_buf[0..self.path_len];
    }
    pub fn name(self: *const RepoEntry) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    /// Copy a decoded `Repo` (borrowed slices) into owned inline storage.
    pub fn fromRepo(r: Repo) RepoEntry {
        var e = RepoEntry{ .id = r.id, .active = r.active };
        e.path_len = @min(r.path.len, max_path_bytes);
        @memcpy(e.path_buf[0..e.path_len], r.path[0..e.path_len]);
        e.name_len = @min(r.name.len, max_name_bytes);
        @memcpy(e.name_buf[0..e.name_len], r.name[0..e.name_len]);
        return e;
    }
};

/// Fixed-capacity list of loaded repos held in the Model.
pub const max_repos = 128;

pub const select_columns = "id, path, name, active, added_at";
pub const list_sql = "SELECT " ++ select_columns ++ " FROM repos ORDER BY added_at DESC;";
pub const exists_sql = "SELECT id FROM repos WHERE path = ?1;";

pub const insert_sql = "INSERT INTO repos(path, name, active, added_at) VALUES(?1, ?2, 1, ?3);";
pub const delete_sql = "DELETE FROM repos WHERE id = ?1;";

/// Fill a caller-owned 3-element buffer with the insert params and return
/// a statement referencing it. The buffer MUST outlive the dbExec call
/// (params are copied into slot storage at call time). Returning `&.{...}`
/// of runtime values would dangle, so params live in the caller's frame.
pub fn insertStatement(buf: *[3]db.Value, path: []const u8, name: []const u8, now_ms: i64) db.Statement {
    buf.* = .{ db.val.text(path), db.val.text(name), db.val.int(now_ms) };
    return .{ .sql = insert_sql, .params = buf };
}

/// Fill a caller-owned 1-element buffer with the delete param.
pub fn deleteStatement(buf: *[1]db.Value, id: i64) db.Statement {
    buf.* = .{db.val.int(id)};
    return .{ .sql = delete_sql, .params = buf };
}

// ------------------------------------------------------- path helpers

/// Normalize a user-entered path: trim surrounding whitespace and any
/// trailing slash (except root "/"). Returns a slice of the input.
pub fn normalizePath(raw: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = raw.len;
    while (start < end and std.ascii.isWhitespace(raw[start])) start += 1;
    while (end > start and std.ascii.isWhitespace(raw[end - 1])) end -= 1;
    // Strip a trailing slash unless the whole path is just "/".
    while (end - start > 1 and raw[end - 1] == '/') end -= 1;
    return raw[start..end];
}

/// The default display name for a repo path: its trailing component.
pub fn defaultName(path: []const u8) []const u8 {
    const p = normalizePath(path);
    if (p.len == 0) return p;
    var start = p.len;
    while (start > 0 and p[start - 1] != '/') start -= 1;
    return p[start..];
}

/// The path to a repo's `.git` marker, used to validate that a folder is
/// a git repository via `statFile`. Allocated from `allocator`.
pub fn gitMarkerPath(allocator: std.mem.Allocator, repo_path: []const u8) ![]const u8 {
    return db_join(allocator, normalizePath(repo_path), ".git");
}

fn db_join(allocator: std.mem.Allocator, base: []const u8, child: []const u8) ![]const u8 {
    var end = base.len;
    while (end > 1 and base[end - 1] == '/') end -= 1;
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ base[0..end], child });
}

/// A basic sanity check on a candidate path before we even hit the
/// filesystem: non-empty and absolute (macOS paths from the OS are
/// absolute; a relative path is almost certainly a typo).
pub const PathIssue = enum { ok, empty, not_absolute };

pub fn checkPathShape(raw: []const u8) PathIssue {
    const p = normalizePath(raw);
    if (p.len == 0) return .empty;
    if (p[0] != '/' and !(p.len > 1 and p[0] == '~')) return .not_absolute;
    return .ok;
}

// --------------------------------------------------------------- tests

const testing = std.testing;

test "normalizePath trims whitespace and trailing slashes" {
    try testing.expectEqualStrings("/a/b", normalizePath("  /a/b  "));
    try testing.expectEqualStrings("/a/b", normalizePath("/a/b/"));
    try testing.expectEqualStrings("/a/b", normalizePath("/a/b///"));
    try testing.expectEqualStrings("/", normalizePath("/"));
    try testing.expectEqualStrings("", normalizePath("   "));
}

test "defaultName returns the trailing path component" {
    try testing.expectEqualStrings("repo", defaultName("/Users/rui/code/repo"));
    try testing.expectEqualStrings("repo", defaultName("/Users/rui/code/repo/"));
    try testing.expectEqualStrings("Users", defaultName("/Users"));
}

test "gitMarkerPath appends .git to the normalized path" {
    const a = testing.allocator;
    const m1 = try gitMarkerPath(a, "/Users/rui/repo");
    defer a.free(m1);
    try testing.expectEqualStrings("/Users/rui/repo/.git", m1);

    const m2 = try gitMarkerPath(a, "/Users/rui/repo/");
    defer a.free(m2);
    try testing.expectEqualStrings("/Users/rui/repo/.git", m2);
}

test "checkPathShape rejects empty and relative paths" {
    try testing.expectEqual(PathIssue.ok, checkPathShape("/Users/rui/repo"));
    try testing.expectEqual(PathIssue.ok, checkPathShape("~/repo"));
    try testing.expectEqual(PathIssue.empty, checkPathShape("   "));
    try testing.expectEqual(PathIssue.not_absolute, checkPathShape("relative/path"));
}

test "insertStatement and deleteStatement carry the right params" {
    var ibuf: [3]db.Value = undefined;
    const ins = insertStatement(&ibuf, "/r", "r", 1234);
    try testing.expectEqual(@as(usize, 3), ins.params.len);
    try testing.expectEqualStrings("/r", ins.params[0].text);
    try testing.expectEqualStrings("r", ins.params[1].text);
    try testing.expectEqual(@as(i64, 1234), ins.params[2].integer);

    var dbuf: [1]db.Value = undefined;
    const del = deleteStatement(&dbuf, 9);
    try testing.expectEqual(@as(i64, 9), del.params[0].integer);
}

// Integration test: insert + list + delete against a real in-memory DB.
const native_sdk = @import("native_sdk");
const relational_store = native_sdk.runtime.relational_store;
const Msg = union(enum) { db: native_sdk.EffectDbResult };
const Fx = native_sdk.Effects(Msg);

test "repos insert/list/delete round-trip against a real database" {
    const open_result = try relational_store.Database.openMemoryMigrated(testing.allocator, &db.migrations);
    try testing.expectEqual(relational_store.OpenOutcome.ok, open_result.outcome);
    var database = open_result.database.?;
    defer database.deinit();
    var fx = Fx.init(testing.allocator);
    defer fx.deinit();
    fx.bindRelationalStore(database.binding());

    // Insert two repos (each statement gets its own params buffer).
    var b1: [3]db.Value = undefined;
    var b2: [3]db.Value = undefined;
    fx.dbExec(.{ .key = 1, .statements = &.{
        insertStatement(&b1, "/Users/rui/alpha", "alpha", 200),
        insertStatement(&b2, "/Users/rui/beta", "beta", 100),
    }, .on_result = Fx.dbMsg(.db) });
    try testing.expectEqual(native_sdk.EffectDbOutcome.ok, fx.takeMsg().?.db.outcome);

    // List: ordered by added_at DESC -> alpha (200) first, beta (100) next.
    fx.dbQuery(.{ .key = 2, .sql = list_sql, .on_result = Fx.dbMsg(.db) });
    const page = fx.takeMsg().?.db;
    try testing.expectEqual(native_sdk.EffectDbResultKind.page, page.kind);
    var reader = try db.PageReader.init(page.bytes);
    try testing.expectEqual(@as(usize, 2), reader.rowCount());

    var row: [5]db.ColumnValue = undefined;
    const first = Repo.fromRow((try reader.next(&row)).?).?;
    try testing.expectEqualStrings("alpha", first.name);
    try testing.expect(first.active);
    const second = Repo.fromRow((try reader.next(&row)).?).?;
    try testing.expectEqualStrings("beta", second.name);
    _ = fx.takeMsg(); // .done
    const alpha_id = first.id;

    // Delete alpha, then list shows only beta.
    var dbuf: [1]db.Value = undefined;
    fx.dbExec(.{ .key = 3, .statements = &.{deleteStatement(&dbuf, alpha_id)}, .on_result = Fx.dbMsg(.db) });
    try testing.expectEqual(native_sdk.EffectDbOutcome.ok, fx.takeMsg().?.db.outcome);

    fx.dbQuery(.{ .key = 4, .sql = list_sql, .on_result = Fx.dbMsg(.db) });
    const page2 = fx.takeMsg().?.db;
    var reader2 = try db.PageReader.init(page2.bytes);
    try testing.expectEqual(@as(usize, 1), reader2.rowCount());
    var row2: [5]db.ColumnValue = undefined;
    const only = Repo.fromRow((try reader2.next(&row2)).?).?;
    try testing.expectEqualStrings("beta", only.name);
    _ = fx.takeMsg(); // .done
}

test "duplicate repo path is rejected by the UNIQUE constraint" {
    const open_result = try relational_store.Database.openMemoryMigrated(testing.allocator, &db.migrations);
    var database = open_result.database.?;
    defer database.deinit();
    var fx = Fx.init(testing.allocator);
    defer fx.deinit();
    fx.bindRelationalStore(database.binding());

    var b1: [3]db.Value = undefined;
    fx.dbExec(.{ .key = 1, .statements = &.{insertStatement(&b1, "/dup", "dup", 1)}, .on_result = Fx.dbMsg(.db) });
    try testing.expectEqual(native_sdk.EffectDbOutcome.ok, fx.takeMsg().?.db.outcome);

    var b2: [3]db.Value = undefined;
    fx.dbExec(.{ .key = 2, .statements = &.{insertStatement(&b2, "/dup", "dup", 2)}, .on_result = Fx.dbMsg(.db) });
    try testing.expectEqual(native_sdk.EffectDbOutcome.constraint, fx.takeMsg().?.db.outcome);
}
