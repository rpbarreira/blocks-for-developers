//! Chat data layer + local-LLM protocol shaping — PURE (Task 10).
//!
//! Blocks' chat talks to the LOCAL llama.cpp runtime over its
//! OpenAI-compatible HTTP API and grounds answers in the developer's own
//! git/file memory via the MCP `search_memory` tool. This module owns
//! everything about that exchange that can be expressed without touching
//! the OS or the network:
//!
//!   * the `chats` / `messages` data layer (statement builders + row
//!     decoders + a model-owned `MessageEntry` inline copy), mirroring the
//!     conventions in repos.zig / git.zig (caller-owned `*[N]db.Value`
//!     param buffers, `select_columns`/`*_sql` consts, `fromRow`),
//!   * a builder for the `/v1/chat/completions` request body (system prompt
//!     + the message history + an optional retrieved-memory context block),
//!   * a parser for the streamed Server-Sent-Events `data:` lines (extract
//!     each `delta.content` token; detect the terminal `[DONE]`) and for a
//!     buffered (non-streamed) completion,
//!   * the MCP `tools/call` request body for `search_memory`, the unwrapper
//!     for its double-wrapped result (`result.content[0].text` -> the tool's
//!     own JSON), and a formatter that turns the ranked hits into a compact
//!     plain-text context block to inject.
//!
//! **Retrieval strategy (v1 decision — see docs/PROGRESS.md):** rather than
//! rely on the small local model's (unreliable) native tool-calling, the app
//! does retrieval-augmented generation — it calls `search_memory` with the
//! user's message itself and injects the top hits as context BEFORE asking
//! the model. Deterministic, works with a 1.5-3B model, and still exercises
//! the MCP tools built in Task 8. Native OpenAI tool-calling is a follow-up.
//!
//! Everything here is pure and unit-tested; the effect firing lives in
//! main.zig.

const std = @import("std");
const db = @import("db.zig");

// ------------------------------------------------------- message roles

/// A chat message role. Stored as TEXT in the `messages.role` column
/// ('user' | 'assistant' | 'system') and mapped to the OpenAI role names
/// (which are identical) in the request body.
pub const Role = enum {
    user,
    assistant,
    system,

    pub fn name(self: Role) []const u8 {
        return switch (self) {
            .user => "user",
            .assistant => "assistant",
            .system => "system",
        };
    }
    pub fn fromName(s: []const u8) ?Role {
        if (std.mem.eql(u8, s, "user")) return .user;
        if (std.mem.eql(u8, s, "assistant")) return .assistant;
        if (std.mem.eql(u8, s, "system")) return .system;
        return null;
    }
};

// ---------------------------------------------------- summaries (Task 11)

/// The three single-click summaries. Each is a canned "turn": Blocks pulls
/// the developer's RECENT ACTIVITY from the MCP `get_activity` tool (a time
/// window for the recap/standup, a broader window for top-of-mind), injects
/// it as context, and asks the local model to write the summary with a fixed
/// instruction. Each maps to a distinct `chats.kind` so the sidebar (Task 13)
/// can badge them, and carries its own title + prompt.
pub const SummaryKind = enum {
    day_recap,
    top_of_mind,
    standup,

    /// The value stored in `chats.kind` (must match the schema CHECK: one of
    /// 'chat' | 'day_recap' | 'top_of_mind' | 'standup').
    pub fn chatKind(self: SummaryKind) []const u8 {
        return switch (self) {
            .day_recap => "day_recap",
            .top_of_mind => "top_of_mind",
            .standup => "standup",
        };
    }

    /// A human title for the generated chat (shown in the transcript header /
    /// sidebar).
    pub fn title(self: SummaryKind) []const u8 {
        return switch (self) {
            .day_recap => "Day Recap",
            .top_of_mind => "What's Top of Mind",
            .standup => "Standup Update",
        };
    }

    /// The canned instruction sent as the turn's user message. Phrased to lean
    /// on the injected "Recent activity" block and to keep the small local
    /// model on task.
    pub fn prompt(self: SummaryKind) []const u8 {
        return switch (self) {
            .day_recap =>
            "Write a Day Recap of my recent coding work. Using the recent activity below, " ++
                "summarize what I worked on — group related commits and file changes by repository " ++
                "and theme, and note anything that looks unfinished. Use short bullet points. " ++
                "If there is no recent activity, say so plainly.",
            .top_of_mind =>
            "Tell me what's top of mind in my recent coding work. From the recent activity below, " ++
                "identify the few threads I've been most active on and what I likely need to pick back up. " ++
                "Use short bullet points, most important first. If there is no recent activity, say so plainly.",
            .standup =>
            "Write a standup update from my recent coding work. Using the recent activity below, produce " ++
                "three short sections — \"Yesterday\" (what I did), \"Today\" (the natural next steps), and " ++
                "\"Blockers\" (anything that looks stuck, or \"None\"). Keep it to a few bullets each. " ++
                "If there is no recent activity, say so plainly.",
        };
    }

    /// How far back to pull activity, relative to now (ms). Recap/standup look
    /// at the last work day-ish window; top-of-mind spans a bit wider so it can
    /// surface threads that stalled a couple of days ago. A sentinel of 0 means
    /// "no lower bound" (unused today; every kind has a window).
    pub fn lookbackMs(self: SummaryKind) i64 {
        const day: i64 = 24 * 60 * 60 * 1000;
        return switch (self) {
            .day_recap => 1 * day,
            .standup => 1 * day,
            .top_of_mind => 3 * day,
        };
    }

    /// How many activity rows to retrieve for the context block.
    pub fn activityLimit(self: SummaryKind) u32 {
        return switch (self) {
            .day_recap, .top_of_mind => 30,
            .standup => 30,
        };
    }
};

// ------------------------------------------------------- chats table

pub const chat_select_columns = "id, title, preview, kind, created_at, updated_at";

/// Insert a new chat. Title/preview are set from the first user message;
/// kind defaults to 'chat'. ?1=title ?2=preview ?3=now(created) ?4=now(updated)
pub const chat_insert_sql =
    "INSERT INTO chats(title, preview, kind, created_at, updated_at) " ++
    "VALUES(?1, ?2, 'chat', ?3, ?3);";

