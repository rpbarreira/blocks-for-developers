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
const db = @import("db.zig");
const repos = @import("repos.zig");
const git = @import("git.zig");
const snapshots = @import("snapshots.zig");
const tray = @import("tray.zig");

const canvas = native_sdk.canvas;

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const geometry = native_sdk.geometry;
const canvas_label = "main-canvas";
const window_width: f32 = 1024;
const window_height: f32 = 680;

const app_version = "0.1.0";
/// Must match app.json `id` and the runner's `bundle_id` below so our
/// resolved data dir points at the same folder the engine-owned app.db
/// is opened in.
const bundle_id = "dev.blocks.app";

// A process-lifetime arena for resolved paths + username. These outlive
// every update call and are read by effects and the view.
var boot_arena: std.heap.ArenaAllocator = undefined;
var boot_paths: ?config.Paths = null;
var boot_username: []const u8 = "developer";

// Effect keys (spawn/fetch/file share one key space).
const key_stat_config: u64 = 100;
const key_write_config: u64 = 101;
const key_write_keep: u64 = 102;
const key_git_check: u64 = 110;
const key_repo_insert: u64 = 111;
const key_repos_list: u64 = 112;
const key_repo_delete: u64 = 113;
// Git history capture (Task 4).
const key_capture_since: u64 = 120; // query a repo's last_indexed_oid
const key_capture_log: u64 = 121; // spawn `git log` for a repo
const key_capture_write: u64 = 122; // insert events + update bookkeeping
// Working-tree file-change capture (Task 5). spawn/file keys:
const key_snap_status: u64 = 130; // spawn `git status --porcelain -z`
const key_snap_lasthash: u64 = 131; // query a file's last content_hash
const key_snap_content: u64 = 132; // readFile a changed file's content
const key_snap_diff: u64 = 133; // spawn `git diff -- <path>`
const key_snap_write: u64 = 134; // insert the snapshot row
// Launch-at-login host requests (Task 6). Share the spawn/fetch/file key space.
const key_login_status: u64 = 140; // query current launch-at-login state
const key_login_set: u64 = 141; // enable/disable launch-at-login

// Launch-at-login host-service names (see SDK effects: native host requests).
const host_login_status = "native-sdk.launch-at-login.status";
const host_login_set = "native-sdk.launch-at-login.set";

/// The window label the tray "Open Blocks" action reveals. Matches the
/// `shell_windows` entry below.
const main_window_label = "main";
// Timer keys live in their OWN namespace (never collide with the above).
const key_snap_timer: u64 = 1; // the repeating scan/debounce tick

/// How often the working-tree scan runs. This interval IS the debounce /
/// coalesce window: edits made between ticks collapse into the single
/// snapshot taken at the next tick.
const snapshot_interval_ms: u64 = 15_000;

/// Bounds for the snapshot scan (fixed inline model storage, no allocator).
const max_changed_files = 64; // changed paths tracked per repo per scan
const max_content_bytes = 256 * 1024; // skip snapshotting files larger than this
const max_diff_bytes = 256 * 1024; // stored diff cap

/// Capacity of the repo-path input field.
const path_input_capacity = repos.max_path_bytes;

/// Max commits indexed per repo in a single capture pass. If a repo has
/// more new commits than this, the bookkeeping oid advances to the last
/// one written and a later pass continues from there — so history is still
/// captured fully, just across multiple passes.
const max_commits_per_pass = 128;

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

/// A changed working-tree path copied into owned inline storage, since the
/// `git status` output bytes it came from only live during one update.
pub const ChangedPath = struct {
    buf: [repos.max_path_bytes]u8 = undefined,
    len: usize = 0,
    /// True for an untracked file (its diff is empty — git diff skips it).
    untracked: bool = false,

    pub fn path(self: *const ChangedPath) []const u8 {
        return self.buf[0..self.len];
    }
    pub fn fromChange(c: snapshots.Change) ChangedPath {
        var e = ChangedPath{ .untracked = c.isUntracked() };
        e.len = @min(c.rel_path.len, repos.max_path_bytes);
        @memcpy(e.buf[0..e.len], c.rel_path[0..e.len]);
        return e;
    }
};

