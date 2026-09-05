//! Pure configuration + path layout for Blocks. Everything here is a
//! plain function of its inputs (home dir, username, env lookups) so it
//! is unit-testable without touching the OS. The effectful bootstrap
//! (creating directories, reading the real environment) lives in
//! bootstrap.zig and calls into these helpers.

const std = @import("std");

/// The app's data lives in `~/blocks`, per the product spec (NOT the OS
/// app-data dir). These are the subpaths under that root.
pub const dir_root = "blocks";
pub const dir_models = "models";
pub const dir_db_file = "blocks.db";
pub const dir_config_file = "config.json";

/// The resolved absolute paths for this install, all rooted at
/// `<home>/blocks`. Backed by a caller-owned buffer arena (an
/// ArenaAllocator or the app's page allocator) so the strings live as
/// long as the app.
pub const Paths = struct {
    /// `<home>/blocks`
    root: []const u8,
    /// `<home>/blocks/models`
    models: []const u8,
    /// `<home>/blocks/blocks.db`
    db: []const u8,
    /// `<home>/blocks/config.json`
    config: []const u8,

    /// Build the path set from a home directory. Allocates the joined
    /// strings from `allocator`; the caller owns them.
    pub fn resolve(allocator: std.mem.Allocator, home: []const u8) !Paths {
        const root = try joinPath(allocator, home, dir_root);
        return .{
            .root = root,
            .models = try joinPath(allocator, root, dir_models),
            .db = try joinPath(allocator, root, dir_db_file),
            .config = try joinPath(allocator, root, dir_config_file),
        };
    }
};

/// Join two path segments with a single '/' separator (macOS/POSIX).
/// Trailing separators on `base` are collapsed so joining is idempotent.
pub fn joinPath(allocator: std.mem.Allocator, base: []const u8, child: []const u8) ![]const u8 {
    var end = base.len;
    while (end > 0 and base[end - 1] == '/') end -= 1;
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ base[0..end], child });
}

/// The display name shown next to the avatar in the chat/materials
/// screens, detected from the OS account. Precedence mirrors what a
/// login shell exposes on macOS:
///   1. `USER`   (set by every interactive shell)
///   2. `LOGNAME` (POSIX fallback)
///   3. the trailing component of `HOME` (e.g. /Users/rui -> "rui")
///   4. "developer" as a last resort so the UI never shows blank
///
/// `lookup` is an env accessor (real env in the app, a fixed map in
/// tests), keeping this function pure and testable.
pub fn detectUsername(
    lookup: *const fn (name: []const u8) ?[]const u8,
    home: ?[]const u8,
) []const u8 {
    if (nonEmpty(lookup("USER"))) |u| return u;
    if (nonEmpty(lookup("LOGNAME"))) |u| return u;
    if (nonEmpty(home)) |h| {
        if (basename(h)) |b| return b;
    }
    return "developer";
}

/// Resolve the home directory: `HOME` env, else empty (the caller
/// decides how to handle a missing home; in practice macOS always sets
/// HOME for a GUI app).
pub fn detectHome(lookup: *const fn (name: []const u8) ?[]const u8) ?[]const u8 {
    return nonEmpty(lookup("HOME"));
}

fn nonEmpty(value: ?[]const u8) ?[]const u8 {
    const v = value orelse return null;
    return if (v.len == 0) null else v;
}

/// Trailing path component of `path` (no allocation). Returns null for a
/// path that is only separators.
fn basename(path: []const u8) ?[]const u8 {
    var end = path.len;
    while (end > 0 and path[end - 1] == '/') end -= 1;
    if (end == 0) return null;
    var start = end;
    while (start > 0 and path[start - 1] != '/') start -= 1;
    return path[start..end];
}

// --------------------------------------------------------------- tests

const testing = std.testing;

// A tiny env stub for the pure detection tests.
const EnvStub = struct {
    var user: ?[]const u8 = null;
    var logname: ?[]const u8 = null;
    var home: ?[]const u8 = null;

    fn reset() void {
        user = null;
        logname = null;
        home = null;
    }
    fn lookup(name: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, name, "USER")) return user;
        if (std.mem.eql(u8, name, "LOGNAME")) return logname;
        if (std.mem.eql(u8, name, "HOME")) return home;
        return null;
    }
};

test "joinPath joins with a single separator and collapses trailing slashes" {
    const a = testing.allocator;
    const p1 = try joinPath(a, "/Users/rui", "blocks");
    defer a.free(p1);
    try testing.expectEqualStrings("/Users/rui/blocks", p1);

    const p2 = try joinPath(a, "/Users/rui/", "blocks");
    defer a.free(p2);
    try testing.expectEqualStrings("/Users/rui/blocks", p2);
}

test "Paths.resolve builds the full ~/blocks layout" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const paths = try Paths.resolve(arena.allocator(), "/Users/rui");
    try testing.expectEqualStrings("/Users/rui/blocks", paths.root);
    try testing.expectEqualStrings("/Users/rui/blocks/models", paths.models);
    try testing.expectEqualStrings("/Users/rui/blocks/blocks.db", paths.db);
    try testing.expectEqualStrings("/Users/rui/blocks/config.json", paths.config);
}

test "detectUsername prefers USER, then LOGNAME, then HOME basename, then fallback" {
    EnvStub.reset();
    EnvStub.user = "rui";
    try testing.expectEqualStrings("rui", detectUsername(EnvStub.lookup, "/Users/rui"));

    EnvStub.reset();
    EnvStub.logname = "logrui";
    try testing.expectEqualStrings("logrui", detectUsername(EnvStub.lookup, "/Users/whatever"));

    EnvStub.reset();
    EnvStub.home = "/Users/homerui";
    try testing.expectEqualStrings("homerui", detectUsername(EnvStub.lookup, "/Users/homerui"));

    EnvStub.reset();
    try testing.expectEqualStrings("developer", detectUsername(EnvStub.lookup, null));
}

test "detectUsername ignores empty env values" {
    EnvStub.reset();
    EnvStub.user = "";
    EnvStub.logname = "fallbackname";
    try testing.expectEqualStrings("fallbackname", detectUsername(EnvStub.lookup, "/Users/x"));
}

test "detectHome reads HOME and rejects empty" {
    EnvStub.reset();
    EnvStub.home = "/Users/rui";
    try testing.expectEqualStrings("/Users/rui", detectHome(EnvStub.lookup).?);

    EnvStub.reset();
    EnvStub.home = "";
    try testing.expect(detectHome(EnvStub.lookup) == null);
}
