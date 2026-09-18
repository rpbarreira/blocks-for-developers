//! Snippets ("materials") data layer — PURE, unit-tested (Task 12).
//!
//! Typed statement builders + row decoding over the `snippets` table, plus a
//! model-owned inline copy (`SnippetEntry`) so the loaded list survives across
//! updates without an allocator (query page bytes are valid only during the
//! receiving update). Mirrors the conventions in `repos.zig`:
//!   * `*_sql` string consts + caller-owned `*[N]db.Value` param buffers
//!     (the lifetime trap — a builder returning `&.{ runtimeValue, ... }`
//!     would dangle; the buffer must live until `dbExec`/`dbQuery` returns),
//!   * `Snippet.fromRow` decodes a `PageReader` row (borrowed slices),
//!   * `SnippetEntry` copies the row into fixed inline storage.
//!
//! A snippet is a saved piece of code ("material") the user keeps and can
//! recall. It carries a `language` tag (free-form — the user types it, with
//! typeahead from languages they've used before), a free-form `annotation`
//! and a `text_expander` note (the mockup's "All Context" panel), and an
//! optional origin (the chat/message it was saved from — "Save to Snippets").

const std = @import("std");
const db = @import("db.zig");

// ------------------------------------------------------------- bounds

/// Fixed inline caps for the model-owned copy (no allocator). Content is the
/// large one; the rest are short. A snippet larger than the content cap is
/// stored/displayed truncated (same policy as chat messages).
pub const max_title_bytes = 200;
pub const max_content_bytes = 8 * 1024;
pub const max_language_bytes = 64;
pub const max_annotation_bytes = 1024;
pub const max_text_expander_bytes = 1024;

/// Fixed-capacity list of loaded snippets held in the Model. Each entry
/// carries an inline copy (title/content/annotation/text_expander), so this
/// cap bounds the Model's size — keep it modest (the sidebar shows a scrolled
/// list, not thousands at once). At ~10 KiB/entry, 64 keeps the array ~0.7 MiB.
pub const max_snippets = 64;
/// Distinct languages surfaced for the filter menu + set-language typeahead.
pub const max_languages = 64;

// ------------------------------------------------------------- columns

/// Column order shared by `Snippet.fromRow` and the SELECT lists below.
pub const select_columns =
    "id, title, content, language, annotation, text_expander, " ++
    "origin_chat_id, origin_message_id, updated_at";

/// A decoded `snippets` row. Slices borrow the page bytes — copy what the
/// model keeps (see `SnippetEntry`). `origin_chat_id`/`origin_message_id`
/// are 0 when NULL (no origin).
pub const Snippet = struct {
    id: i64,
    title: []const u8,
    content: []const u8,
    language: []const u8,
    annotation: []const u8,
    text_expander: []const u8,
    origin_chat_id: i64,
    origin_message_id: i64,
    updated_at: i64,

    pub fn fromRow(cols: []const db.ColumnValue) ?Snippet {
        if (cols.len < 9) return null;
        return .{
            .id = cols[0].asInt() orelse return null,
            .title = cols[1].asText() orelse return null,
            .content = cols[2].asText() orelse return null,
            .language = cols[3].asText() orelse "",
            .annotation = cols[4].asText() orelse "",
            .text_expander = cols[5].asText() orelse "",
            // Nullable FKs: asInt() yields null for a NULL column -> 0.
            .origin_chat_id = cols[6].asInt() orelse 0,
            .origin_message_id = cols[7].asInt() orelse 0,
            .updated_at = cols[8].asInt() orelse 0,
        };
    }
};

/// A short one-line blurb cap for the sidebar cards.
pub const max_blurb_bytes = 160;

