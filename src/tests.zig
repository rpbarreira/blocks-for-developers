const std = @import("std");
const native_sdk = @import("native_sdk");
const main = @import("main.zig");

// Pull in the pure module unit tests (config path/username logic and the
// bootstrap content/decisions).
comptime {
    _ = @import("config.zig");
    _ = @import("bootstrap.zig");
    _ = @import("env.zig");
    _ = @import("db.zig");
    _ = @import("repos.zig");
    _ = @import("git.zig");
    _ = @import("snapshots.zig");
    _ = @import("tray.zig");
    _ = @import("embed_core.zig");
    _ = @import("embeddings.zig");
    // Local model management + llama.cpp runtime (Task 9): pure catalog,
    // path/argv builders, progress + config parsing.
    _ = @import("models.zig");
    // MCP server core (Task 8): pure protocol + tool builders, plus the
    // real-DB integration tests for each tool's SQL + JSON shaping.
    _ = @import("mcp/protocol.zig");
    _ = @import("mcp/tools.zig");
    _ = @import("mcp/mcp_tools.zig");
}

const canvas = native_sdk.canvas;
const AppMarkup = canvas.MarkupView(main.Model, main.Msg);
const AppUi = main.AppUi;

fn buildTree(arena: std.mem.Allocator, model: *const main.Model) !AppUi.Tree {
    var view = try AppMarkup.init(arena, main.app_markup);
    var ui = AppUi.init(arena);
    const node = view.build(&ui, model) catch |err| {
        if (err == error.MarkupBuild) {
            std.debug.print("app.native:{d}:{d}: {s}\n", .{ view.diagnostic.line, view.diagnostic.column, view.diagnostic.message });
        }
        return err;
    };
    return ui.finalize(node);
}

test "the boot shell view builds against the model" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.Model{
        .stage = .ready,
        .username = "rui",
        .data_dir = "/Users/rui/Library/Application Support/dev.blocks.app",
        .onboarded = true,
    };
    const tree = try buildTree(arena, &model);
    // The username must appear somewhere in the rendered tree.
    var found_username = false;
    const walk = struct {
        fn f(w: canvas.Widget, hit: *bool) void {
            if (std.mem.indexOf(u8, w.text, "rui") != null) hit.* = true;
            for (w.children) |c| f(c, hit);
        }
    };
    walk.f(tree.root, &found_username);
    try std.testing.expect(found_username);
}

test "statusText reflects onboarding state" {
    var m = main.Model{ .stage = .booting };
    try std.testing.expectEqualStrings("Starting Blocks…", m.statusText());
    m.stage = .ready;
    m.onboarded = false;
    try std.testing.expectEqualStrings("Welcome — let's get set up", m.statusText());
    m.onboarded = true;
    try std.testing.expectEqualStrings("Ready", m.statusText());
}

test "update: existing config marks the user onboarded and ready" {
    var m = main.Model{};
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    // A successful stat with exists=true = returning user.
    main.update(&m, .{ .stat_config = .{ .key = 100, .op = .stat, .outcome = .ok, .exists = true } }, &fx);
    try std.testing.expect(m.onboarded);
    try std.testing.expect(m.data_dir_ready);
    try std.testing.expectEqual(main.Stage.ready, m.stage);
}

test "update: a successful config write leaves a first-run user ready but not onboarded" {
    var m = main.Model{};
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&m, .{ .wrote_config = .{ .key = 101, .op = .write, .outcome = .ok } }, &fx);
    try std.testing.expect(m.data_dir_ready);
    try std.testing.expect(!m.onboarded);
    try std.testing.expectEqual(main.Stage.ready, m.stage);
}

// ---- Tray + launch-at-login (Task 6) ----

test "update: tray Open reveals the main window" {
    var m = main.Model{};
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&m, .open_window, &fx);
    const s = fx.windowActionState();
    try std.testing.expectEqual(@as(u32, 1), s.show_count);
    try std.testing.expectEqualStrings("main", s.lastLabel());
}

test "update: tray Quit asks the app to quit" {
    var m = main.Model{};
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&m, .quit_app, &fx);
    try std.testing.expectEqual(@as(u32, 1), fx.windowActionState().quit_count);
}

test "update: login status result 'enabled' turns the toggle on" {
    var m = main.Model{};
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&m, .{ .login_status_done = .{ .key = 140, .ok = true, .bytes = "enabled" } }, &fx);
    try std.testing.expect(m.login_enabled);
    try std.testing.expect(m.login_supported);
}

test "update: login result 'disabled' turns the toggle off" {
    var m = main.Model{ .login_enabled = true };
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&m, .{ .login_set_done = .{ .key = 141, .ok = true, .bytes = "disabled" } }, &fx);
    try std.testing.expect(!m.login_enabled);
}

test "update: 'requires_approval' counts as enabled (item registered)" {
    var m = main.Model{};
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&m, .{ .login_status_done = .{ .key = 140, .ok = true, .bytes = "requires_approval" } }, &fx);
    try std.testing.expect(m.login_enabled);
}

test "update: an 'unsupported' failure disables the toggle" {
    var m = main.Model{ .login_supported = true };
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&m, .{ .login_set_done = .{ .key = 141, .ok = false, .bytes = "unsupported" } }, &fx);
    try std.testing.expect(!m.login_supported);
}

test "update: toggling login while unsupported is a no-op" {
    var m = main.Model{ .login_supported = false, .login_enabled = false };
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    // Should not flip the model or crash; the host is never asked.
    main.update(&m, .toggle_login, &fx);
    try std.testing.expect(!m.login_enabled);
}

