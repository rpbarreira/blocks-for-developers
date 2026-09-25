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
const embeddings = @import("embeddings.zig");
const models = @import("models.zig");
const chat = @import("chat.zig");
const snippets = @import("snippets.zig");

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
// (Keys 140/141 were the launch-at-login host requests — removed. Users who
// want start-at-login use macOS System Settings > General > Login Items.)
// Embedding generation (Task 7).
const key_embed_events: u64 = 150; // query un-embedded events
const key_embed_snaps: u64 = 151; // query un-embedded file snapshots
const key_embed_write: u64 = 152; // insert embeddings + fts rows
// MCP server child process (Task 8). Share the spawn/fetch/file key space.
const key_mcp_spawn: u64 = 160; // spawn the blocks-mcp child
const key_mcp_health: u64 = 161; // fetch tools/list to confirm it's up
// Local model management + llama.cpp runtime (Task 9). spawn/fetch/file keys:
const key_cfg_read: u64 = 170; // read config.json to learn the selected model
const key_model_stat: u64 = 171; // stat the model file to see if it's present
const key_model_download: u64 = 172; // spawn curl to download the GGUF (.lines)
const key_model_rename: u64 = 173; // spawn mv to move .part into place
const key_llama_spawn: u64 = 174; // spawn the llama-server runtime child
const key_llama_health: u64 = 175; // fetch /health to confirm the runtime is up
// Chat experience (Task 10). Share the spawn/fetch/file key space.
const key_mcp_search: u64 = 180; // POST search_memory tools/call to the MCP server
const key_llama_chat: u64 = 181; // POST /v1/chat/completions (.stream) to the runtime
const key_chat_insert: u64 = 182; // INSERT a new chats row
const key_chat_rowid: u64 = 183; // SELECT last_insert_rowid() for the new chat
const key_chat_write: u64 = 184; // INSERT the turn's messages + touch the chat
const key_messages_list: u64 = 185; // load a chat's messages
const key_chats_list: u64 = 187; // load the chat-history sidebar list
const key_chat_delete: u64 = 188; // DELETE a chat (its messages cascade)
// Single-click summaries (Task 11). Share the spawn/fetch/file key space.
const key_mcp_activity: u64 = 186; // POST get_activity tools/call for a summary's context
// Materials / snippets (Task 12). Share the spawn/fetch/file/db key space.
const key_snip_list: u64 = 190; // query the snippets list (recent/alpha, optional lang filter)
const key_snip_langs: u64 = 191; // query the distinct languages
const key_snip_insert: u64 = 192; // INSERT a new snippet
const key_snip_rowid: u64 = 193; // SELECT MAX(id) to recover a new snippet's id
const key_snip_update: u64 = 194; // UPDATE an existing snippet
const key_snip_setlang: u64 = 195; // UPDATE just the language (set-language modal)
const key_snip_delete: u64 = 196; // DELETE a snippet
const key_snip_clip: u64 = 197; // writeClipboard the selected snippet
const key_snip_detail: u64 = 198; // query the selected snippet's full body
// Config rewrites AFTER first-run (Task 13). A separate key/Msg from the
// first-run `key_write_config`/`.wrote_config` so persisting a model change
// or completing onboarding never re-runs the first-run arm (which clears
// `onboarded`). See `config_persisted`.
const key_config_persist: u64 = 200; // rewrite config.json (model change / onboarding)

/// The loopback port the MCP child binds (passed explicitly so the app
/// knows where to reach it without first reading the endpoint file).
const mcp_port: u16 = 39_017;
/// Default argv[0] for the MCP child. Under `native dev` the app's cwd is the
/// repo root, so this repo-relative path resolves. A packaged `.app` cannot
/// see the repo, and the SDK exposes no self-exe-path effect, so the bundle's
/// launcher script exports `BLOCKS_MCP_SERVER` with the absolute path to the
/// vendored `blocks-mcp` beside the app — `resolveMcpBinary` prefers it.
const mcp_binary_default = "mcp/zig-out/bin/blocks-mcp";
/// Env var the packaged launcher sets to point the app at the vendored MCP
/// child (mirror of `BLOCKS_LLAMA_SERVER` for the llama runtime).
const mcp_binary_env = "BLOCKS_MCP_SERVER";

/// The MCP child binary path: `$BLOCKS_MCP_SERVER` when set (packaged build),
/// else the repo-relative default (`native dev`).
fn resolveMcpBinary() []const u8 {
    if (env.lookup(mcp_binary_env)) |v| {
        if (v.len > 0) return v;
    }
    return mcp_binary_default;
}
/// The MCP tools/list request body used as a health check once the child
/// has had a moment to bind its port.
const mcp_health_body =
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}";
/// One-shot delay before the FIRST health check, giving the child time to bind.
const mcp_health_delay_ms: u64 = 400;
/// Delay between subsequent MCP health checks while the child is still coming
/// up. The single-shot check used to race the child's bind and leave
/// `mcp_ready` false forever (retrieval then silently skipped) — so we retry
/// on a fixed backoff, mirroring the llama health check (Task 9).
const mcp_health_retry_ms: u64 = 500;
/// How many MCP health checks to attempt before giving up (non-fatal). The
/// child binds fast (no model load), so a handful of tries over ~a few
/// seconds is ample; `mcp_failed` is set only after the cap.
const mcp_health_max_attempts: u32 = 20;

/// The loopback port the llama.cpp runtime binds. Task 10's chat POSTs to
/// its OpenAI-compatible endpoint here; for now we only health-check it.
const llama_port: u16 = 39_018;

/// Human-readable loopback URLs shown in Settings › Model Context Protocol
/// (mockup 3). Kept in sync with `mcp_port` / `llama_port` above. Static so
/// the accessors can return borrowed slices without owned storage.
const mcp_url = "http://127.0.0.1:39017/";
const llama_url = "http://127.0.0.1:39018/v1";
/// Delay before the FIRST llama health check. Model load (mmap + warmup)
/// takes noticeably longer than the MCP child's bind.
const llama_health_delay_ms: u64 = 1_500;
/// Delay between subsequent llama health checks while the model is still
/// loading. A fresh multi-GB GGUF can take 10-30s to become ready, so we
/// poll until it answers (or we give up after `llama_health_max_attempts`).
const llama_health_retry_ms: u64 = 1_500;
/// How many health checks to attempt before declaring the runtime failed.
/// `1500 + 40*1500 ≈ 60s` of grace covers a cold load of a large model.
const llama_health_max_attempts: u32 = 40;
/// Max curl progress lines we bother to process per download (each just
/// updates a float; this is a sanity bound, not a hard limit).
const download_progress_line_cap: usize = 100_000;

/// Chat tuning (Task 10).
const chat_max_tokens: u32 = 512; // cap the assistant reply length
const chat_search_hits: u32 = 6; // how many memory hits to retrieve for context
const chat_context_cap: usize = 4096; // max bytes of retrieved context injected
const chat_reply_cap: usize = chat.max_content_bytes; // max streamed reply we retain
const chat_input_capacity = 2048; // chat text-field buffer capacity

/// Materials / snippets (Task 12) input-field capacities.
const snip_search_capacity = 256; // "Find materials…" search field
const snip_title_capacity = snippets.max_title_bytes;
const snip_content_capacity = 8192; // editor body field (display/edit cap)
const snip_language_capacity = snippets.max_language_bytes;
const snip_annotation_capacity = snippets.max_annotation_bytes;
const snip_text_expander_capacity = snippets.max_text_expander_bytes;
/// How the sidebar list is ordered (mockup: SORT BY → Recent / Alphabetical).
const SnippetSort = enum { recent, alphabetical };

/// Which top-level screen is showing. A minimal nav so the Chat and Materials
/// views don't stack in one scroll (Task 13 does the high-fidelity shell).
const Screen = enum { chat, materials };

/// The two-step first-run onboarding flow (Task 13). Shown as a full-screen
/// overlay while `!onboarded`: a welcome splash, then a model picker. The
/// user picks + installs a model, then lands in the app.
const OnboardStep = enum { welcome, pick_model };

/// The welcome-splash description (mockup 4).
const welcome_blurb =
    "Blocks runs in the background on your computer, forming a searchable memory " ++
    "of the history of your local git repositories so you can build better context " ++
    "and store materials that help you be more productive.";

/// Which settings section is open in the Settings modal (mockup 3).
const SettingsSection = enum { all, about, repos, mcp, local_model };

/// What the shared delete-confirmation dialog is deleting. The one dialog
/// window serves both the Materials screen and the chat-history sidebar.
const DeleteKind = enum { material, chat };
/// Whole-exchange timeout for the streamed completion (a long reply on a
/// small local model can still take a while); the stream lifetime counts.
const chat_stream_timeout_ms: u32 = 120_000;

/// How many source rows to embed per query batch. Each row contributes a
/// 256-f32 vector + an FTS insert; two statements/row, all frame-local.
const embed_batch = 16;
/// Text length embedded per row (subject+body / path+content, truncated).
const embed_text_bytes = 4096;


/// The window label the tray "Open Blocks" action reveals. Matches the
/// `shell_windows` entry below.
const main_window_label = "main";
/// The Settings window (Task 13): a model-declared SECONDARY OS window
/// (opened via `windows_fn` when `settings_open`, built by `window_view`).
/// Its canvas label MUST be distinct from the main canvas.
const settings_window_label = "settings";
const settings_canvas_label = "settings-canvas";
/// The material add/edit editor (formerly an inline `<if editorOpen>` sheet on
/// the main canvas) is ALSO a model-declared SECONDARY OS window, mirroring
/// Settings: opened via `windows_fn` when `editor_open`, built by `window_view`
/// (a UiApp binds markup to only ONE canvas, so a second window is Zig-built).
const editor_window_label = "material-editor";
const editor_canvas_label = "material-canvas";
/// The delete-confirmation dialog is ALSO a secondary OS window (per the
/// user's request — not an inline overlay): opened via `windows_fn` when
/// `confirm_delete_open`, built by `window_view`.
const confirm_delete_window_label = "confirm-delete";
const confirm_delete_canvas_label = "confirm-delete-canvas";
// Timer keys live in their OWN namespace (never collide with the above).
const key_snap_timer: u64 = 1; // the repeating scan/debounce tick
const key_mcp_health_timer: u64 = 2; // one-shot delay before the MCP health check
const key_llama_health_timer: u64 = 3; // one-shot delay before the llama health check

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

/// Which source table an embedding pass is currently draining. A pass
/// embeds all un-embedded events, then all un-embedded file snapshots.
pub const EmbedPhase = enum { events, snapshots };

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

/// One row in the model picker's `<for each>` (Task 9 picker + Task 13
/// onboarding/settings cards). Built by `refreshModelChoices` from the
/// static catalog + the current selection. The `name`/`blurb`/`tierLabel`
/// slices borrow comptime catalog strings; `size`/`ram` are computed into
/// this struct's own inline buffers (so the view slice stays valid across
/// rebuilds without an allocator).
pub const ModelChoice = struct {
    index: usize,
    name: []const u8,
    blurb: []const u8,
    selected: bool,
    /// True for the single recommended model (a starred badge in the card).
    recommended: bool = false,
    /// The tier badge label ("Premium" / "Balanced" / "Basic").
    tierLabel: []const u8 = "",
    /// Inline-owned "N GB"/"N MB" size label.
    size_buf: [16]u8 = undefined,
    size_len: usize = 0,
    /// Inline-owned "Needs N GB RAM" label ("" when unknown).
    ram_buf: [24]u8 = undefined,
    ram_len: usize = 0,
    /// Inline-owned one-line spec caption combining size + RAM, e.g.
    /// "1.7 GB · Needs 8 GB RAM" (just the size when RAM is unknown). Kept
    /// as ONE line so a card stays compact (all three fit without scroll).
    spec_buf: [48]u8 = undefined,
    spec_len: usize = 0,

    pub fn sizeLabel(self: *const ModelChoice) []const u8 {
        return self.size_buf[0..self.size_len];
    }
    pub fn ramLabel(self: *const ModelChoice) []const u8 {
        return self.ram_buf[0..self.ram_len];
    }
    pub fn hasRam(self: *const ModelChoice) bool {
        return self.ram_len > 0;
    }
    pub fn specLine(self: *const ModelChoice) []const u8 {
        return self.spec_buf[0..self.spec_len];
    }
};

/// One single-click summary card (Task 11) for the view's `<for each>`.
/// `tag` is the `chat.SummaryKind` enum tag name — the markup coerces it to
/// the enum for `on-press="start_summary:{c.tag}"`.
pub const SummaryCard = struct {
    tag: []const u8,
    label: []const u8,
    blurb: []const u8,
    /// Built-in icon name for the card's leading glyph (mockup: a colored
    /// icon per card). Drawn via `<icon name="{c.icon}">`.
    icon: []const u8,
};

/// The fixed set of summary cards, one per `chat.SummaryKind`. `tag` MUST be
/// the exact enum tag name (`@tagName`) so markup's `stringToEnum` coercion
/// resolves it. Blurbs + icons mirror the chat mockup.
const summary_cards = [_]SummaryCard{
    .{ .tag = @tagName(chat.SummaryKind.day_recap), .label = "Day Recap", .blurb = "Accomplishments and what's still open", .icon = "clock" },
    .{ .tag = @tagName(chat.SummaryKind.top_of_mind), .label = "What's Top of Mind", .blurb = "Recurring themes by intensity", .icon = "alert" },
    .{ .tag = @tagName(chat.SummaryKind.standup), .label = "Standup Update", .blurb = "Progress, plans, and blockers", .icon = "check-circle" },
};