pub const Model = struct {
    stage: Stage = .booting,
    /// True once bootstrap has confirmed (or created) the app-data dir.
    data_dir_ready: bool = false,
    /// True when the config file already existed at boot (returning user).
    onboarded: bool = false,
    /// Detected OS username, shown next to the avatar. Borrowed from the
    /// process-lifetime boot arena.
    username: []const u8 = "developer",
    /// Absolute app-data directory (all data lives here), shown in
    /// Settings for backup. Borrowed from the boot arena.
    data_dir: []const u8 = "",

    // ---- Watched repositories (Task 3) ----
    /// The repo-path input field buffer (model-owned inline storage).
    repo_input: canvas.TextBuffer(path_input_capacity) = .{},
    /// Loaded watched repos, refreshed from the DB after each change.
    repo_list: [repos.max_repos]repos.RepoEntry = undefined,
    repo_count: usize = 0,
    /// True while a git-validation spawn is in flight for a pending add.
    adding_repo: bool = false,
    /// Last add error, shown under the input ("" when none).
    repo_error_buf: [256]u8 = undefined,
    repo_error_len: usize = 0,
    /// The path being validated/added (held across the git-check spawn).
    pending_path_buf: [repos.max_path_bytes]u8 = undefined,
    pending_path_len: usize = 0,

    // ---- Git history capture (Task 4) ----
    /// True while a capture pass is walking the repo list.
    capturing: bool = false,
    /// Index into `repo_list` of the repo currently being captured.
    capture_idx: usize = 0,
    /// The id/path of the repo currently being captured, held across the
    /// since-query -> git-log -> insert effect chain.
    capture_repo_id: i64 = 0,
    capture_path_buf: [repos.max_path_bytes]u8 = undefined,
    capture_path_len: usize = 0,
    /// The `last_indexed_oid` we passed to `git log` for the current repo
    /// (empty = full history). Used as the fallback "last oid" if the log
    /// yields no new commits.
    capture_since_buf: [64]u8 = undefined,
    capture_since_len: usize = 0,

    // ---- Working-tree snapshot scan (Task 5) ----
    /// True while a scan pass is walking repos/files (coalesces ticks: a
    /// tick that arrives mid-scan is ignored).
    scanning: bool = false,
    /// True once the repeating scan timer has been armed.
    scan_timer_started: bool = false,
    /// Index into `repo_list` of the repo currently being scanned.
    scan_repo_idx: usize = 0,
    /// The current scan repo's id + path (held across the effect chain).
    scan_repo_id: i64 = 0,
    scan_repo_path_buf: [repos.max_path_bytes]u8 = undefined,
    scan_repo_path_len: usize = 0,
    /// Changed relative paths for the current repo (copied out of the
    /// `git status` output, which does not survive the update).
    scan_paths: [max_changed_files]ChangedPath = undefined,
    scan_path_count: usize = 0,
    /// Index of the file currently being processed within `scan_paths`.
    scan_file_idx: usize = 0,
    /// The current file's content (copied out of the readFile result so it
    /// survives the diff spawn + insert), and its computed hash.
    scan_content_buf: [max_content_bytes]u8 = undefined,
    scan_content_len: usize = 0,
    scan_hash_buf: [snapshots.hash_hex_len]u8 = undefined,
    /// The last stored hash for the current file ("" when never stored).
    scan_last_hash_buf: [snapshots.hash_hex_len]u8 = undefined,
    scan_last_hash_len: usize = 0,

    // ---- Tray + launch-at-login (Task 6) ----
    /// Whether "start at login" is currently enabled (drives the tray
    /// toggle's check mark). Learned from the host on boot.
    login_enabled: bool = false,
    /// Whether the platform/build supports launch-at-login at all. When
    /// false the tray toggle is shown disabled. Assume supported until the
    /// host says otherwise (a `.set`/`.status` "unsupported" result).
    login_supported: bool = true,

    pub fn capturePath(self: *const Model) []const u8 {
        return self.capture_path_buf[0..self.capture_path_len];
    }
    fn setCapturePath(self: *Model, p: []const u8) void {
        self.capture_path_len = @min(p.len, self.capture_path_buf.len);
        @memcpy(self.capture_path_buf[0..self.capture_path_len], p[0..self.capture_path_len]);
    }
    pub fn captureSince(self: *const Model) []const u8 {
        return self.capture_since_buf[0..self.capture_since_len];
    }
    fn setCaptureSince(self: *Model, oid: []const u8) void {
        self.capture_since_len = @min(oid.len, self.capture_since_buf.len);
        @memcpy(self.capture_since_buf[0..self.capture_since_len], oid[0..self.capture_since_len]);
    }

    pub fn scanRepoPath(self: *const Model) []const u8 {
        return self.scan_repo_path_buf[0..self.scan_repo_path_len];
    }
    fn setScanRepoPath(self: *Model, p: []const u8) void {
        self.scan_repo_path_len = @min(p.len, self.scan_repo_path_buf.len);
        @memcpy(self.scan_repo_path_buf[0..self.scan_repo_path_len], p[0..self.scan_repo_path_len]);
    }
    fn currentScanPath(self: *const Model) []const u8 {
        if (self.scan_file_idx >= self.scan_path_count) return "";
        return self.scan_paths[self.scan_file_idx].path();
    }
    fn scanContent(self: *const Model) []const u8 {
        return self.scan_content_buf[0..self.scan_content_len];
    }
    fn scanLastHash(self: *const Model) []const u8 {
        return self.scan_last_hash_buf[0..self.scan_last_hash_len];
    }
    fn setScanLastHash(self: *Model, h: []const u8) void {
        self.scan_last_hash_len = @min(h.len, self.scan_last_hash_buf.len);
        @memcpy(self.scan_last_hash_buf[0..self.scan_last_hash_len], h[0..self.scan_last_hash_len]);
    }

    pub fn usernameText(self: *const Model) []const u8 {
        return self.username;
    }

    pub fn repoError(self: *const Model) []const u8 {
        return self.repo_error_buf[0..self.repo_error_len];
    }
    fn setRepoError(self: *Model, msg: []const u8) void {
        self.repo_error_len = @min(msg.len, self.repo_error_buf.len);
        @memcpy(self.repo_error_buf[0..self.repo_error_len], msg[0..self.repo_error_len]);
    }
    fn clearRepoError(self: *Model) void {
        self.repo_error_len = 0;
    }
    fn pendingPath(self: *const Model) []const u8 {
        return self.pending_path_buf[0..self.pending_path_len];
    }
    fn setPendingPath(self: *Model, p: []const u8) void {
        self.pending_path_len = @min(p.len, self.pending_path_buf.len);
        @memcpy(self.pending_path_buf[0..self.pending_path_len], p[0..self.pending_path_len]);
    }
    /// Repos as a slice for the view's `<for each>`.
    pub fn reposSlice(self: *const Model) []const repos.RepoEntry {
        return self.repo_list[0..self.repo_count];
    }
    pub fn hasRepos(self: *const Model) bool {
        return self.repo_count > 0;
    }
    pub fn isAddingRepo(self: *const Model) bool {
        return self.adding_repo;
    }
    /// The app-data directory path, surfaced in the Settings modal.
    pub fn dataDirText(self: *const Model) []const u8 {
        return self.data_dir;
    }

    // These fields are read by update/effect logic or via accessor
    // functions (usernameText/dataDirText/statusText), not bound directly
    // in markup, so they are intentionally exempt from the dead-state lint.
    pub const view_unbound = .{
        "stage",            "data_dir_ready",   "onboarded",        "username",
        "data_dir",         "repo_list",        "repo_count",       "adding_repo",
        "repo_error_buf",   "repo_error_len",   "pending_path_buf", "pending_path_len",
        "capturing",        "capture_idx",      "capture_repo_id",  "capture_path_buf",
        "capture_path_len", "capture_since_buf", "capture_since_len",
        "capturePath",      "captureSince",
        // Working-tree snapshot scan (Task 5).
        "scanning",           "scan_timer_started", "scan_repo_idx",   "scan_repo_id",
        "scan_repo_path_buf", "scan_repo_path_len", "scan_paths",      "scan_path_count",
        "scan_file_idx",      "scan_content_buf",   "scan_content_len", "scan_hash_buf",
        "scan_last_hash_buf", "scan_last_hash_len", "scanRepoPath",
        // Tray + launch-at-login (Task 6).
        "login_enabled",      "login_supported",
    };
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

    // Watched repositories (Task 3)
    repo_input_edit: canvas.TextInputEvent, // typing in the path field
    add_repo_clicked, // "Add" pressed (or field submitted)
    git_check_done: native_sdk.EffectExit, // git rev-parse validation result
    repo_inserted: native_sdk.EffectDbResult, // insert transaction result
    repos_listed: native_sdk.EffectDbResult, // list query result page/done
    remove_repo: i64, // delete a repo by id
    repo_removed: native_sdk.EffectDbResult, // delete transaction result

    // Git history capture (Task 4)
    capture_since_done: native_sdk.EffectDbResult, // last_indexed_oid query result
    capture_log_done: native_sdk.EffectExit, // `git log` output (collected)
    capture_write_done: native_sdk.EffectDbResult, // insert+bookkeeping result

    // Working-tree snapshot scan (Task 5)
    snapshot_tick: native_sdk.EffectTimer, // repeating scan timer fired
    snap_status_done: native_sdk.EffectExit, // `git status` output (collected)
    snap_lasthash_done: native_sdk.EffectDbResult, // last content_hash query
    snap_content_done: native_sdk.EffectFileResult, // readFile current content
    snap_diff_done: native_sdk.EffectExit, // `git diff` output (collected)
    snap_write_done: native_sdk.EffectDbResult, // snapshot insert result

    // Tray + launch-at-login (Task 6)
    open_window, // tray "Open Blocks" — reveal the main window
    quit_app, // tray "Quit Blocks"
    toggle_login, // tray "Start at Login" toggle
    login_status_done: native_sdk.EffectHostResult, // launch-at-login status query
    login_set_done: native_sdk.EffectHostResult, // launch-at-login set result

    // Delivered by effects/host, never bound as markup handlers.
    pub const view_unbound = .{
        "stat_config",         "wrote_config",       "wrote_keep",
        "git_check_done",      "repo_inserted",      "repos_listed",
        "repo_removed",        "capture_since_done", "capture_log_done",
        "capture_write_done",  "snapshot_tick",      "snap_status_done",
        "snap_lasthash_done",  "snap_content_done",  "snap_diff_done",
        "snap_write_done",     "open_window",        "quit_app",
        "toggle_login",        "login_status_done",  "login_set_done",
    };
};

