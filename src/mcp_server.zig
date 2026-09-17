//! Blocks MCP server — the SPAWNED CHILD PROCESS (Task 8).
//!
//! A standalone binary the app launches on boot. It opens the app's
//! SQLite database (`app.db`) directly via the system libsqlite3, and
//! serves the developer-memory MCP tools over HTTP/JSON-RPC on
//! `127.0.0.1`. The v1 consumer is the app's own local LLM.
//!
//! Why a separate process (locked decision): the Native SDK has a `fetch`
//! CLIENT but no in-process HTTP/socket LISTENER effect, so the server
//! cannot live inside the app runtime. It lives here, bound to loopback,
//! and the app reaches it with `fx.fetch`.
//!
//! Why libsqlite3 (not the SDK relational store): the SDK's SQLite is only
//! wired into the app-runtime build graph; a plain sidecar can't import it
//! without ejecting the whole build. `app.db` is a plain SQLite file, so
//! this process opens it READ-ONLY with the system library that ships on
//! every macOS. It only READS — the app runtime remains the sole writer.
//!
//! The tool LOGIC (SQL, JSON shaping, ranking) is the SAME pure code the
//! app-side tests exercise: `mcp/protocol.zig`, `mcp/tools.zig`, and
//! `embeddings.zig`. This file is the thin I/O shell: sqlite bindings, an
//! HTTP accept loop, and a JSON-RPC dispatcher.
//!
//! Usage: `blocks-mcp --db <path-to-app.db> [--port N] [--endpoint <file>]`.
//! On start it binds a loopback port (the requested one, else scans a small
//! range) and writes `{"port":N,"pid":P}` to the endpoint file (default
//! `<db-dir>/mcp-endpoint.json`) so the parent can discover where to fetch.

const std = @import("std");
const proto = @import("mcp/protocol.zig");
const tools = @import("mcp/tools.zig");
// The SDK-free embedding core (vector math + hashing embedder + top-k),
// NOT `embeddings.zig` — the latter pulls in the SDK-coupled `db.zig`.
const embeddings = @import("embed_core.zig");

const net = std.Io.net;
const http = std.http;

// --------------------------------------------------------- sqlite bindings

/// Minimal libsqlite3 C surface (declared directly to avoid a @cImport of
/// the platform header). We link `-lsqlite3`. Only the read path is used.
const c = struct {
    const sqlite3 = opaque {};
    const sqlite3_stmt = opaque {};

    const SQLITE_OK: c_int = 0;
    const SQLITE_ROW: c_int = 100;
    const SQLITE_DONE: c_int = 101;
    const SQLITE_OPEN_READONLY: c_int = 0x00000001;

    // Column types.
    const SQLITE_INTEGER: c_int = 1;
    const SQLITE_FLOAT: c_int = 2;
    const SQLITE_TEXT: c_int = 3;
    const SQLITE_BLOB: c_int = 4;
    const SQLITE_NULL: c_int = 5;

    // Destructor sentinel for sqlite3_bind_text. We use SQLITE_STATIC
    // (null): the bound text slices come from caller memory that lives for
    // the whole `query` call (until the statement is finalized), so sqlite
    // need not copy them.
    const bind_static: ?*const fn (?*anyopaque) callconv(.c) void = null;

    extern "c" fn sqlite3_open_v2(filename: [*:0]const u8, ppDb: *?*sqlite3, flags: c_int, zVfs: ?[*:0]const u8) c_int;
    extern "c" fn sqlite3_close(db: ?*sqlite3) c_int;
    extern "c" fn sqlite3_prepare_v2(db: ?*sqlite3, zSql: [*]const u8, nByte: c_int, ppStmt: *?*sqlite3_stmt, pzTail: ?*?[*]const u8) c_int;
    extern "c" fn sqlite3_finalize(stmt: ?*sqlite3_stmt) c_int;
    extern "c" fn sqlite3_step(stmt: ?*sqlite3_stmt) c_int;
    extern "c" fn sqlite3_reset(stmt: ?*sqlite3_stmt) c_int;
    extern "c" fn sqlite3_bind_int64(stmt: ?*sqlite3_stmt, idx: c_int, v: i64) c_int;
    extern "c" fn sqlite3_bind_text(stmt: ?*sqlite3_stmt, idx: c_int, v: [*]const u8, n: c_int, del: ?*const fn (?*anyopaque) callconv(.c) void) c_int;
    extern "c" fn sqlite3_column_count(stmt: ?*sqlite3_stmt) c_int;
    extern "c" fn sqlite3_column_type(stmt: ?*sqlite3_stmt, i: c_int) c_int;
    extern "c" fn sqlite3_column_int64(stmt: ?*sqlite3_stmt, i: c_int) i64;
    extern "c" fn sqlite3_column_text(stmt: ?*sqlite3_stmt, i: c_int) ?[*]const u8;
    extern "c" fn sqlite3_column_blob(stmt: ?*sqlite3_stmt, i: c_int) ?*const anyopaque;
    extern "c" fn sqlite3_column_bytes(stmt: ?*sqlite3_stmt, i: c_int) c_int;
    extern "c" fn sqlite3_errmsg(db: ?*sqlite3) [*:0]const u8;
};

