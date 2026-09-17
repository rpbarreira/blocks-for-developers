//! MCP protocol + memory-tool core — PURE (Task 8), no SDK / no I/O.
//!
//! The MCP server (Blocks' developer-memory server) runs as a SPAWNED
//! CHILD PROCESS and speaks JSON-RPC 2.0 over HTTP (Streamable HTTP: a
//! POST carries one request, the response body is the JSON-RPC reply).
//! The v1 consumer is the app's own local LLM over `127.0.0.1`.
//!
//! This module is the pure, deterministic heart of that server:
//!   * JSON-RPC envelope parsing (id + method + params) and response
//!     rendering (result / error), spec-correct escaping.
//!   * The MCP lifecycle payloads (`initialize`, `tools/list`).
//!   * The three memory tools — `search_memory`, `get_activity`,
//!     `get_commits` — as (a) SQL builders and (b) row -> JSON shapers.
//!
//! It imports NOTHING effectful and NOTHING from the SDK, so the exact
//! same logic is exercised by `native test` (via a thin adapter in
//! tests.zig / mcp_tools.zig) and compiled into the standalone server
//! binary that links libsqlite3 directly. Ranking of vector hits reuses
//! `embeddings.zig` (also pure) in the tools layer, not here.

const std = @import("std");

/// MCP protocol revision this server advertises. A stable, widely
/// supported revision; the client echoes a version and we simply return
/// ours (no negotiation handshake in MCP — each side states its version).
pub const protocol_version = "2025-06-18";

pub const server_name = "blocks-memory";
pub const server_version = "0.1.0";

// --------------------------------------------------------- JSON-RPC ids

/// A JSON-RPC id is either a number or a string (or absent, for a
/// notification). We preserve which so the reply echoes it verbatim.
pub const Id = union(enum) {
    none,
    number: i64,
    string: []const u8,

    /// Render the id as it must appear in a response (`"id": <here>`).
    /// A `none` id (notification) renders as JSON null, which is what the
    /// spec uses when an error cannot be tied to a request id.
    pub fn writeJson(self: Id, w: *JsonWriter) !void {
        switch (self) {
            .none => try w.raw("null"),
            .number => |n| try w.number(n),
            .string => |s| try w.string(s),
        }
    }
};

/// A parsed JSON-RPC request: method + the raw params object + the id.
/// `params_json` borrows from the input buffer (valid while it lives).
pub const Request = struct {
    id: Id = .none,
    method: []const u8 = "",
    /// The raw `params` value as a JSON slice ("{}" when absent), so the
    /// tools layer can parse only what it needs.
    params_json: []const u8 = "{}",
};

pub const ParseError = error{ InvalidJson, NotAnObject, MissingMethod };

/// Parse a single JSON-RPC request object from `body`. Uses a scanning
/// parser (no allocation for the envelope): we only need `id`, `method`,
/// and the raw `params` span. `arena` is used solely to hold a decoded
/// string id / method (short-lived, freed by the caller's arena).
pub fn parseRequest(arena: std.mem.Allocator, body: []const u8) ParseError!Request {
    var parsed = std.json.parseFromSlice(std.json.Value, arena, body, .{}) catch
        return error.InvalidJson;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.NotAnObject;
    const obj = root.object;

    var req = Request{};

    if (obj.get("method")) |m| {
        if (m == .string) req.method = arena.dupe(u8, m.string) catch return error.InvalidJson;
    }
    if (req.method.len == 0) return error.MissingMethod;

    if (obj.get("id")) |idv| {
        req.id = switch (idv) {
            .integer => |n| .{ .number = n },
            .float => |f| .{ .number = @intFromFloat(f) },
            .string => |s| .{ .string = arena.dupe(u8, s) catch return error.InvalidJson },
            else => .none,
        };
    }

    if (obj.get("params")) |p| {
        // Re-stringify the params value so the tools layer can re-parse
        // just its fields. Small objects; arena-backed.
        req.params_json = std.json.Stringify.valueAlloc(arena, p, .{}) catch return error.InvalidJson;
    }

    return req;
}

/// Whether a method is a notification we simply acknowledge with no reply
/// (e.g. `notifications/initialized`). Notifications have no `id`.
pub fn isNotification(method: []const u8) bool {
    return std.mem.startsWith(u8, method, "notifications/");
}

// --------------------------------------------------------- JSON writer