pub const Effects = native_sdk.Effects(Msg);

/// Write the two anchor files (config.json + models/.keep) on a first
/// run (config absent).
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

/// Query the watched-repos list into the model (fires after every change).
fn listRepos(fx: *Effects) void {
    fx.dbQuery(.{
        .key = key_repos_list,
        .sql = repos.list_sql,
        .on_result = Effects.dbMsg(.repos_listed),
    });
}

pub fn initFx(model: *Model, fx: *Effects) void {
    model.username = boot_username;

    // Resolve the app-data directory (all data lives here) from the real
    // environment. The SDK runner has already created it and opened the
    // engine-owned app.db inside it.
    const paths = config.Paths.resolve(boot_arena.allocator(), bundle_id, env.lookup) catch {
        // Without HOME we cannot resolve the data dir; stay in booting.
        // (macOS GUI apps always have HOME in practice.)
        return;
    };
    boot_paths = paths;
    model.data_dir = paths.data_dir;

    // Learn whether this is a first run by stat-ing the config file.
    fx.statFile(.{
        .key = key_stat_config,
        .path = paths.config,
        .on_result = Effects.fileMsg(.stat_config),
    });

    // Query the current launch-at-login state so the tray toggle reflects
    // reality (empty payload = a status read).
    fx.hostRequest(.{
        .key = key_login_status,
        .name = host_login_status,
        .on_result = Effects.hostMsg(.login_status_done),
    });
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
            // Either way the DB is ready — load the watched-repo list.
            listRepos(fx);
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

        // ---- Watched repositories ----
        .repo_input_edit => |event| {
            model.repo_input.apply(event);
            model.clearRepoError();
        },
        .add_repo_clicked => addRepoClicked(model, fx),
        .git_check_done => |exit| gitCheckDone(model, exit, fx),
        .repo_inserted => |res| {
            model.adding_repo = false;
            if (res.outcome == .ok) {
                model.repo_input.clear();
                model.pending_path_len = 0;
                model.clearRepoError();
                listRepos(fx);
            } else if (res.outcome == .constraint) {
                model.setRepoError("That repository is already being watched.");
            } else {
                model.setRepoError("Could not save the repository.");
            }
        },
        .repos_listed => |res| {
            loadReposPage(model, res);
            // When the list has fully loaded (terminal .done) and no capture
            // pass is already running, start indexing git history from the
            // top of the list.
            if (res.kind == .done and !model.capturing) startCapture(model, fx);
            // Arm the repeating working-tree scan timer once the app is up.
            if (res.kind == .done) armSnapshotTimer(model, fx);
        },
        .remove_repo => |id| {
            var params: [1]db.Value = undefined;
            fx.dbExec(.{
                .key = key_repo_delete,
                .statements = &.{repos.deleteStatement(&params, id)},
                .on_result = Effects.dbMsg(.repo_removed),
            });
        },
        .repo_removed => |res| {
            if (res.outcome == .ok) listRepos(fx);
        },

        // ---- Git history capture (Task 4) ----
        .capture_since_done => |res| captureSinceDone(model, res, fx),
        .capture_log_done => |exit| captureLogDone(model, exit, fx),
        .capture_write_done => {
            // The repo's events + bookkeeping are committed (or the write
            // failed — either way we move on so one bad repo can't stall
            // the pass). Advance to the next repo.
            model.capture_idx += 1;
            captureNext(model, fx);
        },

        // ---- Working-tree snapshot scan (Task 5) ----
        .snapshot_tick => |timer| {
            // Ignore a rejected timer or a tick that lands mid-scan (the
            // interval is the debounce/coalesce window).
            if (timer.outcome == .rejected) return;
            if (model.scanning) return;
            startScan(model, fx);
        },
        .snap_status_done => |exit| snapStatusDone(model, exit, fx),
        .snap_lasthash_done => |res| snapLastHashDone(model, res, fx),
        .snap_content_done => |res| snapContentDone(model, res, fx),
        .snap_diff_done => |exit| snapDiffDone(model, exit, fx),
        .snap_write_done => {
            // Snapshot committed (or failed) — either way, next file.
            model.scan_file_idx += 1;
            scanNextFile(model, fx);
        },

        // ---- Tray + launch-at-login (Task 6) ----
        .open_window => fx.showWindow(main_window_label),
        .quit_app => fx.quitApp(),
        .toggle_login => {
            if (!model.login_supported) return;
            // Optimistically flip; the host result confirms/corrects it.
            const enable = !model.login_enabled;
            const payload = [_]u8{@intFromBool(enable)};
            fx.hostRequest(.{
                .key = key_login_set,
                .name = host_login_set,
                .payload = &payload,
                .on_result = Effects.hostMsg(.login_set_done),
            });
        },
        .login_status_done => |res| applyLoginResult(model, res),
        .login_set_done => |res| applyLoginResult(model, res),
    }
}