/// Insert a new chat with an EXPLICIT kind. Used by the single-click
/// summaries (Task 11), which create a chat whose `kind` is one of
/// 'day_recap' | 'top_of_mind' | 'standup' rather than 'chat'.
/// ?1=title ?2=preview ?3=kind ?4=now(created+updated)
pub const chat_insert_kind_sql =
    "INSERT INTO chats(title, preview, kind, created_at, updated_at) " ++
    "VALUES(?1, ?2, ?3, ?4, ?4);";

/// Bump a chat's preview + updated_at after a new message. ?1=preview ?2=now ?3=id
pub const chat_touch_sql =
    "UPDATE chats SET preview = ?1, updated_at = ?2 WHERE id = ?3;";

pub fn chatInsertStatement(buf: *[3]db.Value, title: []const u8, preview: []const u8, now_ms: i64) db.Statement {
    buf.* = .{ db.val.text(title), db.val.text(preview), db.val.int(now_ms) };
    return .{ .sql = chat_insert_sql, .params = buf };
}

/// Build a kind-tagged chat INSERT (Task 11 summaries). `kind` must be one
/// of the schema-allowed chat kinds (see `SummaryKind.chatKind`).
pub fn chatInsertKindStatement(
    buf: *[4]db.Value,
    title: []const u8,
    preview: []const u8,
    kind: []const u8,
    now_ms: i64,
) db.Statement {
    buf.* = .{ db.val.text(title), db.val.text(preview), db.val.text(kind), db.val.int(now_ms) };
    return .{ .sql = chat_insert_kind_sql, .params = buf };
}

pub fn chatTouchStatement(buf: *[3]db.Value, preview: []const u8, now_ms: i64, chat_id: i64) db.Statement {
    buf.* = .{ db.val.text(preview), db.val.int(now_ms), db.val.int(chat_id) };
    return .{ .sql = chat_touch_sql, .params = buf };
}

// ------------------------------------------------------- messages table

pub const msg_select_columns = "id, chat_id, role, content, seq, created_at";

/// Messages for one chat in order. ?1 = chat_id.
pub const messages_by_chat_sql =
    "SELECT " ++ msg_select_columns ++ " FROM messages WHERE chat_id = ?1 ORDER BY seq ASC;";

/// Insert one message. ?1=chat_id ?2=role ?3=content ?4=seq ?5=now.
pub const message_insert_sql =
    "INSERT INTO messages(chat_id, role, content, seq, created_at) " ++
    "VALUES(?1, ?2, ?3, ?4, ?5);";

/// The id of the most recently created chat. We read the new chat's id back
/// with this (MAX(id)) rather than `last_insert_rowid()`: the SDK relational
/// store may run a follow-up query on a DIFFERENT pooled connection, where
/// `last_insert_rowid()` is 0. Blocks is the SOLE writer and rows are never
/// deleted mid-turn, so the greatest id is the chat we just inserted.
pub const max_chat_id_sql = "SELECT MAX(id) FROM chats;";

/// All chats, most-recently-updated first — the history sidebar list.
/// Columns match `chat_select_columns`.
pub const chats_list_sql =
    "SELECT " ++ chat_select_columns ++ " FROM chats ORDER BY updated_at DESC;";

/// Delete one chat by id. `messages.chat_id` is `ON DELETE CASCADE`, so the
/// chat's messages go with it; `snippets.origin_chat_id` is `ON DELETE SET
/// NULL`, so any materials saved from the chat survive (their back-link is
/// cleared). ?1 = chat id.
pub const chat_delete_sql = "DELETE FROM chats WHERE id = ?1;";

/// Fill a caller-owned 1-element buffer with the delete param and return the
/// statement (caller-owned buffer must outlive the `dbExec` — lifetime trap).
pub fn chatDeleteStatement(buf: *[1]db.Value, id: i64) db.Statement {
    buf.* = .{db.val.int(id)};
    return .{ .sql = chat_delete_sql, .params = buf };
}

/// A decoded `chats` row. Slices borrow the page bytes — copy what the model
/// keeps (see `ChatEntry`).
pub const Chat = struct {
    id: i64,
    title: []const u8,
    preview: []const u8,
    kind: []const u8,
    created_at: i64,
    updated_at: i64,

    pub fn fromRow(cols: []const db.ColumnValue) ?Chat {
        if (cols.len < 6) return null;
        return .{
            .id = cols[0].asInt() orelse return null,
            .title = cols[1].asText() orelse "",
            .preview = cols[2].asText() orelse "",
            .kind = cols[3].asText() orelse "chat",
            .created_at = cols[4].asInt() orelse 0,
            .updated_at = cols[5].asInt() orelse 0,
        };
    }
};

/// Bounds for the model-owned chat-history list (fixed inline storage).
pub const max_chats = 256; // history rows kept loaded for the sidebar
pub const chat_title_bytes = title_max_bytes; // title cap (matches excerptTitle)
pub const chat_preview_bytes = 120; // one-line preview under the title

/// Coarse date bucket for grouping the history list (Today / Yesterday /
/// Earlier). The sidebar prints a header when the bucket changes between
/// consecutive rows (the list is ordered newest-first).
pub const DateGroup = enum {
    today,
    yesterday,
    earlier,

    pub fn label(self: DateGroup) []const u8 {
        return switch (self) {
            .today => "TODAY",
            .yesterday => "YESTERDAY",
            .earlier => "EARLIER",
        };
    }
};

/// Classify a timestamp (Unix-ms) into a `DateGroup` relative to `now_ms`,
/// using local-day boundaries derived from a UTC-day approximation. We only
/// need coarse buckets, so day granularity from the epoch is sufficient and
/// dependency-free.
pub fn dateGroup(ts_ms: i64, now_ms: i64) DateGroup {
    const day_ms: i64 = 24 * 60 * 60 * 1000;
    const today_day = @divFloor(now_ms, day_ms);
    const ts_day = @divFloor(ts_ms, day_ms);
    const delta = today_day - ts_day;
    if (delta <= 0) return .today;
    if (delta == 1) return .yesterday;
    return .earlier;
}

/// A civil Y-M-D triple decoded from a day count.
const CivilDate = struct { year: i64, month: u32, day: u32 };

