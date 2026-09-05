//! Pure configuration + path layout for Blocks.
//!
//! DATA LOCATION: everything Blocks stores — the SQLite database, the
//! downloaded models, and the config file — lives in ONE place: the macOS
//! app-data directory, `~/Library/Application Support/<bundle_id>/`. This
//! matches where the Native SDK's engine-owned relational store (`app.db`)
//! is opened by the runner, so the whole app footprint is a single
//! backup-friendly folder. The Settings modal surfaces this path.
//!
//! The path helpers here take the resolved data dir (or the inputs to
//! resolve it) so they stay pure and unit-testable without touching the
//! OS. The effectful bootstrap (creating dirs, reading the real
//! environment) lives in bootstrap.zig / main.zig.

const std = @import("std");
const app_dirs = @import("native_sdk").app_dirs;

/// The engine-owned SQLite file the SDK runner opens inside the data dir.
pub const db_file = "app.db";
/// Subdirectory (under the data dir) holding downloaded GGUF models.
pub const dir_models = "models";
/// The app's own settings file (not the DB), under the data dir.
pub const config_file = "config.json";

/// Resolved absolute paths for this install, all rooted at the macOS
/// app-data directory. Strings are allocated from a caller-owned
/// allocator (typically a process-lifetime arena) so they live as long
/// as the app.
pub const Paths = struct {
    /// `~/Library/Application Support/<bundle_id>`
    data_dir: []const u8,
    /// `<data_dir>/app.db` (engine-owned; the runner opens this)
    db: []const u8,
    /// `<data_dir>/models`
    models: []const u8,
    /// `<data_dir>/config.json`
    config: []const u8,

    /// Resolve the path set for `bundle_id` from the environment lookup.
    /// On macOS the data dir is `<HOME>/Library/Application Support/<bundle_id>`.
    pub fn resolve(
        allocator: std.mem.Allocator,
        bundle_id: []const u8,
        lookupFn: *const fn (name: []const u8) ?[]const u8,
    ) !Paths {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const data = try app_dirs.resolveOne(
            .{ .name = bundle_id },
            app_dirs.currentPlatform(),
            envFromLookup(lookupFn),
            .data,
            &buf,
        );
        const data_owned = try allocator.dupe(u8, data);
        return .{
            .data_dir = data_owned,
            .db = try joinPath(allocator, data_owned, db_file),
            .models = try joinPath(allocator, data_owned, dir_models),
            .config = try joinPath(allocator, data_owned, config_file),
        };
    }
};

/// Build an app_dirs.Env from an env-var lookup. Only the fields the
/// macOS resolver reads (HOME) are strictly required; the rest are
/// filled for completeness / cross-platform parity later.
pub fn envFromLookup(lookupFn: *const fn (name: []const u8) ?[]const u8) app_dirs.Env {
    return .{
        .home = lookupFn("HOME"),
        .xdg_config_home = lookupFn("XDG_CONFIG_HOME"),
        .xdg_cache_home = lookupFn("XDG_CACHE_HOME"),
        .xdg_data_home = lookupFn("XDG_DATA_HOME"),
        .xdg_state_home = lookupFn("XDG_STATE_HOME"),
        .tmpdir = lookupFn("TMPDIR"),
    };
}

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
///   1. `USER`    (set by every interactive shell)
///   2. `LOGNAME` (POSIX fallback)
///   3. the trailing component of `HOME` (e.g. /Users/rui -> "rui")
///   4. "developer" as a last resort so the UI never shows blank
pub fn detectUsername(
    lookupFn: *const fn (name: []const u8) ?[]const u8,
    home: ?[]const u8,
) []const u8 {
    if (nonEmpty(lookupFn("USER"))) |u| return u;
    if (nonEmpty(lookupFn("LOGNAME"))) |u| return u;
    if (nonEmpty(home)) |h| {
        if (basename(h)) |b| return b;
    }
    return "developer";
}

/// Resolve the home directory from `HOME`, else null.
pub fn detectHome(lookupFn: *const fn (name: []const u8) ?[]const u8) ?[]const u8 {
    return nonEmpty(lookupFn("HOME"));
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
    const p1 = try joinPath(a, "/base/dir", "child");
    defer a.free(p1);
    try testing.expectEqualStrings("/base/dir/child", p1);

    const p2 = try joinPath(a, "/base/dir/", "child");
    defer a.free(p2);
    try testing.expectEqualStrings("/base/dir/child", p2);
}

test "Paths.resolve builds the app-data layout on macOS from HOME + bundle id" {
    EnvStub.reset();
    EnvStub.home = "/Users/rui";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const paths = try Paths.resolve(arena.allocator(), "dev.blocks.app", EnvStub.lookup);
    // On the host (macOS) the data dir is <HOME>/Library/Application Support/<id>.
    try testing.expectEqualStrings("/Users/rui/Library/Application Support/dev.blocks.app", paths.data_dir);
    try testing.expectEqualStrings("/Users/rui/Library/Application Support/dev.blocks.app/app.db", paths.db);
    try testing.expectEqualStrings("/Users/rui/Library/Application Support/dev.blocks.app/models", paths.models);
    try testing.expectEqualStrings("/Users/rui/Library/Application Support/dev.blocks.app/config.json", paths.config);
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