/// Interpret a launch-at-login host result (from either the status query or
/// a set request) and update the model's login flags. The result bytes are
/// the status name on success, or an error tag on failure.
fn applyLoginResult(model: *Model, res: native_sdk.EffectHostResult) void {
    if (!res.ok) {
        // "unsupported" means the platform/build has no launch-at-login;
        // disable the toggle. "failed"/"rejected" leave state unchanged.
        if (std.mem.eql(u8, res.bytes, "unsupported")) model.login_supported = false;
        return;
    }
    model.login_supported = true;
    if (std.mem.eql(u8, res.bytes, "enabled")) {
        model.login_enabled = true;
    } else if (std.mem.eql(u8, res.bytes, "disabled") or std.mem.eql(u8, res.bytes, "not_found")) {
        model.login_enabled = false;
    } else if (std.mem.eql(u8, res.bytes, "requires_approval")) {
        // macOS SMAppService: registered but pending the user's approval in
        // System Settings. Treat as "on" for the toggle — the item exists.
        model.login_enabled = true;
    }
}

/// Tray menu state, derived from the model each rebuild. The runtime calls
/// this and applies the returned status item; menu selections come back
/// through `onTrayCommand`.
fn statusItem(model: *const Model, scratch: *BlocksApp.StatusItemScratch) BlocksApp.StatusItemState {
    const items = tray.buildMenu(&scratch.items, model.login_enabled, model.login_supported);
    return .{
        .title = "Blocks",
        .tooltip = "Blocks for Developers",
        .items = items,
    };
}