// ---- MCP server child process (Task 8) ----

test "update: a 200 tools/list health response marks the MCP server ready" {
    var m = main.Model{};
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&m, .{ .mcp_health_done = .{ .key = 161, .outcome = .ok, .status = 200, .body = "{\"jsonrpc\":\"2.0\"}" } }, &fx);
    try std.testing.expect(m.mcp_ready);
    try std.testing.expect(!m.mcp_failed);
}

test "update: a failed health response leaves the MCP server not-ready (non-fatal)" {
    var m = main.Model{};
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    // A connection failure while the child is still binding: not ready,
    // but not marked failed either (Task 10 adds retry/backoff).
    main.update(&m, .{ .mcp_health_done = .{ .key = 161, .outcome = .rejected, .status = 0, .body = "" } }, &fx);
    try std.testing.expect(!m.mcp_ready);
}

test "update: the MCP child exiting marks it failed but does not crash" {
    var m = main.Model{ .mcp_ready = true };
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&m, .{ .mcp_exit = .{ .key = 160, .code = 1, .reason = .exited } }, &fx);
    try std.testing.expect(!m.mcp_ready);
    try std.testing.expect(m.mcp_failed);
}

test "update: a rejected health-check timer tick is ignored" {
    var m = main.Model{};
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    // A rejected timer must not fire a fetch or change state.
    main.update(&m, .{ .mcp_health_tick = .{ .key = 2, .outcome = .rejected } }, &fx);
    try std.testing.expect(!m.mcp_ready);
    try std.testing.expect(!m.mcp_failed);
}

// ---- Local model management + llama.cpp runtime (Task 9) ----

const models = @import("models.zig");

test "update: config_read_done adopts the selected model id from config" {
    var m = main.initialModel();
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    const cfg =
        \\{ "version": "0.1.0", "username": "rui", "selected_model": "qwen2.5-1.5b-instruct-q4" }
    ;
    main.update(&m, .{ .config_read_done = .{ .key = 170, .op = .read, .outcome = .ok, .bytes = cfg, .exists = true } }, &fx);
    try std.testing.expectEqualStrings("qwen2.5-1.5b-instruct-q4", m.selectedModel());
}

test "update: model_stat_done present=true marks the model present" {
    var m = main.initialModel();
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&m, .{ .model_stat_done = .{ .key = 171, .op = .stat, .outcome = .ok, .exists = true } }, &fx);
    try std.testing.expect(m.model_present);
}

test "update: model_stat_done absent leaves the model not present" {
    var m = main.initialModel();
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&m, .{ .model_stat_done = .{ .key = 171, .op = .stat, .outcome = .ok, .exists = false } }, &fx);
    try std.testing.expect(!m.model_present);
}

test "update: select_model switches the selection and marks it not present" {
    var m = main.initialModel();
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    // Pick a different catalog entry by index.
    var target: usize = 0;
    for (models.catalog, 0..) |c, i| {
        if (!std.mem.eql(u8, c.id, m.selectedModel())) {
            target = i;
            break;
        }
    }
    main.update(&m, .{ .select_model = target }, &fx);
    try std.testing.expectEqualStrings(models.catalog[target].id, m.selectedModel());
    try std.testing.expect(!m.model_present);
}

test "update: out-of-range select_model is ignored" {
    var m = main.initialModel();
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    const before = m.selectedModel();
    main.update(&m, .{ .select_model = 9999 }, &fx);
    try std.testing.expectEqualStrings(before, m.selectedModel());
}

test "update: a curl progress line updates download_progress" {
    var m = main.initialModel();
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    // key 172 is the download spawn key; a 40% bar line -> 0.40.
    main.update(&m, .{ .download_progress_line = .{ .key = 172, .line = "########            40.0%" } }, &fx);
    try std.testing.expectApproxEqAbs(@as(f32, 0.40), m.download_progress, 0.0001);
    try std.testing.expectEqual(@as(i64, 40), m.downloadPercent());
}

test "update: a failed download marks download_failed and clears downloading" {
    var m = main.initialModel();
    m.downloading = true;
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&m, .{ .download_done = .{ .key = 172, .code = 22, .reason = .exited } }, &fx);
    try std.testing.expect(!m.downloading);
    try std.testing.expect(m.download_failed);
}

test "update: a failed rename marks the download failed" {
    var m = main.initialModel();
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&m, .{ .model_renamed = .{ .key = 173, .code = 1, .reason = .exited } }, &fx);
    try std.testing.expect(m.download_failed);
    try std.testing.expect(!m.model_present);
}

test "update: a 200 llama /health response marks the runtime ready" {
    var m = main.initialModel();
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&m, .{ .llama_health_done = .{ .key = 175, .outcome = .ok, .status = 200, .body = "ok" } }, &fx);
    try std.testing.expect(m.llama_ready);
    try std.testing.expect(!m.llama_failed);
}

test "update: the llama child exiting marks the runtime failed (non-fatal)" {
    var m = main.initialModel();
    m.llama_ready = true;
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&m, .{ .llama_exit = .{ .key = 174, .code = 127, .reason = .spawn_failed } }, &fx);
    try std.testing.expect(!m.llama_ready);
    try std.testing.expect(m.llama_failed);
}

test "update: a rejected llama health tick is ignored" {
    var m = main.initialModel();
    var fx = main.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    main.update(&m, .{ .llama_health_tick = .{ .key = 3, .outcome = .rejected } }, &fx);
    try std.testing.expect(!m.llama_ready);
    try std.testing.expect(!m.llama_failed);
}