/// A bind parameter for a prepared statement.
const Bind = union(enum) {
    int: i64,
    text: []const u8,
};

/// A decoded column value, owned by the row's arena.
const Col = union(enum) {
    null_value,
    int: i64,
    text: []const u8,
    blob: []const u8,

    fn asInt(self: Col) ?i64 {
        return switch (self) {
            .int => |n| n,
            else => null,
        };
    }
    fn asText(self: Col) []const u8 {
        return switch (self) {
            .text => |s| s,
            else => "",
        };
    }
    fn asBlob(self: Col) ?[]const u8 {
        return switch (self) {
            .blob => |b| b,
            else => null,
        };
    }
};

const Db = struct {
    handle: ?*c.sqlite3,

    fn openReadOnly(path: [:0]const u8) !Db {
        var handle: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open_v2(path.ptr, &handle, c.SQLITE_OPEN_READONLY, null);
        if (rc != c.SQLITE_OK) {
            if (handle != null) _ = c.sqlite3_close(handle);
            return error.OpenFailed;
        }
        return .{ .handle = handle };
    }
    fn close(self: *Db) void {
        _ = c.sqlite3_close(self.handle);
        self.handle = null;
    }

    /// Run `sql` with `binds`, invoking `onRow(arena, cols)` for each row.
    /// Column slices live in `arena` (valid until the caller frees it).
    fn query(
        self: *Db,
        arena: std.mem.Allocator,
        sql: []const u8,
        binds: []const Bind,
        ctx: anytype,
        comptime onRow: fn (@TypeOf(ctx), []const Col) anyerror!void,
    ) !void {
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.handle, sql.ptr, @intCast(sql.len), &stmt, null);
        if (rc != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        for (binds, 0..) |b, i| {
            const idx: c_int = @intCast(i + 1);
            switch (b) {
                .int => |n| _ = c.sqlite3_bind_int64(stmt, idx, n),
                .text => |s| _ = c.sqlite3_bind_text(stmt, idx, s.ptr, @intCast(s.len), c.bind_static),
            }
        }

        const ncols: usize = @intCast(c.sqlite3_column_count(stmt));
        while (true) {
            const step = c.sqlite3_step(stmt);
            if (step == c.SQLITE_DONE) break;
            if (step != c.SQLITE_ROW) return error.StepFailed;

            var cols = try arena.alloc(Col, ncols);
            for (0..ncols) |i| {
                const ci: c_int = @intCast(i);
                cols[i] = switch (c.sqlite3_column_type(stmt, ci)) {
                    c.SQLITE_INTEGER => .{ .int = c.sqlite3_column_int64(stmt, ci) },
                    c.SQLITE_TEXT => blk: {
                        const n: usize = @intCast(c.sqlite3_column_bytes(stmt, ci));
                        const p = c.sqlite3_column_text(stmt, ci);
                        const copy = try arena.dupe(u8, if (p) |pp| pp[0..n] else "");
                        break :blk .{ .text = copy };
                    },
                    c.SQLITE_BLOB => blk: {
                        const n: usize = @intCast(c.sqlite3_column_bytes(stmt, ci));
                        const p = c.sqlite3_column_blob(stmt, ci);
                        const bytes = if (p) |pp| @as([*]const u8, @ptrCast(pp))[0..n] else "";
                        break :blk .{ .blob = try arena.dupe(u8, bytes) };
                    },
                    else => .null_value,
                };
            }
            try onRow(ctx, cols);
        }
    }
};

// ------------------------------------------------------------- dispatch

/// The server context passed through the HTTP loop into dispatch.
const Context = struct {
    db: *Db,
};