/// Map a tray/menu command name to a Msg (or null to ignore it).
fn onTrayCommand(name: []const u8) ?Msg {
    if (std.mem.eql(u8, name, tray.cmd_open)) return .open_window;
    if (std.mem.eql(u8, name, tray.cmd_toggle_login)) return .toggle_login;
    if (std.mem.eql(u8, name, tray.cmd_quit)) return .quit_app;
    return null;
}

// -------------------------------------------------- git history capture

/// Begin a capture pass over the loaded repo list from the top.
fn startCapture(model: *Model, fx: *Effects) void {
    if (model.capturing) return;
    if (model.repo_count == 0) return;
    model.capturing = true;
    model.capture_idx = 0;
    captureNext(model, fx);
}

/// Advance to the next active repo and query its last_indexed_oid, or end
/// the pass when the list is exhausted.
fn captureNext(model: *Model, fx: *Effects) void {
    while (model.capture_idx < model.repo_count) : (model.capture_idx += 1) {
        const entry = &model.repo_list[model.capture_idx];
        if (!entry.active) continue;
        model.capture_repo_id = entry.id;
        model.setCapturePath(entry.path());
        // Look up where we left off for this repo.
        var params: [1]db.Value = undefined;
        params[0] = db.val.int(entry.id);
        fx.dbQuery(.{
            .key = key_capture_since,
            .sql = git.select_last_indexed_sql,
            .params = &params,
            .on_result = Effects.dbMsg(.capture_since_done),
        });
        return;
    }
    // No more repos to index.
    model.capturing = false;
}

/// Received the repo's stored `last_indexed_oid`; spawn `git log` from
/// there (or full history when it has never been indexed).
fn captureSinceDone(model: *Model, res: native_sdk.EffectDbResult, fx: *Effects) void {
    switch (res.kind) {
        .page => {
            model.capture_since_len = 0;
            var reader = db.PageReader.init(res.bytes) catch return;
            var row: [1]db.ColumnValue = undefined;
            if ((reader.next(&row) catch null)) |cols| {
                if (cols.len > 0) {
                    if (cols[0].asText()) |oid| model.setCaptureSince(oid);
                }
            }
        },
        .done => {
            // All pages seen; now spawn the log for this repo.
            spawnCaptureLog(model, fx);
        },
        .exec => {},
    }
}