/// A LIGHTWEIGHT model-owned copy of a snippet row for the SIDEBAR LIST — just
/// the fields the card shows (id, title, a short blurb, language, updated_at,
/// origins). It deliberately does NOT hold the full content/annotation/text-
/// expander: keeping those inline for every list row would make the Model
/// several MB (the list is capped at `max_snippets`). The full body of the
/// SELECTED snippet is loaded separately into `SnippetDetail`.
pub const SnippetEntry = struct {
    id: i64 = 0,
    origin_chat_id: i64 = 0,
    origin_message_id: i64 = 0,
    updated_at: i64 = 0,
    title_buf: [max_title_bytes]u8 = undefined,
    title_len: usize = 0,
    language_buf: [max_language_bytes]u8 = undefined,
    language_len: usize = 0,
    blurb_buf: [max_blurb_bytes]u8 = undefined,
    blurb_len: usize = 0,

    pub fn title(self: *const SnippetEntry) []const u8 {
        return self.title_buf[0..self.title_len];
    }
    pub fn language(self: *const SnippetEntry) []const u8 {
        return self.language_buf[0..self.language_len];
    }
    /// A short one-line description for the sidebar card (annotation first,
    /// falling back to the content's first line), computed at copy time.
    pub fn cardBlurb(self: *const SnippetEntry) []const u8 {
        return self.blurb_buf[0..self.blurb_len];
    }

    pub fn fromSnippet(s: Snippet) SnippetEntry {
        var e = SnippetEntry{
            .id = s.id,
            .origin_chat_id = s.origin_chat_id,
            .origin_message_id = s.origin_message_id,
            .updated_at = s.updated_at,
        };
        copyInto(&e.title_buf, &e.title_len, s.title);
        copyInto(&e.language_buf, &e.language_len, s.language);
        const blurb = if (s.annotation.len > 0) firstLine(s.annotation) else firstLine(s.content);
        copyInto(&e.blurb_buf, &e.blurb_len, blurb);
        return e;
    }
};

/// The FULL body of the currently-selected snippet, loaded on demand (one at
/// a time), so the large content/annotation/text-expander buffers exist once
/// in the Model rather than per list row.
pub const SnippetDetail = struct {
    id: i64 = 0,
    origin_chat_id: i64 = 0,
    origin_message_id: i64 = 0,
    title_buf: [max_title_bytes]u8 = undefined,
    title_len: usize = 0,
    content_buf: [max_content_bytes]u8 = undefined,
    content_len: usize = 0,
    language_buf: [max_language_bytes]u8 = undefined,
    language_len: usize = 0,
    annotation_buf: [max_annotation_bytes]u8 = undefined,
    annotation_len: usize = 0,
    text_expander_buf: [max_text_expander_bytes]u8 = undefined,
    text_expander_len: usize = 0,

    pub fn title(self: *const SnippetDetail) []const u8 {
        return self.title_buf[0..self.title_len];
    }
    pub fn content(self: *const SnippetDetail) []const u8 {
        return self.content_buf[0..self.content_len];
    }
    pub fn language(self: *const SnippetDetail) []const u8 {
        return self.language_buf[0..self.language_len];
    }
    pub fn annotation(self: *const SnippetDetail) []const u8 {
        return self.annotation_buf[0..self.annotation_len];
    }
    pub fn textExpander(self: *const SnippetDetail) []const u8 {
        return self.text_expander_buf[0..self.text_expander_len];
    }

    pub fn fromSnippet(s: Snippet) SnippetDetail {
        var d = SnippetDetail{
            .id = s.id,
            .origin_chat_id = s.origin_chat_id,
            .origin_message_id = s.origin_message_id,
        };
        copyInto(&d.title_buf, &d.title_len, s.title);
        copyInto(&d.content_buf, &d.content_len, s.content);
        copyInto(&d.language_buf, &d.language_len, s.language);
        copyInto(&d.annotation_buf, &d.annotation_len, s.annotation);
        copyInto(&d.text_expander_buf, &d.text_expander_len, s.text_expander);
        return d;
    }
};

fn copyInto(buf: []u8, len: *usize, src: []const u8) void {
    len.* = @min(src.len, buf.len);
    @memcpy(buf[0..len.*], src[0..len.*]);
}

/// The first line of `text`, trimmed, capped for a compact card blurb.
fn firstLine(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    var end = trimmed.len;
    if (std.mem.indexOfScalar(u8, trimmed, '\n')) |nl| end = nl;
    const cap = 120;
    if (end > cap) end = cap;
    return trimmed[0..end];
}