/// Handle one JSON-RPC request body, appending the response JSON to `out`.
/// Returns false when the request was a notification (no response to send).
fn handleRpc(ctx: *Context, arena: std.mem.Allocator, body: []const u8, out: *std.ArrayList(u8)) !bool {
    const req = proto.parseRequest(arena, body) catch {
        try proto.writeError(out, arena, .none, proto.err_parse, "invalid JSON-RPC request");
        return true;
    };

    if (proto.isNotification(req.method)) return false; // ack, no body

    if (std.mem.eql(u8, req.method, "initialize")) {
        try proto.writeInitializeResult(out, arena, req.id);
        return true;
    }
    if (std.mem.eql(u8, req.method, "tools/list")) {
        try proto.writeToolsListResult(out, arena, req.id);
        return true;
    }
    if (std.mem.eql(u8, req.method, "tools/call")) {
        try handleToolCall(ctx, arena, req, out);
        return true;
    }
    if (std.mem.eql(u8, req.method, "ping")) {
        // MCP utility: an empty result object.
        var w = proto.JsonWriter.init(out, arena);
        try proto.beginResponse(&w, req.id);
        try w.key("result");
        try w.raw("{}}");
        return true;
    }

    try proto.writeError(out, arena, req.id, proto.err_method_not_found, "unknown method");
    return true;
}

fn handleToolCall(ctx: *Context, arena: std.mem.Allocator, req: proto.Request, out: *std.ArrayList(u8)) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, arena, req.params_json, .{}) catch {
        try proto.writeError(out, arena, req.id, proto.err_invalid_params, "params must be an object");
        return;
    };
    defer parsed.deinit();

    const args = tools.parseCallArguments(&parsed) catch {
        try proto.writeError(out, arena, req.id, proto.err_invalid_params, "missing tool name or arguments");
        return;
    };

    // Each tool builds its JSON payload into `payload`, wrapped as MCP text.
    var payload: std.ArrayList(u8) = .empty;

    if (std.mem.eql(u8, args.name, proto.tool_get_commits)) {
        try runGetCommits(ctx, arena, args.arguments, &payload);
    } else if (std.mem.eql(u8, args.name, proto.tool_get_activity)) {
        try runGetActivity(ctx, arena, args.arguments, &payload);
    } else if (std.mem.eql(u8, args.name, proto.tool_search_memory)) {
        const ok = try runSearchMemory(ctx, arena, args.arguments, &payload);
        if (!ok) {
            try proto.writeToolResult(out, arena, req.id, "{\"error\":\"query is required\"}", true);
            return;
        }
    } else {
        try proto.writeError(out, arena, req.id, proto.err_invalid_params, "unknown tool");
        return;
    }

    try proto.writeToolResult(out, arena, req.id, payload.items, false);
}

// --------------------------------------------------------------- tools

const CommitCtx = struct {
    w: *proto.JsonWriter,
    first: *bool,
};

fn runGetCommits(ctx: *Context, arena: std.mem.Allocator, argmap: std.json.ObjectMap, payload: *std.ArrayList(u8)) !void {
    const q = tools.parseCommitsArgs(argmap);
    var w = proto.JsonWriter.init(payload, arena);
    try tools.beginCommits(&w);
    var first = true;
    var cc = CommitCtx{ .w = &w, .first = &first };

    const Row = struct {
        fn on(cc_: *CommitCtx, cols: []const Col) anyerror!void {
            if (cols.len < 10) return;
            try tools.writeCommitRow(cc_.w, cc_.first.*, .{
                .id = cols[0].asInt() orelse 0,
                .repo_id = cols[1].asInt() orelse 0,
                .repo_name = cols[2].asText(),
                .oid = cols[3].asText(),
                .author = cols[4].asText(),
                .subject = cols[5].asText(),
                .occurred_at = cols[6].asInt() orelse 0,
                .files_changed = cols[7].asInt() orelse 0,
                .insertions = cols[8].asInt() orelse 0,
                .deletions = cols[9].asInt() orelse 0,
            });
            cc_.first.* = false;
        }
    };

    if (q.repo_id) |rid| {
        try ctx.db.query(arena, tools.commits_sql_by_repo, &.{ .{ .int = rid }, .{ .int = q.limit } }, &cc, Row.on);
    } else {
        try ctx.db.query(arena, tools.commits_sql_all, &.{.{ .int = q.limit }}, &cc, Row.on);
    }
    try tools.endList(&w);
}

const ActivityCtx = struct {
    w: *proto.JsonWriter,
    first: *bool,
};