/// Spawn `git -C <path> log --reverse --numstat --format=… [<since>..HEAD]`
/// for the current capture repo, collecting the whole output.
fn spawnCaptureLog(model: *Model, fx: *Effects) void {
    var argv_buf: [git.max_argv][]const u8 = undefined;
    var fmt_buf: [64]u8 = undefined;
    var range_buf: [96]u8 = undefined;
    const argv = git.logArgv(&argv_buf, &fmt_buf, &range_buf, model.capturePath(), model.captureSince());
    fx.spawn(.{
        .key = key_capture_log,
        .argv = argv,
        .output = .collect,
        .on_exit = Effects.exitMsg(.capture_log_done),
    });
}

/// Parse collected `git log` output into `events` inserts, then update the
/// repo's `last_indexed_oid`/`last_indexed_at`. All params live on this
/// frame (dbExec copies them at call time).
fn captureLogDone(model: *Model, exit: native_sdk.EffectExit, fx: *Effects) void {
    // A failed spawn / non-zero exit (e.g. a repo that moved) — skip it
    // without stalling the pass.
    if (exit.reason != .exited or exit.code != 0) {
        model.capture_idx += 1;
        captureNext(model, fx);
        return;
    }

    const output = exit.output;
    var commits_buf: [max_commits_per_pass]git.Commit = undefined;
    const commits = git.parseLog(&commits_buf, output) catch {
        model.capture_idx += 1;
        captureNext(model, fx);
        return;
    };

    if (commits.len == 0) {
        // Nothing new for this repo; just move on (no bookkeeping change
        // needed since last_indexed_oid is unchanged).
        model.capture_idx += 1;
        captureNext(model, fx);
        return;
    }

    // Build one exec batch: an INSERT per commit + a final bookkeeping
    // UPDATE. Each statement needs its OWN params buffer that lives until
    // dbExec returns (the lifetime trap), so all buffers live here.
    const now = fx.wallMs();
    var insert_params: [max_commits_per_pass][git.insert_param_count]db.Value = undefined;
    var statements: [max_commits_per_pass + 1]db.Statement = undefined;
    var n: usize = 0;
    while (n < commits.len) : (n += 1) {
        const c = commits[n];
        const occurred = git.isoToUnixMs(c.author_date_iso, now);
        statements[n] = git.insertStatement(&insert_params[n], model.capture_repo_id, c, occurred, now);
    }

    // Bookkeeping update: last indexed oid = the newest (last, since we
    // walked --reverse) commit's oid.
    var update_params: [3]db.Value = undefined;
    const last_oid = commits[commits.len - 1].oid;
    statements[n] = git.updateIndexedStatement(&update_params, model.capture_repo_id, last_oid, now);
    n += 1;

    fx.dbExec(.{
        .key = key_capture_write,
        .statements = statements[0..n],
        .on_result = Effects.dbMsg(.capture_write_done),
    });
}

/// Validate the input path's shape, then spawn `git -C <path> rev-parse`
/// to confirm it is a real git repository before inserting it.
fn addRepoClicked(model: *Model, fx: *Effects) void {
    if (model.adding_repo) return; // ignore double clicks while validating
    const raw = model.repo_input.text();
    const normalized = repos.normalizePath(raw);

    switch (repos.checkPathShape(normalized)) {
        .empty => {
            model.setRepoError("Enter a repository path.");
            return;
        },
        .not_absolute => {
            model.setRepoError("Enter an absolute path (starting with / or ~).");
            return;
        },
        .ok => {},
    }

    model.setPendingPath(normalized);
    model.adding_repo = true;
    model.clearRepoError();

    // `git -C <path> rev-parse --is-inside-work-tree` exits 0 for a repo.
    fx.spawn(.{
        .key = key_git_check,
        .argv = &.{ "git", "-C", model.pendingPath(), "rev-parse", "--is-inside-work-tree" },
        .output = .collect,
        .on_exit = Effects.exitMsg(.git_check_done),
    });
}

fn gitCheckDone(model: *Model, exit: native_sdk.EffectExit, fx: *Effects) void {
    const is_repo = (exit.reason == .exited and exit.code == 0);
    if (!is_repo) {
        model.adding_repo = false;
        if (exit.reason == .spawn_failed) {
            model.setRepoError("Could not run git — is it installed?");
        } else {
            model.setRepoError("That folder is not a git repository.");
        }
        return;
    }
    // Valid repo — insert it. Name defaults to the trailing path component.
    // The params buffer lives on this frame; dbExec copies params at call.
    const path = model.pendingPath();
    const name = repos.defaultName(path);
    var params: [3]db.Value = undefined;
    fx.dbExec(.{
        .key = key_repo_insert,
        .statements = &.{repos.insertStatement(&params, path, name, fx.wallMs())},
        .on_result = Effects.dbMsg(.repo_inserted),
    });
}

