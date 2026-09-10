//! Git history capture: PURE argv builders + PURE output parsers for
//! reading a watched repository's commit history into the `events` table.
//!
//! The effectful side (spawning `git`, running `dbExec`) lives in main.zig;
//! everything here is deterministic and unit-testable against captured
//! `git log` output strings, with no subprocess or database involved.
//!
//! Design:
//!   * `logArgv` builds `git -C <path> log --reverse --numstat --format=<fmt>`
//!     (optionally `<since>..HEAD`). Oldest-first so `last_indexed_oid`
//!     advances monotonically as we insert.
//!   * The custom `--format` frames each commit's header with control
//!     chars so message content (which may contain newlines, quotes, or
//!     anything) can never break parsing:
//!       - Record separator  RS  = 0x1e  starts every commit header line.
//!       - Field separator   US  = 0x1f  delimits the header fields.
//!     After the header line, `--numstat` emits one `add<TAB>del<TAB>path`
//!     line per changed file, until the next RS (or end of output).
//!   * `parseLog` walks the output into `Commit` values that borrow from
//!     the input bytes (copy anything kept beyond the parse).
//!   * `insertStatement` builds the `events` INSERT with a caller-owned
//!     param buffer (avoids the dangling-params lifetime trap).

const std = @import("std");
const db = @import("db.zig");

pub const rs: u8 = 0x1e; // record separator — begins each commit header
pub const us: u8 = 0x1f; // unit separator  — between header fields

/// The `--format` string handed to `git log`. Fields, in order:
///   %H  full commit hash
///   %an author name
///   %ae author email
///   %aI author date, strict ISO-8601 (with timezone)
///   %s  subject (first line of the message)
///   %b  body (the rest of the message; may be multi-line/empty)
/// The leading RS frames the record; a trailing US closes the body so a
/// body ending in a newline (from --numstat's blank line) is unambiguous.
pub const log_format =
    "\x1e%H\x1f%an\x1f%ae\x1f%aI\x1f%s\x1f%b\x1f";

/// Maximum argv slots any builder needs (git, -C, path, log, --reverse,
/// --numstat, --format=..., range). Callers pass a buffer of this size.
pub const max_argv = 8;

/// Build the `git log` argv into a caller-owned buffer and return the
/// used slice. When `since_oid` is non-empty, only commits after it are
/// listed (`<since>..HEAD`); otherwise the full history is walked.
///
/// The `format_buf` receives the `--format=` argument (its contents must
/// outlive use of the returned argv). `range_buf` similarly holds the
/// `<since>..HEAD` argument when a range is used.
pub fn logArgv(
    argv: *[max_argv][]const u8,
    format_buf: []u8,
    range_buf: []u8,
    repo_path: []const u8,
    since_oid: []const u8,
) [][]const u8 {
    const format_arg = std.fmt.bufPrint(format_buf, "--format={s}", .{log_format}) catch "--format=";
    argv[0] = "git";
    argv[1] = "-C";
    argv[2] = repo_path;
    argv[3] = "log";
    argv[4] = "--reverse";
    argv[5] = "--numstat";
    argv[6] = format_arg;
    if (since_oid.len > 0) {
        const range = std.fmt.bufPrint(range_buf, "{s}..HEAD", .{since_oid}) catch {
            return argv[0..7];
        };
        argv[7] = range;
        return argv[0..8];
    }
    return argv[0..7];
}

/// One parsed commit. All slices borrow from the parsed `git log` output.
pub const Commit = struct {
    oid: []const u8,
    author_name: []const u8,
    author_email: []const u8,
    /// Author date as the raw ISO-8601 string git emitted (e.g.
    /// "2026-09-10T14:03:22+02:00").
    author_date_iso: []const u8,
    subject: []const u8,
    body: []const u8,
    files_changed: i64 = 0,
    insertions: i64 = 0,
    deletions: i64 = 0,
};

pub const ParseError = error{Malformed};