pub const Model = struct {
    /// True when the user has completed onboarding (config already existed at
    /// boot, OR they just finished the welcome flow). Drives whether the
    /// full-screen onboarding overlay is shown. Read by `persistConfig` to
    /// preserve the flag when rewriting config.json on a model change.
    onboarded: bool = false,
    /// Which onboarding step is showing while `!onboarded` (Task 13).
    onboard_step: OnboardStep = .welcome,
    /// Settings window open state + which section is selected (Task 13).
    settings_open: bool = false,
    settings_section: SettingsSection = .all,
    /// Bumped on each Settings OPEN so the window gets a fresh canvas label
    /// (`settings-canvas-<n>`) — a re-declare under the same label doesn't
    /// re-install the canvas in a live session, so each open is a new one.
    settings_open_count: u32 = 0,
    /// Inline storage for the current `settings-canvas-<n>` label, (re)written
    /// by `refreshSettingsCanvasLabel` on each open. `windows_fn` reads it.
    settings_canvas_buf: [40]u8 = undefined,
    settings_canvas_len: usize = 0,
    /// Detected OS username, shown next to the avatar. Borrowed from the
    /// process-lifetime boot arena.
    username: []const u8 = "developer",
    /// The avatar initials (derived from `username` at boot), shown in the
    /// sidebar avatar circle. Inline-owned (1-2 bytes).
    avatar_initials_buf: [4]u8 = undefined,
    avatar_initials_len: usize = 0,
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

    // ---- Embedding generation (Task 7) ----
    /// True while an embedding pass is running (coalesces triggers).
    embedding: bool = false,
    /// Which source table the current pass is draining.
    embed_phase: EmbedPhase = .events,
    /// Rows embedded in the batch currently being written. Continuation is
    /// driven STRICTLY from the write result (so the write has committed
    /// before the next query runs, avoiding re-embedding the same rows):
    /// a full batch => more may remain, query again; a short/empty batch
    /// => this phase is drained. The query's own `.done` is a no-op.
    embed_last_rows: usize = 0,

    // ---- MCP server child process (Task 8) ----
    /// True once the MCP child has been spawned this session (so we spawn
    /// it exactly once, on boot).
    mcp_started: bool = false,
    /// True after a health-check fetch confirmed the child answers
    /// `tools/list` — the memory tools are reachable over HTTP.
    mcp_ready: bool = false,
    /// True if the child exited or failed to spawn. Surfaced for later UI;
    /// the app still runs (the MCP server is optional for the core UX).
    mcp_failed: bool = false,
    /// How many MCP `/` health checks have been attempted this session.
    /// Resets on spawn; caps at `mcp_health_max_attempts` before we declare
    /// the server unreachable (non-fatal).
    mcp_health_attempts: u32 = 0,

    // ---- Local model management + llama.cpp runtime (Task 9) ----
    /// The selected model's catalog id, read from config.json on boot (or
    /// the catalog default until then). Inline-owned so it survives updates.
    selected_model_buf: [128]u8 = undefined,
    selected_model_len: usize = 0,
    /// True once the selected model's GGUF file is present on disk.
    model_present: bool = false,
    /// True while a download (curl child) is in flight.
    downloading: bool = false,
    /// Latest parsed download progress in [0,1] (0 until curl reports any).
    download_progress: f32 = 0,
    /// True if the last download attempt failed (curl non-zero / no binary).
    download_failed: bool = false,
    /// True once the llama-server runtime child has been spawned this
    /// session (spawn it at most once per selected-model load).
    llama_started: bool = false,
    /// True after a `GET /health` returned 200 — the runtime is serving.
    llama_ready: bool = false,
    /// True if the runtime child exited or failed to spawn (e.g. the
    /// llama-server binary isn't installed). Non-fatal: the app still runs;
    /// Task 10's chat surfaces this and offers a retry.
    llama_failed: bool = false,
    /// How many llama `/health` checks have been attempted for the current
    /// runtime spawn. Resets on each `startLlama`; caps at
    /// `llama_health_max_attempts` before we declare the runtime failed.
    llama_health_attempts: u32 = 0,
    /// Picker rows, rebuilt from the catalog + selection (see
    /// refreshModelChoices). Inline storage so the view slice survives.
    model_choices: [models.catalog.len]ModelChoice = undefined,

    // ---- Chat experience (Task 10) ----
    /// The chat-input field buffer (model-owned inline storage).
    chat_input: canvas.TextBuffer(chat_input_capacity) = .{},
    /// The active chat's id (0 = none yet; a row is created on first send).
    current_chat_id: i64 = 0,
    /// The chat-history sidebar list (most-recently-updated first), inline-owned
    /// so the view slice survives updates. Refreshed on boot + after each write.
    chat_list: [chat.max_chats]chat.ChatEntry = undefined,
    chat_count: usize = 0,
    /// True once the chat-history list has been loaded on boot (load once).
    chats_loaded: bool = false,
    /// The active chat's human title, shown above the transcript. Set when a
    /// past chat is opened or a new turn/summary starts; empty for a fresh chat.
    chat_title_buf: [chat.chat_title_bytes]u8 = undefined,
    chat_title_len: usize = 0,
    /// The next message `seq` for the active chat. We are the sole writer,
    /// so we track this in-model instead of re-querying MAX(seq) each turn.
    next_seq: i64 = 0,
    /// Loaded/visible messages for the active chat (oldest first).
    messages: [chat.max_messages]chat.MessageEntry = undefined,
    message_count: usize = 0,
    /// The user text for the turn in flight, held from `send_chat` across the
    /// MCP-search → stream chain so it can be persisted at the end.
    pending_user_buf: [chat.max_content_bytes]u8 = undefined,
    pending_user_len: usize = 0,
    /// For a single-click summary turn (Task 11), the summary being generated;
    /// null for an ordinary chat turn. Held across the whole turn so the new
    /// chat is created with the right `chats.kind` + title, then cleared when
    /// the turn completes (`chat_write_done`) or fails. A summary retrieves
    /// context via the MCP `get_activity` tool (time-windowed) instead of
    /// `search_memory`, but otherwise reuses the exact chat turn machinery.
    pending_summary_kind: ?chat.SummaryKind = null,
    /// The assistant reply being streamed in (grows as tokens arrive).
    streaming_buf: [chat_reply_cap]u8 = undefined,
    streaming_len: usize = 0,
    /// The retrieved-memory context for the turn in flight (from MCP search),
    /// held only until the request body is built.
    context_buf: [chat_context_cap]u8 = undefined,
    context_len: usize = 0,
    /// True from `send_chat` until the assistant reply is fully PERSISTED
    /// (through the async INSERT/reload chain), not merely until the stream
    /// ends. This is the sole interlock `canSend` uses, so keeping it set
    /// through persistence prevents a second turn from overlapping the
    /// new-chat id recovery (which would create a duplicate chat + colliding
    /// seqs). Cleared in `chat_write_done` (success) or the finalize failure
    /// path (no persist).
    sending: bool = false,
    /// Guards `finalizeChat` against running twice for one turn (the `[DONE]`
    /// sentinel and the terminal `chat_done` both call it). Set on the first
    /// finalize, cleared when the next turn starts.
    finalizing: bool = false,
    /// True while llama tokens are streaming into `streaming_buf`.
    streaming: bool = false,
    /// Last chat error, shown under the input ("" when none).
    chat_error_buf: [256]u8 = undefined,
    chat_error_len: usize = 0,

    // ---- Top-level navigation (Task 12) ----
    /// Which screen is showing (Chat by default; Materials is Task 12's view).
    screen: Screen = .chat,

    // ---- Materials / snippets (Task 12) ----
    /// Loaded snippets (filtered + sorted by the current controls), refreshed
    /// after every change. Inline-owned so the view slice survives updates.
    snippet_list: [snippets.max_snippets]snippets.SnippetEntry = undefined,
    snippet_count: usize = 0,
    /// The distinct languages the user has snippets for — powers the sidebar
    /// language-filter menu AND the set-language modal's typeahead suggestions.
    languages: [snippets.max_languages]snippets.LanguageEntry = undefined,
    language_count: usize = 0,
    /// The selected snippet's id (0 = none). The sidebar `snippet_list` holds
    /// only lightweight cards; the SELECTED snippet's full body is loaded into
    /// `selected_detail` on demand (so the big content buffers exist once).
    selected_snippet_id: i64 = 0,
    selected_detail: snippets.SnippetDetail = .{},
    /// Sidebar controls: sort order + the active language filter ("" = All).
    snippet_sort: SnippetSort = .recent,
    lang_filter_buf: [snippets.max_language_bytes]u8 = undefined,
    lang_filter_len: usize = 0,
    /// "Find materials…" search text (client-side filter over the loaded list).
    snippet_search: canvas.TextBuffer(snip_search_capacity) = .{},
    /// Which transient sidebar menu is open (only one at a time).
    sort_menu_open: bool = false,
    lang_menu_open: bool = false,
    /// The material editor: a SECONDARY OS window (like Settings), open when
    /// adding or editing a snippet. `editing_id` is 0 for a new snippet, else
    /// the id being edited.
    editor_open: bool = false,
    editing_id: i64 = 0,
    /// Bumped on each editor OPEN so the window gets a fresh canvas label
    /// (`material-canvas-<n>`) — a re-declare under the same label doesn't
    /// re-install the canvas in a live session (the Settings reopen-blank
    /// gotcha), so each open is a clean install.
    editor_open_count: u32 = 0,
    editor_canvas_buf: [40]u8 = undefined,
    editor_canvas_len: usize = 0,
    edit_title: canvas.TextBuffer(snip_title_capacity) = .{},
    edit_content: canvas.TextBuffer(snip_content_capacity) = .{},
    edit_language: canvas.TextBuffer(snip_language_capacity) = .{},
    edit_annotation: canvas.TextBuffer(snip_annotation_capacity) = .{},
    edit_text_expander: canvas.TextBuffer(snip_text_expander_capacity) = .{},
    /// The delete-confirmation dialog: a SECONDARY OS window (like the editor
    /// + Settings), open when awaiting the user's confirmation. Same fresh-
    /// canvas-label-per-open pattern (the reopen-blank fix). The prompt
    /// sentence is built when the window opens (accessors don't allocate).
    confirm_delete_open: bool = false,
    confirm_delete_open_count: u32 = 0,
    confirm_delete_canvas_buf: [40]u8 = undefined,
    confirm_delete_canvas_len: usize = 0,
    confirm_delete_prompt_buf: [snippets.max_title_bytes + 64]u8 = undefined,
    confirm_delete_prompt_len: usize = 0,
    /// What the delete-confirmation dialog is about (the SAME dialog serves
    /// both a material and a chat). `.chat` also carries the target id, since
    /// a chat can be deleted from any row without selecting it first.
    confirm_delete_kind: DeleteKind = .material,
    confirm_delete_chat_id: i64 = 0,
    /// True once the snippets list has been loaded on boot (load exactly once).
    snippets_loaded: bool = false,
    /// True while a snippet write (insert/update/delete/setlang) is in flight,
    /// so the new snippet's id recovery (MAX(id)) can't race a second write.
    snippet_writing: bool = false,
    /// Transient status/toast for materials actions (e.g. "Copied to clipboard").
    snippet_status_buf: [128]u8 = undefined,
    snippet_status_len: usize = 0,
    /// The selected material's "Saved …" subtitle (mockup), computed against
    /// "now" when the detail loads (accessors have no clock, so we precompute).
    saved_ago_buf: [64]u8 = undefined,
    saved_ago_len: usize = 0,

    pub fn selectedModel(self: *const Model) []const u8 {
        if (self.selected_model_len == 0) return models.default_model_id;
        return self.selected_model_buf[0..self.selected_model_len];
    }
    fn setSelectedModel(self: *Model, id: []const u8) void {
        self.selected_model_len = @min(id.len, self.selected_model_buf.len);
        @memcpy(self.selected_model_buf[0..self.selected_model_len], id[0..self.selected_model_len]);
    }
    /// The catalog as picker rows for the view's `<for each>`. Rebuilt into
    /// inline storage by `refreshModelChoices` whenever the selection
    /// changes; the accessor just returns the slice.
    pub fn modelChoices(self: *const Model) []const ModelChoice {
        return self.model_choices[0..models.catalog.len];
    }
    /// Refill `model_choices` from the static catalog + current selection,
    /// computing each card's size + RAM labels into its inline buffers.
    /// Public so view-build tests can seed a Model with populated cards.
    pub fn refreshModelChoices(self: *Model) void {
        const sel = self.selectedModel();
        for (models.catalog, 0..) |m, i| {
            var choice = ModelChoice{
                .index = i,
                .name = m.display_name,
                .blurb = m.blurb,
                .selected = std.mem.eql(u8, m.id, sel),
                .recommended = m.recommended,
                .tierLabel = m.tier.label(),
            };
            const size = models.formatSize(&choice.size_buf, m.size_bytes);
            choice.size_len = size.len;
            const ram = models.formatRam(&choice.ram_buf, m.min_ram_bytes);
            choice.ram_len = ram.len;
            // One-line caption: "<size> · <ram>" (or just the size when RAM
            // is unknown). Built from the two labels just computed.
            const spec = if (ram.len > 0)
                std.fmt.bufPrint(&choice.spec_buf, "{s} · {s}", .{ size, ram }) catch size
            else
                std.fmt.bufPrint(&choice.spec_buf, "{s}", .{size}) catch size;
            choice.spec_len = spec.len;
            self.model_choices[i] = choice;
        }
    }
    /// Display name of the selected model (falls back to its id).
    pub fn selectedModelName(self: *const Model) []const u8 {
        const m = models.findModel(self.selectedModel()) orelse return self.selectedModel();
        return m.display_name;
    }
    /// A one-line status for the model/runtime, shown under the picker.
    pub fn modelStatusText(self: *const Model) []const u8 {
        if (self.downloading) return "Downloading model…";
        if (self.download_failed) return "Download failed — check your connection and retry.";
        if (self.llama_ready) return "Model ready.";
        if (self.llama_failed) return "Model runtime unavailable (llama-server not found).";
        if (self.model_present) return "Model downloaded. Starting runtime…";
        return "Model not downloaded yet.";
    }
    /// Download progress as a whole-number percent (0–100) for the UI.
    pub fn downloadPercent(self: *const Model) i64 {
        return @intFromFloat(@round(std.math.clamp(self.download_progress, 0, 1) * 100));
    }
    /// True when the download button should be offered (model missing and
    /// not already downloading).
    pub fn canDownload(self: *const Model) bool {
        return !self.model_present and !self.downloading;
    }

    // ---- Chat accessors (Task 10) ----
    /// Loaded messages as a slice for the view's `<for each>`.
    pub fn messagesSlice(self: *const Model) []const chat.MessageEntry {
        return self.messages[0..self.message_count];
    }
    /// The assistant reply currently streaming in (empty when idle).
    pub fn streamingText(self: *const Model) []const u8 {
        return self.streaming_buf[0..self.streaming_len];
    }
    /// True while a reply is streaming (drives the in-progress bubble).
    pub fn isStreaming(self: *const Model) bool {
        return self.streaming;
    }
    /// The Send button is offered only when the runtime is up and no turn is
    /// already in flight.
    pub fn canSend(self: *const Model) bool {
        return self.llama_ready and !self.sending;
    }
    /// Inverse of `canSend`, for the button's `disabled` binding.
    pub fn sendDisabled(self: *const Model) bool {
        return !self.canSend();
    }
    /// The single-click summary cards (Task 11) share the same gate as Send:
    /// offered only when the runtime is up and no turn is already in flight.
    pub fn summaryDisabled(self: *const Model) bool {
        return !self.canSend();
    }
    /// The summary cards for the view's `<for each>`. `tag` is the
    /// `SummaryKind` enum tag NAME — markup coerces it to the enum for
    /// `on-press="start_summary:{c.tag}"` (the runtime does
    /// `std.meta.stringToEnum`). Static strings, so no owned storage needed.
    pub fn summaryCards(self: *const Model) []const SummaryCard {
        _ = self;
        return &summary_cards;
    }
    /// A one-line status for the chat area.
    pub fn chatStatusText(self: *const Model) []const u8 {
        if (self.chat_error_len > 0) return self.chat_error_buf[0..self.chat_error_len];
        const summary = self.pending_summary_kind != null;
        if (self.streaming) return if (summary) "Writing your summary…" else "Blocks is thinking…";
        if (self.sending) return if (summary) "Gathering your recent activity…" else "Searching your memory…";
        if (!self.llama_ready) return self.modelStatusText();
        return "Ask about your recent work, or tap a summary above.";
    }
    /// Whether to surface the chat status line above the composer: only when
    /// there's something worth saying (an error, a turn in flight, or the
    /// runtime not yet ready) — never the idle hint, which would just be a
    /// redundant echo of the placeholder.
    pub fn showChatStatus(self: *const Model) bool {
        return self.chat_error_len > 0 or self.sending or self.streaming or !self.llama_ready;
    }
    /// True when there is nothing to show yet (empty-state hint).
    pub fn chatEmpty(self: *const Model) bool {
        return self.message_count == 0 and !self.streaming;
    }
    /// The chat-history sidebar list (newest-first) for the view's `<for each>`.
    pub fn chatList(self: *const Model) []const chat.ChatEntry {
        return self.chat_list[0..self.chat_count];
    }
    /// True when the user has at least one saved chat (drives the empty hint).
    pub fn hasChats(self: *const Model) bool {
        return self.chat_count > 0;
    }
    /// The active chat's title, shown above the transcript ("" when none, so
    /// the header collapses on a brand-new chat).
    pub fn chatTitleText(self: *const Model) []const u8 {
        return self.chat_title_buf[0..self.chat_title_len];
    }
    /// True when a chat title should be shown above the transcript.
    pub fn hasChatTitle(self: *const Model) bool {
        return self.chat_title_len > 0;
    }
    fn setChatTitle(self: *Model, text: []const u8) void {
        self.chat_title_len = @min(text.len, self.chat_title_buf.len);
        @memcpy(self.chat_title_buf[0..self.chat_title_len], text[0..self.chat_title_len]);
    }
    /// Whether a given history row is the active (open) chat — drives the
    /// sidebar highlight. Used by the per-row view function.
    pub fn isActiveChat(self: *const Model, id: i64) bool {
        return self.current_chat_id == id and id != 0;
    }
    /// The user's avatar initials (first letter of the detected username,
    /// uppercased), for the sidebar avatar circle.
    pub fn avatarInitials(self: *const Model) []const u8 {
        return self.avatar_initials_buf[0..self.avatar_initials_len];
    }
    /// Derive the avatar initials from `username` (first alnum letter,
    /// uppercased; falls back to "?"). Called once the username is known.
    fn refreshAvatarInitials(self: *Model) void {
        for (self.username) |c| {
            if (std.ascii.isAlphanumeric(c)) {
                self.avatar_initials_buf[0] = std.ascii.toUpper(c);
                self.avatar_initials_len = 1;
                return;
            }
        }
        self.avatar_initials_buf[0] = '?';
        self.avatar_initials_len = 1;
    }
    fn pendingUser(self: *const Model) []const u8 {
        return self.pending_user_buf[0..self.pending_user_len];
    }
    fn setPendingUser(self: *Model, text: []const u8) void {
        self.pending_user_len = @min(text.len, self.pending_user_buf.len);
        @memcpy(self.pending_user_buf[0..self.pending_user_len], text[0..self.pending_user_len]);
    }
    fn contextText(self: *const Model) []const u8 {
        return self.context_buf[0..self.context_len];
    }
    fn setContext(self: *Model, text: []const u8) void {
        self.context_len = @min(text.len, self.context_buf.len);
        @memcpy(self.context_buf[0..self.context_len], text[0..self.context_len]);
    }
    fn appendStreaming(self: *Model, delta: []const u8) void {
        const room = self.streaming_buf.len - self.streaming_len;
        const n = @min(delta.len, room);
        @memcpy(self.streaming_buf[self.streaming_len .. self.streaming_len + n], delta[0..n]);
        self.streaming_len += n;
    }
    fn setChatError(self: *Model, msg: []const u8) void {
        self.chat_error_len = @min(msg.len, self.chat_error_buf.len);
        @memcpy(self.chat_error_buf[0..self.chat_error_len], msg[0..self.chat_error_len]);
    }
    fn clearChatError(self: *Model) void {
        self.chat_error_len = 0;
    }
    /// Append a message to the in-memory list (bounded), for immediate
    /// display; the DB is the source of truth on the next reload. Public so
    /// update-arm tests can seed a conversation.
    pub fn pushMessage(self: *Model, role: chat.Role, text: []const u8) void {
        if (self.message_count >= chat.max_messages) return;
        self.messages[self.message_count] = chat.MessageEntry.set(role, text);
        self.messages[self.message_count].index = @intCast(self.message_count);
        self.message_count += 1;
    }

    // ---- Navigation accessors (Task 12) ----
    pub fn onChatScreen(self: *const Model) bool {
        return self.screen == .chat;
    }
    pub fn onMaterialsScreen(self: *const Model) bool {
        return self.screen == .materials;
    }

    // ---- Onboarding accessors (Task 13) ----
    /// True while the full-screen onboarding overlay should be shown.
    pub fn needsOnboarding(self: *const Model) bool {
        return !self.onboarded;
    }
    pub fn onWelcomeStep(self: *const Model) bool {
        return !self.onboarded and self.onboard_step == .welcome;
    }
    pub fn onPickModelStep(self: *const Model) bool {
        return !self.onboarded and self.onboard_step == .pick_model;
    }
    /// The welcome-splash description paragraph (mockup 4).
    pub fn welcomeBlurb(self: *const Model) []const u8 {
        _ = self;
        return welcome_blurb;
    }
    /// The onboarding "Install" button label: kicks off (or reflects) the
    /// selected model's download.
    pub fn installLabel(self: *const Model) []const u8 {
        if (self.model_present or self.llama_ready) return "Continue";
        if (self.downloading) return "Downloading…";
        return "Install";
    }
    /// The onboarding Install/Continue button is disabled while a download
    /// is mid-flight (the label shows the progress via `modelStatusText`).
    pub fn installDisabled(self: *const Model) bool {
        return self.downloading;
    }

    // ---- Settings modal accessors (Task 13) ----
    pub fn settingsOpen(self: *const Model) bool {
        return self.settings_open;
    }
    /// The current Settings-window canvas label (`settings-canvas-<n>`),
    /// read by `windows_fn`. Falls back to the base label before the first
    /// open (count 0).
    pub fn settingsCanvasLabel(self: *const Model) []const u8 {
        if (self.settings_canvas_len == 0) return settings_canvas_label;
        return self.settings_canvas_buf[0..self.settings_canvas_len];
    }
    /// Rewrite `settings_canvas_buf` to `settings-canvas-<open_count>`; called
    /// from the `open_settings` arm (which owns a mutable Model).
    fn refreshSettingsCanvasLabel(self: *Model) void {
        const s = std.fmt.bufPrint(&self.settings_canvas_buf, "{s}-{d}", .{ settings_canvas_label, self.settings_open_count }) catch settings_canvas_label;
        self.settings_canvas_len = s.len;
    }
    /// The current material-editor canvas label (`material-canvas-<n>`), read
    /// by `windows_fn`. Falls back to the base label before the first open.
    pub fn editorCanvasLabel(self: *const Model) []const u8 {
        if (self.editor_canvas_len == 0) return editor_canvas_label;
        return self.editor_canvas_buf[0..self.editor_canvas_len];
    }
    /// Rewrite `editor_canvas_buf` to `material-canvas-<open_count>`; called
    /// from `openEditor` (a fresh label each open, like Settings).
    fn refreshEditorCanvasLabel(self: *Model) void {
        const s = std.fmt.bufPrint(&self.editor_canvas_buf, "{s}-{d}", .{ editor_canvas_label, self.editor_open_count }) catch editor_canvas_label;
        self.editor_canvas_len = s.len;
    }
    /// The current delete-confirmation canvas label (`confirm-delete-canvas-<n>`),
    /// read by `windows_fn`. Falls back to the base label before the first open.
    pub fn confirmDeleteCanvasLabel(self: *const Model) []const u8 {
        if (self.confirm_delete_canvas_len == 0) return confirm_delete_canvas_label;
        return self.confirm_delete_canvas_buf[0..self.confirm_delete_canvas_len];
    }
    fn refreshConfirmDeleteCanvasLabel(self: *Model) void {
        const s = std.fmt.bufPrint(&self.confirm_delete_canvas_buf, "{s}-{d}", .{ confirm_delete_canvas_label, self.confirm_delete_open_count }) catch confirm_delete_canvas_label;
        self.confirm_delete_canvas_len = s.len;
    }
    /// The confirmation prompt sentence shown in the dialog window.
    pub fn confirmDeletePrompt(self: *const Model) []const u8 {
        return self.confirm_delete_prompt_buf[0..self.confirm_delete_prompt_len];
    }
    /// The dialog window's title/heading, matching what's being deleted.
    pub fn confirmDeleteTitle(self: *const Model) []const u8 {
        return switch (self.confirm_delete_kind) {
            .material => "Delete material",
            .chat => "Delete chat",
        };
    }
    pub fn settingsAbout(self: *const Model) bool {
        return self.settings_section == .about or self.settings_section == .all;
    }
    pub fn settingsMcp(self: *const Model) bool {
        return self.settings_section == .mcp or self.settings_section == .all;
    }
    pub fn settingsLocalModel(self: *const Model) bool {
        return self.settings_section == .local_model or self.settings_section == .all;
    }
    pub fn settingsRepos(self: *const Model) bool {
        // Watched Repositories are their own section (also shown under "All").
        return self.settings_section == .all or self.settings_section == .repos;
    }
    /// The app version string, shown in Settings › About (mockup 3).
    pub fn appVersionText(self: *const Model) []const u8 {
        _ = self;
        return app_version;
    }
    /// The MCP server URL, shown in Settings › MCP with a copy button.
    pub fn mcpUrlText(self: *const Model) []const u8 {
        _ = self;
        return mcp_url;
    }
    /// The local runtime (OpenAI-compatible) URL, shown in Settings › MCP.
    pub fn llamaUrlText(self: *const Model) []const u8 {
        _ = self;
        return llama_url;
    }
    // ---- Materials / snippets accessors (Task 12) ----
    /// The loaded snippets, further narrowed by the "Find materials…" text
    /// (client-side substring match over title + blurb). The language filter
    /// and sort are applied server-side by the reload query; search is applied
    /// here so typing doesn't hit the DB per keystroke. NOTE: returns a slice
    /// into a per-call static scratch of indices is overkill — instead the
    /// view iterates `snippetList()` and each row exposes `matchesSearch`.
    pub fn snippetList(self: *const Model) []const snippets.SnippetEntry {
        return self.snippet_list[0..self.snippet_count];
    }
    /// The count badge in the sidebar ("N/total"): matches shown / total loaded.
    pub fn snippetCount(self: *const Model) i64 {
        return @intCast(self.snippet_count);
    }
    pub fn languageList(self: *const Model) []const snippets.LanguageEntry {
        return self.languages[0..self.language_count];
    }
    pub fn snippetSearchText(self: *const Model) []const u8 {
        return self.snippet_search.text();
    }
    pub fn hasSnippets(self: *const Model) bool {
        return self.snippet_count > 0;
    }
    pub fn noSnippets(self: *const Model) bool {
        return self.snippet_count == 0;
    }
    pub fn snippetSelected(self: *const Model) bool {
        return self.selected_snippet_id != 0 and self.selected_detail.id == self.selected_snippet_id;
    }
    pub fn noSnippetSelected(self: *const Model) bool {
        return !self.snippetSelected();
    }

    /// The editor's current content text (bound by the editable `<code>`).
    pub fn editContent(self: *const Model) []const u8 {
        return self.edit_content.text();
    }
    /// The selected snippet's LIST CARD (or null when not in the loaded list).
    pub fn selectedCard(self: *const Model) ?*const snippets.SnippetEntry {
        for (self.snippet_list[0..self.snippet_count]) |*e| {
            if (e.id == self.selected_snippet_id) return e;
        }
        return null;
    }
    /// The selected snippet's full detail (valid when `id` matches the selection).
    fn detail(self: *const Model) ?*const snippets.SnippetDetail {
        if (self.selected_detail.id != 0 and self.selected_detail.id == self.selected_snippet_id)
            return &self.selected_detail;
        return null;
    }
    pub fn selectedTitle(self: *const Model) []const u8 {
        return if (self.detail()) |d| d.title() else "";
    }
    pub fn selectedContent(self: *const Model) []const u8 {
        return if (self.detail()) |d| d.content() else "";
    }
    pub fn selectedLanguage(self: *const Model) []const u8 {
        return if (self.detail()) |d| d.language() else "";
    }
    pub fn selectedAnnotation(self: *const Model) []const u8 {
        return if (self.detail()) |d| d.annotation() else "";
    }
    pub fn selectedTextExpander(self: *const Model) []const u8 {
        return if (self.detail()) |d| d.textExpander() else "";
    }
    /// The selected material's "Saved …" subtitle (precomputed on load).
    pub fn selectedSavedAgo(self: *const Model) []const u8 {
        return self.saved_ago_buf[0..self.saved_ago_len];
    }
    pub fn langFilter(self: *const Model) []const u8 {
        return self.lang_filter_buf[0..self.lang_filter_len];
    }
    /// The active filter's display label for the sidebar ("All" when none).
    pub fn langFilterLabel(self: *const Model) []const u8 {
        return if (self.lang_filter_len == 0) "All" else self.langFilter();
    }
    pub fn sortLabel(self: *const Model) []const u8 {
        return switch (self.snippet_sort) {
            .recent => "Recent",
            .alphabetical => "Alphabetical",
        };
    }
    pub fn sortMenuOpen(self: *const Model) bool {
        return self.sort_menu_open;
    }
    pub fn langMenuOpen(self: *const Model) bool {
        return self.lang_menu_open;
    }
    pub fn editorOpen(self: *const Model) bool {
        return self.editor_open;
    }
    pub fn editorTitleLabel(self: *const Model) []const u8 {
        return if (self.editing_id == 0) "New material" else "Edit material";
    }
    pub fn snippetStatus(self: *const Model) []const u8 {
        return self.snippet_status_buf[0..self.snippet_status_len];
    }
    /// Whether a materials toast/status line is currently set (so the view
    /// only shows the status text when there's something to say — no box).
    pub fn hasSnippetStatus(self: *const Model) bool {
        return self.snippet_status_len > 0;
    }
    fn setSnippetStatus(self: *Model, msg: []const u8) void {
        self.snippet_status_len = @min(msg.len, self.snippet_status_buf.len);
        @memcpy(self.snippet_status_buf[0..self.snippet_status_len], msg[0..self.snippet_status_len]);
    }
    fn setLangFilter(self: *Model, lang: []const u8) void {
        self.lang_filter_len = @min(lang.len, self.lang_filter_buf.len);
        @memcpy(self.lang_filter_buf[0..self.lang_filter_len], lang[0..self.lang_filter_len]);
    }

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
    pub fn isAddingRepo(self: *const Model) bool {
        return self.adding_repo;
    }
    /// The app-data directory path, surfaced in the Settings modal.
    pub fn dataDirText(self: *const Model) []const u8 {
        return self.data_dir;
    }

    // These fields/accessors are read by update/effect logic or via accessor
    // functions (usernameText/dataDirText/…), or are TextBuffers the
    // text-fields drive through their on-input handlers, not bound directly
    // in markup — so they are intentionally exempt from the dead-state lint.
    pub const view_unbound = .{
        "onboarded",        "username",
        "avatar_initials_buf", "avatar_initials_len",
        "data_dir",         "repo_list",        "repo_count",       "adding_repo",
        "repo_input",       "chat_input",
        "repo_error_buf",   "repo_error_len",   "pending_path_buf", "pending_path_len",
        "capturing",        "capture_idx",      "capture_repo_id",  "capture_path_buf",
        "capture_path_len", "capture_since_buf", "capture_since_len",
        "capturePath",      "captureSince",
        // Working-tree snapshot scan (Task 5).
        "scanning",           "scan_timer_started", "scan_repo_idx",   "scan_repo_id",
        "scan_repo_path_buf", "scan_repo_path_len", "scan_paths",      "scan_path_count",
        "scan_file_idx",      "scan_content_buf",   "scan_content_len", "scan_hash_buf",
        "scan_last_hash_buf", "scan_last_hash_len", "scanRepoPath",
        // Embedding generation (Task 7).
        "embedding",          "embed_phase",       "embed_last_rows",
        // MCP server child process (Task 8).
        "mcp_started",        "mcp_ready",         "mcp_failed",     "mcp_health_attempts",
        // Local model management + llama.cpp runtime (Task 9).
        "selected_model_buf", "selected_model_len", "model_present",  "downloading",
        "download_progress",  "download_failed",    "llama_started",  "llama_ready",
        "llama_failed",       "selectedModel",       "model_choices",
        "selectedModelName",  "downloadPercent",     "llama_health_attempts",
        "refreshModelChoices",
        // Chat experience (Task 10). chat_input is bound (text-field), and
        // messagesSlice/streamingText/isStreaming/canSend/chatStatusText/
        // chatEmpty are bound in markup — the rest are update/effect state.
        "current_chat_id",    "next_seq",           "messages",       "message_count",
        "chat_list",          "chat_count",         "chats_loaded",   "chat_title_buf",
        "chat_title_len",
        "pending_user_buf",   "pending_user_len",   "streaming_buf",  "streaming_len",
        "context_buf",        "context_len",        "sending",        "streaming",
        "finalizing",         "chat_error_buf",     "chat_error_len", "pushMessage",
        "canSend",
        // Single-click summaries (Task 11). `pending_summary_kind` is
        // per-turn update state; `summaryDisabled` is retained for tests
        // (the Task 13 cards are tappable columns gated in `startSummary`).
        "pending_summary_kind", "summaryDisabled",
        // Onboarding + Settings (Task 13). needsOnboarding/onWelcomeStep/
        // onPickModelStep/welcomeBlurb/installLabel/installDisabled are bound
        // in the onboarding markup; the SETTINGS accessors below are read
        // only by the Zig-built settings WINDOW (`window_view` in main.zig),
        // not markup — so they live here alongside the update-only fields.
        "onboard_step",         "settings_open",       "settings_section",
        "settings_open_count",  "settings_canvas_buf", "settings_canvas_len",
        "settingsOpen",         "settingsAbout",       "settingsMcp",
        "settingsLocalModel",   "settingsRepos",       "appVersionText",
        "mcpUrlText",           "llamaUrlText",
        "dataDirText",          "repoError",           "isAddingRepo",
        "reposSlice",           "canDownload",         "settingsCanvasLabel",
        "refreshSettingsCanvasLabel",
        // The material EDITOR window (Task 12 editor, now a Zig-built
        // secondary window like Settings): these accessors are read by
        // `editorWindowView`/`blocksWindows`/tests, not markup.
        "editorCanvasLabel",    "refreshEditorCanvasLabel",
        "editorOpen",           "editorTitleLabel",    "editContent",
        // The delete-confirmation dialog window (also Zig-built): fields +
        // accessors read by `confirmDeleteWindowView`/`blocksWindows`, not markup.
        "confirm_delete_open",  "confirm_delete_open_count",
        "confirm_delete_canvas_buf", "confirm_delete_canvas_len",
        "confirm_delete_prompt_buf", "confirm_delete_prompt_len",
        "confirm_delete_kind",      "confirm_delete_chat_id",
        "confirmDeleteCanvasLabel", "refreshConfirmDeleteCanvasLabel",
        "confirmDeletePrompt",      "confirmDeleteTitle",
        // Navigation + Materials / snippets (Task 12). The list/menu/editor
        // accessors are bound in markup; these are the update/effect-only
        // fields + the text-field buffers (driven via on-input, not bound).
        "screen",
        "snippet_list",         "snippet_count",       "languages",          "language_count",
        "selected_snippet_id",  "selected_detail",     "snippet_sort",       "lang_filter_buf",
        "lang_filter_len",
        "snippet_search",       "sort_menu_open",      "lang_menu_open",     "editor_open",
        "editing_id",           "edit_title",          "edit_content",       "edit_language",
        "edit_annotation",      "edit_text_expander",
        "snippet_writing",      "snippet_status_buf",  "snippet_status_len",
        "saved_ago_buf",        "saved_ago_len",
        "editor_open_count",    "editor_canvas_buf",   "editor_canvas_len",
        "snippets_loaded",
        // Accessors read only from update/other-accessor logic (not bound in
        // markup): the search text drives a reload; selectedLanguage feeds
        // the editor prefill; langFilter feeds the reload query.
        "snippetSearchText",    "selectedLanguage",    "langFilter",
    };
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

    // Tray (Task 6)
    open_window, // tray "Open Blocks" — reveal the main window
    quit_app, // tray "Quit Blocks"

    // Embedding generation (Task 7)
    embed_events_page: native_sdk.EffectDbResult, // un-embedded events query
    embed_snaps_page: native_sdk.EffectDbResult, // un-embedded snapshots query
    embed_write_done: native_sdk.EffectDbResult, // embeddings+fts insert result

    // MCP server child process (Task 8)
    mcp_exit: native_sdk.EffectExit, // the child process exited/failed to spawn
    mcp_health_tick: native_sdk.EffectTimer, // delay elapsed -> run the health check
    mcp_health_done: native_sdk.EffectResponse, // tools/list health-check response

    // Local model management + llama.cpp runtime (Task 9)
    config_read_done: native_sdk.EffectFileResult, // read config.json for selected model
    model_stat_done: native_sdk.EffectFileResult, // stat the model file (present?)
    download_model, // UI: start downloading the selected model
    select_model: usize, // UI: choose catalog[index] as the selected model
    download_progress_line: native_sdk.EffectLine, // a curl progress line
    download_done: native_sdk.EffectExit, // curl finished (ok/failed)
    model_renamed: native_sdk.EffectExit, // mv .part -> final finished
    llama_exit: native_sdk.EffectExit, // the runtime child exited/failed to spawn
    llama_health_tick: native_sdk.EffectTimer, // delay elapsed -> run the health check
    llama_health_done: native_sdk.EffectResponse, // /health response

    // Chat experience (Task 10)
    chat_input_edit: canvas.TextInputEvent, // typing in the chat field
    send_chat, // Send pressed (or field submitted)
    mcp_search_done: native_sdk.EffectResponse, // search_memory result -> build context
    chat_line: native_sdk.EffectLine, // one streamed SSE line from the runtime
    chat_done: native_sdk.EffectResponse, // the completion stream ended (terminal)
    chat_inserted: native_sdk.EffectDbResult, // new chats row insert result
    chat_rowid_done: native_sdk.EffectDbResult, // last_insert_rowid() for the new chat
    chat_write_done: native_sdk.EffectDbResult, // the turn's messages persisted
    messages_listed: native_sdk.EffectDbResult, // a chat's messages reload
    chats_listed: native_sdk.EffectDbResult, // the chat-history sidebar list reload
    select_chat: i64, // open a saved chat from the history sidebar
    new_chat, // "+ New chat" — reset to a fresh conversation
    request_delete_chat: i64, // trash on a chat row — open the confirm dialog for it
    chat_deleted: native_sdk.EffectDbResult, // a chat DELETE completed — reload the list

    // Single-click summaries (Task 11)
    start_summary: chat.SummaryKind, // a summary card was tapped
    mcp_activity_done: native_sdk.EffectResponse, // get_activity result -> build context

    // Navigation (Task 12)
    show_chat, // top-level nav: show the Chat screen
    show_materials, // top-level nav: show the Materials screen

    // Onboarding + Settings (Task 13)
    onboard_next, // welcome "Get Started" -> the model-picker step
    onboard_finish, // model-picker "Install"/"Continue" -> enter the app
    open_settings, // open the Settings modal
    close_settings, // close the Settings modal
    settings_all, // Settings nav: All
    settings_about, // Settings nav: About
    settings_repos, // Settings nav: Watched Repositories
    settings_mcp, // Settings nav: Model Context Protocol
    settings_local_model, // Settings nav: Local Model
    copy_mcp_url, // copy the MCP server URL to the clipboard
    copy_llama_url, // copy the runtime URL to the clipboard
    copy_data_dir, // copy the app-data folder path to the clipboard
    url_clip_done: native_sdk.EffectClipboardResult, // URL clipboard write result
    config_persisted: native_sdk.EffectFileResult, // config.json rewrite (model/onboarding)

    // Materials / snippets (Task 12)
    snippets_listed: native_sdk.EffectDbResult, // snippets list query page/done
    languages_listed: native_sdk.EffectDbResult, // distinct-languages query page/done
    select_snippet: i64, // a sidebar card was tapped (select by id)
    snippet_search_edit: canvas.TextInputEvent, // typing in "Find materials…"
    toggle_sort_menu, // open/close the SORT BY menu
    sort_recent, // choose the Recent sort
    sort_alphabetical, // choose the Alphabetical sort
    toggle_lang_menu, // open/close the language-filter menu
    clear_lang_filter, // "All" — clear the language filter
    set_lang_filter: usize, // choose a filter language (filterIndex = position+1)
    open_new_snippet, // "+" — open a blank editor
    open_edit_snippet, // pencil — load the selected snippet into the editor
    edit_title_edit: canvas.TextInputEvent,
    edit_content_edit: canvas.TextInputEvent,
    edit_language_edit: canvas.TextInputEvent,
    edit_annotation_edit: canvas.TextInputEvent,
    edit_text_expander_edit: canvas.TextInputEvent,
    save_snippet, // commit the editor (insert or update)
    cancel_editor, // discard the editor (Cancel button in the editor window)
    close_editor, // the editor window's native red-button close
    request_delete_snippet, // trash — open the delete-confirmation dialog window
    confirm_delete, // dialog "Yes, delete it!" — actually delete
    cancel_delete, // dialog Cancel (or native close) — dismiss without deleting
    copy_snippet, // copy icon — copy the selected snippet to the clipboard
    snippet_clip_done: native_sdk.EffectClipboardResult, // clipboard write result
    start_copilot_chat, // "Start Copilot Chat" — seed a new chat from the snippet
    snippet_inserted: native_sdk.EffectDbResult, // new snippet insert result
    snippet_rowid_done: native_sdk.EffectDbResult, // MAX(id) recovery for a new snippet
    snippet_write_done: native_sdk.EffectDbResult, // update/delete/setlang result
    snippet_detail_loaded: native_sdk.EffectDbResult, // selected snippet's full body
    save_to_snippets: i64, // "Save to Snippets" from a chat message (by seq index)

    // Delivered by effects/host, never bound as markup handlers.
    pub const view_unbound = .{
        "stat_config",         "wrote_config",       "wrote_keep",
        "git_check_done",      "repo_inserted",      "repos_listed",
        "repo_removed",        "capture_since_done", "capture_log_done",
        "capture_write_done",  "snapshot_tick",      "snap_status_done",
        "snap_lasthash_done",  "snap_content_done",  "snap_diff_done",
        "snap_write_done",     "open_window",        "quit_app",
        "embed_events_page",   "embed_snaps_page",   "embed_write_done",
        "mcp_exit",            "mcp_health_tick",    "mcp_health_done",
        // Task 9 effect-delivered arms (download_model/select_model ARE
        // bound as markup handlers, so they are intentionally omitted).
        "config_read_done",    "model_stat_done",    "download_progress_line",
        "download_done",       "model_renamed",      "llama_exit",
        "llama_health_tick",   "llama_health_done",
        // Task 10 effect-delivered arms (send_chat/chat_input_edit ARE
        // bound as markup handlers, so they are intentionally omitted).
        "mcp_search_done",     "chat_line",          "chat_done",
        "chat_inserted",       "chat_rowid_done",    "chat_write_done",
        "messages_listed",     "chats_listed",       "chat_deleted",
        // Task 11 effect-delivered arm (start_summary IS bound as a markup
        // handler, so it is intentionally omitted).
        "mcp_activity_done",
        // Task 12 effect-delivered arms (the select/toggle/open-editor/
        // delete/copy + the set-language-modal + start_copilot_chat arms ARE
        // bound as markup handlers, so they are intentionally omitted).
        "snippets_listed",  "languages_listed",  "snippet_clip_done",
        "snippet_inserted", "snippet_rowid_done", "snippet_write_done",
        "snippet_detail_loaded",
        // The material EDITOR is now a SEPARATE OS window (like Settings),
        // built in Zig by `window_view` — so its Save/Cancel/close + the five
        // edit_*_edit on-input arms are dispatched from that window, NOT
        // markup, and belong here. (open_new_snippet/open_edit_snippet stay
        // markup-bound: the FAB + pencil live on the main canvas.)
        "save_snippet",     "cancel_editor",     "close_editor",
        "edit_title_edit",  "edit_content_edit", "edit_language_edit",
        "edit_annotation_edit", "edit_text_expander_edit",
        // The delete-confirmation dialog window's buttons (confirm/cancel) are
        // dispatched from its Zig `window_view`, not markup. (The trash button
        // `request_delete_snippet` stays markup-bound on the main canvas.)
        "confirm_delete",   "cancel_delete",
        // Task 13. onboard_next/onboard_finish/open_settings are bound in
        // the main markup; the SETTINGS-window controls (close_settings,
        // settings_all/about/mcp/local_model, copy_*_url, download_model,
        // and the repos add/remove/input Msgs) are dispatched from the
        // Zig-built settings window (`window_view`), not markup, so they're
        // listed here. url_clip_done/config_persisted are effect results.
        // (add_repo_clicked/repo_input_edit/remove_repo live here from Task 3
        // now that Watched Repositories lives only in the settings window.)
        "url_clip_done",   "config_persisted",
        "close_settings",  "settings_all",       "settings_about",
        "settings_repos",  "settings_mcp",       "settings_local_model",
        "copy_mcp_url",
        "copy_llama_url",  "copy_data_dir",      "download_model",
        "repo_input_edit", "add_repo_clicked",   "remove_repo",
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
    model.refreshAvatarInitials();

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
                // Returning user: config already present. Read it to learn
                // the selected model AND the onboarded flag (`config_read_
                // done` sets both). We must NOT infer onboarded from mere
                // file existence — a user who quit mid-onboarding has a
                // config with `onboarded:false` and should see the flow.
                readConfig(fx);
            } else {
                // First run: create the directory tree + default config.
                writeAnchors(model, fx);
            }
            // Either way the DB is ready — load the watched-repo list.
            listRepos(fx);
        },
        .wrote_config => |res| {
            if (res.outcome == .ok) {
                model.onboarded = false;
                // First-run config just written with the default model id;
                // check whether that model is already on disk.
                statSelectedModel(model, fx);
            }
        },

        // ---- Local model management + llama.cpp runtime (Task 9) ----
        .config_read_done => |res| {
            if (res.outcome == .ok and res.bytes.len > 0) {
                if (models.parseSelectedModel(res.bytes)) |id| model.setSelectedModel(id);
                // Adopt the persisted onboarded flag. Absent (a config that
                // predates the flag) is treated as NOT onboarded, so the
                // welcome flow runs once and then persists `true`.
                model.onboarded = models.parseOnboarded(res.bytes) orelse false;
            }
            model.refreshModelChoices();
            // Now that we know which model is selected, see if it's present.
            statSelectedModel(model, fx);
        },
        .model_stat_done => |res| {
            model.model_present = (res.outcome == .ok and res.exists);
            // If the model is already downloaded, bring up the runtime.
            if (model.model_present) startLlama(model, fx);
        },
        .select_model => |idx| {
            if (idx >= models.catalog.len) return;
            model.setSelectedModel(models.catalog[idx].id);
            model.refreshModelChoices();
            model.model_present = false;
            model.download_failed = false;
            model.download_progress = 0;
            // Persist the choice, then re-check presence for the new model.
            persistConfig(model, fx);
            statSelectedModel(model, fx);
        },
        .download_model => startDownload(model, fx),
        .download_progress_line => |line| {
            if (line.key != key_model_download) return;
            if (models.parseProgress(line.line)) |p| model.download_progress = p;
        },
        .download_done => |exit| downloadDone(model, exit, fx),
        .model_renamed => |exit| modelRenamed(model, exit, fx),
        .llama_exit => |exit| {
            _ = exit;
            model.llama_ready = false;
            model.llama_failed = true;
        },
        .llama_health_tick => |timer| {
            if (timer.outcome == .rejected) return;
            model.llama_health_attempts += 1;
            healthCheckLlama(fx);
        },
        .llama_health_done => |res| {
            if (res.outcome == .ok and res.status == 200) {
                // The runtime is serving — memory + chat tools are reachable.
                model.llama_ready = true;
                model.llama_failed = false;
            } else if (!model.llama_ready) {
                // Still loading (connection refused while the model warms up)
                // or a transient error: retry with a fixed backoff until the
                // attempt cap, then give up (non-fatal — the UI can offer a
                // manual retry, and Task 10 wires that).
                if (model.llama_health_attempts < llama_health_max_attempts) {
                    armLlamaHealth(llama_health_retry_ms, fx);
                } else {
                    model.llama_failed = true;
                }
            }
        },

        // ---- Chat experience (Task 10) ----
        .chat_input_edit => |event| {
            model.chat_input.apply(event);
            model.clearChatError();
        },
        .send_chat => sendChat(model, fx),
        .mcp_search_done => |res| mcpSearchDone(model, res, fx),
        .chat_line => |line| {
            if (line.key != key_llama_chat) return;
            if (!model.streaming) return;
            var scratch: [chat.max_content_bytes]u8 = undefined;
            switch (chat.parseStreamLine(line.line, &scratch)) {
                .delta => |d| model.appendStreaming(d),
                // Finalize on the `[DONE]` sentinel: llama-server keeps the
                // connection open (keep-alive) after `[DONE]`, so the terminal
                // `chat_done` response lags by the whole stream timeout. The
                // sentinel is the reliable end-of-turn signal. `finalizeChat`
                // is idempotent, so a later `chat_done` is a no-op.
                .done => finalizeChat(model, true, fx),
                .ignore => {},
            }
        },
        .chat_done => |res| {
            // Terminal response for the stream. If `[DONE]` already finalized
            // the turn this is a no-op; otherwise finalize (covers a clean
            // close without a `[DONE]`, or a mid-stream failure).
            const ok = res.outcome == .ok;
            finalizeChat(model, ok, fx);
        },
        .chat_inserted => |res| {
            if (res.outcome == .ok) {
                // Learn the new chat's id, then persist the turn's messages.
                fx.dbQuery(.{
                    .key = key_chat_rowid,
                    .sql = chat.max_chat_id_sql,
                    .on_result = Effects.dbMsg(.chat_rowid_done),
                });
            } else {
                model.sending = false;
                model.pending_summary_kind = null;
                model.setChatError("Could not start a new chat.");
            }
        },
        .chat_rowid_done => |res| chatRowidDone(model, res, fx),
        .chat_write_done => {
            // The turn's messages are committed — the turn is fully done now.
            // Clear the interlock (re-enabling Send) and the per-turn buffers,
            // then reload from the DB (source of truth) so ids/seqs/next_seq
            // are authoritative.
            model.sending = false;
            model.pending_user_len = 0;
            model.context_len = 0;
            model.pending_summary_kind = null;
            if (model.current_chat_id != 0) loadMessages(model.current_chat_id, fx);
            // Refresh the history sidebar so the new/updated chat rises to the
            // top with its refreshed preview.
            loadChats(fx);
        },
        .messages_listed => |res| messagesListed(model, res),
        .chats_listed => |res| chatsListed(model, res, fx.wallMs()),
        .select_chat => |id| selectChat(model, id, fx),
        .new_chat => newChat(model),
        .request_delete_chat => |id| openDeleteChatConfirm(model, id),
        .chat_deleted => |res| chatDeleted(model, res, fx),

        // ---- Single-click summaries (Task 11) ----
        .start_summary => |kind| startSummary(model, kind, fx),
        .mcp_activity_done => |res| mcpActivityDone(model, res, fx),

        // ---- Navigation (Task 12) ----
        .show_chat => model.screen = .chat,
        .show_materials => model.screen = .materials,

        // ---- Onboarding + Settings (Task 13) ----
        .onboard_next => model.onboard_step = .pick_model,
        .onboard_finish => {
            // Complete onboarding: mark it done, persist the flag (+ the
            // selected model), and — if the model isn't on disk yet — kick
            // off its download so the user lands in a working app.
            model.onboarded = true;
            persistConfig(model, fx);
            if (!model.model_present and !model.downloading) startDownload(model, fx);
        },
        .open_settings => {
            // Bump the open counter so `blocksWindows` hands the window a
            // fresh canvas label (`settings-canvas-<n>`) — a clean install
            // each time (see the note in `blocksWindows`).
            if (!model.settings_open) {
                model.settings_open_count +%= 1;
                model.refreshSettingsCanvasLabel();
            }
            model.settings_open = true;
        },
        .close_settings => model.settings_open = false,
        .settings_all => model.settings_section = .all,
        .settings_about => model.settings_section = .about,
        .settings_repos => model.settings_section = .repos,
        .settings_mcp => model.settings_section = .mcp,
        .settings_local_model => model.settings_section = .local_model,
        .copy_mcp_url => fx.writeClipboard(.{
            .key = key_snip_clip,
            .text = mcp_url,
            .on_result = Effects.clipboardMsg(.url_clip_done),
        }),
        .copy_llama_url => fx.writeClipboard(.{
            .key = key_snip_clip,
            .text = llama_url,
            .on_result = Effects.clipboardMsg(.url_clip_done),
        }),
        .copy_data_dir => fx.writeClipboard(.{
            .key = key_snip_clip,
            .text = model.data_dir,
            .on_result = Effects.clipboardMsg(.url_clip_done),
        }),
        .url_clip_done => |res| {
            // No success toast (the copy confirmation was removed, like the
            // material-copy one); clear any prior status so nothing lingers
            // behind the settings window.
            if (res.outcome == .ok) model.snippet_status_len = 0;
        },
        .config_persisted => |res| {
            // A model-change / onboarding config rewrite completed. Nothing
            // to do on success; on failure we simply keep the in-memory
            // state (the next rewrite will retry).
            _ = res;
        },

        // ---- Materials / snippets (Task 12) ----
        .snippets_listed => |res| snippetsListed(model, res),
        .languages_listed => |res| languagesListed(model, res),
        .select_snippet => |id| {
            model.selected_snippet_id = id;
            model.snippet_status_len = 0;
            refreshSelectedSnippet(model);
            loadSnippetDetail(model, id, fx);
        },
        .snippet_search_edit => |event| {
            model.snippet_search.apply(event);
            loadSnippets(model, fx);
        },
        .toggle_sort_menu => {
            model.sort_menu_open = !model.sort_menu_open;
            model.lang_menu_open = false;
        },
        .sort_recent => {
            model.snippet_sort = .recent;
            model.sort_menu_open = false;
            loadSnippets(model, fx);
        },
        .sort_alphabetical => {
            model.snippet_sort = .alphabetical;
            model.sort_menu_open = false;
            loadSnippets(model, fx);
        },
        .toggle_lang_menu => {
            model.lang_menu_open = !model.lang_menu_open;
            model.sort_menu_open = false;
        },
        .clear_lang_filter => {
            model.lang_filter_len = 0;
            model.lang_menu_open = false;
            loadSnippets(model, fx);
        },
        .set_lang_filter => |fidx| {
            // filterIndex is position+1 (index 0 is the separate "All" action),
            // so the language is languages[fidx-1].
            if (fidx >= 1 and fidx - 1 < model.language_count) {
                model.setLangFilter(model.languages[fidx - 1].name());
            }
            model.lang_menu_open = false;
            loadSnippets(model, fx);
        },
        .open_new_snippet => openEditor(model, 0),
        .open_edit_snippet => {
            if (model.selected_snippet_id != 0) openEditor(model, model.selected_snippet_id);
        },
        .edit_title_edit => |e| model.edit_title.apply(e),
        .edit_content_edit => |e| model.edit_content.apply(e),
        .edit_language_edit => |e| model.edit_language.apply(e),
        .edit_annotation_edit => |e| model.edit_annotation.apply(e),
        .edit_text_expander_edit => |e| model.edit_text_expander.apply(e),
        .save_snippet => saveSnippet(model, fx),
        .cancel_editor, .close_editor => {
            model.editor_open = false;
            model.editing_id = 0;
        },
        .request_delete_snippet => openDeleteConfirm(model),
        .confirm_delete => {
            model.confirm_delete_open = false;
            switch (model.confirm_delete_kind) {
                .material => deleteSnippet(model, fx),
                .chat => deleteChat(model, fx),
            }
        },
        .cancel_delete => model.confirm_delete_open = false,
        .copy_snippet => copySnippet(model, fx),
        .snippet_clip_done => |res| {
            // No success toast (the user asked for the copy confirmation to be
            // removed); clear any prior status so nothing lingers. A FAILED
            // copy is still surfaced.
            if (res.outcome == .ok) {
                model.snippet_status_len = 0;
            } else {
                model.setSnippetStatus("Couldn't copy to the clipboard.");
            }
        },
        .start_copilot_chat => startCopilotChat(model, fx),
        .snippet_inserted => |res| {
            if (res.outcome == .ok) {
                fx.dbQuery(.{
                    .key = key_snip_rowid,
                    .sql = snippets.max_id_sql,
                    .on_result = Effects.dbMsg(.snippet_rowid_done),
                });
            } else {
                model.snippet_writing = false;
                model.setSnippetStatus("Couldn't save the material.");
            }
        },
        .snippet_rowid_done => |res| snippetRowidDone(model, res, fx),
        .snippet_write_done => {
            model.snippet_writing = false;
            loadSnippets(model, fx);
            loadLanguages(model, fx);
            if (model.selected_snippet_id != 0) loadSnippetDetail(model, model.selected_snippet_id, fx);
        },
        .snippet_detail_loaded => |res| snippetDetailLoaded(model, res, fx.wallMs()),
        .save_to_snippets => |seq_idx| saveToSnippets(model, seq_idx, fx),

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
            // Start the MCP server child once, now that app.db exists and
            // the runner has applied migrations (the list query proves it).
            if (res.kind == .done) startMcpServer(model, fx);
            // Load the saved materials (snippets) + their languages once the
            // DB is confirmed ready (Task 12).
            if (res.kind == .done and !model.snippets_loaded) {
                model.snippets_loaded = true;
                loadSnippets(model, fx);
                loadLanguages(model, fx);
            }
            // Load the chat-history sidebar list once the DB is ready.
            if (res.kind == .done and !model.chats_loaded) {
                model.chats_loaded = true;
                loadChats(fx);
            }
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

        // ---- Tray (Task 6) ----
        .open_window => fx.showWindow(main_window_label),
        .quit_app => fx.quitApp(),

        // ---- Embedding generation (Task 7) ----
        .embed_events_page => |res| embedEventsPage(model, res, fx),
        .embed_snaps_page => |res| embedSnapsPage(model, res, fx),
        .embed_write_done => |res| embedWriteDone(model, res, fx),

        // ---- MCP server child process (Task 8) ----
        .mcp_exit => |exit| {
            // The child exited or failed to spawn. Mark it down; the app
            // keeps running (the MCP server is optional for the core UX,
            // and Task 10's chat will surface/retry it).
            _ = exit;
            model.mcp_ready = false;
            model.mcp_failed = true;
        },
        .mcp_health_tick => |timer| {
            if (timer.outcome == .rejected) return;
            model.mcp_health_attempts += 1;
            healthCheckMcp(fx);
        },
        .mcp_health_done => |res| {
            // A 200 with a JSON-RPC result means the tools are reachable.
            if (res.outcome == .ok and res.status == 200) {
                model.mcp_ready = true;
                model.mcp_failed = false;
            } else if (!model.mcp_ready) {
                // The child may still be binding (connection refused) or the
                // first check raced its listen(). Retry on a fixed backoff
                // until the cap, then give up (non-fatal — retrieval degrades
                // to no-context, and the UI still works). Mirrors the llama
                // health check (Task 9).
                if (model.mcp_health_attempts < mcp_health_max_attempts) {
                    armMcpHealth(mcp_health_retry_ms, fx);
                } else {
                    model.mcp_failed = true;
                }
            }
        },
    }
}