fn runGetActivity(ctx: *Context, arena: std.mem.Allocator, argmap: std.json.ObjectMap, payload: *std.ArrayList(u8)) !void {
    const q = tools.parseActivityArgs(argmap);
    const b = tools.activityBounds(q);
    var w = proto.JsonWriter.init(payload, arena);
    try tools.beginActivity(&w);
    var first = true;
    var ac = ActivityCtx{ .w = &w, .first = &first };

    const Row = struct {
        fn on(ac_: *ActivityCtx, cols: []const Col) anyerror!void {
            if (cols.len < 6) return;
            try tools.writeActivityRow(ac_.w, ac_.first.*, .{
                .kind = cols[0].asText(),
                .ref_id = cols[1].asInt() orelse 0,
                .repo_id = cols[2].asInt() orelse 0,
                .repo_name = cols[3].asText(),
                .title = cols[4].asText(),
                .occurred_at = cols[5].asInt() orelse 0,
            });
            ac_.first.* = false;
        }
    };

    try ctx.db.query(arena, tools.activity_sql, &.{ .{ .int = b.since }, .{ .int = b.until }, .{ .int = b.limit } }, &ac, Row.on);
    try tools.endList(&w);
}

/// A collector for the vector-search arm: gather (kind, source_id, vector)
/// rows and rank them against the query vector with the pure top-k helper.
const RankCtx = struct {
    query: *const embeddings.Vector,
    hits: []embeddings.Hit,
    count: usize = 0,

    fn on(self: *RankCtx, cols: []const Col) anyerror!void {
        if (cols.len < 3) return;
        const kind = embeddings.kindFromName(cols[0].asText()) orelse return;
        const source_id = cols[1].asInt() orelse return;
        const blob = cols[2].asBlob() orelse return;
        var vec: embeddings.Vector = undefined;
        embeddings.vectorFromBytes(blob, &vec) catch return;
        const score = embeddings.dot(self.query, &vec);
        self.count = embeddings.considerTopK(self.hits, self.count, .{ .kind = kind, .source_id = source_id, .score = score });
    }
};

const HitRowCtx = struct {
    row: ?[]const Col = null,
    arena: std.mem.Allocator,

    fn on(self: *HitRowCtx, cols: []const Col) anyerror!void {
        if (self.row != null) return; // only the first row
        // The cols already live in the caller's arena.
        self.row = try self.arena.dupe(Col, cols);
    }
};

/// search_memory: embed the query, rank stored vectors, then fetch each
/// hit's display row and shape it. Returns false if `query` was missing.
fn runSearchMemory(ctx: *Context, arena: std.mem.Allocator, argmap: std.json.ObjectMap, payload: *std.ArrayList(u8)) !bool {
    const q = tools.parseSearchArgs(argmap) catch return false;

    var query_vec = embeddings.embedValue(q.query);

    // Rank all stored vectors for the fixed model.
    const max_hits = 50;
    var hits: [max_hits]embeddings.Hit = undefined;
    const k: usize = @intCast(std.math.clamp(q.limit, 1, max_hits));
    var rank = RankCtx{ .query = &query_vec, .hits = hits[0..k] };
    try ctx.db.query(arena, embeddings.select_vectors_sql, &.{.{ .text = embeddings.model_id }}, &rank, RankCtx.on);

    var w = proto.JsonWriter.init(payload, arena);
    try tools.beginSearch(&w, q.query);
    var first = true;
    var i: usize = 0;
    while (i < rank.count) : (i += 1) {
        const hit = rank.hits[i];
        // Fetch the display row for this hit.
        var hit_arena_state = std.heap.ArenaAllocator.init(arena);
        defer hit_arena_state.deinit();
        const ha = hit_arena_state.allocator();
        var rowctx = HitRowCtx{ .arena = ha };
        const sql = switch (hit.kind) {
            .event => tools.search_event_row_sql,
            .file_snapshot => tools.search_snapshot_row_sql,
            else => continue,
        };
        try ctx.db.query(ha, sql, &.{.{ .int = hit.source_id }}, &rowctx, HitRowCtx.on);
        const cols = rowctx.row orelse continue;
        if (cols.len < 5) continue;
        try tools.writeSearchHit(&w, first, .{
            .kind = hit.kind.name(),
            .source_id = hit.source_id,
            .repo_id = cols[0].asInt() orelse 0,
            .repo_name = cols[1].asText(),
            .title = cols[2].asText(),
            .snippet = tools.excerpt(cols[3].asText(), 240),
            .occurred_at = cols[4].asInt() orelse 0,
            .score = hit.score,
        });
        first = false;
    }
    try tools.endList(&w);
    return true;
}

// ------------------------------------------------------------- HTTP loop

const default_port: u16 = 39_017;
const port_scan_count: u16 = 32;