/// Streaming parser over `git log --reverse --numstat --format=log_format`
/// output. Yields commits in the order git emitted them (oldest-first).
pub const LogParser = struct {
    bytes: []const u8,
    at: usize = 0,

    pub fn init(bytes: []const u8) LogParser {
        return .{ .bytes = bytes };
    }

    /// Parse the next commit, or null at end of input.
    pub fn next(self: *LogParser) ParseError!?Commit {
        // Advance to the next record separator (skips the numstat lines /
        // blank lines that follow the previous commit).
        const rs_idx = std.mem.indexOfScalarPos(u8, self.bytes, self.at, rs) orelse {
            self.at = self.bytes.len;
            return null;
        };
        self.at = rs_idx + 1;

        // The header is the six US-separated fields, terminated by the
        // trailing US in log_format. Read exactly six fields.
        var fields: [6][]const u8 = undefined;
        var i: usize = 0;
        while (i < 6) : (i += 1) {
            const us_idx = std.mem.indexOfScalarPos(u8, self.bytes, self.at, us) orelse return error.Malformed;
            fields[i] = self.bytes[self.at..us_idx];
            self.at = us_idx + 1;
        }

        var commit = Commit{
            .oid = fields[0],
            .author_name = fields[1],
            .author_email = fields[2],
            .author_date_iso = fields[3],
            .subject = fields[4],
            .body = std.mem.trimEnd(u8, fields[5], "\n"),
        };

        // Everything from here to the next RS (or EOF) is --numstat output:
        // lines of "<added>\t<deleted>\t<path>". Rename lines look the
        // same for our counting purposes. Binary files use "-" for counts.
        const stats_end = std.mem.indexOfScalarPos(u8, self.bytes, self.at, rs) orelse self.bytes.len;
        const stats = self.bytes[self.at..stats_end];
        self.accumulateNumstat(&commit, stats);
        // Leave self.at pointing before the next RS; `next` re-seeks it.
        self.at = stats_end;

        return commit;
    }

    fn accumulateNumstat(_: *LogParser, commit: *Commit, stats: []const u8) void {
        var lines = std.mem.splitScalar(u8, stats, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \r");
            if (trimmed.len == 0) continue;
            var parts = std.mem.splitScalar(u8, trimmed, '\t');
            const add_s = parts.next() orelse continue;
            const del_s = parts.next() orelse continue;
            const path = parts.rest();
            if (path.len == 0) continue;
            commit.files_changed += 1;
            // Binary files report "-"; treat as zero line changes.
            commit.insertions += std.fmt.parseInt(i64, add_s, 10) catch 0;
            commit.deletions += std.fmt.parseInt(i64, del_s, 10) catch 0;
        }
    }
};

/// Parse the whole log output into `out` (a caller-owned buffer), returning
/// the filled slice. Stops at `out.len` commits.
pub fn parseLog(out: []Commit, bytes: []const u8) ParseError![]Commit {
    var parser = LogParser.init(bytes);
    var n: usize = 0;
    while (n < out.len) {
        const c = (try parser.next()) orelse break;
        out[n] = c;
        n += 1;
    }
    return out[0..n];
}

// ------------------------------------------------------- time parsing

/// Convert a strict ISO-8601 timestamp (as `%aI` emits, e.g.
/// "2026-09-10T14:03:22+02:00" or "...Z") to Unix milliseconds. Returns a
/// fallback (usually the current wall clock) if the string is malformed.
pub fn isoToUnixMs(iso: []const u8, fallback_ms: i64) i64 {
    const secs = isoToUnixSeconds(iso) orelse return fallback_ms;
    return secs * 1000;
}

fn isoToUnixSeconds(iso: []const u8) ?i64 {
    // Expect at least "YYYY-MM-DDTHH:MM:SS" (19 chars).
    if (iso.len < 19) return null;
    if (iso[4] != '-' or iso[7] != '-') return null;
    if (iso[10] != 'T' and iso[10] != ' ') return null;
    if (iso[13] != ':' or iso[16] != ':') return null;

    const year = parseField(iso[0..4]) orelse return null;
    const month = parseField(iso[5..7]) orelse return null;
    const day = parseField(iso[8..10]) orelse return null;
    const hour = parseField(iso[11..13]) orelse return null;
    const minute = parseField(iso[14..16]) orelse return null;
    const second = parseField(iso[17..19]) orelse return null;

    if (month < 1 or month > 12 or day < 1 or day > 31) return null;

    const days = daysFromCivil(year, @intCast(month), @intCast(day));
    var total: i64 = days * 86400 + hour * 3600 + minute * 60 + second;

    // Timezone offset: after the seconds we may have Z, +HH:MM, or -HH:MM.
    if (iso.len > 19) {
        const tz = iso[19..];
        if (tz[0] == '+' or tz[0] == '-') {
            // Accept "+HH:MM" or "+HHMM".
            if (tz.len >= 3) {
                const off_h = parseField(tz[1..3]) orelse 0;
                var off_m: i64 = 0;
                if (tz.len >= 6 and tz[3] == ':') {
                    off_m = parseField(tz[4..6]) orelse 0;
                } else if (tz.len >= 5) {
                    off_m = parseField(tz[3..5]) orelse 0;
                }
                const offset = off_h * 3600 + off_m * 60;
                total -= if (tz[0] == '+') offset else -offset;
            }
        }
        // 'Z' (or anything else) => already UTC, no adjustment.
    }
    return total;
}