// ----------------------------------------------------- embedding generation

/// Begin an embedding pass: drain un-embedded events, then snapshots. A
/// pass already in flight is left alone (its own loop will pick up anything
/// new on the next trigger).
fn startEmbedPass(model: *Model, fx: *Effects) void {
    if (model.embedding) return;
    model.embedding = true;
    model.embed_phase = .events;
    queryUnembedded(model, fx);
}

/// Query the next batch of un-embedded rows for the current phase.
fn queryUnembedded(model: *Model, fx: *Effects) void {
    model.embed_last_rows = 0;
    var params: [2]db.Value = .{ db.val.text(embeddings.model_id), db.val.int(embed_batch) };
    switch (model.embed_phase) {
        .events => fx.dbQuery(.{
            .key = key_embed_events,
            .sql = embeddings.select_unembedded_events_sql,
            .params = &params,
            .on_result = Effects.dbMsg(.embed_events_page),
        }),
        .snapshots => fx.dbQuery(.{
            .key = key_embed_snaps,
            .sql = embeddings.select_unembedded_snapshots_sql,
            .params = &params,
            .on_result = Effects.dbMsg(.embed_snaps_page),
        }),
    }
}

/// A page of un-embedded events (id, subject, body): embed + write it.
/// Continuation is driven from the write result, NOT this `.done` (so the
/// write commits before the next query runs — no re-embedding).
fn embedEventsPage(model: *Model, res: native_sdk.EffectDbResult, fx: *Effects) void {
    if (res.kind == .page) model.embed_last_rows += embedPageRows(res, .event, fx);
    // A batch that yields ZERO rows (drained) won't produce a write, so its
    // `.done` is where we advance the phase.
    if (res.kind == .done and model.embedding and model.embed_last_rows == 0) {
        model.embed_phase = .snapshots;
        queryUnembedded(model, fx);
    }
}