// ------------------------------------------------------------- language list

/// A distinct language name for the filter menu / typeahead, copied inline.
/// `index` is its position in the loaded list (used by the set-language
/// typeahead: `pick_lang_suggestion:{index}`); `filterIndex` is `index+1`
/// because the filter menu reserves index 0 for the "All" option.
pub const LanguageEntry = struct {
    buf: [max_language_bytes]u8 = undefined,
    len: usize = 0,
    index: usize = 0,
    filterIndex: usize = 1,
    pub fn name(self: *const LanguageEntry) []const u8 {
        return self.buf[0..self.len];
    }
    pub fn set(s: []const u8) LanguageEntry {
        var e = LanguageEntry{};
        copyInto(&e.buf, &e.len, s);
        return e;
    }
};

// ------------------------------------------------------------- SQL

/// Most-recently-updated first (the "Recent" sort in the mockup).
pub const list_recent_sql =
    "SELECT " ++ select_columns ++ " FROM snippets ORDER BY updated_at DESC, id DESC;";
/// A-Z by title, case-insensitive (the "Alphabetical" sort).
pub const list_alpha_sql =
    "SELECT " ++ select_columns ++ " FROM snippets ORDER BY title COLLATE NOCASE ASC, id ASC;";
/// Same as recent but filtered to one language (?1 = language).
pub const list_recent_by_lang_sql =
    "SELECT " ++ select_columns ++ " FROM snippets WHERE language = ?1 ORDER BY updated_at DESC, id DESC;";
pub const list_alpha_by_lang_sql =
    "SELECT " ++ select_columns ++ " FROM snippets WHERE language = ?1 ORDER BY title COLLATE NOCASE ASC, id ASC;";

/// Search variants — title/content/annotation LIKE the query (?1 = pattern,
/// already wrapped in %…%). Combined with the language filter as ?2 where used.
pub const search_recent_sql =
    "SELECT " ++ select_columns ++ " FROM snippets " ++
    "WHERE (title LIKE ?1 OR content LIKE ?1 OR annotation LIKE ?1) " ++
    "ORDER BY updated_at DESC, id DESC;";
pub const search_alpha_sql =
    "SELECT " ++ select_columns ++ " FROM snippets " ++
    "WHERE (title LIKE ?1 OR content LIKE ?1 OR annotation LIKE ?1) " ++
    "ORDER BY title COLLATE NOCASE ASC, id ASC;";
pub const search_recent_by_lang_sql =
    "SELECT " ++ select_columns ++ " FROM snippets " ++
    "WHERE (title LIKE ?1 OR content LIKE ?1 OR annotation LIKE ?1) AND language = ?2 " ++
    "ORDER BY updated_at DESC, id DESC;";
pub const search_alpha_by_lang_sql =
    "SELECT " ++ select_columns ++ " FROM snippets " ++
    "WHERE (title LIKE ?1 OR content LIKE ?1 OR annotation LIKE ?1) AND language = ?2 " ++
    "ORDER BY title COLLATE NOCASE ASC, id ASC;";

/// The set of languages the user has used, for the filter menu + typeahead.
/// Skips the empty tag so "no language" never shows up as a filter option.
pub const distinct_langs_sql =
    "SELECT DISTINCT language FROM snippets WHERE language <> '' ORDER BY language COLLATE NOCASE ASC;";

/// Wrap a raw search term as a case-insensitive LIKE pattern into `buf`
/// (`%term%`). LIKE is ASCII-case-insensitive in SQLite by default, which is
/// fine for code/material search. Returns the slice written.
pub fn likePattern(buf: []u8, term: []const u8) []const u8 {
    var n: usize = 0;
    if (n < buf.len) {
        buf[n] = '%';
        n += 1;
    }
    for (term) |c| {
        if (n >= buf.len - 1) break;
        // Escape LIKE wildcards so a literal % or _ in the term matches itself
        // is overkill for v1; we treat the term as plain text (rare in code
        // search) and just copy. (An ESCAPE clause is a later refinement.)
        buf[n] = c;
        n += 1;
    }
    if (n < buf.len) {
        buf[n] = '%';
        n += 1;
    }
    return buf[0..n];
}