/// Inverse of Howard Hinnant's `daysFromCivil`: convert days-since-epoch
/// (1970-01-01) back to a civil Y-M-D. Public-domain algorithm.
fn civilFromDays(z_in: i64) CivilDate {
    const z = z_in + 719468;
    const era = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const doe = z - era * 146097; // [0, 146096]
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365); // [0, 399]
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100)); // [0, 365]
    const mp = @divFloor(5 * doy + 2, 153); // [0, 11]
    const d: u32 = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1); // [1, 31]
    const m: u32 = @intCast(if (mp < 10) mp + 3 else mp - 9); // [1, 12]
    return .{ .year = if (m <= 2) y + 1 else y, .month = m, .day = d };
}

/// The number of bytes a `dd-MM-yyyy` date string occupies.
pub const dmy_len = 10;

/// Format a Unix-ms timestamp as `dd-MM-yyyy` (UTC civil day) into `buf`,
/// returning the written slice. `buf` must hold at least `dmy_len` bytes.
pub fn formatDmy(buf: []u8, ts_ms: i64) []const u8 {
    const day_ms: i64 = 24 * 60 * 60 * 1000;
    const days = @divFloor(ts_ms, day_ms);
    const c = civilFromDays(days);
    // Cast the year to unsigned so `{d}` doesn't emit a leading '+' sign
    // (which would also overflow the exact-width `dmy_len` buffer). Years are
    // always positive for any real chat timestamp.
    const year: u32 = if (c.year < 0) 0 else @intCast(c.year);
    return std.fmt.bufPrint(buf, "{d:0>2}-{d:0>2}-{d:0>4}", .{ c.day, c.month, year }) catch buf[0..0];
}

/// A model-owned copy of a chat-history row with inline storage, so the
/// loaded sidebar list survives across updates without an allocator.
pub const ChatEntry = struct {
    id: i64 = 0,
    kind_is_summary: bool = false,
    /// True when this row is the currently-open chat — drives the sidebar
    /// highlight (`card selected`). Recomputed whenever the active chat or
    /// the list changes.
    active: bool = false,
    /// The coarse date bucket (computed at load time against "now").
    group: DateGroup = .today,
    /// True when this is the first row of its date bucket — the view prints
    /// the group header only for these (the list is newest-first).
    group_head: bool = false,
    updated_at: i64 = 0,
    /// The chat's creation time (Unix-ms), used for the date-group header.
    created_at: i64 = 0,
    /// The `dd-MM-yyyy` creation date, shown as the header for the "earlier"
    /// bucket (in place of the "EARLIER" label). Filled in `fromChat`.
    date_buf: [dmy_len]u8 = undefined,
    date_len: usize = 0,
    title_buf: [chat_title_bytes]u8 = undefined,
    title_len: usize = 0,
    preview_buf: [chat_preview_bytes]u8 = undefined,
    preview_len: usize = 0,

    pub fn title(self: *const ChatEntry) []const u8 {
        return self.title_buf[0..self.title_len];
    }
    pub fn preview(self: *const ChatEntry) []const u8 {
        return self.preview_buf[0..self.preview_len];
    }
    /// The date-group header label to show above this row (empty unless this
    /// row is the head of its bucket). TODAY / YESTERDAY keep their words; the
    /// "earlier" bucket shows the chat's creation date as `dd-MM-yyyy`.
    pub fn groupLabel(self: *const ChatEntry) []const u8 {
        if (!self.group_head) return "";
        if (self.group == .earlier) return self.date_buf[0..self.date_len];
        return self.group.label();
    }
    /// Whether this row is the head of its date bucket (prints a header).
    pub fn groupHead(self: *const ChatEntry) bool {
        return self.group_head;
    }
    /// The header key this row would print regardless of `group_head`: the
    /// bucket label for today/yesterday, or the `dd-MM-yyyy` date for the
    /// "earlier" bucket. Used to decide where a new header starts (so two
    /// "earlier" chats from different days each get their own date header).
    pub fn headerKey(self: *const ChatEntry) []const u8 {
        if (self.group == .earlier) return self.date_buf[0..self.date_len];
        return self.group.label();
    }
    /// Whether this row has a non-empty preview line.
    pub fn hasPreview(self: *const ChatEntry) bool {
        return self.preview_len > 0;
    }

    pub fn fromChat(c: Chat, now_ms: i64) ChatEntry {
        var e = ChatEntry{
            .id = c.id,
            .updated_at = c.updated_at,
            .created_at = c.created_at,
            // The date header reflects the chat's LAST-ACTIVITY time, matching
            // the list's `updated_at DESC` ordering.
            .group = dateGroup(c.updated_at, now_ms),
        };
        const dmy = formatDmy(&e.date_buf, c.updated_at);
        e.date_len = dmy.len;
        e.kind_is_summary = !std.mem.eql(u8, c.kind, "chat");
        const t = if (c.title.len > 0) c.title else "Untitled chat";
        e.title_len = @min(t.len, chat_title_bytes);
        @memcpy(e.title_buf[0..e.title_len], t[0..e.title_len]);
        e.preview_len = @min(c.preview.len, chat_preview_bytes);
        @memcpy(e.preview_buf[0..e.preview_len], c.preview[0..e.preview_len]);
        return e;
    }
};

pub fn messageInsertStatement(
    buf: *[5]db.Value,
    chat_id: i64,
    role: Role,
    content: []const u8,
    seq: i64,
    now_ms: i64,
) db.Statement {
    buf.* = .{
        db.val.int(chat_id),
        db.val.text(role.name()),
        db.val.text(content),
        db.val.int(seq),
        db.val.int(now_ms),
    };
    return .{ .sql = message_insert_sql, .params = buf };
}

/// A decoded `messages` row. Slices borrow the page bytes — copy what the
/// model keeps (see `MessageEntry`).
pub const Message = struct {
    id: i64,
    chat_id: i64,
    role: Role,
    content: []const u8,
    seq: i64,

    pub fn fromRow(cols: []const db.ColumnValue) ?Message {
        if (cols.len < 5) return null;
        return .{
            .id = cols[0].asInt() orelse return null,
            .chat_id = cols[1].asInt() orelse return null,
            .role = Role.fromName(cols[2].asText() orelse return null) orelse return null,
            .content = cols[3].asText() orelse return null,
            .seq = cols[4].asInt() orelse return null,
        };
    }
};