/// A page of un-embedded snapshots (id, rel_path, content).
fn embedSnapsPage(model: *Model, res: native_sdk.EffectDbResult, fx: *Effects) void {
    if (res.kind == .page) model.embed_last_rows += embedPageRows(res, .file_snapshot, fx);
    if (res.kind == .done and model.embedding and model.embed_last_rows == 0) {
        model.embedding = false; // snapshots drained -> pass complete
    }
}

/// Shared page handler: embed up to `embed_batch` rows and issue ONE
/// dbExec of (embedding insert + fts insert) per row. All backing storage
/// (vectors, text, params) is frame-local — dbExec copies params at call
/// time, and the query page bytes we read from are valid for this update.
/// Returns the number of rows embedded (a write is issued iff > 0).
fn embedPageRows(res: native_sdk.EffectDbResult, kind: embeddings.SourceKind, fx: *Effects) usize {
    var reader = db.PageReader.init(res.bytes) catch return 0;

    // Frame-local batch storage.
    var vectors: [embed_batch]embeddings.Vector = undefined;
    var text_bufs: [embed_batch][embed_text_bytes]u8 = undefined;
    var emb_params: [embed_batch][embeddings.insert_param_count]db.Value = undefined;
    var fts_params: [embed_batch][3]db.Value = undefined;
    var statements: [embed_batch * 2]db.Statement = undefined;

    const now = fx.wallMs();
    var rows: usize = 0;
    var stmt_n: usize = 0;
    var row: [3]db.ColumnValue = undefined;
    while (rows < embed_batch) {
        const cols = (reader.next(&row) catch null) orelse break;
        const source_id = cols[0].asInt() orelse continue;
        const a = cols[1].asText() orelse "";
        const b = cols[2].asText() orelse "";
        const text = switch (kind) {
            .file_snapshot => embeddings.fileSnapshotText(&text_bufs[rows], a, b),
            else => embeddings.eventText(&text_bufs[rows], a, b),
        };
        embeddings.embed(text, &vectors[rows]);
        const vbytes = embeddings.vectorBytes(&vectors[rows]);
        statements[stmt_n] = embeddings.insertStatement(&emb_params[rows], kind, source_id, vbytes, now);
        stmt_n += 1;
        // FTS body is the same text (valid: it lives in text_bufs[rows]).
        statements[stmt_n] = embeddings.ftsInsertStatement(&fts_params[rows], kind, source_id, text);
        stmt_n += 1;
        rows += 1;
    }

    if (rows == 0) return 0;

    fx.dbExec(.{
        .key = key_embed_write,
        .statements = statements[0..stmt_n],
        .on_result = Effects.dbMsg(.embed_write_done),
    });
    return rows;
}

