//! Typed SQLite helpers for Blocks over the Native SDK relational effects.
//!
//! The SDK delivers query results as encoded `.page` byte blobs on the
//! effects channel (EffectDbResult.bytes). This module provides:
//!   * `PageReader` — decodes that documented wire format into typed
//!     column values, so the rest of the app never touches raw bytes.
//!   * `val` — ergonomic constructors for bind parameters (EffectDbValue).
//!   * The embedded initial schema + the migration array, used by tests
//!     (the real app uses the build-generated migrations from
//!     `native db`, which are identical to these SQL files).
//!
//! Page wire format (little-endian), per relational_store.zig:
//!   u32 column_count, u32 row_count,
//!   column_count × (u32 len + name bytes),
//!   row_count × column_count × value:
//!     tag 0 = null
//!     tag 1 = i64
//!     tag 2 = f64 (u64 bits)
//!     tag 3 = text (u32 len + bytes)
//!     tag 4 = blob (u32 len + bytes)

const std = @import("std");
const native_sdk = @import("native_sdk");
const relational_store = native_sdk.runtime.relational_store;

pub const Value = native_sdk.EffectDbValue; // relational_store.Value
pub const Statement = native_sdk.EffectDbStatement;
pub const Migration = relational_store.Migration;

// ------------------------------------------------------------ migrations

/// The initial schema, embedded so tests can apply the exact same SQL the
/// build ships. Keep this list in sync with `src/schema/NNNN_*.sql`; the
/// running app loads the build-generated copy, not this one.
pub const migrations = [_]Migration{
    .{ .version = 1, .name = "initial_schema", .sql = @embedFile("schema/0001_initial_schema.sql") },
    .{ .version = 2, .name = "snippets_text_expander", .sql = @embedFile("schema/0002_snippets_text_expander.sql") },
};

// -------------------------------------------------------- bind value ctors

/// Ergonomic constructors for statement parameters.
pub const val = struct {
    pub fn int(n: i64) Value {
        return .{ .integer = n };
    }
    pub fn text(s: []const u8) Value {
        return .{ .text = s };
    }
    pub fn real(n: f64) Value {
        return .{ .real = n };
    }
    pub fn blob(b: []const u8) Value {
        return .{ .blob = b };
    }
    pub const null_value: Value = .null_value;
};

// ------------------------------------------------------------- page reader

pub const ColumnValue = union(enum) {
    null_value,
    integer: i64,
    real: f64,
    text: []const u8,
    blob: []const u8,

    pub fn asInt(self: ColumnValue) ?i64 {
        return switch (self) {
            .integer => |n| n,
            else => null,
        };
    }
    pub fn asText(self: ColumnValue) ?[]const u8 {
        return switch (self) {
            .text => |s| s,
            else => null,
        };
    }
    pub fn asBlob(self: ColumnValue) ?[]const u8 {
        return switch (self) {
            .blob => |b| b,
            else => null,
        };
    }
    pub fn isNull(self: ColumnValue) bool {
        return self == .null_value;
    }
};

pub const ReadError = error{MalformedPage};

/// Streaming decoder over one encoded query page. Column names and values
/// borrow from the page bytes (valid only while those bytes live — i.e.
/// during the `update` call that received the EffectDbResult). Copy out
/// anything the model keeps.
pub const PageReader = struct {
    bytes: []const u8,
    at: usize = 0,
    column_count: usize = 0,
    row_count: usize = 0,
    columns: [max_columns][]const u8 = undefined,
    rows_read: usize = 0,

    pub const max_columns = 64;

    pub fn init(bytes: []const u8) ReadError!PageReader {
        var self = PageReader{ .bytes = bytes };
        self.column_count = try self.readU32();
        self.row_count = try self.readU32();
        if (self.column_count > max_columns) return error.MalformedPage;
        for (0..self.column_count) |i| {
            self.columns[i] = try self.readLenBytes();
        }
        return self;
    }

    /// Number of rows encoded in this page.
    pub fn rowCount(self: *const PageReader) usize {
        return self.row_count;
    }

    /// Number of columns per row.
    pub fn columnCount(self: *const PageReader) usize {
        return self.column_count;
    }

    /// Read the next row into `out` (must have room for `column_count`
    /// values). Returns the row slice, or null when the page is exhausted.
    pub fn next(self: *PageReader, out: []ColumnValue) ReadError!?[]ColumnValue {
        if (self.rows_read >= self.row_count) return null;
        if (out.len < self.column_count) return error.MalformedPage;
        for (0..self.column_count) |i| {
            out[i] = try self.readValue();
        }
        self.rows_read += 1;
        return out[0..self.column_count];
    }

    fn readValue(self: *PageReader) ReadError!ColumnValue {
        const tag = try self.readByte();
        return switch (tag) {
            0 => .null_value,
            1 => .{ .integer = @bitCast(try self.readU64()) },
            2 => .{ .real = @bitCast(try self.readU64()) },
            3 => .{ .text = try self.readLenBytes() },
            4 => .{ .blob = try self.readLenBytes() },
            else => error.MalformedPage,
        };
    }

    fn readByte(self: *PageReader) ReadError!u8 {
        if (self.at >= self.bytes.len) return error.MalformedPage;
        const b = self.bytes[self.at];
        self.at += 1;
        return b;
    }

    fn readU32(self: *PageReader) ReadError!usize {
        const raw = try self.take(4);
        return std.mem.readInt(u32, raw[0..4], .little);
    }

    fn readU64(self: *PageReader) ReadError!u64 {
        const raw = try self.take(8);
        return std.mem.readInt(u64, raw[0..8], .little);
    }

    fn readLenBytes(self: *PageReader) ReadError![]const u8 {
        const len = try self.readU32();
        return self.take(len);
    }

    fn take(self: *PageReader, len: usize) ReadError![]const u8 {
        if (self.at + len > self.bytes.len) return error.MalformedPage;
        const out = self.bytes[self.at .. self.at + len];
        self.at += len;
        return out;
    }
};

