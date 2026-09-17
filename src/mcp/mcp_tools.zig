//! MCP tools — SDK-side integration tests + the JSON-RPC dispatcher used
//! against the Native SDK relational store (Task 8).
//!
//! The standalone server binary talks to libsqlite3 directly; but the tool
//! LOGIC (SQL in `tools.zig`, JSON in `protocol.zig`) is DB-agnostic, so we
//! prove it here against the SDK's real in-memory SQLite the same way
//! `embeddings.zig` does — inserting fixtures, running each tool's SQL
//! through `dbQuery`, decoding the page with `db.PageReader`, and shaping
//! the rows with the pure writers. This is the authoritative correctness
//! check for the queries; the standalone binary re-runs the identical SQL.
//!
//! It also hosts `search_memory`'s ranking bridge: embed the query, rank
//! stored vectors (embeddings.rankPage) + gather FTS matches, then fetch
//! each hit's display row and shape it. Kept here (not in the pure tools
//! file) because ranking + fetching is inherently multi-query I/O.

const std = @import("std");
const native_sdk = @import("native_sdk");
const db = @import("../db.zig");
const embeddings = @import("../embeddings.zig");
const proto = @import("protocol.zig");
const tools = @import("tools.zig");

// ------------------------------------------------------------- test rig

const testing = std.testing;
const relational_store = native_sdk.runtime.relational_store;
const Msg = union(enum) { db: native_sdk.EffectDbResult };
const Fx = native_sdk.Effects(Msg);

const Rig = struct {
    database: relational_store.Database,
    fx: Fx,
    arena: std.heap.ArenaAllocator,

    fn open() !Rig {
        const open_result = try relational_store.Database.openMemoryMigrated(testing.allocator, &db.migrations);
        try testing.expectEqual(relational_store.OpenOutcome.ok, open_result.outcome);
        var rig = Rig{
            .database = open_result.database.?,
            .fx = Fx.init(testing.allocator),
            .arena = std.heap.ArenaAllocator.init(testing.allocator),
        };
        rig.fx.bindRelationalStore(rig.database.binding());
        return rig;
    }
    fn close(self: *Rig) void {
        self.arena.deinit();
        self.fx.deinit();
        self.database.deinit();
    }
    fn exec(self: *Rig, statements: []const db.Statement) !void {
        self.fx.dbExec(.{ .key = 1, .statements = statements, .on_result = Fx.dbMsg(.db) });
        const r = self.fx.takeMsg().?.db;
        try testing.expectEqual(native_sdk.EffectDbOutcome.ok, r.outcome);
    }
    fn execSql(self: *Rig, sql: []const u8) !void {
        try self.exec(&.{.{ .sql = sql }});
    }
    /// Run a query and return the first page's bytes copied into the rig
    /// arena (so they survive draining the terminal .done).
    fn queryPage(self: *Rig, sql: []const u8, params: []const db.Value) !?[]const u8 {
        self.fx.dbQuery(.{ .key = 2, .sql = sql, .params = params, .on_result = Fx.dbMsg(.db) });
        var page_bytes: ?[]const u8 = null;
        while (self.fx.takeMsg()) |m| {
            const r = m.db;
            if (r.kind == .done) break;
            if (r.kind == .page and page_bytes == null) {
                page_bytes = try self.arena.allocator().dupe(u8, r.bytes);
            }
        }
        return page_bytes;
    }
};

fn seedRepo(rig: *Rig) !void {
    try rig.execSql("INSERT INTO repos(id, path, name, added_at) VALUES(1,'/r','blocks',1);");
}

// ------------------------------------------------------- get_commits