/// Bounds for the model-owned message list (fixed inline storage, no alloc).
pub const max_content_bytes = 8 * 1024; // per-message content cap for display/storage
pub const max_messages = 256; // messages kept loaded per chat

/// A model-owned copy of a message row with inline content storage, so the
/// loaded conversation survives across updates without an allocator (the DB
/// page bytes a query returns are only valid during the receiving update).
pub const MessageEntry = struct {
    id: i64 = 0,
    role: Role = .user,
    seq: i64 = 0,
    /// Position in the loaded list — set by the caller after appending, so
    /// markup can pass it as a payload (e.g. "Save to Snippets" by index).
    index: i64 = 0,
    content_buf: [max_content_bytes]u8 = undefined,
    content_len: usize = 0,

    pub fn content(self: *const MessageEntry) []const u8 {
        return self.content_buf[0..self.content_len];
    }
    pub fn isUser(self: *const MessageEntry) bool {
        return self.role == .user;
    }
    pub fn isAssistant(self: *const MessageEntry) bool {
        return self.role == .assistant;
    }
    /// The role as a display label for the view.
    pub fn roleLabel(self: *const MessageEntry) []const u8 {
        return switch (self.role) {
            .user => "You",
            .assistant => "Blocks",
            .system => "System",
        };
    }

    pub fn fromMessage(m: Message) MessageEntry {
        var e = MessageEntry{ .id = m.id, .role = m.role, .seq = m.seq };
        e.setContent(m.content);
        return e;
    }
    pub fn set(role: Role, text: []const u8) MessageEntry {
        var e = MessageEntry{ .role = role };
        e.setContent(text);
        return e;
    }
    fn setContent(self: *MessageEntry, text: []const u8) void {
        self.content_len = @min(text.len, max_content_bytes);
        @memcpy(self.content_buf[0..self.content_len], text[0..self.content_len]);
    }
};

// --------------------------------------------- OpenAI chat request body

/// The system prompt that frames Blocks' assistant persona and tells it how
/// to use the injected memory context.
pub const system_prompt =
    "You are Blocks, a developer's memory assistant. You help the user recall " ++
    "and reason about their own recent coding work — git commits and file changes " ++
    "across their watched repositories. When a \"Relevant memory\" section is " ++
    "provided below, ground your answer in it and cite specifics (repo names, commit " ++
    "subjects, files). If the memory does not contain the answer, say so plainly " ++
    "rather than inventing details. Be concise and concrete.";

/// A message to serialize into the request (borrowed slices).
pub const OutMessage = struct {
    role: Role,
    content: []const u8,
};

/// Build the JSON body for POST /v1/chat/completions into `out`.
///
///   {"model":"local","stream":<stream>,"max_tokens":<max>,"messages":[
///      {"role":"system","content":<system_prompt [+ context]>},
///      {"role":<r>,"content":<c>}, ... ]}
///
/// `context` (when non-empty) is appended to the system message as a
/// "Relevant memory" block — this is the RAG injection. `history` are the
/// prior turns (oldest first) plus the new user message. All strings are
/// JSON-escaped. `model_name` is cosmetic (llama-server ignores it and uses
/// the loaded model), but we send a stable value.
pub fn buildRequest(
    out: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    history: []const OutMessage,
    context: []const u8,
    stream: bool,
    max_tokens: u32,
) !void {
    var w = JsonWriter{ .out = out, .alloc = alloc };
    try w.raw("{\"model\":\"local\",\"stream\":");
    try w.raw(if (stream) "true" else "false");
    try w.raw(",\"max_tokens\":");
    try w.number(@intCast(max_tokens));
    try w.raw(",\"messages\":[");

    // System message (prompt + optional retrieved context).
    try w.raw("{\"role\":\"system\",\"content\":");
    if (context.len == 0) {
        try w.string(system_prompt);
    } else {
        // Concatenate prompt + context into one escaped string.
        try w.beginString();
        try w.stringChunk(system_prompt);
        try w.stringChunk("\n\nRelevant memory:\n");
        try w.stringChunk(context);
        try w.endString();
    }
    try w.raw("}");

    for (history) |m| {
        try w.raw(",{\"role\":");
        try w.string(m.role.name());
        try w.raw(",\"content\":");
        try w.string(m.content);
        try w.raw("}");
    }
    try w.raw("]}");
}

// --------------------------------------------- streamed response parsing

/// The outcome of feeding one streamed line to the parser.
pub const StreamEvent = union(enum) {
    /// A content token to append to the in-progress assistant message.
    delta: []const u8,
    /// The terminal `data: [DONE]` sentinel — the stream is complete.
    done,
    /// A line with no content for us (keep-alive, role-only delta, blank).
    ignore,
};

/// Parse one line of the llama-server SSE stream. Lines look like:
///   `data: {"choices":[{"delta":{"content":"Hello"},...}]}`
///   `data: [DONE]`
/// Non-`data:` lines (blank keep-alives, comments) are ignored. The
/// returned `delta` slice borrows `line` (valid only for this call).
/// `scratch` is used to unescape the JSON string content.
pub fn parseStreamLine(line: []const u8, scratch: []u8) StreamEvent {
    const trimmed = std.mem.trim(u8, line, " \r\n\t");
    if (trimmed.len == 0) return .ignore;
    if (!std.mem.startsWith(u8, trimmed, "data:")) return .ignore;
    const payload = std.mem.trim(u8, trimmed["data:".len..], " \r\n\t");
    if (std.mem.eql(u8, payload, "[DONE]")) return .done;
    // Extract the "content" string from the first choice's delta. We do a
    // targeted scan rather than a full JSON parse to stay allocation-free
    // in the hot streaming path.
    const content = extractDeltaContent(payload, scratch) orelse return .ignore;
    if (content.len == 0) return .ignore;
    return .{ .delta = content };
}