// --------------------------------------------- working-tree snapshot scan

/// Arm the repeating scan timer exactly once. The interval is the
/// debounce/coalesce window; each fire delivers `snapshot_tick`.
fn armSnapshotTimer(model: *Model, fx: *Effects) void {
    if (model.scan_timer_started) return;
    model.scan_timer_started = true;
    fx.startTimer(.{
        .key = key_snap_timer,
        .interval_ms = snapshot_interval_ms,
        .mode = .repeating,
        .on_fire = Effects.timerMsg(.snapshot_tick),
    });
}

/// Begin a scan pass over the loaded repo list from the top.
fn startScan(model: *Model, fx: *Effects) void {
    if (model.scanning) return;
    if (model.repo_count == 0) return;
    model.scanning = true;
    model.scan_repo_idx = 0;
    scanNextRepo(model, fx);
}

/// Advance to the next active repo and spawn `git status` for it, or end
/// the pass when the repo list is exhausted.
fn scanNextRepo(model: *Model, fx: *Effects) void {
    while (model.scan_repo_idx < model.repo_count) : (model.scan_repo_idx += 1) {
        const entry = &model.repo_list[model.scan_repo_idx];
        if (!entry.active) continue;
        model.scan_repo_id = entry.id;
        model.setScanRepoPath(entry.path());
        model.scan_path_count = 0;
        model.scan_file_idx = 0;
        var argv_buf: [snapshots.max_argv][]const u8 = undefined;
        const argv = snapshots.statusArgv(&argv_buf, model.scanRepoPath());
        fx.spawn(.{
            .key = key_snap_status,
            .argv = argv,
            .output = .collect,
            .on_exit = Effects.exitMsg(.snap_status_done),
        });
        return;
    }
    model.scanning = false;
}

/// Parse `git status` output into the model's changed-path list, then start
/// processing files one at a time.
fn snapStatusDone(model: *Model, exit: native_sdk.EffectExit, fx: *Effects) void {
    // A failed status (repo moved/removed) — skip this repo.
    if (exit.reason != .exited or exit.code != 0) {
        model.scan_repo_idx += 1;
        scanNextRepo(model, fx);
        return;
    }
    var changes_buf: [max_changed_files]snapshots.Change = undefined;
    const changes = snapshots.parseStatus(&changes_buf, exit.output) catch {
        model.scan_repo_idx += 1;
        scanNextRepo(model, fx);
        return;
    };
    model.scan_path_count = 0;
    for (changes) |c| {
        if (model.scan_path_count >= max_changed_files) break;
        model.scan_paths[model.scan_path_count] = ChangedPath.fromChange(c);
        model.scan_path_count += 1;
    }
    model.scan_file_idx = 0;
    scanNextFile(model, fx);
}

/// Process the current file: query its last stored content hash. When the
/// file list is exhausted, move on to the next repo.
fn scanNextFile(model: *Model, fx: *Effects) void {
    if (model.scan_file_idx >= model.scan_path_count) {
        model.scan_repo_idx += 1;
        scanNextRepo(model, fx);
        return;
    }
    model.scan_last_hash_len = 0;
    var params: [2]db.Value = undefined;
    fx.dbQuery(.{
        .key = key_snap_lasthash,
        .sql = snapshots.select_last_hash_sql,
        .params = snapshots.lastHashParams(&params, model.scan_repo_id, model.currentScanPath()),
        .on_result = Effects.dbMsg(.snap_lasthash_done),
    });
}

/// Received the file's last stored hash; on the query's terminal `.done`,
/// read the file's current content.
fn snapLastHashDone(model: *Model, res: native_sdk.EffectDbResult, fx: *Effects) void {
    switch (res.kind) {
        .page => {
            var reader = db.PageReader.init(res.bytes) catch return;
            var row: [1]db.ColumnValue = undefined;
            if ((reader.next(&row) catch null)) |cols| {
                if (cols.len > 0) {
                    if (cols[0].asText()) |h| model.setScanLastHash(h);
                }
            }
        },
        .done => readCurrentFile(model, fx),
        .exec => {},
    }
}