// --------------------------------------------------------------- tests

const testing = std.testing;

// Real-DB test scaffolding: apply the embedded migrations to an in-memory
// database and drive it through a real Effects channel, exactly as the app
// does at runtime.
const Msg = union(enum) { db: native_sdk.EffectDbResult };
const Fx = native_sdk.Effects(Msg);

const TestDb = struct {
    database: relational_store.Database,
    fx: Fx,

    fn open() !TestDb {
        const open_result = try relational_store.Database.openMemoryMigrated(testing.allocator, &migrations);
        try testing.expectEqual(relational_store.OpenOutcome.ok, open_result.outcome);
        var db = TestDb{ .database = open_result.database.?, .fx = Fx.init(testing.allocator) };
        db.fx.bindRelationalStore(db.database.binding());
        return db;
    }

    fn close(self: *TestDb) void {
        self.fx.deinit();
        self.database.deinit();
    }

    fn take(self: *TestDb) !native_sdk.EffectDbResult {
        return if (self.fx.takeMsg()) |m| m.db else error.NoResult;
    }

    /// Run an exec batch and assert it committed ok.
    fn exec(self: *TestDb, statements: []const Statement) !void {
        self.fx.dbExec(.{ .key = 1, .statements = statements, .on_result = Fx.dbMsg(.db) });
        const r = try self.take();
        try testing.expectEqual(native_sdk.EffectDbResultKind.exec, r.kind);
        try testing.expectEqual(native_sdk.EffectDbOutcome.ok, r.outcome);
    }

    /// Run a query and return the first page's row count (0 if no page).
    fn queryRowCount(self: *TestDb, sql: []const u8, params: []const Value) !usize {
        self.fx.dbQuery(.{ .key = 2, .sql = sql, .params = params, .on_result = Fx.dbMsg(.db) });
        const first = try self.take();
        if (first.kind == .done) return 0;
        try testing.expectEqual(native_sdk.EffectDbResultKind.page, first.kind);
        var reader = try PageReader.init(first.bytes);
        const n = reader.rowCount();
        // drain the terminal .done
        const done = try self.take();
        try testing.expectEqual(native_sdk.EffectDbResultKind.done, done.kind);
        return n;
    }
};

test "migrations apply to a fresh in-memory database (schema version 2)" {
    var db = try TestDb.open();
    defer db.close();
    const version = try db.database.schemaVersion();
    try testing.expectEqual(@as(u32, 2), version);
}

test "re-applying migrations is idempotent (already at target version)" {
    var db = try TestDb.open();
    defer db.close();
    // Applying the same set again must be a no-op ok at the same version.
    const result = db.database.applyMigrations(&migrations);
    try testing.expectEqual(relational_store.OpenOutcome.ok, result.outcome);
    try testing.expectEqual(@as(u32, 2), result.version);
}

test "migration 0002 adds the snippets.text_expander column" {
    var db = try TestDb.open();
    defer db.close();
    // A row written with text_expander reads back — proves the column exists
    // with the right name after the 0002 ALTER.
    try db.exec(&.{.{
        .sql = "INSERT INTO snippets(id, title, content, language, annotation, text_expander, created_at, updated_at) " ++
            "VALUES(1,'t','c','zig','a','expand-me',1,1);",
    }});
    db.fx.dbQuery(.{ .key = 7, .sql = "SELECT text_expander FROM snippets WHERE id = 1;", .on_result = Fx.dbMsg(.db) });
    const page = try db.take();
    var reader = try PageReader.init(page.bytes);
    var row: [1]ColumnValue = undefined;
    const cols = (try reader.next(&row)).?;
    try testing.expectEqualStrings("expand-me", cols[0].asText().?);
    _ = try db.take(); // .done
}

test "every declared table exists after migration" {
    var db = try TestDb.open();
    defer db.close();
    const tables = [_][]const u8{ "repos", "events", "file_snapshots", "chats", "messages", "snippets", "embeddings", "memory_fts" };
    for (tables) |name| {
        const n = try db.queryRowCount(
            "SELECT name FROM sqlite_master WHERE name = ?1;",
            &.{val.text(name)},
        );
        try testing.expectEqual(@as(usize, 1), n);
    }
}

