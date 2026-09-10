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

    // Delivered by effects/host, never bound as markup handlers.
    pub const view_unbound = .{
        "stat_config",         "wrote_config",     "wrote_keep",
        "git_check_done",      "repo_inserted",    "repos_listed",
        "repo_removed",        "capture_since_done", "capture_log_done",
        "capture_write_done",
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
    }
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