/// One snippet by id (for a fresh reload after edit).
pub const get_sql = "SELECT " ++ select_columns ++ " FROM snippets WHERE id = ?1;";

/// The greatest id — used to recover a just-inserted snippet's id (the SDK
/// store's `last_insert_rowid()` can read 0 on a pooled connection; Blocks is
/// the sole writer and rows aren't deleted mid-insert, mirroring chats).
pub const max_id_sql = "SELECT MAX(id) FROM snippets;";

/// Insert a new snippet. Origins are optional (NULL when created directly).
///   ?1 title ?2 content ?3 language ?4 annotation ?5 text_expander
///   ?6 origin_chat_id ?7 origin_message_id ?8 created+updated (now)
pub const insert_sql =
    "INSERT INTO snippets(title, content, language, annotation, text_expander, " ++
    "origin_chat_id, origin_message_id, created_at, updated_at) " ++
    "VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?8);";

/// Update an existing snippet's editable fields + bump updated_at.
///   ?1 title ?2 content ?3 language ?4 annotation ?5 text_expander
///   ?6 now ?7 id
pub const update_sql =
    "UPDATE snippets SET title = ?1, content = ?2, language = ?3, annotation = ?4, " ++
    "text_expander = ?5, updated_at = ?6 WHERE id = ?7;";

/// Set just the language + bump updated_at (the set-language modal). ?1 lang ?2 now ?3 id.
pub const set_language_sql =
    "UPDATE snippets SET language = ?1, updated_at = ?2 WHERE id = ?3;";

pub const delete_sql = "DELETE FROM snippets WHERE id = ?1;";

// ------------------------------------------------------- statement builders

/// New-snippet insert. Pass 0 for `origin_chat_id`/`origin_message_id` to
/// store NULL (created directly rather than from a chat). Caller-owned buffer.
pub fn insertStatement(
    buf: *[8]db.Value,
    title: []const u8,
    content: []const u8,
    language: []const u8,
    annotation: []const u8,
    text_expander: []const u8,
    origin_chat_id: i64,
    origin_message_id: i64,
    now_ms: i64,
) db.Statement {
    buf.* = .{
        db.val.text(title),
        db.val.text(content),
        db.val.text(language),
        db.val.text(annotation),
        db.val.text(text_expander),
        if (origin_chat_id != 0) db.val.int(origin_chat_id) else db.val.null_value,
        if (origin_message_id != 0) db.val.int(origin_message_id) else db.val.null_value,
        db.val.int(now_ms),
    };
    return .{ .sql = insert_sql, .params = buf };
}

pub fn updateStatement(
    buf: *[7]db.Value,
    id: i64,
    title: []const u8,
    content: []const u8,
    language: []const u8,
    annotation: []const u8,
    text_expander: []const u8,
    now_ms: i64,
) db.Statement {
    buf.* = .{
        db.val.text(title),
        db.val.text(content),
        db.val.text(language),
        db.val.text(annotation),
        db.val.text(text_expander),
        db.val.int(now_ms),
        db.val.int(id),
    };
    return .{ .sql = update_sql, .params = buf };
}

pub fn setLanguageStatement(buf: *[3]db.Value, id: i64, language: []const u8, now_ms: i64) db.Statement {
    buf.* = .{ db.val.text(language), db.val.int(now_ms), db.val.int(id) };
    return .{ .sql = set_language_sql, .params = buf };
}

pub fn deleteStatement(buf: *[1]db.Value, id: i64) db.Statement {
    buf.* = .{db.val.int(id)};
    return .{ .sql = delete_sql, .params = buf };
}

pub fn getParams(buf: *[1]db.Value, id: i64) []const db.Value {
    buf.* = .{db.val.int(id)};
    return buf;
}

pub fn langFilterParams(buf: *[1]db.Value, language: []const u8) []const db.Value {
    buf.* = .{db.val.text(language)};
    return buf;
}

// --------------------------------------------------------------- helpers