/// A batch write finished. If the batch was full there may be more rows in
/// this phase — query again (the write has committed, so those rows now
/// count as embedded). A short batch means the phase is nearly drained; we
/// still query once more so the terminal empty `.done` can advance/finish.
fn embedWriteDone(model: *Model, res: native_sdk.EffectDbResult, fx: *Effects) void {
    _ = res; // ok or constraint alike: continue (dup embeddings are harmless)
    if (!model.embedding) return;
    queryUnembedded(model, fx);
}

// ----------------------------------------------------- MCP server child

/// Spawn the MCP server child exactly once. It opens `app.db` (read-only)
/// and serves the memory tools over HTTP on `127.0.0.1:mcp_port`. We pass
/// the db path and an explicit port so we know where to reach it, then arm
/// a short one-shot timer before health-checking (giving it time to bind).
fn startMcpServer(model: *Model, fx: *Effects) void {
    if (model.mcp_started) return;
    const paths = boot_paths orelse return;
    model.mcp_started = true;

    var port_buf: [8]u8 = undefined;
    const port_str = std.fmt.bufPrint(&port_buf, "{d}", .{mcp_port}) catch return;

    // `.collect` output: we don't stream the child's stdout; we only care
    // that it stays alive (an exit delivers `mcp_exit`). The child logs to
    // its own stderr, surfaced in the exit Msg's stderr_tail if it dies.
    fx.spawn(.{
        .key = key_mcp_spawn,
        .argv = &.{ resolveMcpBinary(), "--db", paths.db, "--port", port_str },
        .output = .collect,
        .on_exit = Effects.exitMsg(.mcp_exit),
    });

    // Give the child a moment to bind before the first health check.
    model.mcp_health_attempts = 0;
    armMcpHealth(mcp_health_delay_ms, fx);
}

/// Arm the one-shot timer that fires the next MCP health check after `delay_ms`.
fn armMcpHealth(delay_ms: u64, fx: *Effects) void {
    fx.startTimer(.{
        .key = key_mcp_health_timer,
        .interval_ms = delay_ms,
        .mode = .one_shot,
        .on_fire = Effects.timerMsg(.mcp_health_tick),
    });
}

/// Health-check the MCP child: POST a `tools/list` to its loopback port and
/// confirm a 200 response. Reachability sets `mcp_ready`.
fn healthCheckMcp(fx: *Effects) void {
    var url_buf: [64]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/", .{mcp_port}) catch return;
    fx.fetch(.{
        .key = key_mcp_health,
        .method = .POST,
        .url = url,
        .headers = &.{.{ .name = "content-type", .value = "application/json" }},
        .body = mcp_health_body,
        .timeout_ms = 3_000,
        .on_response = Effects.responseMsg(.mcp_health_done),
    });
}

// ------------------------------ local model management + llama runtime

/// Read config.json so we can learn which model the user selected. The
/// selected id lands in the model via `config_read_done`.
fn readConfig(fx: *Effects) void {
    const paths = boot_paths orelse return;
    fx.readFile(.{
        .key = key_cfg_read,
        .path = paths.config,
        .on_result = Effects.fileMsg(.config_read_done),
    });
}

/// Persist the current config (selected model + onboarded flag) by
/// rewriting config.json. Uses `key_config_persist`/`.config_persisted`
/// (NOT the first-run `key_write_config`/`.wrote_config`) so it never
/// re-runs the first-run arm that clears `onboarded`.
fn persistConfig(model: *const Model, fx: *Effects) void {
    const paths = boot_paths orelse return;
    const arena = boot_arena.allocator();
    const json = bootstrap.configJson(arena, model.username, app_version, model.selectedModel(), model.onboarded) catch return;
    fx.writeFile(.{
        .key = key_config_persist,
        .path = paths.config,
        .bytes = json,
        .on_result = Effects.fileMsg(.config_persisted),
    });
}

/// Stat the selected model's GGUF file to learn whether it is on disk.
fn statSelectedModel(model: *const Model, fx: *Effects) void {
    const paths = boot_paths orelse return;
    const m = models.findModel(model.selectedModel()) orelse return;
    var buf: [models.max_path_bytes]u8 = undefined;
    const path = models.modelFilePath(&buf, paths.models, m.file_name) catch return;
    fx.statFile(.{
        .key = key_model_stat,
        .path = path,
        .on_result = Effects.fileMsg(.model_stat_done),
    });
}

/// Begin downloading the selected model with a spawned `curl`, writing to
/// a `.part` file. Progress lines stream in via `download_progress_line`;
/// the terminal exit is `download_done`. A download already in flight (or
/// a model already present) is a no-op.
fn startDownload(model: *Model, fx: *Effects) void {
    if (model.downloading or model.model_present) return;
    const paths = boot_paths orelse return;
    const m = models.findModel(model.selectedModel()) orelse return;

    var part_buf: [models.max_path_bytes]u8 = undefined;
    const part_path = models.partFilePath(&part_buf, paths.models, m.file_name) catch return;

    model.downloading = true;
    model.download_failed = false;
    model.download_progress = 0;

    var argv_buf: [models.download_argv_len][]const u8 = undefined;
    const argv = models.downloadArgv(&argv_buf, m.url, part_path);
    fx.spawn(.{
        .key = key_model_download,
        .argv = argv,
        .output = .lines, // stream curl's progress meter line-by-line
        .on_line = Effects.lineMsg(.download_progress_line),
        .on_exit = Effects.exitMsg(.download_done),
    });
}

/// curl finished. On a clean exit, move the `.part` into place with `mv`
/// (there is no rename file effect); otherwise mark the download failed.
fn downloadDone(model: *Model, exit: native_sdk.EffectExit, fx: *Effects) void {
    model.downloading = false;
    if (exit.reason != .exited or exit.code != 0) {
        model.download_failed = true;
        return;
    }
    model.download_progress = 1.0;

    const paths = boot_paths orelse return;
    const m = models.findModel(model.selectedModel()) orelse return;
    var part_buf: [models.max_path_bytes]u8 = undefined;
    var final_buf: [models.max_path_bytes]u8 = undefined;
    const part_path = models.partFilePath(&part_buf, paths.models, m.file_name) catch return;
    const final_path = models.modelFilePath(&final_buf, paths.models, m.file_name) catch return;

    var argv_buf: [models.rename_argv_len][]const u8 = undefined;
    const argv = models.renameArgv(&argv_buf, part_path, final_path);
    fx.spawn(.{
        .key = key_model_rename,
        .argv = argv,
        .output = .collect,
        .on_exit = Effects.exitMsg(.model_renamed),
    });
}

/// The `.part` -> final move finished. On success the model is present, so
/// bring up the runtime; on failure surface a download error.
fn modelRenamed(model: *Model, exit: native_sdk.EffectExit, fx: *Effects) void {
    if (exit.reason == .exited and exit.code == 0) {
        model.model_present = true;
        model.download_failed = false;
        startLlama(model, fx);
    } else {
        model.download_failed = true;
    }
}

/// Spawn the llama.cpp runtime child exactly once, pointing it at the
/// selected model's GGUF and binding loopback `llama_port`. Mirrors the
/// MCP child pattern: spawn, then a one-shot delay before health-checking
/// (model load takes a moment). Graceful-degrades if the binary is missing
/// (the exit's `.spawn_failed` lands in `llama_exit` and marks it failed).
fn startLlama(model: *Model, fx: *Effects) void {
    if (model.llama_started) return;
    if (!model.model_present) return;
    const paths = boot_paths orelse return;
    const m = models.findModel(model.selectedModel()) orelse return;
    model.llama_started = true;
    model.llama_health_attempts = 0;

    var model_buf: [models.max_path_bytes]u8 = undefined;
    const model_path = models.modelFilePath(&model_buf, paths.models, m.file_name) catch return;
    const binary = models.resolveServerBinary(env.lookup(models.server_binary_env));

    var port_buf: [8]u8 = undefined;
    const port_str = std.fmt.bufPrint(&port_buf, "{d}", .{llama_port}) catch return;
    var ctx_buf: [12]u8 = undefined;
    const ctx_str = std.fmt.bufPrint(&ctx_buf, "{d}", .{m.context_length}) catch return;

    var argv_buf: [models.server_argv_len][]const u8 = undefined;
    const argv = models.serverArgv(&argv_buf, binary, model_path, port_str, ctx_str);
    fx.spawn(.{
        .key = key_llama_spawn,
        .argv = argv,
        .output = .collect, // we don't stream stdout; an exit -> llama_exit
        .on_exit = Effects.exitMsg(.llama_exit),
    });

    // Arm the first health check after a short delay (the child needs a
    // moment to bind + start loading the model).
    armLlamaHealth(llama_health_delay_ms, fx);
}