test "get_commits SQL + shaper returns commits newest-first as JSON" {
    var rig = try Rig.open();
    defer rig.close();
    try seedRepo(&rig);
    try rig.execSql(
        "INSERT INTO events(id, repo_id, kind, occurred_at, commit_oid, author_name, subject, files_changed, insertions, deletions, created_at) " ++
        "VALUES(1,1,'commit',100,'aaa','Rui','first commit',2,10,1,100)," ++
        "(2,1,'commit',200,'bbb','Rui','second commit',1,3,0,200);",
    );

    const q = tools.parseCommitsArgs(.{});
    const page = (try rig.queryPage(tools.commitsSql(q), &.{db.val.int(q.limit)})).?;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    var w = proto.JsonWriter.init(&out, testing.allocator);
    try tools.beginCommits(&w);
    var reader = try db.PageReader.init(page);
    var row: [10]db.ColumnValue = undefined;
    var first = true;
    while (try reader.next(&row)) |cols| {
        try tools.writeCommitRow(&w, first, .{
            .id = cols[0].asInt().?,
            .repo_id = cols[1].asInt().?,
            .repo_name = cols[2].asText().?,
            .oid = cols[3].asText() orelse "",
            .author = cols[4].asText() orelse "",
            .subject = cols[5].asText() orelse "",
            .occurred_at = cols[6].asInt().?,
            .files_changed = cols[7].asInt().?,
            .insertions = cols[8].asInt().?,
            .deletions = cols[9].asInt().?,
        });
        first = false;
    }
    try tools.endList(&w);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), out.items, .{});
    defer parsed.deinit();
    const commits = parsed.value.object.get("commits").?.array;
    try testing.expectEqual(@as(usize, 2), commits.items.len);
    // Newest first: occurred_at 200 (id 2) leads.
    try testing.expectEqual(@as(i64, 2), commits.items[0].object.get("id").?.integer);
    try testing.expectEqualStrings("second commit", commits.items[0].object.get("subject").?.string);
}

test "get_commits filters by repo_id" {
    var rig = try Rig.open();
    defer rig.close();
    try rig.execSql("INSERT INTO repos(id, path, name, added_at) VALUES(1,'/a','a',1),(2,'/b','b',1);");
    try rig.execSql(
        "INSERT INTO events(id, repo_id, kind, occurred_at, commit_oid, subject, created_at) " ++
        "VALUES(1,1,'commit',100,'a1','in a',100),(2,2,'commit',200,'b1','in b',200);",
    );
    var argmap: std.json.ObjectMap = .{};
    try argmap.put(rig.arena.allocator(), "repo_id", .{ .integer = 2 });
    const q = tools.parseCommitsArgs(argmap);
    const page = (try rig.queryPage(tools.commitsSql(q), &.{ db.val.int(q.repo_id.?), db.val.int(q.limit) })).?;
    var reader = try db.PageReader.init(page);
    try testing.expectEqual(@as(usize, 1), reader.rowCount());
    var row: [10]db.ColumnValue = undefined;
    const cols = (try reader.next(&row)).?;
    try testing.expectEqual(@as(i64, 2), cols[1].asInt().?); // repo_id
}

// ------------------------------------------------------- get_activity

test "get_activity unions commits and snapshots newest-first" {
    var rig = try Rig.open();
    defer rig.close();
    try seedRepo(&rig);
    try rig.execSql("INSERT INTO events(id, repo_id, kind, occurred_at, subject, created_at) VALUES(1,1,'commit',100,'a commit',100);");
    try rig.execSql("INSERT INTO file_snapshots(id, repo_id, rel_path, content, content_hash, byte_len, captured_at) VALUES(1,1,'src/main.zig','x','h',1,300);");

    const q = tools.parseActivityArgs(.{});
    const b = tools.activityBounds(q);
    const page = (try rig.queryPage(tools.activity_sql, &.{ db.val.int(b.since), db.val.int(b.until), db.val.int(b.limit) })).?;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    var w = proto.JsonWriter.init(&out, testing.allocator);
    try tools.beginActivity(&w);
    var reader = try db.PageReader.init(page);
    var row: [6]db.ColumnValue = undefined;
    var first = true;
    while (try reader.next(&row)) |cols| {
        try tools.writeActivityRow(&w, first, .{
            .kind = cols[0].asText().?,
            .ref_id = cols[1].asInt().?,
            .repo_id = cols[2].asInt().?,
            .repo_name = cols[3].asText().?,
            .title = cols[4].asText() orelse "",
            .occurred_at = cols[5].asInt().?,
        });
        first = false;
    }
    try tools.endList(&w);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), out.items, .{});
    defer parsed.deinit();
    const activity = parsed.value.object.get("activity").?.array;
    try testing.expectEqual(@as(usize, 2), activity.items.len);
    // The snapshot (captured_at 300) is newest.
    try testing.expectEqualStrings("file_snapshot", activity.items[0].object.get("kind").?.string);
}