/// A short default title from a snippet body's first line (used when saving a
/// snippet from a chat message, where the user hasn't named it yet).
pub fn defaultTitle(content: []const u8) []const u8 {
    const line = firstLine(content);
    return if (line.len > 0) line else "Untitled snippet";
}

// --------------------------------------------------------------- tests

const testing = std.testing;

test "Snippet.fromRow decodes all columns incl null origins" {
    var cols = [_]db.ColumnValue{
        .{ .integer = 5 },
        .{ .text = "My Snippet" },
        .{ .text = "print(1)" },
        .{ .text = "python" },
        .{ .text = "a note" },
        .{ .text = "expander" },
        .null_value, // origin_chat_id NULL
        .null_value, // origin_message_id NULL
        .{ .integer = 999 },
    };
    const s = Snippet.fromRow(&cols).?;
    try testing.expectEqual(@as(i64, 5), s.id);
    try testing.expectEqualStrings("My Snippet", s.title);
    try testing.expectEqualStrings("python", s.language);
    try testing.expectEqualStrings("expander", s.text_expander);
    try testing.expectEqual(@as(i64, 0), s.origin_chat_id);
    try testing.expectEqual(@as(i64, 999), s.updated_at);
}

test "SnippetEntry (list card) copies title/language and derives a blurb" {
    const s = Snippet{
        .id = 1, .title = "T", .content = "line1\nline2", .language = "zig",
        .annotation = "the annotation", .text_expander = "x",
        .origin_chat_id = 3, .origin_message_id = 4, .updated_at = 10,
    };
    const e = SnippetEntry.fromSnippet(s);
    try testing.expectEqualStrings("T", e.title());
    try testing.expectEqualStrings("zig", e.language());
    try testing.expectEqual(@as(i64, 3), e.origin_chat_id);
    // Blurb prefers the annotation's first line.
    try testing.expectEqualStrings("the annotation", e.cardBlurb());
}

test "cardBlurb falls back to the content's first line" {
    const s = Snippet{
        .id = 1, .title = "T", .content = "first code line\nmore", .language = "",
        .annotation = "", .text_expander = "", .origin_chat_id = 0, .origin_message_id = 0, .updated_at = 1,
    };
    const e = SnippetEntry.fromSnippet(s);
    try testing.expectEqualStrings("first code line", e.cardBlurb());
}

test "SnippetDetail holds the full body of one snippet" {
    const s = Snippet{
        .id = 5, .title = "Detail", .content = "line1\nline2", .language = "zig",
        .annotation = "note", .text_expander = "expand", .origin_chat_id = 2, .origin_message_id = 0, .updated_at = 9,
    };
    const d = SnippetDetail.fromSnippet(s);
    try testing.expectEqual(@as(i64, 5), d.id);
    try testing.expectEqualStrings("line1\nline2", d.content());
    try testing.expectEqualStrings("note", d.annotation());
    try testing.expectEqualStrings("expand", d.textExpander());
}

test "insertStatement stores NULL origins as null_value and carries fields" {
    var buf: [8]db.Value = undefined;
    const s = insertStatement(&buf, "Title", "body", "rust", "note", "exp", 0, 0, 4242);
    try testing.expectEqualStrings(insert_sql, s.sql);
    try testing.expectEqualStrings("Title", s.params[0].text);
    try testing.expectEqualStrings("rust", s.params[2].text);
    try testing.expectEqualStrings("exp", s.params[4].text);
    try testing.expect(s.params[5] == .null_value);
    try testing.expect(s.params[6] == .null_value);
    try testing.expectEqual(@as(i64, 4242), s.params[7].integer);

    // With an origin, the ids are stored as integers.
    var buf2: [8]db.Value = undefined;
    const s2 = insertStatement(&buf2, "T", "b", "", "", "", 7, 9, 1);
    try testing.expectEqual(@as(i64, 7), s2.params[5].integer);
    try testing.expectEqual(@as(i64, 9), s2.params[6].integer);
}

