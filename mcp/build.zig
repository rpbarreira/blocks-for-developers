//! Standalone build for the Blocks MCP server sidecar (Task 8).
//!
//! The MCP server runs as a SPAWNED CHILD PROCESS of the app, opens the
//! app's `app.db` via the system libsqlite3, and serves the memory tools
//! over HTTP/JSON-RPC on loopback. It is a plain Zig executable with NO
//! dependency on the Native SDK, so it builds with ordinary `zig build`
//! (kept OUT of the SDK's generated/ejected build graph on purpose):
//!
//!     zig build --build-file mcp/build.zig            # debug
//!     zig build --build-file mcp/build.zig -Doptimize=ReleaseFast
//!
//! Output: `mcp/zig-out/bin/blocks-mcp`. The app locates and spawns this
//! binary by absolute path (see main.zig).
//!
//! Root source is `../src/mcp_server.zig`; it imports only SDK-free files
//! (`mcp/protocol.zig`, `mcp/tools.zig`, `embed_core.zig`) via relative
//! paths, so no module wiring is needed beyond linking libc + libsqlite3.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    const root_module = b.createModule(.{
        .root_source_file = b.path("../src/mcp_server.zig"),
        .target = target,
        .optimize = optimize,
        // libsqlite3 ships on every macOS; we open app.db read-only via it.
        .link_libc = true,
    });
    root_module.linkSystemLibrary("sqlite3", .{});

    const exe = b.addExecutable(.{
        .name = "blocks-mcp",
        .root_module = root_module,
    });
    b.installArtifact(exe);

    // `zig build --build-file mcp/build.zig run -- --db <path>` for manual
    // verification.
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    const run_step = b.step("run", "Run the MCP server");
    run_step.dependOn(&run.step);
}