/// Find `"content":"..."` inside a chat.completion.chunk payload and return
/// the UNESCAPED string (written into `scratch`). Returns null if there is
/// no content field (e.g. a role-only opening delta or a finish chunk).
fn extractDeltaContent(payload: []const u8, scratch: []u8) ?[]const u8 {
    const key = "\"content\":";
    const at = std.mem.indexOf(u8, payload, key) orelse return null;
    var i = at + key.len;
    while (i < payload.len and (payload[i] == ' ' or payload[i] == '\t')) i += 1;
    if (i >= payload.len) return null;
    if (payload[i] == 'n') return null; // "content":null (no token)
    if (payload[i] != '"') return null;
    i += 1;
    return unescapeJsonString(payload[i..], scratch);
}

/// Unescape a JSON string body (the bytes AFTER the opening quote) up to the
/// closing unescaped quote, writing the decoded bytes into `scratch`.
fn unescapeJsonString(s: []const u8, scratch: []u8) ?[]const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == '"') return scratch[0..n];
        if (n >= scratch.len) return scratch[0..n]; // cap — keep what we have
        if (c == '\\' and i + 1 < s.len) {
            i += 1;
            const e = s[i];
            const decoded: u8 = switch (e) {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                '"' => '"',
                '\\' => '\\',
                '/' => '/',
                'b' => 0x08,
                'f' => 0x0c,
                'u' => {
                    // \uXXXX — emit the codepoint as UTF-8 (BMP only; good
                    // enough for chat text) and advance past the 4 hex digits.
                    if (i + 4 >= s.len) return scratch[0..n];
                    const cp = std.fmt.parseInt(u21, s[i + 1 .. i + 5], 16) catch {
                        i += 5;
                        continue;
                    };
                    i += 4;
                    var utf8: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(cp, &utf8) catch {
                        i += 1;
                        continue;
                    };
                    const room = @min(len, scratch.len - n);
                    @memcpy(scratch[n .. n + room], utf8[0..room]);
                    n += room;
                    i += 1;
                    continue;
                },
                else => e,
            };
            scratch[n] = decoded;
            n += 1;
            i += 1;
            continue;
        }
        scratch[n] = c;
        n += 1;
        i += 1;
    }
    return scratch[0..n]; // no closing quote seen (partial) — return what we have
}

// ------------------------------------------------- MCP search_memory call

/// Build the JSON-RPC `tools/call` body for `search_memory` into `out`:
///   {"jsonrpc":"2.0","id":1,"method":"tools/call",
///    "params":{"name":"search_memory","arguments":{"query":<q>,"limit":<n>}}}
pub fn buildSearchRequest(out: *std.ArrayList(u8), alloc: std.mem.Allocator, query: []const u8, limit: u32) !void {
    var w = JsonWriter{ .out = out, .alloc = alloc };
    try w.raw("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"search_memory\",\"arguments\":{\"query\":");
    try w.string(query);
    try w.raw(",\"limit\":");
    try w.number(@intCast(limit));
    try w.raw("}}}");
}

/// Turn an MCP `search_memory` HTTP response body into a compact plain-text
/// context block for injection, written into `out`. The response is
/// double-wrapped: JSON-RPC `result.content[0].text` is itself the tool's
/// JSON (`{"query":...,"results":[{repo,title,snippet,...}]}`). We parse it
/// with std.json (this runs once per user turn, off the hot path) and emit
/// up to `max_hits` lines like:
///   - [<repo>] <title>: <snippet>
/// Returns the number of hits written (0 when there are none / on any parse
/// failure — retrieval is best-effort and never blocks the chat).
pub fn formatSearchContext(
    out: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    response_body: []const u8,
    max_hits: usize,
) !usize {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, response_body, .{}) catch return 0;
    defer parsed.deinit();
    if (parsed.value != .object) return 0;

    // result.content[0].text
    const result = parsed.value.object.get("result") orelse return 0;
    if (result != .object) return 0;
    const content = result.object.get("content") orelse return 0;
    if (content != .array or content.array.items.len == 0) return 0;
    const first = content.array.items[0];
    if (first != .object) return 0;
    const text_v = first.object.get("text") orelse return 0;
    if (text_v != .string) return 0;

    // Parse the inner tool JSON.
    var inner = std.json.parseFromSlice(std.json.Value, alloc, text_v.string, .{}) catch return 0;
    defer inner.deinit();
    if (inner.value != .object) return 0;
    const results = inner.value.object.get("results") orelse return 0;
    if (results != .array) return 0;

    var written: usize = 0;
    for (results.array.items) |hit| {
        if (written >= max_hits) break;
        if (hit != .object) continue;
        const repo = strField(hit.object, "repo") orelse "";
        const title = strField(hit.object, "title") orelse "";
        const snippet = strField(hit.object, "snippet") orelse "";
        try out.appendSlice(alloc, "- [");
        try out.appendSlice(alloc, repo);
        try out.appendSlice(alloc, "] ");
        try out.appendSlice(alloc, title);
        if (snippet.len > 0) {
            try out.appendSlice(alloc, ": ");
            try out.appendSlice(alloc, snippet);
        }
        try out.appendSlice(alloc, "\n");
        written += 1;
    }
    return written;
}

fn strField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn intField(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |n| n,
        .float => |f| @as(i64, @intFromFloat(f)),
        else => null,
    };
}

// ------------------------------------------------ MCP get_activity call

/// Build the JSON-RPC `tools/call` body for `get_activity` into `out`. Used
/// by the single-click summaries to retrieve recent commits ∪ file snapshots
/// in a time window:
///   {"jsonrpc":"2.0","id":1,"method":"tools/call",
///    "params":{"name":"get_activity","arguments":{"since_ms":<s>,"limit":<n>}}}
/// `since_ms` bounds the window; `until_ms` is left open (the tool defaults it
/// to +inf), so "now" is implicit.
pub fn buildActivityRequest(
    out: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    since_ms: i64,
    limit: u32,
) !void {
    var w = JsonWriter{ .out = out, .alloc = alloc };
    try w.raw("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"get_activity\",\"arguments\":{\"since_ms\":");
    try w.number(since_ms);
    try w.raw(",\"limit\":");
    try w.number(@intCast(limit));
    try w.raw("}}}");
}