test "get_activity respects the since/until window" {
    var rig = try Rig.open();
    defer rig.close();
    try seedRepo(&rig);
    try rig.execSql(
        "INSERT INTO events(id, repo_id, kind, occurred_at, subject, created_at) " ++
        "VALUES(1,1,'commit',50,'old',50),(2,1,'commit',150,'mid',150),(3,1,'commit',250,'new',250);",
    );
    var argmap: std.json.ObjectMap = .{};
    try argmap.put(rig.arena.allocator(), "since_ms", .{ .integer = 100 });
    try argmap.put(rig.arena.allocator(), "until_ms", .{ .integer = 200 });
    const q = tools.parseActivityArgs(argmap);
    const b = tools.activityBounds(q);
    const page = (try rig.queryPage(tools.activity_sql, &.{ db.val.int(b.since), db.val.int(b.until), db.val.int(b.limit) })).?;
    var reader = try db.PageReader.init(page);
    try testing.expectEqual(@as(usize, 1), reader.rowCount()); // only 'mid'
}

// ------------------------------------------------------- search_memory

test "search_memory ranks the most relevant memory and shapes it" {
    var rig = try Rig.open();
    defer rig.close();
    try seedRepo(&rig);
    // Three commit events + their embeddings (the real hashing embedder).
    try rig.execSql(
        "INSERT INTO events(id, repo_id, kind, occurred_at, subject, body, created_at) VALUES" ++
        "(10,1,'commit',100,'add nginx reverse proxy','for the staging deployment',100)," ++
        "(20,1,'commit',200,'refactor sqlite migration runner','and the page reader',200)," ++
        "(30,1,'commit',300,'banana smoothie recipe generator','mango demo',300);",
    );
    for ([_]struct { id: i64, text: []const u8 }{
        .{ .id = 10, .text = "add nginx reverse proxy for the staging deployment" },
        .{ .id = 20, .text = "refactor sqlite migration runner and the page reader" },
        .{ .id = 30, .text = "banana smoothie recipe generator mango demo" },
    }) |e| {
        var vec = embeddings.embedValue(e.text);
        const bytes = embeddings.vectorBytes(&vec);
        var params: [embeddings.insert_param_count]db.Value = undefined;
        try rig.exec(&.{embeddings.insertStatement(&params, .event, e.id, bytes, 100)});
    }

    // Rank stored vectors against the query.
    var query = embeddings.embedValue("nginx deployment proxy configuration");
    const vpage = (try rig.queryPage(embeddings.select_vectors_sql, &.{db.val.text(embeddings.model_id)})).?;
    var top: [5]embeddings.Hit = undefined;
    const n = embeddings.rankPage(&top, 0, &query, vpage);
    try testing.expect(n >= 1);
    // The nginx memory (id 10) must rank first.
    try testing.expectEqual(@as(i64, 10), top[0].source_id);
    try testing.expectEqual(embeddings.SourceKind.event, top[0].kind);

    // Fetch the top hit's display row + shape it.
    const rowpage = (try rig.queryPage(tools.search_event_row_sql, &.{db.val.int(top[0].source_id)})).?;
    var reader = try db.PageReader.init(rowpage);
    var row: [5]db.ColumnValue = undefined;
    const cols = (try reader.next(&row)).?;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    var w = proto.JsonWriter.init(&out, testing.allocator);
    try tools.beginSearch(&w, "nginx deployment proxy configuration");
    try tools.writeSearchHit(&w, true, .{
        .kind = "event",
        .source_id = top[0].source_id,
        .repo_id = cols[0].asInt().?,
        .repo_name = cols[1].asText().?,
        .title = cols[2].asText() orelse "",
        .snippet = tools.excerpt(cols[3].asText() orelse "", 200),
        .occurred_at = cols[4].asInt().?,
        .score = top[0].score,
    });
    try tools.endList(&w);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), out.items, .{});
    defer parsed.deinit();
    const results = parsed.value.object.get("results").?.array;
    try testing.expectEqual(@as(usize, 1), results.items.len);
    try testing.expectEqualStrings("add nginx reverse proxy", results.items[0].object.get("title").?.string);
}

test "search_memory FTS arm finds a keyword match" {
    var rig = try Rig.open();
    defer rig.close();
    try seedRepo(&rig);
    try rig.execSql(
        "INSERT INTO memory_fts(ref_kind, ref_id, body) VALUES" ++
        "('event',10,'add nginx reverse proxy config')," ++
        "('event',20,'sqlite migration runner refactor');",
    );
    const page = (try rig.queryPage(embeddings.fts_search_sql, &.{ db.val.text("nginx"), db.val.int(10) })).?;
    var reader = try db.PageReader.init(page);
    try testing.expectEqual(@as(usize, 1), reader.rowCount());
    var row: [3]db.ColumnValue = undefined;
    const cols = (try reader.next(&row)).?;
    try testing.expectEqualStrings("event", cols[0].asText().?);
    try testing.expectEqual(@as(i64, 10), cols[1].asInt().?);
}
