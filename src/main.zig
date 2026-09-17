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

/// The loopback port the MCP child binds (passed explicitly so the app
/// knows where to reach it without first reading the endpoint file).
const mcp_port: u16 = 39_017;
/// argv[0] for the MCP child. Under `native dev` the app's cwd is the repo
/// root, so this repo-relative path resolves. A packaged build ships the
/// binary beside the app; locating it there needs the bundle path (no
/// self-path effect exists yet) and is a documented Task 8 follow-up.
const mcp_binary_path = "mcp/zig-out/bin/blocks-mcp";
/// The MCP tools/list request body used as a health check once the child
/// has had a moment to bind its port.
const mcp_health_body =
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}";
/// One-shot delay before the health check, giving the child time to bind.
const mcp_health_delay_ms: u64 = 400;

/// The loopback port the llama.cpp runtime binds. Task 10's chat POSTs to
/// its OpenAI-compatible endpoint here; for now we only health-check it.
const llama_port: u16 = 39_018;
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
/// Whole-exchange timeout for the streamed completion (a long reply on a
/// small local model can still take a while); the stream lifetime counts.
const chat_stream_timeout_ms: u32 = 120_000;

/// How many source rows to embed per query batch. Each row contributes a
/// 256-f32 vector + an FTS insert; two statements/row, all frame-local.
const embed_batch = 16;
/// Text length embedded per row (subject+body / path+content, truncated).
const embed_text_bytes = 4096;

// Launch-at-login host-service names (see SDK effects: native host requests).
const host_login_status = "native-sdk.launch-at-login.status";
const host_login_set = "native-sdk.launch-at-login.set";

/// The window label the tray "Open Blocks" action reveals. Matches the
/// `shell_windows` entry below.
const main_window_label = "main";
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

/// One row in the model picker's `<for each>`. Built fresh each rebuild
/// from the static catalog + the current selection (no owned storage — the
/// name/blurb slices borrow the comptime catalog strings, which live for
/// the whole program).
pub const ModelChoice = struct {
    index: usize,
    name: []const u8,
    blurb: []const u8,
    selected: bool,
};