fn parseField(s: []const u8) ?i64 {
    return std.fmt.parseInt(i64, s, 10) catch null;
}

/// Days since Unix epoch (1970-01-01) for a civil Y-M-D, per Howard
/// Hinnant's public-domain algorithm.
fn daysFromCivil(y_in: i64, m: u32, d: u32) i64 {
    const y = if (m <= 2) y_in - 1 else y_in;
    const era = @divFloor(if (y >= 0) y else y - 399, 400);
    const yoe: i64 = y - era * 400; // [0, 399]
    const mp: i64 = @intCast((m + 9) % 12); // Mar=0..Feb=11
    const doy: i64 = @divFloor(153 * mp + 2, 5) + @as(i64, d) - 1; // [0,365]
    const doe: i64 = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

// ------------------------------------------------ event insert builder

/// Column list / SQL for inserting a commit event.
pub const insert_sql =
    "INSERT INTO events(repo_id, kind, occurred_at, commit_oid, author_name, author_email, subject, body, files_changed, insertions, deletions, created_at) " ++
    "VALUES(?1, 'commit', ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11);";

/// Number of bind params `insertStatement` fills.
pub const insert_param_count = 11;

/// Fill a caller-owned param buffer for one commit-event insert and return
/// the statement pointing into it. The buffer (and the commit's borrowed
/// slices) MUST outlive the `dbExec` call — params are copied at call time.
/// `occurred_at` is the commit's author time in Unix-ms; `now_ms` is the
/// capture (created_at) time.
pub fn insertStatement(
    buf: *[insert_param_count]db.Value,
    repo_id: i64,
    commit: Commit,
    occurred_at_ms: i64,
    now_ms: i64,
) db.Statement {
    buf.* = .{
        db.val.int(repo_id),
        db.val.int(occurred_at_ms),
        db.val.text(commit.oid),
        db.val.text(commit.author_name),
        db.val.text(commit.author_email),
        db.val.text(commit.subject),
        db.val.text(commit.body),
        db.val.int(commit.files_changed),
        db.val.int(commit.insertions),
        db.val.int(commit.deletions),
        db.val.int(now_ms),
    };
    return .{ .sql = insert_sql, .params = buf };
}

/// Update a repo's incremental-capture bookkeeping after indexing.
pub const update_indexed_sql =
    "UPDATE repos SET last_indexed_oid = ?1, last_indexed_at = ?2 WHERE id = ?3;";

pub fn updateIndexedStatement(
    buf: *[3]db.Value,
    repo_id: i64,
    last_oid: []const u8,
    now_ms: i64,
) db.Statement {
    buf.* = .{ db.val.text(last_oid), db.val.int(now_ms), db.val.int(repo_id) };
    return .{ .sql = update_indexed_sql, .params = buf };
}

/// Query for a repo's stored `last_indexed_oid` (NULL when never indexed).
pub const select_last_indexed_sql = "SELECT last_indexed_oid FROM repos WHERE id = ?1;";

// --------------------------------------------------------------- tests

const testing = std.testing;

test "logArgv builds a full-history command without a range" {
    var argv: [max_argv][]const u8 = undefined;
    var fbuf: [64]u8 = undefined;
    var rbuf: [64]u8 = undefined;
    const cmd = logArgv(&argv, &fbuf, &rbuf, "/Users/rui/repo", "");
    try testing.expectEqual(@as(usize, 7), cmd.len);
    try testing.expectEqualStrings("git", cmd[0]);
    try testing.expectEqualStrings("-C", cmd[1]);
    try testing.expectEqualStrings("/Users/rui/repo", cmd[2]);
    try testing.expectEqualStrings("log", cmd[3]);
    try testing.expectEqualStrings("--reverse", cmd[4]);
    try testing.expectEqualStrings("--numstat", cmd[5]);
    try testing.expect(std.mem.startsWith(u8, cmd[6], "--format="));
}

test "logArgv appends since..HEAD when a since oid is given" {
    var argv: [max_argv][]const u8 = undefined;
    var fbuf: [64]u8 = undefined;
    var rbuf: [64]u8 = undefined;
    const cmd = logArgv(&argv, &fbuf, &rbuf, "/r", "abc123");
    try testing.expectEqual(@as(usize, 8), cmd.len);
    try testing.expectEqualStrings("abc123..HEAD", cmd[7]);
}

test "parseLog reads a single commit with numstat totals" {
    // \x1e<oid>\x1f<an>\x1f<ae>\x1f<date>\x1f<subject>\x1f<body>\x1f then numstat lines.
    const out =
        "\x1eabc123\x1fRui\x1frui@example.com\x1f2026-09-10T14:03:22+02:00\x1fInitial commit\x1f\x1f\n" ++
        "10\t0\tsrc/main.zig\n" ++
        "3\t1\tREADME.md\n";
    var buf: [4]Commit = undefined;
    const commits = try parseLog(&buf, out);
    try testing.expectEqual(@as(usize, 1), commits.len);
    const c = commits[0];
    try testing.expectEqualStrings("abc123", c.oid);
    try testing.expectEqualStrings("Rui", c.author_name);
    try testing.expectEqualStrings("rui@example.com", c.author_email);
    try testing.expectEqualStrings("Initial commit", c.subject);
    try testing.expectEqualStrings("", c.body);
    try testing.expectEqual(@as(i64, 2), c.files_changed);
    try testing.expectEqual(@as(i64, 13), c.insertions);
    try testing.expectEqual(@as(i64, 1), c.deletions);
}

test "parseLog reads multiple commits and a multi-line body" {
    const out =
        "\x1eaaa\x1fRui\x1fr@e\x1f2026-01-01T00:00:00Z\x1ffirst\x1f\x1f\n" ++
        "1\t0\ta.txt\n" ++
        "\x1ebbb\x1fRui\x1fr@e\x1f2026-01-02T00:00:00Z\x1fsecond\x1fline one\nline two\x1f\n" ++
        "2\t2\tb.txt\n" ++
        "-\t-\timg.png\n";
    var buf: [8]Commit = undefined;
    const commits = try parseLog(&buf, out);
    try testing.expectEqual(@as(usize, 2), commits.len);
    try testing.expectEqualStrings("aaa", commits[0].oid);
    try testing.expectEqualStrings("first", commits[0].subject);
    try testing.expectEqualStrings("bbb", commits[1].oid);
    try testing.expectEqualStrings("line one\nline two", commits[1].body);
    // Binary file counted in files_changed, zero line deltas from "-".
    try testing.expectEqual(@as(i64, 2), commits[1].files_changed);
    try testing.expectEqual(@as(i64, 2), commits[1].insertions);
    try testing.expectEqual(@as(i64, 2), commits[1].deletions);
}

test "parseLog on empty output yields nothing" {
    var buf: [4]Commit = undefined;
    const commits = try parseLog(&buf, "");
    try testing.expectEqual(@as(usize, 0), commits.len);
}

test "parseLog tolerates a commit with no file changes (merge/empty)" {
    const out = "\x1eccc\x1fRui\x1fr@e\x1f2026-03-03T12:00:00Z\x1fempty\x1f\x1f\n";
    var buf: [2]Commit = undefined;
    const commits = try parseLog(&buf, out);
    try testing.expectEqual(@as(usize, 1), commits.len);
    try testing.expectEqual(@as(i64, 0), commits[0].files_changed);
}

test "isoToUnixMs converts a UTC timestamp" {
    // 2026-01-01T00:00:00Z = 1767225600 seconds since epoch.
    const ms = isoToUnixMs("2026-01-01T00:00:00Z", 0);
    try testing.expectEqual(@as(i64, 1767225600 * 1000), ms);
}

test "isoToUnixMs applies the timezone offset" {
    // +02:00 means local is 2h ahead of UTC, so UTC = local - 2h.
    const utc = isoToUnixMs("2026-01-01T02:00:00Z", 0);
    const plus2 = isoToUnixMs("2026-01-01T04:00:00+02:00", 0);
    try testing.expectEqual(utc, plus2);
}

test "isoToUnixMs falls back on malformed input" {
    try testing.expectEqual(@as(i64, 42), isoToUnixMs("not-a-date", 42));
    try testing.expectEqual(@as(i64, 7), isoToUnixMs("", 7));
}

test "insertStatement carries commit fields as params" {
    const c = Commit{
        .oid = "deadbeef",
        .author_name = "Rui",
        .author_email = "r@e",
        .author_date_iso = "2026-01-01T00:00:00Z",
        .subject = "subj",
        .body = "body",
        .files_changed = 3,
        .insertions = 10,
        .deletions = 4,
    };
    var buf: [insert_param_count]db.Value = undefined;
    const stmt = insertStatement(&buf, 5, c, 1234, 9999);
    try testing.expectEqual(@as(usize, insert_param_count), stmt.params.len);
    try testing.expectEqual(@as(i64, 5), stmt.params[0].integer);
    try testing.expectEqual(@as(i64, 1234), stmt.params[1].integer);
    try testing.expectEqualStrings("deadbeef", stmt.params[2].text);
    try testing.expectEqualStrings("subj", stmt.params[5].text);
    try testing.expectEqual(@as(i64, 3), stmt.params[7].integer);
    try testing.expectEqual(@as(i64, 10), stmt.params[8].integer);
    try testing.expectEqual(@as(i64, 4), stmt.params[9].integer);
    try testing.expectEqual(@as(i64, 9999), stmt.params[10].integer);
}

test "updateIndexedStatement carries oid + times" {
    var buf: [3]db.Value = undefined;
    const stmt = updateIndexedStatement(&buf, 7, "abc", 555);
    try testing.expectEqualStrings("abc", stmt.params[0].text);
    try testing.expectEqual(@as(i64, 555), stmt.params[1].integer);
    try testing.expectEqual(@as(i64, 7), stmt.params[2].integer);
}

// ---- Real-database integration tests ----

const native_sdk = @import("native_sdk");
const relational_store = native_sdk.runtime.relational_store;
const IntMsg = union(enum) { db: native_sdk.EffectDbResult };
const IntFx = native_sdk.Effects(IntMsg);

test "parsed commits insert into events and read back with correct totals" {
    const open_result = try relational_store.Database.openMemoryMigrated(testing.allocator, &db.migrations);
    try testing.expectEqual(relational_store.OpenOutcome.ok, open_result.outcome);
    var database = open_result.database.?;
    defer database.deinit();
    var fx = IntFx.init(testing.allocator);
    defer fx.deinit();
    fx.bindRelationalStore(database.binding());

    // A repo to attach events to.
    var rbuf: [3]db.Value = undefined;
    rbuf = .{ db.val.int(1), db.val.text("/r"), db.val.int(1) };
    fx.dbExec(.{ .key = 1, .statements = &.{
        .{ .sql = "INSERT INTO repos(id, path, name, added_at) VALUES(?1, ?2, 'r', ?3);", .params = &rbuf },
    }, .on_result = IntFx.dbMsg(.db) });
    try testing.expectEqual(native_sdk.EffectDbOutcome.ok, fx.takeMsg().?.db.outcome);

    // Parse two commits from canonical log output.
    const out =
        "\x1eaaa111\x1fRui\x1fr@e\x1f2026-01-01T00:00:00Z\x1ffirst\x1f\x1f\n" ++
        "10\t2\tsrc/a.zig\n" ++
        "\x1ebbb222\x1fRui\x1fr@e\x1f2026-01-02T00:00:00Z\x1fsecond\x1fbody text\x1f\n" ++
        "1\t1\tsrc/b.zig\n";
    var commits_buf: [8]Commit = undefined;
    const commits = try parseLog(&commits_buf, out);
    try testing.expectEqual(@as(usize, 2), commits.len);

    // Insert both + a bookkeeping update, exactly as capture does.
    var ins: [2][insert_param_count]db.Value = undefined;
    var upd: [3]db.Value = undefined;
    var stmts: [3]db.Statement = undefined;
    stmts[0] = insertStatement(&ins[0], 1, commits[0], isoToUnixMs(commits[0].author_date_iso, 0), 500);
    stmts[1] = insertStatement(&ins[1], 1, commits[1], isoToUnixMs(commits[1].author_date_iso, 0), 500);
    stmts[2] = updateIndexedStatement(&upd, 1, commits[1].oid, 500);
    fx.dbExec(.{ .key = 2, .statements = &stmts, .on_result = IntFx.dbMsg(.db) });
    try testing.expectEqual(native_sdk.EffectDbOutcome.ok, fx.takeMsg().?.db.outcome);

    // Read back: two commit events, ordered by occurred_at.
    fx.dbQuery(.{ .key = 3, .sql = "SELECT commit_oid, subject, files_changed, insertions, deletions FROM events WHERE repo_id=1 ORDER BY occurred_at;", .on_result = IntFx.dbMsg(.db) });
    const page = fx.takeMsg().?.db;
    try testing.expectEqual(native_sdk.EffectDbResultKind.page, page.kind);
    var reader = try db.PageReader.init(page.bytes);
    try testing.expectEqual(@as(usize, 2), reader.rowCount());
    var row: [5]db.ColumnValue = undefined;
    const r0 = (try reader.next(&row)).?;
    try testing.expectEqualStrings("aaa111", r0[0].asText().?);
    try testing.expectEqualStrings("first", r0[1].asText().?);
    try testing.expectEqual(@as(i64, 1), r0[2].asInt().?);
    try testing.expectEqual(@as(i64, 10), r0[3].asInt().?);
    try testing.expectEqual(@as(i64, 2), r0[4].asInt().?);
    const r1 = (try reader.next(&row)).?;
    try testing.expectEqualStrings("bbb222", r1[0].asText().?);
    _ = fx.takeMsg(); // .done

    // Bookkeeping stored the newest oid.
    fx.dbQuery(.{ .key = 4, .sql = "SELECT last_indexed_oid FROM repos WHERE id=1;", .on_result = IntFx.dbMsg(.db) });
    const bpage = fx.takeMsg().?.db;
    var breader = try db.PageReader.init(bpage.bytes);
    var brow: [1]db.ColumnValue = undefined;
    const bcols = (try breader.next(&brow)).?;
    try testing.expectEqualStrings("bbb222", bcols[0].asText().?);
    _ = fx.takeMsg(); // .done
}

test "re-inserting the same commit hits the UNIQUE(repo_id, commit_oid) constraint" {
    const open_result = try relational_store.Database.openMemoryMigrated(testing.allocator, &db.migrations);
    try testing.expectEqual(relational_store.OpenOutcome.ok, open_result.outcome);
    var database = open_result.database.?;
    defer database.deinit();
    var fx = IntFx.init(testing.allocator);
    defer fx.deinit();
    fx.bindRelationalStore(database.binding());

    fx.dbExec(.{ .key = 1, .statements = &.{
        .{ .sql = "INSERT INTO repos(id, path, name, added_at) VALUES(1, '/r', 'r', 1);" },
    }, .on_result = IntFx.dbMsg(.db) });
    try testing.expectEqual(native_sdk.EffectDbOutcome.ok, fx.takeMsg().?.db.outcome);

    const c = Commit{
        .oid = "dupoid",
        .author_name = "Rui",
        .author_email = "r@e",
        .author_date_iso = "2026-01-01T00:00:00Z",
        .subject = "s",
        .body = "",
    };
    var p1: [insert_param_count]db.Value = undefined;
    fx.dbExec(.{ .key = 2, .statements = &.{insertStatement(&p1, 1, c, 1000, 1000)}, .on_result = IntFx.dbMsg(.db) });
    try testing.expectEqual(native_sdk.EffectDbOutcome.ok, fx.takeMsg().?.db.outcome);

    // A second insert of the same (repo_id, commit_oid) must be rejected —
    // this is why incremental capture only asks git for `<since>..HEAD`.
    var p2: [insert_param_count]db.Value = undefined;
    fx.dbExec(.{ .key = 3, .statements = &.{insertStatement(&p2, 1, c, 1000, 1000)}, .on_result = IntFx.dbMsg(.db) });
    try testing.expectEqual(native_sdk.EffectDbOutcome.constraint, fx.takeMsg().?.db.outcome);
}