test "updateStatement + setLanguageStatement + deleteStatement carry params" {
    var ubuf: [7]db.Value = undefined;
    const u = updateStatement(&ubuf, 3, "T", "b", "go", "n", "e", 555);
    try testing.expectEqualStrings("go", u.params[2].text);
    try testing.expectEqual(@as(i64, 555), u.params[5].integer);
    try testing.expectEqual(@as(i64, 3), u.params[6].integer);

    var lbuf: [3]db.Value = undefined;
    const l = setLanguageStatement(&lbuf, 8, "elixir", 20);
    try testing.expectEqualStrings("elixir", l.params[0].text);
    try testing.expectEqual(@as(i64, 8), l.params[2].integer);

    var dbuf: [1]db.Value = undefined;
    const d = deleteStatement(&dbuf, 12);
    try testing.expectEqual(@as(i64, 12), d.params[0].integer);
}

test "defaultTitle uses the first line or a fallback" {
    try testing.expectEqualStrings("fn main() {}", defaultTitle("fn main() {}\n// body"));
    try testing.expectEqualStrings("Untitled snippet", defaultTitle("   \n  "));
}

test "likePattern wraps the term in percent signs" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("%docker%", likePattern(&buf, "docker"));
    try testing.expectEqualStrings("%%", likePattern(&buf, ""));
}

// ---- Real in-memory DB integration test ----

const native_sdk = @import("native_sdk");
const relational_store = native_sdk.runtime.relational_store;
const Msg = union(enum) { db: native_sdk.EffectDbResult };
const Fx = native_sdk.Effects(Msg);

test "snippets insert/list/filter/update/delete round-trip against a real database" {
    const open_result = try relational_store.Database.openMemoryMigrated(testing.allocator, &db.migrations);
    try testing.expectEqual(relational_store.OpenOutcome.ok, open_result.outcome);
    var database = open_result.database.?;
    defer database.deinit();
    var fx = Fx.init(testing.allocator);
    defer fx.deinit();
    fx.bindRelationalStore(database.binding());

    // Insert three snippets: two python, one zig, staggered updated_at.
    var b1: [8]db.Value = undefined;
    var b2: [8]db.Value = undefined;
    var b3: [8]db.Value = undefined;
    fx.dbExec(.{ .key = 1, .statements = &.{
        insertStatement(&b1, "Alpha", "a()", "python", "", "", 0, 0, 100),
        insertStatement(&b2, "Beta", "b()", "zig", "note", "exp", 0, 0, 300),
        insertStatement(&b3, "Gamma", "c()", "python", "", "", 0, 0, 200),
    }, .on_result = Fx.dbMsg(.db) });
    try testing.expectEqual(native_sdk.EffectDbOutcome.ok, fx.takeMsg().?.db.outcome);

    // Recent list: Beta(300), Gamma(200), Alpha(100).
    fx.dbQuery(.{ .key = 2, .sql = list_recent_sql, .on_result = Fx.dbMsg(.db) });
    const page = fx.takeMsg().?.db;
    var reader = try db.PageReader.init(page.bytes);
    try testing.expectEqual(@as(usize, 3), reader.rowCount());
    var row: [9]db.ColumnValue = undefined;
    const first = Snippet.fromRow((try reader.next(&row)).?).?;
    try testing.expectEqualStrings("Beta", first.title);
    try testing.expectEqualStrings("exp", first.text_expander);
    _ = fx.takeMsg(); // .done
    const beta_id = first.id;

    // Distinct languages: python, zig (sorted, empty excluded).
    fx.dbQuery(.{ .key = 3, .sql = distinct_langs_sql, .on_result = Fx.dbMsg(.db) });
    const langs_page = fx.takeMsg().?.db;
    var langs_reader = try db.PageReader.init(langs_page.bytes);
    try testing.expectEqual(@as(usize, 2), langs_reader.rowCount());
    var lrow: [1]db.ColumnValue = undefined;
    try testing.expectEqualStrings("python", (try langs_reader.next(&lrow)).?[0].asText().?);
    try testing.expectEqualStrings("zig", (try langs_reader.next(&lrow)).?[0].asText().?);
    _ = fx.takeMsg(); // .done

    // Filter to python: Gamma(200), Alpha(100).
    var lb: [1]db.Value = undefined;
    fx.dbQuery(.{ .key = 4, .sql = list_recent_by_lang_sql, .params = langFilterParams(&lb, "python"), .on_result = Fx.dbMsg(.db) });
    const py_page = fx.takeMsg().?.db;
    var py_reader = try db.PageReader.init(py_page.bytes);
    try testing.expectEqual(@as(usize, 2), py_reader.rowCount());
    _ = fx.takeMsg(); // .done

    // Update Beta's language + fields, then read it back.
    var ub: [7]db.Value = undefined;
    fx.dbExec(.{ .key = 5, .statements = &.{updateStatement(&ub, beta_id, "Beta2", "b2()", "ziglang", "n2", "e2", 400)}, .on_result = Fx.dbMsg(.db) });
    try testing.expectEqual(native_sdk.EffectDbOutcome.ok, fx.takeMsg().?.db.outcome);
    var gb: [1]db.Value = undefined;
    fx.dbQuery(.{ .key = 6, .sql = get_sql, .params = getParams(&gb, beta_id), .on_result = Fx.dbMsg(.db) });
    const g_page = fx.takeMsg().?.db;
    var g_reader = try db.PageReader.init(g_page.bytes);
    var grow: [9]db.ColumnValue = undefined;
    const updated = Snippet.fromRow((try g_reader.next(&grow)).?).?;
    try testing.expectEqualStrings("Beta2", updated.title);
    try testing.expectEqualStrings("ziglang", updated.language);
    try testing.expectEqualStrings("e2", updated.text_expander);
    _ = fx.takeMsg(); // .done

    // Delete Alpha; list now has two rows.
    var deb: [1]db.Value = undefined;
    fx.dbExec(.{ .key = 7, .statements = &.{deleteStatement(&deb, first.id)}, .on_result = Fx.dbMsg(.db) });
    _ = fx.takeMsg();
    // (first.id is Beta; deleting it is fine for the count check.)
    fx.dbQuery(.{ .key = 8, .sql = list_recent_sql, .on_result = Fx.dbMsg(.db) });
    const page2 = fx.takeMsg().?.db;
    var reader2 = try db.PageReader.init(page2.bytes);
    try testing.expectEqual(@as(usize, 2), reader2.rowCount());
    _ = fx.takeMsg(); // .done
}