/// Read the current changed file's content (absolute path = repo + rel).
/// The joined path lives on this frame; readFile copies the path string at
/// call time (like all effect string params), so a stack buffer is safe.
fn readCurrentFile(model: *Model, fx: *Effects) void {
    var abs_buf: [repos.max_path_bytes * 2 + 1]u8 = undefined;
    const abs = std.fmt.bufPrint(&abs_buf, "{s}/{s}", .{ model.scanRepoPath(), model.currentScanPath() }) catch {
        // Path too long to join — skip this file.
        model.scan_file_idx += 1;
        scanNextFile(model, fx);
        return;
    };
    fx.readFile(.{
        .key = key_snap_content,
        .path = abs,
        .on_result = Effects.fileMsg(.snap_content_done),
    });
}

/// Got the file content. Hash it, compare to the last stored hash, and
/// either skip (unchanged / too large / unreadable) or spawn `git diff`.
fn snapContentDone(model: *Model, res: native_sdk.EffectFileResult, fx: *Effects) void {
    // Skip anything we can't fully read: unreadable (deleted between
    // status and read, permissions), truncated (over the SDK's file cap),
    // or over our own content bound. This keeps stored content honest —
    // we never snapshot a partial file.
    if (res.outcome != .ok or res.bytes.len > max_content_bytes) {
        model.scan_file_idx += 1;
        scanNextFile(model, fx);
        return;
    }

    // Copy content into owned storage (the result bytes don't survive the
    // upcoming diff spawn + insert).
    model.scan_content_len = @min(res.bytes.len, max_content_bytes);
    @memcpy(model.scan_content_buf[0..model.scan_content_len], res.bytes[0..model.scan_content_len]);
    snapshots.sha256Hex(model.scanContent(), &model.scan_hash_buf);

    // Unchanged since the last snapshot? Skip (the core dedup rule).
    if (model.scan_last_hash_len == snapshots.hash_hex_len and
        std.mem.eql(u8, model.scanLastHash(), &model.scan_hash_buf))
    {
        model.scan_file_idx += 1;
        scanNextFile(model, fx);
        return;
    }

    // Untracked files have no git diff; snapshot them with an empty diff.
    if (model.scan_paths[model.scan_file_idx].untracked) {
        writeSnapshot(model, "", fx);
        return;
    }

    var argv_buf: [snapshots.max_argv][]const u8 = undefined;
    const argv = snapshots.diffArgv(&argv_buf, model.scanRepoPath(), model.currentScanPath());
    fx.spawn(.{
        .key = key_snap_diff,
        .argv = argv,
        .output = .collect,
        .on_exit = Effects.exitMsg(.snap_diff_done),
    });
}

/// Got the `git diff` output; write the snapshot with it (capped).
fn snapDiffDone(model: *Model, exit: native_sdk.EffectExit, fx: *Effects) void {
    const diff = if (exit.reason == .exited)
        exit.output[0..@min(exit.output.len, max_diff_bytes)]
    else
        "";
    writeSnapshot(model, diff, fx);
}

/// Insert one `file_snapshots` row for the current file. Params live on
/// this frame (dbExec copies them at call time).
fn writeSnapshot(model: *Model, diff: []const u8, fx: *Effects) void {
    var params: [snapshots.insert_param_count]db.Value = undefined;
    const stmt = snapshots.insertStatement(
        &params,
        model.scan_repo_id,
        model.currentScanPath(),
        model.scanContent(),
        diff,
        &model.scan_hash_buf,
        fx.wallMs(),
    );
    fx.dbExec(.{
        .key = key_snap_write,
        .statements = &.{stmt},
        .on_result = Effects.dbMsg(.snap_write_done),
    });
}

/// Copy a `repos_listed` query result page into the model's owned list.
/// The query returns a single page for our modest repo counts; a `.done`
/// terminal simply ends the list.
fn loadReposPage(model: *Model, res: native_sdk.EffectDbResult) void {
    switch (res.kind) {
        .page => {
            var reader = db.PageReader.init(res.bytes) catch return;
            model.repo_count = 0;
            var row: [8]db.ColumnValue = undefined;
            while (reader.next(&row) catch null) |cols| {
                if (model.repo_count >= repos.max_repos) break;
                const r = repos.Repo.fromRow(cols) orelse continue;
                model.repo_list[model.repo_count] = repos.RepoEntry.fromRepo(r);
                model.repo_count += 1;
            }
        },
        .done, .exec => {},
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
        // Menu-bar tray: a model-derived menu (Open / Start at Login / Quit).
        .status_item_fn = statusItem,
        .on_command = onTrayCommand,
    });
    defer app_state.destroy();
    app_state.model = initialModel();

    try runner.runWithOptions(app_state.app(), .{
        .app_name = "blocks",
        .window_title = "Blocks for Developers",
        .bundle_id = bundle_id,
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