/// Arm a one-shot timer that will fire the next llama health check.
fn armLlamaHealth(delay_ms: u64, fx: *Effects) void {
    fx.startTimer(.{
        .key = key_llama_health_timer,
        .interval_ms = delay_ms,
        .mode = .one_shot,
        .on_fire = Effects.timerMsg(.llama_health_tick),
    });
}

/// Health-check the llama runtime: GET its `/health` and confirm a 200.
fn healthCheckLlama(fx: *Effects) void {
    var url_buf: [64]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/health", .{llama_port}) catch return;
    fx.fetch(.{
        .key = key_llama_health,
        .method = .GET,
        .url = url,
        .timeout_ms = 3_000,
        .on_response = Effects.responseMsg(.llama_health_done),
    });
}

// ------------------------------------------------------------- chat (Task 10)

/// A user pressed Send. Capture the input, show it immediately, and kick off
/// the turn: first retrieve relevant memory from the MCP server (if it's
/// reachable), then stream a completion from the local runtime with that
/// memory injected as context.
fn sendChat(model: *Model, fx: *Effects) void {
    if (model.sending) return; // one turn at a time
    if (!model.llama_ready) {
        model.setChatError("The model runtime isn't ready yet.");
        return;
    }
    const raw = std.mem.trim(u8, model.chat_input.text(), " \t\r\n");
    if (raw.len == 0) return;

    model.setPendingUser(raw);
    model.pushMessage(.user, raw); // optimistic display
    // On a brand-new chat, adopt the first user message as the title (shown
    // above the transcript and mirrored by the persisted `chats.title`).
    if (model.current_chat_id == 0 and model.chat_title_len == 0) {
        model.setChatTitle(chat.excerptTitle(raw));
    }
    model.chat_input.clear();
    model.clearChatError();
    model.pending_summary_kind = null; // an ordinary chat turn (not a summary)
    model.sending = true;
    model.finalizing = false;
    model.streaming = false;
    model.streaming_len = 0;
    model.context_len = 0;

    // Retrieve memory context first (best-effort). If the MCP server isn't
    // ready, skip straight to the completion with no injected context.
    if (model.mcp_ready) {
        searchMemory(model, fx);
    } else {
        startCompletion(model, fx);
    }
}

/// POST a `search_memory` tools/call to the MCP server for the pending user
/// text. The result lands in `mcp_search_done`.
fn searchMemory(model: *Model, fx: *Effects) void {
    // Build the request body in a frame-local fixed buffer — no allocator
    // dependency, no growth over the session (fetch copies the body at call).
    // Sized for the worst case: every query byte could escape to `\uXXXX`
    // (6x), plus the fixed JSON-RPC envelope. Generous so retrieval is never
    // silently skipped for a heavily-punctuated query.
    var scratch: [chat.max_content_bytes * 6 + 512]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    var body: std.ArrayList(u8) = .empty;
    chat.buildSearchRequest(&body, fba.allocator(), model.pendingUser(), chat_search_hits) catch {
        // Couldn't build the request — proceed without context.
        return startCompletion(model, fx);
    };
    var url_buf: [64]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/", .{mcp_port}) catch return;
    fx.fetch(.{
        .key = key_mcp_search,
        .method = .POST,
        .url = url,
        .headers = &.{.{ .name = "content-type", .value = "application/json" }},
        .body = body.items,
        .timeout_ms = 5_000,
        .on_response = Effects.responseMsg(.mcp_search_done),
    });
}

/// Got the memory-search response (or a failure). Format the hits into the
/// context block (best-effort) and start the completion either way.
fn mcpSearchDone(model: *Model, res: native_sdk.EffectResponse, fx: *Effects) void {
    if (res.outcome == .ok and res.status == 200) {
        // Parse + format the retrieved hits in a short-lived arena (std.json
        // builds a tree proportional to the body, which the SDK caps at
        // 256 KiB). The arena is freed before this update returns, so nothing
        // accumulates across turns.
        var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena_state.deinit();
        var ctx: std.ArrayList(u8) = .empty;
        const hits = chat.formatSearchContext(&ctx, arena_state.allocator(), res.body, chat_search_hits) catch 0;
        if (hits > 0) model.setContext(ctx.items);
    }
    // Whether or not we found memory, ask the model now.
    startCompletion(model, fx);
}

/// A single-click summary card was tapped (Task 11). A summary is a canned
/// turn: the card's fixed prompt becomes the "user" message, Blocks pulls the
/// developer's recent activity from the MCP `get_activity` tool as context,
/// and the model writes the summary. It always starts a FRESH chat, tagged
/// with the summary's `chats.kind`. Reuses the entire Task 10 turn machinery
/// (`startCompletion` → stream → `finalizeChat` → persist).
fn startSummary(model: *Model, kind: chat.SummaryKind, fx: *Effects) void {
    if (model.sending) return; // one turn at a time
    if (!model.llama_ready) {
        model.setChatError("The model runtime isn't ready yet.");
        return;
    }

    // A summary is a NEW conversation, so reset the active chat. The canned
    // prompt is the turn's user message (shown + persisted).
    const prompt = kind.prompt();
    model.current_chat_id = 0;
    model.next_seq = 0;
    model.message_count = 0;
    model.setChatTitle(kind.title());
    model.setPendingUser(prompt);
    model.pushMessage(.user, prompt); // optimistic display
    model.clearChatError();
    model.pending_summary_kind = kind;
    model.sending = true;
    model.finalizing = false;
    model.streaming = false;
    model.streaming_len = 0;
    model.context_len = 0;

    // Retrieve recent activity (best-effort). If the MCP server isn't ready,
    // proceed straight to the completion with no injected context.
    if (model.mcp_ready) {
        retrieveActivity(model, kind, fx);
    } else {
        startCompletion(model, fx);
    }
}

/// POST a `get_activity` tools/call to the MCP server for the summary's time
/// window. The result lands in `mcp_activity_done`.
fn retrieveActivity(model: *Model, kind: chat.SummaryKind, fx: *Effects) void {
    const since_ms = fx.wallMs() - kind.lookbackMs();
    // The request is small + fixed-shape (two integers); a stack buffer is
    // ample. fetch copies the body at call time.
    var scratch: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    var body: std.ArrayList(u8) = .empty;
    chat.buildActivityRequest(&body, fba.allocator(), since_ms, kind.activityLimit()) catch {
        return startCompletion(model, fx);
    };
    var url_buf: [64]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/", .{mcp_port}) catch return;
    fx.fetch(.{
        .key = key_mcp_activity,
        .method = .POST,
        .url = url,
        .headers = &.{.{ .name = "content-type", .value = "application/json" }},
        .body = body.items,
        .timeout_ms = 5_000,
        .on_response = Effects.responseMsg(.mcp_activity_done),
    });
}

/// Got the recent-activity response (or a failure). Format it into the
/// context block (best-effort) and start the completion either way.
fn mcpActivityDone(model: *Model, res: native_sdk.EffectResponse, fx: *Effects) void {
    if (res.outcome == .ok and res.status == 200) {
        const rows: usize = if (model.pending_summary_kind) |k| k.activityLimit() else 30;
        var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena_state.deinit();
        var ctx: std.ArrayList(u8) = .empty;
        const n = chat.formatActivityContext(&ctx, arena_state.allocator(), res.body, rows) catch 0;
        if (n > 0) model.setContext(ctx.items);
    }
    startCompletion(model, fx);
}

/// Build the OpenAI chat request from the loaded history (which already
/// includes the just-added user message) + the retrieved context, and open
/// a streamed completion against the runtime. Tokens arrive via `chat_line`;
/// the terminal `chat_done` finalizes and persists the turn.
fn startCompletion(model: *Model, fx: *Effects) void {
    // Assemble the history as OutMessages (borrowing the model's inline
    // storage, valid for this call — buildRequest copies into `body`).
    var hist_buf: [chat.max_messages]chat.OutMessage = undefined;
    var n: usize = 0;
    for (model.messagesSlice()) |*m| {
        if (n >= hist_buf.len) break;
        hist_buf[n] = .{ .role = m.role, .content = m.content() };
        n += 1;
    }

    // Build the request body in a short-lived arena (freed before this
    // update returns — nothing accumulates across turns). fetch copies the
    // body at call time.
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    var body: std.ArrayList(u8) = .empty;
    chat.buildRequest(&body, arena_state.allocator(), hist_buf[0..n], model.contextText(), true, chat_max_tokens) catch {
        model.sending = false;
        model.setChatError("Could not build the chat request.");
        return;
    };

    model.streaming = true;
    model.streaming_len = 0;

    var url_buf: [80]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/v1/chat/completions", .{llama_port}) catch return;
    fx.fetch(.{
        .key = key_llama_chat,
        .method = .POST,
        .url = url,
        .headers = &.{.{ .name = "content-type", .value = "application/json" }},
        .body = body.items,
        .timeout_ms = chat_stream_timeout_ms,
        .response = .stream, // frame the SSE body into `chat_line` Msgs
        .on_line = Effects.lineMsg(.chat_line),
        .on_response = Effects.responseMsg(.chat_done),
    });
}

/// Finalize the in-flight completion: turn the accumulated `streaming_buf`
/// into an assistant message and persist the turn. IDEMPOTENT via the
/// `finalizing` guard — it is called once on the `[DONE]` stream sentinel and
/// again on the terminal `chat_done`; the second call returns immediately.
/// `sending` stays SET across the async persist chain (cleared only in
/// `chat_write_done` or the failure path here) so `canSend` keeps a second
/// turn from overlapping the new-chat id recovery. `ok` is false for a
/// transport failure.
fn finalizeChat(model: *Model, ok: bool, fx: *Effects) void {
    if (model.finalizing) return; // already finalized this turn
    if (!model.sending) return; // no turn in flight
    model.finalizing = true;
    model.streaming = false;
    const reply = model.streamingText();

    // We got the `[DONE]` sentinel or a clean close — cancel the (possibly
    // still-open, keep-alive) stream fetch so it doesn't linger to its
    // timeout before the terminal response arrives.
    fx.cancel(key_llama_chat);

    if (!ok or reply.len == 0) {
        // Nothing usable came back. Drop the in-flight turn state; keep the
        // user's message visible so they can retry. No persist runs, so clear
        // `sending` here to re-enable input.
        model.sending = false;
        model.streaming_len = 0;
        model.context_len = 0;
        model.pending_summary_kind = null;
        if (!ok) model.setChatError("The model did not respond. Is the runtime still up?");
        return;
    }

    // Show the finished reply as a real message and clear the streaming line.
    model.pushMessage(.assistant, reply);
    model.streaming_len = 0;

    // Persist the turn. If this is a brand-new chat, create the row first
    // (its id + the messages are written once the id comes back); otherwise
    // write the two messages directly.
    if (model.current_chat_id == 0) {
        createChatThenPersist(model, fx);
    } else {
        persistTurn(model, fx);
    }
}

/// INSERT a new `chats` row; the id is read back in `chat_rowid_done`, which
/// then persists the turn's messages. For a single-click summary (Task 11)
/// the row is tagged with the summary's `chats.kind` and its fixed title;
/// for an ordinary chat it defaults to kind='chat' titled from the first
/// user message. Both param buffers live on this frame (dbExec copies at call).
fn createChatThenPersist(model: *Model, fx: *Effects) void {
    const now = fx.wallMs();
    if (model.pending_summary_kind) |kind| {
        // A summary: fixed title, explicit kind. The preview is filled in
        // from the reply by `persistTurn`'s chat-touch.
        const title = kind.title();
        var params: [4]db.Value = undefined;
        fx.dbExec(.{
            .key = key_chat_insert,
            .statements = &.{chat.chatInsertKindStatement(&params, title, title, kind.chatKind(), now)},
            .on_result = Effects.dbMsg(.chat_inserted),
        });
        return;
    }
    const title = chat.excerptTitle(model.pendingUser());
    var params: [3]db.Value = undefined;
    fx.dbExec(.{
        .key = key_chat_insert,
        .statements = &.{chat.chatInsertStatement(&params, title, title, now)},
        .on_result = Effects.dbMsg(.chat_inserted),
    });
}

/// The new chat's id came back — adopt it and persist the turn's messages.
fn chatRowidDone(model: *Model, res: native_sdk.EffectDbResult, fx: *Effects) void {
    switch (res.kind) {
        .page => {
            var reader = db.PageReader.init(res.bytes) catch return;
            var row: [1]db.ColumnValue = undefined;
            if ((reader.next(&row) catch null)) |cols| {
                if (cols.len > 0) {
                    if (cols[0].asInt()) |id| {
                        model.current_chat_id = id;
                        model.next_seq = 0;
                    }
                }
            }
        },
        .done => persistTurn(model, fx),
        .exec => {},
    }
}

/// Write the turn's two messages (user then assistant) with monotonic seqs
/// and bump the chat's preview/updated_at, all in one exec batch.
fn persistTurn(model: *Model, fx: *Effects) void {
    if (model.current_chat_id == 0) {
        // We finished a reply but couldn't obtain a chat id to save it under.
        // Surface it and re-enable input; the messages stay on screen.
        model.sending = false;
        model.pending_summary_kind = null;
        model.setChatError("Couldn't save this chat — your reply is shown but not stored.");
        return;
    }
    const now = fx.wallMs();
    // `next_seq` is authoritative in-model: it starts at 0 for a new chat and
    // is recomputed from the DB on every reload (`messagesListed`), so the two
    // seqs for this turn are next_seq and next_seq+1. The reload after the
    // write refreshes it, so we do NOT advance it here (that would double it).
    const user_seq = model.next_seq;
    const asst_seq = model.next_seq + 1;

    // The assistant reply is the last message `finalizeChat` pushed.
    const reply = if (model.message_count > 0)
        model.messages[model.message_count - 1].content()
    else
        "";

    var user_params: [5]db.Value = undefined;
    var asst_params: [5]db.Value = undefined;
    var touch_params: [3]db.Value = undefined;
    const preview = chat.excerptTitle(reply);
    fx.dbExec(.{
        .key = key_chat_write,
        .statements = &.{
            chat.messageInsertStatement(&user_params, model.current_chat_id, .user, model.pendingUser(), user_seq, now),
            chat.messageInsertStatement(&asst_params, model.current_chat_id, .assistant, reply, asst_seq, now),
            chat.chatTouchStatement(&touch_params, preview, now, model.current_chat_id),
        },
        .on_result = Effects.dbMsg(.chat_write_done),
    });
    // `sending` stays SET until `chat_write_done` — the turn isn't done until
    // the write commits, which keeps a second turn from overlapping.
}

/// Load the chat-history sidebar list (newest-first). Fired on boot (once the
/// DB is ready) and after every turn is persisted so a new/updated chat rises
/// to the top with its refreshed preview.
fn loadChats(fx: *Effects) void {
    fx.dbQuery(.{
        .key = key_chats_list,
        .sql = chat.chats_list_sql,
        .on_result = Effects.dbMsg(.chats_listed),
    });
}

/// Copy a `chats_listed` page into the model's owned history list, computing
/// each row's date bucket against "now" and marking the first row of each
/// bucket so the sidebar can print a single group header per bucket.
fn chatsListed(model: *Model, res: native_sdk.EffectDbResult, now_ms: i64) void {
    switch (res.kind) {
        .page => {
            var reader = db.PageReader.init(res.bytes) catch return;
            model.chat_count = 0;
            var last_key: ?[]const u8 = null;
            var row: [6]db.ColumnValue = undefined;
            while (reader.next(&row) catch null) |cols| {
                if (model.chat_count >= chat.max_chats) break;
                const c = chat.Chat.fromRow(cols) orelse continue;
                var entry = chat.ChatEntry.fromChat(c, now_ms);
                // The list is ordered newest-first, so a header-key change marks
                // the head row — the only row that prints the group header. The
                // "earlier" bucket keys on the `dd-MM-yyyy` creation date, so
                // each distinct earlier day gets its own date header.
                const key = entry.headerKey();
                entry.group_head = (last_key == null or !std.mem.eql(u8, last_key.?, key));
                entry.active = (entry.id == model.current_chat_id and entry.id != 0);
                // `key` borrows `entry.date_buf`; store the entry FIRST, then
                // point `last_key` at the stored copy so it stays valid.
                model.chat_list[model.chat_count] = entry;
                last_key = model.chat_list[model.chat_count].headerKey();
                model.chat_count += 1;
            }
        },
        .done, .exec => {},
    }
}

/// Recompute each history row's `active` flag against `current_chat_id`, so
/// the sidebar highlight tracks a selection change without a full DB reload.
fn refreshActiveChat(model: *Model) void {
    for (model.chat_list[0..model.chat_count]) |*e| {
        e.active = (e.id == model.current_chat_id and e.id != 0);
    }
}

/// Open a saved chat from the history sidebar: adopt its id + title and load
/// its messages. A no-op mid-turn (don't swap the transcript out from under a
/// streaming reply).
fn selectChat(model: *Model, id: i64, fx: *Effects) void {
    if (model.sending or id == 0) return;
    model.current_chat_id = id;
    model.clearChatError();
    model.streaming = false;
    model.streaming_len = 0;
    // Adopt the title from the loaded list entry (if present).
    for (model.chatList()) |e| {
        if (e.id == id) {
            model.setChatTitle(e.title());
            break;
        }
    }
    refreshActiveChat(model);
    loadMessages(id, fx);
}