/// Minimal, allocation-light JSON writer over a caller-provided
/// `std.ArrayList(u8)`. It gives us exact control over escaping and field
/// order, and works identically in the SDK build and the standalone
/// binary (no dependency on a specific std.json encoder shape).
pub const JsonWriter = struct {
    out: *std.ArrayList(u8),
    alloc: std.mem.Allocator,

    pub fn init(out: *std.ArrayList(u8), alloc: std.mem.Allocator) JsonWriter {
        return .{ .out = out, .alloc = alloc };
    }

    pub fn raw(self: *JsonWriter, s: []const u8) !void {
        try self.out.appendSlice(self.alloc, s);
    }

    pub fn number(self: *JsonWriter, n: i64) !void {
        var buf: [24]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch unreachable;
        try self.raw(s);
    }

    /// Write a JSON string literal with proper escaping.
    pub fn string(self: *JsonWriter, s: []const u8) !void {
        try self.out.append(self.alloc, '"');
        for (s) |c| {
            switch (c) {
                '"' => try self.raw("\\\""),
                '\\' => try self.raw("\\\\"),
                '\n' => try self.raw("\\n"),
                '\r' => try self.raw("\\r"),
                '\t' => try self.raw("\\t"),
                0x08 => try self.raw("\\b"),
                0x0c => try self.raw("\\f"),
                else => {
                    if (c < 0x20) {
                        var b: [6]u8 = undefined;
                        const e = std.fmt.bufPrint(&b, "\\u{x:0>4}", .{c}) catch unreachable;
                        try self.raw(e);
                    } else {
                        try self.out.append(self.alloc, c);
                    }
                },
            }
        }
        try self.out.append(self.alloc, '"');
    }

    /// Write `"key":` (the caller writes the value next).
    pub fn key(self: *JsonWriter, k: []const u8) !void {
        try self.string(k);
        try self.raw(":");
    }
};

// --------------------------------------------------- JSON-RPC responses

/// JSON-RPC 2.0 error codes we use.
pub const err_parse: i64 = -32700;
pub const err_invalid_request: i64 = -32600;
pub const err_method_not_found: i64 = -32601;
pub const err_invalid_params: i64 = -32602;
pub const err_internal: i64 = -32603;

/// Begin a JSON-RPC response envelope: `{"jsonrpc":"2.0","id":<id>,`.
/// The caller appends either `"result":<...>}` (via `finishResult`) or an
/// error (via `writeError`). Kept as two calls so results can stream the
/// body straight into `out` without an intermediate buffer.
pub fn beginResponse(w: *JsonWriter, id: Id) !void {
    try w.raw("{\"jsonrpc\":\"2.0\",");
    try w.key("id");
    try id.writeJson(w);
    try w.raw(",");
}

/// Finish a response whose `result` body has already been written after a
/// `"result":` key. (Convenience for callers that build result inline.)
pub fn closeObject(w: *JsonWriter) !void {
    try w.raw("}");
}

/// Write a complete JSON-RPC error response into `out`.
pub fn writeError(out: *std.ArrayList(u8), alloc: std.mem.Allocator, id: Id, code: i64, message: []const u8) !void {
    var w = JsonWriter.init(out, alloc);
    try beginResponse(&w, id);
    try w.key("error");
    try w.raw("{");
    try w.key("code");
    try w.number(code);
    try w.raw(",");
    try w.key("message");
    try w.string(message);
    try w.raw("}}");
}

// --------------------------------------------------- lifecycle payloads

/// Write the `initialize` result: our protocol version, capabilities
/// (tools only for v1), and server info.
pub fn writeInitializeResult(out: *std.ArrayList(u8), alloc: std.mem.Allocator, id: Id) !void {
    var w = JsonWriter.init(out, alloc);
    try beginResponse(&w, id);
    try w.key("result");
    try w.raw("{");
    try w.key("protocolVersion");
    try w.string(protocol_version);
    try w.raw(",");
    try w.key("capabilities");
    try w.raw("{\"tools\":{\"listChanged\":false}},");
    try w.key("serverInfo");
    try w.raw("{");
    try w.key("name");
    try w.string(server_name);
    try w.raw(",");
    try w.key("version");
    try w.string(server_version);
    try w.raw("}}}");
}

/// One tool's static descriptor: name, human description, and a JSON
/// Schema string for its arguments (embedded verbatim).
pub const ToolDef = struct {
    name: []const u8,
    description: []const u8,
    /// A JSON object literal for the tool's inputSchema.
    input_schema: []const u8,
};

pub const tool_search_memory = "search_memory";
pub const tool_get_activity = "get_activity";
pub const tool_get_commits = "get_commits";

/// The three memory tools exposed to the model. Input schemas are minimal
/// but honest (types + which are required), matching the query builders.
pub const tools = [_]ToolDef{
    .{
        .name = tool_search_memory,
        .description = "Search the developer's memory (git commits + working-tree file snapshots) by meaning and keyword. Returns the most relevant items.",
        .input_schema =
        \\{"type":"object","properties":{"query":{"type":"string","description":"What to look for, in natural language or keywords."},"limit":{"type":"integer","description":"Max results (default 10, max 50)."}},"required":["query"]}
        ,
    },
    .{
        .name = tool_get_activity,
        .description = "List recent developer activity (git commits and file-change snapshots) across watched repositories, most recent first, optionally within a time range.",
        .input_schema =
        \\{"type":"object","properties":{"since_ms":{"type":"integer","description":"Only items at or after this Unix-ms time."},"until_ms":{"type":"integer","description":"Only items at or before this Unix-ms time."},"limit":{"type":"integer","description":"Max items (default 20, max 100)."}}}
        ,
    },
    .{
        .name = tool_get_commits,
        .description = "List git commits from watched repositories, most recent first, optionally filtered to one repository.",
        .input_schema =
        \\{"type":"object","properties":{"repo_id":{"type":"integer","description":"Restrict to this watched repository id."},"limit":{"type":"integer","description":"Max commits (default 20, max 100)."}}}
        ,
    },
};