pub const Model = struct {
    /// True when the config file already existed at boot (returning user).
    /// Read by `persistSelectedModel` to preserve the flag when rewriting
    /// config.json on a model change.
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
    /// Refill `model_choices` from the static catalog + current selection.
    fn refreshModelChoices(self: *Model) void {
        const sel = self.selectedModel();
        for (models.catalog, 0..) |m, i| {
            self.model_choices[i] = .{
                .index = i,
                .name = m.display_name,
                .blurb = m.blurb,
                .selected = std.mem.eql(u8, m.id, sel),
            };
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
    /// A one-line status for the chat area.
    pub fn chatStatusText(self: *const Model) []const u8 {
        if (self.chat_error_len > 0) return self.chat_error_buf[0..self.chat_error_len];
        if (self.streaming) return "Blocks is thinking…";
        if (self.sending) return "Searching your memory…";
        if (!self.llama_ready) return self.modelStatusText();
        return "Ask about your recent work.";
    }
    /// True when there is nothing to show yet (empty-state hint).
    pub fn chatEmpty(self: *const Model) bool {
        return self.message_count == 0 and !self.streaming;
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
        self.message_count += 1;
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
        // Tray + launch-at-login (Task 6).
        "login_enabled",      "login_supported",
        // Embedding generation (Task 7).
        "embedding",          "embed_phase",       "embed_last_rows",
        // MCP server child process (Task 8).
        "mcp_started",        "mcp_ready",         "mcp_failed",
        // Local model management + llama.cpp runtime (Task 9).
        "selected_model_buf", "selected_model_len", "model_present",  "downloading",
        "download_progress",  "download_failed",    "llama_started",  "llama_ready",
        "llama_failed",       "selectedModel",       "model_choices",
        "selectedModelName",  "downloadPercent",     "llama_health_attempts",
        // Chat experience (Task 10). chat_input is bound (text-field), and
        // messagesSlice/streamingText/isStreaming/canSend/chatStatusText/
        // chatEmpty are bound in markup — the rest are update/effect state.
        "current_chat_id",    "next_seq",           "messages",       "message_count",
        "pending_user_buf",   "pending_user_len",   "streaming_buf",  "streaming_len",
        "context_buf",        "context_len",        "sending",        "streaming",
        "finalizing",         "chat_error_buf",     "chat_error_len", "pushMessage",
        "canSend",
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

    // Tray + launch-at-login (Task 6)
    open_window, // tray "Open Blocks" — reveal the main window
    quit_app, // tray "Quit Blocks"
    toggle_login, // tray "Start at Login" toggle
    login_status_done: native_sdk.EffectHostResult, // launch-at-login status query
    login_set_done: native_sdk.EffectHostResult, // launch-at-login set result

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

    // Delivered by effects/host, never bound as markup handlers.
    pub const view_unbound = .{
        "stat_config",         "wrote_config",       "wrote_keep",
        "git_check_done",      "repo_inserted",      "repos_listed",
        "repo_removed",        "capture_since_done", "capture_log_done",
        "capture_write_done",  "snapshot_tick",      "snap_status_done",
        "snap_lasthash_done",  "snap_content_done",  "snap_diff_done",
        "snap_write_done",     "open_window",        "quit_app",
        "toggle_login",        "login_status_done",  "login_set_done",
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
        "messages_listed",
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
                // Returning user: config already present. Read it to learn
                // the selected model (then stat the model file).
                model.onboarded = true;
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
            persistSelectedModel(model, fx);
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
            if (model.current_chat_id != 0) loadMessages(model.current_chat_id, fx);
        },
        .messages_listed => |res| messagesListed(model, res),

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
            healthCheckMcp(fx);
        },
        .mcp_health_done => |res| {
            // A 200 with a JSON-RPC result means the tools are reachable.
            if (res.outcome == .ok and res.status == 200) {
                model.mcp_ready = true;
                model.mcp_failed = false;
            }
            // A failure is not fatal: the child may still be binding. We
            // leave mcp_ready false; Task 10 will add retry/backoff.
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
        .argv = &.{ mcp_binary_path, "--db", paths.db, "--port", port_str },
        .output = .collect,
        .on_exit = Effects.exitMsg(.mcp_exit),
    });

    // Give the child a moment to bind before the first health check.
    fx.startTimer(.{
        .key = key_mcp_health_timer,
        .interval_ms = mcp_health_delay_ms,
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

/// Persist the current selection by rewriting config.json. We keep the
/// existing username + version + onboarded state and swap the model id.
fn persistSelectedModel(model: *const Model, fx: *Effects) void {
    const paths = boot_paths orelse return;
    const arena = boot_arena.allocator();
    const json = bootstrap.configJson(arena, model.username, app_version, model.selectedModel(), model.onboarded) catch return;
    fx.writeFile(.{
        .key = key_write_config,
        .path = paths.config,
        .bytes = json,
        .on_result = Effects.fileMsg(.wrote_config),
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
    model.chat_input.clear();
    model.clearChatError();
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

/// INSERT a new `chats` row titled from the user's first message; the id is
/// read back in `chat_rowid_done`, which then persists the turn's messages.
fn createChatThenPersist(model: *Model, fx: *Effects) void {
    const title = chat.excerptTitle(model.pendingUser());
    var params: [3]db.Value = undefined;
    fx.dbExec(.{
        .key = key_chat_insert,
        .statements = &.{chat.chatInsertStatement(&params, title, title, fx.wallMs())},
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
                model.message_count += 1;
                if (m.seq + 1 > model.next_seq) model.next_seq = m.seq + 1;
            }
        },
        .done, .exec => {},
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

const BlocksApp = native_sdk.UiApp(Model, Msg);

pub fn initialModel() Model {
    var m = Model{ .username = boot_username };
    m.refreshModelChoices();
    return m;
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