test "snippet origin FK is set null when the origin chat is deleted" {
    const open_result = try relational_store.Database.openMemoryMigrated(testing.allocator, &db.migrations);
    var database = open_result.database.?;
    defer database.deinit();
    var fx = Fx.init(testing.allocator);
    defer fx.deinit();
    fx.bindRelationalStore(database.binding());

    // A chat + a snippet whose origin points at it.
    fx.dbExec(.{ .key = 1, .statements = &.{
        .{ .sql = "INSERT INTO chats(id, title, created_at, updated_at) VALUES(1,'c',1,1);" },
    }, .on_result = Fx.dbMsg(.db) });
    _ = fx.takeMsg();
    var ib: [8]db.Value = undefined;
    fx.dbExec(.{ .key = 2, .statements = &.{insertStatement(&ib, "S", "code", "zig", "", "", 1, 0, 5)}, .on_result = Fx.dbMsg(.db) });
    try testing.expectEqual(native_sdk.EffectDbOutcome.ok, fx.takeMsg().?.db.outcome);

    // Deleting the chat SET NULLs the snippet's origin_chat_id (FK ON DELETE
    // SET NULL) — the snippet survives.
    fx.dbExec(.{ .key = 3, .statements = &.{.{ .sql = "DELETE FROM chats WHERE id = 1;" }}, .on_result = Fx.dbMsg(.db) });
    _ = fx.takeMsg();
    fx.dbQuery(.{ .key = 4, .sql = "SELECT origin_chat_id FROM snippets;", .on_result = Fx.dbMsg(.db) });
    const page = fx.takeMsg().?.db;
    var reader = try db.PageReader.init(page.bytes);
    var row: [1]db.ColumnValue = undefined;
    const cols = (try reader.next(&row)).?;
    try testing.expect(cols[0].isNull());
    _ = fx.takeMsg(); // .done
}