pub fn findTool(name: []const u8) ?ToolDef {
    for (tools) |t| {
        if (std.mem.eql(u8, t.name, name)) return t;
    }
    return null;
}

/// Write the `tools/list` result (the tool descriptors above).
pub fn writeToolsListResult(out: *std.ArrayList(u8), alloc: std.mem.Allocator, id: Id) !void {
    var w = JsonWriter.init(out, alloc);
    try beginResponse(&w, id);
    try w.key("result");
    try w.raw("{\"tools\":[");
    for (tools, 0..) |t, i| {
        if (i > 0) try w.raw(",");
        try w.raw("{");
        try w.key("name");
        try w.string(t.name);
        try w.raw(",");
        try w.key("description");
        try w.string(t.description);
        try w.raw(",");
        try w.key("inputSchema");
        try w.raw(t.input_schema); // already a JSON object literal
        try w.raw("}");
    }
    try w.raw("]}}");
}

/// Wrap an already-built text payload as a `tools/call` result:
/// `{"result":{"content":[{"type":"text","text":<text>}],"isError":<b>}}`.
/// `text` is the tool's textual output (we return JSON-as-text so the
/// model gets structured, parseable results).
pub fn writeToolResult(out: *std.ArrayList(u8), alloc: std.mem.Allocator, id: Id, text: []const u8, is_error: bool) !void {
    var w = JsonWriter.init(out, alloc);
    try beginResponse(&w, id);
    try w.key("result");
    try w.raw("{\"content\":[{\"type\":\"text\",");
    try w.key("text");
    try w.string(text);
    try w.raw("}],");
    try w.key("isError");
    try w.raw(if (is_error) "true" else "false");
    try w.raw("}}");
}

// --------------------------------------------------------------- tests

const testing = std.testing;

test "parseRequest extracts method, numeric id, and raw params" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const req = try parseRequest(arena.allocator(),
        \\{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"get_commits","arguments":{"limit":5}}}
    );
    try testing.expectEqualStrings("tools/call", req.method);
    try testing.expectEqual(@as(i64, 7), req.id.number);
    try testing.expect(std.mem.indexOf(u8, req.params_json, "get_commits") != null);
}

test "parseRequest handles string id and absent params" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const req = try parseRequest(arena.allocator(),
        \\{"jsonrpc":"2.0","id":"abc","method":"initialize"}
    );
    try testing.expectEqualStrings("initialize", req.method);
    try testing.expectEqualStrings("abc", req.id.string);
    try testing.expectEqualStrings("{}", req.params_json);
}

test "parseRequest rejects non-object and missing method" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.NotAnObject, parseRequest(arena.allocator(), "[1,2,3]"));
    try testing.expectError(error.MissingMethod, parseRequest(arena.allocator(),
        \\{"jsonrpc":"2.0","id":1}
    ));
    try testing.expectError(error.InvalidJson, parseRequest(arena.allocator(), "{not json"));
}

test "isNotification recognizes the initialized notification" {
    try testing.expect(isNotification("notifications/initialized"));
    try testing.expect(!isNotification("tools/call"));
}

test "JsonWriter escapes control chars and quotes" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    var w = JsonWriter.init(&out, testing.allocator);
    try w.string("a\"b\\c\nd\te");
    try testing.expectEqualStrings("\"a\\\"b\\\\c\\nd\\te\"", out.items);
}

test "writeError builds a spec-shaped error envelope" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try writeError(&out, testing.allocator, .{ .number = 3 }, err_method_not_found, "no such method");
    try testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":3,"error":{"code":-32601,"message":"no such method"}}
    , out.items);
}

test "writeInitializeResult advertises version, tools capability, server info" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try writeInitializeResult(&out, testing.allocator, .{ .number = 1 });
    try testing.expect(std.mem.indexOf(u8, out.items, "\"protocolVersion\":\"2025-06-18\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"tools\":{\"listChanged\":false}") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"name\":\"blocks-memory\"") != null);
}

test "writeToolsListResult lists all three tools with schemas" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try writeToolsListResult(&out, testing.allocator, .{ .number = 2 });
    try testing.expect(std.mem.indexOf(u8, out.items, tool_search_memory) != null);
    try testing.expect(std.mem.indexOf(u8, out.items, tool_get_activity) != null);
    try testing.expect(std.mem.indexOf(u8, out.items, tool_get_commits) != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"inputSchema\":{") != null);
    // The result must be valid JSON.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), out.items, .{});
    defer parsed.deinit();
}

test "writeToolResult wraps text content and error flag" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try writeToolResult(&out, testing.allocator, .{ .number = 9 }, "{\"commits\":[]}", false);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"type\":\"text\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"isError\":false") != null);
    // Nested JSON is escaped as a string, so the envelope stays valid JSON.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), out.items, .{});
    defer parsed.deinit();
}

test "findTool resolves known tools and rejects unknown" {
    try testing.expect(findTool(tool_search_memory) != null);
    try testing.expect(findTool("bogus") == null);
}