fn writeEndpointFile(io: std.Io, path: []const u8, port: u16) !void {
    var buf: [128]u8 = undefined;
    const json = try std.fmt.bufPrint(&buf, "{{\"port\":{d},\"pid\":{d}}}", .{ port, std.c.getpid() });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = json });
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    // ---- args (Zig 0.16: via the process Init) ----
    const args = try init.minimal.args.toSlice(arena);

    var db_path: ?[:0]const u8 = null;
    var endpoint_path: ?[]const u8 = null;
    var want_port: u16 = default_port;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--db") and i + 1 < args.len) {
            i += 1;
            db_path = args[i];
        } else if (std.mem.eql(u8, a, "--endpoint") and i + 1 < args.len) {
            i += 1;
            endpoint_path = args[i];
        } else if (std.mem.eql(u8, a, "--port") and i + 1 < args.len) {
            i += 1;
            want_port = std.fmt.parseInt(u16, args[i], 10) catch default_port;
        }
    }

    const dbp = db_path orelse {
        std.debug.print("blocks-mcp: --db <path> is required\n", .{});
        return error.MissingDbPath;
    };

    // Default endpoint file lives next to the db.
    var endpoint_buf: [std.fs.max_path_bytes]u8 = undefined;
    const endpoint = endpoint_path orelse blk: {
        const dir = std.fs.path.dirname(dbp) orelse ".";
        break :blk try std.fmt.bufPrint(&endpoint_buf, "{s}/mcp-endpoint.json", .{dir});
    };

    // ---- open db (read-only) ----
    var db = Db.openReadOnly(dbp) catch {
        std.debug.print("blocks-mcp: cannot open db at {s}\n", .{dbp});
        return error.OpenFailed;
    };
    defer db.close();
    var ctx = Context{ .db = &db };

    // ---- bind a loopback port (scan a small range on conflict) ----
    var server: net.Server = undefined;
    var bound_port: u16 = 0;
    var p: u16 = want_port;
    const end = want_port + port_scan_count;
    while (p < end) : (p += 1) {
        const addr = net.IpAddress.parseIp4("127.0.0.1", p) catch unreachable;
        server = net.IpAddress.listen(&addr, io, .{ .reuse_address = true }) catch continue;
        bound_port = p;
        break;
    }
    if (bound_port == 0) {
        std.debug.print("blocks-mcp: no free loopback port in [{d},{d})\n", .{ want_port, end });
        return error.NoFreePort;
    }
    defer server.deinit(io);

    // Publish the endpoint so the parent can fetch us.
    try writeEndpointFile(io, endpoint, bound_port);
    std.debug.print("blocks-mcp: listening on 127.0.0.1:{d}, db={s}\n", .{ bound_port, dbp });

    // ---- accept loop ----
    var recv_buf: [64 * 1024]u8 = undefined;
    var send_buf: [64 * 1024]u8 = undefined;
    while (true) {
        var stream = server.accept(io) catch |err| {
            std.debug.print("blocks-mcp: accept error {t}\n", .{err});
            continue;
        };
        handleConnection(&ctx, io, &stream, &recv_buf, &send_buf, gpa) catch {};
        stream.close(io);
    }
}

fn handleConnection(
    ctx: *Context,
    io: std.Io,
    stream: *net.Stream,
    recv_buf: []u8,
    send_buf: []u8,
    gpa: std.mem.Allocator,
) !void {
    var reader = stream.reader(io, recv_buf);
    var writer = stream.writer(io, send_buf);
    var server = http.Server.init(&reader.interface, &writer.interface);

    while (server.reader.state == .ready) {
        var request = server.receiveHead() catch return;

        // Only POST carries JSON-RPC; a GET (SSE stream) is not supported
        // in v1 — reply 405 so a client falls back to POST.
        if (request.head.method != .POST) {
            request.respond("", .{ .status = .method_not_allowed, .keep_alive = false }) catch return;
            return;
        }

        // One arena per request: it backs both the response buffer growth
        // and all JSON parsing scratch, freed in one shot below.
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        // Read the request body.
        var body_buf: [256 * 1024]u8 = undefined;
        const body_reader = request.readerExpectContinue(&body_buf) catch return;
        const body = body_reader.allocRemaining(arena, .limited(1024 * 1024)) catch return;

        // The response JSON is grown and read from `arena` (never gpa), so
        // the JSON writer's allocator and the buffer's allocator match.
        var out: std.ArrayList(u8) = .empty;

        const has_reply = handleRpc(ctx, arena, body, &out) catch {
            request.respond("", .{ .status = .internal_server_error, .keep_alive = false }) catch return;
            return;
        };

        if (!has_reply) {
            // Notification: 202 Accepted with no body (MCP allows this).
            request.respond("", .{ .status = .accepted }) catch return;
        } else {
            request.respond(out.items, .{
                .status = .ok,
                .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
            }) catch return;
        }
    }
}
