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
    _ = @import("embeddings.zig");
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