/// Start a brand-new chat (the "+ New chat" button): clear the active id,
/// transcript, title, and composer so the summary cards + empty hint show.
/// A no-op mid-turn.
fn newChat(model: *Model) void {
    if (model.sending) return;
    model.current_chat_id = 0;
    model.next_seq = 0;
    model.message_count = 0;
    model.streaming = false;
    model.streaming_len = 0;
    model.chat_title_len = 0;
    model.chat_input.clear();
    model.clearChatError();
    refreshActiveChat(model);
}

/// Load a chat's messages into the model (oldest first). ?1 = chat id.
fn loadMessages(chat_id: i64, fx: *Effects) void {
    var params: [1]db.Value = .{db.val.int(chat_id)};
    fx.dbQuery(.{
        .key = key_messages_list,
        .sql = chat.messages_by_chat_sql,
        .params = &params,
        .on_result = Effects.dbMsg(.messages_listed),
    });
}

/// Copy a `messages_listed` page into the model's owned list.
fn messagesListed(model: *Model, res: native_sdk.EffectDbResult) void {
    switch (res.kind) {
        .page => {
            var reader = db.PageReader.init(res.bytes) catch return;
            model.message_count = 0;
            var row: [8]db.ColumnValue = undefined;
            while (reader.next(&row) catch null) |cols| {
                if (model.message_count >= chat.max_messages) break;
                const m = chat.Message.fromRow(cols) orelse continue;
                model.messages[model.message_count] = chat.MessageEntry.fromMessage(m);
                model.messages[model.message_count].index = @intCast(model.message_count);
                model.message_count += 1;
                if (m.seq + 1 > model.next_seq) model.next_seq = m.seq + 1;
            }
        },
        .done, .exec => {},
    }
}

// ------------------------------------------------- materials / snippets (Task 12)

/// Load the snippets list into the model, honoring the current sort + language
/// filter. Fired on boot (after the DB is ready) and after every change.
fn loadSnippets(model: *Model, fx: *Effects) void {
    const has_filter = model.lang_filter_len > 0;
    const search = std.mem.trim(u8, model.snippet_search.text(), " \t\r\n");
    const has_search = search.len > 0;

    // LIKE pattern lives on this frame (dbQuery copies params at call time).
    var like_buf: [snip_search_capacity + 4]u8 = undefined;
    const pattern = snippets.likePattern(&like_buf, search);

    if (has_search) {
        const sql = switch (model.snippet_sort) {
            .recent => if (has_filter) snippets.search_recent_by_lang_sql else snippets.search_recent_sql,
            .alphabetical => if (has_filter) snippets.search_alpha_by_lang_sql else snippets.search_alpha_sql,
        };
        if (has_filter) {
            var params: [2]db.Value = .{ db.val.text(pattern), db.val.text(model.langFilter()) };
            fx.dbQuery(.{ .key = key_snip_list, .sql = sql, .params = &params, .on_result = Effects.dbMsg(.snippets_listed) });
        } else {
            var params: [1]db.Value = .{db.val.text(pattern)};
            fx.dbQuery(.{ .key = key_snip_list, .sql = sql, .params = &params, .on_result = Effects.dbMsg(.snippets_listed) });
        }
        return;
    }

    const sql = switch (model.snippet_sort) {
        .recent => if (has_filter) snippets.list_recent_by_lang_sql else snippets.list_recent_sql,
        .alphabetical => if (has_filter) snippets.list_alpha_by_lang_sql else snippets.list_alpha_sql,
    };
    if (has_filter) {
        var params: [1]db.Value = undefined;
        fx.dbQuery(.{
            .key = key_snip_list,
            .sql = sql,
            .params = snippets.langFilterParams(&params, model.langFilter()),
            .on_result = Effects.dbMsg(.snippets_listed),
        });
    } else {
        fx.dbQuery(.{
            .key = key_snip_list,
            .sql = sql,
            .on_result = Effects.dbMsg(.snippets_listed),
        });
    }
}

/// Load the distinct languages (for the filter menu + set-language typeahead).
fn loadLanguages(model: *Model, fx: *Effects) void {
    _ = model;
    fx.dbQuery(.{
        .key = key_snip_langs,
        .sql = snippets.distinct_langs_sql,
        .on_result = Effects.dbMsg(.languages_listed),
    });
}

/// Copy a `snippets_listed` page into the model's owned list, preserving the
/// current selection when the selected id is still present (else selecting the
/// first row so the detail panel always shows something after a reload).
fn snippetsListed(model: *Model, res: native_sdk.EffectDbResult) void {
    switch (res.kind) {
        .page => {
            var reader = db.PageReader.init(res.bytes) catch return;
            model.snippet_count = 0;
            var row: [9]db.ColumnValue = undefined;
            while (reader.next(&row) catch null) |cols| {
                if (model.snippet_count >= snippets.max_snippets) break;
                const s = snippets.Snippet.fromRow(cols) orelse continue;
                model.snippet_list[model.snippet_count] = snippets.SnippetEntry.fromSnippet(s);
                model.snippet_count += 1;
            }
        },
        .done => {
            // Keep the selection valid: if the selected id vanished (deleted or
            // filtered out), select the first visible snippet (or none). We
            // don't fetch the detail here — the caller (`select_snippet` or a
            // write's follow-up) drives detail loads; this only keeps the id sane.
            if (model.selectedCard() == null) {
                model.selected_snippet_id = if (model.snippet_count > 0) model.snippet_list[0].id else 0;
            }
            refreshSelectedSnippet(model);
        },
        .exec => {},
    }
}

/// Recompute each sidebar card's `selected` flag against `selected_snippet_id`
/// so the highlight tracks the selection without a full DB reload (mirrors
/// `refreshActiveChat` for the chat sidebar).
fn refreshSelectedSnippet(model: *Model) void {
    for (model.snippet_list[0..model.snippet_count]) |*e| {
        e.selected = (e.id == model.selected_snippet_id and e.id != 0);
    }
}

/// Load the full body of one snippet into `selected_detail` (the detail panel).
fn loadSnippetDetail(model: *Model, id: i64, fx: *Effects) void {
    if (id == 0) {
        model.selected_detail = .{};
        return;
    }
    var params: [1]db.Value = undefined;
    fx.dbQuery(.{
        .key = key_snip_detail,
        .sql = snippets.get_sql,
        .params = snippets.getParams(&params, id),
        .on_result = Effects.dbMsg(.snippet_detail_loaded),
    });
}

/// Copy the selected snippet's full row into `selected_detail`.
fn snippetDetailLoaded(model: *Model, res: native_sdk.EffectDbResult, now_ms: i64) void {
    switch (res.kind) {
        .page => {
            var reader = db.PageReader.init(res.bytes) catch return;
            var row: [9]db.ColumnValue = undefined;
            if ((reader.next(&row) catch null)) |cols| {
                if (snippets.Snippet.fromRow(cols)) |s| {
                    model.selected_detail = snippets.SnippetDetail.fromSnippet(s);
                    // Precompute the "Saved …" subtitle now (render-time
                    // accessors have no clock of their own).
                    const ago = snippets.formatSavedAgo(&model.saved_ago_buf, s.updated_at, now_ms);
                    model.saved_ago_len = ago.len;
                }
            }
        },
        .done, .exec => {},
    }
}

/// Copy a `languages_listed` page into the model's owned language list.
fn languagesListed(model: *Model, res: native_sdk.EffectDbResult) void {
    switch (res.kind) {
        .page => {
            var reader = db.PageReader.init(res.bytes) catch return;
            model.language_count = 0;
            var row: [1]db.ColumnValue = undefined;
            while (reader.next(&row) catch null) |cols| {
                if (model.language_count >= snippets.max_languages) break;
                const name = cols[0].asText() orelse continue;
                var entry = snippets.LanguageEntry.set(name);
                entry.index = model.language_count;
                entry.filterIndex = model.language_count + 1;
                model.languages[model.language_count] = entry;
                model.language_count += 1;
            }
        },
        .done, .exec => {},
    }
}

/// Open the editor sheet, blank for a new snippet (`id == 0`) or pre-filled
/// from the snippet being edited.
fn openEditor(model: *Model, id: i64) void {
    // Fresh canvas label per open (the Settings reopen-blank fix), so the
    // secondary editor window renders on every reopen.
    if (!model.editor_open) {
        model.editor_open_count +%= 1;
        model.refreshEditorCanvasLabel();
    }
    model.editor_open = true;
    model.editing_id = id;
    model.snippet_status_len = 0;
    if (id == 0) {
        model.edit_title.clear();
        model.edit_content.clear();
        model.edit_language.clear();
        model.edit_annotation.clear();
        model.edit_text_expander.clear();
    } else if (model.detail()) |s| {
        model.edit_title.set(s.title());
        model.edit_content.set(s.content());
        model.edit_language.set(s.language());
        model.edit_annotation.set(s.annotation());
        model.edit_text_expander.set(s.textExpander());
    }
}

/// Commit the editor: INSERT a new snippet or UPDATE the one being edited.
/// A title is required (fall back to a first-line default when blank).
fn saveSnippet(model: *Model, fx: *Effects) void {
    if (model.snippet_writing) return;
    const content = model.edit_content.text();
    const raw_title = std.mem.trim(u8, model.edit_title.text(), " \t\r\n");
    const title = if (raw_title.len > 0) raw_title else snippets.defaultTitle(content);
    const language = std.mem.trim(u8, model.edit_language.text(), " \t\r\n");
    const now = fx.wallMs();

    model.snippet_writing = true;
    model.editor_open = false;
    if (model.editing_id == 0) {
        var params: [8]db.Value = undefined;
        fx.dbExec(.{
            .key = key_snip_insert,
            .statements = &.{snippets.insertStatement(
                &params,
                title,
                content,
                language,
                model.edit_annotation.text(),
                model.edit_text_expander.text(),
                0, // no origin — created directly
                0,
                now,
            )},
            .on_result = Effects.dbMsg(.snippet_inserted),
        });
    } else {
        var params: [7]db.Value = undefined;
        fx.dbExec(.{
            .key = key_snip_update,
            .statements = &.{snippets.updateStatement(
                &params,
                model.editing_id,
                title,
                content,
                language,
                model.edit_annotation.text(),
                model.edit_text_expander.text(),
                now,
            )},
            .on_result = Effects.dbMsg(.snippet_write_done),
        });
        // Keep this snippet selected after the reload.
        model.selected_snippet_id = model.editing_id;
    }
    model.editing_id = 0;
}

/// A brand-new snippet's id came back — select it, then reload the list +
/// languages so the sidebar + detail reflect it.
fn snippetRowidDone(model: *Model, res: native_sdk.EffectDbResult, fx: *Effects) void {
    switch (res.kind) {
        .page => {
            var reader = db.PageReader.init(res.bytes) catch return;
            var row: [1]db.ColumnValue = undefined;
            if ((reader.next(&row) catch null)) |cols| {
                if (cols.len > 0) {
                    if (cols[0].asInt()) |id| model.selected_snippet_id = id;
                }
            }
        },
        .done => {
            model.snippet_writing = false;
            loadSnippets(model, fx);
            loadLanguages(model, fx);
            // Load the just-created snippet's full body into the detail panel.
            if (model.selected_snippet_id != 0) loadSnippetDetail(model, model.selected_snippet_id, fx);
        },
        .exec => {},
    }
}

/// Open the delete-confirmation dialog window for the selected material,
/// building its prompt sentence (with the material's title). No-op when
/// nothing is selected. A fresh canvas label per open (the reopen-blank fix).
fn openDeleteConfirm(model: *Model) void {
    if (model.selected_snippet_id == 0) return;
    model.confirm_delete_kind = .material;
    const title = model.selectedTitle();
    const prompt = std.fmt.bufPrint(
        &model.confirm_delete_prompt_buf,
        "Are you sure you want to delete the material '{s}'?",
        .{title},
    ) catch "Are you sure you want to delete this material?";
    model.confirm_delete_prompt_len = prompt.len;
    if (!model.confirm_delete_open) {
        model.confirm_delete_open_count +%= 1;
        model.refreshConfirmDeleteCanvasLabel();
    }
    model.confirm_delete_open = true;
}

/// Open the SAME delete-confirmation dialog for a chat row (its trash button),
/// remembering the target id and building a prompt with the chat's title. A
/// chat can be deleted from any row without opening it first.
fn openDeleteChatConfirm(model: *Model, id: i64) void {
    if (id == 0) return;
    model.confirm_delete_kind = .chat;
    model.confirm_delete_chat_id = id;
    // Find the row's title for the prompt (fall back to a generic sentence).
    var title: []const u8 = "";
    for (model.chat_list[0..model.chat_count]) |*e| {
        if (e.id == id) {
            title = e.title();
            break;
        }
    }
    const prompt = if (title.len > 0)
        std.fmt.bufPrint(
            &model.confirm_delete_prompt_buf,
            "Are you sure you want to delete the chat '{s}'? This can't be undone.",
            .{title},
        ) catch "Are you sure you want to delete this chat? This can't be undone."
    else
        std.fmt.bufPrint(
            &model.confirm_delete_prompt_buf,
            "Are you sure you want to delete this chat? This can't be undone.",
            .{},
        ) catch "Are you sure you want to delete this chat? This can't be undone.";
    model.confirm_delete_prompt_len = prompt.len;
    if (!model.confirm_delete_open) {
        model.confirm_delete_open_count +%= 1;
        model.refreshConfirmDeleteCanvasLabel();
    }
    model.confirm_delete_open = true;
}

/// Delete the selected snippet, then reload.
fn deleteSnippet(model: *Model, fx: *Effects) void {
    if (model.snippet_writing) return;
    if (model.selected_snippet_id == 0) return;
    model.snippet_writing = true;
    // Drop the selection so the reload picks a new one.
    const id = model.selected_snippet_id;
    model.selected_snippet_id = 0;
    var params: [1]db.Value = undefined;
    fx.dbExec(.{
        .key = key_snip_delete,
        .statements = &.{snippets.deleteStatement(&params, id)},
        .on_result = Effects.dbMsg(.snippet_write_done),
    });
}

/// Delete the chat targeted by the confirmation dialog. Its messages cascade
/// (FK ON DELETE CASCADE); materials saved from it survive (origin SET NULL).
/// If it's the chat currently open, reset the transcript to a fresh chat.
fn deleteChat(model: *Model, fx: *Effects) void {
    const id = model.confirm_delete_chat_id;
    model.confirm_delete_chat_id = 0;
    if (id == 0) return;
    // If we're deleting the open conversation, clear it (mirror `newChat`,
    // but that self-gates on `sending`, so reset the fields directly here).
    if (model.current_chat_id == id) {
        model.current_chat_id = 0;
        model.next_seq = 0;
        model.message_count = 0;
        model.chat_title_len = 0;
        model.clearChatError();
    }
    var params: [1]db.Value = undefined;
    fx.dbExec(.{
        .key = key_chat_delete,
        .statements = &.{chat.chatDeleteStatement(&params, id)},
        .on_result = Effects.dbMsg(.chat_deleted),
    });
}

/// A chat DELETE finished — reload the history sidebar so the row disappears.
fn chatDeleted(model: *Model, res: native_sdk.EffectDbResult, fx: *Effects) void {
    _ = model;
    if (res.kind != .done and res.kind != .exec) return;
    loadChats(fx);
}

/// Copy the selected snippet's content to the system clipboard.
fn copySnippet(model: *Model, fx: *Effects) void {
    const s = model.detail() orelse return;
    fx.writeClipboard(.{
        .key = key_snip_clip,
        .text = s.content(),
        .on_result = Effects.clipboardMsg(.snippet_clip_done),
    });
}

/// "Save to Snippets" from a chat message: create a snippet from a message's
/// content, tagged with the current chat + message as its origin. `seq_idx`
/// is the index into the loaded `messages` (the seq shown in the transcript).
fn saveToSnippets(model: *Model, seq_idx: i64, fx: *Effects) void {
    if (model.snippet_writing) return;
    const idx: usize = if (seq_idx < 0) return else @intCast(seq_idx);
    if (idx >= model.message_count) return;
    const msg = &model.messages[idx];
    const content = msg.content();
    if (content.len == 0) return;

    model.snippet_writing = true;
    var params: [8]db.Value = undefined;
    fx.dbExec(.{
        .key = key_snip_insert,
        .statements = &.{snippets.insertStatement(
            &params,
            snippets.defaultTitle(content),
            content,
            "", // language unset — the user tags it later via the modal
            "", // annotation
            "", // text_expander
            model.current_chat_id, // origin chat (0 -> NULL if none)
            msg.id, // origin message (0 -> NULL if not yet persisted)
            fx.wallMs(),
        )},
        .on_result = Effects.dbMsg(.snippet_inserted),
    });
    model.setSnippetStatus("Saved to Materials.");
}