/// Turn an MCP `get_activity` HTTP response body into a compact plain-text
/// "recent activity" context block for injection, written into `out`. Same
/// double-wrapping as `formatSearchContext`: JSON-RPC `result.content[0].text`
/// is the tool's own JSON (`{"activity":[{kind,repo,title,occurred_at,...}]}`).
/// Emits up to `max_rows` lines like:
///   - [<repo>] <commit|edit> <title>
/// Returns the number of rows written (0 when there are none / on any parse
/// failure — retrieval is best-effort and never blocks the summary).
pub fn formatActivityContext(
    out: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    response_body: []const u8,
    max_rows: usize,
) !usize {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, response_body, .{}) catch return 0;
    defer parsed.deinit();
    if (parsed.value != .object) return 0;

    const result = parsed.value.object.get("result") orelse return 0;
    if (result != .object) return 0;
    const content = result.object.get("content") orelse return 0;
    if (content != .array or content.array.items.len == 0) return 0;
    const first = content.array.items[0];
    if (first != .object) return 0;
    const text_v = first.object.get("text") orelse return 0;
    if (text_v != .string) return 0;

    var inner = std.json.parseFromSlice(std.json.Value, alloc, text_v.string, .{}) catch return 0;
    defer inner.deinit();
    if (inner.value != .object) return 0;
    const activity = inner.value.object.get("activity") orelse return 0;
    if (activity != .array) return 0;

    var written: usize = 0;
    for (activity.array.items) |row| {
        if (written >= max_rows) break;
        if (row != .object) continue;
        const repo = strField(row.object, "repo") orelse "";
        const title = strField(row.object, "title") orelse "";
        const kind = strField(row.object, "kind") orelse "";
        // Map the tool's row kind to a compact verb.
        const verb: []const u8 = if (std.mem.eql(u8, kind, "commit"))
            "commit"
        else if (std.mem.eql(u8, kind, "file_snapshot"))
            "edit"
        else
            kind;
        _ = intField(row.object, "occurred_at"); // reserved for a future date prefix
        try out.appendSlice(alloc, "- [");
        try out.appendSlice(alloc, repo);
        try out.appendSlice(alloc, "] ");
        if (verb.len > 0) {
            try out.appendSlice(alloc, verb);
            try out.appendSlice(alloc, " ");
        }
        try out.appendSlice(alloc, title);
        try out.appendSlice(alloc, "\n");
        written += 1;
    }
    return written;
}

// --------------------------------------------------------- misc helpers

/// The maximum length of a chat title/preview derived from a message.
pub const title_max_bytes = 80;

/// Derive a short single-line title/preview from a message: trim, collapse
/// to the first line, and cap at `title_max_bytes` (UTF-8-safe-ish). Returns
/// a slice of `text` (no allocation). Used for the chat's title + preview.
pub fn excerptTitle(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    // Cut at the first newline.
    var end = trimmed.len;
    if (std.mem.indexOfScalar(u8, trimmed, '\n')) |nl| end = nl;
    if (end > title_max_bytes) {
        end = title_max_bytes;
        // Back off over a UTF-8 continuation boundary.
        while (end > 0 and (trimmed[end] & 0xC0) == 0x80) end -= 1;
    }
    return trimmed[0..end];
}

// --------------------------------------------------------- JSON writer

/// A tiny allocation-light JSON string writer over a caller `ArrayList`.
/// Kept local (rather than importing the MCP one) so this module has no
/// dependency on the MCP layer.
const JsonWriter = struct {
    out: *std.ArrayList(u8),
    alloc: std.mem.Allocator,

    fn raw(self: *JsonWriter, s: []const u8) !void {
        try self.out.appendSlice(self.alloc, s);
    }
    fn number(self: *JsonWriter, n: i64) !void {
        var buf: [24]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch unreachable;
        try self.raw(s);
    }
    fn beginString(self: *JsonWriter) !void {
        try self.out.append(self.alloc, '"');
    }
    fn endString(self: *JsonWriter) !void {
        try self.out.append(self.alloc, '"');
    }
    /// Append escaped bytes to an already-open string (no surrounding quotes).
    fn stringChunk(self: *JsonWriter, s: []const u8) !void {
        for (s) |c| {
            switch (c) {
                '"' => try self.raw("\\\""),
                '\\' => try self.raw("\\\\"),
                '\n' => try self.raw("\\n"),
                '\r' => try self.raw("\\r"),
                '\t' => try self.raw("\\t"),
                0x08 => try self.raw("\\b"),
                0x0c => try self.raw("\\f"),
                else => {
                    if (c < 0x20) {
                        var b: [6]u8 = undefined;
                        const e = std.fmt.bufPrint(&b, "\\u{x:0>4}", .{c}) catch unreachable;
                        try self.raw(e);
                    } else {
                        try self.out.append(self.alloc, c);
                    }
                },
            }
        }
    }
    /// Write a complete quoted, escaped JSON string.
    fn string(self: *JsonWriter, s: []const u8) !void {
        try self.beginString();
        try self.stringChunk(s);
        try self.endString();
    }
};

// --------------------------------------------------------------- tests

const testing = std.testing;

test "Role round-trips through name/fromName" {
    try testing.expectEqualStrings("assistant", Role.assistant.name());
    try testing.expectEqual(Role.user, Role.fromName("user").?);
    try testing.expectEqual(Role.system, Role.fromName("system").?);
    try testing.expect(Role.fromName("bogus") == null);
}

test "message/chat statement builders carry the right params" {
    var cbuf: [3]db.Value = undefined;
    const c = chatInsertStatement(&cbuf, "Title", "Preview", 1000);
    try testing.expectEqualStrings("Title", c.params[0].text);
    try testing.expectEqualStrings("Preview", c.params[1].text);
    try testing.expectEqual(@as(i64, 1000), c.params[2].integer);

    var mbuf: [5]db.Value = undefined;
    const m = messageInsertStatement(&mbuf, 7, .assistant, "hi", 3, 2000);
    try testing.expectEqual(@as(i64, 7), m.params[0].integer);
    try testing.expectEqualStrings("assistant", m.params[1].text);
    try testing.expectEqualStrings("hi", m.params[2].text);
    try testing.expectEqual(@as(i64, 3), m.params[3].integer);
    try testing.expectEqual(@as(i64, 2000), m.params[4].integer);
}