test "repos CRUD round-trip and decoded columns" {
    var db = try TestDb.open();
    defer db.close();
    try db.exec(&.{
        .{ .sql = "INSERT INTO repos(id, path, name, active, added_at) VALUES(?1,?2,?3,1,?4);", .params = &.{ val.int(1), val.text("/tmp/repo"), val.text("repo"), val.int(1000) } },
    });

    db.fx.dbQuery(.{ .key = 3, .sql = "SELECT id, path, name, active FROM repos WHERE id = ?1;", .params = &.{val.int(1)}, .on_result = Fx.dbMsg(.db) });
    const page = try db.take();
    try testing.expectEqual(native_sdk.EffectDbResultKind.page, page.kind);
    var reader = try PageReader.init(page.bytes);
    try testing.expectEqual(@as(usize, 1), reader.rowCount());
    var row: [4]ColumnValue = undefined;
    const cols = (try reader.next(&row)).?;
    try testing.expectEqual(@as(i64, 1), cols[0].asInt().?);
    try testing.expectEqualStrings("/tmp/repo", cols[1].asText().?);
    try testing.expectEqualStrings("repo", cols[2].asText().?);
    try testing.expectEqual(@as(i64, 1), cols[3].asInt().?);
    _ = try db.take(); // .done
}

test "events FK cascade: deleting a repo removes its events" {
    var db = try TestDb.open();
    defer db.close();
    try db.exec(&.{
        .{ .sql = "INSERT INTO repos(id, path, name, added_at) VALUES(1,'/r','r',1);" },
        .{ .sql = "INSERT INTO events(id, repo_id, kind, occurred_at, created_at) VALUES(1,1,'commit',10,10);" },
    });
    try testing.expectEqual(@as(usize, 1), try db.queryRowCount("SELECT id FROM events;", &.{}));
    try db.exec(&.{.{ .sql = "DELETE FROM repos WHERE id = 1;" }});
    // foreign_keys=ON is set by the store writer, so the cascade fires.
    try testing.expectEqual(@as(usize, 0), try db.queryRowCount("SELECT id FROM events;", &.{}));
}

test "unique commit index rejects duplicate commit in the same repo" {
    var db = try TestDb.open();
    defer db.close();
    try db.exec(&.{.{ .sql = "INSERT INTO repos(id, path, name, added_at) VALUES(1,'/r','r',1);" }});
    try db.exec(&.{.{ .sql = "INSERT INTO events(id, repo_id, kind, occurred_at, commit_oid, created_at) VALUES(1,1,'commit',10,'abc',10);" }});

    // A second event with the same (repo_id, commit_oid) must violate the
    // unique partial index -> constraint outcome, not ok.
    db.fx.dbExec(.{ .key = 9, .statements = &.{
        .{ .sql = "INSERT INTO events(id, repo_id, kind, occurred_at, commit_oid, created_at) VALUES(2,1,'commit',11,'abc',11);" },
    }, .on_result = Fx.dbMsg(.db) });
    const r = try db.take();
    try testing.expectEqual(native_sdk.EffectDbOutcome.constraint, r.outcome);
}

test "FTS5 memory_fts supports MATCH queries" {
    var db = try TestDb.open();
    defer db.close();
    try db.exec(&.{
        .{ .sql = "INSERT INTO memory_fts(ref_kind, ref_id, body) VALUES('event', 1, 'nginx deployment configuration');" },
        .{ .sql = "INSERT INTO memory_fts(ref_kind, ref_id, body) VALUES('event', 2, 'neovim editor setup');" },
    });
    try testing.expectEqual(@as(usize, 1), try db.queryRowCount("SELECT ref_id FROM memory_fts WHERE memory_fts MATCH 'nginx';", &.{}));
    try testing.expectEqual(@as(usize, 0), try db.queryRowCount("SELECT ref_id FROM memory_fts WHERE memory_fts MATCH 'kubernetes';", &.{}));
}

test "embeddings store and read back a raw f32 vector blob" {
    var db = try TestDb.open();
    defer db.close();
    const vec = [_]f32{ 0.1, 0.2, 0.3, 0.4 };
    const vec_bytes = std.mem.sliceAsBytes(vec[0..]);
    try db.exec(&.{
        .{ .sql = "INSERT INTO embeddings(source_kind, source_id, model, dim, vector, created_at) VALUES(?1,?2,?3,?4,?5,?6);", .params = &.{ val.text("snippet"), val.int(7), val.text("test-embed"), val.int(4), val.blob(vec_bytes), val.int(100) } },
    });

    db.fx.dbQuery(.{ .key = 4, .sql = "SELECT dim, vector FROM embeddings WHERE source_kind='snippet' AND source_id=7;", .on_result = Fx.dbMsg(.db) });
    const page = try db.take();
    var reader = try PageReader.init(page.bytes);
    var row: [2]ColumnValue = undefined;
    const cols = (try reader.next(&row)).?;
    try testing.expectEqual(@as(i64, 4), cols[0].asInt().?);
    const got = cols[1].asBlob().?;
    try testing.expectEqualSlices(u8, vec_bytes, got);
    _ = try db.take(); // .done
}