/// "Start Copilot Chat" from the selected snippet: begin a fresh chat whose
/// first user message references the snippet, then stream a reply. Reuses the
/// Task 10 chat turn machinery (send as if the user typed it).
fn startCopilotChat(model: *Model, fx: *Effects) void {
    const s = model.detail() orelse return;
    if (!model.llama_ready) {
        model.setSnippetStatus("The model runtime isn't ready yet.");
        return;
    }
    if (model.sending) return;

    // Seed the chat input with a prompt about this snippet, then send it
    // through the normal chat path (which persists + streams). The materials
    // screen stays put; the chat view shows the conversation.
    var buf: [snippets.max_content_bytes + 256]u8 = undefined;
    const seeded = std.fmt.bufPrint(
        &buf,
        "Here is a code snippet titled \"{s}\". Explain what it does and suggest improvements:\n\n{s}",
        .{ s.title(), s.content() },
    ) catch s.content();
    model.chat_input.set(seeded);
    model.setSnippetStatus("Started a chat about this material.");
    sendChat(model, fx);
}

/// Tray menu state, derived from the model each rebuild. The runtime calls
/// this and applies the returned status item; menu selections come back
/// through `onTrayCommand`.
fn statusItem(model: *const Model, scratch: *BlocksApp.StatusItemScratch) BlocksApp.StatusItemState {
    _ = model;
    const items = tray.buildMenu(&scratch.items);
    return .{
        .title = "Blocks",
        .tooltip = "Blocks for Developers",
        .items = items,
    };
}

/// Map a tray/menu command name to a Msg (or null to ignore it).
fn onTrayCommand(name: []const u8) ?Msg {
    if (std.mem.eql(u8, name, tray.cmd_open)) return .open_window;
    if (std.mem.eql(u8, name, tray.cmd_quit)) return .quit_app;
    return null;
}

// ---------------------------------------------- Settings window (Task 13)

/// Declare the model-declared secondary windows that should exist RIGHT
/// NOW. Presence in the returned slice IS liveness: the runtime creates the
/// Settings window when `settings_open` flips true (the `open_settings` Msg)
/// and closes it when the slice no longer contains it (`close_settings`).
/// The user's red-button close dispatches `on_close = .close_settings`, so
/// the model clears the flag and the reconcile does not resurrect it.
fn blocksWindows(model: *const Model, scratch: *BlocksApp.WindowsScratch) []const BlocksApp.WindowDescriptor {
    var count: usize = 0;
    if (model.settings_open) {
        scratch.windows[count] = .{
            .label = settings_window_label,
            // A FRESH canvas label per open (`settings-canvas-<n>`): removing
            // the window from this slice to close it destroys its slot, and a
            // re-declare under the SAME canvas label never re-installs the
            // canvas in a live GPU session (the recreated window's install
            // frame doesn't arrive) — so each open gets a NEW canvas label,
            // which the runtime treats as a clean install. The `window_view`
            // is keyed by the WINDOW label, so it builds regardless.
            .canvas_label = model.settingsCanvasLabel(),
            .title = "Settings",
            .width = 900,
            .height = 640,
            .min_width = 720,
            .min_height = 480,
            .titlebar = .hidden_inset,
            .close_policy = .quit,
            .on_close = .close_settings,
        };
        count += 1;
    }
    // The material add/edit editor: a second secondary window, same pattern.
    // A fresh `material-canvas-<n>` per open (the reopen-blank fix); the
    // native red-button close dispatches `close_editor`.
    if (model.editor_open) {
        scratch.windows[count] = .{
            .label = editor_window_label,
            .canvas_label = model.editorCanvasLabel(),
            .title = if (model.editing_id == 0) "New material" else "Edit material",
            .width = 720,
            .height = 640,
            .min_width = 520,
            .min_height = 420,
            .titlebar = .hidden_inset,
            .close_policy = .quit,
            .on_close = .close_editor,
        };
        count += 1;
    }
    // The delete-confirmation dialog: a small third window. The native
    // red-button close cancels (same as the Cancel button).
    if (model.confirm_delete_open) {
        scratch.windows[count] = .{
            .label = confirm_delete_window_label,
            .canvas_label = model.confirmDeleteCanvasLabel(),
            .title = model.confirmDeleteTitle(),
            .width = 460,
            .height = 200,
            .min_width = 360,
            .min_height = 160,
            .titlebar = .hidden_inset,
            .close_policy = .quit,
            .on_close = .cancel_delete,
        };
        count += 1;
    }
    return scratch.windows[0..count];
}

/// A small pill badge (there is no `badge` sugar on `Ui`; badge is a
/// text-bearing widget kind).
fn badge(ui: *BlocksApp.Ui, text: []const u8) BlocksApp.Ui.Node {
    var node = ui.el(.badge, .{}, .{});
    node.widget.text = text;
    return node;
}

/// One left-nav row: a ghost button that reads as selected when its section
/// is active.
fn settingsNavRow(ui: *BlocksApp.Ui, label: []const u8, active: bool, msg: Msg) BlocksApp.Ui.Node {
    return ui.button(.{
        .variant = if (active) .secondary else .ghost,
        .selected = active,
        .on_press = msg,
        .grow = 1,
    }, label);
}

/// One model card in the Settings › Local Model picker (mirrors the
/// onboarding card: name at heading, badges, blurb, spec caption, bordered
/// when selected, tapping selects).
fn settingsModelCard(ui: *BlocksApp.Ui, choice: *const ModelChoice) BlocksApp.Ui.Node {
    var header_children: [3]BlocksApp.Ui.Node = undefined;
    var hc: usize = 0;
    header_children[hc] = ui.text(.{ .size = .heading, .grow = 1 }, choice.name);
    hc += 1;
    if (choice.recommended) {
        header_children[hc] = badge(ui, "Recommended");
        hc += 1;
    }
    header_children[hc] = badge(ui, choice.tierLabel);
    hc += 1;

    return ui.el(.card, .{
        .selected = choice.selected,
        .on_press = .{ .select_model = choice.index },
    }, .{
        ui.column(.{ .gap = 2, .padding = 8 }, .{
            ui.row(.{ .cross = .center, .gap = 8 }, header_children[0..hc]),
            ui.text(.{ .wrap = true }, choice.blurb),
            ui.text(.{}, choice.specLine()),
        }),
    });
}

/// Build the material add/edit editor window's canvas tree. Formerly the
/// inline `<if editorOpen>` markup sheet; now a Zig-built SECONDARY window
/// (like Settings), driven by the SAME Model/Msg/update loop. Each field
/// seeds its current buffer text (`.text = ...`) so an EDIT shows the loaded
/// snippet's values; edits flow back through `edit_*_edit` (via
/// `Ui.inputMsg`) into the same `edit_*` TextBuffers the old markup used.
fn editorWindowView(ui: *BlocksApp.Ui, model: *const Model) BlocksApp.Ui.Node {
    const heading = if (model.editing_id == 0) "New material" else "Edit material";
    return ui.column(.{ .gap = 10, .padding = 20, .grow = 1 }, .{
        ui.text(.{ .size = .heading }, heading),
        ui.textField(.{
            .placeholder = "Title",
            .text = model.edit_title.text(),
            .on_input = BlocksApp.Ui.inputMsg(.edit_title_edit),
            .autofocus = true,
        }),
        ui.textField(.{
            .placeholder = "Language (e.g. python, zig)",
            .text = model.edit_language.text(),
            .on_input = BlocksApp.Ui.inputMsg(.edit_language_edit),
        }),
        // The code body: an editable, highlighted code surface (same widget
        // the read-only detail panel uses), growing to fill the window.
        ui.code(.{
            .editable = true,
            .on_input = BlocksApp.Ui.inputMsg(.edit_content_edit),
            .line_numbers = true,
            .grow = 1,
        }, model.edit_content.text()),
        ui.textField(.{
            .placeholder = "Annotation",
            .text = model.edit_annotation.text(),
            .on_input = BlocksApp.Ui.inputMsg(.edit_annotation_edit),
        }),
        ui.textField(.{
            .placeholder = "Text expander",
            .text = model.edit_text_expander.text(),
            .on_input = BlocksApp.Ui.inputMsg(.edit_text_expander_edit),
        }),
        ui.row(.{ .gap = 8, .cross = .center }, .{
            ui.button(.{ .variant = .primary, .size = .sm, .on_press = .save_snippet }, "Save"),
            ui.button(.{ .variant = .ghost, .size = .sm, .on_press = .cancel_editor }, "Cancel"),
        }),
    });
}

/// Build the delete-confirmation dialog window's tree: a title + prompt (built
/// for the material or chat being deleted) + a red "Yes, delete it!" (confirm)
/// and a Cancel button. Confirm deletes; Cancel (and the native close) dismiss.
fn confirmDeleteWindowView(ui: *BlocksApp.Ui, model: *const Model) BlocksApp.Ui.Node {
    return ui.column(.{ .gap = 16, .padding = 20, .grow = 1 }, .{
        ui.text(.{ .size = .heading }, model.confirmDeleteTitle()),
        ui.text(.{ .wrap = true, .grow = 1 }, model.confirmDeletePrompt()),
        ui.row(.{ .gap = 8, .cross = .center }, .{
            ui.button(.{ .variant = .destructive, .on_press = .confirm_delete }, "Yes, delete it!"),
            ui.button(.{ .variant = .ghost, .on_press = .cancel_delete }, "Cancel"),
        }),
    });
}

/// Build the Settings window's canvas tree (Task 13). A left nav (All /
/// About / MCP / Local Model, the active row highlighted) + a right scroll
/// pane; "All" shows every section, a specific choice narrows to one. Driven
/// by the SAME Model/Msg/update loop as the main window.
fn blocksWindowView(ui: *BlocksApp.Ui, model: *const Model, window_label: []const u8) BlocksApp.Ui.Node {
    // Three secondary windows share this builder; dispatch on the WINDOW label.
    if (std.mem.eql(u8, window_label, editor_window_label))
        return editorWindowView(ui, model);
    if (std.mem.eql(u8, window_label, confirm_delete_window_label))
        return confirmDeleteWindowView(ui, model);
    std.debug.assert(std.mem.eql(u8, window_label, settings_window_label));

    // --- Left nav ---
    const nav = ui.column(.{ .gap = 4, .padding = 8, .width = 240 }, .{
        settingsNavRow(ui, "All", model.settings_section == .all, .settings_all),
        settingsNavRow(ui, "About", model.settings_section == .about, .settings_about),
        settingsNavRow(ui, "Watched Repositories", model.settings_section == .repos, .settings_repos),
        settingsNavRow(ui, "Model Context Protocol (MCP)", model.settings_section == .mcp, .settings_mcp),
        settingsNavRow(ui, "Local Model", model.settings_section == .local_model, .settings_local_model),
    });

    // --- Right pane sections (each gated so "All" shows everything) ---
    var panes: [5]BlocksApp.Ui.Node = undefined;
    var pn: usize = 0;

    if (model.settingsAbout()) {
        panes[pn] = ui.column(.{ .gap = 6, .padding = 12 }, .{
            ui.text(.{}, "Version"),
            ui.text(.{ .size = .heading }, model.appVersionText()),
            ui.spacer(12),
            ui.text(.{}, "Data folder (all Blocks data lives here — back this up):"),
            ui.row(.{ .cross = .center, .gap = 8 }, .{
                ui.statusBar(.{ .grow = 1 }, model.dataDirText()),
                ui.button(.{ .variant = .ghost, .size = .sm, .on_press = .copy_data_dir }, "Copy"),
            }),
        });
        pn += 1;
    }

    if (model.settingsRepos()) {
        panes[pn] = ui.column(.{ .gap = 6, .padding = 12 }, .{
            ui.text(.{ .size = .heading }, "Watched Repositories"),
            ui.text(.{ .wrap = true }, "Blocks indexes the git history and file changes of the repositories you watch."),
            ui.row(.{ .cross = .center, .gap = 8 }, .{
                ui.textField(.{ .placeholder = "/path/to/your/repo", .on_input = BlocksApp.Ui.inputMsg(.repo_input_edit), .on_submit = .add_repo_clicked, .grow = 1 }),
                ui.button(.{ .variant = .primary, .on_press = .add_repo_clicked, .disabled = model.isAddingRepo() }, "Add"),
            }),
            ui.column(.{ .gap = 4 }, ui.each(model.reposSlice(), repoKey, repoRow)),
        });
        pn += 1;
    }

    if (model.settingsMcp()) {
        panes[pn] = ui.column(.{ .gap = 6, .padding = 12 }, .{
            ui.text(.{ .size = .heading }, "Model Context Protocol (MCP)"),
            ui.text(.{}, "Server URLs"),
            ui.row(.{ .cross = .center, .gap = 8 }, .{
                ui.text(.{ .grow = 1 }, model.mcpUrlText()),
                ui.button(.{ .variant = .ghost, .size = .sm, .on_press = .copy_mcp_url }, "Copy"),
            }),
            ui.text(.{}, "Local runtime (OpenAI-compatible):"),
            ui.row(.{ .cross = .center, .gap = 8 }, .{
                ui.text(.{ .grow = 1 }, model.llamaUrlText()),
                ui.button(.{ .variant = .ghost, .size = .sm, .on_press = .copy_llama_url }, "Copy"),
            }),
        });
        pn += 1;
    }

    if (model.settingsLocalModel()) {
        panes[pn] = ui.column(.{ .gap = 8, .padding = 12 }, .{
            ui.text(.{ .size = .heading }, "Local Model"),
            ui.text(.{ .wrap = true }, "Blocks chats with a model that runs entirely on your machine."),
            ui.column(.{ .gap = 8 }, ui.each(model.modelChoices(), modelChoiceKey, settingsModelCardEach)),
            ui.row(.{ .cross = .center, .gap = 8 }, .{
                ui.statusBar(.{ .grow = 1 }, model.modelStatusText()),
                if (model.canDownload())
                    ui.button(.{ .variant = .primary, .size = .sm, .on_press = .download_model }, "Download")
                else
                    ui.spacer(0),
            }),
        });
        pn += 1;
    }

    const body = ui.row(.{ .gap = 20, .grow = 1 }, .{
        nav,
        ui.scroll(.{ .grow = 1 }, .{
            ui.column(.{ .gap = 16, .grow = 1 }, panes[0..pn]),
        }),
    });

    return ui.column(.{ .gap = 12, .padding = 20, .grow = 1 }, .{
        ui.text(.{ .size = .heading }, "Settings"),
        body,
    });
}

// Key + row builders for the `ui.each` loops above. `each` passes the *Ui
// (self) and each item as a `*const T` pointer to the view fn.
fn repoKey(entry: *const repos.RepoEntry) canvas.UiKey {
    return .{ .int = @intCast(entry.id) };
}
fn repoRow(ui: *BlocksApp.Ui, entry: *const repos.RepoEntry) BlocksApp.Ui.Node {
    return ui.row(.{ .gap = 8, .padding = 8, .cross = .center }, .{
        ui.column(.{ .grow = 1, .gap = 2 }, .{
            ui.text(.{}, entry.name()),
            ui.statusBar(.{}, entry.path()),
        }),
        ui.button(.{ .variant = .ghost, .size = .sm, .on_press = .{ .remove_repo = entry.id } }, "Remove"),
    });
}
fn modelChoiceKey(choice: *const ModelChoice) canvas.UiKey {
    return .{ .index = choice.index };
}
fn settingsModelCardEach(ui: *BlocksApp.Ui, choice: *const ModelChoice) BlocksApp.Ui.Node {
    return settingsModelCard(ui, choice);
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
    // No more repos to index — git history is up to date, so (re)embed any
    // new commit events.
    model.capturing = false;
    startEmbedPass(model, fx);
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
    // The working tree is snapshotted; embed any new snapshots (and any new
    // commit events too — the pass drains both tables).
    startEmbedPass(model, fx);
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

/// Custom vector icons registered at boot (see `main`). The welcome-splash
/// sparkle (mockup 4) has no built-in equivalent, so we parse our own SVG
/// (in the framework's stroke/fill icon dialect) and expose it to markup as
/// `app:sparkle`. Parsed at comptime — a malformed SVG is a compile error.
const sparkle_icon = canvas.svg_icon.parseComptime(@embedFile("assets/icons/sparkle.svg"));
/// The Materials screen's `{}` glyph (the built-in icon set has no braces
/// icon). Same custom-SVG path as `app:sparkle`; drawn via `app:braces`.
const braces_icon = canvas.svg_icon.parseComptime(@embedFile("assets/icons/braces.svg"));
/// Reflected by the model contract (`native check`) to validate `app:`
/// icon references in markup, and handed to `registerAppIcons` in `main`.
/// MUST be `pub const app_icons` on the app root for the contract to see it.
pub const app_icons = [_]canvas.icons.Entry{
    .{ .name = "sparkle", .icon = &sparkle_icon },
    .{ .name = "braces", .icon = &braces_icon },
};

const BlocksApp = native_sdk.UiApp(Model, Msg);

pub fn initialModel() Model {
    var m = Model{ .username = boot_username };
    m.refreshAvatarInitials();
    m.refreshModelChoices();
    return m;
}

pub fn main(init: std.process.Init) !void {
    boot_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    // Detect the username once, up front, from the real environment.
    const home = config.detectHome(env.lookup);
    boot_username = config.detectUsername(env.lookup, home);

    // Register our custom vector icons (the welcome-splash sparkle isn't in
    // the built-in set) so markup can draw them via `app:<name>`. Registered
    // before the runtime starts, per the icons API contract.
    canvas.icons.registerAppIcons(&app_icons);

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
        // Settings lives in a SEPARATE OS window (Task 13): declared by
        // `windows_fn` when `settings_open`, built by `window_view`. Markup
        // only binds the main canvas, so the settings tree is Zig-built.
        .windows_fn = blocksWindows,
        .window_view = blocksWindowView,
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