test "MessageEntry copies content and reports role" {
    const e = MessageEntry.set(.user, "hello world");
    try testing.expectEqualStrings("hello world", e.content());
    try testing.expect(e.isUser());
    try testing.expectEqualStrings("You", e.roleLabel());
}

test "buildRequest without context embeds the system prompt and messages" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    const hist = [_]OutMessage{
        .{ .role = .user, .content = "hi \"there\"" },
    };
    try buildRequest(&out, testing.allocator, &hist, "", true, 256);
    // Valid JSON with stream true and the escaped user content.
    try testing.expect(std.mem.indexOf(u8, out.items, "\"stream\":true") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\\\"there\\\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "You are Blocks") != null);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out.items, .{});
    defer parsed.deinit();
}

test "buildRequest with context injects a Relevant memory block" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    const hist = [_]OutMessage{.{ .role = .user, .content = "what did I do?" }};
    try buildRequest(&out, testing.allocator, &hist, "- [repo] Fix bug: details", false, 128);
    try testing.expect(std.mem.indexOf(u8, out.items, "Relevant memory") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "Fix bug") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"stream\":false") != null);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out.items, .{});
    defer parsed.deinit();
}

test "parseStreamLine extracts delta content, DONE, and ignores others" {
    var scratch: [256]u8 = undefined;
    const d = parseStreamLine("data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"},\"index\":0}]}", &scratch);
    try testing.expectEqualStrings("Hello", d.delta);

    const done = parseStreamLine("data: [DONE]", &scratch);
    try testing.expectEqual(StreamEvent.done, done);

    // Role-only opening delta -> no content -> ignore.
    const role = parseStreamLine("data: {\"choices\":[{\"delta\":{\"role\":\"assistant\"},\"index\":0}]}", &scratch);
    try testing.expectEqual(StreamEvent.ignore, role);

    // Blank keep-alive.
    try testing.expectEqual(StreamEvent.ignore, parseStreamLine("", &scratch));
    try testing.expectEqual(StreamEvent.ignore, parseStreamLine(": ping", &scratch));
}

test "parseStreamLine unescapes newlines and quotes in content" {
    var scratch: [256]u8 = undefined;
    const d = parseStreamLine("data: {\"choices\":[{\"delta\":{\"content\":\"line1\\nsay \\\"hi\\\"\"}}]}", &scratch);
    try testing.expectEqualStrings("line1\nsay \"hi\"", d.delta);
}

test "buildSearchRequest builds a tools/call for search_memory" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try buildSearchRequest(&out, testing.allocator, "tray commit", 5);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"method\":\"tools/call\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"name\":\"search_memory\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"query\":\"tray commit\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"limit\":5") != null);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out.items, .{});
    defer parsed.deinit();
}

test "formatSearchContext unwraps the double-wrapped result into lines" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    // The inner tool JSON (as text) with two hits.
    const inner =
        "{\"query\":\"tray\",\"results\":[" ++
        "{\"kind\":\"event\",\"repo\":\"blocks\",\"title\":\"Task 6: tray\",\"snippet\":\"always-on tray\",\"score\":0.9}," ++
        "{\"kind\":\"file_snapshot\",\"repo\":\"blocks\",\"title\":\"src/tray.zig\",\"snippet\":\"menu builder\",\"score\":0.7}]}";
    // The MCP envelope wraps that as result.content[0].text (escaped).
    var envelope: std.ArrayList(u8) = .empty;
    defer envelope.deinit(testing.allocator);
    var w = JsonWriter{ .out = &envelope, .alloc = testing.allocator };
    try w.raw("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"content\":[{\"type\":\"text\",\"text\":");
    try w.string(inner);
    try w.raw("}],\"isError\":false}}");

    const n = try formatSearchContext(&out, testing.allocator, envelope.items, 5);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expect(std.mem.indexOf(u8, out.items, "[blocks] Task 6: tray: always-on tray") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "src/tray.zig: menu builder") != null);
}

test "formatSearchContext returns 0 on malformed or empty input" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), try formatSearchContext(&out, testing.allocator, "not json", 5));
    try testing.expectEqual(@as(usize, 0), try formatSearchContext(&out, testing.allocator, "{\"result\":{}}", 5));
}

test "SummaryKind exposes distinct chat kinds, titles, and prompts" {
    try testing.expectEqualStrings("day_recap", SummaryKind.day_recap.chatKind());
    try testing.expectEqualStrings("top_of_mind", SummaryKind.top_of_mind.chatKind());
    try testing.expectEqualStrings("standup", SummaryKind.standup.chatKind());
    try testing.expectEqualStrings("Day Recap", SummaryKind.day_recap.title());
    try testing.expectEqualStrings("What's Top of Mind", SummaryKind.top_of_mind.title());
    try testing.expectEqualStrings("Standup Update", SummaryKind.standup.title());
    // Prompts are non-empty and mention "activity" (they lean on the block).
    inline for (.{ SummaryKind.day_recap, SummaryKind.top_of_mind, SummaryKind.standup }) |k| {
        try testing.expect(k.prompt().len > 0);
        try testing.expect(std.mem.indexOf(u8, k.prompt(), "activity") != null);
        try testing.expect(k.lookbackMs() > 0);
        try testing.expect(k.activityLimit() > 0);
    }
    // Top-of-mind looks back further than the day recap.
    try testing.expect(SummaryKind.top_of_mind.lookbackMs() > SummaryKind.day_recap.lookbackMs());
}

test "chatInsertKindStatement carries the kind param" {
    var buf: [4]db.Value = undefined;
    const s = chatInsertKindStatement(&buf, "Day Recap", "preview", "day_recap", 4242);
    try testing.expectEqualStrings(chat_insert_kind_sql, s.sql);
    try testing.expectEqualStrings("Day Recap", s.params[0].text);
    try testing.expectEqualStrings("preview", s.params[1].text);
    try testing.expectEqualStrings("day_recap", s.params[2].text);
    try testing.expectEqual(@as(i64, 4242), s.params[3].integer);
}

