//! Blocks for Developers — app core (Zig).
//!
//! Task 1 scope: the Model/Msg/update loop, `~/blocks` bootstrap, and OS
//! username detection. The window renders a minimal shell; the real
//! screens (welcome, chat, materials, settings) arrive in later tasks.
//!
//! Boot sequence (init_fx):
//!   1. Resolve `~/blocks` paths from $HOME and detect the username.
//!   2. `statFile(config.json)` to learn if this is a first run.
//!   3. On miss, write default config + models/.keep to materialize the
//!      directory tree (writeFile creates missing parents).

const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");

const config = @import("config.zig");
const env = @import("env.zig");
const bootstrap = @import("bootstrap.zig");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const geometry = native_sdk.geometry;
const canvas_label = "main-canvas";
const window_width: f32 = 1024;
const window_height: f32 = 680;

const app_version = "0.1.0";

// A process-lifetime arena for resolved paths + username. These outlive
// every update call and are read by effects and the view.
var boot_arena: std.heap.ArenaAllocator = undefined;
var boot_paths: ?config.Paths = null;
var boot_username: []const u8 = "developer";

// Effect keys (spawn/fetch/file share one key space).
const key_stat_config: u64 = 100;
const key_write_config: u64 = 101;
const key_write_keep: u64 = 102;

const app_permissions = [_][]const u8{
    native_sdk.security.permission_command,
    native_sdk.security.permission_view,
    "filesystem",
    "network",
};
const shell_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "Blocks canvas", .accessibility_label = "Blocks for Developers", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "Blocks for Developers",
    .width = window_width,
    .height = window_height,
    .titlebar = .hidden_inset,
    .close_policy = .hide,
    .views = &shell_views,
}};
const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

// ------------------------------------------------------------------ model

/// Which onboarding/app stage the UI is in. Task 1 only distinguishes
/// "still booting" from "ready"; later tasks add welcome/chat/materials.
pub const Stage = enum { booting, ready };

pub const Model = struct {
    stage: Stage = .booting,
    /// True once bootstrap has confirmed (or created) `~/blocks`.
    data_dir_ready: bool = false,
    /// True when the config file already existed at boot (returning user).
    onboarded: bool = false,
    /// Detected OS username, shown next to the avatar. Borrowed from the
    /// process-lifetime boot arena.
    username: []const u8 = "developer",
    /// Absolute `~/blocks` root, for display/diagnostics. Borrowed.
    root_path: []const u8 = "",

    pub fn usernameText(self: *const Model) []const u8 {
        return self.username;
    }
    pub fn rootText(self: *const Model) []const u8 {
        return self.root_path;
    }
    pub fn statusText(self: *const Model) []const u8 {
        return switch (self.stage) {
            .booting => "Starting Blocks…",
            .ready => if (self.onboarded) "Ready" else "Welcome — let's get set up",
        };
    }
};

pub const Msg = union(enum) {
    stat_config: native_sdk.EffectFileResult,
    wrote_config: native_sdk.EffectFileResult,
    wrote_keep: native_sdk.EffectFileResult,

    pub const view_unbound = .{ "stat_config", "wrote_config", "wrote_keep" };
};

pub const Effects = native_sdk.Effects(Msg);

/// Write the two anchor files that materialize `~/blocks`. Called on a
/// first run (config absent).
fn writeAnchors(model: *const Model, fx: *Effects) void {
    const paths = boot_paths orelse return;
    const arena = boot_arena.allocator();

    const cfg = bootstrap.defaultConfigJson(arena, model.username, app_version) catch return;
    fx.writeFile(.{
        .key = key_write_config,
        .path = paths.config,
        .bytes = cfg,
        .on_result = Effects.fileMsg(.wrote_config),
    });

    const keep_path = bootstrap.modelsKeepPath(arena, paths) catch return;
    fx.writeFile(.{
        .key = key_write_keep,
        .path = keep_path,
        .bytes = bootstrap.models_keep_contents,
        .on_result = Effects.fileMsg(.wrote_keep),
    });
}

pub fn initFx(model: *Model, fx: *Effects) void {
    // Resolve home + username from the real environment.
    const home = config.detectHome(env.lookup) orelse "";
    model.username = boot_username;
    if (home.len > 0) {
        const paths = config.Paths.resolve(boot_arena.allocator(), home) catch {
            // Without a home dir we cannot bootstrap; stay in booting and
            // surface it. (macOS GUI apps always have HOME in practice.)
            return;
        };
        boot_paths = paths;
        model.root_path = paths.root;

        // Learn whether this is a first run by stat-ing the config file.
        fx.statFile(.{
            .key = key_stat_config,
            .path = paths.config,
            .on_result = Effects.fileMsg(.stat_config),
        });
    }
}

pub fn update(model: *Model, msg: Msg, fx: *Effects) void {
    switch (msg) {
        .stat_config => |res| {
            if (res.outcome == .ok and res.exists) {
                // Returning user: config already present.
                model.onboarded = true;
                model.data_dir_ready = true;
                model.stage = .ready;
            } else {
                // First run: create the directory tree + default config.
                writeAnchors(model, fx);
            }
        },
        .wrote_config => |res| {
            if (res.outcome == .ok) {
                model.data_dir_ready = true;
                model.onboarded = false;
                model.stage = .ready;
            }
        },
        .wrote_keep => {
            // Directory anchor created; no state change needed. Kept as a
            // distinct arm so a future models UI can react to it.
        },
    }
}

// ------------------------------------------------------------------- view

pub const AppUi = native_sdk.canvas.Ui(Msg);
pub const app_markup = @embedFile("app.native");

const BlocksApp = native_sdk.UiApp(Model, Msg);

pub fn initialModel() Model {
    return .{ .username = boot_username };
}

pub fn main(init: std.process.Init) !void {
    boot_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    // Detect the username once, up front, from the real environment.
    const home = config.detectHome(env.lookup);
    boot_username = config.detectUsername(env.lookup, home);

    const app_state = try BlocksApp.create(std.heap.page_allocator, .{
        .name = "blocks",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .update_fx = update,
        .init_fx = initFx,
        .markup = .{ .source = app_markup, .watch_path = "src/app.native", .io = init.io },
    });
    defer app_state.destroy();
    app_state.model = initialModel();

    try runner.runWithOptions(app_state.app(), .{
        .app_name = "blocks",
        .window_title = "Blocks for Developers",
        .bundle_id = "dev.blocks.app",
        .icon_path = "assets/icon.png",
        .default_frame = geometry.RectF.init(0, 0, window_width, window_height),
        .js_window_api = false,
        .security = .{
            .permissions = &app_permissions,
            .navigation = .{ .allowed_origins = &.{ "zero://inline", "zero://app" } },
        },
    }, init);
}

test {
    _ = @import("tests.zig");
}
