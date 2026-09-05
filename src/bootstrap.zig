//! First-run bootstrap of the `~/blocks` data directory.
//!
//! The SDK has no dedicated `mkdir` effect, but `writeFile` creates any
//! missing parent directories (verified in the spike). So we materialize
//! the layout by writing two anchor files:
//!   - `~/blocks/config.json`     (creates `~/blocks/`)
//!   - `~/blocks/models/.keep`    (creates `~/blocks/models/`)
//!
//! Writes are idempotent-by-intent: we only write the config when it is
//! absent (checked via `statFile`), so re-running never clobbers user
//! settings. The `.keep` marker is safe to rewrite.
//!
//! This module keeps the *content* (default config JSON) and the
//! *decision* (write-or-skip) pure and testable; the effect firing is a
//! thin wrapper the app calls from `init_fx` / a boot Msg.

const std = @import("std");
const config = @import("config.zig");

pub const models_keep_rel = config.dir_models ++ "/.keep";
pub const models_keep_contents =
    "This directory holds locally-downloaded GGUF models for Blocks.\n";

/// The default config written on first run. `username` is the detected
/// OS account name shown in the UI. Kept minimal for v1; later tasks
/// extend the schema (selected model, MCP port, etc.).
pub fn defaultConfigJson(
    allocator: std.mem.Allocator,
    username: []const u8,
    app_version: []const u8,
) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\{{
        \\  "version": "{s}",
        \\  "username": "{s}",
        \\  "onboarded": false
        \\}}
        \\
    , .{ app_version, username });
}

/// Absolute path of the models `.keep` anchor for a resolved layout.
pub fn modelsKeepPath(allocator: std.mem.Allocator, paths: config.Paths) ![]const u8 {
    return config.joinPath(allocator, paths.models, ".keep");
}

// --------------------------------------------------------------- tests

const testing = std.testing;

test "defaultConfigJson embeds username and version and marks not-onboarded" {
    const a = testing.allocator;
    const json = try defaultConfigJson(a, "rui", "0.1.0");
    defer a.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"username\": \"rui\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"version\": \"0.1.0\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"onboarded\": false") != null);
}

test "modelsKeepPath sits under <root>/models" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const paths = try config.Paths.resolve(arena.allocator(), "/Users/rui");
    const keep = try modelsKeepPath(arena.allocator(), paths);
    try testing.expectEqualStrings("/Users/rui/blocks/models/.keep", keep);
}