test "buildActivityRequest builds a tools/call for get_activity" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try buildActivityRequest(&out, testing.allocator, 1_700_000_000_000, 30);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"method\":\"tools/call\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"name\":\"get_activity\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"since_ms\":1700000000000") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"limit\":30") != null);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out.items, .{});
    defer parsed.deinit();
}

test "formatActivityContext unwraps the double-wrapped result into lines" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    const inner =
        "{\"activity\":[" ++
        "{\"kind\":\"commit\",\"ref_id\":1,\"repo_id\":1,\"repo\":\"blocks\",\"title\":\"Add tray\",\"occurred_at\":2000}," ++
        "{\"kind\":\"file_snapshot\",\"ref_id\":2,\"repo_id\":1,\"repo\":\"blocks\",\"title\":\"src/tray.zig\",\"occurred_at\":1000}]}";
    var envelope: std.ArrayList(u8) = .empty;
    defer envelope.deinit(testing.allocator);
    var w = JsonWriter{ .out = &envelope, .alloc = testing.allocator };
    try w.raw("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"content\":[{\"type\":\"text\",\"text\":");
    try w.string(inner);
    try w.raw("}],\"isError\":false}}");

    const n = try formatActivityContext(&out, testing.allocator, envelope.items, 10);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expect(std.mem.indexOf(u8, out.items, "[blocks] commit Add tray") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "[blocks] edit src/tray.zig") != null);
}

test "formatActivityContext returns 0 on malformed or empty input" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), try formatActivityContext(&out, testing.allocator, "not json", 5));
    try testing.expectEqual(@as(usize, 0), try formatActivityContext(&out, testing.allocator, "{\"result\":{}}", 5));
}

test "excerptTitle trims, takes the first line, and caps length" {
    try testing.expectEqualStrings("hello", excerptTitle("  hello  "));
    try testing.expectEqualStrings("first line", excerptTitle("first line\nsecond line"));
    const long = "x" ** 200;
    try testing.expectEqual(@as(usize, title_max_bytes), excerptTitle(long).len);
}

test "dateGroup buckets by local-day delta from now" {
    const day: i64 = 24 * 60 * 60 * 1000;
    const now: i64 = 100 * day + (day / 2); // midday of day 100
    try testing.expectEqual(DateGroup.today, dateGroup(now, now));
    try testing.expectEqual(DateGroup.today, dateGroup(100 * day + 10, now));
    try testing.expectEqual(DateGroup.yesterday, dateGroup(99 * day + 10, now));
    try testing.expectEqual(DateGroup.earlier, dateGroup(98 * day + 10, now));
    try testing.expectEqual(DateGroup.earlier, dateGroup(0, now));
}

test "formatDmy renders a timestamp as dd-MM-yyyy (UTC civil day)" {
    var buf: [dmy_len]u8 = undefined;
    // 1970-01-01 (epoch).
    try testing.expectEqualStrings("01-01-1970", formatDmy(&buf, 0));
    // 2026-01-01T00:00:00Z = 1767225600 s.
    try testing.expectEqualStrings("01-01-2026", formatDmy(&buf, 1767225600 * 1000));
    // A day+time within 2026-09-24.
    try testing.expectEqualStrings("24-09-2026", formatDmy(&buf, 1790208000 * 1000));
}

test "ChatEntry.groupLabel shows the creation date for the earlier bucket" {
    const day: i64 = 24 * 60 * 60 * 1000;
    const now: i64 = 20500 * day; // some day well past epoch
    // A chat last active several days ago falls in the "earlier" bucket and
    // its header is the dd-MM-yyyy last-activity date, not the word "EARLIER".
    const c = Chat{
        .id = 1,
        .title = "old chat",
        .preview = "",
        .kind = "chat",
        .created_at = 19000 * day, // older still — NOT what the header uses
        .updated_at = 20000 * day, // 20000 days after epoch = 2024-10-04
    };
    var e = ChatEntry.fromChat(c, now);
    try testing.expectEqual(DateGroup.earlier, e.group);
    e.group_head = true;
    var buf: [dmy_len]u8 = undefined;
    try testing.expectEqualStrings(formatDmy(&buf, 20000 * day), e.groupLabel());
    // TODAY / YESTERDAY keep their words.
    const t = Chat{ .id = 2, .title = "t", .preview = "", .kind = "chat", .created_at = now, .updated_at = now };
    var te = ChatEntry.fromChat(t, now);
    te.group_head = true;
    try testing.expectEqualStrings("TODAY", te.groupLabel());
}

test "ChatEntry.fromChat copies title/preview, flags summaries, computes group" {
    const day: i64 = 24 * 60 * 60 * 1000;
    const now: i64 = 100 * day;
    const c = Chat{
        .id = 7,
        .title = "Work Progress Update",
        .preview = "Neovim setup discussed.",
        .kind = "standup",
        .created_at = 99 * day,
        .updated_at = 99 * day,
    };
    const e = ChatEntry.fromChat(c, now);
    try testing.expectEqual(@as(i64, 7), e.id);
    try testing.expectEqualStrings("Work Progress Update", e.title());
    try testing.expectEqualStrings("Neovim setup discussed.", e.preview());
    try testing.expect(e.kind_is_summary);
    try testing.expectEqual(DateGroup.yesterday, e.group);

    const plain = Chat{ .id = 8, .title = "", .preview = "", .kind = "chat", .created_at = now, .updated_at = now };
    const pe = ChatEntry.fromChat(plain, now);
    try testing.expectEqualStrings("Untitled chat", pe.title());
    try testing.expect(!pe.kind_is_summary);
    try testing.expectEqual(DateGroup.today, pe.group);
}

test "Message.fromRow decodes a messages row" {
    var cols = [_]db.ColumnValue{
        .{ .integer = 5 },
        .{ .integer = 2 },
        .{ .text = "assistant" },
        .{ .text = "hi" },
        .{ .integer = 1 },
    };
    const m = Message.fromRow(&cols).?;
    try testing.expectEqual(@as(i64, 5), m.id);
    try testing.expectEqual(@as(i64, 2), m.chat_id);
    try testing.expectEqual(Role.assistant, m.role);
    try testing.expectEqualStrings("hi", m.content);
    try testing.expectEqual(@as(i64, 1), m.seq);
}
